use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use core_types::{
    AudioCodec, AudioFormat, ProviderKind, StreamKey, StreamProviderCapabilities, StreamSourceSpec,
    TrackSource,
};

use super::client::QobuzProvider;
use super::config::{QobuzUserSession, format_ids};
use super::models::{QobuzStreamResponse, normalize_sample_rate, resolve_qobuz_format_id};
use super::transport::HttpRequest;
use crate::error::ProviderError;
use crate::http::endpoint_url;
use crate::traits::{
    ResolvedStream, StreamResolver, extract_expire_at_from_url, validate_stream_key,
};

struct QobuzResolvedPayload {
    stream_url: String,
    format: AudioFormat,
    headers: Vec<(String, String)>,
    hint_ext: &'static str,
    mime_type: Option<String>,
    bitrate_bps: Option<u64>,
}

impl QobuzProvider {
    pub(super) async fn resolve_legacy_stream(
        &self,
        track: &TrackSource,
    ) -> Result<ResolvedStream, ProviderError> {
        if track.provider != ProviderKind::Qobuz {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Cannot resolve non-Qobuz track on QobuzProvider: {}",
                track.provider
            )));
        }

        let session = self.ensure_session().await?;
        let (base_url, app_id, app_secret, default_format_id) = {
            let cfg = self.config.read().await;
            (
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
                cfg.app_secret().map(str::to_string),
                cfg.default_format_id,
            )
        };

        let max_quality = session.max_streaming_quality;
        let requested_format_id = if let Some(explicit_fmt) = default_format_id {
            explicit_fmt
        } else if track.format.sample_rate_hz >= 176400 && max_quality >= format_ids::FLAC_24_192 {
            format_ids::FLAC_24_192
        } else if track.format.sample_rate_hz >= 88200 && max_quality >= format_ids::FLAC_24_96 {
            format_ids::FLAC_24_96
        } else if max_quality >= format_ids::FLAC_16_44 {
            format_ids::FLAC_16_44
        } else {
            format_ids::MP3_320
        };

        let payload = self
            .fetch_stream_for_format(
                &track.external_track_id,
                requested_format_id,
                &session,
                &base_url,
                &app_id,
                app_secret.as_deref(),
            )
            .await?;

        Ok(ResolvedStream::http_stream(
            payload.stream_url,
            payload.format,
            payload.headers,
            Some(payload.hint_ext.to_string()),
        )
        .with_replay_gain_from_track(track))
    }

    async fn fetch_stream_for_format(
        &self,
        track_id: &str,
        requested_format_id: u32,
        session: &QobuzUserSession,
        base_url: &str,
        app_id: &str,
        app_secret: Option<&str>,
    ) -> Result<QobuzResolvedPayload, ProviderError> {
        let url = endpoint_url(base_url, "track/getFileUrl");
        let mut query_params = vec![
            ("track_id".to_string(), track_id.to_string()),
            ("format_id".to_string(), requested_format_id.to_string()),
            ("intent".to_string(), "stream".to_string()),
        ];

        if let Some(secret) = app_secret {
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
                .to_string();
            let sig_payload = format!(
                "trackgetFileUrlformat_id{requested_format_id}intentstreamtrack_id{track_id}{ts}{secret}"
            );
            let sig = md5_hex(sig_payload.as_bytes());
            query_params.push(("request_ts".to_string(), ts));
            query_params.push(("request_sig".to_string(), sig));
        }

        let req = HttpRequest {
            method: "GET".to_string(),
            url,
            headers: vec![
                ("X-App-Id".to_string(), app_id.to_string()),
                (
                    "X-User-Auth-Token".to_string(),
                    session.user_auth_token.clone(),
                ),
            ],
            query_params,
            body: None,
        };

        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found("qobuz", track_id));
        }
        self.map_http_response(&resp, "track/getFileUrl")?;

        let parsed: QobuzStreamResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!("Failed to parse stream response: {e}"))
        })?;

        if parsed.status.as_deref() == Some("error") {
            return Err(ProviderError::StreamResolutionFailed(
                parsed
                    .message
                    .unwrap_or_else(|| "Stream resolution error".to_string()),
            ));
        }

        if let Some(restrictions) = parsed.restrictions {
            if !restrictions.is_empty() {
                return Err(ProviderError::DrmRestricted(format!(
                    "Track restricted: {:?}",
                    restrictions
                )));
            }
        }

        let stream_url = parsed.url.filter(|s| !s.trim().is_empty()).ok_or_else(|| {
            ProviderError::StreamResolutionFailed("Missing stream URL".to_string())
        })?;

        let actual_format_id = parsed.format_id.unwrap_or(requested_format_id);
        let (default_sr, default_bd) = resolve_qobuz_format_id(actual_format_id);
        let sample_rate = parsed
            .sampling_rate
            .as_ref()
            .map(normalize_sample_rate)
            .unwrap_or(default_sr);
        let bit_depth = parsed.bit_depth.unwrap_or(default_bd);

        let codec = if parsed.mime_type.as_deref() == Some("audio/mpeg")
            || actual_format_id == format_ids::MP3_320
        {
            AudioCodec::Mp3
        } else {
            AudioCodec::Flac
        };

        let resolved_format = AudioFormat::pcm(codec, sample_rate, bit_depth, 2)?;
        let hint_ext = if codec == AudioCodec::Mp3 {
            "mp3"
        } else {
            "flac"
        };
        let mime_type = parsed.mime_type.or_else(|| {
            Some(
                if codec == AudioCodec::Mp3 {
                    "audio/mpeg"
                } else {
                    "audio/flac"
                }
                .to_string(),
            )
        });
        let bitrate_bps = if codec == AudioCodec::Mp3 {
            Some(320_000)
        } else {
            None
        };

        Ok(QobuzResolvedPayload {
            stream_url,
            format: resolved_format,
            headers: vec![
                ("X-App-Id".to_string(), app_id.to_string()),
                (
                    "X-User-Auth-Token".to_string(),
                    session.user_auth_token.clone(),
                ),
                ("User-Agent".to_string(), "LuminaAudio/0.1.0".to_string()),
            ],
            hint_ext,
            mime_type,
            bitrate_bps,
        })
    }
}

#[async_trait]
impl StreamResolver for QobuzProvider {
    fn provider_id(&self) -> &'static str {
        "qobuz"
    }

    fn capabilities(&self) -> StreamProviderCapabilities {
        StreamProviderCapabilities::qobuz()
    }

    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError> {
        validate_stream_key("qobuz", key)?;
        let session = self.ensure_session().await?;
        let (base_url, app_id, app_secret, default_format_id) = {
            let cfg = self.config.read().await;
            (
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
                cfg.app_secret().map(str::to_string),
                cfg.default_format_id,
            )
        };

        let candidates = qobuz_format_candidates(
            &key.quality_key,
            session.max_streaming_quality,
            default_format_id,
        )?;

        let mut last_err: Option<ProviderError> = None;
        for fmt_id in candidates {
            match self
                .fetch_stream_for_format(
                    &key.track_id,
                    fmt_id,
                    &session,
                    &base_url,
                    &app_id,
                    app_secret.as_deref(),
                )
                .await
            {
                Ok(payload) => {
                    let headers: BTreeMap<String, String> = payload.headers.into_iter().collect();
                    let expire_at = extract_expire_at_from_url(&payload.stream_url);
                    return Ok(StreamSourceSpec::DirectRange {
                        key: key.clone(),
                        url: payload.stream_url,
                        headers,
                        content_length: None,
                        bitrate_bps: payload.bitrate_bps,
                        mime_type: payload.mime_type,
                        hint_extension: Some(payload.hint_ext.to_string()),
                        expire_at,
                        init_range_end: None,
                        index_range_start: None,
                        index_range_end: None,
                        loudness: None,
                        album_loudness: None,
                    });
                }
                Err(e) => {
                    if matches!(
                        e,
                        ProviderError::AuthenticationFailed(_)
                            | ProviderError::Unauthenticated(_)
                            | ProviderError::RateLimited { .. }
                            | ProviderError::TrackNotFound(_)
                            | ProviderError::DrmRestricted(_)
                    ) {
                        return Err(e);
                    }
                    last_err = Some(e);
                }
            }
        }

        Err(last_err.unwrap_or_else(|| {
            ProviderError::StreamResolutionFailed(
                "Qobuz failed to resolve stream for all quality tiers".to_string(),
            )
        }))
    }
}

fn qobuz_chain_from_format_id(format_id: u32) -> Vec<u32> {
    match format_id {
        format_ids::FLAC_24_192 => vec![
            format_ids::FLAC_24_192,
            format_ids::FLAC_24_96,
            format_ids::FLAC_16_44,
            format_ids::MP3_320,
        ],
        format_ids::FLAC_24_96 => vec![
            format_ids::FLAC_24_96,
            format_ids::FLAC_16_44,
            format_ids::MP3_320,
        ],
        format_ids::FLAC_16_44 => vec![format_ids::FLAC_16_44, format_ids::MP3_320],
        format_ids::MP3_320 => vec![format_ids::MP3_320],
        other => vec![other],
    }
}

fn qobuz_format_candidates(
    quality_key: &str,
    max_quality: u32,
    default_format_id: Option<u32>,
) -> Result<Vec<u32>, ProviderError> {
    let normalized = quality_key.trim().to_ascii_lowercase();
    let chain = match normalized.as_str() {
        "" | "default" | "auto" => {
            if let Some(explicit) = default_format_id {
                qobuz_chain_from_format_id(explicit)
            } else {
                let capped: Vec<u32> = [
                    format_ids::FLAC_24_192,
                    format_ids::FLAC_24_96,
                    format_ids::FLAC_16_44,
                    format_ids::MP3_320,
                ]
                .into_iter()
                .filter(|&id| id <= max_quality)
                .collect();
                if capped.is_empty() {
                    vec![format_ids::MP3_320]
                } else {
                    capped
                }
            }
        }
        "27" | "hi_res_192" | "hires_192" | "24_192" | "24/192" | "flac_24_192" | "hi_res"
        | "hires" | "max" | "best" => vec![
            format_ids::FLAC_24_192,
            format_ids::FLAC_24_96,
            format_ids::FLAC_16_44,
            format_ids::MP3_320,
        ],
        "7" | "hi_res_96" | "hires_96" | "24_96" | "24/96" | "flac_24_96" => vec![
            format_ids::FLAC_24_96,
            format_ids::FLAC_16_44,
            format_ids::MP3_320,
        ],
        "6" | "lossless" | "cd" | "flac" | "flac_16_44" | "16_44" | "16/44" => {
            vec![format_ids::FLAC_16_44, format_ids::MP3_320]
        }
        "5" | "mp3_320" | "mp3" | "high" | "320" => vec![format_ids::MP3_320],
        _ => {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Unsupported Qobuz quality key: '{quality_key}'"
            )));
        }
    };
    Ok(chain)
}

/// Pure-Rust RFC 1321 MD5 digest (hex lowercase) for Qobuz request signing.
pub fn md5_hex(input: &[u8]) -> String {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];

    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut msg = input.to_vec();
    msg.push(0x80);
    while (msg.len() % 64) != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_le_bytes());

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    for chunk in msg.chunks_exact(64) {
        let mut m = [0u32; 16];
        for (i, word) in m.iter_mut().enumerate() {
            let off = i * 4;
            *word =
                u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        }

        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i {
                0..=15 => ((b & c) | ((!b) & d), i),
                16..=31 => ((d & b) | ((!d) & c), (5 * i + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | (!d)), (7 * i) % 16),
            };
            let temp = d;
            d = c;
            c = b;
            let sum = a.wrapping_add(f).wrapping_add(K[i]).wrapping_add(m[g]);
            b = b.wrapping_add(sum.rotate_left(S[i]));
            a = temp;
        }

        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut digest = [0u8; 16];
    digest[0..4].copy_from_slice(&a0.to_le_bytes());
    digest[4..8].copy_from_slice(&b0.to_le_bytes());
    digest[8..12].copy_from_slice(&c0.to_le_bytes());
    digest[12..16].copy_from_slice(&d0.to_le_bytes());

    digest.iter().map(|b| format!("{b:02x}")).collect()
}
