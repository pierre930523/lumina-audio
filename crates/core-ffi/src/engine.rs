use core_audio::network_monitor::{NetworkMonitor, NetworkMonitorConfig};
use core_audio::streaming::L2CacheManager;
use core_audio::AudioPlayer;
use core_db::{FallbackCredentialStore, L1StreamCacheRepository, MemoryCredentialStore, SqlitePool};
use core_providers::ProviderManager;
use core_server::zones::ZoneManager;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Duration;
use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

pub struct EngineState {
    pub runtime: Runtime,
    pub initialized: AtomicBool,
    pub playback_state: AtomicI32, // 0=Uninit, 1=Stopped, 2=Playing, 3=Paused, 4=Error, 5=Loading
    pub has_real_stream: AtomicBool,
    pub epoch: AtomicU64,
    pub last_caller_epoch: AtomicU64,
    pub play_request_id: AtomicU64,
    pub loaded_request_id: AtomicU64,
    pub async_generation: AtomicU64,
    pub async_commit_lock: Mutex<()>,
    pub active_play_cancel: RwLock<Option<CancellationToken>>,
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
}

impl EngineState {
    pub fn new() -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("create FFI tokio runtime");
        let cred_store = Arc::new(FallbackCredentialStore::new(Arc::new(
            MemoryCredentialStore::new(),
        )));
        let provider_manager = Arc::new(ProviderManager::with_credential_store(cred_store));
        let zone_manager = Arc::new(ZoneManager::new(None));

        Self {
            runtime,
            initialized: AtomicBool::new(false),
            playback_state: AtomicI32::new(0),
            has_real_stream: AtomicBool::new(false),
            epoch: AtomicU64::new(0),
            last_caller_epoch: AtomicU64::new(0),
            play_request_id: AtomicU64::new(0),
            loaded_request_id: AtomicU64::new(0),
            async_generation: AtomicU64::new(0),
            async_commit_lock: Mutex::new(()),
            active_play_cancel: RwLock::new(None),
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
        }
    }

    pub fn set_volume(&self, vol: f32) {
        let clamped = if vol.is_nan() { 0.0 } else { vol.clamp(0.0, 1.0) };
        if let Ok(lock) = self.player.read()
            && let Some(ref p) = *lock
        {
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
        if let Ok(lock) = self.player.read()
            && let Some(ref p) = *lock
        {
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
                    eng.cancel_active_play_token();
                    eng.async_generation.fetch_add(1, Ordering::SeqCst);
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

        if let Ok(mut lock) = self.player.write() {
            if let Some(prev) = lock.take() {
                prev.shutdown();
            }
            *lock = Some(new_player.clone());
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

    pub fn current_epoch(&self) -> u64 {
        let ep = self.epoch.load(Ordering::SeqCst);
        let player_ep = self
            .player
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|p| p.current_epoch()))
            .unwrap_or(0);
        ep.max(player_ep)
    }

    pub fn advance_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let player_ep = self
            .player
            .read()
            .ok()
            .and_then(|g| g.as_ref().map(|p| p.current_epoch()))
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

        // 3. Cancel active playback tokens and stop audio player + embedded server.
        self.cancel_active_play_token();
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
        self.epoch.store(0, Ordering::SeqCst);
        self.last_caller_epoch.store(0, Ordering::SeqCst);
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

        if let Ok(mut lock) = self.player.write()
            && let Some(p) = lock.take()
        {
            p.shutdown();
        }
        if let Ok(mut lock) = self.server_shutdown.write()
            && let Some(tx) = lock.take()
        {
            let _ = tx.send(());
        }

        // 4. Flush pending background SQLite L1 & L2 cache writes BEFORE closing the pool.
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
