//! Session descriptors, clock source mapping, capability resolution, and metadata committers.

use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;

use core_types::{
    AudioDeviceCapabilities, AudioFormat, DeckTrackMetadata, OutputBackendKind, OutputMode,
    StreamSourceSpec,
};
use tokio_util::sync::CancellationToken;

use crate::backend::cpal_shared::enumerate_cpal_devices;
use crate::backend::device_manager::AudioDeviceManager;
use crate::engine::dual_deck::DeckMetadataSnapshot;
use crate::engine::{ActiveTrackMeta, PlayerInner, PlayerOrigin, VIRTUAL_DEVICE_ID};
use crate::error::BackendError;
use crate::verification::WireSampleFormat;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum OutputReuseKey {
    #[cfg(target_os = "windows")]
    WasapiExclusive(crate::backend::wasapi_win::WasapiExclusiveOpenSpec),
    VirtualWire {
        output_mode: OutputMode,
        wire_format: WireSampleFormat,
        sample_rate: u32,
        channels: u16,
    },
    VirtualPcm {
        sample_rate: u32,
        channels: u16,
    },
    CpalShared {
        device_id: String,
        sample_rate: u32,
        channels: u16,
    },
    None,
}

pub(crate) const CLOCK_SRC_STREAM_FRAMES: u8 = 0;
pub(crate) const CLOCK_SRC_WASAPI_HARDWARE: u8 = 1;
pub(crate) const CLOCK_SRC_ASIO_HARDWARE: u8 = 2;
pub(crate) const CLOCK_SRC_UNINIT: u8 = 255;

#[inline]
pub(crate) fn backend_to_clock_src(headless: bool, bk: OutputBackendKind) -> u8 {
    if headless {
        CLOCK_SRC_STREAM_FRAMES
    } else if bk == OutputBackendKind::WindowsAsio {
        CLOCK_SRC_ASIO_HARDWARE
    } else if bk == OutputBackendKind::WindowsWasapiExclusive {
        CLOCK_SRC_WASAPI_HARDWARE
    } else {
        CLOCK_SRC_STREAM_FRAMES
    }
}

#[inline]
pub(crate) fn clock_src_to_str(code: u8) -> &'static str {
    match code {
        CLOCK_SRC_ASIO_HARDWARE => "asio_hardware",
        CLOCK_SRC_WASAPI_HARDWARE => "wasapi_hardware",
        _ => "stream_frames",
    }
}

#[allow(clippy::large_enum_variant)]
pub(crate) enum NativeOutputSession {
    #[cfg(target_os = "windows")]
    WasapiExclusive(crate::backend::wasapi_win::WasapiExclusiveSession),
    #[cfg(target_os = "windows")]
    AsioNative(crate::backend::asio_win::AsioNativeSession),
    VirtualWire(JoinHandle<()>),
}

impl NativeOutputSession {
    pub(crate) fn set_paused(&self, paused: bool) {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.set_paused(paused),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.set_paused(paused),
            Self::VirtualWire(_) => {}
        }
    }

    pub(crate) fn flush(&self) -> Result<(), BackendError> {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.flush(),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => {
                if s.flush() {
                    Ok(())
                } else {
                    Err(BackendError::DriverError("ASIO flush failed".into()))
                }
            }
            Self::VirtualWire(_) => Ok(()),
        }
    }

    #[allow(dead_code)]
    pub(crate) fn is_device_lost(&self) -> bool {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.is_device_lost(),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.is_device_lost(),
            Self::VirtualWire(_) => false,
        }
    }

    pub(crate) fn set_eof_state_code(&self, code: i32) {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.set_eof_state_code(code),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.set_eof_target_state(code),
            Self::VirtualWire(_) => {}
        }
    }

    pub(crate) fn stop_and_join(self) {
        match self {
            #[cfg(target_os = "windows")]
            Self::WasapiExclusive(s) => s.stop(),
            #[cfg(target_os = "windows")]
            Self::AsioNative(s) => s.stop(),
            Self::VirtualWire(h) => {
                let _ = h.join();
            }
        }
    }
}

pub(crate) struct PipelineSpec {
    pub(crate) session_id: u64,
    pub(crate) pcm_rate: u32,
    pub(crate) out_channels: u16,
    pub(crate) path: PathBuf,
    pub(crate) source_label: String,
    pub(crate) origin: PlayerOrigin,
    pub(crate) track_meta: Option<DeckTrackMetadata>,
    pub(crate) cancel_token: CancellationToken,
    pub(crate) format: AudioFormat,
    pub(crate) duration_ms: u64,
    pub(crate) start_paused: bool,
}

pub(crate) fn resolve_target_capabilities(
    inner: &PlayerInner,
    sel_id: Option<&str>,
    sel_backend: Option<OutputBackendKind>,
) -> AudioDeviceCapabilities {
    if inner.headless || sel_id == Some(VIRTUAL_DEVICE_ID) {
        return AudioDeviceManager::virtual_device_capabilities();
    }
    let caps = AudioDeviceManager::list_devices();
    if caps.is_empty() {
        return AudioDeviceManager::virtual_device_capabilities();
    }

    let eff_backend = sel_backend.or_else(|| {
        sel_id.and_then(|s| {
            if s.starts_with("wasapi-shared::") {
                Some(OutputBackendKind::WindowsWasapiShared)
            } else if s.starts_with("asio::") {
                Some(OutputBackendKind::WindowsAsio)
            } else {
                None
            }
        })
    });

    if eff_backend == Some(OutputBackendKind::WindowsAsio)
        || sel_id.is_some_and(|s| s.starts_with("asio::"))
    {
        if let Some(id) = sel_id
            && let Some(found) = caps.iter().find(|c| {
                c.backend == OutputBackendKind::WindowsAsio && (c.device_id == id || c.name == id)
            })
        {
            return found.clone();
        }
        if let Some(asio) = caps
            .iter()
            .find(|c| c.backend == OutputBackendKind::WindowsAsio && c.asio_available)
        {
            return asio.clone();
        }
    }

    if let Some(id) = sel_id {
        let raw_id = AudioDeviceManager::strip_mode_prefix(id);
        // 1. Exact (id + backend) match
        if let Some(bk) = eff_backend
            && let Some(found) = caps.iter().find(|c| {
                c.backend == bk
                    && (c.device_id == id
                        || AudioDeviceManager::strip_mode_prefix(&c.device_id) == raw_id
                        || raw_id.contains(AudioDeviceManager::strip_mode_prefix(&c.device_id))
                        || c.name == id)
            })
        {
            return found.clone();
        }
        // 2. General id match when backend wasn't specified
        if eff_backend.is_none()
            && let Some(found) = caps.iter().find(|c| {
                c.device_id == id
                    || AudioDeviceManager::strip_mode_prefix(&c.device_id) == raw_id
                    || raw_id.contains(AudioDeviceManager::strip_mode_prefix(&c.device_id))
                    || c.name == id
            })
        {
            return found.clone();
        }
        // 3. Match via cpal device description name when sel_id came from enumerate_cpal_devices()
        let cpal_name = enumerate_cpal_devices()
            .into_iter()
            .find(|d| d.id == id)
            .map(|d| d.name);
        if let Some(ref name) = cpal_name
            && let Some(found) = caps
                .iter()
                .find(|c| c.name == *name && eff_backend.is_none_or(|bk| c.backend == bk))
        {
            return found.clone();
        }
    }

    if let Some(bk) = eff_backend
        && let Some(found) = caps.iter().find(|c| c.backend == bk && c.is_default)
    {
        return found.clone();
    }

    caps.iter()
        .find(|c| c.is_default)
        .or_else(|| caps.first())
        .cloned()
        .unwrap_or_else(AudioDeviceManager::virtual_device_capabilities)
}

pub(crate) fn patched_track_meta(snap: &DeckMetadataSnapshot) -> Option<DeckTrackMetadata> {
    snap.track_meta.as_ref().map(|m| {
        let mut copy = m.clone();
        if snap.duration_ms > 0 {
            copy.duration_ms = snap.duration_ms;
        }
        copy
    })
}

pub(crate) fn commit_deck_metadata_to_inner(inner: &PlayerInner, snap: &DeckMetadataSnapshot) {
    inner.duration_ms.store(snap.duration_ms, Ordering::SeqCst);
    inner.out_sample_rate.store(snap.out_rate, Ordering::SeqCst);
    inner
        .published_format_stamp
        .store(snap.expected_stamp, Ordering::Release);
    if let Ok(mut rg_lock) = inner.track_replay_gain.write() {
        *rg_lock = snap.rg_tags.clone();
    }
    inner.dsp_generation.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut spec_lock) = inner.active_source_spec.write() {
        *spec_lock = snap.origin.source_spec().cloned();
    }
    if let Ok(mut vw) = inner.verification.write() {
        *vw = Some((
            snap.verification.clone(),
            snap.api_label.clone(),
            snap.device_name.clone(),
        ));
    }
    let resolved_track_meta = patched_track_meta(snap);
    if let Ok(mut meta_lock) = inner.active_meta.write() {
        *meta_lock = Some(ActiveTrackMeta {
            path: snap.path.clone(),
            source_label: snap.source_label.clone(),
            format: snap.format.clone(),
            duration_ms: snap.duration_ms,
            resampled_to_hz: snap.resampled_to_hz,
            backend: snap.backend,
            device_name: snap.device_name.clone(),
            track_meta: resolved_track_meta.clone(),
        });
    }
    if let Ok(mut tm_lock) = inner.active_track_metadata.write() {
        *tm_lock = resolved_track_meta;
    }
}

#[allow(dead_code)]
pub(super) fn _unused_spec_ref(_: &StreamSourceSpec) {}
