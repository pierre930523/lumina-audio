use async_trait::async_trait;
use core_types::AudioCodec;
use tokio_util::sync::CancellationToken;

use super::models::{SelectedYtAudio, YtDlpInfoJson};
use crate::error::ProviderError;
use crate::process_guard::{ProcessGuard, ProcessOutput, ProcessSpec};

/// Subprocess execution abstraction whose default implementation delegates directly to
/// [`ProcessGuard::run_capture`].
#[async_trait]
pub trait YtDlpCommandRunner: Send + Sync {
    async fn run(
        &self,
        spec: &ProcessSpec,
        cancel: CancellationToken,
    ) -> Result<ProcessOutput, ProviderError>;
}

/// Default runner executing every subprocess through [`ProcessGuard::run_capture`].
#[derive(Debug, Default)]
pub struct GuardedProcessRunner;

#[async_trait]
impl YtDlpCommandRunner for GuardedProcessRunner {
    async fn run(
        &self,
        spec: &ProcessSpec,
        cancel: CancellationToken,
    ) -> Result<ProcessOutput, ProviderError> {
        ProcessGuard::run_capture(spec, cancel).await
    }
}

pub(super) fn yt_track_url(track_id: &str) -> String {
    let trimmed = track_id.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://music.youtube.com/watch?v={trimmed}")
    }
}

pub(super) fn yt_playlist_url(playlist_id: &str) -> String {
    let trimmed = playlist_id.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://music.youtube.com/playlist?list={trimmed}")
    }
}

pub(super) fn yt_dlp_format_selector(quality: &str) -> &'static str {
    match quality.trim().to_ascii_lowercase().as_str() {
        "" | "default" | "auto" | "best" | "high" | "max" | "opus" | "lossless" => {
            "bestaudio[acodec=opus]/bestaudio/best"
        }
        "aac" | "m4a" | "mp4" => "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio/best",
        "low" | "128" | "saver" => "bestaudio[abr<=128]/worstaudio/bestaudio/best",
        _ => "bestaudio/best",
    }
}

pub(super) fn classify_yt_dlp_error(err: ProviderError) -> ProviderError {
    match err {
        ProviderError::ProcessFailed {
            binary,
            exit_code,
            stderr,
        } => {
            let lower = stderr.to_ascii_lowercase();
            if lower.contains("429") || lower.contains("too many requests") {
                return ProviderError::rate_limited(
                    format!("{binary} rate limited: {stderr}"),
                    None,
                );
            }
            if lower.contains("451")
                || lower.contains("not available in your country")
                || lower.contains("geo-block")
                || lower.contains("geoblock")
                || lower.contains("region")
            {
                return ProviderError::RegionBlocked(format!("{binary} region blocked: {stderr}"));
            }
            if lower.contains("401")
                || lower.contains("sign in to confirm")
                || lower.contains("authentication")
                || lower.contains("cookies are no longer valid")
            {
                return ProviderError::AuthExpired(format!(
                    "{binary} authentication required/expired: {stderr}"
                ));
            }
            if lower.contains("video unavailable")
                || lower.contains("private video")
                || lower.contains("has been removed")
            {
                return ProviderError::TrackUnavailable(format!(
                    "{binary} track unavailable: {stderr}"
                ));
            }
            if lower.contains("502")
                || lower.contains("503")
                || lower.contains("504")
                || lower.contains("timed out")
                || lower.contains("temporary failure")
            {
                return ProviderError::Network(format!(
                    "{binary} transient network failure: {stderr}"
                ));
            }
            ProviderError::ProcessFailed {
                binary,
                exit_code,
                stderr,
            }
        }
        other => other,
    }
}

pub(super) fn parse_yt_dlp_single_json(raw: &str) -> Result<YtDlpInfoJson, ProviderError> {
    let trimmed = raw.trim();
    if let Ok(parsed) = serde_json::from_str::<YtDlpInfoJson>(trimmed) {
        return Ok(parsed);
    }
    for line in trimmed.lines().rev() {
        let candidate = line.trim();
        if candidate.starts_with('{') {
            if let Ok(parsed) = serde_json::from_str::<YtDlpInfoJson>(candidate) {
                return Ok(parsed);
            }
        }
    }
    Err(ProviderError::StreamResolutionFailed(
        "Failed to parse yt-dlp JSON output".to_string(),
    ))
}

pub(super) fn select_best_audio_stream(info: &YtDlpInfoJson) -> Option<SelectedYtAudio> {
    if let Some(url) = info.url.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        return Some(SelectedYtAudio {
            url: url.to_string(),
            headers: info.http_headers.clone().unwrap_or_default(),
            content_length: info.filesize.or(info.filesize_approx),
            bitrate_bps: kbps_to_bps(info.abr.or(info.tbr)),
            ext: info.ext.clone(),
            acodec: info.acodec.clone(),
            mime_type: info.mime_type.clone(),
        });
    }

    let candidate = info
        .requested_formats
        .iter()
        .chain(info.formats.iter())
        .filter(|f| {
            f.url.as_deref().is_some_and(|u| !u.trim().is_empty())
                && f.acodec
                    .as_deref()
                    .is_none_or(|c| !c.eq_ignore_ascii_case("none"))
        })
        .max_by(|a, b| {
            let a_audio_only = a.vcodec.as_deref().is_some_and(|v| v == "none");
            let b_audio_only = b.vcodec.as_deref().is_some_and(|v| v == "none");
            a_audio_only.cmp(&b_audio_only).then_with(|| {
                a.abr
                    .or(a.tbr)
                    .unwrap_or(0.0)
                    .total_cmp(&b.abr.or(b.tbr).unwrap_or(0.0))
            })
        })?;

    Some(SelectedYtAudio {
        url: candidate.url.clone()?,
        headers: candidate
            .http_headers
            .clone()
            .or_else(|| info.http_headers.clone())
            .unwrap_or_default(),
        content_length: candidate.filesize.or(candidate.filesize_approx),
        bitrate_bps: kbps_to_bps(candidate.abr.or(candidate.tbr)),
        ext: candidate.ext.clone().or_else(|| info.ext.clone()),
        acodec: candidate.acodec.clone().or_else(|| info.acodec.clone()),
        mime_type: candidate.mime_type.clone(),
    })
}

fn kbps_to_bps(kbps: Option<f64>) -> Option<u64> {
    kbps.filter(|v| v.is_finite() && *v > 0.0)
        .map(|v| (v * 1000.0).round() as u64)
}

pub(super) fn infer_audio_codec(acodec: Option<&str>, ext: Option<&str>) -> AudioCodec {
    let ac = acodec.unwrap_or("").to_ascii_lowercase();
    if ac.contains("opus") {
        return AudioCodec::Opus;
    }
    if ac.contains("mp4a") || ac.contains("aac") {
        return AudioCodec::Aac;
    }
    if ac.contains("flac") {
        return AudioCodec::Flac;
    }
    match ext.unwrap_or("").to_ascii_lowercase().as_str() {
        "m4a" | "mp4" | "aac" => AudioCodec::Aac,
        "mp3" => AudioCodec::Mp3,
        "flac" => AudioCodec::Flac,
        _ => AudioCodec::Opus,
    }
}

pub(super) fn infer_mime_type(ext: Option<&str>, acodec: Option<&str>) -> Option<String> {
    match ext.unwrap_or("").to_ascii_lowercase().as_str() {
        "webm" => Some(if acodec.is_some_and(|c| c.contains("opus")) {
            "audio/webm; codecs=\"opus\"".to_string()
        } else {
            "audio/webm".to_string()
        }),
        "m4a" | "mp4" => Some("audio/mp4".to_string()),
        "opus" | "ogg" => Some("audio/ogg".to_string()),
        "mp3" => Some("audio/mpeg".to_string()),
        "flac" => Some("audio/flac".to_string()),
        _ => None,
    }
}
