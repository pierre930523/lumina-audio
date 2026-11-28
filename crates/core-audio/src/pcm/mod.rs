//! Backward-compatible thin re-export shim for [`crate::decoder::pcm`].

pub mod decoder;
pub mod opus;
pub mod synth;

pub use crate::decoder::pcm::{
    AudioChunk, AudioDecoder, DecodedTrackMetadata, OpusSymphoniaDecoder, SymphoniaDecoder,
    SynthAudioDecoder, register_opus_codec,
};
