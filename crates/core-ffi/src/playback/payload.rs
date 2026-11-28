use core_types::{DeckTrackMetadata, StreamSourceSpec};
use std::collections::HashMap;

pub(super) const ADAPTIVE_RAPID_WINDOW_MS: u64 = 300;
pub(super) const ADAPTIVE_DEBOUNCE_MS: u64 = 130;

pub(super) fn demo_track_default_duration_ms(track_id: &str) -> u64 {
    match track_id {
        "trk-001" => 245_000,
        "trk-002" => 232_000,
        "trk-003" => 382_000,
        "am-001" => 248_000,
        "ytm-001" => 222_000,
        "dz-001" => 369_000,
        _ => 245_000,
    }
}

pub(super) fn is_http_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

pub(super) fn first_non_empty_str(val: &serde_json::Value, keys: &[&str]) -> Option<String> {
    for &k in keys {
        if let Some(s) = val.get(k).and_then(|v| v.as_str()) {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn infer_provider_id(
    track_id: Option<&str>,
    source: Option<&str>,
    has_local_file: bool,
) -> Option<String> {
    if let Some(tid) = track_id {
        let lower = tid.trim().to_ascii_lowercase();
        if lower.starts_with("youtube_music:")
            || lower.starts_with("ytm:")
            || lower.starts_with("ytm_")
            || lower.starts_with("ytm-")
        {
            return Some("youtube_music".to_string());
        }
        if lower.starts_with("qobuz:") || lower.starts_with("qb:") || lower.starts_with("qb-") {
            return Some("qobuz".to_string());
        }
        if lower.starts_with("tidal:") || lower.starts_with("td:") || lower.starts_with("td-") {
            return Some("tidal".to_string());
        }
        if lower.starts_with("deezer:") || lower.starts_with("dz:") || lower.starts_with("dz-") {
            return Some("deezer".to_string());
        }
        if lower.starts_with("apple_music:")
            || lower.starts_with("apple:")
            || lower.starts_with("am:")
            || lower.starts_with("am-")
        {
            return Some("apple_music".to_string());
        }
        if lower.starts_with("podcast_rss:") || lower.starts_with("rss:") {
            return Some("podcast_rss".to_string());
        }
        if lower.starts_with("smb:") {
            return Some("smb".to_string());
        }
        if lower.starts_with("webdav:") || lower.starts_with("web_dav:") {
            return Some("web_dav".to_string());
        }
        if lower.starts_with("local:") {
            return Some("local".to_string());
        }
    }
    if let Some(src) = source {
        let lower = src.trim().to_ascii_lowercase();
        if lower.contains("youtube") || lower == "ytm" {
            return Some("youtube_music".to_string());
        }
        if lower.contains("qobuz") {
            return Some("qobuz".to_string());
        }
        if lower.contains("tidal") {
            return Some("tidal".to_string());
        }
        if lower.contains("deezer") {
            return Some("deezer".to_string());
        }
        if lower.contains("apple") {
            return Some("apple_music".to_string());
        }
        if lower.contains("podcast") {
            return Some("podcast_rss".to_string());
        }
        if lower.contains("smb") {
            return Some("smb".to_string());
        }
        if lower.contains("webdav") || lower.contains("web_dav") {
            return Some("web_dav".to_string());
        }
        if lower.contains("local") {
            return Some("local".to_string());
        }
    }
    if has_local_file {
        return Some("local".to_string());
    }
    None
}

pub fn parse_deck_track_metadata(
    raw: &str,
    fallback_spec: Option<&StreamSourceSpec>,
) -> Option<DeckTrackMetadata> {
    let trimmed = raw.trim();
    if let Ok(val) = serde_json::from_str::<serde_json::Value>(trimmed) {
        let parsed_spec: Option<StreamSourceSpec> = if fallback_spec.is_none() {
            val.get("source_spec")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
        } else {
            None
        };
        let eff_spec = fallback_spec.or(parsed_spec.as_ref());

        let track_id =
            first_non_empty_str(&val, &["track_id", "id", "external_track_id"]).or_else(|| {
                eff_spec
                    .map(|s| s.key().track_id.trim().to_string())
                    .filter(|s| !s.is_empty())
            });
        let source_hint = first_non_empty_str(&val, &["source"]);
        let has_local_file = first_non_empty_str(&val, &["file_path", "path"]).is_some()
            || matches!(eff_spec, Some(StreamSourceSpec::LocalFile { .. }));
        let provider_id = first_non_empty_str(&val, &["provider_id", "provider"])
            .or_else(|| {
                eff_spec
                    .map(|s| s.key().provider_id.trim().to_string())
                    .filter(|s| !s.is_empty())
            })
            .or_else(|| {
                infer_provider_id(track_id.as_deref(), source_hint.as_deref(), has_local_file)
            })
            .unwrap_or_default();

        let title = first_non_empty_str(&val, &["title"]).unwrap_or_default();
        let artist = first_non_empty_str(&val, &["artist", "album_artist"]).unwrap_or_default();
        let album = first_non_empty_str(&val, &["album"]).unwrap_or_default();
        let cover_url = first_non_empty_str(&val, &["cover_url", "album_art_url", "artwork_url"]);
        let duration_ms = val.get("duration_ms").and_then(|v| v.as_u64()).unwrap_or(0);

        if track_id.is_none()
            && title.is_empty()
            && artist.is_empty()
            && album.is_empty()
            && cover_url.is_none()
        {
            return None;
        }

        return Some(DeckTrackMetadata {
            track_id: track_id.unwrap_or_default(),
            provider_id,
            title,
            artist,
            album,
            cover_url,
            duration_ms,
        });
    }

    if !trimmed.is_empty() && !trimmed.contains('{') {
        let track_id = fallback_spec
            .map(|s| s.key().track_id.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| trimmed.to_string());
        let provider_id = fallback_spec
            .map(|s| s.key().provider_id.trim().to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| infer_provider_id(Some(&track_id), None, !is_http_url(trimmed)))
            .unwrap_or_default();
        return Some(DeckTrackMetadata {
            track_id,
            provider_id,
            ..Default::default()
        });
    }

    fallback_spec.map(|spec| DeckTrackMetadata {
        track_id: spec.key().track_id.clone(),
        provider_id: spec.key().provider_id.clone(),
        ..Default::default()
    })
}

pub(super) fn parse_headers_field(val: &serde_json::Value) -> HashMap<String, String> {
    let Some(obj) = val
        .get("headers")
        .or_else(|| val.get("http_headers"))
        .and_then(|v| v.as_object())
    else {
        return HashMap::new();
    };
    obj.iter()
        .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
        .collect()
}

pub(super) struct ParsedPayloadHints {
    pub(super) caller_epoch: Option<u64>,
    pub(super) debounced: bool,
    pub(super) duration_ms: u64,
    pub(super) source_spec: Option<StreamSourceSpec>,
    pub(super) source_label: String,
}

pub(super) fn default_label_for_source_spec(spec: &StreamSourceSpec, fallback: &str) -> String {
    if fallback != "Local Library" {
        return fallback.to_string();
    }
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

pub(super) fn parse_payload_hints(raw: &str) -> Result<ParsedPayloadHints, String> {
    let mut source_label = "Local Library".to_string();
    let Ok(val) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Ok(ParsedPayloadHints {
            caller_epoch: None,
            debounced: false,
            duration_ms: 0,
            source_spec: None,
            source_label,
        });
    };
    if let Some(src) = val
        .get("source")
        .or_else(|| val.get("provider"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|v| !v.is_empty())
    {
        source_label = src.to_string();
    }
    let caller_epoch = val
        .get("playback_epoch")
        .or_else(|| val.get("playbackEpoch"))
        .or_else(|| val.get("epoch"))
        .and_then(|v| v.as_u64())
        .filter(|&e| e > 0);
    let debounced = val
        .get("debounced")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let duration_ms = val.get("duration_ms").and_then(|v| v.as_u64()).unwrap_or(0);
    let source_spec = match val.get("source_spec") {
        Some(spec_val) if !spec_val.is_null() => {
            let spec: StreamSourceSpec = serde_json::from_value(spec_val.clone())
                .map_err(|e| format!("Invalid source_spec payload: {e}"))?;
            if let StreamSourceSpec::ExternalBackend {
                key, provider_id, ..
            } = &spec
            {
                return Err(format!(
                    "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                    key.track_id
                ));
            }
            Some(spec)
        }
        _ => None,
    };
    Ok(ParsedPayloadHints {
        caller_epoch,
        debounced,
        duration_ms,
        source_spec,
        source_label,
    })
}
