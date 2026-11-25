use crate::pairing::PinPairingManager;
use crate::ws::messages::{PlaybackStatePayload, SignalPathNodeDto, SignalPathPayload, WsMessage};
use crate::zones::ZoneManager;
use core_audio::AudioPlayer;
use core_db::{FallbackCredentialStore, MemoryCredentialStore, SqlitePool};
use core_providers::{
    IngestionPipeline, ProviderManager, StorageWatcherManager, DEFAULT_DISCOGS_BASE_URL,
    DEFAULT_MUSICBRAINZ_BASE_URL,
};
use core_types::{
    AudioCodec, AudioFormat, DeckId, DeckTrackMetadata, DspPipelineConfig as SharedDspConfig,
    OutputBackendKind, SignalPath, StreamSourceSpec,
};
use sqlx::SqlitePool as SqlxPool;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, watch, RwLock};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct ServerPlayCmd {
    pub track_id: Option<String>,
    pub file_path: Option<String>,
    pub stream_url: Option<String>,
    pub headers: Option<HashMap<String, String>>,
    pub source: Option<String>,
    pub hint_extension: Option<String>,
    pub source_spec: Option<StreamSourceSpec>,
    pub track: Option<DeckTrackMetadata>,
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

        let initial_epoch = player.as_ref().map(|p| p.playback_epoch()).unwrap_or(0);
        let initial_playback = PlaybackStatePayload {
            status: "stopped".to_string(),
            track_id: None,
            position_ms: 0,
            duration_ms: 0,
            track: None,
            swap_generation: 0,
            playback_epoch: initial_epoch,
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
        let ingestion_pipeline = db_pool
            .as_ref()
            .map(|pool| IngestionPipeline::with_defaults(pool.clone()));

        let state = Self {
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
            watcher_manager: Arc::new(RwLock::new(None)),
            scan_progress_relay_started: Arc::new(AtomicBool::new(false)),
        };
        state.ensure_scan_progress_relay();
        state
    }

    /// Spawns (once) a background task forwarding `IngestionPipeline` scan progress events
    /// to WebSocket clients as `WsMessage::Event { event: "library.scan_progress", .. }`.
    pub fn ensure_scan_progress_relay(&self) {
        let Some(ref pipeline) = self.ingestion_pipeline else {
            return;
        };
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        if self
            .scan_progress_relay_started
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }
        let mut rx = pipeline.subscribe_progress();
        let tx = self.broadcast_tx.clone();
        handle.spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        if let Ok(payload) = serde_json::to_value(&ev) {
                            let _ = tx.send(WsMessage::Event {
                                event: "library.scan_progress".to_string(),
                                payload,
                            });
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    /// Lazily initializes and returns the `StorageWatcherManager` bound to `ingestion_pipeline`.
    pub async fn ensure_watcher_manager(&self) -> Option<StorageWatcherManager> {
        self.ensure_scan_progress_relay();
        if let Some(existing) = self.watcher_manager.read().await.clone() {
            return Some(existing);
        }
        let pipeline = self.ingestion_pipeline.as_ref()?.clone();
        let mut guard = self.watcher_manager.write().await;
        if let Some(existing) = guard.clone() {
            return Some(existing);
        }
        let watcher = StorageWatcherManager::with_default_debounce(pipeline);
        *guard = Some(watcher.clone());
        Some(watcher)
    }

    pub fn elapsed_ms_since_start(&self) -> u64 {
        (self.created_at.elapsed().as_millis() as u64).max(1)
    }

    pub fn current_playback_epoch(&self) -> u64 {
        let local = self.playback_epoch.load(Ordering::SeqCst);
        let player_ep = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        local.max(player_ep)
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

    pub fn advance_playback_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let player_ep = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        loop {
            let floor = cur.max(player_ep);
            let next = match caller_epoch {
                Some(ep) if ep > floor => ep,
                _ => floor.saturating_add(1).max(1),
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                next,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return next,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn is_loading_pending(&self) -> bool {
        self.play_generation.load(Ordering::SeqCst) > self.loaded_generation.load(Ordering::SeqCst)
    }

    pub fn sync_playback_epoch_from_player(&self, min_epoch: u64) -> u64 {
        let player_ep = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        let eff = min_epoch.max(player_ep);
        let prev = self.playback_epoch.fetch_max(eff, Ordering::SeqCst);
        prev.max(eff)
    }

    pub fn advance_after_epochless_skip(&self) -> u64 {
        let player_pb = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        loop {
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
                Ok(_) => return candidate,
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
        if let Some(watcher) = self.ensure_watcher_manager().await {
            let _ = watcher.restore_watched_roots().await;
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

/// Spawns a background watcher polling `player.swap_generation()` and `player.playback_epoch()`
/// every 50ms when `state.player` is present. On `swap_generation` advance, refreshes
/// `state.playback_state` and `state.signal_path` and broadcasts `track_changed`, `queue_updated`,
/// `PlaybackStateChanged`, and `SignalPathUpdated`. On `playback_epoch`-only advance, refreshes
/// state and broadcasts `PlaybackStateChanged` + `SignalPathUpdated`.
pub fn spawn_playback_transition_watcher(state: Arc<AppState>) -> Option<JoinHandle<()>> {
    let player = state.player.clone()?;
    Some(tokio::spawn(async move {
        let mut last_gen = player.swap_generation();
        let mut last_epoch = player.playback_epoch();
        let mut interval = tokio::time::interval(Duration::from_millis(50));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            interval.tick().await;
            let mut current_gen = player.swap_generation();
            let mut current_epoch = player.playback_epoch();
            let gen_changed = current_gen > last_gen;
            let epoch_changed = current_epoch > last_epoch;
            if !gen_changed && !epoch_changed {
                continue;
            }
            if !gen_changed && state.is_loading_pending() {
                last_epoch = current_epoch;
                continue;
            }

            if gen_changed {
                // Wait briefly for relay_loop to commit active_meta / duration_ms after an RT flip.
                for _ in 0..10 {
                    if !player.has_pending_transition_commit() {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(2)).await;
                }
                current_gen = player.swap_generation();
                current_epoch = player.playback_epoch();
            }
            last_gen = current_gen;
            last_epoch = current_epoch;
            let eff_epoch = state.sync_playback_epoch_from_player(current_epoch);

            let dd = player.dual_deck_status();
            let player_dur_ms = player.duration_ms();
            let track_meta: Option<DeckTrackMetadata> = dd.active_track.clone().map(|mut t| {
                if player_dur_ms > 0 {
                    t.duration_ms = player_dur_ms;
                }
                t
            });
            let duration_ms = if player_dur_ms > 0 {
                player_dur_ms
            } else {
                track_meta.as_ref().map(|t| t.duration_ms).unwrap_or(0)
            };

            let active_key = match dd.active_deck {
                DeckId::DeckA => dd.deck_a_key.as_ref(),
                DeckId::DeckB => dd.deck_b_key.as_ref(),
            };
            let track_id = track_meta
                .as_ref()
                .map(|t| t.track_id.clone())
                .filter(|s| !s.is_empty())
                .or_else(|| {
                    active_key
                        .map(|k| k.track_id.clone())
                        .filter(|s| !s.is_empty())
                });
            let provider_id = track_meta
                .as_ref()
                .map(|t| t.provider_id.clone())
                .filter(|s| !s.is_empty())
                .or_else(|| active_key.map(|k| k.provider_id.clone()))
                .unwrap_or_default();
            let title = track_meta
                .as_ref()
                .map(|t| t.title.clone())
                .filter(|s| !s.is_empty())
                .or_else(|| player.active_meta().map(|m| m.source_label))
                .unwrap_or_default();
            let artist = track_meta
                .as_ref()
                .map(|t| t.artist.clone())
                .unwrap_or_default();
            let album = track_meta
                .as_ref()
                .map(|t| t.album.clone())
                .unwrap_or_default();
            let cover_url = track_meta.as_ref().and_then(|t| t.cover_url.clone());

            let status = match player.state_code() {
                2 => "playing",
                3 => "paused",
                5 => "loading",
                8 => "ended",
                4 => "error",
                _ => "stopped",
            }
            .to_string();
            let pos_ms = if gen_changed { 0 } else { player.position_ms() };

            let pb_payload = {
                let mut pb = state.playback_state.write().await;
                pb.status = status;
                if track_id.is_some() || gen_changed {
                    pb.track_id = track_id.clone();
                }
                pb.position_ms = pos_ms;
                pb.duration_ms = duration_ms;
                pb.track = track_meta.clone();
                pb.swap_generation = current_gen;
                pb.playback_epoch = eff_epoch;
                pb.clone()
            };

            let sp_payload = signal_path_to_payload(&player.current_signal_path());
            *state.signal_path.write().await = sp_payload.clone();

            if gen_changed {
                let event_payload = serde_json::json!({
                    "swap_generation": current_gen,
                    "playback_epoch": eff_epoch,
                    "epoch": eff_epoch,
                    "position_ms": 0,
                    "duration_ms": duration_ms,
                    "track": track_meta,
                    "track_id": track_id,
                    "provider_id": provider_id,
                    "title": title,
                    "artist": artist,
                    "album": album,
                    "cover_url": cover_url,
                });
                let _ = state.broadcast_tx.send(WsMessage::Event {
                    event: "track_changed".to_string(),
                    payload: event_payload.clone(),
                });
                let _ = state.broadcast_tx.send(WsMessage::Event {
                    event: "queue_updated".to_string(),
                    payload: event_payload,
                });
            }
            let _ = state.broadcast_tx.send(WsMessage::PlaybackStateChanged {
                payload: pb_payload,
            });
            let _ = state.broadcast_tx.send(WsMessage::SignalPathUpdated {
                payload: sp_payload,
            });
        }
    }))
}
