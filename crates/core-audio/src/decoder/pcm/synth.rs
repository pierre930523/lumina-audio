use std::f64::consts::PI;
use std::time::Duration;

use core_types::{AudioCodec, AudioFormat};

use super::{AudioChunk, AudioDecoder};
use crate::error::DecoderError;

const DEFAULT_SAMPLE_RATE_HZ: u32 = 48_000;
const DEFAULT_CHANNELS: u16 = 2;
const DEFAULT_DURATION_MS: u64 = 245_000;
const CHUNK_FRAMES: usize = 2048;

/// Genuine synthesized PCM audio decoder for built-in demo / catalog tracks
/// when no physical file or remote URL is bound.
///
/// Generates deterministic, pleasant multi-harmonic chord + pentatonic arpeggio
/// PCM frames as a stateless function of `frame_cursor` so seeking is exact.
pub struct SynthAudioDecoder {
    format: AudioFormat,
    duration: Duration,
    total_frames: u64,
    frame_cursor: u64,
    root_hz: f64,
    pentatonic_ratios: [f64; 5],
}

impl SynthAudioDecoder {
    pub fn new(
        track_id: impl AsRef<str>,
        title: impl AsRef<str>,
        duration_ms: u64,
        sample_rate_hz: u32,
        channels: u16,
    ) -> Self {
        let rate = if sample_rate_hz == 0 {
            DEFAULT_SAMPLE_RATE_HZ
        } else {
            sample_rate_hz.max(8_000)
        };
        let ch = if channels == 0 {
            DEFAULT_CHANNELS
        } else {
            channels.clamp(1, 8)
        };
        let eff_dur_ms = if duration_ms == 0 {
            DEFAULT_DURATION_MS
        } else {
            duration_ms
        };
        let total_frames = (((eff_dur_ms as u128) * (rate as u128)) / 1000).max(1) as u64;
        let format = AudioFormat::pcm(AudioCodec::Flac, rate, 24, ch as u8)
            .expect("valid synth AudioFormat");

        let seed = fnv1a_64(track_id.as_ref().as_bytes()) ^ fnv1a_64(title.as_ref().as_bytes());
        const ROOTS: [f64; 7] = [220.0, 246.94, 261.63, 293.66, 329.63, 349.23, 392.0];
        let root_hz = ROOTS[(seed as usize) % ROOTS.len()];

        // Minor/major pentatonic intervals for a warm ambient electric-piano feel
        let pentatonic_ratios = if seed.is_multiple_of(2) {
            [1.0, 1.125, 1.25, 1.5, 1.6667] // major pentatonic
        } else {
            [1.0, 1.2, 1.3333, 1.5, 1.7778] // minor pentatonic
        };

        Self {
            format,
            duration: Duration::from_millis(eff_dur_ms),
            total_frames,
            frame_cursor: 0,
            root_hz,
            pentatonic_ratios,
        }
    }
}

impl AudioDecoder for SynthAudioDecoder {
    fn format(&self) -> &AudioFormat {
        &self.format
    }

    fn duration(&self) -> Option<Duration> {
        Some(self.duration)
    }

    fn total_frames(&self) -> Option<u64> {
        Some(self.total_frames)
    }

    fn next_chunk(&mut self) -> Result<Option<AudioChunk>, DecoderError> {
        if self.frame_cursor >= self.total_frames {
            return Ok(None);
        }

        let ch = self.format.channels as usize;
        let rate = self.format.sample_rate_hz as f64;
        let remaining = self.total_frames - self.frame_cursor;
        let frames = remaining.min(CHUNK_FRAMES as u64) as usize;
        let mut samples = Vec::with_capacity(frames * ch);

        let fade_in_frames = (0.04 * rate) as u64;
        let fade_out_frames = (0.08 * rate) as u64;
        let note_period_s = 0.5;

        for i in 0..frames {
            let idx = self.frame_cursor + (i as u64);
            let t = (idx as f64) / rate;

            // Warm triad pad (root, fifth, octave)
            let pad_l = 0.10 * (2.0 * PI * self.root_hz * t).sin()
                + 0.06 * (2.0 * PI * (self.root_hz * 1.5) * t + 0.3).sin()
                + 0.04 * (2.0 * PI * (self.root_hz * 2.0) * t + 0.7).sin();
            let pad_r = 0.10 * (2.0 * PI * self.root_hz * t + 0.15).sin()
                + 0.06 * (2.0 * PI * (self.root_hz * 1.5) * t + 0.5).sin()
                + 0.04 * (2.0 * PI * (self.root_hz * 2.0) * t + 1.0).sin();

            // Gentle pentatonic arpeggio chime
            let step = (t / note_period_s).floor() as usize;
            let local_t = t - (step as f64) * note_period_s;
            let env = (1.0 - (-local_t * 60.0).exp()) * (-local_t * 4.5).exp();
            let note_hz =
                self.root_hz * 2.0 * self.pentatonic_ratios[step % self.pentatonic_ratios.len()];
            let chime = 0.12
                * env
                * ((2.0 * PI * note_hz * t).sin() + 0.35 * (4.0 * PI * note_hz * t).sin());

            let pan = if step.is_multiple_of(2) { 0.65 } else { 0.35 };
            let mut l = pad_l + chime * pan;
            let mut r = pad_r + chime * (1.0 - pan);

            // Track-level edge fade
            let mut edge_gain = 1.0;
            if fade_in_frames > 0 && idx < fade_in_frames {
                edge_gain *= (idx as f64) / (fade_in_frames as f64);
            }
            if fade_out_frames > 0 && idx + fade_out_frames > self.total_frames {
                let tail = self.total_frames.saturating_sub(idx);
                edge_gain *= (tail as f64) / (fade_out_frames as f64);
            }
            l *= edge_gain;
            r *= edge_gain;

            match ch {
                1 => samples.push(0.5 * (l + r)),
                2 => {
                    samples.push(l);
                    samples.push(r);
                }
                _ => {
                    for c in 0..ch {
                        samples.push(if c % 2 == 0 { l } else { r });
                    }
                }
            }
        }

        self.frame_cursor += frames as u64;

        Ok(Some(AudioChunk::PcmF64 {
            samples,
            channels: self.format.channels as u16,
            sample_rate: self.format.sample_rate_hz,
        }))
    }

    fn seek(&mut self, time: Duration) -> Result<(), DecoderError> {
        let target = ((time.as_secs_f64() * (self.format.sample_rate_hz as f64)).round() as u64)
            .min(self.total_frames);
        self.frame_cursor = target;
        Ok(())
    }
}

fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}
