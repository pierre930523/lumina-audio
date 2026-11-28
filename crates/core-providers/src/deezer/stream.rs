use std::collections::BTreeMap;

use async_trait::async_trait;
use core_types::{
    AudioCodec, AudioFormat, DEFAULT_DEEZER_BLOCK_SIZE, DEFAULT_DEEZER_STRIDE, NormalizedLoudness,
    ProviderKind, StreamCipher, StreamKey, StreamProviderCapabilities, StreamSourceSpec,
    TrackSource,
};

use super::client::DeezerProvider;
use super::models::{
    DeezerGwResponse, DeezerMediaResolved, DeezerMediaResponse, DeezerQualityPlan, DeezerSession,
    DeezerSongDataResult, DeezerTrackDto,
};
use crate::error::ProviderError;
use crate::http::{HttpRequest, endpoint_url};
use crate::traits::{
    ResolvedStream, StreamResolver, extract_expire_at_from_url, validate_stream_key,
};

impl DeezerProvider {
    pub(super) async fn resolve_legacy_stream(
        &self,
        track: &TrackSource,
    ) -> Result<ResolvedStream, ProviderError> {
        if track.provider != ProviderKind::Deezer {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Cannot resolve non-Deezer track on DeezerProvider: {}",
                track.provider
            )));
        }

        let sess = self.ensure_session().await?;
        let preferred_formats = if sess.user.can_stream_lossless {
            vec![
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "FLAC" }),
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
            ]
        } else {
            vec![
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
            ]
        };

        let resolved = self
            .fetch_encrypted_media(&sess, &track.external_track_id, preferred_formats)
            .await?;
        let format = AudioFormat::pcm(resolved.codec, 44100, 16, 2)?;

        Ok(ResolvedStream::http_stream(
            resolved.url,
            format,
            vec![("Cookie".to_string(), format!("arl={}", sess.arl))],
            Some(resolved.hint_ext.to_string()),
        )
        .with_replay_gain(resolved.gw_gain_db, None, None, None)
        .with_replay_gain_from_track(track))
    }

    async fn fetch_encrypted_media(
        &self,
        sess: &DeezerSession,
        track_id: &str,
        preferred_formats: Vec<serde_json::Value>,
    ) -> Result<DeezerMediaResolved, ProviderError> {
        let cookie_header = self.build_cookie_header(sess);
        let cfg = self.config.read().await.clone();

        // Optionally query song.getData to obtain TRACK_TOKEN and ReplayGain when api_token is available.
        let mut track_token = track_id.to_string();
        let mut gw_gain_db: Option<f64> = None;

        if let Some(ref api_token) = sess.api_token {
            let song_body = serde_json::json!({ "sng_id": track_id }).to_string();
            let song_req = HttpRequest::post_json(&cfg.gw_base_url, song_body)
                .with_header("Cookie", &cookie_header)
                .with_query("method", "song.getData")
                .with_query("input", "3")
                .with_query("api_version", "1.0")
                .with_query("api_token", api_token);

            if let Ok(song_resp) = self.transport.execute(song_req).await {
                if song_resp.status == 200 {
                    if let Ok(parsed) = serde_json::from_str::<DeezerGwResponse<DeezerSongDataResult>>(
                        &song_resp.body,
                    ) {
                        if let Some(res) = parsed.results {
                            if let Some(tt) = res.track_token.filter(|s| !s.trim().is_empty()) {
                                track_token = tt;
                            }
                            if let Some(g) = res.gain {
                                gw_gain_db = match g {
                                    serde_json::Value::Number(n) => n.as_f64(),
                                    serde_json::Value::String(s) => s.parse::<f64>().ok(),
                                    _ => None,
                                }
                                .filter(|v| v.is_finite());
                            }
                        }
                    }
                }
            }
        }

        let media_payload = serde_json::json!({
            "license_token": sess.license_token.as_deref().unwrap_or(""),
            "media": [{
                "type": "FULL",
                "formats": preferred_formats,
            }],
            "track_tokens": [track_token],
        })
        .to_string();

        let media_req = HttpRequest::post_json(&cfg.media_base_url, media_payload)
            .with_header("Cookie", &cookie_header);

        let resp = self.transport.execute(media_req).await?;
        if resp.status == 401 {
            return Err(ProviderError::AuthenticationFailed(
                "Deezer media endpoint unauthorized (HTTP 401)".to_string(),
            ));
        }
        if resp.status == 403 {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "Deezer media endpoint forbidden (HTTP 403): {}",
                resp.body
            )));
        }
        if resp.status == 429 {
            let retry_after = resp
                .header("retry-after")
                .and_then(crate::resilience::parse_retry_after);
            return Err(ProviderError::rate_limited(
                "Deezer media endpoint rate limited (HTTP 429)",
                retry_after,
            ));
        }
        if resp.status >= 400 {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "Deezer media endpoint failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let parsed: DeezerMediaResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!(
                "Failed to parse Deezer media response: {e}"
            ))
        })?;

        let mut chosen_format_name: Option<String> = None;
        let mut media_exp: Option<u64> = None;
        let mut is_unencrypted = false;
        let stream_url = if let Some(u) = parsed.url.filter(|s| !s.trim().is_empty()) {
            u
        } else if let Some(first) = parsed.data.into_iter().next() {
            let media_was_empty = first.media.is_empty();
            let mut found_media: Option<(Option<String>, Option<u64>, bool, String)> = None;
            for media in first.media {
                if let Some(src) = media.sources.into_iter().find(|s| !s.url.trim().is_empty()) {
                    let unenc = is_deezer_cipher_none(media.cipher.as_ref());
                    found_media = Some((media.format, media.exp, unenc, src.url));
                    break;
                }
            }

            if let Some((fmt_name, exp, unenc, url)) = found_media {
                chosen_format_name = fmt_name;
                media_exp = exp;
                is_unencrypted = unenc;
                url
            } else if let Some(err) = first.errors.into_iter().next() {
                let code = err.code.unwrap_or(0);
                let msg = err.message.unwrap_or_else(|| "Unavailable".to_string());
                if code == 2002 || msg.to_ascii_lowercase().contains("license") {
                    return Err(ProviderError::DrmRestricted(format!(
                        "Deezer track restricted ({code}): {msg}"
                    )));
                }
                return Err(ProviderError::StreamResolutionFailed(format!(
                    "Deezer media error ({code}): {msg}"
                )));
            } else if media_was_empty {
                return Err(ProviderError::StreamResolutionFailed(
                    "Deezer media response contained empty data item".to_string(),
                ));
            } else {
                return Err(ProviderError::StreamResolutionFailed(
                    "Deezer media item contained no source URLs".to_string(),
                ));
            }
        } else {
            return Err(ProviderError::StreamResolutionFailed(
                "Deezer media response missing stream URL".to_string(),
            ));
        };

        let upper_fmt = chosen_format_name
            .as_deref()
            .map(|f| f.to_ascii_uppercase());
        let (codec, hint_ext, mime_type, bitrate_bps) = match upper_fmt.as_deref() {
            Some("MP3_128") => (AudioCodec::Mp3, "mp3", "audio/mpeg", Some(128_000)),
            Some(f) if f.starts_with("MP3") => {
                (AudioCodec::Mp3, "mp3", "audio/mpeg", Some(320_000))
            }
            Some(_) => (AudioCodec::Flac, "flac", "audio/flac", None),
            None if !sess.user.can_stream_lossless => {
                (AudioCodec::Mp3, "mp3", "audio/mpeg", Some(320_000))
            }
            None => (AudioCodec::Flac, "flac", "audio/flac", None),
        };
        let expire_at = media_exp.or_else(|| extract_expire_at_from_url(&stream_url));

        Ok(DeezerMediaResolved {
            url: stream_url,
            codec,
            hint_ext,
            mime_type: mime_type.to_string(),
            bitrate_bps,
            gw_gain_db,
            expire_at,
            is_unencrypted,
        })
    }

    async fn fetch_preview_info(
        &self,
        track_id: &str,
    ) -> Result<(String, Option<NormalizedLoudness>), ProviderError> {
        let api_base = self.config.read().await.api_base_url.clone();
        let url = endpoint_url(&api_base, &format!("track/{track_id}"));
        let mut req = HttpRequest::get(url);
        if let Ok(arl) = self.get_valid_arl().await {
            req = req.with_header("Cookie", format!("arl={arl}"));
        }
        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found("deezer", track_id));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer track preview fetch failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }
        let dto: DeezerTrackDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!(
                "Failed to parse Deezer track response: {e}"
            ))
        })?;
        let loudness = dto
            .gain
            .filter(|g| g.is_finite())
            .map(|g| NormalizedLoudness::from_deezer_gain(g as f32));
        let preview_url = dto
            .preview
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                ProviderError::StreamResolutionFailed(format!(
                    "Deezer track '{track_id}' has no preview stream URL"
                ))
            })?;
        Ok((preview_url, loudness))
    }

    async fn resolve_preview_source(
        &self,
        key: &StreamKey,
    ) -> Result<StreamSourceSpec, ProviderError> {
        let (preview_url, loudness) = self.fetch_preview_info(&key.track_id).await?;
        let expire_at = extract_expire_at_from_url(&preview_url);
        Ok(StreamSourceSpec::DirectRange {
            key: key.clone(),
            url: preview_url,
            headers: BTreeMap::new(),
            content_length: None,
            bitrate_bps: Some(128_000),
            mime_type: Some("audio/mpeg".to_string()),
            hint_extension: Some("mp3".to_string()),
            expire_at,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness,
            album_loudness: None,
        })
    }
}

fn is_deezer_cipher_none(cipher: Option<&serde_json::Value>) -> bool {
    match cipher {
        Some(serde_json::Value::String(s)) => s.trim().eq_ignore_ascii_case("NONE"),
        Some(serde_json::Value::Object(map)) => map
            .get("type")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s.trim().eq_ignore_ascii_case("NONE")),
        _ => false,
    }
}

fn deezer_quality_plan(
    quality_key: &str,
    can_stream_lossless: bool,
    can_stream_hq: bool,
) -> Result<DeezerQualityPlan, ProviderError> {
    let normalized = quality_key.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "preview" => Ok(DeezerQualityPlan::PreviewOnly),
        "" | "default" | "auto" | "flac" | "lossless" | "hi_res" | "hires" | "max" | "best" => {
            if can_stream_lossless {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "FLAC" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else if can_stream_hq {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else {
                Ok(DeezerQualityPlan::PreviewOnly)
            }
        }
        "mp3_320" | "mp3" | "high" | "320" => {
            if can_stream_hq || can_stream_lossless {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else {
                Ok(DeezerQualityPlan::PreviewOnly)
            }
        }
        "mp3_128" | "low" | "128" => {
            if can_stream_hq || can_stream_lossless {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else {
                Ok(DeezerQualityPlan::PreviewOnly)
            }
        }
        _ => Err(ProviderError::UnsupportedFormat(format!(
            "Unsupported Deezer quality key: '{quality_key}'"
        ))),
    }
}

#[async_trait]
impl StreamResolver for DeezerProvider {
    fn provider_id(&self) -> &'static str {
        "deezer"
    }

    fn capabilities(&self) -> StreamProviderCapabilities {
        StreamProviderCapabilities::deezer()
    }

    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError> {
        validate_stream_key("deezer", key)?;

        if key.quality_key.trim().eq_ignore_ascii_case("preview") {
            return self.resolve_preview_source(key).await;
        }

        // Validate quality_key syntax up front before any session/network fallback.
        let _ = deezer_quality_plan(&key.quality_key, true, true)?;

        let sess = match self.ensure_session().await {
            Ok(s) => s,
            Err(ProviderError::Unauthenticated(unauth_msg)) => {
                if let Ok(spec) = self.resolve_preview_source(key).await {
                    return Ok(spec);
                }
                return Err(ProviderError::Unauthenticated(unauth_msg));
            }
            Err(e) => return Err(e),
        };

        let plan = deezer_quality_plan(
            &key.quality_key,
            sess.user.can_stream_lossless,
            sess.user.can_stream_hq,
        )?;

        match plan {
            DeezerQualityPlan::PreviewOnly => self.resolve_preview_source(key).await,
            DeezerQualityPlan::Full(preferred_formats) => {
                match self
                    .fetch_encrypted_media(&sess, &key.track_id, preferred_formats)
                    .await
                {
                    Ok(media) => {
                        let headers =
                            BTreeMap::from([("Cookie".to_string(), format!("arl={}", sess.arl))]);
                        let loudness = media
                            .gw_gain_db
                            .filter(|g| g.is_finite())
                            .map(|g| NormalizedLoudness::from_deezer_gain(g as f32));
                        if media.is_unencrypted {
                            Ok(StreamSourceSpec::DirectRange {
                                key: key.clone(),
                                url: media.url,
                                headers,
                                content_length: None,
                                bitrate_bps: media.bitrate_bps,
                                mime_type: Some(media.mime_type),
                                hint_extension: Some(media.hint_ext.to_string()),
                                expire_at: media.expire_at,
                                init_range_end: None,
                                index_range_start: None,
                                index_range_end: None,
                                loudness,
                                album_loudness: None,
                            })
                        } else {
                            Ok(StreamSourceSpec::EncryptedRange {
                                key: key.clone(),
                                url: media.url,
                                headers,
                                content_length: None,
                                bitrate_bps: media.bitrate_bps,
                                mime_type: Some(media.mime_type),
                                hint_extension: Some(media.hint_ext.to_string()),
                                cipher: StreamCipher::DeezerBlowfish {
                                    track_id: key.track_id.clone(),
                                    block_size: DEFAULT_DEEZER_BLOCK_SIZE,
                                    stride: DEFAULT_DEEZER_STRIDE,
                                },
                                expire_at: media.expire_at,
                                loudness,
                                album_loudness: None,
                            })
                        }
                    }
                    Err(
                        e @ (ProviderError::AuthenticationFailed(_)
                        | ProviderError::RateLimited { .. }),
                    ) => Err(e),
                    Err(orig_err) => self.resolve_preview_source(key).await.or(Err(orig_err)),
                }
            }
        }
    }
}
