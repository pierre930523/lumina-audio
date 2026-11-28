//! Hard real-time audio pipeline primitives:
//! - [`ring_buffer`]: Lock-free, epoch-aware SPSC ring buffer and [`UnderrunGuard`].
//! - [`rt_telemetry`]: Cache-line-padded, strictly RT-safe atomic telemetry & error reporting.
//! - [`fade`]: Ring sizing/watermark math and Strict Bit-Perfect-gated RT micro-fade helpers.

pub mod decode_worker;
pub mod fade;
pub mod ring_buffer;
pub mod rt_telemetry;

pub use fade::{
    AUTO_PREDECODE_REMAINING_MS, AudioFadeControl, FadeDirection, FadeTarget, LinearFadeState,
    MICRO_FADE_MS, MISMATCH_ALIGNMENT_OFFSET_MS, MISMATCH_CROSSFADE_MS, STANDBY_PREDECODE_MS,
    STARTUP_WATERMARK_MS, TARGET_RING_BUFFER_SECS, apply_fade_ramp_to_wire_bytes,
    apply_fade_ramp_to_wire_bytes_guarded, compute_pcm_ring_samples,
    compute_startup_watermark_bytes, compute_startup_watermark_samples, compute_wire_ring_bytes,
    crossfade_wire_bytes, crossfade_wire_bytes_guarded, fade_out_f32_tail,
    fade_out_f32_tail_guarded, fade_out_wire_tail, fade_out_wire_tail_guarded, is_fade_permitted,
};
pub use ring_buffer::{
    CachePadded, Consumer, EpochShared, Producer, RingBufferControl, SpscRingBuffer, UnderrunGuard,
};
pub use rt_telemetry::{RtErrorCode, RtTelemetry};
