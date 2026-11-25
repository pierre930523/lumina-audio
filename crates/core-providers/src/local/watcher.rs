use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use core_db::IngestionRepository;
use core_types::{ScanLifecycleState, ScanProgressEvent, WatchMode, WatchedRoot};
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::{broadcast, mpsc, RwLock};
use tokio::task::JoinHandle;
use tracing::{info, warn};

use super::ignore::should_ignore_relative_path;
use super::pipeline::IngestionPipeline;
use super::scanner::normalize_path;
use crate::error::ProviderError;
use crate::library::db_err;

struct ActiveNativeWatch {
    _watcher: RecommendedWatcher,
}

struct ManagedRootEntry {
    root: WatchedRoot,
    last_polled: Option<Instant>,
    was_online: bool,
}

/// Dual-track filesystem & NAS watcher manager:
/// - Track 1: OS native watcher (`notify::RecommendedWatcher`) with debounce + per-root batch queue
/// - Track 2: Lightweight incremental mtime+size polling for `WatchMode::NasPolling`, UNC paths
///   (`\\server\share`), and offline volume reconnect recovery.
#[derive(Clone)]
pub struct StorageWatcherManager {
    pipeline: IngestionPipeline,
    debounce_ms: u64,
    roots: Arc<RwLock<HashMap<String, ManagedRootEntry>>>,
    native_watchers: Arc<RwLock<HashMap<String, ActiveNativeWatch>>>,
    event_tx: mpsc::UnboundedSender<(String, Vec<PathBuf>)>,
    tasks: Arc<RwLock<Vec<JoinHandle<()>>>>,
}

impl StorageWatcherManager {
    pub fn new(pipeline: IngestionPipeline, debounce_ms: u64) -> Self {
        let debounce_ms = debounce_ms.clamp(50, 10_000);
        let roots: Arc<RwLock<HashMap<String, ManagedRootEntry>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let native_watchers: Arc<RwLock<HashMap<String, ActiveNativeWatch>>> =
            Arc::new(RwLock::new(HashMap::new()));
        let (event_tx, event_rx) = mpsc::unbounded_channel::<(String, Vec<PathBuf>)>();

        let debounce_task = spawn_debounce_loop(
            pipeline.clone(),
            roots.clone(),
            event_rx,
            Duration::from_millis(debounce_ms),
        );
        let poll_task = spawn_polling_loop(pipeline.clone(), roots.clone());

        Self {
            pipeline,
            debounce_ms,
            roots,
            native_watchers,
            event_tx,
            tasks: Arc::new(RwLock::new(vec![debounce_task, poll_task])),
        }
    }

    pub fn with_default_debounce(pipeline: IngestionPipeline) -> Self {
        Self::new(pipeline, 750)
    }

    pub fn pipeline(&self) -> &IngestionPipeline {
        &self.pipeline
    }

    pub fn debounce_ms(&self) -> u64 {
        self.debounce_ms
    }

    pub fn subscribe_progress(&self) -> broadcast::Receiver<ScanProgressEvent> {
        self.pipeline.subscribe_progress()
    }

    /// Hydrates persisted `watched_roots` from SQLite and attaches active watchers/pollers.
    pub async fn restore_watched_roots(&self) -> Result<usize, ProviderError> {
        let persisted = IngestionRepository::list_watched_roots(self.pipeline.pool())
            .await
            .map_err(db_err)?;
        let mut count = 0usize;
        for r in persisted {
            let path = PathBuf::from(&r.root_path);
            let _ = self
                .attach_root_entry(r.clone(), &path)
                .await;
            count += 1;
        }
        Ok(count)
    }

    /// Registers a watched root in SQLite and attaches either OS native watcher or NAS polling.
    /// UNC paths (`\\server\share`) automatically select `WatchMode::NasPolling` if `NativeOs` is passed.
    pub async fn add_root(
        &self,
        provider_id: &str,
        root_path: &Path,
        watch_mode: WatchMode,
        poll_interval_sec: u32,
    ) -> Result<WatchedRoot, ProviderError> {
        let raw_str = root_path.to_string_lossy().to_string();
        let effective_mode = if watch_mode == WatchMode::NativeOs && is_network_or_unc_path(&raw_str)
        {
            WatchMode::NasPolling
        } else {
            watch_mode
        };
        let norm_root = normalize_path(root_path);
        let stored = IngestionRepository::upsert_watched_root(
            self.pipeline.pool(),
            provider_id,
            &norm_root,
            effective_mode,
            poll_interval_sec.max(10),
        )
        .await
        .map_err(db_err)?;

        self.attach_root_entry(stored.clone(), root_path).await?;
        Ok(stored)
    }

    async fn attach_root_entry(
        &self,
        stored: WatchedRoot,
        fs_path: &Path,
    ) -> Result<(), ProviderError> {
        let key = normalize_path(&stored.root_path);
        let online = fs_path.exists() && fs_path.is_dir();

        if stored.watch_mode == WatchMode::NativeOs && online {
            let tx = self.event_tx.clone();
            let root_key = key.clone();
            let watch_root = fs_path.to_path_buf();
            let watcher_res = notify::recommended_watcher(move |res: notify::Result<Event>| {
                if let Ok(ev) = res {
                    let filtered: Vec<PathBuf> = ev
                        .paths
                        .into_iter()
                        .filter(|p| !should_ignore_relative_path(p, &watch_root))
                        .collect();
                    if !filtered.is_empty() {
                        let _ = tx.send((root_key.clone(), filtered));
                    }
                }
            });

            match watcher_res {
                Ok(mut watcher) => {
                    if let Err(e) = watcher.watch(fs_path, RecursiveMode::Recursive) {
                        warn!(
                            "Failed to attach native watcher to '{}', falling back to polling: {e}",
                            fs_path.display()
                        );
                    } else {
                        self.native_watchers.write().await.insert(
                            key.clone(),
                            ActiveNativeWatch { _watcher: watcher },
                        );
                        let _ = self.pipeline.progress_sender().send(ScanProgressEvent {
                            scan_id: String::new(),
                            root_path: stored.root_path.clone(),
                            state: ScanLifecycleState::Watching,
                            ..Default::default()
                        });
                    }
                }
                Err(e) => {
                    warn!("Failed to create OS watcher for '{}': {e}", fs_path.display());
                }
            }
        }

        self.roots.write().await.insert(
            key,
            ManagedRootEntry {
                root: stored,
                last_polled: None,
                was_online: online,
            },
        );
        Ok(())
    }

    pub async fn remove_root(&self, id_or_path: &str) -> Result<bool, ProviderError> {
        let key_norm = normalize_path(id_or_path);
        {
            let mut roots = self.roots.write().await;
            let matched_key = roots
                .iter()
                .find(|(k, e)| {
                    e.root.id == id_or_path.trim()
                        || *k == &key_norm
                        || e.root.root_path == id_or_path.trim()
                })
                .map(|(k, _)| k.clone());
            if let Some(k) = matched_key {
                roots.remove(&k);
                self.native_watchers.write().await.remove(&k);
            }
        }
        IngestionRepository::remove_watched_root(self.pipeline.pool(), id_or_path)
            .await
            .map_err(db_err)
    }

    pub async fn list_roots(&self) -> Result<Vec<WatchedRoot>, ProviderError> {
        IngestionRepository::list_watched_roots(self.pipeline.pool())
            .await
            .map_err(db_err)
    }

    /// Manually triggers a full incremental scan for a registered root (by ID or path)
    /// or directly for an arbitrary filesystem path.
    pub async fn trigger_scan(&self, id_or_path: &str) -> Result<ScanProgressEvent, ProviderError> {
        let key_norm = normalize_path(id_or_path);
        let (target_path, provider_id) = {
            let roots = self.roots.read().await;
            if let Some((_, entry)) = roots.iter().find(|(k, e)| {
                e.root.id == id_or_path.trim()
                    || *k == &key_norm
                    || e.root.root_path == id_or_path.trim()
            }) {
                (
                    PathBuf::from(&entry.root.root_path),
                    entry.root.provider_id.clone(),
                )
            } else {
                (PathBuf::from(id_or_path.trim()), "local".to_string())
            }
        };

        let result = self.pipeline.scan_root(&target_path, &provider_id).await;
        if result.is_ok() {
            if let Some(entry) = self.roots.write().await.get_mut(&normalize_path(&target_path)) {
                entry.last_polled = Some(Instant::now());
                entry.was_online = true;
            }
        }
        result
    }

    /// Stops all native watchers and background debounce/polling tasks cleanly.
    pub async fn shutdown(&self) {
        self.native_watchers.write().await.clear();
        let mut tasks = self.tasks.write().await;
        for handle in tasks.drain(..) {
            handle.abort();
        }
    }
}

fn is_network_or_unc_path(raw: &str) -> bool {
    let trimmed = raw.trim();
    trimmed.starts_with(r"\\")
        || trimmed.starts_with("//")
        || trimmed.starts_with("smb://")
        || trimmed.starts_with("dav://")
        || trimmed.starts_with("davs://")
}

fn spawn_debounce_loop(
    pipeline: IngestionPipeline,
    roots: Arc<RwLock<HashMap<String, ManagedRootEntry>>>,
    mut event_rx: mpsc::UnboundedReceiver<(String, Vec<PathBuf>)>,
    debounce_window: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut pending: HashMap<String, (Instant, HashSet<PathBuf>)> = HashMap::new();
        let tick = Duration::from_millis(50);

        loop {
            tokio::select! {
                maybe_ev = event_rx.recv() => {
                    match maybe_ev {
                        Some((root_key, paths)) => {
                            let entry = pending
                                .entry(root_key)
                                .or_insert_with(|| (Instant::now(), HashSet::new()));
                            entry.0 = Instant::now();
                            for p in paths {
                                entry.1.insert(p);
                            }
                        }
                        None => break,
                    }
                }
                _ = tokio::time::sleep(tick), if !pending.is_empty() => {
                    let now = Instant::now();
                    let ready_keys: Vec<String> = pending
                        .iter()
                        .filter(|(_, (last_ts, _))| now.duration_since(*last_ts) >= debounce_window)
                        .map(|(k, _)| k.clone())
                        .collect();

                    for key in ready_keys {
                        if let Some((_, path_set)) = pending.remove(&key) {
                            let target = {
                                let guard = roots.read().await;
                                guard.get(&key).map(|e| {
                                    (PathBuf::from(&e.root.root_path), e.root.provider_id.clone())
                                })
                            };
                            if let Some((root_path, provider_id)) = target {
                                let batch: Vec<PathBuf> = path_set.into_iter().collect();
                                if let Err(e) = pipeline
                                    .process_changed_paths(&root_path, &provider_id, &batch)
                                    .await
                                {
                                    warn!(
                                        "Debounced watcher batch failed for '{}': {e}",
                                        root_path.display()
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }
    })
}

fn spawn_polling_loop(
    pipeline: IngestionPipeline,
    roots: Arc<RwLock<HashMap<String, ManagedRootEntry>>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(1));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            interval.tick().await;
            let snapshot: Vec<(String, WatchedRoot, Option<Instant>, bool)> = {
                let guard = roots.read().await;
                guard
                    .iter()
                    .map(|(k, e)| (k.clone(), e.root.clone(), e.last_polled, e.was_online))
                    .collect()
            };

            let now = Instant::now();
            for (key, root, last_polled, was_online) in snapshot {
                if root.watch_mode == WatchMode::Manual {
                    continue;
                }

                let path = PathBuf::from(&root.root_path);
                let path_check = path.clone();
                let is_online = tokio::task::spawn_blocking(move || {
                    path_check.exists() && path_check.is_dir()
                })
                .await
                .unwrap_or(false);

                if !is_online {
                    if was_online {
                        let _ = IngestionRepository::set_root_online_status(
                            pipeline.pool(),
                            &root.id,
                            false,
                        )
                        .await;
                        if let Some(entry) = roots.write().await.get_mut(&key) {
                            entry.was_online = false;
                        }
                    }
                    continue;
                }

                let reconnected = !was_online;
                let poll_due = root.watch_mode == WatchMode::NasPolling
                    && last_polled.is_none_or(|t| {
                        now.duration_since(t) >= Duration::from_secs(u64::from(root.poll_interval_sec.max(1)))
                    });

                if reconnected || poll_due {
                    if reconnected {
                        info!("Watched root '{}' reconnected; triggering incremental sync", root.root_path);
                        let _ = IngestionRepository::set_root_online_status(
                            pipeline.pool(),
                            &root.id,
                            true,
                        )
                        .await;
                    }
                    let _ = pipeline.scan_root(&path, &root.provider_id).await;
                    if let Some(entry) = roots.write().await.get_mut(&key) {
                        entry.was_online = true;
                        entry.last_polled = Some(Instant::now());
                    }
                }
            }
        }
    })
}
