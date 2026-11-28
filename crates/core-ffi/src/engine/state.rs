use core_audio::AudioPlayer;
use core_audio::network_monitor::NetworkMonitor;
use core_audio::streaming::L2CacheManager;
use core_db::{FallbackCredentialStore, MemoryCredentialStore, SqlitePool};
use core_providers::{IngestionPipeline, ProviderManager, StorageWatcherManager};
use core_server::zones::ZoneManager;
use core_types::{LuminaError, QueueState, RepeatMode};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU16, AtomicU64};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Instant;
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
    pub last_structured_error: RwLock<Option<LuminaError>>,
    pub volume_bits: AtomicU64, // f32 stored in atomic
    pub pre_mute_volume_bits: AtomicU64,
    pub is_muted: AtomicBool,
    pub repeat_mode: RwLock<RepeatMode>,
    pub shuffle: AtomicBool,
    pub active_zone_id: RwLock<Option<String>>,
    pub active_device_id: RwLock<Option<String>>,
    pub queue_state: RwLock<QueueState>,
    pub sequence: AtomicU64,
    pub position_ms: AtomicU64,
    pub duration_ms: AtomicU64,
    pub dsp_bypassed: AtomicBool,
    pub server_running: AtomicBool,
    pub server_port: AtomicU16,
    pub server_mdns_enabled: AtomicBool,
    pub active_track_json: RwLock<Option<String>>,
    pub db_path: RwLock<Option<String>>,
    pub db_pool: RwLock<Option<SqlitePool>>,
    pub l2_cache_manager: RwLock<Option<Arc<L2CacheManager>>>,
    pub player: RwLock<Option<AudioPlayer>>,
    pub server_shutdown: RwLock<Option<oneshot::Sender<()>>>,
    pub server_task_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub backup_scheduler_cancel: RwLock<Option<CancellationToken>>,
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
            last_structured_error: RwLock::new(None),
            volume_bits: AtomicU64::new((1.0f32).to_bits() as u64),
            pre_mute_volume_bits: AtomicU64::new((1.0f32).to_bits() as u64),
            is_muted: AtomicBool::new(false),
            repeat_mode: RwLock::new(RepeatMode::Off),
            shuffle: AtomicBool::new(false),
            active_zone_id: RwLock::new(Some("zone-local".to_string())),
            active_device_id: RwLock::new(None),
            queue_state: RwLock::new(QueueState::default()),
            sequence: AtomicU64::new(0),
            position_ms: AtomicU64::new(0),
            duration_ms: AtomicU64::new(245_000), // Default demo track 4:05
            dsp_bypassed: AtomicBool::new(false),
            server_running: AtomicBool::new(false),
            server_port: AtomicU16::new(0),
            server_mdns_enabled: AtomicBool::new(false),
            active_track_json: RwLock::new(None),
            db_path: RwLock::new(None),
            db_pool: RwLock::new(None),
            l2_cache_manager: RwLock::new(None),
            player: RwLock::new(None),
            server_shutdown: RwLock::new(None),
            server_task_handle: Mutex::new(None),
            backup_scheduler_cancel: RwLock::new(None),
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
