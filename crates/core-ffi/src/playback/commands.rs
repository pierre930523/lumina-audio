use super::payload::is_http_url;
use super::transport::{
    lumina_playback_get_position_ms, lumina_playback_pause, lumina_playback_play,
    lumina_playback_reconnect_device, lumina_playback_resume, lumina_playback_seek,
    lumina_playback_set_volume, lumina_playback_stop,
};
use crate::engine::{EngineState, get_engine};
use crate::error::{
    LUMINA_ERR_AUDIO_BACKEND, LUMINA_ERR_GENERAL, LUMINA_ERR_INVALID_UTF8,
    LUMINA_ERR_NOT_INITIALIZED, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi,
    set_last_structured_error,
};
use core_types::{
    LuminaError, LuminaErrorCode, PlaybackCommand, QueueItem, RepeatMode, TrackMetadata,
};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use uuid::Uuid;

fn play_track_metadata_internal(
    engine: &Arc<EngineState>,
    track: &TrackMetadata,
    start_position_ms: Option<u64>,
    playback_epoch: Option<u64>,
) -> c_int {
    let mut payload_obj = match serde_json::to_value(track) {
        Ok(serde_json::Value::Object(map)) => map,
        _ => serde_json::Map::new(),
    };
    payload_obj.insert("id".into(), serde_json::json!(track.track_id));
    payload_obj.insert("track_id".into(), serde_json::json!(track.track_id));
    if !track.provider_id.is_empty() {
        payload_obj.insert("provider".into(), serde_json::json!(track.provider_id));
        payload_obj.insert("provider_id".into(), serde_json::json!(track.provider_id));
    }
    if let Some(ref uri) = track.uri {
        let trimmed = uri.trim();
        if !trimmed.is_empty() {
            if is_http_url(trimmed) {
                payload_obj.insert("stream_url".into(), serde_json::json!(trimmed));
            } else {
                payload_obj.insert("file_path".into(), serde_json::json!(trimmed));
            }
        }
    }
    if let Some(ep) = playback_epoch {
        payload_obj.insert("playback_epoch".into(), serde_json::json!(ep));
    }

    let payload_str = match serde_json::to_string(&serde_json::Value::Object(payload_obj)) {
        Ok(s) => s,
        Err(e) => {
            let err = LuminaError::new(
                LuminaErrorCode::InvalidCommand,
                format!("Failed to serialize track payload: {e}"),
            );
            engine.set_structured_error(err.clone());
            set_last_structured_error(err);
            return LUMINA_ERR_GENERAL;
        }
    };

    let c_payload = match std::ffi::CString::new(payload_str) {
        Ok(c) => c,
        Err(e) => {
            let err = LuminaError::new(
                LuminaErrorCode::InvalidCommand,
                format!("Track payload contains interior NUL byte: {e}"),
            );
            engine.set_structured_error(err.clone());
            set_last_structured_error(err);
            return LUMINA_ERR_GENERAL;
        }
    };

    let rc = lumina_playback_play(c_payload.as_ptr());
    if rc == LUMINA_OK
        && let Some(pos) = start_position_ms
        && pos > 0
    {
        let _ = lumina_playback_seek(pos);
    }
    rc
}

/// Unified C-ABI command dispatcher accepting a canonical [`core_types::PlaybackCommand`] JSON payload.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_dispatch_command(cmd_json: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_dispatch_command",
        || {
            if cmd_json.is_null() {
                set_last_structured_error(LuminaError::new(
                    LuminaErrorCode::InvalidCommand,
                    "cmd_json must not be null",
                ));
                return Ok(LUMINA_ERR_NULL_POINTER);
            }

            let raw = match unsafe { CStr::from_ptr(cmd_json).to_str() } {
                Ok(s) => s,
                Err(e) => {
                    set_last_structured_error(LuminaError::new(
                        LuminaErrorCode::InvalidCommand,
                        format!("Invalid UTF-8 in cmd_json: {e}"),
                    ));
                    return Ok(LUMINA_ERR_INVALID_UTF8);
                }
            };

            let cmd: PlaybackCommand = match serde_json::from_str(raw) {
                Ok(c) => c,
                Err(e) => {
                    set_last_structured_error(LuminaError::new(
                        LuminaErrorCode::InvalidCommand,
                        format!("Invalid PlaybackCommand JSON: {e}"),
                    ));
                    return Ok(LUMINA_ERR_GENERAL);
                }
            };

            let engine = get_engine();
            if !engine.initialized.load(Ordering::SeqCst) {
                let err = LuminaError::new(
                    LuminaErrorCode::NotInitialized,
                    "Audio engine not initialized",
                );
                engine.set_structured_error(err.clone());
                set_last_structured_error(err);
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            }

            let rc = match cmd {
                PlaybackCommand::Play {
                    track,
                    start_position_ms,
                    playback_epoch,
                } => {
                    play_track_metadata_internal(&engine, &track, start_position_ms, playback_epoch)
                }
                PlaybackCommand::Pause => lumina_playback_pause(),
                PlaybackCommand::Resume => lumina_playback_resume(),
                PlaybackCommand::Stop => lumina_playback_stop(),
                PlaybackCommand::Seek { position_ms } => lumina_playback_seek(position_ms),
                PlaybackCommand::Next => {
                    let next_track = if let Ok(mut q) = engine.queue_state.write() {
                        if q.items.is_empty() {
                            None
                        } else {
                            let repeat = engine
                                .repeat_mode
                                .read()
                                .map(|g| *g)
                                .unwrap_or(q.repeat_mode);
                            let target_idx = match (q.current_index, repeat) {
                                (Some(idx), RepeatMode::One) => Some(idx.min(q.items.len() - 1)),
                                (Some(idx), RepeatMode::All) => Some((idx + 1) % q.items.len()),
                                (Some(idx), RepeatMode::Off) if idx + 1 < q.items.len() => {
                                    Some(idx + 1)
                                }
                                (Some(_), RepeatMode::Off) => None,
                                (None, _) => Some(0),
                            };
                            q.current_index = target_idx;
                            q.queue_epoch = q.queue_epoch.saturating_add(1);
                            q.timestamp_ms = EngineState::now_unix_ms();
                            target_idx.and_then(|i| q.items.get(i).map(|it| it.track.clone()))
                        }
                    } else {
                        None
                    };
                    if let Some(track) = next_track {
                        play_track_metadata_internal(&engine, &track, None, None)
                    } else {
                        lumina_playback_stop()
                    }
                }
                PlaybackCommand::Previous => {
                    let pos = lumina_playback_get_position_ms();
                    if pos > 3_000 {
                        lumina_playback_seek(0)
                    } else {
                        let prev_track = if let Ok(mut q) = engine.queue_state.write() {
                            if q.items.is_empty() {
                                None
                            } else {
                                let repeat = engine
                                    .repeat_mode
                                    .read()
                                    .map(|g| *g)
                                    .unwrap_or(q.repeat_mode);
                                let target_idx = match (q.current_index, repeat) {
                                    (Some(0), RepeatMode::All) => Some(q.items.len() - 1),
                                    (Some(0), _) => Some(0),
                                    (Some(idx), _) => Some(idx - 1),
                                    (None, _) => Some(0),
                                };
                                q.current_index = target_idx;
                                q.queue_epoch = q.queue_epoch.saturating_add(1);
                                q.timestamp_ms = EngineState::now_unix_ms();
                                target_idx.and_then(|i| q.items.get(i).map(|it| it.track.clone()))
                            }
                        } else {
                            None
                        };
                        if let Some(track) = prev_track {
                            play_track_metadata_internal(&engine, &track, None, None)
                        } else {
                            lumina_playback_seek(0)
                        }
                    }
                }
                PlaybackCommand::SetVolume { volume } => lumina_playback_set_volume(volume),
                PlaybackCommand::SetMute { muted } => {
                    engine.set_muted(muted);
                    LUMINA_OK
                }
                PlaybackCommand::SetRepeatMode { mode } => {
                    if let Ok(mut lock) = engine.repeat_mode.write() {
                        *lock = mode;
                    }
                    if let Ok(mut q) = engine.queue_state.write() {
                        q.repeat_mode = mode;
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = EngineState::now_unix_ms();
                    }
                    LUMINA_OK
                }
                PlaybackCommand::SetShuffle { enabled } => {
                    engine.shuffle.store(enabled, Ordering::SeqCst);
                    if let Ok(mut q) = engine.queue_state.write() {
                        q.shuffle = enabled;
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = EngineState::now_unix_ms();
                    }
                    LUMINA_OK
                }
                PlaybackCommand::SetOutputDevice { device_id, backend } => {
                    let dev_opt = if device_id.trim().is_empty() {
                        None
                    } else {
                        Some(device_id.trim().to_string())
                    };
                    if let Some(p) = engine.player_clone() {
                        if let Err(e) = p.select_output_device(dev_opt.as_deref(), backend) {
                            let structured = e.to_lumina_error();
                            engine.set_structured_error(structured.clone());
                            set_last_structured_error(structured);
                            return Ok(LUMINA_ERR_AUDIO_BACKEND);
                        }
                        if let Ok(mut lock) = engine.active_device_id.write() {
                            *lock = dev_opt.clone();
                        }
                        engine
                            .dsp_bypassed
                            .store(p.is_dsp_bypassed(), Ordering::SeqCst);
                        engine
                            .volume_bits
                            .store(p.volume().to_bits() as u64, Ordering::Relaxed);
                        engine.runtime.block_on(
                            engine
                                .zone_manager
                                .sync_local_zone_selected_device(dev_opt.as_deref(), Some(&p)),
                        );
                        LUMINA_OK
                    } else {
                        let err = LuminaError::new(
                            LuminaErrorCode::NotInitialized,
                            "Audio player not initialized",
                        );
                        engine.set_structured_error(err.clone());
                        set_last_structured_error(err);
                        LUMINA_ERR_NOT_INITIALIZED
                    }
                }
                PlaybackCommand::SetActiveZone { zone_id } => {
                    let trimmed = zone_id.trim().to_string();
                    if trimmed.is_empty() {
                        set_last_structured_error(LuminaError::new(
                            LuminaErrorCode::InvalidCommand,
                            "zone_id cannot be empty",
                        ));
                        return Ok(LUMINA_ERR_GENERAL);
                    }
                    let exists = engine
                        .runtime
                        .block_on(engine.zone_manager.get_zone(&trimmed))
                        .is_some();
                    if !exists {
                        let err = LuminaError::new(
                            LuminaErrorCode::DeviceNotFound,
                            format!("Zone not found: {trimmed}"),
                        );
                        engine.set_structured_error(err.clone());
                        set_last_structured_error(err);
                        return Ok(LUMINA_ERR_AUDIO_BACKEND);
                    }
                    if let Ok(mut lock) = engine.active_zone_id.write() {
                        *lock = Some(trimmed);
                    }
                    LUMINA_OK
                }
                PlaybackCommand::LoadQueue {
                    items,
                    start_index,
                    auto_play,
                } => {
                    let track_to_play = if let Ok(mut q) = engine.queue_state.write() {
                        q.items = items
                            .into_iter()
                            .map(|track| QueueItem {
                                item_id: Uuid::new_v4().to_string(),
                                track,
                                is_user_queued: false,
                            })
                            .collect();
                        q.current_index = if q.items.is_empty() {
                            None
                        } else {
                            Some(start_index.min(q.items.len() - 1))
                        };
                        q.repeat_mode = engine
                            .repeat_mode
                            .read()
                            .map(|g| *g)
                            .unwrap_or(RepeatMode::Off);
                        q.shuffle = engine.shuffle.load(Ordering::SeqCst);
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = EngineState::now_unix_ms();
                        if auto_play {
                            q.current_index
                                .and_then(|i| q.items.get(i).map(|it| it.track.clone()))
                        } else {
                            None
                        }
                    } else {
                        None
                    };
                    if let Some(track) = track_to_play {
                        play_track_metadata_internal(&engine, &track, None, None)
                    } else {
                        LUMINA_OK
                    }
                }
                PlaybackCommand::Enqueue { items, play_next } => {
                    if let Ok(mut q) = engine.queue_state.write() {
                        let new_items: Vec<QueueItem> = items
                            .into_iter()
                            .map(|track| QueueItem {
                                item_id: Uuid::new_v4().to_string(),
                                track,
                                is_user_queued: true,
                            })
                            .collect();
                        if play_next {
                            let insert_at = q
                                .current_index
                                .map(|idx| (idx + 1).min(q.items.len()))
                                .unwrap_or(0);
                            q.items.splice(insert_at..insert_at, new_items);
                        } else {
                            q.items.extend(new_items);
                        }
                        if q.current_index.is_none() && !q.items.is_empty() {
                            q.current_index = Some(0);
                        }
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = EngineState::now_unix_ms();
                    }
                    LUMINA_OK
                }
                PlaybackCommand::RemoveQueueItem { index } => {
                    if let Ok(mut q) = engine.queue_state.write() {
                        if index >= q.items.len() {
                            set_last_structured_error(LuminaError::new(
                                LuminaErrorCode::InvalidCommand,
                                format!(
                                    "Queue index {index} out of bounds (len={})",
                                    q.items.len()
                                ),
                            ));
                            return Ok(LUMINA_ERR_GENERAL);
                        }
                        q.items.remove(index);
                        q.current_index = match q.current_index {
                            None => None,
                            Some(_) if q.items.is_empty() => None,
                            Some(cur) if index < cur => Some(cur - 1),
                            Some(cur) if cur >= q.items.len() => Some(q.items.len() - 1),
                            Some(cur) => Some(cur),
                        };
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = EngineState::now_unix_ms();
                    }
                    LUMINA_OK
                }
                PlaybackCommand::ReorderQueue {
                    from_index,
                    to_index,
                } => {
                    if let Ok(mut q) = engine.queue_state.write() {
                        if from_index >= q.items.len() || to_index >= q.items.len() {
                            set_last_structured_error(LuminaError::new(
                                LuminaErrorCode::InvalidCommand,
                                format!(
                                    "Reorder indices ({from_index} -> {to_index}) out of bounds (len={})",
                                    q.items.len()
                                ),
                            ));
                            return Ok(LUMINA_ERR_GENERAL);
                        }
                        if from_index != to_index {
                            let item = q.items.remove(from_index);
                            q.items.insert(to_index, item);
                            if let Some(cur) = q.current_index {
                                q.current_index = Some(if cur == from_index {
                                    to_index
                                } else if from_index < cur && cur <= to_index {
                                    cur - 1
                                } else if to_index <= cur && cur < from_index {
                                    cur + 1
                                } else {
                                    cur
                                });
                            }
                            q.queue_epoch = q.queue_epoch.saturating_add(1);
                            q.timestamp_ms = EngineState::now_unix_ms();
                        }
                    }
                    LUMINA_OK
                }
                PlaybackCommand::ClearQueue => {
                    if let Ok(mut q) = engine.queue_state.write() {
                        q.items.clear();
                        q.current_index = None;
                        q.queue_epoch = q.queue_epoch.saturating_add(1);
                        q.timestamp_ms = EngineState::now_unix_ms();
                    }
                    LUMINA_OK
                }
                PlaybackCommand::ClearUpcomingQueue => {
                    if let Ok(mut q) = engine.queue_state.write() {
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
                        q.timestamp_ms = EngineState::now_unix_ms();
                    }
                    engine.cancel_active_standby_token();
                    let _ = engine.standby_cmd_tx.send_replace(None);
                    if let Ok(guard) = engine.player.read()
                        && let Some(ref player) = *guard
                    {
                        player.cancel_standby();
                    }
                    LUMINA_OK
                }
                PlaybackCommand::ReconnectDevice => {
                    engine.clear_structured_error();
                    lumina_playback_reconnect_device()
                }
            };

            if rc == LUMINA_OK {
                engine.next_sequence();
            }
            Ok(rc)
        },
    )
}
