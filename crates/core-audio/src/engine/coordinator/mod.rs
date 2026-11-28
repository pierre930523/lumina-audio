//! Playback coordinator loop (`coordinator_loop`), explicit `OutputDeviceFsm`
//! lifecycle tracking, and control-thread reconfigure coalescer.

mod commands;
mod loop_runner;
mod recovery;
mod reopen;
mod standby_reopen;
mod transport;

pub(crate) use loop_runner::coordinator_loop;

use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Arc, mpsc};
use std::time::Duration;

use core_types::{AudioFormat, DeckTrackMetadata, StreamSourceSpec};
use tokio_util::sync::CancellationToken;

use crate::backend::DeviceEvent;
use crate::backend::device_fsm::{
    DEFAULT_POST_RELEASE_GUARD_DELAY, OutputDeviceFsm, OutputDeviceState,
};
use crate::decoder::pcm::AudioDecoder;
use crate::engine::session::ActiveSession;
use crate::engine::{PlayerInner, PlayerOrigin, TrackReplayGainTags, encode_device_fsm_state};
use crate::error::CoreAudioError;

pub(crate) struct PendingStart {
    pub(crate) session_id: u64,
    pub(crate) decoder: Box<dyn AudioDecoder>,
    pub(crate) path: PathBuf,
    pub(crate) source_label: String,
    pub(crate) origin: PlayerOrigin,
    pub(crate) track_meta: Option<DeckTrackMetadata>,
    pub(crate) cancel_token: CancellationToken,
    pub(crate) ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
}

#[allow(clippy::large_enum_variant)]
pub(crate) enum PlayerCommand {
    ApplyLatestStart,
    FormatSwitchNext {
        session_id: u64,
        decoder: Box<dyn AudioDecoder>,
        path: PathBuf,
        source_label: String,
        origin: PlayerOrigin,
        track_meta: Option<DeckTrackMetadata>,
        cancel_token: CancellationToken,
        rg_tags: TrackReplayGainTags,
    },
    ReopenForFormatChange {
        session_id: u64,
        #[allow(dead_code)]
        new_format: AudioFormat,
        resume_pos_ms: u64,
    },
    HotReloadSpec {
        session_id: u64,
        new_spec: StreamSourceSpec,
        resume_ms: u64,
    },
    HardwareDeviceEvent(DeviceEvent),
    RerouteOutput {
        ack_tx: mpsc::SyncSender<Result<(), CoreAudioError>>,
        recover_device_lost: bool,
    },
    Pause,
    Resume,
    Stop,
    SeekMs {
        was_ended: bool,
    },
    RetireDeck {
        deck_idx: usize,
        #[allow(dead_code)]
        deck_gen: u64,
    },
    ReopenOntoStandby {
        from_deck: usize,
        to_deck: usize,
        to_deck_gen: u64,
        is_manual_skip: bool,
        is_mismatch_recovery: bool,
    },
    TriggerAutoStandby,
    Shutdown,
}

pub(crate) struct SavedRecoverySession {
    pub(super) path: PathBuf,
    pub(super) source_label: String,
    pub(super) origin: PlayerOrigin,
    pub(super) format: AudioFormat,
    pub(super) duration_ms: u64,
    pub(super) pcm_rate: u32,
    pub(super) resume_pos_ms: u64,
    pub(super) was_playing: bool,
    pub(super) from_suspend: bool,
    pub(super) track_meta: Option<DeckTrackMetadata>,
}

pub(super) struct CoordinatorState {
    pub(super) inner: Arc<PlayerInner>,
    pub(super) cmd_tx: mpsc::Sender<PlayerCommand>,
    pub(super) active: Option<ActiveSession>,
    pub(super) saved_recovery: Option<SavedRecoverySession>,
    pub(super) fsm: OutputDeviceFsm,
}

#[inline]
pub(super) fn sync_fsm_state(inner: &PlayerInner, fsm: &OutputDeviceFsm) {
    inner
        .device_fsm_state
        .store(encode_device_fsm_state(fsm.state()), Ordering::Release);
}

pub(super) fn teardown_active_retiring_with_fsm(
    fsm: &mut OutputDeviceFsm,
    inner: &PlayerInner,
    active: &mut Option<ActiveSession>,
    cancel_own_token: bool,
    reconfiguring: bool,
) {
    let Some(sess) = active.as_ref() else {
        return;
    };
    let use_guard = !inner.headless && sess.is_hardware_output();
    fsm.set_post_release_guard_delay(if use_guard {
        DEFAULT_POST_RELEASE_GUARD_DELAY
    } else {
        Duration::ZERO
    });
    if reconfiguring && fsm.state() == OutputDeviceState::Running {
        let _ = fsm.transition(OutputDeviceState::Reconfiguring);
        sync_fsm_state(inner, fsm);
    }
    let _ = fsm.stop_and_release_sequence(active, |s| {
        s.stop_retiring_decode(inner, cancel_own_token);
    });
    sync_fsm_state(inner, fsm);
}

pub(super) fn teardown_active_join_with_fsm(
    fsm: &mut OutputDeviceFsm,
    inner: &PlayerInner,
    active: &mut Option<ActiveSession>,
    reconfiguring: bool,
) -> Option<Box<dyn AudioDecoder>> {
    let sess = active.as_ref()?;
    let use_guard = !inner.headless && sess.is_hardware_output();
    fsm.set_post_release_guard_delay(if use_guard {
        DEFAULT_POST_RELEASE_GUARD_DELAY
    } else {
        Duration::ZERO
    });
    if reconfiguring && fsm.state() == OutputDeviceState::Running {
        let _ = fsm.transition(OutputDeviceState::Reconfiguring);
        sync_fsm_state(inner, fsm);
    }
    let mut reused = None;
    let _ = fsm.stop_and_release_sequence(active, |s| {
        reused = s.stop_and_join();
    });
    sync_fsm_state(inner, fsm);
    reused
}

pub(super) fn enter_opening_with_fsm(fsm: &mut OutputDeviceFsm, inner: &PlayerInner) {
    if fsm.state() == OutputDeviceState::Faulted {
        let _ = fsm.reset_from_fault();
    }
    let _ = fsm.transition(OutputDeviceState::Opening);
    sync_fsm_state(inner, fsm);
}

pub(super) fn mark_running_with_fsm(fsm: &mut OutputDeviceFsm, inner: &PlayerInner) {
    let _ = fsm.transition(OutputDeviceState::Running);
    sync_fsm_state(inner, fsm);
}

pub(super) fn mark_faulted_with_fsm(fsm: &mut OutputDeviceFsm, inner: &PlayerInner) {
    fsm.mark_faulted();
    sync_fsm_state(inner, fsm);
}
