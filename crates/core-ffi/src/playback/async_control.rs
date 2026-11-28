use super::loader::ensure_playback_loaders_started;
use super::payload::{ADAPTIVE_RAPID_WINDOW_MS, parse_payload_hints};
use crate::engine::{PlayDispatchCmd, get_engine};
use crate::error::{
    LUMINA_ERR_AUDIO_BACKEND, LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_OK,
    catch_unwind_ffi, set_last_error, take_last_error,
};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::Ordering;
use tokio_util::sync::CancellationToken;

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_play_async(track_json: *const c_char, request_id: u64) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_play_async", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            set_last_error("Audio engine not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }
        if track_json.is_null() {
            set_last_error("track_json must not be null for lumina_playback_play_async");
            return Ok(LUMINA_ERR_GENERAL);
        }
        if request_id == 0 {
            set_last_error("request_id must be greater than 0 for lumina_playback_play_async");
            return Ok(LUMINA_ERR_GENERAL);
        }

        let c_str = unsafe { CStr::from_ptr(track_json) };
        let payload = match c_str.to_str() {
            Ok(str_val) => str_val.trim().to_string(),
            Err(e) => {
                set_last_error(format!("Invalid UTF-8 in playback payload: {e}"));
                return Ok(LUMINA_ERR_GENERAL);
            }
        };

        let hints = match parse_payload_hints(&payload) {
            Ok(h) => h,
            Err(msg) => {
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
        };
        if !engine.accept_caller_epoch(hints.caller_epoch) {
            return Ok(LUMINA_OK);
        }

        let Some(player) = engine.player_clone() else {
            set_last_error("Audio player not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        // Non-blocking skip transition (<0.1ms): keeps WASAPI alive in silence, zero jh.join().
        let (player_play_ep, cancel_token, task_epoch) = if let Some(ep) = hints.caller_epoch {
            let tok = CancellationToken::new();
            let Some(play_ep) = player.begin_skip_transition_with_epoch(ep, tok.clone()) else {
                return Ok(LUMINA_OK);
            };
            let eff_ep = engine.sync_playback_epoch_from_player(&player, ep);
            (play_ep, tok, eff_ep)
        } else {
            let (play_ep, tok) = player.begin_skip_transition();
            let eff_ep = engine.advance_after_epochless_skip(&player);
            (play_ep, tok, eff_ep)
        };

        engine.swap_play_cancel_token(cancel_token.clone());
        engine.cancel_active_standby_token();
        let _ = engine.standby_cmd_tx.send_replace(None);
        let generation = engine.async_generation.fetch_add(1, Ordering::SeqCst) + 1;
        engine.loaded_request_id.store(0, Ordering::SeqCst);
        engine.play_request_id.store(request_id, Ordering::SeqCst);
        engine.clear_structured_error();
        let _ = take_last_error();
        let _ = player.take_last_error();
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.position_ms.store(0, Ordering::Relaxed);
        engine
            .duration_ms
            .store(hints.duration_ms, Ordering::Relaxed);
        engine.playback_state.store(5, Ordering::SeqCst); // 5 = Loading

        if let Ok(mut lock) = engine.active_track_json.write() {
            *lock = Some(payload.clone());
        }

        let now_ms = engine.elapsed_ms_since_start();
        let prev_ms = engine.last_play_dispatch_ms.swap(now_ms, Ordering::SeqCst);
        let rapid_within_300ms =
            prev_ms > 0 && now_ms.saturating_sub(prev_ms) <= ADAPTIVE_RAPID_WINDOW_MS;

        ensure_playback_loaders_started(&engine);
        let _ = engine.play_cmd_tx.send_replace(Some(PlayDispatchCmd {
            payload,
            request_id,
            generation,
            task_epoch,
            player_play_ep,
            cancel_token,
            debounced: hints.debounced,
            rapid_within_300ms,
        }));

        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_cancel_pending(epoch: u64) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_cancel_pending", || {
        let engine = get_engine();
        if epoch > 0 && !engine.accept_caller_epoch(Some(epoch)) {
            return Ok(LUMINA_OK);
        }

        engine.async_generation.fetch_add(1, Ordering::SeqCst);
        engine.clear_pending_commands();
        engine.cancel_active_standby_token();

        if let Some(player) = engine.player_clone() {
            if epoch > 0 {
                let fresh = CancellationToken::new();
                let _ = player.begin_skip_transition_with_epoch(epoch, fresh.clone());
                engine.sync_playback_epoch_from_player(&player, epoch);
                engine.swap_play_cancel_token(fresh);
            } else {
                let (_, fresh) = player.begin_skip_transition();
                let _ = engine.advance_after_epochless_skip(&player);
                engine.swap_play_cancel_token(fresh);
            }
        } else {
            engine.cancel_active_play_token();
            engine.advance_playback_epoch((epoch > 0).then_some(epoch));
        }

        let active_id = engine.play_request_id.load(Ordering::SeqCst);
        engine.loaded_request_id.store(active_id, Ordering::SeqCst);
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.position_ms.store(0, Ordering::Relaxed);
        engine.playback_state.store(1, Ordering::SeqCst);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_active_request_id() -> u64 {
    get_engine().play_request_id.load(Ordering::SeqCst)
}
