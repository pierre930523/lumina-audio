//! Coordinator command coalescing and main event loop.

use std::collections::VecDeque;
use std::sync::{Arc, mpsc};
use std::time::Duration;

use crate::backend::DeviceEvent;
use crate::backend::device_fsm::{DEFAULT_POST_RELEASE_GUARD_DELAY, OutputDeviceFsm};
use crate::engine::PlayerInner;
use crate::error::CoreAudioError;

use super::commands::{handle_apply_latest_start, handle_format_switch_next};
use super::recovery::{handle_hardware_device_event, handle_reroute_output};
use super::reopen::{handle_hot_reload_spec, handle_reopen_for_format_change};
use super::standby_reopen::handle_reopen_onto_standby;
use super::transport::{
    handle_pause, handle_resume, handle_retire_deck, handle_seek_ms, handle_trigger_auto_standby,
};
use super::{CoordinatorState, PlayerCommand, sync_fsm_state, teardown_active_retiring_with_fsm};

/// Control-thread command coalescer: drains immediately queued `PlayerCommand` items
/// via `try_recv()` and collapses redundant rapid-skip / format-switch / device-reroute
/// requests so the output device only reconfigures once to the latest target.
fn enqueue_and_coalesce(
    pending: &mut VecDeque<PlayerCommand>,
    extra_reroute_acks: &mut Vec<mpsc::SyncSender<Result<(), CoreAudioError>>>,
    inner: &PlayerInner,
    cmd: PlayerCommand,
) {
    match cmd {
        PlayerCommand::ApplyLatestStart => {
            // Multiple ApplyLatestStart commands share the single-slot `inner.latest_start`.
            if !pending
                .iter()
                .any(|c| matches!(c, PlayerCommand::ApplyLatestStart))
            {
                pending.push_back(PlayerCommand::ApplyLatestStart);
            }
        }
        PlayerCommand::RerouteOutput {
            ack_tx,
            recover_device_lost,
        } => {
            if let Some(existing) = pending
                .iter_mut()
                .find(|c| matches!(c, PlayerCommand::RerouteOutput { .. }))
            {
                if let PlayerCommand::RerouteOutput {
                    recover_device_lost: existing_recover,
                    ..
                } = existing
                {
                    *existing_recover |= recover_device_lost;
                }
                extra_reroute_acks.push(ack_tx);
            } else {
                pending.push_back(PlayerCommand::RerouteOutput {
                    ack_tx,
                    recover_device_lost,
                });
            }
        }
        PlayerCommand::ReopenForFormatChange { .. } => {
            pending.retain(|c| !matches!(c, PlayerCommand::ReopenForFormatChange { .. }));
            pending.push_back(cmd);
        }
        PlayerCommand::FormatSwitchNext { .. } => {
            pending.retain(|c| !matches!(c, PlayerCommand::FormatSwitchNext { .. }));
            pending.push_back(cmd);
        }
        PlayerCommand::ReopenOntoStandby { .. } => {
            let had_prev = pending
                .iter()
                .any(|c| matches!(c, PlayerCommand::ReopenOntoStandby { .. }));
            if had_prev {
                pending.retain(|c| !matches!(c, PlayerCommand::ReopenOntoStandby { .. }));
                inner.dual_deck.notify_flip_done();
            }
            pending.push_back(cmd);
        }
        PlayerCommand::HardwareDeviceEvent(DeviceEvent::DefaultRenderChanged(_)) => {
            pending.retain(|c| {
                !matches!(
                    c,
                    PlayerCommand::HardwareDeviceEvent(DeviceEvent::DefaultRenderChanged(_))
                )
            });
            pending.push_back(cmd);
        }
        PlayerCommand::HardwareDeviceEvent(DeviceEvent::DeviceAdded(ref id)) => {
            pending.retain(|c| {
                !matches!(
                    c,
                    PlayerCommand::HardwareDeviceEvent(DeviceEvent::DeviceAdded(old)) if old == id
                )
            });
            pending.push_back(cmd);
        }
        PlayerCommand::TriggerAutoStandby => {
            if !pending
                .iter()
                .any(|c| matches!(c, PlayerCommand::TriggerAutoStandby))
            {
                pending.push_back(cmd);
            }
        }
        PlayerCommand::Stop | PlayerCommand::Shutdown => {
            // Stop/Shutdown supersedes queued starts/reroutes/reopens; wake any waiting callers.
            let mut kept = VecDeque::new();
            while let Some(old) = pending.pop_front() {
                match old {
                    PlayerCommand::RerouteOutput { ack_tx, .. } => {
                        let _ = ack_tx.send(Ok(()));
                    }
                    PlayerCommand::ReopenOntoStandby { .. } => {
                        inner.dual_deck.notify_flip_done();
                    }
                    PlayerCommand::ApplyLatestStart
                    | PlayerCommand::FormatSwitchNext { .. }
                    | PlayerCommand::ReopenForFormatChange { .. }
                    | PlayerCommand::HotReloadSpec { .. }
                    | PlayerCommand::TriggerAutoStandby => {}
                    other => kept.push_back(other),
                }
            }
            for tx in extra_reroute_acks.drain(..) {
                let _ = tx.send(Ok(()));
            }
            *pending = kept;
            pending.push_back(cmd);
        }
        other => pending.push_back(other),
    }
}

pub(super) fn drain_available_commands(
    cmd_rx: &mpsc::Receiver<PlayerCommand>,
    pending: &mut VecDeque<PlayerCommand>,
    extra_reroute_acks: &mut Vec<mpsc::SyncSender<Result<(), CoreAudioError>>>,
    inner: &PlayerInner,
) {
    while let Ok(next_cmd) = cmd_rx.try_recv() {
        enqueue_and_coalesce(pending, extra_reroute_acks, inner, next_cmd);
    }
}

pub(super) fn notify_reroute_acks(
    primary: mpsc::SyncSender<Result<(), CoreAudioError>>,
    extras: &mut Vec<mpsc::SyncSender<Result<(), CoreAudioError>>>,
    res: Result<(), CoreAudioError>,
) {
    match res {
        Ok(()) => {
            let _ = primary.send(Ok(()));
            for tx in extras.drain(..) {
                let _ = tx.send(Ok(()));
            }
        }
        Err(e) => {
            let msg = e.to_string();
            let _ = primary.send(Err(e));
            for tx in extras.drain(..) {
                let _ = tx.send(Err(CoreAudioError::Backend(
                    crate::error::BackendError::DriverError(msg.clone()),
                )));
            }
        }
    }
}

pub(crate) fn coordinator_loop(
    inner: Arc<PlayerInner>,
    cmd_rx: mpsc::Receiver<PlayerCommand>,
    cmd_tx: mpsc::Sender<PlayerCommand>,
) {
    let fsm = OutputDeviceFsm::with_guard_delay(if inner.headless {
        Duration::ZERO
    } else {
        DEFAULT_POST_RELEASE_GUARD_DELAY
    });
    sync_fsm_state(&inner, &fsm);

    let mut st = CoordinatorState {
        inner,
        cmd_tx,
        active: None,
        saved_recovery: None,
        fsm,
    };
    let mut pending: VecDeque<PlayerCommand> = VecDeque::new();
    let mut extra_reroute_acks: Vec<mpsc::SyncSender<Result<(), CoreAudioError>>> = Vec::new();

    loop {
        if pending.is_empty() {
            let Ok(first_cmd) = cmd_rx.recv() else {
                break;
            };
            enqueue_and_coalesce(&mut pending, &mut extra_reroute_acks, &st.inner, first_cmd);
        }
        drain_available_commands(&cmd_rx, &mut pending, &mut extra_reroute_acks, &st.inner);
        let Some(cmd) = pending.pop_front() else {
            continue;
        };
        match cmd {
            PlayerCommand::ApplyLatestStart => {
                handle_apply_latest_start(&mut st);
            }
            PlayerCommand::FormatSwitchNext {
                session_id,
                decoder,
                path,
                source_label,
                origin,
                track_meta,
                cancel_token,
                rg_tags,
            } => {
                handle_format_switch_next(
                    &mut st,
                    &cmd_rx,
                    &mut pending,
                    &mut extra_reroute_acks,
                    session_id,
                    decoder,
                    path,
                    source_label,
                    origin,
                    track_meta,
                    cancel_token,
                    rg_tags,
                );
            }
            PlayerCommand::ReopenForFormatChange {
                session_id,
                new_format,
                resume_pos_ms,
            } => {
                handle_reopen_for_format_change(&mut st, session_id, new_format, resume_pos_ms);
            }
            PlayerCommand::HotReloadSpec {
                session_id,
                new_spec,
                resume_ms,
            } => {
                handle_hot_reload_spec(&mut st, session_id, new_spec, resume_ms);
            }
            PlayerCommand::HardwareDeviceEvent(event) => {
                handle_hardware_device_event(&mut st, event);
            }
            PlayerCommand::RerouteOutput {
                ack_tx,
                recover_device_lost,
            } => {
                handle_reroute_output(
                    &mut st,
                    ack_tx,
                    &mut extra_reroute_acks,
                    recover_device_lost,
                );
            }
            PlayerCommand::Pause => handle_pause(&st),
            PlayerCommand::Resume => handle_resume(&mut st),
            PlayerCommand::Stop => {
                st.saved_recovery = None;
                st.inner.clear_latest_start();
                teardown_active_retiring_with_fsm(
                    &mut st.fsm,
                    &st.inner,
                    &mut st.active,
                    true,
                    false,
                );
                if let Ok(mut af) = st.inner.active_fade.write() {
                    *af = None;
                }
            }
            PlayerCommand::SeekMs { was_ended } => handle_seek_ms(&mut st, was_ended),
            PlayerCommand::RetireDeck { deck_idx, .. } => handle_retire_deck(&mut st, deck_idx),
            PlayerCommand::ReopenOntoStandby {
                from_deck,
                to_deck,
                to_deck_gen,
                is_manual_skip,
                is_mismatch_recovery,
            } => {
                handle_reopen_onto_standby(
                    &mut st,
                    from_deck,
                    to_deck,
                    to_deck_gen,
                    is_manual_skip,
                    is_mismatch_recovery,
                );
            }
            PlayerCommand::TriggerAutoStandby => handle_trigger_auto_standby(&st),
            PlayerCommand::Shutdown => {
                let _ = st.saved_recovery.take();
                st.inner.clear_latest_start();
                if let Some(ref prev) = st.active {
                    prev.fade_ctrl.mark_silent();
                }
                teardown_active_retiring_with_fsm(
                    &mut st.fsm,
                    &st.inner,
                    &mut st.active,
                    true,
                    true,
                );
                st.inner.dual_deck.cancel_standby();
                let cur_active = st.inner.dual_deck.active_idx();
                let _ = st.inner.dual_deck.cancel_and_join_deck(cur_active);
                #[cfg(target_os = "windows")]
                st.inner.set_active_wasapi_ctrl(None);
                #[cfg(not(target_os = "windows"))]
                st.inner.set_active_wasapi_ctrl();
                st.inner.reaper.shutdown();
                break;
            }
        }
    }
}
