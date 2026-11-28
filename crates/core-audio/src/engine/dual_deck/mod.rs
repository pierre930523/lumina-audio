//! Dual-deck lock-free playback feeders (`DualDeckPcmFeeder`, `DualDeckWireFeeder`),
//! RT-safe transition ring (`DualDeckControl`), and background `ThreadReaper`.

mod control;
mod control_lifecycle;
mod decode_handle;
mod pcm_feeder;
mod pcm_loop;
mod pcm_render;
mod reaper;
mod transition;
mod wire_feeder;
mod wire_render;
mod wire_transitions;

pub(crate) use control::DualDeckControl;
pub(crate) use decode_handle::{
    ActiveOutputProfile, DeckDecodeHandle, DeckMetadataSnapshot, RtPcmInboxPayload,
    RtWireInboxPayload, StandbyWakeState,
};
pub(crate) use pcm_feeder::{DualDeckPcmFeeder, PcmRenderOutcome};
pub(crate) use reaper::{DecodeThreadGuard, ThreadReaper};
pub(crate) use transition::{RtTransitionEvent, RtTransitionKind};
pub(crate) use wire_feeder::{DualDeckWireFeeder, DualDeckWireOutcome, fill_wire_silence};

#[inline]
pub(crate) fn sanitize_and_clamp_f32(sample: f32, max_pos: f32) -> f32 {
    if sample.is_finite() {
        sample.clamp(-1.0, max_pos)
    } else {
        0.0
    }
}
