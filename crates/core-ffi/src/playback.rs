use crate::engine::{get_engine, EngineState};
use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, take_last_error, LUMINA_ERR_AUDIO_BACKEND,
    LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_OK,
};
use core_audio::{
    device_manager::AudioDeviceManager, AudioPlayer, CoreAudioError, DecoderError,
    OpenedStreamDecoder, StreamSource,
};
use core_db::LibraryRepository;
use core_types::{
    AudioEngineOutputInfo, DsdOutputMode, DualDeckStatusSnapshot, OutputBackendKind,
    StreamSourceSpec,
};
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

fn demo_track_default_duration_ms(track_id: &str) -> u64 {
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

fn is_http_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

fn parse_headers_field(val: &serde_json::Value) -> HashMap<String, String> {
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

struct ParsedPayloadHints {
    caller_epoch: Option<u64>,
    duration_ms: u64,
    source_spec: Option<StreamSourceSpec>,
    source_label: String,
}

enum ResolvedPlaybackCandidate {
    SourceSpec {
        spec: StreamSourceSpec,
        source_label: String,
    },
    Legacy {
        stream: StreamSource,
        source_label: String,
    },
}

fn default_label_for_source_spec(spec: &StreamSourceSpec, fallback: &str) -> String {
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

fn parse_payload_hints(raw: &str) -> Result<ParsedPayloadHints, String> {
    let mut source_label = "Local Library".to_string();
    let Ok(val) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Ok(ParsedPayloadHints {
            caller_epoch: None,
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
    let caller_epoch = val.get("epoch").and_then(|v| v.as_u64()).filter(|&e| e > 0);
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
        duration_ms,
        source_spec,
        source_label,
    })
}

async fn resolve_candidate_async(
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
                    candidate_stream = Some((StreamSource::local_file(ext_id), source_label.clone()));
                }
            }

            if candidate_stream.is_none()
                && let Some(track_id) = val.get("id").and_then(|v| v.as_str())
                && let Some(pool) = engine.db_pool.read().ok().and_then(|g| g.clone())
                && let Ok(Some(trk)) = LibraryRepository::find_track_source_by_id(&pool, track_id).await
            {
                if let Ok(resolved) = engine.provider_manager.resolve_stream(&trk).await {
                    let hdr_map: HashMap<String, String> =
                        resolved.headers.into_iter().collect();
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

fn fail_async_if_current(
    engine: &EngineState,
    generation: u64,
    request_id: u64,
    task_epoch: u64,
    cancel_token: &CancellationToken,
    msg: String,
) {
    fail_async_if_current_with_code(
        engine,
        generation,
        request_id,
        task_epoch,
        cancel_token,
        msg,
        None,
        None,
    );
}

#[allow(clippy::too_many_arguments)]
fn fail_async_if_current_with_code(
    engine: &EngineState,
    generation: u64,
    request_id: u64,
    task_epoch: u64,
    cancel_token: &CancellationToken,
    msg: String,
    code: Option<String>,
    provider: Option<String>,
) {
    let _commit_guard = engine
        .async_commit_lock
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let is_stale = engine.async_generation.load(Ordering::SeqCst) != generation
        || engine.play_request_id.load(Ordering::SeqCst) != request_id
        || engine.current_epoch() != task_epoch
        || cancel_token.is_cancelled();
    if !is_stale {
        if let Ok(mut err_lock) = engine.async_last_error.write() {
            *err_lock = Some(msg.clone());
        }
        if let Ok(mut code_lock) = engine.async_last_error_code.write() {
            *code_lock = code;
        }
        if let Ok(mut prov_lock) = engine.async_last_error_provider.write() {
            *prov_lock = provider;
        }
        set_last_error(msg);
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.playback_state.store(4, Ordering::SeqCst);
        engine.loaded_request_id.store(request_id, Ordering::SeqCst);
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_play_async(
    track_json: *const c_char,
    request_id: u64,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_play_async", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            set_last_error("Audio engine not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }
        if track_json.is_null() {
            set_last_error("track_json must not be null for lumina_playback_play_async");
            return Ok(LUMINA_ERR_GENERAL);
        }
        if request_id == 0 {
            set_last_error("request_id must be greater than 0 for lumina_playback_play_async");
            return Ok(LUMINA_ERR_GENERAL);
        }

        let c_str = unsafe { CStr::from_ptr(track_json) };
        let payload = match c_str.to_str() {
            Ok(str_val) => str_val.trim().to_string(),
            Err(e) => {
                set_last_error(format!("Invalid UTF-8 in playback payload: {e}"));
                return Ok(LUMINA_ERR_GENERAL);
            }
        };

        let hints = match parse_payload_hints(&payload) {
            Ok(h) => h,
            Err(msg) => {
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
        };
        if !engine.accept_caller_epoch(hints.caller_epoch) {
            return Ok(LUMINA_OK);
        }
        let _ = crate::l2_cache::ensure_default_l2_cache_manager(&engine);

        let cancel_token = CancellationToken::new();
        engine.swap_play_cancel_token(cancel_token.clone());
        let generation = engine.async_generation.fetch_add(1, Ordering::SeqCst) + 1;
        engine.play_request_id.store(0, Ordering::SeqCst);
        engine.loaded_request_id.store(0, Ordering::SeqCst);
        engine.play_request_id.store(request_id, Ordering::SeqCst);
        if let Ok(mut err_lock) = engine.async_last_error.write() {
            *err_lock = None;
        }
        if let Ok(mut code_lock) = engine.async_last_error_code.write() {
            *code_lock = None;
        }
        if let Ok(mut prov_lock) = engine.async_last_error_provider.write() {
            *prov_lock = None;
        }
        let _ = take_last_error();
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.position_ms.store(0, Ordering::Relaxed);
        engine.duration_ms.store(hints.duration_ms, Ordering::Relaxed);
        engine.playback_state.store(5, Ordering::SeqCst); // 5 = Loading

        if let Ok(mut lock) = engine.active_track_json.write() {
            *lock = Some(payload.clone());
        }

        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            player.stop();
            let _ = player.take_last_error();
        }

        let task_epoch = engine.advance_epoch(hints.caller_epoch);
        let player_play_ep = if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            let Some(ep) = player.begin_source_epoch(task_epoch, cancel_token.clone()) else {
                return Ok(LUMINA_OK);
            };
            ep
        } else {
            set_last_error("Audio player not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        let engine_bg = engine.clone();
        engine.runtime.spawn(async move {
            let is_stale = || {
                engine_bg.async_generation.load(Ordering::SeqCst) != generation
                    || engine_bg.play_request_id.load(Ordering::SeqCst) != request_id
                    || engine_bg.current_epoch() != task_epoch
                    || cancel_token.is_cancelled()
            };

            if is_stale() {
                return;
            }

            let candidate = tokio::select! {
                biased;
                _ = cancel_token.cancelled() => return,
                res = resolve_candidate_async(&engine_bg, &payload) => match res {
                    Ok(c) => c,
                    Err(msg) => {
                        fail_async_if_current(&engine_bg, generation, request_id, task_epoch, &cancel_token, msg);
                        return;
                    }
                }
            };

            if is_stale() {
                return;
            }

            let label = match &candidate {
                ResolvedPlaybackCandidate::SourceSpec { source_label, .. }
                | ResolvedPlaybackCandidate::Legacy { source_label, .. } => source_label.clone(),
            };

            let open_cancel = cancel_token.clone();
            let open_res: Result<(OpenedStreamDecoder, Option<StreamSourceSpec>), CoreAudioError> =
                match &candidate {
                    ResolvedPlaybackCandidate::SourceSpec { spec, .. } => {
                        let player_opt = engine_bg.player.read().ok().and_then(|g| g.clone());
                        match player_opt {
                            Some(player) => tokio::select! {
                                biased;
                                _ = cancel_token.cancelled() => return,
                                res = player.open_source_spec_async_with_l2(
                                    spec.clone(),
                                    open_cancel.clone(),
                                    None,
                                ) => res.map(|(dec, adopted)| (dec, Some(adopted))),
                            },
                            None => {
                                fail_async_if_current(
                                    &engine_bg,
                                    generation,
                                    request_id,
                                    task_epoch,
                                    &cancel_token,
                                    "Audio player not initialized".to_string(),
                                );
                                return;
                            }
                        }
                    }
                    ResolvedPlaybackCandidate::Legacy { stream, .. } => {
                        tokio::select! {
                            biased;
                            _ = cancel_token.cancelled() => return,
                            res = AudioPlayer::open_stream_async(
                                stream.clone(),
                                open_cancel,
                                Duration::from_secs(10),
                            ) => res.map(|dec| (dec, None)),
                        }
                    }
                };

            let (decoder, adopted_spec) = match open_res {
                Ok(pair) => pair,
                Err(e) => {
                    let (err_code, err_provider, err_msg) = match &e {
                        CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
                            provider_id,
                            status,
                        }) => (
                            Some("AUTH_REQUIRED".to_string()),
                            Some(provider_id.clone()),
                            format!(
                                "Authentication required for {provider_id} (HTTP {status})"
                            ),
                        ),
                        _ => (None, None, format!("Failed to open stream ({label}): {e}")),
                    };
                    fail_async_if_current_with_code(
                        &engine_bg,
                        generation,
                        request_id,
                        task_epoch,
                        &cancel_token,
                        err_msg,
                        err_code,
                        err_provider,
                    );
                    return;
                }
            };

            if is_stale() {
                return;
            }

            let _ = tokio::task::spawn_blocking(move || {
                let is_stale_blocking = || {
                    engine_bg.async_generation.load(Ordering::SeqCst) != generation
                        || engine_bg.play_request_id.load(Ordering::SeqCst) != request_id
                        || engine_bg.current_epoch() != task_epoch
                        || cancel_token.is_cancelled()
                };

                let _commit_guard = engine_bg
                    .async_commit_lock
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                if is_stale_blocking() {
                    return;
                }

                if let Ok(player_guard) = engine_bg.player.read()
                    && let Some(ref player) = *player_guard
                {
                    let start_res = match &candidate {
                        ResolvedPlaybackCandidate::SourceSpec { spec, source_label } => {
                            let effective_spec = adopted_spec.as_ref().unwrap_or(spec);
                            player.start_opened_source_spec(
                                effective_spec,
                                decoder,
                                source_label,
                                player_play_ep,
                                cancel_token.clone(),
                            )
                        }
                        ResolvedPlaybackCandidate::Legacy {
                            stream,
                            source_label,
                        } => player.start_opened_decoder_with_epoch(
                            stream,
                            decoder,
                            source_label,
                            player_play_ep,
                            cancel_token.clone(),
                        ),
                    };
                    if let Err(e) = start_res {
                        let msg = format!("Failed to play stream ({label}): {e}");
                        if !is_stale_blocking() {
                            if let Ok(mut err_lock) = engine_bg.async_last_error.write() {
                                *err_lock = Some(msg.clone());
                            }
                            set_last_error(msg);
                            engine_bg.has_real_stream.store(false, Ordering::SeqCst);
                            engine_bg.playback_state.store(4, Ordering::SeqCst);
                            engine_bg
                                .loaded_request_id
                                .store(request_id, Ordering::SeqCst);
                        }
                        return;
                    }
                    if is_stale_blocking() {
                        player.stop();
                        return;
                    }
                    engine_bg.has_real_stream.store(true, Ordering::SeqCst);
                    engine_bg
                        .duration_ms
                        .store(player.duration_ms(), Ordering::Relaxed);
                    engine_bg.position_ms.store(0, Ordering::Relaxed);
                    engine_bg.playback_state.store(2, Ordering::SeqCst);
                    engine_bg
                        .loaded_request_id
                        .store(request_id, Ordering::SeqCst);
                } else {
                    if let Ok(mut err_lock) = engine_bg.async_last_error.write() {
                        *err_lock = Some("Audio player not initialized".to_string());
                    }
                    set_last_error("Audio player not initialized");
                    engine_bg.has_real_stream.store(false, Ordering::SeqCst);
                    engine_bg.playback_state.store(4, Ordering::SeqCst);
                    engine_bg
                        .loaded_request_id
                        .store(request_id, Ordering::SeqCst);
                }
            })
            .await;
        });

        Ok(LUMINA_OK)
    })
}

fn resolve_candidate_sync(
    engine: &std::sync::Arc<EngineState>,
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

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_cancel_pending(min_request_id: u64) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_cancel_pending",
        || {
            let engine = get_engine();
            let active_id = engine.play_request_id.load(Ordering::SeqCst);
            let loaded_id = engine.loaded_request_id.load(Ordering::SeqCst);
            if active_id > loaded_id && active_id >= min_request_id {
                engine.async_generation.fetch_add(1, Ordering::SeqCst);
                engine.cancel_active_play_token();
                engine.advance_epoch(None);
                let _commit_guard = engine
                    .async_commit_lock
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                engine.loaded_request_id.store(active_id, Ordering::SeqCst);
                engine.has_real_stream.store(false, Ordering::SeqCst);
                engine.playback_state.store(1, Ordering::SeqCst);
                if let Ok(player_guard) = engine.player.read()
                    && let Some(ref player) = *player_guard
                {
                    player.stop();
                }
            }
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_active_request_id() -> u64 {
    get_engine().play_request_id.load(Ordering::SeqCst)
}

/// Pre-resolves and pre-decodes 2–3 seconds of the next track onto the Standby deck
/// without interrupting Active deck playback. Rejects `ExternalBackend` (Apple Music).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_prepare_standby_async(
    track_json: *const c_char,
    caller_epoch: u64,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_playback_prepare_standby_async",
        || {
            let engine = get_engine();
            if !engine.initialized.load(Ordering::SeqCst) {
                set_last_error("Audio engine not initialized");
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            }
            if track_json.is_null() {
                set_last_error(
                    "track_json must not be null for lumina_playback_prepare_standby_async",
                );
                return Ok(LUMINA_ERR_GENERAL);
            }

            let c_str = unsafe { CStr::from_ptr(track_json) };
            let payload = match c_str.to_str() {
                Ok(str_val) => str_val.trim().to_string(),
                Err(e) => {
                    set_last_error(format!("Invalid UTF-8 in standby payload: {e}"));
                    return Ok(LUMINA_ERR_GENERAL);
                }
            };
            if payload.is_empty() {
                set_last_error("standby track_json payload must not be empty");
                return Ok(LUMINA_ERR_GENERAL);
            }

            let hints = match parse_payload_hints(&payload) {
                Ok(h) => h,
                Err(msg) => {
                    set_last_error(msg);
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
            };

            let eff_epoch = if caller_epoch > 0 {
                Some(caller_epoch)
            } else {
                hints.caller_epoch
            };
            if let Some(ep) = eff_epoch {
                let last_ep = engine.last_caller_epoch.load(Ordering::SeqCst);
                if ep < last_ep {
                    return Ok(LUMINA_OK);
                }
            }

            let _ = crate::l2_cache::ensure_default_l2_cache_manager(&engine);

            if let Some(spec) = hints.source_spec {
                let Ok(player_guard) = engine.player.read() else {
                    set_last_error("Audio player lock poisoned");
                    return Ok(LUMINA_ERR_GENERAL);
                };
                let Some(ref player) = *player_guard else {
                    set_last_error("Audio player not initialized");
                    return Ok(LUMINA_ERR_NOT_INITIALIZED);
                };
                if let Err(e) = player.prepare_standby_spec(spec) {
                    set_last_error(format!("Failed to prepare standby spec: {e}"));
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
                return Ok(LUMINA_OK);
            }

            let engine_bg = engine.clone();
            engine.runtime.spawn(async move {
                if let Some(ep) = eff_epoch
                    && ep < engine_bg.last_caller_epoch.load(Ordering::SeqCst)
                {
                    return;
                }
                let Ok(candidate) = resolve_candidate_async(&engine_bg, &payload).await else {
                    return;
                };
                if let Some(ep) = eff_epoch
                    && ep < engine_bg.last_caller_epoch.load(Ordering::SeqCst)
                {
                    return;
                }
                if let Ok(player_guard) = engine_bg.player.read()
                    && let Some(ref player) = *player_guard
                {
                    let _ = match candidate {
                        ResolvedPlaybackCandidate::SourceSpec { spec, .. } => {
                            player.prepare_standby_spec(spec)
                        }
                        ResolvedPlaybackCandidate::Legacy {
                            stream,
                            source_label,
                        } => player.prepare_standby(stream, source_label),
                    };
                }
            });

            Ok(LUMINA_OK)
        },
    )
}

/// Switches playback to the Standby deck in 5–15 ms if Standby is `STANDBY_READY`.
/// Returns `1` if the zero-latency switch occurred, `0` if Standby was not ready, or `< 0` on error.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_skip_to_standby() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_skip_to_standby", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            set_last_error("Audio engine not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        let Ok(player_guard) = engine.player.read() else {
            set_last_error("Audio player lock poisoned");
            return Ok(LUMINA_ERR_GENERAL);
        };
        let Some(ref player) = *player_guard else {
            set_last_error("Audio player not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        match player.skip_to_standby() {
            Ok(true) => {
                engine.has_real_stream.store(true, Ordering::SeqCst);
                engine
                    .duration_ms
                    .store(player.duration_ms(), Ordering::Relaxed);
                engine
                    .position_ms
                    .store(player.position_ms(), Ordering::Relaxed);
                engine.playback_state.store(2, Ordering::SeqCst);
                let req_id = engine.play_request_id.load(Ordering::SeqCst);
                engine.loaded_request_id.store(req_id, Ordering::SeqCst);
                Ok(1)
            }
            Ok(false) => Ok(0),
            Err(e) => {
                set_last_error(format!("Failed to skip to standby deck: {e}"));
                Ok(LUMINA_ERR_AUDIO_BACKEND)
            }
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_play(track_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_play", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            set_last_error("Audio engine not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if track_json.is_null() {
            engine.cancel_active_play_token();
            engine.async_generation.fetch_add(1, Ordering::SeqCst);
            engine.play_request_id.store(0, Ordering::SeqCst);
            engine.loaded_request_id.store(0, Ordering::SeqCst);
            if let Ok(player_guard) = engine.player.read()
                && let Some(ref player) = *player_guard
            {
                let state = player.state_code();
                if state == 3 {
                    player.resume();
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 8 {
                    player.seek_ms(0);
                    player.resume();
                    engine.position_ms.store(0, Ordering::Relaxed);
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 2 {
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 1 && engine.has_real_stream.load(Ordering::SeqCst) {
                    player.seek_ms(0);
                    player.resume();
                    engine.position_ms.store(0, Ordering::Relaxed);
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
            }
            if engine.has_real_stream.load(Ordering::SeqCst)
                && let Ok(player_guard) = engine.player.read()
                && let Some(ref player) = *player_guard
            {
                let state = player.state_code();
                if state == 3 {
                    player.resume();
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 8 {
                    player.seek_ms(0);
                    player.resume();
                    engine.position_ms.store(0, Ordering::Relaxed);
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
                if state == 2 {
                    engine.playback_state.store(2, Ordering::SeqCst);
                    return Ok(LUMINA_OK);
                }
            }
            if let Ok(player_guard) = engine.player.read()
                && let Some(ref player) = *player_guard
            {
                engine.advance_epoch(None);
                let stream = StreamSource::synth("trk-001", "Time", 245_000);
                if let Err(e) = player.play_stream(stream, "Lumina Demo Synth") {
                    engine.has_real_stream.store(false, Ordering::SeqCst);
                    engine.playback_state.store(4, Ordering::SeqCst);
                    set_last_error(format!("Failed to play demo stream: {e}"));
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
                engine.has_real_stream.store(true, Ordering::SeqCst);
                engine
                    .duration_ms
                    .store(player.duration_ms(), Ordering::Relaxed);
                engine.position_ms.store(0, Ordering::Relaxed);
                engine.playback_state.store(2, Ordering::SeqCst);
                return Ok(LUMINA_OK);
            }
            set_last_error("Audio player not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        let c_str = unsafe { CStr::from_ptr(track_json) };
        let s = match c_str.to_str() {
            Ok(str_val) => str_val.trim(),
            Err(e) => {
                set_last_error(format!("Invalid UTF-8 in playback payload: {e}"));
                return Ok(LUMINA_ERR_GENERAL);
            }
        };

        let hints = match parse_payload_hints(s) {
            Ok(h) => h,
            Err(msg) => {
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
        };
        if !engine.accept_caller_epoch(hints.caller_epoch) {
            return Ok(LUMINA_OK);
        }
        let _ = crate::l2_cache::ensure_default_l2_cache_manager(&engine);

        let cancel_token = CancellationToken::new();
        engine.swap_play_cancel_token(cancel_token.clone());
        engine.async_generation.fetch_add(1, Ordering::SeqCst);
        engine.play_request_id.store(0, Ordering::SeqCst);
        engine.loaded_request_id.store(0, Ordering::SeqCst);
        if let Ok(mut err_lock) = engine.async_last_error.write() {
            *err_lock = None;
        }
        if let Ok(mut code_lock) = engine.async_last_error_code.write() {
            *code_lock = None;
        }
        if let Ok(mut prov_lock) = engine.async_last_error_provider.write() {
            *prov_lock = None;
        }
        let _ = take_last_error();
        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            let _ = player.take_last_error();
        }
        if let Ok(mut lock) = engine.active_track_json.write() {
            *lock = Some(s.to_string());
        }

        let candidate = match resolve_candidate_sync(&engine, s) {
            Ok(c) => c,
            Err(msg) => {
                engine.has_real_stream.store(false, Ordering::SeqCst);
                engine.playback_state.store(4, Ordering::SeqCst);
                if let Ok(mut err_lock) = engine.async_last_error.write() {
                    *err_lock = Some(msg.clone());
                }
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
        };

        let _commit_guard = engine
            .async_commit_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            let task_epoch = engine.advance_epoch(hints.caller_epoch);
            let label = match &candidate {
                ResolvedPlaybackCandidate::SourceSpec { source_label, .. }
                | ResolvedPlaybackCandidate::Legacy { source_label, .. } => source_label.clone(),
            };
            let play_res = match candidate {
                ResolvedPlaybackCandidate::SourceSpec { spec, source_label } => {
                    player.play_source_spec_with_label(spec, &source_label, task_epoch, cancel_token)
                }
                ResolvedPlaybackCandidate::Legacy {
                    stream,
                    source_label,
                } => player.play_stream(stream, &source_label),
            };
            if let Err(e) = play_res {
                let (err_code, err_provider, msg) = match &e {
                    CoreAudioError::Decoder(DecoderError::StreamAuthRequired {
                        provider_id,
                        status,
                    }) => (
                        Some("AUTH_REQUIRED".to_string()),
                        Some(provider_id.clone()),
                        format!("Authentication required for {provider_id} (HTTP {status})"),
                    ),
                    _ => (
                        player.last_error_code(),
                        player.last_error_provider(),
                        format!("Failed to play stream ({label}): {e}"),
                    ),
                };
                engine.has_real_stream.store(false, Ordering::SeqCst);
                engine.playback_state.store(4, Ordering::SeqCst);
                if let Ok(mut err_lock) = engine.async_last_error.write() {
                    *err_lock = Some(msg.clone());
                }
                if let Ok(mut code_lock) = engine.async_last_error_code.write() {
                    *code_lock = err_code;
                }
                if let Ok(mut prov_lock) = engine.async_last_error_provider.write() {
                    *prov_lock = err_provider;
                }
                set_last_error(msg);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
            engine.has_real_stream.store(true, Ordering::SeqCst);
            engine
                .duration_ms
                .store(player.duration_ms(), Ordering::Relaxed);
            engine.position_ms.store(0, Ordering::Relaxed);
            engine.playback_state.store(2, Ordering::SeqCst);
            return Ok(LUMINA_OK);
        }

        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.playback_state.store(4, Ordering::SeqCst);
        set_last_error("Audio player not initialized");
        Ok(LUMINA_ERR_NOT_INITIALIZED)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_pause() -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_playback_pause", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if engine.has_real_stream.load(Ordering::SeqCst)
            && let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            player.pause();
            engine
                .position_ms
                .store(player.position_ms(), Ordering::Relaxed);
        }

        engine.playback_state.store(3, Ordering::SeqCst); // 3 = Paused
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_stop() -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_playback_stop", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        engine.async_generation.fetch_add(1, Ordering::SeqCst);
        engine.cancel_active_play_token();
        engine.advance_epoch(None);
        let _commit_guard = engine
            .async_commit_lock
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        engine
            .loaded_request_id
            .store(engine.play_request_id.load(Ordering::SeqCst), Ordering::SeqCst);
        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            player.stop();
        }

        if let Ok(mut err_lock) = engine.async_last_error.write() {
            *err_lock = None;
        }
        engine.has_real_stream.store(false, Ordering::SeqCst);
        engine.playback_state.store(1, Ordering::SeqCst); // 1 = Stopped
        engine.position_ms.store(0, Ordering::Relaxed);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_resume() -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_playback_resume", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            player.resume();
            engine.playback_state.store(2, Ordering::SeqCst);
            return Ok(LUMINA_OK);
        }

        engine.playback_state.store(2, Ordering::SeqCst);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_seek(position_ms: u64) -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_playback_seek", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            let state = player.state_code();
            if state == 0 || state == 4 {
                set_last_error("Cannot seek in uninitialized or error state");
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
            player.seek_ms(position_ms);
            engine.position_ms.store(position_ms, Ordering::Relaxed);
            return Ok(LUMINA_OK);
        }

        engine.advance_epoch(None);
        engine.position_ms.store(position_ms, Ordering::Relaxed);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_reconnect_device() -> c_int {
    catch_unwind_ffi(
        crate::error::LUMINA_ERR_GENERAL,
        "lumina_playback_reconnect_device",
        || {
            let engine = get_engine();
            if !engine.initialized.load(Ordering::SeqCst) {
                return Ok(LUMINA_ERR_NOT_INITIALIZED);
            }

            if let Ok(guard) = engine.player.read()
                && let Some(ref player) = *guard
            {
                let _ = player.take_last_error();
                if let Ok(mut lock) = engine.async_last_error.write() {
                    *lock = None;
                }
                if let Ok(mut lock) = engine.async_last_error_code.write() {
                    *lock = None;
                }
                if let Ok(mut lock) = engine.async_last_error_provider.write() {
                    *lock = None;
                }
                let _ = player.select_output_device(None, None);
                player.set_device_lost(false);
                if engine.playback_state.load(Ordering::SeqCst) == 4 {
                    engine.playback_state.store(1, Ordering::SeqCst);
                }
                return Ok(LUMINA_OK);
            }

            if engine.playback_state.load(Ordering::SeqCst) == 4 {
                engine.playback_state.store(1, Ordering::SeqCst);
            }
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_state_json() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_playback_get_state_json", || {
        let engine = get_engine();
        let play_request_id = engine.play_request_id.load(Ordering::SeqCst);
        let loaded_request_id = engine.loaded_request_id.load(Ordering::SeqCst);
        let (
            mut state_code,
            mut state_name,
            mut position_ms,
            mut duration_ms,
            clock_source,
            seek_epoch,
            is_seeking,
            dsp_bypassed,
            strict_bit_perfect,
            volume,
            mut last_error,
            mut last_error_code,
            mut last_error_provider,
            device_lost,
            dual_deck,
        ) = if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            let code = player.state_code();
            let name = player.state_name();
            let pos = player.position_ms();
            let dur = player.duration_ms();
            let clk = player.clock_source();
            let epoch = player.seek_epoch();
            let seeking = player.is_seeking();
            let dsp_byp = player.is_dsp_bypassed();
            let strict = player.is_strict_bit_perfect();
            let vol = player.volume();
            let err = player.last_error();
            let err_code = player.last_error_code();
            let err_prov = player.last_error_provider();
            let lost = player.is_device_lost();
            let dd = player.dual_deck_status();
            (
                code,
                name,
                pos,
                dur,
                clk,
                epoch,
                seeking,
                dsp_byp,
                strict,
                vol,
                err,
                err_code,
                err_prov,
                lost,
                dd,
            )
        } else {
            let code = engine.playback_state.load(Ordering::SeqCst);
            let name = match code {
                0 => "Uninitialized",
                1 => "Stopped",
                2 => "Playing",
                3 => "Paused",
                4 => "Error",
                5 => "Loading",
                6 => "Seeking",
                7 => "Buffering",
                8 => "Ended",
                _ => "Unknown",
            };
            let pos = engine.position_ms.load(Ordering::Relaxed);
            let dur = engine.duration_ms.load(Ordering::Relaxed);
            let clk = "stream_frames";
            let epoch = 0u64;
            let seeking = false;
            let dsp_byp = engine.dsp_bypassed.load(Ordering::Relaxed);
            let strict = false;
            let vol = engine.get_volume();
            let err = None;
            let err_code = None;
            let err_prov = None;
            let lost = false;
            let dd = DualDeckStatusSnapshot::default();
            (
                code,
                name,
                pos,
                dur,
                clk,
                epoch,
                seeking,
                dsp_byp,
                strict,
                vol,
                err,
                err_code,
                err_prov,
                lost,
                dd,
            )
        };

        if play_request_id > loaded_request_id {
            state_code = 5;
            state_name = "Loading";
            position_ms = 0;
            duration_ms = engine.duration_ms.load(Ordering::Relaxed);
        } else if !engine.has_real_stream.load(Ordering::SeqCst)
            && engine.playback_state.load(Ordering::SeqCst) == 4
        {
            state_code = 4;
            state_name = "Error";
            duration_ms = 0;
            if let Ok(g) = engine.async_last_error.read()
                && g.is_some()
            {
                last_error = g.clone();
            }
            if let Ok(g) = engine.async_last_error_code.read()
                && g.is_some()
            {
                last_error_code = g.clone();
            }
            if let Ok(g) = engine.async_last_error_provider.read()
                && g.is_some()
            {
                last_error_provider = g.clone();
            }
        }

        let current_track_id = engine.active_track_json.read().ok().and_then(|g| {
            g.as_ref().and_then(|raw| {
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(raw) {
                    val.get("id")
                        .or_else(|| val.get("external_track_id"))
                        .and_then(|v| v.as_str())
                        .map(str::to_string)
                } else if !raw.trim().is_empty() && !raw.contains('{') {
                    Some(raw.trim().to_string())
                } else {
                    None
                }
            })
        });

        let json_val = serde_json::json!({
            "state_code": state_code,
            "state_name": state_name,
            "position_ms": position_ms,
            "duration_ms": duration_ms,
            "clock_source": clock_source,
            "seek_epoch": seek_epoch,
            "epoch": engine.current_epoch(),
            "is_seeking": is_seeking,
            "dsp_bypassed": dsp_bypassed,
            "strict_bit_perfect": strict_bit_perfect,
            "volume": volume,
            "last_error": last_error,
            "last_error_code": last_error_code,
            "last_error_provider": last_error_provider,
            "device_lost": device_lost,
            "current_track_id": current_track_id,
            "play_request_id": play_request_id,
            "loaded_request_id": loaded_request_id,
            "active_deck": dual_deck.active_deck.as_str(),
            "deck_a_state": dual_deck.deck_a_state.as_str(),
            "deck_b_state": dual_deck.deck_b_state.as_str(),
            "deck_a_key": dual_deck.deck_a_key,
            "deck_b_key": dual_deck.deck_b_key,
            "standby_buffered_ms": dual_deck.standby_buffered_ms,
            "gapless_transitions": dual_deck.gapless_transitions,
            "manual_zero_latency_switches": dual_deck.manual_zero_latency_switches,
            "format_mismatch_recoveries": dual_deck.format_mismatch_recoveries,
            "activeDeck": dual_deck.active_deck.as_str(),
            "deckAState": dual_deck.deck_a_state.as_str(),
            "deckBState": dual_deck.deck_b_state.as_str(),
            "standbyBufferedMs": dual_deck.standby_buffered_ms,
            "gaplessTransitions": dual_deck.gapless_transitions,
            "manualZeroLatencySwitches": dual_deck.manual_zero_latency_switches,
            "formatMismatchRecoveries": dual_deck.format_mismatch_recoveries,
        });

        let json_str = serde_json::to_string(&json_val)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_set_volume(volume: f32) -> c_int {
    catch_unwind_ffi(
        crate::error::LUMINA_ERR_GENERAL,
        "lumina_playback_set_volume",
        || {
            let engine = get_engine();
            engine.set_volume(volume);
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_volume() -> f32 {
    let engine = get_engine();
    engine.get_volume()
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_state() -> c_int {
    let engine = get_engine();
    let play_req = engine.play_request_id.load(Ordering::SeqCst);
    let loaded_req = engine.loaded_request_id.load(Ordering::SeqCst);
    if play_req > loaded_req {
        return 5;
    }
    if !engine.has_real_stream.load(Ordering::SeqCst)
        && engine.playback_state.load(Ordering::SeqCst) == 4
    {
        return 4;
    }
    if engine.initialized.load(Ordering::SeqCst)
        && engine.has_real_stream.load(Ordering::SeqCst)
        && let Ok(player_guard) = engine.player.read()
        && let Some(ref player) = *player_guard
    {
        return player.state_code();
    }
    engine.playback_state.load(Ordering::SeqCst)
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_position_ms() -> u64 {
    let engine = get_engine();
    if engine.play_request_id.load(Ordering::SeqCst) > engine.loaded_request_id.load(Ordering::SeqCst)
    {
        return 0;
    }
    if engine.initialized.load(Ordering::SeqCst)
        && engine.has_real_stream.load(Ordering::SeqCst)
        && let Ok(player_guard) = engine.player.read()
        && let Some(ref player) = *player_guard
    {
        return player.position_ms();
    }
    engine.position_ms.load(Ordering::Relaxed)
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_duration_ms() -> u64 {
    let engine = get_engine();
    if engine.initialized.load(Ordering::SeqCst)
        && engine.has_real_stream.load(Ordering::SeqCst)
        && let Ok(player_guard) = engine.player.read()
        && let Some(ref player) = *player_guard
    {
        return player.duration_ms();
    }
    engine.duration_ms.load(Ordering::Relaxed)
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_list_devices() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_audio_list_devices", || {
        let engine = get_engine();
        let devices = if let Ok(guard) = engine.player.read()
            && let Some(ref p) = *guard
        {
            p.list_output_devices()
        } else {
            let real = core_audio::enumerate_cpal_devices();
            if real.is_empty() {
                let tmp = core_audio::AudioPlayer::new_headless();
                let list = tmp.list_output_devices();
                tmp.shutdown();
                list
            } else {
                real
            }
        };
        let json_str = serde_json::to_string(&devices)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_select_device(
    device_id: *const c_char,
    backend_kind: c_int,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_select_device", || {
        let dev_id = if device_id.is_null() {
            None
        } else {
            let s = unsafe { CStr::from_ptr(device_id).to_str()? }.trim();
            if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            }
        };

        let backend = if backend_kind >= 0 {
            OutputBackendKind::ALL.get(backend_kind as usize).copied()
        } else {
            None
        };

        let engine = get_engine();
        if let Ok(guard) = engine.player.read()
            && let Some(ref p) = *guard
        {
            if let Err(e) = p.select_output_device(dev_id.as_deref(), backend) {
                set_last_error(e.to_string());
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
            engine
                .dsp_bypassed
                .store(p.is_dsp_bypassed(), Ordering::SeqCst);
            engine
                .volume_bits
                .store(p.volume().to_bits() as u64, Ordering::Relaxed);
            engine.runtime.block_on(
                engine
                    .zone_manager
                    .sync_local_zone_selected_device(dev_id.as_deref(), Some(p)),
            );
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}

/// Returns JSON of full Phase 10 `AudioEngineOutputInfo` (SOURCE, DECODER, OUTPUT, VERIFICATION).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_get_output_info() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_audio_get_output_info",
        || {
            let engine = get_engine();
            let info = if let Ok(guard) = engine.player.read()
                && let Some(ref p) = *guard
            {
                p.output_info()
            } else {
                AudioEngineOutputInfo::default()
            };
            let json_str = serde_json::to_string(&info)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Returns JSON array of real probed `AudioDeviceCapabilities` (WASAPI + ASIO)
/// enriched with OS-default, HDMI, and hardware buffer bounds metadata.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_list_device_capabilities() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_audio_list_device_capabilities",
        || {
            let engine = get_engine();
            let caps_with_meta = if let Ok(guard) = engine.player.read()
                && let Some(ref p) = *guard
            {
                p.list_device_capabilities_with_meta()
            } else {
                AudioDeviceManager::list_devices_with_meta()
            };
            let mut items = Vec::with_capacity(caps_with_meta.len());
            for (cap, meta) in caps_with_meta {
                let mut val = serde_json::to_value(&cap)?;
                if let Some(obj) = val.as_object_mut() {
                    obj.insert("is_os_default".into(), serde_json::json!(meta.is_os_default));
                    obj.insert("is_hdmi".into(), serde_json::json!(meta.is_hdmi));
                    obj.insert(
                        "hardware_supports_exclusive".into(),
                        serde_json::json!(meta.hardware_supports_exclusive),
                    );
                    obj.insert(
                        "buffer_size_supported".into(),
                        serde_json::json!(meta.buffer_size_supported),
                    );
                    if let Some(v) = meta.min_buffer_frames {
                        obj.insert("min_buffer_frames".into(), serde_json::json!(v));
                    }
                    if let Some(v) = meta.max_buffer_frames {
                        obj.insert("max_buffer_frames".into(), serde_json::json!(v));
                    }
                    if let Some(v) = meta.default_buffer_frames {
                        obj.insert("default_buffer_frames".into(), serde_json::json!(v));
                    }
                    if let Some(v) = meta.buffer_granularity {
                        obj.insert("buffer_granularity".into(), serde_json::json!(v));
                    }
                }
                items.push(val);
            }
            let json_str = serde_json::to_string(&items)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Sets preferred hardware buffer size in frames when supported by the active backend.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_set_buffer_frames(frames: u32) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_audio_set_buffer_frames",
        || {
            let engine = get_engine();
            if let Ok(guard) = engine.player.read()
                && let Some(ref p) = *guard
            {
                if let Err(e) = p.set_preferred_buffer_frames(frames) {
                    set_last_error(e.to_string());
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
                Ok(LUMINA_OK)
            } else {
                Ok(LUMINA_ERR_NOT_INITIALIZED)
            }
        },
    )
}

/// Enables or disables Strict Bit-Perfect Mode (disables EQ/ReplayGain/Crossfeed/SW Volume/SRC).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_set_strict_mode(enabled: c_int) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_set_strict_mode", || {
        let engine = get_engine();
        let on = enabled != 0;
        if let Ok(guard) = engine.player.read()
            && let Some(ref p) = *guard
        {
            p.set_strict_bit_perfect(on)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            engine
                .dsp_bypassed
                .store(p.is_dsp_bypassed(), Ordering::SeqCst);
            engine
                .volume_bits
                .store(p.volume().to_bits() as u64, Ordering::Relaxed);
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}

/// Sets DSD output mode: 0 = Auto, 1 = NativeDsd, 2 = DoP, 3 = DsdToPcm.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_set_dsd_mode(mode: c_int) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_set_dsd_mode", || {
        let dsd_mode = match mode {
            1 => DsdOutputMode::NativeDsd,
            2 => DsdOutputMode::DoP,
            3 => DsdOutputMode::DsdToPcm,
            _ => DsdOutputMode::Auto,
        };
        let engine = get_engine();
        if let Ok(guard) = engine.player.read()
            && let Some(ref p) = *guard
        {
            p.set_dsd_output_mode(dsd_mode)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}
