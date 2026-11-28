use super::payload::{parse_deck_track_metadata, parse_payload_hints};
use super::resolver::{ResolvedPlaybackCandidate, resolve_candidate_sync};
use crate::engine::get_engine;
use crate::error::{
    LUMINA_ERR_AUDIO_BACKEND, LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_OK,
    catch_unwind_ffi, set_last_error, set_last_structured_error, take_last_error,
};
use core_audio::{CoreAudioError, DecoderError, StreamSource};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::Ordering;
use tokio_util::sync::CancellationToken;

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_play(track_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_play", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            set_last_error("Audio engine not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if track_json.is_null() {
            engine.clear_pending_commands();
            engine.cancel_active_play_token();
            engine.cancel_active_standby_token();
            engine.async_generation.fetch_add(1, Ordering::SeqCst);
            engine.play_request_id.store(0, Ordering::SeqCst);
            engine.loaded_request_id.store(0, Ordering::SeqCst);
            if let Some(player) = engine.player_clone() {
                let state = player.state_code();
                if state == 3 {
                    player.resume();
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 8 {
                    player.seek_ms(0);
                    player.resume();
                    engine.position_ms.store(0, Ordering::Relaxed);
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 2 {
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 1 && engine.has_real_stream.load(Ordering::SeqCst) {
                    player.seek_ms(0);
                    player.resume();
                    engine.position_ms.store(0, Ordering::Relaxed);
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                let bumped = engine.advance_playback_epoch(None);
                let stream = StreamSource::synth("trk-001", "Time", 245_000);
                if let Err(e) = player.play_stream(stream, "Lumina Demo Synth") {
                    engine.has_real_stream.store(false, Ordering::SeqCst);
                    engine.playback_state.store(4, Ordering::SeqCst);
                    set_last_error(format!("Failed to play demo stream: {e}"));
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
                let _ = engine.sync_playback_epoch_from_player(&player, bumped);
                engine.has_real_stream.store(true, Ordering::SeqCst);
                engine
                    .duration_ms
                    .store(player.duration_ms(), Ordering::Relaxed);
                engine.position_ms.store(0, Ordering::Relaxed);
                engine.playback_state.store(2, Ordering::SeqCst);
                return Ok(LUMINA_OK);
            }
            set_last_error("Audio player not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        let c_str = unsafe { CStr::from_ptr(track_json) };
        let s = match c_str.to_str() {
            Ok(str_val) => str_val.trim(),
            Err(e) => {
                set_last_error(format!("Invalid UTF-8 in playback payload: {e}"));
                return Ok(LUMINA_ERR_GENERAL);
            }
        };

        let hints = match parse_payload_hints(s) {
            Ok(h) => h,
            Err(msg) => {
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
        };
        if !engine.accept_caller_epoch(hints.caller_epoch) {
            return Ok(LUMINA_OK);
        }
        let _ = crate::l2_cache::ensure_default_l2_cache_manager(&engine);

        let cancel_token = CancellationToken::new();
        engine.clear_pending_commands();
        engine.swap_play_cancel_token(cancel_token.clone());
        engine.cancel_active_standby_token();
        engine.async_generation.fetch_add(1, Ordering::SeqCst);
        engine.play_request_id.store(0, Ordering::SeqCst);
        engine.loaded_request_id.store(0, Ordering::SeqCst);
        engine.clear_structured_error();
        let _ = take_last_error();
        if let Some(player) = engine.player_clone() {
            let _ = player.take_last_error();
        }
        if let Ok(mut lock) = engine.active_track_json.write() {
            *lock = Some(s.to_string());
        }

        let candidate = match resolve_candidate_sync(&engine, s) {
            Ok(c) => c,
            Err(msg) => {
                engine.has_real_stream.store(false, Ordering::SeqCst);
                engine.playback_state.store(4, Ordering::SeqCst);
                if let Ok(mut err_lock) = engine.async_last_error.write() {
                    *err_lock = Some(msg.clone());
                }
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
        };

        if let Some(player) = engine.player_clone() {
            let task_epoch = engine.advance_playback_epoch(hints.caller_epoch);
            let label = match &candidate {
                ResolvedPlaybackCandidate::SourceSpec { source_label, .. }
                | ResolvedPlaybackCandidate::Legacy { source_label, .. } => source_label.clone(),
            };
            let play_res = match candidate {
                ResolvedPlaybackCandidate::SourceSpec { spec, source_label } => {
                    let track_meta = parse_deck_track_metadata(s, Some(&spec));
                    player.play_source_spec_with_metadata(
                        spec,
                        &source_label,
                        task_epoch,
                        cancel_token,
                        track_meta,
                    )
                }
                ResolvedPlaybackCandidate::Legacy {
                    stream,
                    source_label,
                } => {
                    let track_meta = parse_deck_track_metadata(s, None);
                    player.play_stream_with_metadata(stream, &source_label, track_meta)
                }
            };
            if let Err(e) = play_res {
                let (err_code, err_provider, msg) = match &e {
                    CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    }) => (
                        Some("AUTH_REQUIRED".to_string()),
                        Some(provider_id.clone()),
                        format!("Authentication required for {provider_id} (HTTP {status})"),
                    ),
                    _ => (
                        player.last_error_code(),
                        player.last_error_provider(),
                        format!("Failed to play stream ({label}): {e}"),
                    ),
                };
                let mut structured = e.to_lumina_error();
                structured.message = msg.clone();
                if let Some(ref prov) = err_provider
                    && structured.provider.is_none()
                {
                    structured.provider = Some(prov.clone());
                }
                engine.has_real_stream.store(false, Ordering::SeqCst);
                engine.playback_state.store(4, Ordering::SeqCst);
                engine.set_structured_error(structured.clone());
                if let Ok(mut code_lock) = engine.async_last_error_code.write()
                    && err_code.is_some()
                {
                    *code_lock = err_code;
                }
                set_last_structured_error(structured);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
            let _ = engine.sync_playback_epoch_from_player(&player, task_epoch);
            engine.has_real_stream.store(true, Ordering::SeqCst);
            engine
                .duration_ms
                .store(player.duration_ms(), Ordering::Relaxed);
            engine.position_ms.store(0, Ordering::Relaxed);
            engine.playback_state.store(2, Ordering::SeqCst);
            return Ok(LUMINA_OK);
        }

        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.playback_state.store(4, Ordering::SeqCst);
        set_last_error("Audio player not initialized");
        Ok(LUMINA_ERR_NOT_INITIALIZED)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_pause() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_pause", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        let play_req = engine.play_request_id.load(Ordering::SeqCst);
        let loaded_req = engine.loaded_request_id.load(Ordering::SeqCst);
        let has_real = engine.has_real_stream.load(Ordering::SeqCst);
        if !has_real || play_req > loaded_req {
            // Cancel any in-flight async resolve/open so pause cannot be overridden moments later.
            engine.async_generation.fetch_add(1, Ordering::SeqCst);
            engine.clear_pending_commands();
            engine.cancel_active_play_token();
            engine.loaded_request_id.store(play_req, Ordering::SeqCst);
            engine.has_real_stream.store(false, Ordering::SeqCst);
        }

        if let Some(player) = engine.player_clone() {
            player.pause();
            if has_real {
                engine
                    .position_ms
                    .store(player.position_ms(), Ordering::Relaxed);
            }
        }

        engine.playback_state.store(3, Ordering::SeqCst); // 3 = Paused
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_stop() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_stop", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        engine.async_generation.fetch_add(1, Ordering::SeqCst);
        engine.clear_pending_commands();
        engine.cancel_active_play_token();
        engine.cancel_active_standby_token();
        let bumped = engine.advance_playback_epoch(None);
        engine.loaded_request_id.store(
            engine.play_request_id.load(Ordering::SeqCst),
            Ordering::SeqCst,
        );
        if let Some(player) = engine.player_clone() {
            player.stop();
            let _ = engine.sync_playback_epoch_from_player(&player, bumped);
        }

        engine.clear_structured_error();
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.playback_state.store(1, Ordering::SeqCst); // 1 = Stopped
        engine.position_ms.store(0, Ordering::Relaxed);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_resume() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_resume", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if let Some(player) = engine.player_clone() {
            player.resume();
            engine.playback_state.store(2, Ordering::SeqCst);
            return Ok(LUMINA_OK);
        }

        engine.playback_state.store(2, Ordering::SeqCst);
        Ok(LUMINA_OK)
    })
}

fn seek_impl(position_ms: u64, caller_epoch: Option<u64>) -> anyhow::Result<c_int> {
    let engine = get_engine();
    if !engine.initialized.load(Ordering::SeqCst) {
        return Ok(LUMINA_ERR_NOT_INITIALIZED);
    }

    if let Some(ep) = caller_epoch
        && !engine.accept_caller_epoch(Some(ep))
    {
        return Ok(LUMINA_OK);
    }

    if let Some(player) = engine.player_clone() {
        let state = player.state_code();
        if state == 0 || state == 4 {
            set_last_error("Cannot seek in uninitialized or error state");
            return Ok(LUMINA_ERR_AUDIO_BACKEND);
        }
        if let Some(ep) = caller_epoch {
            player.sync_caller_epoch_floor(ep);
            engine.sync_caller_epoch_floor(ep);
        }
        player.seek_ms(position_ms);
        engine.position_ms.store(position_ms, Ordering::Relaxed);
        return Ok(LUMINA_OK);
    }

    if let Some(ep) = caller_epoch {
        engine.sync_caller_epoch_floor(ep);
    } else {
        engine.advance_epoch(None);
    }
    engine.position_ms.store(position_ms, Ordering::Relaxed);
    Ok(LUMINA_OK)
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_seek(position_ms: u64) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_seek", || {
        seek_impl(position_ms, None)
    })
}

/// Seeks to `position_ms` while synchronizing `epoch`/`playback_epoch` with `caller_epoch`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_seek_at_epoch(position_ms: u64, epoch: u64) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_seek_at_epoch", || {
        seek_impl(position_ms, (epoch > 0).then_some(epoch))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_reconnect_device() -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_reconnect_device",
        || {
            let engine = get_engine();
            if !engine.initialized.load(Ordering::SeqCst) {
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            }

            if let Some(player) = engine.player_clone() {
                let _ = player.take_last_error();
                engine.clear_structured_error();
                let _ = player.select_output_device(None, None);
                player.set_device_lost(false);
                if engine.playback_state.load(Ordering::SeqCst) == 4 {
                    engine.playback_state.store(1, Ordering::SeqCst);
                }
                return Ok(LUMINA_OK);
            }

            if engine.playback_state.load(Ordering::SeqCst) == 4 {
                engine.playback_state.store(1, Ordering::SeqCst);
            }
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_set_volume(volume: f32) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_set_volume", || {
        let engine = get_engine();
        engine.set_volume(volume);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_volume() -> f32 {
    let engine = get_engine();
    engine.get_volume()
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_state() -> c_int {
    let engine = get_engine();
    let play_req = engine.play_request_id.load(Ordering::SeqCst);
    let loaded_req = engine.loaded_request_id.load(Ordering::SeqCst);
    if play_req > loaded_req {
        return 5;
    }
    if !engine.has_real_stream.load(Ordering::SeqCst)
        && engine.playback_state.load(Ordering::SeqCst) == 4
    {
        return 4;
    }
    if engine.initialized.load(Ordering::SeqCst)
        && engine.has_real_stream.load(Ordering::SeqCst)
        && let Some(player) = engine.player_clone()
    {
        return player.state_code();
    }
    engine.playback_state.load(Ordering::SeqCst)
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_position_ms() -> u64 {
    let engine = get_engine();
    if engine.play_request_id.load(Ordering::SeqCst)
        > engine.loaded_request_id.load(Ordering::SeqCst)
    {
        return 0;
    }
    if engine.initialized.load(Ordering::SeqCst)
        && engine.has_real_stream.load(Ordering::SeqCst)
        && let Some(player) = engine.player_clone()
    {
        return player.position_ms();
    }
    engine.position_ms.load(Ordering::Relaxed)
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_duration_ms() -> u64 {
    let engine = get_engine();
    if engine.initialized.load(Ordering::SeqCst)
        && engine.has_real_stream.load(Ordering::SeqCst)
        && let Some(player) = engine.player_clone()
    {
        return player.duration_ms();
    }
    engine.duration_ms.load(Ordering::Relaxed)
}
