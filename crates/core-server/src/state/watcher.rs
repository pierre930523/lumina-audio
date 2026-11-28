use super::{AppState, now_unix_ms, signal_path_to_payload};
use crate::ws::messages::{PlaybackStatePayload, WsMessage};
use core_types::{DeckId, DeckTrackMetadata, PlaybackLifecycleState, TrackMetadata};
use std::sync::Arc;
use std::time::Duration;
use tokio::task::JoinHandle;

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

            let lifecycle = PlaybackLifecycleState::from_i32(player.state_code());
            let pos_ms = if gen_changed { 0 } else { player.position_ms() };

            {
                let mut pb = state.playback_state.write().await;
                pb.status = lifecycle.as_snake_str().to_string();
                pb.state_code = lifecycle.as_i32();
                pb.state_name = lifecycle.as_legacy_state_name().to_string();
                if track_id.is_some() || gen_changed {
                    pb.track_id = track_id.clone();
                    pb.current_track_id = track_id.clone();
                }
                pb.position_ms = pos_ms;
                pb.duration_ms = duration_ms;
                pb.timestamp_ms = now_unix_ms();
                pb.track = track_meta.as_ref().map(TrackMetadata::from);
                pb.swap_generation = current_gen;
                pb.playback_epoch = eff_epoch;
            }

            let mut full_pb = state.build_playback_state().await;
            if gen_changed {
                full_pb.position_ms = 0;
            }
            full_pb.swap_generation = current_gen;
            full_pb.playback_epoch = eff_epoch;
            let pb_payload = PlaybackStatePayload::from(full_pb);

            let sp_raw = player.current_signal_path();
            let sp_payload = signal_path_to_payload(&sp_raw);
            *state.signal_path_raw.write().await = sp_raw;
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
