//! Shared Windows WASAPI Exclusive / ASIO native wire output opener.

use std::sync::Arc;
use std::sync::atomic::AtomicBool;
#[cfg(target_os = "windows")]
use std::time::Duration;

#[cfg(target_os = "windows")]
use core_types::ChannelLayout;
use core_types::{AudioDeviceCapabilities, OutputBackendKind, OutputMode, PlaybackEnginePolicy};

use crate::backend::device_manager::NegotiatedFormat;
use crate::engine::PlayerInner;
use crate::error::BackendError;
use crate::pipeline::fade::AudioFadeControl;
use crate::pipeline::ring_buffer::Consumer;
use crate::verification::AudioVerificationEngine;

use super::types::{NativeOutputSession, OutputReuseKey};

#[allow(clippy::too_many_arguments)]
pub(super) fn open_native_wire_session(
    inner: &Arc<PlayerInner>,
    caps: &AudioDeviceCapabilities,
    negotiated: &NegotiatedFormat,
    policy: &PlaybackEnginePolicy,
    byte_cons: Consumer<u8>,
    verification: &AudioVerificationEngine,
    eof_flag: &Arc<AtomicBool>,
    session_id: u64,
    watermark_bytes: usize,
    fade_ctrl: &Arc<AudioFadeControl>,
    expected_stamp: u64,
    start_paused: bool,
) -> Result<
    (
        NativeOutputSession,
        u32,
        String,
        OutputBackendKind,
        &'static str,
        OutputReuseKey,
    ),
    BackendError,
> {
    #[cfg(target_os = "windows")]
    {
        if matches!(
            negotiated.output_mode,
            OutputMode::AsioPcm | OutputMode::AsioNativeDsd | OutputMode::DoPOverAsio
        ) {
            let is_native_dsd = negotiated.output_mode == OutputMode::AsioNativeDsd;
            crate::backend::asio_win::AsioNativeSession::open_and_start_with_telemetry(
                Some(&caps.device_id),
                negotiated.target_sample_rate,
                negotiated.target_channels,
                negotiated.wire_format,
                is_native_dsd,
                byte_cons,
                verification.clone(),
                Arc::clone(&inner.frames_rendered),
                Arc::clone(&inner.nonzero_output_frames),
                Arc::clone(&inner.state_code),
                Arc::clone(eof_flag),
                session_id,
                Arc::clone(&inner.current_session_id),
                watermark_bytes,
                Some(Arc::clone(fade_ctrl)),
                Some(Arc::clone(&inner.buffered_ms)),
                Arc::clone(&inner.ring_buffer_underrun_count),
                Arc::clone(&inner.device_lost),
                Arc::clone(&inner.last_error),
                Arc::clone(&inner.format_mismatch_flag),
                Arc::clone(&inner.published_format_stamp),
                expected_stamp,
                None,
            )
            .map(|mut sess| {
                sess.set_post_release_guard_delay(Duration::ZERO);
                if start_paused {
                    sess.set_paused(true);
                }
                let frames = sess.buffer_frames;
                let dname = sess.driver_name.clone();
                (
                    NativeOutputSession::AsioNative(sess),
                    frames,
                    dname,
                    OutputBackendKind::WindowsAsio,
                    "ASIO 2.x COM Driver",
                    OutputReuseKey::None,
                )
            })
        } else {
            let open_spec = crate::backend::wasapi_win::WasapiExclusiveOpenSpec {
                device_id: Some(caps.device_id.clone()),
                sample_rate: negotiated.target_sample_rate,
                channels: negotiated.target_channels,
                layout: ChannelLayout::from_channels(negotiated.target_channels),
                wire_format: negotiated.wire_format,
                is_dop: negotiated.output_mode == OutputMode::DoPOverWasapiExclusive,
                buffer_frames_hint: policy.preferred_buffer_frames,
            };
            let reuse_spec = open_spec.clone();
            crate::backend::wasapi_win::WasapiExclusiveSession::open_and_start_with_telemetry(
                open_spec,
                byte_cons,
                verification.clone(),
                Arc::clone(&inner.frames_rendered),
                Arc::clone(&inner.nonzero_output_frames),
                Arc::clone(&inner.state_code),
                Arc::clone(eof_flag),
                Arc::clone(&inner.last_error),
                session_id,
                Arc::clone(&inner.current_session_id),
                watermark_bytes,
                Some(Arc::clone(fade_ctrl)),
                Some(Arc::clone(&inner.buffered_ms)),
                Arc::clone(&inner.ring_buffer_underrun_count),
                Arc::clone(&inner.device_lost),
                Arc::clone(&inner.format_mismatch_flag),
                Arc::clone(&inner.published_format_stamp),
                expected_stamp,
            )
            .map(|mut sess| {
                sess.set_post_release_guard_delay(Duration::ZERO);
                if start_paused {
                    sess.set_paused(true);
                }
                let frames = sess.actual_buffer_frames;
                let dname = sess.device_name.clone();
                (
                    NativeOutputSession::WasapiExclusive(sess),
                    frames,
                    dname,
                    OutputBackendKind::WindowsWasapiExclusive,
                    "WASAPI Exclusive (Event-Driven)",
                    OutputReuseKey::WasapiExclusive(reuse_spec),
                )
            })
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (
            inner,
            caps,
            negotiated,
            policy,
            byte_cons,
            verification,
            eof_flag,
            session_id,
            watermark_bytes,
            fade_ctrl,
            expected_stamp,
            start_paused,
        );
        Err(BackendError::DeviceNotFound(
            "Native Windows WASAPI/ASIO unavailable on this OS".into(),
        ))
    }
}
