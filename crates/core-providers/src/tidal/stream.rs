use std::collections::BTreeMap;

use async_trait::async_trait;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use core_types::{
    AudioCodec, AudioFormat, ManifestFormat, NormalizedLoudness, ProviderKind, StreamKey,
    StreamProviderCapabilities, StreamSourceSpec, TrackSource,
};

use super::client::TidalProvider;
use super::models::{TidalBtsDecoded, TidalBtsManifest};
use crate::error::ProviderError;
use crate::traits::{
    ResolvedStream, StreamResolver, extract_expire_at_from_url, validate_stream_key,
};

fn decode_base64_padded(raw: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let mut cleaned: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
    let rem = cleaned.len() % 4;
    if rem != 0 {
        cleaned.extend(std::iter::repeat_n('=', 4 - rem));
    }
    STANDARD.decode(cleaned)
}

fn parse_tidal_bts_manifest(manifest_b64: &str) -> Result<TidalBtsDecoded, ProviderError> {
    let decoded = decode_base64_padded(manifest_b64).map_err(|e| {
        ProviderError::StreamResolutionFailed(format!(
            "Failed to decode Tidal BTS manifest base64: {e}"
        ))
    })?;
    let bts: TidalBtsManifest = serde_json::from_slice(&decoded).map_err(|e| {
        ProviderError::StreamResolutionFailed(format!(
            "Failed to parse Tidal BTS manifest JSON: {e}"
        ))
    })?;
    if let Some(ref enc) = bts.encryption_type {
        if !enc.trim().is_empty() && !enc.eq_ignore_ascii_case("NONE") {
            return Err(ProviderError::DrmRestricted(format!(
                "Tidal BTS manifest encrypted ({enc})"
            )));
        }
    }
    let mut codec_override = None;
    let mut hint_ext = None;
    if let Some(ref mt) = bts.mime_type {
        if mt.contains("mp4")
            || mt.contains("aac")
            || bts.codecs.as_deref().is_some_and(|c| c.starts_with("mp4a"))
        {
            codec_override = Some(AudioCodec::Aac);
            hint_ext = Some("m4a".to_string());
        } else if mt.contains("flac") {
            codec_override = Some(AudioCodec::Flac);
            hint_ext = Some("flac".to_string());
        }
    }
    let stream_url = bts
        .urls
        .into_iter()
        .find(|s| !s.trim().is_empty())
        .ok_or_else(|| {
            ProviderError::StreamResolutionFailed(
                "Tidal BTS manifest contains no stream URLs".to_string(),
            )
        })?;
    Ok(TidalBtsDecoded {
        stream_url,
        codec_override,
        hint_ext,
        mime_type: bts.mime_type,
    })
}

fn has_dash_content_protection(mpd_xml: &str) -> bool {
    let lower = mpd_xml.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    let needle = "contentprotection";
    let mut idx = 0;
    while let Some(pos) = lower[idx..].find(needle) {
        let abs = idx + pos;
        let before_is_tag = abs > 0 && (bytes[abs - 1] == b'<' || bytes[abs - 1] == b':');
        let after = abs + needle.len();
        let after_ok = after >= bytes.len()
            || bytes[after].is_ascii_whitespace()
            || bytes[after] == b'>'
            || bytes[after] == b'/';
        if before_is_tag && after_ok {
            return true;
        }
        idx = after;
    }
    false
}

fn tidal_audio_quality(quality_key: &str, default_quality: &str) -> Result<String, ProviderError> {
    let normalized = quality_key.trim().to_ascii_lowercase();
    let mapped = match normalized.as_str() {
        "" | "default" | "auto" => default_quality.to_string(),
        "hi_res_lossless" | "hi_res" | "hires" | "hi_res_192" | "hi_res_96" | "max" | "best" => {
            "HI_RES_LOSSLESS".to_string()
        }
        "lossless" | "flac" | "cd" => "LOSSLESS".to_string(),
        "high" | "aac_320" | "320" => "HIGH".to_string(),
        "low" | "aac_96" => "LOW".to_string(),
        _ => {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Unsupported Tidal quality key: '{quality_key}'"
            )));
        }
    };
    Ok(mapped)
}

fn tidal_quality_fallback_chain(requested: &str) -> Vec<&'static str> {
    match requested {
        "HI_RES_LOSSLESS" | "HI_RES" => vec!["HI_RES_LOSSLESS", "LOSSLESS", "HIGH", "LOW"],
        "LOSSLESS" => vec!["LOSSLESS", "HIGH", "LOW"],
        "HIGH" => vec!["HIGH", "LOW"],
        "LOW" => vec!["LOW"],
        _ => vec!["LOSSLESS", "HIGH", "LOW"],
    }
}

pub(super) fn audio_format_for_tidal_quality(
    quality: Option<&str>,
    sample_rate_override: Option<u32>,
    bit_depth_override: Option<u8>,
) -> Result<AudioFormat, ProviderError> {
    let (default_codec, default_sr, default_bd) = match quality.unwrap_or("LOSSLESS") {
        "HI_RES_LOSSLESS" | "HI_RES" => (AudioCodec::Flac, 96000, 24),
        "LOSSLESS" => (AudioCodec::Flac, 44100, 16),
        "HIGH" | "LOW" => (AudioCodec::Aac, 44100, 16),
        _ => (AudioCodec::Flac, 44100, 16),
    };
    let sr = sample_rate_override.unwrap_or(default_sr);
    let bd = bit_depth_override.unwrap_or(default_bd);
    Ok(AudioFormat::pcm(default_codec, sr, bd, 2)?)
}

impl TidalProvider {
    pub(super) async fn resolve_legacy_stream(
        &self,
        track: &TrackSource,
    ) -> Result<ResolvedStream, ProviderError> {
        if track.provider != ProviderKind::Tidal {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Cannot resolve non-Tidal track on TidalProvider: {}",
                track.provider
            )));
        }

        let audio_quality = self.config.read().await.audio_quality.clone();
        let (info, auth_header) = self
            .fetch_playback_info(&track.external_track_id, &audio_quality)
            .await?;

        let mut codec_override: Option<AudioCodec> = None;
        let mut hint_ext: Option<String> = None;
        let stream_url = if let Some(u) = info.url.filter(|s| !s.trim().is_empty()) {
            u
        } else if let Some(u) = info.urls.into_iter().find(|s| !s.trim().is_empty()) {
            u
        } else if let Some(manifest_b64) = info.manifest.filter(|s| !s.trim().is_empty()) {
            let mime = info.manifest_mime_type.as_deref().unwrap_or("");
            if mime.eq_ignore_ascii_case("application/dash+xml") {
                return Err(ProviderError::DrmRestricted(
                    "Encrypted/segmented Tidal DASH manifest is not directly streamable"
                        .to_string(),
                ));
            }
            let bts = parse_tidal_bts_manifest(&manifest_b64)?;
            codec_override = bts.codec_override;
            hint_ext = bts.hint_ext;
            bts.stream_url
        } else {
            return Err(ProviderError::StreamResolutionFailed(
                "Tidal playbackinfo missing both stream URL and manifest".to_string(),
            ));
        };

        let mut format = audio_format_for_tidal_quality(
            info.audio_quality.as_deref(),
            info.sample_rate,
            info.bit_depth,
        )?;
        if let Some(c) = codec_override {
            let bd = if c == AudioCodec::Aac {
                16
            } else {
                format.bit_depth
            };
            format = AudioFormat::pcm(c, format.sample_rate_hz, bd, format.channels)?;
        }
        if hint_ext.is_none() {
            hint_ext = Some(format.codec.default_file_extension().to_string());
        }

        let mut resolved = ResolvedStream::http_stream(
            stream_url,
            format,
            vec![("Authorization".to_string(), auth_header)],
            hint_ext,
        );
        resolved = resolved
            .with_replay_gain(
                info.track_replay_gain,
                info.album_replay_gain,
                info.track_peak_amplitude,
                info.album_peak_amplitude,
            )
            .with_replay_gain_from_track(track);

        Ok(resolved)
    }

    async fn resolve_source_for_quality(
        &self,
        key: &StreamKey,
        requested_quality: &str,
    ) -> Result<StreamSourceSpec, ProviderError> {
        let (info, auth_header) = self
            .fetch_playback_info(&key.track_id, requested_quality)
            .await?;

        let headers = BTreeMap::from([("Authorization".to_string(), auth_header)]);
        let loudness = info.track_replay_gain.filter(|g| g.is_finite()).map(|g| {
            NormalizedLoudness::from_replay_gain(
                g as f32,
                info.track_peak_amplitude
                    .filter(|p| p.is_finite())
                    .map(|p| p as f32),
            )
        });
        let album_loudness = info.album_replay_gain.filter(|g| g.is_finite()).map(|g| {
            NormalizedLoudness::from_replay_gain(
                g as f32,
                info.album_peak_amplitude
                    .filter(|p| p.is_finite())
                    .map(|p| p as f32),
            )
        });

        if let Some(u) = info
            .url
            .filter(|s| !s.trim().is_empty())
            .or_else(|| info.urls.into_iter().find(|s| !s.trim().is_empty()))
        {
            let format = audio_format_for_tidal_quality(
                info.audio_quality.as_deref().or(Some(requested_quality)),
                info.sample_rate,
                info.bit_depth,
            )?;
            let hint_ext = format.codec.default_file_extension().to_string();
            let mime_type = if format.codec == AudioCodec::Aac {
                "audio/mp4"
            } else {
                "audio/flac"
            };
            let expire_at = extract_expire_at_from_url(&u);
            return Ok(StreamSourceSpec::DirectRange {
                key: key.clone(),
                url: u,
                headers,
                content_length: None,
                bitrate_bps: None,
                mime_type: Some(mime_type.to_string()),
                hint_extension: Some(hint_ext),
                expire_at,
                init_range_end: None,
                index_range_start: None,
                index_range_end: None,
                loudness,
                album_loudness,
            });
        }

        let manifest_b64 = info
            .manifest
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| {
                ProviderError::StreamResolutionFailed(
                    "Tidal playbackinfo missing both stream URL and manifest".to_string(),
                )
            })?;

        let manifest_mime = info.manifest_mime_type.as_deref().unwrap_or("").trim();
        if manifest_mime.eq_ignore_ascii_case("application/dash+xml") {
            let decoded = decode_base64_padded(&manifest_b64).map_err(|e| {
                ProviderError::StreamResolutionFailed(format!(
                    "Failed to decode Tidal DASH manifest base64: {e}"
                ))
            })?;
            let decoded_mpd_xml = String::from_utf8(decoded).map_err(|e| {
                ProviderError::StreamResolutionFailed(format!(
                    "Tidal DASH manifest is not valid UTF-8 XML: {e}"
                ))
            })?;

            if has_dash_content_protection(&decoded_mpd_xml) {
                return Err(ProviderError::DrmRestricted(
                    "Tidal DASH manifest contains ContentProtection DRM".to_string(),
                ));
            }

            return Ok(StreamSourceSpec::SegmentedManifest {
                key: key.clone(),
                manifest_url_or_xml: decoded_mpd_xml,
                format: ManifestFormat::Dash,
                headers,
                bitrate_bps: None,
                mime_type: Some("application/dash+xml".to_string()),
                expire_at: None,
                loudness,
                album_loudness,
            });
        }

        let bts = parse_tidal_bts_manifest(&manifest_b64)?;
        let format = audio_format_for_tidal_quality(
            info.audio_quality.as_deref().or(Some(requested_quality)),
            info.sample_rate,
            info.bit_depth,
        )?;
        let effective_codec = bts.codec_override.unwrap_or(format.codec);
        let hint_ext = bts
            .hint_ext
            .unwrap_or_else(|| effective_codec.default_file_extension().to_string());
        let mime_type = bts.mime_type.or_else(|| {
            Some(
                if effective_codec == AudioCodec::Aac {
                    "audio/mp4"
                } else {
                    "audio/flac"
                }
                .to_string(),
            )
        });
        let expire_at = extract_expire_at_from_url(&bts.stream_url);

        Ok(StreamSourceSpec::DirectRange {
            key: key.clone(),
            url: bts.stream_url,
            headers,
            content_length: None,
            bitrate_bps: None,
            mime_type,
            hint_extension: Some(hint_ext),
            expire_at,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness,
            album_loudness,
        })
    }
}

#[async_trait]
impl StreamResolver for TidalProvider {
    fn provider_id(&self) -> &'static str {
        "tidal"
    }

    fn capabilities(&self) -> StreamProviderCapabilities {
        StreamProviderCapabilities::tidal()
    }

    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError> {
        validate_stream_key("tidal", key)?;
        let default_quality = self.config.read().await.audio_quality.clone();
        let requested_quality = tidal_audio_quality(&key.quality_key, &default_quality)?;
        let fallback_tiers = tidal_quality_fallback_chain(&requested_quality);

        let mut last_err: Option<ProviderError> = None;
        for tier in fallback_tiers {
            match self.resolve_source_for_quality(key, tier).await {
                Ok(spec) => return Ok(spec),
                Err(err) => {
                    let can_downgrade = matches!(
                        err,
                        ProviderError::StreamResolutionFailed(_)
                            | ProviderError::UnsupportedFormat(_)
                    );
                    if !can_downgrade {
                        return Err(err);
                    }
                    last_err = Some(err);
                }
            }
        }

        Err(last_err.unwrap_or_else(|| {
            ProviderError::StreamResolutionFailed(format!(
                "Tidal failed to resolve track '{}' at any quality tier",
                key.track_id
            ))
        }))
    }
}
