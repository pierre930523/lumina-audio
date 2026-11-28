//! Backward-compatible thin re-export shim for [`crate::engine`], [`crate::pipeline::fade`],
//! [`crate::decoder::source_opener`], [`crate::dsp::resampler`], and [`crate::backend::cpal_shared`].

pub use crate::backend::cpal_shared::{
    enumerate_cpal_devices, rank_sample_format, select_best_config_index,
};
pub use crate::decoder::source_opener::{
    OpenedStreamDecoder, infer_extension_from_magic, open_decoder_for_path,
    open_decoder_for_source_spec, open_decoder_for_source_spec_async,
    open_decoder_for_source_spec_async_with_refresh, open_decoder_for_source_spec_with_refresh,
    open_decoder_for_stream, open_decoder_for_stream_cancellable,
};
pub use crate::dsp::resampler::StreamingSincResampler;
pub use crate::engine::{
    ActiveTrackMeta, AudioPlayer, DEFAULT_IDLE_RECLAIM_THRESHOLD, OutputDeviceState,
    PlaybackLifecycleState, PlayerOrigin,
};
pub use crate::pipeline::fade::{
    AUTO_PREDECODE_REMAINING_MS, AudioFadeControl, FadeDirection, FadeTarget, LinearFadeState,
    MICRO_FADE_MS, MISMATCH_ALIGNMENT_OFFSET_MS, MISMATCH_CROSSFADE_MS, STANDBY_PREDECODE_MS,
    STARTUP_WATERMARK_MS, TARGET_RING_BUFFER_SECS, apply_fade_ramp_to_wire_bytes,
    apply_fade_ramp_to_wire_bytes_guarded, compute_pcm_ring_samples,
    compute_startup_watermark_bytes, compute_startup_watermark_samples, compute_wire_ring_bytes,
    crossfade_wire_bytes, crossfade_wire_bytes_guarded, fade_out_f32_tail,
    fade_out_f32_tail_guarded, fade_out_wire_tail, fade_out_wire_tail_guarded, is_fade_permitted,
};

#[allow(unused_imports)]
pub(crate) use crate::engine::dual_deck::{
    DualDeckControl, DualDeckWireFeeder, DualDeckWireOutcome, RtTransitionEvent, RtTransitionKind,
    RtWireInboxPayload, fill_wire_silence,
};
