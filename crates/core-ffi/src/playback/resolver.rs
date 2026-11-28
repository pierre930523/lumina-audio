use super::payload::{
    default_label_for_source_spec, demo_track_default_duration_ms, is_http_url,
    parse_headers_field, parse_payload_hints,
};
use crate::engine::EngineState;
use core_audio::StreamSource;
use core_db::LibraryRepository;
use core_types::StreamSourceSpec;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

pub(super) enum ResolvedPlaybackCandidate {
    SourceSpec {
        spec: StreamSourceSpec,
        source_label: String,
    },
    Legacy {
        stream: StreamSource,
        source_label: String,
    },
}

pub(super) async fn resolve_candidate_async(
    engine: &EngineState,
    s: &str,
) -> Result<ResolvedPlaybackCandidate, String> {
    let hints = parse_payload_hints(s)?;
    if let Some(spec) = hints.source_spec {
        let label = default_label_for_source_spec(&spec, &hints.source_label);
        return Ok(ResolvedPlaybackCandidate::SourceSpec {
            spec,
            source_label: label,
        });
    }

    let mut candidate_stream: Option<(StreamSource, String)> = None;
    let source_label = hints.source_label;

    if let Ok(val) = serde_json::from_str::<serde_json::Value>(s) {
        let hint = val
            .get("hint_extension")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let headers = parse_headers_field(&val);

        let explicit_stream_url = val
            .get("stream_url")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|v| !v.is_empty());
        let explicit_file_path = val
            .get("file_path")
            .or_else(|| val.get("path"))
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|v| !v.is_empty());

        if let Some(url) = explicit_stream_url {
            if is_http_url(url) {
                candidate_stream = Some((
                    StreamSource::http(url, headers, hint),
                    if source_label == "Local Library" {
                        "HTTP Stream".to_string()
                    } else {
                        source_label.clone()
                    },
                ));
            } else {
                return Err(format!("Unsupported stream URL: {url}"));
            }
        } else if let Some(fp) = explicit_file_path {
            if is_http_url(fp) {
                candidate_stream = Some((
                    StreamSource::http(fp, headers, hint),
                    if source_label == "Local Library" {
                        "HTTP Stream".to_string()
                    } else {
                        source_label.clone()
                    },
                ));
            } else if Path::new(fp).is_file() {
                candidate_stream = Some((StreamSource::local_file(fp), source_label.clone()));
            } else {
                return Err(format!("Audio file not found: {fp}"));
            }
        } else {
            if let Some(ext_id) = val
                .get("external_track_id")
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|v| !v.is_empty())
            {
                if is_http_url(ext_id) {
                    candidate_stream = Some((
                        StreamSource::http(ext_id, headers, hint),
                        if source_label == "Local Library" {
                            "HTTP Stream".to_string()
                        } else {
                            source_label.clone()
                        },
                    ));
                } else if Path::new(ext_id).is_file() {
                    candidate_stream =
                        Some((StreamSource::local_file(ext_id), source_label.clone()));
                }
            }

            if candidate_stream.is_none()
                && let Some(track_id) = val.get("id").and_then(|v| v.as_str())
                && let Some(pool) = engine.db_pool.read().ok().and_then(|g| g.clone())
                && let Ok(Some(trk)) =
                    LibraryRepository::find_track_source_by_id(&pool, track_id).await
            {
                if let Ok(resolved) = engine.provider_manager.resolve_stream(&trk).await {
                    let hdr_map: HashMap<String, String> = resolved.headers.into_iter().collect();
                    let h = resolved
                        .hint_extension
                        .or_else(|| Some(trk.format.codec.as_str().to_string()));
                    if is_http_url(&resolved.url_or_path) {
                        let strm = StreamSource::http(resolved.url_or_path, hdr_map, h)
                            .with_replay_gain(
                                resolved.replay_gain_track_db,
                                resolved.replay_gain_album_db,
                                resolved.replay_gain_track_peak,
                                resolved.replay_gain_album_peak,
                            );
                        candidate_stream = Some((strm, trk.provider.display_name().to_string()));
                    } else if Path::new(&resolved.url_or_path).is_file() {
                        let strm = StreamSource::local_file(&resolved.url_or_path)
                            .with_replay_gain(
                                resolved.replay_gain_track_db,
                                resolved.replay_gain_album_db,
                                resolved.replay_gain_track_peak,
                                resolved.replay_gain_album_peak,
                            );
                        candidate_stream = Some((strm, trk.provider.display_name().to_string()));
                    }
                } else if Path::new(&trk.external_track_id).is_file() {
                    let strm = StreamSource::local_file(&trk.external_track_id).with_replay_gain(
                        trk.replay_gain_track_db,
                        trk.replay_gain_album_db,
                        trk.replay_gain_track_peak,
                        trk.replay_gain_album_peak,
                    );
                    candidate_stream = Some((strm, trk.provider.display_name().to_string()));
                }
            }

            if candidate_stream.is_none() {
                let track_id = val
                    .get("id")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|v| !v.is_empty())
                    .unwrap_or("trk-001");
                let title = val
                    .get("title")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|v| !v.is_empty())
                    .unwrap_or("Lumina Demo Track");
                let dur_ms = val
                    .get("duration_ms")
                    .and_then(|v| v.as_u64())
                    .filter(|&d| d > 0)
                    .unwrap_or_else(|| demo_track_default_duration_ms(track_id));
                let label = if source_label == "Local Library" {
                    "Lumina Demo Synth".to_string()
                } else {
                    source_label.clone()
                };
                candidate_stream = Some((StreamSource::synth(track_id, title, dur_ms), label));
            }
        }
    } else if is_http_url(s) {
        candidate_stream = Some((
            StreamSource::http(s, HashMap::new(), None),
            "HTTP Stream".to_string(),
        ));
    } else if Path::new(s).is_file() {
        candidate_stream = Some((StreamSource::local_file(s), source_label));
    } else {
        return Err(format!("Audio file not found: {s}"));
    }

    let (stream, source_label) =
        candidate_stream.ok_or_else(|| "No playable stream resolved".to_string())?;
    Ok(ResolvedPlaybackCandidate::Legacy {
        stream,
        source_label,
    })
}

pub(super) fn resolve_candidate_sync(
    engine: &Arc<EngineState>,
    s: &str,
) -> Result<ResolvedPlaybackCandidate, String> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let eng = engine.clone();
    let raw = s.to_string();
    engine.runtime.spawn(async move {
        let _ = tx.send(resolve_candidate_async(&eng, &raw).await);
    });
    rx.recv()
        .map_err(|_| "Playback resolve task dropped".to_string())?
}
