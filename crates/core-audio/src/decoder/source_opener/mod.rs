//! Unified audio source opener & streaming proxy/L2 cache admission layer.
//!
//! Decouples `engine/` from `streaming/` (`L2CacheManager`, `ChunkedStreamProxy`,
//! `SegmentedStreamProxy`, `HybridByteStream`, `HybridSegmentedStream`,
//! `DecryptingByteStream`, `StreamRefreshHandler`).

mod dash;
mod http;
mod http_stream;
mod local;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use core_types::{ManifestFormat, StreamKey, StreamSourceSpec};
use tokio_util::sync::CancellationToken;

use crate::decoder::pcm::{AudioDecoder, SymphoniaDecoder};
use crate::error::{CoreAudioError, DecoderError};
use crate::streaming::{FormatMismatchCallback, L2CacheManager, StreamError, StreamRefreshHandler};

pub(crate) use http_stream::open_decoder_for_stream_with_token;
pub use http_stream::{open_decoder_for_stream, open_decoder_for_stream_cancellable};
pub use local::{infer_extension_from_magic, open_decoder_for_path};

pub type OpenedStreamDecoder = Box<dyn AudioDecoder>;

/// Callback probed off-RT by L2 admission tasks to verify the track is still actively
/// playing before committing a `.head` entry. Returns `None` if playback stopped/dropped,
/// or `Some((is_actively_playing_this_key, position_ms))`.
pub(crate) type L2PlayGateProbe = Arc<dyn Fn(&StreamKey) -> Option<(bool, u64)> + Send + Sync>;

pub(crate) fn source_spec_display_path(spec: &StreamSourceSpec) -> PathBuf {
    match spec {
        StreamSourceSpec::DirectRange { url, .. }
        | StreamSourceSpec::EncryptedRange { url, .. } => PathBuf::from(url),
        StreamSourceSpec::SegmentedManifest {
            manifest_url_or_xml,
            key,
            ..
        } => {
            if manifest_url_or_xml.trim_start().starts_with('<') {
                PathBuf::from(format!(
                    "dash://{}:{}:{}",
                    key.provider_id, key.track_id, key.quality_key
                ))
            } else {
                PathBuf::from(manifest_url_or_xml)
            }
        }
        StreamSourceSpec::LocalFile { path, .. } => PathBuf::from(path),
        StreamSourceSpec::ExternalBackend { track_uri, .. } => PathBuf::from(track_uri),
    }
}

pub(crate) fn source_spec_default_label(spec: &StreamSourceSpec) -> String {
    match spec {
        StreamSourceSpec::LocalFile { .. } => "Local Library".to_string(),
        _ => {
            let key = spec.key();
            if key.quality_key.is_empty() {
                key.provider_id.clone()
            } else {
                format!("{} ({})", key.provider_id, key.quality_key)
            }
        }
    }
}

pub(crate) fn provider_needs_network_epoch_reset(provider_id: &str) -> bool {
    crate::network_monitor::NETWORK_EPOCH_RESET_PROVIDERS
        .iter()
        .any(|p| p.eq_ignore_ascii_case(provider_id))
}

pub(crate) fn stream_error_to_core(err: StreamError) -> CoreAudioError {
    match err {
        StreamError::AuthRequired {
            provider_id,
            status,
        } => CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
            provider_id,
            status,
        }),
        StreamError::FormatChanged(spec) => {
            CoreAudioError::Decoder(DecoderError::StreamFormatChanged(spec))
        }
        StreamError::DrmRestricted(msg) | StreamError::Unsupported(msg) => {
            CoreAudioError::UnsupportedFormat(msg)
        }
        StreamError::InvalidManifest(msg) => CoreAudioError::InvalidConfig(msg),
        other => CoreAudioError::Io(other.to_io_error()),
    }
}

/// Synchronously opens a decoder for a declarative [`StreamSourceSpec`] with cooperative
/// [`CancellationToken`] support. Safe to call from OS threads or `tokio::task::spawn_blocking`.
pub fn open_decoder_for_source_spec(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_with_refresh(spec, cancel, None)
}

/// Synchronously opens a decoder for a declarative [`StreamSourceSpec`] with an optional
/// [`StreamRefreshHandler`] attached to range/segmented proxies.
pub fn open_decoder_for_source_spec_with_refresh(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_with_l2(spec, cancel, refresh_handler, None, false, None, None)
}

/// Synchronously opens a decoder for a declarative [`StreamSourceSpec`] with optional L2 cache,
/// bypass control, format mismatch callback, and stable-play admission capture.
///
/// If an expired initial URL triggers HTTP 403/410 self-healing at `offset = 0` before any audio
/// is decoded and the refresh returns a fallback format/length (`StreamFormatChanged`), this
/// function adopts the refreshed spec (bypassing stale L2) up to 2 times seamlessly.
pub(crate) fn open_decoder_for_source_spec_with_l2(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_with_l2_adopted(
        spec,
        cancel,
        refresh_handler,
        l2_manager,
        bypass_l2_read,
        on_mismatch,
        play_gate_probe,
    )
    .map(|(dec, _)| dec)
}

pub(crate) fn open_decoder_for_source_spec_with_l2_adopted(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<(Box<dyn AudioDecoder>, StreamSourceSpec), CoreAudioError> {
    const MAX_INITIAL_FORMAT_ADOPTIONS: usize = 2;
    let mut current_spec = spec.clone();
    let mut current_bypass_l2 = bypass_l2_read;

    for attempt in 0..=MAX_INITIAL_FORMAT_ADOPTIONS {
        match open_decoder_for_source_spec_once(
            &current_spec,
            cancel.clone(),
            refresh_handler.clone(),
            l2_manager.clone(),
            current_bypass_l2,
            on_mismatch.clone(),
            play_gate_probe.clone(),
        ) {
            Err(CoreAudioError::Decoder(DecoderError::StreamFormatChanged(next_spec)))
                if attempt < MAX_INITIAL_FORMAT_ADOPTIONS && !cancel.is_cancelled() =>
            {
                current_spec = *next_spec;
                current_bypass_l2 = true;
            }
            Ok(dec) => return Ok((dec, current_spec)),
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}

pub(crate) async fn open_decoder_for_source_spec_async_with_l2(
    spec: StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError> {
    const MAX_INITIAL_FORMAT_ADOPTIONS: usize = 2;
    let mut current_spec = spec;
    let mut current_bypass_l2 = false;

    for attempt in 0..=MAX_INITIAL_FORMAT_ADOPTIONS {
        if cancel.is_cancelled() {
            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
        }
        let on_mismatch = on_mismatch.clone();
        let play_gate_probe = play_gate_probe.clone();

        let res: Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError> =
            match &current_spec {
                StreamSourceSpec::ExternalBackend {
                    key, provider_id, ..
                } => Err(CoreAudioError::UnsupportedFormat(format!(
                    "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                    key.track_id
                ))),
                StreamSourceSpec::SegmentedManifest {
                    key,
                    manifest_url_or_xml,
                    format,
                    headers,
                    mime_type,
                    ..
                } => {
                    if *format != ManifestFormat::Dash {
                        return Err(CoreAudioError::UnsupportedFormat(
                            "HLS manifest playback is not supported in Phase 1".to_string(),
                        ));
                    }
                    dash::open_dash_spec_async(
                        &current_spec,
                        key,
                        manifest_url_or_xml,
                        headers,
                        mime_type.as_deref(),
                        cancel.clone(),
                        refresh_handler.clone(),
                        l2_manager.clone(),
                        current_bypass_l2,
                        on_mismatch,
                        play_gate_probe,
                    )
                    .await
                }
                _ => {
                    let spec_clone = current_spec.clone();
                    let cancel_clone = cancel.clone();
                    let refresh_clone = refresh_handler.clone();
                    let l2_clone = l2_manager.clone();
                    return tokio::task::spawn_blocking(move || {
                        open_decoder_for_source_spec_with_l2_adopted(
                            &spec_clone,
                            cancel_clone,
                            refresh_clone,
                            l2_clone,
                            current_bypass_l2,
                            on_mismatch,
                            play_gate_probe,
                        )
                    })
                    .await
                    .map_err(|e| {
                        CoreAudioError::Io(std::io::Error::other(format!(
                            "Decoder open task failed: {e}"
                        )))
                    })?;
                }
            };

        match res {
            Err(CoreAudioError::Decoder(DecoderError::StreamFormatChanged(next_spec)))
                if attempt < MAX_INITIAL_FORMAT_ADOPTIONS && !cancel.is_cancelled() =>
            {
                current_spec = *next_spec;
                current_bypass_l2 = true;
            }
            other => return other,
        }
    }
    unreachable!()
}

fn open_decoder_for_source_spec_once(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    match spec {
        StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } => Err(CoreAudioError::UnsupportedFormat(format!(
            "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
            key.track_id
        ))),
        StreamSourceSpec::LocalFile { path, .. } => open_decoder_for_path(Path::new(path)),
        StreamSourceSpec::DirectRange { .. } | StreamSourceSpec::EncryptedRange { .. } => {
            let bridge = http::open_bridge_for_sync_spec(
                spec,
                cancel,
                refresh_handler,
                l2_manager,
                bypass_l2_read,
                on_mismatch,
                play_gate_probe,
            )?;
            let decoder = SymphoniaDecoder::from_blocking_bridge(bridge, spec)?;
            Ok(Box::new(decoder))
        }
        StreamSourceSpec::SegmentedManifest {
            key,
            manifest_url_or_xml,
            format,
            headers,
            mime_type,
            ..
        } => {
            if *format != ManifestFormat::Dash {
                return Err(CoreAudioError::UnsupportedFormat(
                    "HLS manifest playback is not supported in Phase 1".to_string(),
                ));
            }
            dash::open_dash_spec_sync(
                spec,
                key,
                manifest_url_or_xml,
                headers,
                mime_type.as_deref(),
                cancel,
                refresh_handler,
                l2_manager,
                bypass_l2_read,
                on_mismatch,
                play_gate_probe,
            )
        }
    }
}

/// Non-blocking/cancellable async helper that resolves manifests on `STREAMING_RUNTIME` and
/// probes the decoder via `tokio::task::spawn_blocking` without calling `block_on`.
pub async fn open_decoder_for_source_spec_async(
    spec: StreamSourceSpec,
    cancel: CancellationToken,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_async_with_refresh(spec, cancel, None).await
}

/// Non-blocking/cancellable async helper with an optional [`StreamRefreshHandler`] wired into
/// range and DASH segmented proxies.
pub async fn open_decoder_for_source_spec_async_with_refresh(
    spec: StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_source_spec_async_with_l2(spec, cancel, refresh_handler, None, None, None)
        .await
        .map(|(dec, _)| dec)
}
