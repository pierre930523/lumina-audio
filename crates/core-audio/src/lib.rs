pub mod analysis;
pub mod backend;
pub mod buffer;
pub mod decoder;
pub mod device_manager;
pub mod dsd;
pub mod dsp;
pub mod engine;
pub mod error;
pub mod network_monitor;
pub mod pcm;
pub mod pipeline;
pub mod player;
pub mod signal_path;
pub mod stream;
pub mod streaming;
pub mod test_utils;
pub mod verification;
pub mod visualizer;

pub use analysis::analyze_local_track;
pub use backend::{
    AudioDeviceDescription, AudioOutputBackend, BackendConfig, BackendState, PullAudioBackend,
    PullStreamConfig,
    asio::AsioBackend,
    coreaudio::{CoreAudioBackend, enumerate_coreaudio_devices},
    cpal_shared::{
        CPAL_RT_CHUNK_SAMPLES, enumerate_cpal_devices, rank_sample_format,
        render_cpal_output_chunked, select_best_config_index,
    },
    device_fsm::{DEFAULT_POST_RELEASE_GUARD_DELAY, OutputDeviceFsm, OutputDeviceState},
    device_manager::{AudioDeviceManager, AudioFormatManager, DeviceExtraMeta, NegotiatedFormat},
    mock::{MockAudioBackend, MockBackend},
    wasapi::WasapiBackend,
};
pub use decoder::{
    dsd::{
        decimation::{DSD_SILENCE_BYTE, DsdChannelDecimator, DsdStereoDecimator},
        dop::DopFramer,
        dsdiff::{DsdiffHeader, DsdiffParser, DsdiffReader},
        dsf::{DsfHeader, DsfParser, DsfReader},
    },
    pcm::{AudioChunk, AudioDecoder, OpusSymphoniaDecoder, SymphoniaDecoder, SynthAudioDecoder},
    source_opener::{
        OpenedStreamDecoder, infer_extension_from_magic, open_decoder_for_path,
        open_decoder_for_source_spec, open_decoder_for_source_spec_async,
        open_decoder_for_source_spec_async_with_refresh, open_decoder_for_source_spec_with_refresh,
        open_decoder_for_stream, open_decoder_for_stream_cancellable,
    },
};
pub use dsp::{
    autoeq::{AutoEqParser, AutoEqProfile, parse_autoeq_profile_dto, parse_autoeq_txt},
    biquad::{BiquadCoefficients, BiquadFilter, BiquadState, FilterType},
    bypass::DspPipeline,
    crossfeed::CrossfeedFilter,
    gain::{ReplayGain, ReplayGainConfig, ReplayGainMode},
    limiter::LookaheadLimiter,
    peq::{ParametricBand, ParametricEq},
    resampler::{StreamingSincResampler, adapt_channels_f64, adapt_channels_f64_into},
};
pub use engine::{ActiveTrackMeta, AudioPlayer, PlaybackLifecycleState};
pub use error::{BackendError, CoreAudioError, DecoderError, DsdError, DspError};
pub use pipeline::{
    ring_buffer::{CachePadded, Consumer, Producer, SpscRingBuffer, UnderrunGuard},
    rt_telemetry::{RtErrorCode, RtTelemetry},
};
pub use signal_path::{SignalPathContext, SignalPathEngine};
pub use stream::{
    HttpRangeMediaSource, StreamOrigin, StreamSource, is_playlist_extension, parse_m3u_entries,
    parse_pls_entries, resolve_playlist_url, resolve_playlist_url_with_cancel,
};
pub use verification::{
    AudioVerificationEngine, VerificationConfig, VerificationTapProducer, WirePacker,
    WireSampleFormat,
};
pub use visualizer::{
    VisualizerRingBuffer, VisualizerTap, global_tap, init_global_tap, try_global_tap,
};

pub use core_types::DeckTrackMetadata;
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
