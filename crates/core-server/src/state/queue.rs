use super::{AppState, now_unix_ms};
use crate::error::ServerError;
use crate::ws::messages::{PlaybackStatePayload, WsMessage};
use core_types::{
    DeckTrackMetadata, LuminaError, LuminaErrorCode, PlaybackCommand, QueueItem, RepeatMode,
    TrackMetadata,
};
use std::sync::Arc;
use std::sync::atomic::Ordering;

fn build_play_request_for_track(
    track: &TrackMetadata,
    playback_epoch: Option<u64>,
) -> crate::routes::playback::PlaybackCommandRequest {
    let mut req = crate::routes::playback::PlaybackCommandRequest {
        track_id: if track.track_id.is_empty() {
            None
        } else {
            Some(track.track_id.clone())
        },
        playback_epoch,
        track: Some(DeckTrackMetadata::from(track)),
        ..Default::default()
    };
    if let Some(ref uri) = track.uri {
        if uri.starts_with("http://") || uri.starts_with("https://") {
            req.stream_url = Some(uri.clone());
        } else {
            req.file_path = Some(uri.clone());
        }
    }
    if !track.provider_id.is_empty() {
        req.source = Some(track.provider_id.clone());
    }
    req
}

impl AppState {
    pub async fn dispatch_playback_command(
        self: &Arc<Self>,
        cmd: PlaybackCommand,
    ) -> Result<(), ServerError> {
        match cmd {
            PlaybackCommand::Play {
                track,
                start_position_ms,
                playback_epoch,
            } => {
                let req = build_play_request_for_track(&track, playback_epoch);
                *self.last_structured_error.write().await = None;
                crate::routes::playback::execute_play_request(
                    self,
                    req,
                    Some(track),
                    start_position_ms,
                )
                .await?;
                Ok(())
            }
            PlaybackCommand::Pause => {
                let _ = crate::routes::playback::execute_pause(self).await;
                Ok(())
            }
            PlaybackCommand::Resume => {
                let _ = crate::routes::playback::execute_resume(self).await;
                Ok(())
            }
            PlaybackCommand::Stop => {
                let _ = crate::routes::playback::execute_stop(self).await;
                Ok(())
            }
            PlaybackCommand::Seek { position_ms } => {
                let _ = crate::routes::playback::execute_seek(self, position_ms).await;
                Ok(())
            }
            PlaybackCommand::Next => {
                let repeat = *self.repeat_mode.read().await;
                let (next_track, queue_snapshot, was_empty) = {
                    let mut q = self.queue.write().await;
                    if q.items.is_empty() {
                        (None, None, true)
                    } else {
                        let len = q.items.len();
                        let next_idx = match q.current_index {
                            None => Some(0),
                            Some(cur) => match repeat {
                                RepeatMode::One => Some(cur.min(len - 1)),
                                RepeatMode::All => Some((cur + 1) % len),
                                RepeatMode::Off => {
                                    if cur + 1 < len {
                                        Some(cur + 1)
                                    } else {
                                        None
                                    }
                                }
                            },
                        };
                        q.current_index = next_idx;
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = now_unix_ms();
                        let trk = next_idx
                            .and_then(|i| q.items.get(i))
                            .map(|it| it.track.clone());
                        (trk, Some(q.clone()), false)
                    }
                };

                if was_empty {
                    let pb = self.build_playback_state().await;
                    let _ = self.broadcast_tx.send(WsMessage::Event {
                        event: "track_next".to_string(),
                        payload: serde_json::to_value(PlaybackStatePayload::from(pb))
                            .unwrap_or_default(),
                    });
                    return Ok(());
                }

                if let Some(q_snap) = queue_snapshot {
                    let _ = self
                        .broadcast_tx
                        .send(WsMessage::QueueStateChanged { payload: q_snap });
                }

                if let Some(track) = next_track {
                    let req = build_play_request_for_track(&track, None);
                    crate::routes::playback::execute_play_request(self, req, Some(track), None)
                        .await?;
                } else {
                    let _ = crate::routes::playback::execute_stop(self).await;
                }
                Ok(())
            }
            PlaybackCommand::Previous => {
                let current_pos = if let Some(ref p) = self.player {
                    p.position_ms()
                } else {
                    self.playback_state.read().await.position_ms
                };
                let is_active = matches!(
                    self.playback_state.read().await.status.as_str(),
                    "playing" | "paused"
                );
                if is_active && current_pos > 3_000 {
                    let _ = crate::routes::playback::execute_seek(self, 0).await;
                    return Ok(());
                }

                let repeat = *self.repeat_mode.read().await;
                let (prev_track, queue_snapshot, was_empty) = {
                    let mut q = self.queue.write().await;
                    if q.items.is_empty() {
                        (None, None, true)
                    } else {
                        let len = q.items.len();
                        let prev_idx = match q.current_index {
                            None => 0,
                            Some(cur) => match repeat {
                                RepeatMode::One => cur.min(len - 1),
                                RepeatMode::All => {
                                    if cur == 0 {
                                        len - 1
                                    } else {
                                        cur - 1
                                    }
                                }
                                RepeatMode::Off => cur.saturating_sub(1),
                            },
                        };
                        q.current_index = Some(prev_idx);
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = now_unix_ms();
                        let trk = q.items.get(prev_idx).map(|it| it.track.clone());
                        (trk, Some(q.clone()), false)
                    }
                };

                if was_empty {
                    let _ = crate::routes::playback::execute_seek(self, 0).await;
                    return Ok(());
                }

                if let Some(q_snap) = queue_snapshot {
                    let _ = self
                        .broadcast_tx
                        .send(WsMessage::QueueStateChanged { payload: q_snap });
                }

                if let Some(track) = prev_track {
                    let req = build_play_request_for_track(&track, None);
                    crate::routes::playback::execute_play_request(self, req, Some(track), None)
                        .await?;
                }
                Ok(())
            }
            PlaybackCommand::SetVolume { volume } => {
                let _ = crate::routes::playback::execute_volume(self, volume).await;
                Ok(())
            }
            PlaybackCommand::SetMute { muted } => {
                self.is_muted.store(muted, Ordering::SeqCst);
                if muted {
                    let cur = *self.volume.read().await;
                    if cur > 0.0 {
                        *self.pre_mute_volume.write().await = cur;
                    }
                    if let Some(ref player) = self.player {
                        player.set_volume(0.0);
                    }
                } else {
                    let restore = {
                        let cur = *self.volume.read().await;
                        if cur > 0.0 {
                            cur
                        } else {
                            let prev = *self.pre_mute_volume.read().await;
                            let v = if prev > 0.0 { prev } else { 1.0 };
                            *self.volume.write().await = v;
                            v
                        }
                    };
                    if let Some(ref player) = self.player {
                        player.set_volume(restore);
                    }
                }
                self.broadcast_playback_state().await;
                Ok(())
            }
            PlaybackCommand::SetRepeatMode { mode } => {
                *self.repeat_mode.write().await = mode;
                let q_snap = {
                    let mut q = self.queue.write().await;
                    q.repeat_mode = mode;
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                self.broadcast_playback_state().await;
                Ok(())
            }
            PlaybackCommand::SetShuffle { enabled } => {
                self.shuffle.store(enabled, Ordering::SeqCst);
                let q_snap = {
                    let mut q = self.queue.write().await;
                    q.shuffle = enabled;
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                self.broadcast_playback_state().await;
                Ok(())
            }
            PlaybackCommand::SetOutputDevice { device_id, backend } => {
                let _ = crate::routes::playback::execute_select_audio_device(
                    self,
                    Some(device_id),
                    backend,
                )
                .await?;
                Ok(())
            }
            PlaybackCommand::SetActiveZone { zone_id } => {
                let zones = self.zone_manager.list_zones().await;
                if !zones.iter().any(|z| z.id == zone_id) {
                    return Err(ServerError::Lumina(
                        LuminaError::new(
                            LuminaErrorCode::DeviceNotFound,
                            format!("Zone not found: {zone_id}"),
                        )
                        .with_http_status(404),
                    ));
                }
                for mut z in zones {
                    let should_be_active = z.id == zone_id;
                    if z.is_active != should_be_active {
                        z.is_active = should_be_active;
                        self.zone_manager.upsert_zone(z).await;
                    }
                }
                *self.active_zone_id.write().await = Some(zone_id);
                let updated_zones = self.zone_manager.list_zones().await;
                let _ = self.broadcast_tx.send(WsMessage::ZonesChanged {
                    payload: updated_zones,
                });
                self.broadcast_playback_state().await;
                Ok(())
            }
            PlaybackCommand::LoadQueue {
                items,
                start_index,
                auto_play,
            } => {
                let repeat = *self.repeat_mode.read().await;
                let shuffle = self.shuffle.load(Ordering::SeqCst);
                let (selected_track, q_snap) = {
                    let mut q = self.queue.write().await;
                    q.items = items
                        .into_iter()
                        .map(|track| QueueItem {
                            item_id: uuid::Uuid::new_v4().to_string(),
                            track,
                            is_user_queued: false,
                        })
                        .collect();
                    q.current_index = if q.items.is_empty() {
                        None
                    } else {
                        Some(start_index.min(q.items.len() - 1))
                    };
                    q.repeat_mode = repeat;
                    q.shuffle = shuffle;
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    let trk = q
                        .current_index
                        .and_then(|i| q.items.get(i))
                        .map(|it| it.track.clone());
                    (trk, q.clone())
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });

                if auto_play && let Some(track) = selected_track {
                    let req = build_play_request_for_track(&track, None);
                    crate::routes::playback::execute_play_request(self, req, Some(track), None)
                        .await?;
                }
                Ok(())
            }
            PlaybackCommand::Enqueue { items, play_next } => {
                let new_items: Vec<QueueItem> = items
                    .into_iter()
                    .map(|track| QueueItem {
                        item_id: uuid::Uuid::new_v4().to_string(),
                        track,
                        is_user_queued: true,
                    })
                    .collect();
                let q_snap = {
                    let mut q = self.queue.write().await;
                    if play_next {
                        let insert_at = q
                            .current_index
                            .map(|idx| (idx + 1).min(q.items.len()))
                            .unwrap_or(0);
                        for (offset, item) in new_items.into_iter().enumerate() {
                            q.items.insert(insert_at + offset, item);
                        }
                    } else {
                        q.items.extend(new_items);
                    }
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                Ok(())
            }
            PlaybackCommand::RemoveQueueItem { index } => {
                let q_snap = {
                    let mut q = self.queue.write().await;
                    if index >= q.items.len() {
                        return Err(ServerError::Lumina(
                            LuminaError::new(
                                LuminaErrorCode::InvalidCommand,
                                format!(
                                    "Queue index {index} out of bounds (len={})",
                                    q.items.len()
                                ),
                            )
                            .with_http_status(400),
                        ));
                    }
                    q.items.remove(index);
                    if q.items.is_empty() {
                        q.current_index = None;
                    } else if let Some(cur) = q.current_index {
                        if index < cur {
                            q.current_index = Some(cur - 1);
                        } else if index == cur {
                            q.current_index = Some(cur.min(q.items.len() - 1));
                        }
                    }
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                Ok(())
            }
            PlaybackCommand::ReorderQueue {
                from_index,
                to_index,
            } => {
                let q_snap = {
                    let mut q = self.queue.write().await;
                    if from_index >= q.items.len() || to_index >= q.items.len() {
                        return Err(ServerError::Lumina(
                            LuminaError::new(
                                LuminaErrorCode::InvalidCommand,
                                format!(
                                    "Reorder indices ({from_index} -> {to_index}) out of bounds (len={})",
                                    q.items.len()
                                ),
                            )
                            .with_http_status(400),
                        ));
                    }
                    if from_index != to_index {
                        let item = q.items.remove(from_index);
                        q.items.insert(to_index, item);
                        if let Some(cur) = q.current_index {
                            if cur == from_index {
                                q.current_index = Some(to_index);
                            } else if from_index < cur && cur <= to_index {
                                q.current_index = Some(cur - 1);
                            } else if to_index <= cur && cur < from_index {
                                q.current_index = Some(cur + 1);
                            }
                        }
                    }
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                Ok(())
            }
            PlaybackCommand::ClearQueue => {
                let q_snap = {
                    let mut q = self.queue.write().await;
                    q.items.clear();
                    q.current_index = None;
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                Ok(())
            }
            PlaybackCommand::ClearUpcomingQueue => {
                let q_snap = {
                    let mut q = self.queue.write().await;
                    match q.current_index {
                        Some(cur) if cur < q.items.len() => {
                            q.items.truncate(cur + 1);
                        }
                        _ => {
                            q.items.clear();
                            q.current_index = None;
                        }
                    }
                    q.queue_epoch = q.queue_epoch.saturating_add(1);
                    q.timestamp_ms = now_unix_ms();
                    q.clone()
                };
                if let Some(ref player) = self.player {
                    player.cancel_standby();
                }
                let _ = self
                    .broadcast_tx
                    .send(WsMessage::QueueStateChanged { payload: q_snap });
                Ok(())
            }
            PlaybackCommand::ReconnectDevice => {
                let _ = crate::routes::playback::execute_reconnect(self).await;
                Ok(())
            }
        }
    }
}
