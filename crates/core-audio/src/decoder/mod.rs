//! Unified PCM & DSD decoding abstraction.
//!
//! Houses the canonical implementations of [`AudioDecoder`], [`AudioChunk`],
//! [`SymphoniaDecoder`], [`OpusSymphoniaDecoder`], [`SynthAudioDecoder`],
//! [`DopFramer`], [`DsfReader`], [`DsdiffReader`], and [`DsdStereoDecimator`].
//!
//! Legacy paths `crate::pcm::*` and `crate::dsd::*` re-export these modules for
//! backward compatibility.

pub mod dsd;
pub mod pcm;
pub mod source_opener;

pub use dsd::{
    decimation::{DSD_SILENCE_BYTE, DsdChannelDecimator, DsdStereoDecimator},
    dop::DopFramer,
    dsdiff::{DsdiffHeader, DsdiffParser, DsdiffReader},
    dsf::{DsfHeader, DsfParser, DsfReader},
};
pub use pcm::{
    AudioChunk, AudioDecoder, DecodedTrackMetadata, OpusSymphoniaDecoder, SymphoniaDecoder,
    SynthAudioDecoder,
    decoder::{SeekOutcome, build_probe_hint, extension_from_mime_type},
    register_opus_codec,
};
pub use source_opener::{
    OpenedStreamDecoder, infer_extension_from_magic, open_decoder_for_path,
    open_decoder_for_source_spec, open_decoder_for_source_spec_async,
    open_decoder_for_source_spec_async_with_refresh, open_decoder_for_source_spec_with_refresh,
    open_decoder_for_stream, open_decoder_for_stream_cancellable,
};
