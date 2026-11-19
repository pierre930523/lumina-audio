use crate::pairing::PinPairingManager;
use crate::ws::messages::{PlaybackStatePayload, SignalPathNodeDto, SignalPathPayload, WsMessage};
use crate::zones::ZoneManager;
use core_audio::AudioPlayer;
use core_db::{FallbackCredentialStore, MemoryCredentialStore, SqlitePool};
use core_providers::{
    ProviderManager, DEFAULT_DISCOGS_BASE_URL, DEFAULT_MUSICBRAINZ_BASE_URL,
};
use core_types::{
    AudioCodec, AudioFormat, DspPipelineConfig as SharedDspConfig, OutputBackendKind, SignalPath,
};
use sqlx::SqlitePool as SqlxPool;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};

#[derive(Clone)]
pub struct AppState {
    pub pairing_manager: Arc<PinPairingManager>,
    pub broadcast_tx: broadcast::Sender<WsMessage>,
    pub playback_state: Arc<RwLock<PlaybackStatePayload>>,
    pub signal_path: Arc<RwLock<SignalPathPayload>>,
    pub volume: Arc<RwLock<f32>>,
    pub db_pool: Option<SqlitePool>,
    pub player: Option<AudioPlayer>,
    pub provider_manager: Arc<ProviderManager>,
    pub active_profile_id: Arc<RwLock<Option<String>>>,
    pub dsp_config: Arc<RwLock<SharedDspConfig>>,
    pub zone_manager: Arc<ZoneManager>,
    pub mb_base_url: Arc<RwLock<String>>,
    pub discogs_base_url: Arc<RwLock<String>>,
    pub discogs_token: Arc<RwLock<Option<String>>>,
}

impl AppState {
    pub fn new(db_pool: Option<SqlxPool>) -> Self {
        Self::with_player(db_pool, None)
    }

    pub fn with_player(db_pool: Option<SqlxPool>, player: Option<AudioPlayer>) -> Self {
        let (broadcast_tx, _) = broadcast::channel(128);
        let pairing_manager = Arc::new(PinPairingManager::new(60.0, 5, db_pool.clone()));

        let cred_store = Arc::new(FallbackCredentialStore::new(Arc::new(
            MemoryCredentialStore::new(),
        )));
        let provider_manager = Arc::new(ProviderManager::with_credential_store(cred_store));
        let zone_manager = Arc::new(ZoneManager::new(db_pool.clone()));
        zone_manager.sync_local_default_zone_in_memory(player.as_ref());

        let initial_playback = PlaybackStatePayload {
            status: "stopped".to_string(),
            track_id: None,
            position_ms: 0,
            duration_ms: 0,
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

        Self {
            pairing_manager,
            broadcast_tx,
            playback_state: Arc::new(RwLock::new(initial_playback)),
            signal_path: Arc::new(RwLock::new(initial_signal_path)),
            volume: Arc::new(RwLock::new(1.0)),
            db_pool,
            player,
            provider_manager,
            active_profile_id: Arc::new(RwLock::new(None)),
            dsp_config: Arc::new(RwLock::new(dsp_config)),
            zone_manager,
            mb_base_url: Arc::new(RwLock::new(DEFAULT_MUSICBRAINZ_BASE_URL.to_string())),
            discogs_base_url: Arc::new(RwLock::new(DEFAULT_DISCOGS_BASE_URL.to_string())),
            discogs_token: Arc::new(RwLock::new(None)),
        }
    }

    /// Loads persisted paired client tokens and default profile from SQLite on server startup.
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
    }
}

pub fn signal_path_to_payload(path: &SignalPath) -> SignalPathPayload {
    SignalPathPayload {
        quality: path.overall.as_str().to_string(),
        nodes: path
            .nodes
            .iter()
            .map(|n| SignalPathNodeDto {
                stage: n.stage.clone(),
                detail: n.detail.clone(),
                quality: n.quality.as_str().to_string(),
            })
            .collect(),
    }
}
