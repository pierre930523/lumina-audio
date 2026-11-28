//! DSP parameter conversion, ReplayGain computation, mismatch callback, and error helpers.

use std::sync::Arc;
use std::sync::atomic::Ordering;

use core_types::{
    DspPipelineConfig as SharedDspConfig, PeqBandConfig, PeqFilterKind, PlaybackLifecycleState,
    ReplayGainConfig as SharedReplayGainConfig, ReplayGainMode as SharedReplayGainMode,
    StreamSourceSpec,
};

use crate::dsp::{
    BiquadCoefficients, FilterType, ParametricBand, ReplayGain,
    ReplayGainConfig as InternalReplayGainConfig, ReplayGainMode as InternalReplayGainMode,
};
use crate::engine::{AudioPlayer, PlayerInner, TrackReplayGainTags, default_shared_dsp_config};
use crate::error::{CoreAudioError, DspError};
use crate::streaming::FormatMismatchCallback;

pub(super) fn map_filter_kind(kind: PeqFilterKind) -> FilterType {
    match kind {
        PeqFilterKind::Peaking => FilterType::Peaking,
        PeqFilterKind::LowShelf => FilterType::LowShelf,
        PeqFilterKind::HighShelf => FilterType::HighShelf,
        PeqFilterKind::LowPass => FilterType::LowPass,
        PeqFilterKind::HighPass => FilterType::HighPass,
    }
}

pub(super) fn validate_shared_dsp_config(cfg: &SharedDspConfig) -> Result<(), CoreAudioError> {
    if !cfg.replay_gain.preamp_db.is_finite() || cfg.replay_gain.preamp_db.abs() > 60.0 {
        return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
            format!(
                "ReplayGain preamp out of bounds: {}",
                cfg.replay_gain.preamp_db
            ),
        )));
    }
    for band in &cfg.peq_bands {
        if !band.frequency_hz.is_finite()
            || band.frequency_hz <= 0.0
            || band.frequency_hz > 100_000.0
        {
            return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
                format!("PEQ frequency out of bounds: {}", band.frequency_hz),
            )));
        }
        if !band.q_factor.is_finite() || band.q_factor <= 0.0 || band.q_factor > 100.0 {
            return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
                format!("PEQ Q factor out of bounds: {}", band.q_factor),
            )));
        }
        if !band.gain_db.is_finite() || band.gain_db.abs() > 60.0 {
            return Err(CoreAudioError::Dsp(DspError::InvalidFilterParameters(
                format!("PEQ gain out of bounds (+/-60dB): {}", band.gain_db),
            )));
        }
        BiquadCoefficients::compute(
            map_filter_kind(band.filter_type),
            48_000.0,
            band.frequency_hz,
            band.gain_db,
            band.q_factor,
        )?;
    }
    Ok(())
}

pub(crate) fn to_parametric_bands(bands: &[PeqBandConfig]) -> Vec<ParametricBand> {
    bands
        .iter()
        .map(|b| ParametricBand {
            filter_type: map_filter_kind(b.filter_type),
            frequency_hz: b.frequency_hz,
            gain_db: b.gain_db,
            q_factor: b.q_factor,
            enabled: b.enabled,
        })
        .collect()
}

pub(crate) fn to_internal_replay_gain(
    cfg: &SharedReplayGainConfig,
    tags: &TrackReplayGainTags,
) -> InternalReplayGainConfig {
    match cfg.mode {
        SharedReplayGainMode::Off => {
            if tags.from_streaming_spec && tags.track_db.is_some() {
                InternalReplayGainConfig {
                    mode: InternalReplayGainMode::Track,
                    preamp_db: 0.0,
                    track_gain_db: tags.track_db,
                    track_peak: tags.track_peak,
                    album_gain_db: tags.album_db,
                    album_peak: tags.album_peak,
                    prevent_clipping: cfg.prevent_clipping,
                }
            } else {
                InternalReplayGainConfig {
                    mode: InternalReplayGainMode::Track,
                    preamp_db: 0.0,
                    track_gain_db: None,
                    track_peak: None,
                    album_gain_db: None,
                    album_peak: None,
                    prevent_clipping: false,
                }
            }
        }
        SharedReplayGainMode::Track => InternalReplayGainConfig {
            mode: InternalReplayGainMode::Track,
            preamp_db: cfg.preamp_db,
            track_gain_db: tags.track_db,
            track_peak: tags.track_peak,
            album_gain_db: tags.album_db,
            album_peak: tags.album_peak,
            prevent_clipping: cfg.prevent_clipping,
        },
        SharedReplayGainMode::Album => InternalReplayGainConfig {
            mode: InternalReplayGainMode::Album,
            preamp_db: cfg.preamp_db,
            track_gain_db: tags.track_db,
            track_peak: tags.track_peak,
            album_gain_db: tags.album_db,
            album_peak: tags.album_peak,
            prevent_clipping: cfg.prevent_clipping,
        },
    }
}

pub(crate) fn compute_effective_replay_gain_db(
    cfg: &SharedReplayGainConfig,
    tags: &TrackReplayGainTags,
) -> Option<f64> {
    if cfg.mode == SharedReplayGainMode::Off
        && !(tags.from_streaming_spec && tags.track_db.is_some())
    {
        return None;
    }
    let internal = to_internal_replay_gain(cfg, tags);
    let rg = ReplayGain::new(internal);
    let linear = rg.linear_gain();
    if (linear - 1.0).abs() > 1e-6 {
        Some(20.0 * linear.log10())
    } else {
        None
    }
}

pub(crate) fn build_mismatch_callback(
    inner: &Arc<PlayerInner>,
    spec: &StreamSourceSpec,
) -> Option<FormatMismatchCallback> {
    let cmd_tx = inner.cmd_tx_slot.get()?.clone();
    let weak_inner = Arc::downgrade(inner);
    let spec_clone = spec.clone();
    Some(Arc::new(move |mismatch_key, reason| {
        tracing::warn!(
            "L2 FormatMismatch detected for {mismatch_key:?}: {reason:?}; triggering dual-track recovery"
        );
        if let Some(strong_inner) = weak_inner.upgrade() {
            let player = AudioPlayer {
                inner: strong_inner,
                cmd_tx: cmd_tx.clone(),
            };
            let _ = player.trigger_format_mismatch_recovery(mismatch_key, spec_clone.clone());
        }
    }))
}

pub(crate) fn position_ms_from_inner(inner: &PlayerInner) -> u64 {
    let rate = inner.out_sample_rate.load(Ordering::Relaxed) as u128;
    if rate == 0 {
        return 0;
    }
    let frames = inner.frames_rendered.load(Ordering::Relaxed) as u128;
    ((frames * 1000) / rate) as u64
}

pub(crate) fn record_playback_error(inner: &PlayerInner, msg: String) {
    let lower = msg.to_ascii_lowercase();
    let inferred_code = if lower.contains("device") || lower.contains("invalidated") {
        inner.device_lost.store(true, Ordering::SeqCst);
        Some("DEVICE_LOST")
    } else {
        None
    };
    record_playback_error_with_code(inner, msg, inferred_code, None);
}

pub(crate) fn record_playback_error_with_code(
    inner: &PlayerInner,
    msg: String,
    code: Option<&str>,
    provider: Option<String>,
) {
    if code == Some("DEVICE_LOST") {
        inner.device_lost.store(true, Ordering::SeqCst);
    }
    if let Ok(mut err_lock) = inner.last_error.write() {
        *err_lock = Some(msg);
    }
    if let Ok(mut code_lock) = inner.last_error_code.write() {
        *code_lock = code.map(str::to_string);
    }
    if let Ok(mut prov_lock) = inner.last_error_provider.write() {
        *prov_lock = provider;
    }
    inner.stopped.store(true, Ordering::SeqCst);
    inner
        .state_code
        .store(PlaybackLifecycleState::Error as i32, Ordering::SeqCst);
}

pub(crate) fn is_any_dsp_active(inner: &PlayerInner) -> bool {
    let cfg = inner
        .dsp_config
        .read()
        .map(|g| g.clone())
        .unwrap_or_else(|_| default_shared_dsp_config());
    if inner.dsp_bypassed.load(Ordering::Relaxed) || cfg.bypass {
        return false;
    }
    let peq_active = cfg.peq_bands.iter().any(|b| {
        b.enabled
            && (b.gain_db.abs() > 1e-4
                || matches!(
                    b.filter_type,
                    PeqFilterKind::LowPass | PeqFilterKind::HighPass
                ))
    });
    if peq_active || cfg.crossfeed.enabled {
        return true;
    }
    let rg_tags = inner
        .track_replay_gain
        .read()
        .map(|g| g.clone())
        .unwrap_or_default();
    compute_effective_replay_gain_db(&cfg.replay_gain, &rg_tags).is_some()
}
