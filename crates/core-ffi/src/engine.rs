use core_audio::network_monitor::{NetworkMonitor, NetworkMonitorConfig};
use core_audio::streaming::L2CacheManager;
use core_audio::AudioPlayer;
use core_db::{FallbackCredentialStore, L1StreamCacheRepository, MemoryCredentialStore, SqlitePool};
use core_providers::{IngestionPipeline, ProviderManager, StorageWatcherManager};
use core_server::zones::ZoneManager;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::sync::{oneshot, watch};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct PlayDispatchCmd {
    pub payload: String,
    pub request_id: u64,
    pub generation: u64,
    pub task_epoch: u64,
    pub player_play_ep: u64,
    pub cancel_token: CancellationToken,
    pub debounced: bool,
    pub rapid_within_300ms: bool,
}

#[derive(Clone)]
pub struct StandbyDispatchCmd {
    pub payload: String,
    pub eff_epoch: Option<u64>,
    pub cancel_token: CancellationToken,
}

pub struct EngineState {
    pub runtime: Runtime,
    pub created_at: Instant,
    pub initialized: AtomicBool,
    pub playback_state: AtomicI32, // 0=Uninit, 1=Stopped, 2=Playing, 3=Paused, 4=Error, 5=Loading
    pub has_real_stream: AtomicBool,
    pub playback_epoch: AtomicU64,
    pub epoch: AtomicU64,
    pub last_caller_epoch: AtomicU64,
    pub last_play_dispatch_ms: AtomicU64,
    pub play_request_id: AtomicU64,
    pub loaded_request_id: AtomicU64,
    pub async_generation: AtomicU64,
    pub active_play_cancel: RwLock<Option<CancellationToken>>,
    pub active_standby_cancel: RwLock<Option<CancellationToken>>,
    pub play_cmd_tx: watch::Sender<Option<PlayDispatchCmd>>,
    pub play_cmd_rx: Mutex<Option<watch::Receiver<Option<PlayDispatchCmd>>>>,
    pub standby_cmd_tx: watch::Sender<Option<StandbyDispatchCmd>>,
    pub standby_cmd_rx: Mutex<Option<watch::Receiver<Option<StandbyDispatchCmd>>>>,
    pub async_last_error: RwLock<Option<String>>,
    pub async_last_error_code: RwLock<Option<String>>,
    pub async_last_error_provider: RwLock<Option<String>>,
    pub volume_bits: AtomicU64, // f32 stored in atomic
    pub position_ms: AtomicU64,
    pub duration_ms: AtomicU64,
    pub dsp_bypassed: AtomicBool,
    pub server_running: AtomicBool,
    pub server_port: AtomicU16,
    pub active_track_json: RwLock<Option<String>>,
    pub db_path: RwLock<Option<String>>,
    pub db_pool: RwLock<Option<SqlitePool>>,
    pub l2_cache_manager: RwLock<Option<Arc<L2CacheManager>>>,
    pub player: RwLock<Option<AudioPlayer>>,
    pub server_shutdown: RwLock<Option<oneshot::Sender<()>>>,
    pub network_monitor: Mutex<Option<NetworkMonitor>>,
    #[cfg(target_os = "windows")]
    pub device_watcher: Mutex<Option<core_audio::backend::device_watcher_win::DeviceWatcher>>,
    pub provider_manager: Arc<ProviderManager>,
    pub active_profile_id: RwLock<Option<String>>,
    pub zone_manager: Arc<ZoneManager>,
    pub ingestion_pipeline: RwLock<Option<IngestionPipeline>>,
    pub watcher_manager: RwLock<Option<StorageWatcherManager>>,
    pub scan_progress_relay_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl EngineState {
    pub fn new() -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .expect("create FFI tokio runtime");
        let cred_store = Arc::new(FallbackCredentialStore::new(Arc::new(
            MemoryCredentialStore::new(),
        )));
        let provider_manager = Arc::new(ProviderManager::with_credential_store(cred_store));
        let zone_manager = Arc::new(ZoneManager::new(None));
        let (play_cmd_tx, play_cmd_rx) = watch::channel(None);
        let (standby_cmd_tx, standby_cmd_rx) = watch::channel(None);

        Self {
            runtime,
            created_at: Instant::now(),
            initialized: AtomicBool::new(false),
            playback_state: AtomicI32::new(0),
            has_real_stream: AtomicBool::new(false),
            playback_epoch: AtomicU64::new(0),
            epoch: AtomicU64::new(0),
            last_caller_epoch: AtomicU64::new(0),
            last_play_dispatch_ms: AtomicU64::new(0),
            play_request_id: AtomicU64::new(0),
            loaded_request_id: AtomicU64::new(0),
            async_generation: AtomicU64::new(0),
            active_play_cancel: RwLock::new(None),
            active_standby_cancel: RwLock::new(None),
            play_cmd_tx,
            play_cmd_rx: Mutex::new(Some(play_cmd_rx)),
            standby_cmd_tx,
            standby_cmd_rx: Mutex::new(Some(standby_cmd_rx)),
            async_last_error: RwLock::new(None),
            async_last_error_code: RwLock::new(None),
            async_last_error_provider: RwLock::new(None),
            volume_bits: AtomicU64::new((1.0f32).to_bits() as u64),
            position_ms: AtomicU64::new(0),
            duration_ms: AtomicU64::new(245_000), // Default demo track 4:05
            dsp_bypassed: AtomicBool::new(false),
            server_running: AtomicBool::new(false),
            server_port: AtomicU16::new(0),
            active_track_json: RwLock::new(None),
            db_path: RwLock::new(None),
            db_pool: RwLock::new(None),
            l2_cache_manager: RwLock::new(None),
            player: RwLock::new(None),
            server_shutdown: RwLock::new(None),
            network_monitor: Mutex::new(None),
            #[cfg(target_os = "windows")]
            device_watcher: Mutex::new(None),
            provider_manager,
            active_profile_id: RwLock::new(None),
            zone_manager,
            ingestion_pipeline: RwLock::new(None),
            watcher_manager: RwLock::new(None),
            scan_progress_relay_task: Mutex::new(None),
        }
    }

    pub fn shutdown_ingestion(&self) {
        if let Ok(mut guard) = self.scan_progress_relay_task.lock()
            && let Some(handle) = guard.take()
        {
            handle.abort();
        }
        let taken_watcher = self.watcher_manager.write().ok().and_then(|mut g| g.take());
        if let Some(watcher) = taken_watcher {
            self.runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), watcher.shutdown()).await;
            });
        }
        if let Ok(mut guard) = self.ingestion_pipeline.write() {
            *guard = None;
        }
    }

    pub fn init_ingestion_for_pool(
        &self,
        pool: SqlitePool,
    ) -> (IngestionPipeline, StorageWatcherManager) {
        self.shutdown_ingestion();
        let pipeline = IngestionPipeline::with_defaults(pool);
        let watcher = {
            let _enter = self.runtime.enter();
            StorageWatcherManager::with_default_debounce(pipeline.clone())
        };
        let restore_watcher = watcher.clone();
        self.runtime.block_on(async move {
            let _ = restore_watcher.restore_watched_roots().await;
        });

        let mut rx = pipeline.subscribe_progress();
        let relay_handle = self.runtime.spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => crate::library::dispatch_scan_progress_event(&ev),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        if let Ok(mut guard) = self.scan_progress_relay_task.lock() {
            *guard = Some(relay_handle);
        }
        if let Ok(mut guard) = self.ingestion_pipeline.write() {
            *guard = Some(pipeline.clone());
        }
        if let Ok(mut guard) = self.watcher_manager.write() {
            *guard = Some(watcher.clone());
        }
        (pipeline, watcher)
    }

    pub fn player_clone(&self) -> Option<AudioPlayer> {
        self.player.read().ok().and_then(|g| g.clone())
    }

    pub fn elapsed_ms_since_start(&self) -> u64 {
        (self.created_at.elapsed().as_millis() as u64).max(1)
    }

    pub fn set_volume(&self, vol: f32) {
        let clamped = if vol.is_nan() { 0.0 } else { vol.clamp(0.0, 1.0) };
        if let Some(p) = self.player_clone() {
            p.set_volume(clamped);
            let effective = p.volume();
            self.volume_bits
                .store(effective.to_bits() as u64, Ordering::Relaxed);
            return;
        }
        self.volume_bits
            .store(clamped.to_bits() as u64, Ordering::Relaxed);
    }

    pub fn get_volume(&self) -> f32 {
        if let Some(p) = self.player_clone() {
            return p.volume();
        }
        let bits = self.volume_bits.load(Ordering::Relaxed) as u32;
        f32::from_bits(bits)
    }

    pub fn init_player(&self, headless: bool) {
        if let Ok(mut mon_guard) = self.network_monitor.lock()
            && let Some(prev) = mon_guard.take()
        {
            prev.stop();
        }
        #[cfg(target_os = "windows")]
        if let Ok(mut dw_guard) = self.device_watcher.lock() {
            *dw_guard = None;
        }

        let saved_vol = f32::from_bits(self.volume_bits.load(Ordering::Relaxed) as u32);
        let new_player = if headless {
            AudioPlayer::new_headless()
        } else {
            AudioPlayer::new()
        };
        new_player.set_dsp_bypass(self.dsp_bypassed.load(Ordering::Relaxed));
        new_player.set_volume(saved_vol);
        new_player.set_stream_refresh_handler(Some(
            crate::streaming_bridge::ffi_stream_refresh_handler(),
        ));
        if let Ok(guard) = self.l2_cache_manager.read()
            && let Some(ref mgr) = *guard
        {
            new_player.set_l2_cache_manager(Some(Arc::clone(mgr)));
        } else if let Some(mgr) = crate::l2_cache::ensure_default_l2_cache_manager(self) {
            new_player.set_l2_cache_manager(Some(mgr));
        }

        let hook_player = new_player.clone();
        crate::streaming_bridge::register_provider_cancel_hook(Some(Arc::new(
            move |provider_id: &str| {
                let cancelled = hook_player.cancel_active_stream_for_provider(provider_id);
                let eng = get_engine();
                let loading_matches = eng
                    .active_track_json
                    .read()
                    .ok()
                    .and_then(|g| g.clone())
                    .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
                    .and_then(|v| {
                        v.get("provider_id")
                            .or_else(|| v.get("provider"))
                            .or_else(|| {
                                v.get("source_spec")
                                    .and_then(|s| s.get("key"))
                                    .and_then(|k| k.get("provider_id"))
                            })
                            .and_then(|s| s.as_str())
                            .map(|s| s.eq_ignore_ascii_case(provider_id))
                    })
                    .unwrap_or(false);
                if cancelled || loading_matches {
                    eng.clear_pending_commands();
                    eng.cancel_active_play_token();
                    eng.cancel_active_standby_token();
                    eng.async_generation.fetch_add(1, Ordering::SeqCst);
                    eng.advance_playback_epoch(None);
                    eng.has_real_stream.store(false, Ordering::SeqCst);
                    eng.playback_state.store(4, Ordering::SeqCst);
                    let req_id = eng.play_request_id.load(Ordering::SeqCst);
                    eng.loaded_request_id.store(req_id, Ordering::SeqCst);
                    if let Ok(mut e) = eng.async_last_error.write() {
                        *e = Some(format!("Authentication required for {provider_id}"));
                    }
                    if let Ok(mut c) = eng.async_last_error_code.write() {
                        *c = Some("AUTH_REQUIRED".to_string());
                    }
                    if let Ok(mut pr) = eng.async_last_error_provider.write() {
                        *pr = Some(provider_id.to_string());
                    }
                }
            },
        )));

        let prev_player = if let Ok(mut lock) = self.player.write() {
            lock.replace(new_player.clone())
        } else {
            None
        };
        if let Some(prev) = prev_player {
            prev.shutdown();
        }

        if !headless {
            let mon_cfg = NetworkMonitorConfig {
                on_l1_prune: Some(Arc::new(|providers: &[&str], epoch: u64| {
                    let eng = get_engine();
                    let provider_ids: Vec<String> =
                        providers.iter().map(|s| (*s).to_string()).collect();
                    crate::l1_cache::enqueue_prune_stale_epoch(&eng, provider_ids, epoch);
                })),
                on_epoch_changed: Some(Arc::new(|epoch: u64| {
                    crate::streaming_bridge::notify_network_epoch_changed(epoch);
                })),
                reset_http_pools: true,
                ..Default::default()
            };
            match NetworkMonitor::start_system(mon_cfg) {
                Ok(mon) => {
                    if let Ok(mut mon_guard) = self.network_monitor.lock() {
                        *mon_guard = Some(mon);
                    }
                }
                Err(e) => {
                    tracing::warn!("Failed to start NetworkMonitor: {e}");
                }
            }

            #[cfg(target_os = "windows")]
            {
                let watcher_player = new_player.clone();
                match core_audio::backend::device_watcher_win::DeviceWatcher::start(move |ev| {
                    watcher_player.handle_device_event(ev);
                }) {
                    Ok(watcher) => {
                        if let Ok(mut dw_guard) = self.device_watcher.lock() {
                            *dw_guard = Some(watcher);
                        }
                    }
                    Err(e) => {
                        tracing::warn!("Failed to start Windows DeviceWatcher: {e}");
                    }
                }
            }
        }

        self.runtime
            .block_on(self.zone_manager.sync_local_default_zone(Some(&new_player)));
        self.has_real_stream.store(false, Ordering::SeqCst);
        self.initialized.store(true, Ordering::SeqCst);
        self.playback_state.store(1, Ordering::SeqCst); // 1 = Stopped / Ready
    }

    pub fn current_playback_epoch(&self) -> u64 {
        let ep = self.playback_epoch.load(Ordering::SeqCst);
        let player_ep = self
            .player_clone()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        ep.max(player_ep)
    }

    pub fn current_epoch(&self) -> u64 {
        let ep = self.epoch.load(Ordering::SeqCst);
        let pb_ep = self.playback_epoch.load(Ordering::SeqCst);
        let player_ep = self
            .player_clone()
            .map(|p| p.current_epoch().max(p.playback_epoch()))
            .unwrap_or(0);
        ep.max(pb_ep).max(player_ep)
    }

    pub fn advance_playback_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let (player_ep, player_pb_ep) = self
            .player_clone()
            .map(|p| (p.current_epoch(), p.playback_epoch()))
            .unwrap_or((0, 0));
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        let next = loop {
            let floor = cur.max(player_pb_ep);
            let candidate = match caller_epoch {
                Some(ep) if ep > floor => ep,
                _ => floor.saturating_add(1).max(1),
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                candidate,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break candidate,
                Err(actual) => cur = actual,
            }
        };
        if caller_epoch.is_none() {
            let mut ep_cur = self.epoch.load(Ordering::SeqCst);
            loop {
                let floor = ep_cur.max(player_ep);
                let ep_next = floor.saturating_add(1).max(next);
                match self.epoch.compare_exchange_weak(
                    ep_cur,
                    ep_next,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    Ok(_) => break,
                    Err(actual) => ep_cur = actual,
                }
            }
        } else {
            self.epoch.fetch_max(next.max(player_ep), Ordering::SeqCst);
        }
        next
    }

    pub fn sync_playback_epoch_from_player(&self, player: &AudioPlayer, min_epoch: u64) -> u64 {
        let eff_pb = min_epoch.max(player.playback_epoch());
        let prev_pb = self.playback_epoch.fetch_max(eff_pb, Ordering::SeqCst);
        let final_pb = prev_pb.max(eff_pb);
        self.epoch
            .fetch_max(final_pb.max(player.current_epoch()), Ordering::SeqCst);
        final_pb
    }

    /// Advances `playback_epoch` monotonically after an epoch-less `player.begin_skip_transition()`.
    /// Uses `player.playback_epoch()` when it already exceeds the current floor (no double-bump),
    /// otherwise increments `self.playback_epoch` by 1 so the caller never observes a stale epoch.
    pub fn advance_after_epochless_skip(&self, player: &AudioPlayer) -> u64 {
        let player_pb = player.playback_epoch();
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        let next = loop {
            let candidate = if player_pb > cur {
                player_pb
            } else {
                cur.saturating_add(1).max(1)
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                candidate,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => break candidate,
                Err(actual) => cur = actual,
            }
        };
        self.epoch
            .fetch_max(next.max(player.current_epoch()), Ordering::SeqCst);
        next
    }

    pub fn advance_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let player_ep = self
            .player_clone()
            .map(|p| p.current_epoch())
            .unwrap_or(0);
        let mut cur = self.epoch.load(Ordering::SeqCst);
        loop {
            let floor = cur.max(player_ep);
            let next = match caller_epoch {
                Some(ep) if ep > floor => ep,
                _ => floor.saturating_add(1).max(1),
            };
            match self
                .epoch
                .compare_exchange_weak(cur, next, Ordering::SeqCst, Ordering::SeqCst)
            {
                Ok(_) => return next,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn accept_caller_epoch(&self, caller_epoch: Option<u64>) -> bool {
        let Some(ep) = caller_epoch.filter(|&e| e > 0) else {
            return true;
        };
        let mut cur = self.last_caller_epoch.load(Ordering::SeqCst);
        loop {
            if ep < cur {
                return false;
            }
            if ep == cur {
                return true;
            }
            match self.last_caller_epoch.compare_exchange_weak(
                cur,
                ep,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return true,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn cancel_active_play_token(&self) {
        if let Ok(mut guard) = self.active_play_cancel.write()
            && let Some(token) = guard.take()
        {
            token.cancel();
        }
    }

    pub fn swap_play_cancel_token(&self, new_token: CancellationToken) {
        if let Ok(mut guard) = self.active_play_cancel.write()
            && let Some(prev) = guard.replace(new_token)
        {
            prev.cancel();
        }
    }

    pub fn cancel_active_standby_token(&self) {
        if let Ok(mut guard) = self.active_standby_cancel.write()
            && let Some(token) = guard.take()
        {
            token.cancel();
        }
    }

    pub fn swap_standby_cancel_token(&self, new_token: CancellationToken) {
        if let Ok(mut guard) = self.active_standby_cancel.write()
            && let Some(prev) = guard.replace(new_token)
        {
            prev.cancel();
        }
    }

    pub fn clear_pending_commands(&self) {
        let _ = self.play_cmd_tx.send_replace(None);
        let _ = self.standby_cmd_tx.send_replace(None);
    }

    pub fn reset(&self) {
        // 1. Stop OS network & hardware device monitors first so no callbacks fire during teardown.
        if let Ok(mut mon_guard) = self.network_monitor.lock()
            && let Some(mon) = mon_guard.take()
        {
            mon.stop();
        }
        #[cfg(target_os = "windows")]
        if let Ok(mut dw_guard) = self.device_watcher.lock() {
            *dw_guard = None;
        }

        // 2. Unregister provider cancel hook and abort all pending FFI 403/410 refreshes.
        crate::streaming_bridge::register_provider_cancel_hook(None);
        crate::streaming_bridge::cancel_all_pending_refreshes();

        // 3. Cancel active playback/standby tokens and stop audio player + embedded server.
        self.clear_pending_commands();
        self.cancel_active_play_token();
        self.cancel_active_standby_token();
        if let Ok(mut lock) = self.async_last_error.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.async_last_error_code.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.async_last_error_provider.write() {
            *lock = None;
        }
        self.async_generation.fetch_add(1, Ordering::SeqCst);
        self.playback_epoch.store(0, Ordering::SeqCst);
        self.epoch.store(0, Ordering::SeqCst);
        self.last_caller_epoch.store(0, Ordering::SeqCst);
        self.last_play_dispatch_ms.store(0, Ordering::SeqCst);
        self.play_request_id.store(0, Ordering::SeqCst);
        self.loaded_request_id.store(0, Ordering::SeqCst);
        self.initialized.store(false, Ordering::SeqCst);
        self.playback_state.store(0, Ordering::SeqCst);
        self.has_real_stream.store(false, Ordering::SeqCst);
        self.position_ms.store(0, Ordering::Relaxed);
        self.set_volume(1.0);
        self.dsp_bypassed.store(false, Ordering::Relaxed);
        self.server_running.store(false, Ordering::SeqCst);
        self.server_port.store(0, Ordering::SeqCst);

        let taken_player = self.player.write().ok().and_then(|mut g| g.take());
        if let Some(p) = taken_player {
            p.shutdown();
        }
        if let Ok(mut lock) = self.server_shutdown.write()
            && let Some(tx) = lock.take()
        {
            let _ = tx.send(());
        }

        // 4. Stop ingestion watchers & flush pending background SQLite L1 & L2 cache writes BEFORE closing the pool.
        self.shutdown_ingestion();
        crate::l1_cache::flush_pending_writes(self);
        let taken_l2 = self.l2_cache_manager.write().ok().and_then(|mut g| g.take());
        if let Some(mgr) = taken_l2 {
            self.runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), mgr.shutdown()).await;
            });
        }

        // 5. Run WAL TRUNCATE checkpoint & close SQLite pool with a bounded 2s timeout.
        let taken_pool = self.db_pool.write().ok().and_then(|mut g| g.take());
        if let Some(pool) = taken_pool {
            self.runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), async move {
                    let _ = L1StreamCacheRepository::wal_checkpoint_truncate(&pool).await;
                    pool.close().await;
                })
                .await;
            });
        }

        if let Ok(mut lock) = self.active_track_json.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.active_profile_id.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.db_path.write() {
            *lock = None;
        }

        // 6. Drop & rebuild shared Rust HTTP Keep-Alive connection pools cleanly.
        let _ = core_audio::streaming::reset_shared_http_client();
        core_audio::stream::reset_http_client();
    }
}

impl Default for EngineState {
    fn default() -> Self {
        Self::new()
    }
}

static GLOBAL_ENGINE: OnceLock<Arc<EngineState>> = OnceLock::new();

pub fn get_engine() -> Arc<EngineState> {
    GLOBAL_ENGINE
        .get_or_init(|| Arc::new(EngineState::new()))
        .clone()
}
