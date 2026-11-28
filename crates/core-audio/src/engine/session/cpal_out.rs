//! `cpal` shared/fallback output stream builders and RT callback wiring.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use core_types::{OutputBackendKind, PlaybackLifecycleState};
use cpal::traits::DeviceTrait;
use cpal::{FromSample, SampleFormat, SizedSample};

use crate::backend::cpal_shared::{
    render_cpal_output_chunked, resolve_cpal_device, select_output_config,
};
use crate::engine::PlayerInner;
use crate::engine::dual_deck::{DualDeckPcmFeeder, PcmRenderOutcome, RtPcmInboxPayload};
use crate::error::{BackendError, CoreAudioError};
use crate::pipeline::fade::{
    AudioFadeControl, compute_pcm_ring_samples, compute_startup_watermark_samples,
};
use crate::pipeline::ring_buffer::{Producer, SpscRingBuffer};
use crate::pipeline::rt_telemetry::RtErrorCode;
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub(super) fn open_cpal_output(
    desired_rate: u32,
    desired_channels: u16,
    inner: &Arc<PlayerInner>,
    verification: Option<&AudioVerificationEngine>,
    output_kill_flag: &Arc<AtomicBool>,
    active_deck: usize,
    active_gen: u64,
    active_session_id: Arc<AtomicU64>,
    fade_ctrl: &Arc<AudioFadeControl>,
) -> Result<
    (
        cpal::Stream,
        Producer<f32>,
        u32,
        u16,
        SampleFormat,
        OutputBackendKind,
        String,
        usize,
    ),
    CoreAudioError,
> {
    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let (device, backend_kind, dev_name) = resolve_cpal_device(sel_id.as_deref(), sel_backend)?;

    let selected_config = select_output_config(&device, desired_rate, desired_channels)?;
    let sample_format = selected_config.sample_format();
    let out_rate = selected_config.sample_rate();
    let out_channels = selected_config.channels();
    let stream_config: cpal::StreamConfig = selected_config.into();
    let ring_samples = compute_pcm_ring_samples(out_rate, out_channels);
    let (producer, consumer) = SpscRingBuffer::<f32>::new(ring_samples);
    let watermark_samples =
        compute_startup_watermark_samples(out_rate, out_channels, producer.capacity());
    let ver_tap = verification.map(|v| {
        v.attach_rt_tap(
            WireSampleFormat::Float32Le,
            out_channels,
            out_rate,
            1024 * 1024,
        )
    });
    let last_ring_epoch = consumer.epoch();
    let payload = RtPcmInboxPayload {
        consumer,
        ver_tap,
        watermark_samples,
        out_rate,
        out_channels,
        deck_gen: active_gen,
        last_ring_epoch,
    };
    let feeder = DualDeckPcmFeeder::new(
        Arc::clone(&inner.dual_deck),
        Arc::clone(inner),
        active_session_id,
        active_deck,
        payload,
        fade_ctrl,
    );

    let stream = build_cpal_stream_for_format(
        &device,
        sample_format,
        stream_config,
        feeder,
        inner,
        output_kill_flag,
        fade_ctrl,
        &dev_name,
    )?;

    Ok((
        stream,
        producer,
        out_rate,
        out_channels,
        sample_format,
        backend_kind,
        dev_name,
        watermark_samples,
    ))
}

#[allow(clippy::type_complexity)]
pub(super) fn open_cpal_output_with_payload(
    active_deck: usize,
    payload: RtPcmInboxPayload,
    inner: &Arc<PlayerInner>,
    output_kill_flag: &Arc<AtomicBool>,
    active_session_id: Arc<AtomicU64>,
    fade_ctrl: &Arc<AudioFadeControl>,
) -> Result<
    (
        cpal::Stream,
        u32,
        u16,
        SampleFormat,
        OutputBackendKind,
        String,
    ),
    CoreAudioError,
> {
    let (sel_id, sel_backend) = inner
        .selected_output
        .read()
        .map(|g| g.clone())
        .unwrap_or((None, None));
    let (device, backend_kind, dev_name) = resolve_cpal_device(sel_id.as_deref(), sel_backend)?;
    let selected_config = select_output_config(&device, payload.out_rate, payload.out_channels)?;
    let sample_format = selected_config.sample_format();
    let out_rate = selected_config.sample_rate();
    let out_channels = selected_config.channels();
    if out_rate != payload.out_rate || out_channels != payload.out_channels {
        return Err(CoreAudioError::Backend(BackendError::InvalidState(
            format!(
                "Standby PCM format mismatch with cpal output device: standby={}Hz/{}ch vs device={}Hz/{}ch",
                payload.out_rate, payload.out_channels, out_rate, out_channels
            ),
        )));
    }
    let stream_config: cpal::StreamConfig = selected_config.into();
    let feeder = DualDeckPcmFeeder::new(
        Arc::clone(&inner.dual_deck),
        Arc::clone(inner),
        active_session_id,
        active_deck,
        payload,
        fade_ctrl,
    );
    let stream = build_cpal_stream_for_format(
        &device,
        sample_format,
        stream_config,
        feeder,
        inner,
        output_kill_flag,
        fade_ctrl,
        &dev_name,
    )?;
    Ok((
        stream,
        out_rate,
        out_channels,
        sample_format,
        backend_kind,
        dev_name,
    ))
}

#[allow(clippy::too_many_arguments)]
fn build_cpal_stream_for_format(
    device: &cpal::Device,
    sample_format: SampleFormat,
    stream_config: cpal::StreamConfig,
    feeder: DualDeckPcmFeeder,
    inner: &Arc<PlayerInner>,
    output_kill_flag: &Arc<AtomicBool>,
    fade_ctrl: &Arc<AudioFadeControl>,
    dev_name: &str,
) -> Result<cpal::Stream, CoreAudioError> {
    let stream_res = match sample_format {
        SampleFormat::F32 => build_cpal_typed_stream::<f32>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::F64 => build_cpal_typed_stream::<f64>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::I32 => build_cpal_typed_stream::<i32>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::I24 => build_cpal_typed_stream::<cpal::I24>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::I16 => build_cpal_typed_stream::<i16>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::U16 => build_cpal_typed_stream::<u16>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        SampleFormat::U8 => build_cpal_typed_stream::<u8>(
            device,
            stream_config,
            feeder,
            Arc::clone(inner),
            Arc::clone(output_kill_flag),
            Arc::clone(fade_ctrl),
        ),
        other => {
            return Err(CoreAudioError::Backend(BackendError::DriverError(format!(
                "Unsupported cpal output sample format: {other:?}"
            ))));
        }
    };

    stream_res.map_err(|e| {
        CoreAudioError::Backend(BackendError::DriverError(format!(
            "Failed to build cpal output stream for '{dev_name}': {e}"
        )))
    })
}

#[allow(clippy::too_many_arguments)]
fn build_cpal_typed_stream<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    mut feeder: DualDeckPcmFeeder,
    inner: Arc<PlayerInner>,
    output_kill_flag: Arc<AtomicBool>,
    fade_ctrl: Arc<AudioFadeControl>,
) -> Result<cpal::Stream, cpal::Error>
where
    T: SizedSample + FromSample<f32>,
{
    let ch = config.channels.max(1) as usize;
    let max_pos = if T::FORMAT.is_float() {
        1.0_f32
    } else {
        // dasp_sample requires -1.0 <= s < 1.0 for float-to-integer conversions
        0.99999994_f32
    };
    let err_inner = Arc::clone(&inner);

    device.build_output_stream(
        config,
        move |output: &mut [T], _| {
            // Strictly real-time safe: ZERO mutex locks, ZERO heap allocations, ZERO I/O,
            // and <= 2 KiB stack frame via `render_cpal_output_chunked` (256 f32 = 1 KiB).
            if output_kill_flag.load(Ordering::Acquire) {
                output.fill(T::EQUILIBRIUM);
                return;
            }

            let mut stack_wire = [0u8; crate::backend::cpal_shared::CPAL_RT_CHUNK_SAMPLES * 4];
            render_cpal_output_chunked(output, ch, |chunk_f32| {
                let outcome = feeder.render_f32(
                    chunk_f32,
                    &mut stack_wire[..chunk_f32.len() * 4],
                    &fade_ctrl,
                    max_pos,
                );
                if outcome == PcmRenderOutcome::Ended {
                    fade_ctrl.mark_silent();
                    let _ = inner.state_code.compare_exchange(
                        PlaybackLifecycleState::Playing as i32,
                        PlaybackLifecycleState::Ended as i32,
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                    return false;
                }
                outcome == PcmRenderOutcome::Rendered
            });
        },
        move |_err| {
            // Strictly lock-free, allocation-free, log-free, syscall-free on cpal audio thread:
            // relay_loop observes `cpal_stream_error_flag` + `relay_signal` off-RT.
            err_inner.device_lost.store(true, Ordering::SeqCst);
            err_inner
                .cpal_stream_error_flag
                .store(true, Ordering::Release);
            err_inner
                .state_code
                .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
            err_inner
                .rt_telemetry
                .record_error_rt(RtErrorCode::DeviceInvalidated, -1);
            err_inner.dual_deck.signal_relay_rt();
        },
        None,
    )
}
