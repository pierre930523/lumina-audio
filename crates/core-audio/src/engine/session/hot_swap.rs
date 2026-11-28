//! Lock-free zero-reopen hot-swap entry dispatcher for active output sessions.

use std::sync::atomic::Ordering;
use std::sync::{Arc, mpsc};

use core_types::{DeviceTransportKind, DsdOutputMode, OutputBackendKind, OutputMode};

use crate::backend::device_manager::AudioFormatManager;
use crate::decoder::pcm::{AudioDecoder, DecodedTrackMetadata};
use crate::engine::PlayerInner;
use crate::engine::coordinator::PlayerCommand;
use crate::error::{BackendError, CoreAudioError};

use super::active::ActiveSession;
use super::hot_swap_pcm::try_hot_swap_pcm;
use super::hot_swap_wire::try_hot_swap_wire;
use super::types::{PipelineSpec, resolve_target_capabilities};

/// Attempts a zero-reopen lock-free hot-swap of `decoder` onto an already-running `active`
/// output session (WASAPI Exclusive `IAudioClient`, Virtual Wire, Virtual PCM, or CPAL Shared)
/// when the hardware/virtual format specification matches.
///
/// Returns:
/// - `Ok(Ok(()))` when hot-swap succeeded (zero hardware teardown/reopen).
/// - `Ok(Err(decoder))` when output format/mode/device changed or session is not alive (caller
///   tears down `active` and calls [`super::start_output_pipeline`] once).
/// - `Err(err)` on hard format negotiation failure (e.g., Strict Bit-Perfect unsupported rate).
pub(crate) fn try_hot_swap_active_session(
    inner: &Arc<PlayerInner>,
    active: &mut ActiveSession,
    decoder: Box<dyn AudioDecoder>,
    spec: &PipelineSpec,
    cmd_tx: &mpsc::Sender<PlayerCommand>,
) -> Result<Result<(), Box<dyn AudioDecoder>>, CoreAudioError> {
    if !active.is_output_alive(inner) {
        return Ok(Err(decoder));
    }

    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let unified_src = decoder.unified_format();
    let track_meta: Option<DecodedTrackMetadata> = decoder.metadata().cloned();
    let caps = resolve_target_capabilities(inner, sel_id.as_deref(), sel_backend);
    let policy = inner.policy.read().map(|g| g.clone()).unwrap_or_default();
    let dsp_bypassed = inner.dsp_bypassed.load(Ordering::SeqCst);
    let eff_vol = if policy.strict_bit_perfect {
        1.0
    } else {
        f32::from_bits(inner.volume_bits.load(Ordering::Relaxed))
    };

    let explicit_shared = sel_backend == Some(OutputBackendKind::WindowsWasapiShared)
        || sel_id
            .as_deref()
            .is_some_and(|s| s.starts_with("wasapi-shared::"));
    let want_native_wire = !explicit_shared
        && (policy.strict_bit_perfect
            || dsp_bypassed
            || caps.backend == OutputBackendKind::WindowsAsio
            || sel_backend == Some(OutputBackendKind::WindowsAsio)
            || sel_backend == Some(OutputBackendKind::WindowsWasapiExclusive)
            || (unified_src.dsd_rate.is_some()
                && !matches!(policy.dsd_output_mode, DsdOutputMode::DsdToPcm)
                && dsp_bypassed
                && (eff_vol - 1.0).abs() < 1e-6));

    let negotiated_res = AudioFormatManager::negotiate(&unified_src, &caps, &policy);
    if let Err(ref msg) = negotiated_res
        && policy.strict_bit_perfect
        && !policy.allow_shared_fallback
    {
        tracing::warn!("Strict bit-perfect format negotiation rejected stream: {msg}");
        return Err(CoreAudioError::Backend(BackendError::UnsupportedFormat(
            spec.format.clone(),
        )));
    }

    let effective_deck_track_meta = spec.track_meta.clone().map(|mut m| {
        if spec.duration_ms > 0 {
            m.duration_ms = spec.duration_ms;
        }
        m
    });

    // Path A: Native Wire (WASAPI Exclusive / Virtual Wire) hot-swap
    if want_native_wire
        && let Ok(ref negotiated) = negotiated_res
        && negotiated.output_mode.is_exclusive_or_asio()
    {
        let allow_virtual_wire = caps.transport == DeviceTransportKind::Virtual
            && (policy.strict_bit_perfect
                || dsp_bypassed
                || sel_backend == Some(OutputBackendKind::WindowsWasapiExclusive)
                || sel_backend == Some(OutputBackendKind::WindowsAsio)
                || matches!(
                    negotiated.output_mode,
                    OutputMode::DoPOverWasapiExclusive | OutputMode::AsioNativeDsd
                ));

        if caps.transport != DeviceTransportKind::Virtual || allow_virtual_wire {
            return try_hot_swap_wire(
                inner,
                active,
                decoder,
                spec,
                cmd_tx,
                &caps,
                &policy,
                sel_backend,
                dsp_bypassed,
                allow_virtual_wire,
                negotiated,
                unified_src,
                track_meta,
                effective_deck_track_meta,
            );
        }
    }

    // Path B: Virtual PCM / CPAL Shared hot-swap
    try_hot_swap_pcm(
        inner,
        active,
        decoder,
        spec,
        cmd_tx,
        &caps,
        &policy,
        sel_id,
        dsp_bypassed,
        eff_vol,
        unified_src,
        track_meta,
        effective_deck_track_meta,
    )
}
