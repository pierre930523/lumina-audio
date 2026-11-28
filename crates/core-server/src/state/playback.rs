use super::{AppState, now_unix_ms, signal_path_to_payload};
use core_types::{
    AudioDeviceInfo, AudioQualityInfo, LuminaError, LuminaErrorCode, PlaybackLifecycleState,
    PlaybackState, SignalPath, TrackMetadata,
};
use std::sync::atomic::Ordering;
use tokio_util::sync::CancellationToken;

impl AppState {
    pub async fn current_signal_path(&self) -> SignalPath {
        if let Some(ref player) = self.player {
            let sp = player.current_signal_path();
            *self.signal_path_raw.write().await = sp.clone();
            *self.signal_path.write().await = signal_path_to_payload(&sp);
            sp
        } else {
            self.signal_path_raw.read().await.clone()
        }
    }

    pub async fn list_device_infos(&self) -> Vec<AudioDeviceInfo> {
        let player_opt = self.player.clone();
        let active_id = self.active_device_id.read().await.clone();
        let raw_devices = tokio::task::spawn_blocking(move || {
            if let Some(player) = player_opt {
                player.list_output_devices()
            } else {
                let tmp = core_audio::AudioPlayer::new_headless();
                let devices = tmp.list_output_devices();
                tmp.shutdown();
                devices
            }
        })
        .await
        .unwrap_or_default();

        let fallback_active_id = if active_id.is_none() {
            raw_devices
                .iter()
                .find(|d| d.id != "virtual-exclusive-dac" && d.is_default)
                .or_else(|| raw_devices.iter().find(|d| d.id != "virtual-exclusive-dac"))
                .or_else(|| raw_devices.first())
                .map(|d| d.id.clone())
        } else {
            None
        };
        let target_active = active_id.as_deref().or(fallback_active_id.as_deref());

        raw_devices
            .into_iter()
            .map(|d| {
                let mut info = AudioDeviceInfo::from(&d);
                info.is_active = target_active.is_some_and(|id| id == info.id);
                info
            })
            .collect()
    }

    pub async fn build_playback_state(&self) -> PlaybackState {
        let payload = self.playback_state.read().await.clone();
        let vol = *self.volume.read().await;
        let is_muted = self.is_muted.load(Ordering::SeqCst);
        let repeat_mode = *self.repeat_mode.read().await;
        let shuffle = self.shuffle.load(Ordering::SeqCst);
        let active_device = self.active_device.read().await.clone();
        let active_zone_id = self.active_zone_id.read().await.clone();
        let stored_err = self.last_structured_error.read().await.clone();
        let playback_epoch = self.current_playback_epoch();
        let is_loading_pending = self.is_loading_pending();

        let (
            lifecycle,
            pos_ms,
            dur_ms,
            clock_src,
            seek_epoch,
            is_seeking,
            dsp_byp,
            strict,
            player_err,
            player_err_code,
            player_err_provider,
            dev_lost,
            current_track,
            swap_generation,
            audio_quality,
        ) = if let Some(player) = &self.player {
            let clk = player.clock_source().to_string();
            let s_epoch = player.seek_epoch();
            let seeking = player.is_seeking();
            let b = player.is_dsp_bypassed();
            let s = player.is_strict_bit_perfect();
            let lost = player.is_device_lost();
            let dd = player.dual_deck_status();
            let out_info = player.output_info();
            let quality =
                if out_info.source.sample_rate_hz > 0 || out_info.output.sample_rate_hz > 0 {
                    let sr = if out_info.source.sample_rate_hz > 0 {
                        out_info.source.sample_rate_hz
                    } else {
                        out_info.output.sample_rate_hz
                    };
                    let bd = if out_info.source.bit_depth > 0 {
                        out_info.source.bit_depth as u16
                    } else {
                        out_info.output.valid_bits as u16
                    };
                    let ch = if out_info.source.channels > 0 {
                        out_info.source.channels
                    } else {
                        out_info.output.channels.max(2)
                    };
                    let codec = if !out_info.source.codec.is_empty() {
                        out_info.source.codec.clone()
                    } else {
                        "PCM".to_string()
                    };
                    let is_dsd = codec.to_ascii_uppercase().contains("DSD")
                        || out_info
                            .output
                            .output_mode
                            .to_ascii_uppercase()
                            .contains("DSD")
                        || out_info
                            .output
                            .output_mode
                            .to_ascii_uppercase()
                            .contains("DOP");
                    let bit_perfect = b
                        && out_info.output.degradation_reason.is_none()
                        && !out_info
                            .output
                            .output_mode
                            .to_ascii_lowercase()
                            .contains("shared");
                    Some(AudioQualityInfo {
                        codec,
                        sample_rate_hz: sr,
                        bit_depth: bd,
                        channels: ch,
                        bitrate_kbps: None,
                        output_mode: out_info.output.output_mode.clone(),
                        is_dsd,
                        dsd_rate: None,
                        bit_perfect,
                    })
                } else {
                    None
                };

            if is_loading_pending {
                let pending_dur = payload
                    .track
                    .as_ref()
                    .map(|t| t.duration_ms)
                    .filter(|&d| d > 0)
                    .unwrap_or(payload.duration_ms);
                (
                    PlaybackLifecycleState::Loading,
                    0,
                    pending_dur,
                    clk,
                    s_epoch,
                    false,
                    b,
                    s,
                    None,
                    None,
                    None,
                    lost,
                    payload.track.clone(),
                    dd.swap_generation,
                    quality,
                )
            } else {
                let code = player.state_code();
                let lifecycle = PlaybackLifecycleState::from_i32(code);
                let pos = player.position_ms();
                let dur = player.duration_ms();
                let err = player.last_error();
                let err_code = player.last_error_code();
                let err_provider = player.last_error_provider();
                let cur_track = dd
                    .active_track
                    .map(|deck| {
                        let mut meta = TrackMetadata::from(deck);
                        if dur > 0 {
                            meta.duration_ms = dur;
                        }
                        if let Some(ref existing) = payload.track
                            && existing.track_id == meta.track_id
                        {
                            if meta.album_id.is_none() {
                                meta.album_id = existing.album_id.clone();
                            }
                            if meta.artist_id.is_none() {
                                meta.artist_id = existing.artist_id.clone();
                            }
                            if meta.track_number.is_none() {
                                meta.track_number = existing.track_number;
                            }
                            if meta.disc_number.is_none() {
                                meta.disc_number = existing.disc_number;
                            }
                            if meta.isrc.is_none() {
                                meta.isrc = existing.isrc.clone();
                            }
                            if meta.uri.is_none() {
                                meta.uri = existing.uri.clone();
                            }
                            if meta.audio_quality.is_none() {
                                meta.audio_quality = existing.audio_quality.clone();
                            }
                        }
                        meta
                    })
                    .or_else(|| payload.track.clone());
                (
                    lifecycle,
                    pos,
                    dur,
                    clk,
                    s_epoch,
                    seeking,
                    b,
                    s,
                    err,
                    err_code,
                    err_provider,
                    lost,
                    cur_track,
                    dd.swap_generation,
                    quality,
                )
            }
        } else {
            let lifecycle = match payload.status.as_str() {
                "uninitialized" => PlaybackLifecycleState::Uninitialized,
                "playing" => PlaybackLifecycleState::Playing,
                "paused" => PlaybackLifecycleState::Paused,
                "loading" => PlaybackLifecycleState::Loading,
                "seeking" => PlaybackLifecycleState::Seeking,
                "buffering" => PlaybackLifecycleState::Buffering,
                "ended" => PlaybackLifecycleState::Ended,
                "error" => PlaybackLifecycleState::Error,
                _ => PlaybackLifecycleState::Stopped,
            };
            (
                lifecycle,
                payload.position_ms,
                payload.duration_ms,
                "stream_frames".to_string(),
                0,
                false,
                false,
                false,
                None,
                None,
                None,
                false,
                payload.track.clone(),
                payload.swap_generation,
                payload.track.as_ref().and_then(|t| t.audio_quality.clone()),
            )
        };

        let track_id = current_track
            .as_ref()
            .map(|t| t.track_id.clone())
            .filter(|id| !id.is_empty())
            .or_else(|| payload.track_id.clone());

        let effective_quality =
            audio_quality.or_else(|| current_track.as_ref().and_then(|t| t.audio_quality.clone()));

        let structured_error = stored_err.or_else(|| {
            player_err.as_ref().map(|msg| {
                let code = map_error_code_str(player_err_code.as_deref(), dev_lost);
                let mut err = LuminaError::new(code, msg.clone());
                if let Some(ref p) = player_err_provider {
                    err = err.with_provider(p.clone());
                }
                err
            })
        });

        let mut pb = PlaybackState {
            status: lifecycle,
            state_code: lifecycle.as_i32(),
            state_name: lifecycle.as_legacy_state_name().to_string(),
            track: current_track,
            position_ms: pos_ms,
            duration_ms: dur_ms,
            timestamp_ms: now_unix_ms(),
            volume: vol,
            is_muted,
            repeat_mode,
            shuffle,
            audio_quality: effective_quality,
            active_device,
            active_zone_id,
            clock_source: clock_src,
            seek_epoch,
            is_seeking,
            dsp_bypassed: dsp_byp,
            strict_bit_perfect: strict,
            device_lost: dev_lost,
            swap_generation,
            playback_epoch,
            error: None,
            track_id: track_id.clone(),
            current_track_id: track_id,
            last_error: player_err,
            last_error_code: player_err_code,
            last_error_provider: player_err_provider,
        };

        if let Some(err) = structured_error {
            pb = pb.with_error(err);
        }

        pb
    }

    pub fn current_playback_epoch(&self) -> u64 {
        let local = self.playback_epoch.load(Ordering::SeqCst);
        let player_ep = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        local.max(player_ep)
    }

    pub fn accept_caller_epoch(&self, caller_epoch: Option<u64>) -> bool {
        let Some(ep) = caller_epoch.filter(|&e| e > 0) else {
            return true;
        };
        let mut cur = self.last_caller_epoch.load(Ordering::SeqCst);
        loop {
            if ep < cur {
                return false;
            }
            if ep == cur {
                return true;
            }
            match self.last_caller_epoch.compare_exchange_weak(
                cur,
                ep,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return true,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn advance_playback_epoch(&self, caller_epoch: Option<u64>) -> u64 {
        let player_ep = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        loop {
            let floor = cur.max(player_ep);
            let next = match caller_epoch {
                Some(ep) if ep > floor => ep,
                _ => floor.saturating_add(1).max(1),
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                next,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return next,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn is_loading_pending(&self) -> bool {
        self.play_generation.load(Ordering::SeqCst) > self.loaded_generation.load(Ordering::SeqCst)
    }

    pub fn sync_playback_epoch_from_player(&self, min_epoch: u64) -> u64 {
        let player_ep = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        let eff = min_epoch.max(player_ep);
        let prev = self.playback_epoch.fetch_max(eff, Ordering::SeqCst);
        prev.max(eff)
    }

    pub fn advance_after_epochless_skip(&self) -> u64 {
        let player_pb = self
            .player
            .as_ref()
            .map(|p| p.playback_epoch())
            .unwrap_or(0);
        let mut cur = self.playback_epoch.load(Ordering::SeqCst);
        loop {
            let candidate = if player_pb > cur {
                player_pb
            } else {
                cur.saturating_add(1).max(1)
            };
            match self.playback_epoch.compare_exchange_weak(
                cur,
                candidate,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return candidate,
                Err(actual) => cur = actual,
            }
        }
    }

    pub fn cancel_active_play_token(&self) {
        if let Ok(mut guard) = self.active_play_cancel.write()
            && let Some(token) = guard.take()
        {
            token.cancel();
        }
    }

    pub fn swap_play_cancel_token(&self, new_token: CancellationToken) {
        if let Ok(mut guard) = self.active_play_cancel.write()
            && let Some(prev) = guard.replace(new_token)
        {
            prev.cancel();
        }
    }
}

pub(crate) fn map_error_code_str(code: Option<&str>, device_lost: bool) -> LuminaErrorCode {
    if device_lost {
        return LuminaErrorCode::DeviceLost;
    }
    match code.unwrap_or("").to_ascii_lowercase().as_str() {
        "device_open_failed" => LuminaErrorCode::DeviceOpenFailed,
        "exclusive_mode_conflict" | "device_in_use" => LuminaErrorCode::ExclusiveModeConflict,
        "device_not_found" => LuminaErrorCode::DeviceNotFound,
        "device_lost" => LuminaErrorCode::DeviceLost,
        "stream_resolve_timeout" | "timeout" => LuminaErrorCode::StreamResolveTimeout,
        "stream_auth_required" | "unauthorized" | "forbidden" => {
            LuminaErrorCode::StreamAuthRequired
        }
        "network_disconnected" | "network" => LuminaErrorCode::NetworkDisconnected,
        "http_error" | "http_403" | "http_404" | "http_500" => LuminaErrorCode::HttpError,
        "decode_failed" => LuminaErrorCode::DecodeFailed,
        "unsupported_format" => LuminaErrorCode::UnsupportedFormat,
        "invalid_command" => LuminaErrorCode::InvalidCommand,
        "invalid_state" => LuminaErrorCode::InvalidState,
        "not_initialized" => LuminaErrorCode::NotInitialized,
        "database_error" => LuminaErrorCode::DatabaseError,
        _ => LuminaErrorCode::Internal,
    }
}
