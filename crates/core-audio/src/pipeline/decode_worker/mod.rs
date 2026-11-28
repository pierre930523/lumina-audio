//! Background audio decode, DSP, resampling, and wire-packing workers.
//!
//! Runs strictly off the real-time audio thread. Feeds lock-free SPSC ring buffers
//! using pre-allocated reusable buffers (`WirePacker`, `StreamingSincResampler::process_into`,
//! `adapt_channels_f64_into`) and atomic generation caching for DSP/policy config.

mod diagnostics;
mod dsp_stage;
mod gapless;
mod loop_impl;
mod pcm_stage;
mod seek;
mod wire_loop;

#[allow(unused_imports)]
pub(crate) use diagnostics::{is_opus_dump_enabled, maybe_log_underrun_off_rt};
#[allow(unused_imports)]
pub(crate) use dsp_stage::{apply_live_dsp_for_deck, check_wire_chunk_format_mismatch};
pub(crate) use loop_impl::decode_loop;
#[allow(unused_imports)]
pub(crate) use seek::{
    flush_ring_and_seek, is_fatal_seek_io_error, maybe_reclaim_idle_memory, wait_at_eof,
};
pub(crate) use wire_loop::decode_wire_loop;
