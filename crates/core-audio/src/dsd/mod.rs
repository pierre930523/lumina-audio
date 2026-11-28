//! Backward-compatible thin re-export shim for [`crate::decoder::dsd`].

pub mod decimation;
pub mod dop;
pub mod dsdiff;
pub mod dsf;

pub use crate::decoder::dsd::{
    DSD_SILENCE_BYTE, DopFramer, DsdChannelDecimator, DsdStereoDecimator, DsdiffHeader,
    DsdiffParser, DsdiffReader, DsfHeader, DsfParser, DsfReader,
};
