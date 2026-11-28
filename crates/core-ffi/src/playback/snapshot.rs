use super::devices::build_device_infos;
use super::payload::{first_non_empty_str, parse_deck_track_metadata};
use crate::engine::{EngineState, get_engine};
use crate::error::{catch_unwind_ffi, string_to_c_char, synthesize_lumina_error};
use core_audio::AudioPlayer;
use core_types::{
    AudioQualityInfo, DeckTrackMetadata, DualDeckStatusSnapshot, PlaybackLifecycleState,
    PlaybackState, ProtocolSnapshot, RepeatMode, TrackMetadata, VerificationStatus,
};
use std::os::raw::c_char;
use std::sync::atomic::Ordering;

fn enrich_track_metadata(
    deck: &DeckTrackMetadata,
    active_track_raw: Option<&str>,
    audio_quality: Option<AudioQualityInfo>,
) -> TrackMetadata {
    let mut meta = TrackMetadata::from(deck);
    if let Some(raw) = active_track_raw
        && let Ok(val) = serde_json::from_str::<serde_json::Value>(raw)
    {
        if meta.album_id.is_none() {
            meta.album_id = first_non_empty_str(&val, &["album_id"]);
        }
        if meta.artist_id.is_none() {
            meta.artist_id = first_non_empty_str(&val, &["artist_id"]);
        }
        if meta.track_number.is_none() {
            meta.track_number = val
                .get("track_number")
                .and_then(|v| v.as_u64())
                .and_then(|n| u32::try_from(n).ok());
        }
        if meta.disc_number.is_none() {
            meta.disc_number = val
                .get("disc_number")
                .and_then(|v| v.as_u64())
                .and_then(|n| u32::try_from(n).ok());
        }
        if meta.isrc.is_none() {
            meta.isrc = first_non_empty_str(&val, &["isrc"]);
        }
        if meta.uri.is_none() {
            meta.uri = first_non_empty_str(&val, &["uri", "file_path", "stream_url", "path"]);
        }
        if meta.audio_quality.is_none()
            && let Some(q_val) = val.get("audio_quality")
            && let Ok(parsed_q) = serde_json::from_value::<AudioQualityInfo>(q_val.clone())
        {
            meta.audio_quality = Some(parsed_q);
        }
    }
    if meta.audio_quality.is_none() {
        meta.audio_quality = audio_quality;
    }
    meta
}

fn derive_audio_quality(player: &AudioPlayer) -> Option<AudioQualityInfo> {
    let meta = player.active_meta()?;
    let out_info = player.output_info();
    let bit_perfect = matches!(
        out_info.verification.status,
        VerificationStatus::BitPerfect | VerificationStatus::DsdNative | VerificationStatus::DsdDop
    );
    let output_mode = if out_info.output.output_mode.trim().is_empty() {
        meta.backend.as_str().to_string()
    } else {
        out_info.output.output_mode
    };
    Some(AudioQualityInfo::from_audio_format(
        &meta.format,
        output_mode,
        bit_perfect,
    ))
}

struct CanonicalPlaybackSnapshotParts {
    state: PlaybackState,
    dual_deck: DualDeckStatusSnapshot,
    current_track_deck: Option<DeckTrackMetadata>,
    epoch: u64,
    play_request_id: u64,
    loaded_request_id: u64,
}

fn build_canonical_playback_state(engine: &EngineState) -> CanonicalPlaybackSnapshotParts {
    let play_request_id = engine.play_request_id.load(Ordering::SeqCst);
    let loaded_request_id = engine.loaded_request_id.load(Ordering::SeqCst);
    let player_opt = engine.player_clone();
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
        audio_quality,
    ) = if let Some(ref player) = player_opt {
        let dd = player.dual_deck_status();
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
        let aq = derive_audio_quality(player);
        (
            code, name, pos, dur, clk, epoch, seeking, dsp_byp, strict, vol, err, err_code,
            err_prov, lost, dd, aq,
        )
    } else {
        let code = engine.playback_state.load(Ordering::SeqCst);
        let name = PlaybackLifecycleState::from_i32(code).as_legacy_state_name();
        let pos = engine.position_ms.load(Ordering::Relaxed);
        let dur = engine.duration_ms.load(Ordering::Relaxed);
        let clk = "stream_frames";
        let epoch = 0u64;
        let seeking = false;
        let dsp_byp = engine.dsp_bypassed.load(Ordering::Relaxed);
        let strict = false;
        let vol = engine.get_volume();
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
            None,
            None,
            None,
            false,
            DualDeckStatusSnapshot::default(),
            None,
        )
    };

    let engine_state = engine.playback_state.load(Ordering::SeqCst);
    let has_real_stream = engine.has_real_stream.load(Ordering::SeqCst);
    let is_loading = play_request_id > loaded_request_id;
    if is_loading {
        state_code = 5;
        state_name = "Loading";
        position_ms = 0;
        duration_ms = engine.duration_ms.load(Ordering::Relaxed);
    } else if !has_real_stream && engine_state == 4 {
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
    } else if !has_real_stream && engine_state == 3 {
        state_code = 3;
        state_name = "Paused";
    } else if !has_real_stream && engine_state == 1 {
        state_code = 1;
        state_name = "Stopped";
        position_ms = 0;
    }

    let active_track_raw = engine.active_track_json.read().ok().and_then(|g| g.clone());
    let current_track_deck = if is_loading {
        active_track_raw
            .as_deref()
            .and_then(|raw| parse_deck_track_metadata(raw, None))
            .map(|mut t| {
                if duration_ms > 0 {
                    t.duration_ms = duration_ms;
                }
                t
            })
    } else if !has_real_stream && (engine_state == 1 || engine_state == 4) {
        None
    } else {
        dual_deck.active_track.clone().map(|mut t| {
            if t.duration_ms == 0 && duration_ms > 0 {
                t.duration_ms = duration_ms;
            }
            t
        })
    };

    let fallback_track_id = active_track_raw.as_deref().and_then(|raw| {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(raw) {
            val.get("track_id")
                .or_else(|| val.get("id"))
                .or_else(|| val.get("external_track_id"))
                .and_then(|v| v.as_str())
                .map(str::to_string)
        } else if !raw.trim().is_empty() && !raw.contains('{') {
            Some(raw.trim().to_string())
        } else {
            None
        }
    });

    let current_track_id = current_track_deck
        .as_ref()
        .map(|t| t.track_id.clone())
        .filter(|id| !id.is_empty())
        .or(fallback_track_id);

    let track_meta = current_track_deck
        .as_ref()
        .map(|d| enrich_track_metadata(d, active_track_raw.as_deref(), audio_quality.clone()));

    let playback_epoch = engine
        .current_playback_epoch()
        .max(dual_deck.playback_epoch);
    let epoch = engine.current_epoch().max(playback_epoch);

    let structured_error = engine.current_structured_error().or_else(|| {
        last_error.clone().map(|msg| {
            synthesize_lumina_error(msg, last_error_code.as_deref(), last_error_provider.clone())
        })
    });

    let repeat_mode = engine
        .repeat_mode
        .read()
        .map(|g| *g)
        .unwrap_or(RepeatMode::Off);
    let shuffle = engine.shuffle.load(Ordering::SeqCst);
    let is_muted = engine.is_muted.load(Ordering::SeqCst);
    let active_zone_id = engine.active_zone_id.read().ok().and_then(|g| g.clone());
    let devices = build_device_infos(engine);
    let active_device = devices
        .iter()
        .find(|d| d.is_active)
        .or_else(|| devices.iter().find(|d| d.is_default))
        .cloned();

    let state = PlaybackState {
        status: PlaybackLifecycleState::from_i32(state_code),
        state_code,
        state_name: state_name.to_string(),
        track: track_meta,
        position_ms,
        duration_ms,
        timestamp_ms: EngineState::now_unix_ms(),
        volume,
        is_muted,
        repeat_mode,
        shuffle,
        audio_quality,
        active_device,
        active_zone_id,
        clock_source: clock_source.to_string(),
        seek_epoch,
        is_seeking,
        dsp_bypassed,
        strict_bit_perfect,
        device_lost,
        swap_generation: dual_deck.swap_generation,
        playback_epoch,
        error: structured_error,
        track_id: current_track_id.clone(),
        current_track_id,
        last_error,
        last_error_code,
        last_error_provider,
    };

    CanonicalPlaybackSnapshotParts {
        state,
        dual_deck,
        current_track_deck,
        epoch,
        play_request_id,
        loaded_request_id,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_playback_get_state_json() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_playback_get_state_json",
        || {
            let engine = get_engine();
            let parts = build_canonical_playback_state(&engine);
            let mut json_val = serde_json::to_value(&parts.state)?;
            if let Some(obj) = json_val.as_object_mut() {
                // Preserve legacy null key presence and camelCase/dual-deck aliases for backwards compatibility.
                obj.entry("last_error").or_insert(serde_json::Value::Null);
                obj.entry("last_error_code")
                    .or_insert(serde_json::Value::Null);
                obj.entry("last_error_provider")
                    .or_insert(serde_json::Value::Null);
                obj.entry("current_track_id")
                    .or_insert(serde_json::Value::Null);

                obj.insert("epoch".into(), serde_json::json!(parts.epoch));
                obj.insert(
                    "playbackEpoch".into(),
                    serde_json::json!(parts.state.playback_epoch),
                );
                obj.insert(
                    "current_track".into(),
                    serde_json::to_value(&parts.current_track_deck)?,
                );
                obj.insert(
                    "swapGeneration".into(),
                    serde_json::json!(parts.dual_deck.swap_generation),
                );
                obj.insert(
                    "play_request_id".into(),
                    serde_json::json!(parts.play_request_id),
                );
                obj.insert(
                    "loaded_request_id".into(),
                    serde_json::json!(parts.loaded_request_id),
                );
                obj.insert(
                    "active_deck".into(),
                    serde_json::json!(parts.dual_deck.active_deck.as_str()),
                );
                obj.insert(
                    "deck_a_state".into(),
                    serde_json::json!(parts.dual_deck.deck_a_state.as_str()),
                );
                obj.insert(
                    "deck_b_state".into(),
                    serde_json::json!(parts.dual_deck.deck_b_state.as_str()),
                );
                obj.insert(
                    "deck_a_key".into(),
                    serde_json::to_value(&parts.dual_deck.deck_a_key)?,
                );
                obj.insert(
                    "deck_b_key".into(),
                    serde_json::to_value(&parts.dual_deck.deck_b_key)?,
                );
                obj.insert(
                    "standby_buffered_ms".into(),
                    serde_json::json!(parts.dual_deck.standby_buffered_ms),
                );
                obj.insert(
                    "gapless_transitions".into(),
                    serde_json::json!(parts.dual_deck.gapless_transitions),
                );
                obj.insert(
                    "manual_zero_latency_switches".into(),
                    serde_json::json!(parts.dual_deck.manual_zero_latency_switches),
                );
                obj.insert(
                    "format_mismatch_recoveries".into(),
                    serde_json::json!(parts.dual_deck.format_mismatch_recoveries),
                );
                obj.insert(
                    "activeDeck".into(),
                    serde_json::json!(parts.dual_deck.active_deck.as_str()),
                );
                obj.insert(
                    "deckAState".into(),
                    serde_json::json!(parts.dual_deck.deck_a_state.as_str()),
                );
                obj.insert(
                    "deckBState".into(),
                    serde_json::json!(parts.dual_deck.deck_b_state.as_str()),
                );
                obj.insert(
                    "standbyBufferedMs".into(),
                    serde_json::json!(parts.dual_deck.standby_buffered_ms),
                );
                obj.insert(
                    "gaplessTransitions".into(),
                    serde_json::json!(parts.dual_deck.gapless_transitions),
                );
                obj.insert(
                    "manualZeroLatencySwitches".into(),
                    serde_json::json!(parts.dual_deck.manual_zero_latency_switches),
                );
                obj.insert(
                    "formatMismatchRecoveries".into(),
                    serde_json::json!(parts.dual_deck.format_mismatch_recoveries),
                );
            }

            let json_str = serde_json::to_string(&json_val)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Returns the current canonical [`core_types::QueueState`] as JSON.
/// Returned non-null pointers MUST be freed with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_queue_get_state_json() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_queue_get_state_json", || {
        let engine = get_engine();
        let queue = engine
            .queue_state
            .read()
            .map(|g| g.clone())
            .unwrap_or_default();
        let json_str = serde_json::to_string(&queue)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Returns a full canonical [`core_types::ProtocolSnapshot`] as JSON.
/// Returned non-null pointers MUST be freed with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_protocol_snapshot_json() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_protocol_snapshot_json",
        || {
            let engine = get_engine();
            let parts = build_canonical_playback_state(&engine);
            let queue = engine
                .queue_state
                .read()
                .map(|g| g.clone())
                .unwrap_or_default();
            let signal_path = engine.player_clone().map(|p| p.current_signal_path());
            let devices = build_device_infos(&engine);
            let zones = crate::zones::enriched_zones(&engine);
            let snapshot = ProtocolSnapshot {
                playback: parts.state,
                queue,
                signal_path,
                devices,
                zones,
                server_time_ms: EngineState::now_unix_ms(),
                sequence: engine.current_sequence(),
            };
            let json_str = serde_json::to_string(&snapshot)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
