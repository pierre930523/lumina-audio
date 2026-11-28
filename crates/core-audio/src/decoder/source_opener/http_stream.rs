use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use tokio_util::sync::CancellationToken;

use super::local::{infer_extension_from_magic, infer_extension_from_url, open_decoder_for_path};
use crate::decoder::dsd::{DsdiffReader, DsfReader};
use crate::decoder::pcm::{AudioDecoder, SymphoniaDecoder, SynthAudioDecoder};
use crate::error::CoreAudioError;
use crate::stream::{
    HttpRangeMediaSource, StreamOrigin, StreamSource, is_playlist_extension,
    looks_like_playlist_magic, resolve_playlist_url_with_cancel, resolve_playlist_url_with_token,
};

pub fn open_decoder_for_stream(
    stream: &StreamSource,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_stream_cancellable(stream, None, Duration::from_secs(10))
}

pub(crate) fn open_decoder_for_stream_with_token(
    stream: &StreamSource,
    cancel: CancellationToken,
    timeout: Duration,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_stream_impl(stream, Some(cancel), None, timeout)
}

pub fn open_decoder_for_stream_cancellable(
    stream: &StreamSource,
    cancel: Option<Arc<AtomicBool>>,
    timeout: Duration,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    open_decoder_for_stream_impl(stream, None, cancel, timeout)
}

fn open_decoder_for_stream_impl(
    stream: &StreamSource,
    cancel_token: Option<CancellationToken>,
    cancel_flag: Option<Arc<AtomicBool>>,
    timeout: Duration,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let check_cancelled = || -> Result<(), CoreAudioError> {
        if cancel_token.as_ref().is_some_and(|t| t.is_cancelled())
            || cancel_flag
                .as_ref()
                .is_some_and(|flag| flag.load(Ordering::SeqCst))
        {
            Err(
                std::io::Error::new(std::io::ErrorKind::Interrupted, "Stream open cancelled")
                    .into(),
            )
        } else {
            Ok(())
        }
    };
    check_cancelled()?;
    match &stream.origin {
        StreamOrigin::LocalFile(path) => open_decoder_for_path(path),
        StreamOrigin::Http { url, headers } => {
            let deadline = Instant::now() + timeout;
            let remaining = || {
                let rem = deadline.saturating_duration_since(Instant::now());
                if rem.is_zero() {
                    Duration::from_millis(1)
                } else {
                    rem
                }
            };
            let mut media = if let Some(ref tok) = cancel_token {
                HttpRangeMediaSource::open_with_token(url, headers, tok.clone(), remaining())?
            } else {
                HttpRangeMediaSource::open_with_cancel(
                    url,
                    headers,
                    cancel_flag.clone(),
                    remaining(),
                )?
            };
            check_cancelled()?;
            let mut magic = media.read_magic_prefix(32)?;
            check_cancelled()?;
            if looks_like_playlist_magic(&magic) {
                let resolved = if let Some(ref tok) = cancel_token {
                    resolve_playlist_url_with_token(
                        media.resolved_url(),
                        headers,
                        tok.clone(),
                        remaining(),
                    )?
                } else {
                    resolve_playlist_url_with_cancel(
                        media.resolved_url(),
                        headers,
                        cancel_flag.clone(),
                        remaining(),
                    )?
                };
                check_cancelled()?;
                media = if let Some(ref tok) = cancel_token {
                    HttpRangeMediaSource::open_with_token(
                        &resolved,
                        headers,
                        tok.clone(),
                        remaining(),
                    )?
                } else {
                    HttpRangeMediaSource::open_with_cancel(
                        &resolved,
                        headers,
                        cancel_flag.clone(),
                        remaining(),
                    )?
                };
                check_cancelled()?;
                magic = media.read_magic_prefix(32)?;
                check_cancelled()?;
            }

            let ext_hint = stream
                .hint_extension
                .clone()
                .filter(|ext| !is_playlist_extension(ext))
                .or_else(|| {
                    infer_extension_from_url(media.resolved_url())
                        .filter(|ext| !is_playlist_extension(ext))
                })
                .or_else(|| infer_extension_from_magic(&magic).map(str::to_string));

            if magic.starts_with(b"DSD ") || ext_hint.as_deref() == Some("dsf") {
                let reader = DsfReader::new(media)?;
                return Ok(Box::new(reader));
            }
            if (magic.len() >= 12 && &magic[0..4] == b"FRM8" && &magic[8..12] == b"DSD ")
                || matches!(ext_hint.as_deref(), Some("dff" | "dsdiff"))
            {
                let reader = DsdiffReader::new(media)?;
                return Ok(Box::new(reader));
            }

            let content_type = media.content_type().map(str::to_string);
            let decoder = SymphoniaDecoder::from_media_source(
                Box::new(media),
                ext_hint.as_deref(),
                content_type.as_deref(),
            )?;
            Ok(Box::new(decoder))
        }
        StreamOrigin::Synth {
            track_id,
            title,
            duration_ms,
            sample_rate_hz,
            channels,
        } => Ok(Box::new(SynthAudioDecoder::new(
            track_id,
            title,
            *duration_ms,
            *sample_rate_hz,
            *channels,
        ))),
    }
}
