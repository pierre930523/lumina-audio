use crate::engine::get_engine;
use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, LUMINA_ERR_AUDIO_BACKEND,
    LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_OK,
};
use core_audio::{device_manager::AudioDeviceManager, StreamSource};
use core_db::LibraryRepository;
use core_types::{AudioEngineOutputInfo, DsdOutputMode, OutputBackendKind};
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::Path;
use std::sync::atomic::Ordering;

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

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_play(track_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_playback_play", || {
        let engine = get_engine();
        if !engine.initialized.load(Ordering::SeqCst) {
            set_last_error("Audio engine not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        }

        if track_json.is_null() {
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

        let mut candidate_stream: Option<(StreamSource, String)> = None;
        let mut source_label = "Local Library".to_string();

        let c_str = unsafe { CStr::from_ptr(track_json) };
        let s = match c_str.to_str() {
            Ok(str_val) => str_val.trim(),
            Err(e) => {
                set_last_error(format!("Invalid UTF-8 in playback payload: {e}"));
                return Ok(LUMINA_ERR_GENERAL);
            }
        };

        if let Ok(mut lock) = engine.active_track_json.write() {
            *lock = Some(s.to_string());
        }

        if let Ok(val) = serde_json::from_str::<serde_json::Value>(s) {
            if let Some(src) = val
                .get("source")
                .or_else(|| val.get("provider"))
                .and_then(|v| v.as_str())
                && !src.trim().is_empty()
            {
                source_label = src.trim().to_string();
            }

            let hint = val
                .get("hint_extension")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            let headers: HashMap<String, String> = val
                .get("headers")
                .and_then(|v| serde_json::from_value(v.clone()).ok())
                .unwrap_or_default();

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
                if url.starts_with("http://") || url.starts_with("https://") {
                    candidate_stream = Some((
                        StreamSource::http(url, headers, hint),
                        if source_label == "Local Library" {
                            "HTTP Stream".to_string()
                        } else {
                            source_label.clone()
                        },
                    ));
                } else {
                    engine.has_real_stream.store(false, Ordering::SeqCst);
                    engine.playback_state.store(4, Ordering::SeqCst);
                    set_last_error(format!("Unsupported stream URL: {url}"));
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
            } else if let Some(fp) = explicit_file_path {
                if fp.starts_with("http://") || fp.starts_with("https://") {
                    candidate_stream = Some((
                        StreamSource::http(fp, headers, hint),
                        if source_label == "Local Library" {
                            "HTTP Stream".to_string()
                        } else {
                            source_label.clone()
                        },
                    ));
                } else if Path::new(fp).is_file() {
                    candidate_stream =
                        Some((StreamSource::local_file(fp), source_label.clone()));
                } else {
                    engine.has_real_stream.store(false, Ordering::SeqCst);
                    engine.playback_state.store(4, Ordering::SeqCst);
                    set_last_error(format!("Audio file not found: {fp}"));
                    return Ok(LUMINA_ERR_AUDIO_BACKEND);
                }
            } else {
                if let Some(ext_id) = val
                    .get("external_track_id")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|v| !v.is_empty())
                {
                    if ext_id.starts_with("http://") || ext_id.starts_with("https://") {
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
                    && let Ok(pool_guard) = engine.db_pool.read()
                    && let Some(ref pool) = *pool_guard
                    && let Ok(Some(trk)) = engine
                        .runtime
                        .block_on(LibraryRepository::find_track_source_by_id(pool, track_id))
                {
                    if let Ok(resolved) =
                        engine.runtime.block_on(engine.provider_manager.resolve_stream(&trk))
                    {
                        let hdr_map: HashMap<String, String> =
                            resolved.headers.into_iter().collect();
                        let h = resolved
                            .hint_extension
                            .or_else(|| Some(trk.format.codec.as_str().to_string()));
                        if resolved.url_or_path.starts_with("http://")
                            || resolved.url_or_path.starts_with("https://")
                        {
                            let strm = StreamSource::http(resolved.url_or_path, hdr_map, h)
                                .with_replay_gain(
                                    resolved.replay_gain_track_db,
                                    resolved.replay_gain_album_db,
                                    resolved.replay_gain_track_peak,
                                    resolved.replay_gain_album_peak,
                                );
                            candidate_stream =
                                Some((strm, trk.provider.display_name().to_string()));
                        } else if Path::new(&resolved.url_or_path).is_file() {
                            let strm = StreamSource::local_file(&resolved.url_or_path)
                                .with_replay_gain(
                                    resolved.replay_gain_track_db,
                                    resolved.replay_gain_album_db,
                                    resolved.replay_gain_track_peak,
                                    resolved.replay_gain_album_peak,
                                );
                            candidate_stream =
                                Some((strm, trk.provider.display_name().to_string()));
                        }
                    } else if Path::new(&trk.external_track_id).is_file() {
                        let strm = StreamSource::local_file(&trk.external_track_id)
                            .with_replay_gain(
                                trk.replay_gain_track_db,
                                trk.replay_gain_album_db,
                                trk.replay_gain_track_peak,
                                trk.replay_gain_album_peak,
                            );
                        candidate_stream =
                            Some((strm, trk.provider.display_name().to_string()));
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
                    candidate_stream =
                        Some((StreamSource::synth(track_id, title, dur_ms), label));
                }
            }
        } else if s.starts_with("http://") || s.starts_with("https://") {
            candidate_stream = Some((
                StreamSource::http(s, HashMap::new(), None),
                "HTTP Stream".to_string(),
            ));
        } else if Path::new(s).is_file() {
            candidate_stream = Some((StreamSource::local_file(s), source_label));
        } else {
            engine.has_real_stream.store(false, Ordering::SeqCst);
            engine.playback_state.store(4, Ordering::SeqCst);
            set_last_error(format!("Audio file not found: {s}"));
            return Ok(LUMINA_ERR_AUDIO_BACKEND);
        }

        if let Some((stream, label)) = candidate_stream
            && let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            if let Err(e) = player.play_stream(stream, &label) {
                engine.has_real_stream.store(false, Ordering::SeqCst);
                engine.playback_state.store(4, Ordering::SeqCst);
                set_last_error(format!("Failed to play stream ({label}): {e}"));
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

        if let Ok(player_guard) = engine.player.read()
            && let Some(ref player) = *player_guard
        {
            player.stop();
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
                player.set_device_lost(false);
                let _ = player.take_last_error();
                let _ = player.select_output_device(None, None);
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
        let (
            state_code,
            state_name,
            position_ms,
            duration_ms,
            clock_source,
            seek_epoch,
            is_seeking,
            dsp_bypassed,
            strict_bit_perfect,
            volume,
            last_error,
            device_lost,
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
            let lost = player.is_device_lost();
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
                lost,
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
            let lost = false;
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
                lost,
            )
        };

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
            "is_seeking": is_seeking,
            "dsp_bypassed": dsp_bypassed,
            "strict_bit_perfect": strict_bit_perfect,
            "volume": volume,
            "last_error": last_error,
            "device_lost": device_lost,
            "current_track_id": current_track_id,
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
