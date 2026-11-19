use core_audio::AudioPlayer;
use core_db::{FallbackCredentialStore, MemoryCredentialStore, SqlitePool};
use core_providers::ProviderManager;
use core_server::zones::ZoneManager;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use tokio::runtime::Runtime;
use tokio::sync::oneshot;

pub struct EngineState {
    pub runtime: Runtime,
    pub initialized: AtomicBool,
    pub playback_state: AtomicI32, // 0=Uninit, 1=Stopped, 2=Playing, 3=Paused, 4=Error
    pub has_real_stream: AtomicBool,
    pub volume_bits: AtomicU64, // f32 stored in atomic
    pub position_ms: AtomicU64,
    pub duration_ms: AtomicU64,
    pub dsp_bypassed: AtomicBool,
    pub server_running: AtomicBool,
    pub server_port: AtomicU16,
    pub active_track_json: RwLock<Option<String>>,
    pub db_path: RwLock<Option<String>>,
    pub db_pool: RwLock<Option<SqlitePool>>,
    pub player: RwLock<Option<AudioPlayer>>,
    pub server_shutdown: RwLock<Option<oneshot::Sender<()>>>,
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
            volume_bits: AtomicU64::new((1.0f32).to_bits() as u64),
            position_ms: AtomicU64::new(0),
            duration_ms: AtomicU64::new(245_000), // Default demo track 4:05
            dsp_bypassed: AtomicBool::new(false),
            server_running: AtomicBool::new(false),
            server_port: AtomicU16::new(0),
            active_track_json: RwLock::new(None),
            db_path: RwLock::new(None),
            db_pool: RwLock::new(None),
            player: RwLock::new(None),
            server_shutdown: RwLock::new(None),
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
        let saved_vol = f32::from_bits(self.volume_bits.load(Ordering::Relaxed) as u32);
        if let Ok(mut lock) = self.player.write() {
            if let Some(prev) = lock.take() {
                prev.shutdown();
            }
            let p = if headless {
                AudioPlayer::new_headless()
            } else {
                AudioPlayer::new()
            };
            p.set_dsp_bypass(self.dsp_bypassed.load(Ordering::Relaxed));
            p.set_volume(saved_vol);
            *lock = Some(p);
        }
        if let Ok(lock) = self.player.read()
            && let Some(ref p) = *lock
        {
            self.runtime
                .block_on(self.zone_manager.sync_local_default_zone(Some(p)));
        }
        self.has_real_stream.store(false, Ordering::SeqCst);
        self.initialized.store(true, Ordering::SeqCst);
        self.playback_state.store(1, Ordering::SeqCst); // 1 = Stopped / Ready
    }

    pub fn reset(&self) {
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
        if let Ok(mut lock) = self.active_track_json.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.active_profile_id.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.db_path.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.db_pool.write() {
            *lock = None;
        }
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
