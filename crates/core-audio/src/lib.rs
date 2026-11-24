pub mod backend;
pub mod buffer;
pub mod device_manager;
pub mod dsd;
pub mod dsp;
pub mod error;
pub mod network_monitor;
pub mod pcm;
pub mod player;
pub mod signal_path;
pub mod stream;
pub mod streaming;
pub mod test_utils;
pub mod verification;
pub mod visualizer;

pub use device_manager::{AudioDeviceManager, AudioFormatManager, NegotiatedFormat};
pub use verification::{
    AudioVerificationEngine, VerificationConfig, VerificationTapProducer, WireSampleFormat,
};
pub use visualizer::{global_tap, VisualizerRingBuffer, VisualizerTap};

pub use backend::{
    asio::AsioBackend, mock::MockBackend, wasapi::WasapiBackend, AudioDeviceDescription,
    AudioOutputBackend, BackendConfig, BackendState,
};
pub use buffer::{CachePadded, Consumer, Producer, SpscRingBuffer};
pub use dsd::{
    decimation::{DsdChannelDecimator, DsdStereoDecimator, DSD_SILENCE_BYTE},
    dop::DopFramer,
    dsdiff::{DsdiffHeader, DsdiffParser, DsdiffReader},
    dsf::{DsfHeader, DsfParser, DsfReader},
};
pub use dsp::{
    autoeq::{parse_autoeq_profile_dto, parse_autoeq_txt, AutoEqParser, AutoEqProfile},
    biquad::{BiquadCoefficients, BiquadFilter, BiquadState, FilterType},
    bypass::DspPipeline,
    crossfeed::CrossfeedFilter,
    gain::{ReplayGain, ReplayGainConfig, ReplayGainMode},
    limiter::LookaheadLimiter,
    peq::{ParametricBand, ParametricEq},
};
pub use error::{BackendError, CoreAudioError, DecoderError, DsdError, DspError};
pub use pcm::{
    AudioChunk, AudioDecoder, OpusSymphoniaDecoder, SymphoniaDecoder, SynthAudioDecoder,
};
pub use player::{
    enumerate_cpal_devices, infer_extension_from_magic, open_decoder_for_path,
    open_decoder_for_stream, open_decoder_for_stream_cancellable, rank_sample_format,
    select_best_config_index, ActiveTrackMeta, AudioPlayer, OpenedStreamDecoder,
    PlaybackLifecycleState, StreamingSincResampler,
};
pub use signal_path::{SignalPathContext, SignalPathEngine};
pub use stream::{
    is_playlist_extension, parse_m3u_entries, parse_pls_entries, resolve_playlist_url,
    resolve_playlist_url_with_cancel, HttpRangeMediaSource, StreamOrigin, StreamSource,
};

use core_types::{AudioFormat, OutputBackendKind, SignalPath};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeqBand {
    pub frequency_hz: f64,
    pub gain_db: f64,
    pub q_factor: f64,
    pub enabled: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DspPipelineConfig {
    pub bypass: bool,
    pub peq_bands: Vec<PeqBand>,
    pub crossfeed_enabled: bool,
    pub replay_gain_db: Option<f64>,
}

/// Constructs an explicit, transparent Roon-style Signal Path for the current playback chain.
pub fn build_signal_path(
    source_label: &str,
    format: &AudioFormat,
    dsp: &DspPipelineConfig,
    resampled_to_hz: Option<u32>,
    backend: OutputBackendKind,
    device_name: &str,
) -> SignalPath {
    let dsp_active = !dsp.bypass
        && (!dsp.peq_bands.is_empty() || dsp.crossfeed_enabled || dsp.replay_gain_db.is_some());

    let ctx = SignalPathContext {
        source_label,
        format,
        dsp_bypass: dsp.bypass,
        dsp_active,
        resampled_to_hz,
        backend,
        device_name,
    };

    SignalPathEngine::build(&ctx)
}
