use super::loader::{ensure_l2_initialized_in_background, ensure_playback_loaders_started};
use super::payload::{parse_deck_track_metadata, parse_payload_hints};
use super::resolver::{ResolvedPlaybackCandidate, resolve_candidate_async};
use crate::engine::{EngineState, StandbyDispatchCmd, get_engine};
use crate::error::{
    LUMINA_ERR_AUDIO_BACKEND, LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_OK,
    catch_unwind_ffi, set_last_error,
};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

pub(super) async fn run_standby_loader_loop(
    engine: Arc<EngineState>,
    mut rx: watch::Receiver<Option<StandbyDispatchCmd>>,
) {
    while rx.changed().await.is_ok() {
        loop {
            let Some(cmd) = rx.borrow_and_update().clone() else {
                break;
            };
            let is_stale = || {
                cmd.cancel_token.is_cancelled()
                    || cmd
                        .eff_epoch
                        .is_some_and(|ep| ep < engine.last_caller_epoch.load(Ordering::SeqCst))
            };
            if is_stale() {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            ensure_l2_initialized_in_background(&engine).await;
            if is_stale() {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let candidate = tokio::select! {
                biased;
                _ = cmd.cancel_token.cancelled() => {
                    if rx.has_changed().unwrap_or(false) {
                        continue;
                    }
                    break;
                }
                changed = rx.changed() => {
                    if changed.is_err() {
                        return;
                    }
                    continue;
                }
                res = resolve_candidate_async(&engine, &cmd.payload) => match res {
                    Ok(c) => c,
                    Err(_) => {
                        if rx.has_changed().unwrap_or(false) {
                            continue;
                        }
                        break;
                    }
                }
            };

            if is_stale() || rx.has_changed().unwrap_or(false) {
                if rx.has_changed().unwrap_or(false) {
                    continue;
                }
                break;
            }

            let Some(player) = engine.player_clone() else {
                break;
            };
            let eng_sb = engine.clone();
            let cmd_sb = cmd.clone();
            let _ = tokio::task::spawn_blocking(move || {
                if cmd_sb.cancel_token.is_cancelled()
                    || cmd_sb
                        .eff_epoch
                        .is_some_and(|ep| ep < eng_sb.last_caller_epoch.load(Ordering::SeqCst))
                {
                    return;
                }
                let _ = match candidate {
                    ResolvedPlaybackCandidate::SourceSpec { spec, source_label } => {
                        let track_meta = parse_deck_track_metadata(&cmd_sb.payload, Some(&spec));
                        let label_opt =
                            (source_label != "Local Library").then_some(source_label.as_str());
                        player.prepare_standby_spec_with_label_and_metadata(
                            spec, label_opt, track_meta,
                        )
                    }
                    ResolvedPlaybackCandidate::Legacy {
                        stream,
                        source_label,
                    } => {
                        let track_meta = parse_deck_track_metadata(&cmd_sb.payload, None);
                        player.prepare_standby_with_metadata(stream, source_label, track_meta)
                    }
                };
            })
            .await;

            if rx.has_changed().unwrap_or(false) {
                continue;
            }
            break;
        }
    }
}

/// Pre-resolves and pre-decodes 2–3 seconds of the next track onto the Standby deck
/// without interrupting Active deck playback. Rejects `ExternalBackend` (Apple Music).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_prepare_standby_async(
    track_json: *const c_char,
    caller_epoch: u64,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_prepare_standby_async",
        || {
            let engine = get_engine();
            if !engine.initialized.load(Ordering::SeqCst) {
                set_last_error("Audio engine not initialized");
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            }
            if track_json.is_null() {
                set_last_error(
                    "track_json must not be null for lumina_playback_prepare_standby_async",
                );
                return Ok(LUMINA_ERR_GENERAL);
            }

            let c_str = unsafe { CStr::from_ptr(track_json) };
            let payload = match c_str.to_str() {
                Ok(str_val) => str_val.trim().to_string(),
                Err(e) => {
                    set_last_error(format!("Invalid UTF-8 in standby payload: {e}"));
                    return Ok(LUMINA_ERR_GENERAL);
                }
            };
            if payload.is_empty() {
                set_last_error("standby track_json payload must not be empty");
                return Ok(LUMINA_ERR_GENERAL);
            }

            let hints = match parse_payload_hints(&payload) {
                Ok(h) => h,
                Err(msg) => {
                    set_last_error(msg);
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
            };

            let eff_epoch = if caller_epoch > 0 {
                Some(caller_epoch)
            } else {
                hints.caller_epoch
            };
            if let Some(ep) = eff_epoch {
                let last_ep = engine.last_caller_epoch.load(Ordering::SeqCst);
                if ep < last_ep {
                    return Ok(LUMINA_OK);
                }
            }

            if engine.player_clone().is_none() {
                set_last_error("Audio player not initialized");
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            }

            let cancel_token = CancellationToken::new();
            engine.swap_standby_cancel_token(cancel_token.clone());
            ensure_playback_loaders_started(&engine);
            let _ = engine.standby_cmd_tx.send_replace(Some(StandbyDispatchCmd {
                payload,
                eff_epoch,
                cancel_token,
            }));

            Ok(LUMINA_OK)
        },
    )
}

fn skip_to_standby_impl(caller_epoch: Option<u64>) -> anyhow::Result<c_int> {
    let engine = get_engine();
    if !engine.initialized.load(Ordering::SeqCst) {
        set_last_error("Audio engine not initialized");
        return Ok(LUMINA_ERR_NOT_INITIALIZED);
    }
    if let Some(ep) = caller_epoch
        && !engine.accept_caller_epoch(Some(ep))
    {
        return Ok(0);
    }

    let Some(player) = engine.player_clone() else {
        set_last_error("Audio player not initialized");
        return Ok(LUMINA_ERR_NOT_INITIALIZED);
    };

    engine.cancel_active_play_token();
    engine.cancel_active_standby_token();
    engine.clear_pending_commands();
    engine.async_generation.fetch_add(1, Ordering::SeqCst);

    match player.skip_to_standby() {
        Ok(true) => {
            let synced_ep = if let Some(ep) = caller_epoch {
                player.sync_caller_epoch_floor(ep);
                let floor = engine.sync_caller_epoch_floor(ep);
                engine.sync_playback_epoch_from_player(&player, floor)
            } else {
                let bumped = engine.advance_playback_epoch(None);
                engine.sync_playback_epoch_from_player(&player, bumped)
            };
            if let Some(meta) = player.active_track_metadata()
                && let Ok(meta_json) = serde_json::to_string(&meta)
                && let Ok(mut lock) = engine.active_track_json.write()
            {
                *lock = Some(meta_json);
            }
            engine.has_real_stream.store(true, Ordering::SeqCst);
            engine
                .duration_ms
                .store(player.duration_ms(), Ordering::Relaxed);
            engine.position_ms.store(0, Ordering::Relaxed);
            engine.playback_state.store(2, Ordering::SeqCst);
            let aligned_req_id = if let Some(ep) = caller_epoch {
                let prev = engine
                    .play_request_id
                    .fetch_max(ep.max(synced_ep), Ordering::SeqCst);
                prev.max(ep).max(synced_ep)
            } else {
                engine.play_request_id.load(Ordering::SeqCst)
            };
            engine
                .loaded_request_id
                .store(aligned_req_id, Ordering::SeqCst);
            Ok(1)
        }
        Ok(false) => Ok(0),
        Err(e) => {
            set_last_error(format!("Failed to skip to standby deck: {e}"));
            Ok(LUMINA_ERR_AUDIO_BACKEND)
        }
    }
}

/// Switches playback to the Standby deck in 5–15 ms if Standby is `STANDBY_READY`.
/// Returns `1` if the zero-latency switch occurred, `0` if Standby was not ready, or `< 0` on error.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_skip_to_standby() -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_skip_to_standby",
        || skip_to_standby_impl(None),
    )
}

/// Switches playback to the Standby deck while aligning `playback_epoch` and `play_request_id`
/// with the caller's monotonic `caller_epoch` (zero Dart poll-filter mismatch).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_skip_to_standby_at_epoch(caller_epoch: u64) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_skip_to_standby_at_epoch",
        || skip_to_standby_impl((caller_epoch > 0).then_some(caller_epoch)),
    )
}
