pub mod events;
pub mod playback;
pub mod queue;
pub mod watcher;

pub use events::signal_path_to_payload;
pub use watcher::spawn_playback_transition_watcher;

use crate::pairing::PinPairingManager;
use crate::ws::messages::{PlaybackStatePayload, SignalPathPayload, WsMessage};
use crate::zones::ZoneManager;
use core_audio::AudioPlayer;
use core_db::{FallbackCredentialStore, MemoryCredentialStore, SqlitePool};
use core_providers::{
    DEFAULT_DISCOGS_BASE_URL, DEFAULT_MUSICBRAINZ_BASE_URL, IngestionPipeline, ProviderManager,
    StorageWatcherManager,
};
use core_types::{
    AudioCodec, AudioDeviceInfo, AudioFormat, DspPipelineConfig as SharedDspConfig, LuminaError,
    OutputBackendKind, PlaybackLifecycleState, QueueState, RepeatMode, SignalPath,
    StreamSourceSpec, TrackMetadata,
};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{RwLock, broadcast, watch};
use tokio_util::sync::CancellationToken;

pub fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Clone)]
pub struct ServerPlayCmd {
    pub track_id: Option<String>,
    pub file_path: Option<String>,
    pub stream_url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub source: Option<String>,
    pub hint_extension: Option<String>,
    pub source_spec: Option<StreamSourceSpec>,
    pub track: Option<TrackMetadata>,
    pub start_position_ms: Option<u64>,
    pub task_epoch: u64,
    pub player_play_ep: u64,
    pub generation: u64,
    pub cancel_token: CancellationToken,
    pub debounced: bool,
    pub rapid_within_300ms: bool,
}

#[derive(Clone)]
pub struct AppState {
    pub pairing_manager: Arc<PinPairingManager>,
    pub broadcast_tx: broadcast::Sender<WsMessage>,
    pub playback_state: Arc<RwLock<PlaybackStatePayload>>,
    pub signal_path: Arc<RwLock<SignalPathPayload>>,
    pub signal_path_raw: Arc<RwLock<SignalPath>>,
    pub volume: Arc<RwLock<f32>>,
    pub is_muted: Arc<AtomicBool>,
    pub pre_mute_volume: Arc<RwLock<f32>>,
    pub repeat_mode: Arc<RwLock<RepeatMode>>,
    pub shuffle: Arc<AtomicBool>,
    pub queue: Arc<RwLock<QueueState>>,
    pub active_device_id: Arc<RwLock<Option<String>>>,
    pub active_device: Arc<RwLock<Option<AudioDeviceInfo>>>,
    pub active_zone_id: Arc<RwLock<Option<String>>>,
    pub last_structured_error: Arc<RwLock<Option<LuminaError>>>,
    pub ws_sequence: Arc<AtomicU64>,
    pub db_pool: Option<SqlitePool>,
    pub artwork_cache_dir: PathBuf,
    pub player: Option<AudioPlayer>,
    pub provider_manager: Arc<ProviderManager>,
    pub active_profile_id: Arc<RwLock<Option<String>>>,
    pub dsp_config: Arc<RwLock<SharedDspConfig>>,
    pub zone_manager: Arc<ZoneManager>,
    pub mb_base_url: Arc<RwLock<String>>,
    pub discogs_base_url: Arc<RwLock<String>>,
    pub discogs_token: Arc<RwLock<Option<String>>>,
    pub created_at: Instant,
    pub playback_epoch: Arc<AtomicU64>,
    pub last_caller_epoch: Arc<AtomicU64>,
    pub play_generation: Arc<AtomicU64>,
    pub loaded_generation: Arc<AtomicU64>,
    pub last_play_dispatch_ms: Arc<AtomicU64>,
    pub active_play_cancel: Arc<std::sync::RwLock<Option<CancellationToken>>>,
    pub play_cmd_tx: watch::Sender<Option<ServerPlayCmd>>,
    pub play_cmd_rx: Arc<std::sync::Mutex<Option<watch::Receiver<Option<ServerPlayCmd>>>>>,
    pub ingestion_pipeline: Option<IngestionPipeline>,
    pub watcher_manager: Arc<RwLock<Option<StorageWatcherManager>>>,
    scan_progress_relay_started: Arc<AtomicBool>,
}

impl AppState {
    pub fn new(db_pool: Option<SqlitePool>) -> Self {
        Self::with_player(db_pool, None)
    }

    pub fn with_player(db_pool: Option<SqlitePool>, player: Option<AudioPlayer>) -> Self {
        Self::with_shared_ingestion(db_pool, player, None, None)
    }

    pub fn with_shared_ingestion(
        db_pool: Option<SqlitePool>,
        player: Option<AudioPlayer>,
        shared_pipeline: Option<IngestionPipeline>,
        shared_watcher: Option<StorageWatcherManager>,
    ) -> Self {
        let (broadcast_tx, _) = broadcast::channel(128);
        let pairing_manager = Arc::new(PinPairingManager::new(60.0, 5, db_pool.clone()));

        let cred_store = Arc::new(FallbackCredentialStore::new(Arc::new(
            MemoryCredentialStore::new(),
        )));
        let provider_manager = Arc::new(ProviderManager::with_credential_store(cred_store));
        let zone_manager = Arc::new(ZoneManager::new(db_pool.clone()));
        zone_manager.sync_local_default_zone_in_memory(player.as_ref());

        let initial_device = player.as_ref().and_then(|p| {
            let devs = p.list_output_devices();
            let chosen = devs
                .iter()
                .find(|d| d.id != "virtual-exclusive-dac" && d.is_default)
                .or_else(|| devs.iter().find(|d| d.id != "virtual-exclusive-dac"))
                .or_else(|| devs.first());
            chosen.map(|d| {
                let mut info = AudioDeviceInfo::from(d);
                info.is_active = true;
                info
            })
        });
        let initial_device_id = initial_device.as_ref().map(|d| d.id.clone());

        let initial_epoch = player.as_ref().map(|p| p.playback_epoch()).unwrap_or(0);
        let initial_playback = PlaybackStatePayload {
            status: "stopped".to_string(),
            state_code: PlaybackLifecycleState::Stopped.as_i32(),
            state_name: PlaybackLifecycleState::Stopped
                .as_legacy_state_name()
                .to_string(),
            track_id: None,
            current_track_id: None,
            position_ms: 0,
            duration_ms: 0,
            timestamp_ms: now_unix_ms(),
            active_device: initial_device.clone(),
            active_zone_id: Some("zone-local".to_string()),
            track: None,
            swap_generation: 0,
            playback_epoch: initial_epoch,
            ..Default::default()
        };

        let dsp_config = if let Some(ref p) = player {
            p.get_dsp_config()
        } else {
            SharedDspConfig::default()
        };

        let real_signal_path = if let Some(ref p) = player {
            p.current_signal_path()
        } else {
            let format = AudioFormat {
                codec: AudioCodec::Flac,
                sample_rate_hz: 96_000,
                bit_depth: 24,
                channels: 2,
                is_dsd: false,
            };
            let legacy_dsp = core_audio::DspPipelineConfig {
                bypass: true,
                ..Default::default()
            };
            core_audio::build_signal_path(
                "Qobuz Hi-Res",
                &format,
                &legacy_dsp,
                None,
                OutputBackendKind::WindowsAsio,
                "FiiO K9 Pro ASIO Driver",
            )
        };

        let initial_signal_path = signal_path_to_payload(&real_signal_path);
        let (play_cmd_tx, play_cmd_rx) = watch::channel(None);
        let ingestion_pipeline = shared_pipeline.or_else(|| {
            db_pool
                .as_ref()
                .map(|pool| IngestionPipeline::with_defaults(pool.clone()))
        });

        let state = Self {
            pairing_manager,
            broadcast_tx,
            playback_state: Arc::new(RwLock::new(initial_playback)),
            signal_path: Arc::new(RwLock::new(initial_signal_path)),
            signal_path_raw: Arc::new(RwLock::new(real_signal_path)),
            volume: Arc::new(RwLock::new(1.0)),
            is_muted: Arc::new(AtomicBool::new(false)),
            pre_mute_volume: Arc::new(RwLock::new(1.0)),
            repeat_mode: Arc::new(RwLock::new(RepeatMode::Off)),
            shuffle: Arc::new(AtomicBool::new(false)),
            queue: Arc::new(RwLock::new(QueueState::default())),
            active_device_id: Arc::new(RwLock::new(initial_device_id)),
            active_device: Arc::new(RwLock::new(initial_device)),
            active_zone_id: Arc::new(RwLock::new(Some("zone-local".to_string()))),
            last_structured_error: Arc::new(RwLock::new(None)),
            ws_sequence: Arc::new(AtomicU64::new(0)),
            db_pool,
            artwork_cache_dir: std::env::temp_dir().join("lumina_artwork_cache"),
            player,
            provider_manager,
            active_profile_id: Arc::new(RwLock::new(None)),
            dsp_config: Arc::new(RwLock::new(dsp_config)),
            zone_manager,
            mb_base_url: Arc::new(RwLock::new(DEFAULT_MUSICBRAINZ_BASE_URL.to_string())),
            discogs_base_url: Arc::new(RwLock::new(DEFAULT_DISCOGS_BASE_URL.to_string())),
            discogs_token: Arc::new(RwLock::new(None)),
            created_at: Instant::now(),
            playback_epoch: Arc::new(AtomicU64::new(initial_epoch)),
            last_caller_epoch: Arc::new(AtomicU64::new(0)),
            play_generation: Arc::new(AtomicU64::new(0)),
            loaded_generation: Arc::new(AtomicU64::new(0)),
            last_play_dispatch_ms: Arc::new(AtomicU64::new(0)),
            active_play_cancel: Arc::new(std::sync::RwLock::new(None)),
            play_cmd_tx,
            play_cmd_rx: Arc::new(std::sync::Mutex::new(Some(play_cmd_rx))),
            ingestion_pipeline,
            watcher_manager: Arc::new(RwLock::new(shared_watcher)),
            scan_progress_relay_started: Arc::new(AtomicBool::new(false)),
        };
        state.ensure_scan_progress_relay();
        state
    }

    pub fn next_ws_sequence(&self) -> u64 {
        self.ws_sequence.fetch_add(1, Ordering::SeqCst) + 1
    }

    pub fn elapsed_ms_since_start(&self) -> u64 {
        (self.created_at.elapsed().as_millis() as u64).max(1)
    }

    /// Loads persisted paired client tokens, default profile, and watched roots from SQLite on server startup.
    pub async fn bootstrap_from_db(&self) {
        let _ = self.pairing_manager.load_tokens_from_db().await;
        if let Some(ref pool) = self.db_pool
            && self.active_profile_id.read().await.is_none()
        {
            if let Ok(def_prof) = core_db::ProfileRepository::get_default_profile(pool).await {
                *self.active_profile_id.write().await = Some(def_prof.id);
            } else if let Ok(created) = core_db::ProfileRepository::create_profile(
                pool,
                &core_types::Profile::default_profile(),
            )
            .await
            {
                *self.active_profile_id.write().await = Some(created.id);
            }
        }
        self.ensure_scan_progress_relay();
        let had_shared_watcher = self.watcher_manager.read().await.is_some();
        if !had_shared_watcher && let Some(watcher) = self.ensure_watcher_manager().await {
            let _ = watcher.restore_watched_roots().await;
        }
    }
}
