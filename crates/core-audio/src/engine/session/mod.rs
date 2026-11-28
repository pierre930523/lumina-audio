//! Output pipeline session lifecycle, hot-swap, standby deck workers,
//! relay loop, virtual DAC consumers, and cpal stream wiring.

mod active;
mod cpal_out;
mod hot_swap;
mod hot_swap_pcm;
mod hot_swap_wire;
mod native_open;
mod pipeline_start;
mod pipeline_start_pcm;
mod relay;
mod standby;
mod standby_pcm;
mod standby_reopen;
mod types;
mod virtual_out;

pub(crate) use active::ActiveSession;
pub(crate) use hot_swap::try_hot_swap_active_session;
pub(crate) use pipeline_start::start_output_pipeline;
pub(crate) use relay::relay_loop;
pub(crate) use standby::{StandbyDeckGate, run_standby_deck_worker};
pub(crate) use standby_reopen::start_output_pipeline_from_standby;
#[allow(unused_imports)]
pub(crate) use types::{
    CLOCK_SRC_ASIO_HARDWARE, CLOCK_SRC_STREAM_FRAMES, CLOCK_SRC_UNINIT, CLOCK_SRC_WASAPI_HARDWARE,
    NativeOutputSession, OutputReuseKey, PipelineSpec, backend_to_clock_src, clock_src_to_str,
    commit_deck_metadata_to_inner, patched_track_meta, resolve_target_capabilities,
};

use std::sync::Arc;
use std::sync::atomic::Ordering;

use core_types::{AudioDeviceDescription, OutputBackendKind};
use tokio_util::sync::CancellationToken;

use crate::backend::device_manager::AudioDeviceManager;
use crate::decoder::pcm::AudioDecoder;
use crate::engine::{PlayerInner, PlayerOrigin, VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME};
use crate::error::{BackendError, CoreAudioError};
use crate::stream::{StreamOrigin, StreamSource};

pub(crate) fn install_fresh_cancel_token(inner: &PlayerInner) -> Option<CancellationToken> {
    let _ep_guard = inner.epoch_lock.lock().unwrap_or_else(|e| e.into_inner());
    if inner.stopped.load(Ordering::SeqCst) {
        return None;
    }
    let fresh = CancellationToken::new();
    if let Ok(mut guard) = inner.active_cancel.write() {
        let prev = std::mem::replace(&mut *guard, fresh.clone());
        prev.cancel();
    }
    Some(fresh)
}

pub(crate) fn reopen_origin_decoder(
    inner: &Arc<PlayerInner>,
    origin: &PlayerOrigin,
    reused: Option<Box<dyn AudioDecoder>>,
    fresh_cancel: &CancellationToken,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let can_reuse = !matches!(
        origin,
        PlayerOrigin::SourceSpec(_)
            | PlayerOrigin::Legacy(StreamSource {
                origin: StreamOrigin::Http { .. },
                ..
            })
    );
    let refresh_handler = inner.stream_refresh_handler();
    let dec = if can_reuse {
        match reused {
            Some(d) => d,
            None => {
                origin.open_decoder_with_refresh(inner, fresh_cancel.clone(), refresh_handler)?
            }
        }
    } else {
        drop(reused);
        origin.open_decoder_with_refresh(inner, fresh_cancel.clone(), refresh_handler)?
    };
    if fresh_cancel.is_cancelled() || inner.stopped.load(Ordering::SeqCst) {
        return Err(CoreAudioError::Backend(BackendError::InvalidState(
            "Playback cancelled during decoder reopen".to_string(),
        )));
    }
    Ok(dec)
}

pub(crate) fn device_removal_affects_session(
    inner: &PlayerInner,
    sess: &ActiveSession,
    removed_id: &str,
) -> bool {
    let removed_raw = AudioDeviceManager::strip_mode_prefix(removed_id.trim());
    if removed_raw.is_empty() {
        return false;
    }
    if inner.headless
        && (removed_raw == VIRTUAL_DEVICE_ID
            || removed_raw.eq_ignore_ascii_case("default")
            || removed_raw == "*")
    {
        return true;
    }
    let active_raw = AudioDeviceManager::strip_mode_prefix(&sess.active_device_id);
    if sess.active_device_id == removed_id
        || active_raw == removed_raw
        || (!active_raw.is_empty()
            && (active_raw.contains(removed_raw) || removed_raw.contains(active_raw)))
    {
        return true;
    }
    let (sel_id, _) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    if let Some(ref id) = sel_id {
        let sel_raw = AudioDeviceManager::strip_mode_prefix(id);
        if id == removed_id
            || sel_raw == removed_raw
            || (!sel_raw.is_empty()
                && (sel_raw.contains(removed_raw) || removed_raw.contains(sel_raw)))
        {
            return true;
        }
    }
    false
}

pub(crate) fn virtual_exclusive_device(is_default: bool) -> AudioDeviceDescription {
    AudioDeviceDescription {
        id: VIRTUAL_DEVICE_ID.to_string(),
        name: VIRTUAL_DEVICE_NAME.to_string(),
        backend: OutputBackendKind::WindowsWasapiExclusive,
        is_default,
        is_exclusive: true,
        supported_sample_rates: vec![
            44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000,
        ],
        supported_bit_depths: vec![16, 24, 32],
        supports_native_dsd: true,
    }
}
