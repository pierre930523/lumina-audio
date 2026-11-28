use std::sync::Arc;

use super::super::PullStreamConfig;
use crate::buffer::Consumer;
use crate::pipeline::ring_buffer::UnderrunGuard;
use crate::pipeline::rt_telemetry::RtTelemetry;
use crate::verification::WireSampleFormat;

/// Default pre-allocated capture capacity for [`super::MockAudioBackend`] (`2 MiB`).
pub(super) const DEFAULT_MOCK_CAPTURE_BYTES: usize = 2 * 1024 * 1024;

/// Strictly RT-safe pull processor owned by [`super::MockAudioBackend`] (or its render thread).
/// Performs ZERO locks, ZERO heap allocations, and ZERO logging inside `render_period_rt`.
pub(super) struct MockRtProcessor {
    consumer: Consumer<u8>,
    config: PullStreamConfig,
    telemetry: Arc<RtTelemetry>,
    period_scratch: Vec<u8>,
    pub(super) capture_buf: Vec<u8>,
    pub(super) capture_written: usize,
    dop_phase: bool,
}

impl MockRtProcessor {
    pub(super) fn new(
        config: PullStreamConfig,
        consumer: Consumer<u8>,
        telemetry: Arc<RtTelemetry>,
        capture_capacity_bytes: usize,
    ) -> Self {
        let ch = config.channels.max(1) as usize;
        let bpf = config.wire_format.bytes_per_sample().max(1) * ch;
        let scratch_frames = (config.buffer_frames.max(64) as usize).max(4096);
        Self {
            consumer,
            config,
            telemetry,
            period_scratch: vec![0u8; scratch_frames * bpf],
            capture_buf: vec![0u8; capture_capacity_bytes],
            capture_written: 0,
            dop_phase: false,
        }
    }

    /// Strictly RT-safe audio period render callback:
    /// ZERO locks, ZERO heap allocations, ZERO logging.
    #[inline]
    pub(super) fn render_period_rt(&mut self, frames: usize) -> usize {
        let ch = self.config.channels.max(1) as usize;
        let bpf = self.config.wire_format.bytes_per_sample().max(1) * ch;
        if bpf == 0 || frames == 0 {
            return 0;
        }
        let max_bytes = (self.period_scratch.len() / bpf) * bpf;
        let needed = (frames * bpf).min(max_bytes);
        if needed == 0 {
            return 0;
        }

        let popped = self
            .consumer
            .pop_slice_aligned(&mut self.period_scratch[..needed], bpf);

        if popped < needed {
            UnderrunGuard::handle_wire_underrun(
                &mut self.period_scratch[..needed],
                popped,
                self.config.wire_format,
                ch,
                self.config.strict_bit_perfect,
                &mut self.dop_phase,
                Some(&self.telemetry),
            );
        } else if matches!(
            self.config.wire_format,
            WireSampleFormat::Dop24In32MsbLe { .. }
        ) && popped > 0
        {
            self.dop_phase = self.period_scratch[popped - 1] == 0x05;
        }

        // Copy into pre-allocated fixed capture buffer (zero reallocations).
        let cap_rem = self.capture_buf.len().saturating_sub(self.capture_written);
        let to_capture = needed.min(cap_rem);
        if to_capture > 0 {
            let start = self.capture_written;
            self.capture_buf[start..start + to_capture]
                .copy_from_slice(&self.period_scratch[..to_capture]);
            self.capture_written += to_capture;
        }

        let valid_frames = popped / bpf;
        if valid_frames > 0 {
            self.telemetry.add_frames_rt(valid_frames as u64);
            let (peak_l, peak_r) =
                compute_wire_peaks_rt(&self.period_scratch[..popped], self.config.wire_format, ch);
            self.telemetry.set_peaks_rt(peak_l, peak_r);
            if let Some(tap) = crate::visualizer::try_global_tap() {
                tap.feed_wire(
                    &self.period_scratch[..popped],
                    self.config.wire_format,
                    self.config.channels,
                    self.config.sample_rate,
                );
            }
        }
        needed / bpf
    }
}

#[inline]
fn compute_wire_peaks_rt(bytes: &[u8], wire: WireSampleFormat, channels: usize) -> (f32, f32) {
    if matches!(
        wire,
        WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
    ) {
        return (0.0, 0.0);
    }
    let bps = wire.bytes_per_sample();
    let ch = channels.max(1);
    let bpf = bps * ch;
    if bpf == 0 {
        return (0.0, 0.0);
    }
    let mut peak_l = 0.0f32;
    let mut peak_r = 0.0f32;
    for frame in bytes.chunks_exact(bpf) {
        let l = extract_wire_sample_abs(frame, wire, 0);
        let r = if ch > 1 {
            extract_wire_sample_abs(frame, wire, 1)
        } else {
            l
        };
        if l > peak_l {
            peak_l = l;
        }
        if r > peak_r {
            peak_r = r;
        }
    }
    (peak_l, peak_r)
}

#[inline(always)]
fn extract_wire_sample_abs(frame: &[u8], wire: WireSampleFormat, ch_idx: usize) -> f32 {
    let bps = wire.bytes_per_sample();
    let off = ch_idx * bps;
    if off + bps > frame.len() {
        return 0.0;
    }
    let b = &frame[off..off + bps];
    let v = match wire {
        WireSampleFormat::Int16Le => i16::from_le_bytes([b[0], b[1]]) as f32 / 32_768.0,
        WireSampleFormat::Int24PackedLe => {
            let s = (b[0] as i32) | ((b[1] as i32) << 8) | ((b[2] as i8 as i32) << 16);
            s as f32 / 8_388_608.0
        }
        WireSampleFormat::Int24In32MsbLe | WireSampleFormat::Int32Le => {
            i32::from_le_bytes([b[0], b[1], b[2], b[3]]) as f32 / 2_147_483_648.0
        }
        WireSampleFormat::Float32Le => f32::from_le_bytes([b[0], b[1], b[2], b[3]]),
        WireSampleFormat::Float64Le => {
            f64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]) as f32
        }
        WireSampleFormat::Dop24In32MsbLe { .. } | WireSampleFormat::NativeDsd { .. } => 0.0,
    };
    if v.is_finite() { v.abs() } else { 0.0 }
}
