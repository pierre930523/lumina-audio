//! Off-RT diagnostic utilities: Opus 5s WAV dumper and throttled underrun logger.

use std::fs::File;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use core_types::AudioCodec;

use crate::decoder::pcm::AudioChunk;
use crate::engine::PlayerInner;

#[inline]
pub(crate) fn is_opus_dump_enabled() -> bool {
    std::env::var_os("LUMINA_DUMP_OPUS_WAV").is_some_and(|v| v == "1")
}

fn write_ieee_f32_wav(
    path: &Path,
    sample_rate: u32,
    channels: u16,
    samples: &[f32],
) -> std::io::Result<()> {
    use std::io::{BufWriter, Write};

    let ch = channels.max(1);
    let bits_per_sample: u16 = 32;
    let block_align = ch * (bits_per_sample / 8);
    let byte_rate = sample_rate.saturating_mul(block_align as u32);
    let max_samples =
        u32::try_from(samples.len().saturating_mul(4)).unwrap_or(u32::MAX - 36) as usize / 4;
    let data_bytes = (max_samples * 4) as u32;
    let riff_size = 36u32.saturating_add(data_bytes);

    let file = File::create(path)?;
    let mut w = BufWriter::new(file);
    w.write_all(b"RIFF")?;
    w.write_all(&riff_size.to_le_bytes())?;
    w.write_all(b"WAVE")?;
    w.write_all(b"fmt ")?;
    w.write_all(&16u32.to_le_bytes())?;
    w.write_all(&3u16.to_le_bytes())?; // WAVE_FORMAT_IEEE_FLOAT
    w.write_all(&ch.to_le_bytes())?;
    w.write_all(&sample_rate.to_le_bytes())?;
    w.write_all(&byte_rate.to_le_bytes())?;
    w.write_all(&block_align.to_le_bytes())?;
    w.write_all(&bits_per_sample.to_le_bytes())?;
    w.write_all(b"data")?;
    w.write_all(&data_bytes.to_le_bytes())?;
    for &s in &samples[..max_samples] {
        w.write_all(&s.to_le_bytes())?;
    }
    w.flush()
}

/// Off-RT diagnostic capturer gated behind `LUMINA_DUMP_OPUS_WAV=1`.
/// Collects the first 5 seconds of raw Opus-decoded PCM before DSP/resampling/clipping,
/// writes an IEEE Float32 WAV to `%TEMP%`, and logs `max_sample_abs`, `ring_buffer_underrun_count`,
/// and output `(sample_rate, channels, sample_format)`.
pub(super) struct OpusDiagnosticDumper {
    inner: Arc<PlayerInner>,
    pcm_rate: u32,
    pcm_channels: u16,
    out_sample_rate: u32,
    out_channels: u16,
    out_sample_format: String,
    max_samples: usize,
    samples: Vec<f32>,
    max_sample_abs: f32,
    flushed: bool,
}

impl OpusDiagnosticDumper {
    pub(super) fn maybe_new(
        codec: AudioCodec,
        inner: &Arc<PlayerInner>,
        out_sample_rate: u32,
        out_channels: u16,
        out_sample_format: String,
    ) -> Option<Self> {
        if codec != AudioCodec::Opus || !is_opus_dump_enabled() {
            return None;
        }
        Some(Self {
            inner: Arc::clone(inner),
            pcm_rate: 0,
            pcm_channels: 0,
            out_sample_rate,
            out_channels,
            out_sample_format,
            max_samples: 0,
            samples: Vec::new(),
            max_sample_abs: 0.0,
            flushed: false,
        })
    }

    pub(super) fn record_chunk(&mut self, chunk: &AudioChunk) {
        if self.flushed {
            return;
        }
        let AudioChunk::PcmF32 {
            samples,
            channels,
            sample_rate,
        } = chunk
        else {
            return;
        };
        if self.max_samples == 0 {
            let sr = (*sample_rate).max(8_000);
            let ch = (*channels).max(1);
            self.pcm_rate = sr;
            self.pcm_channels = ch;
            self.max_samples = 5usize
                .saturating_mul(sr as usize)
                .saturating_mul(ch as usize);
            self.samples.reserve(self.max_samples.min(480_000));
        }
        for &s in samples {
            if s.is_finite() {
                let abs = s.abs();
                if abs > self.max_sample_abs {
                    self.max_sample_abs = abs;
                }
            }
        }
        let remaining = self.max_samples.saturating_sub(self.samples.len());
        let to_take = remaining.min(samples.len());
        self.samples.extend_from_slice(&samples[..to_take]);
        if self.samples.len() >= self.max_samples {
            self.flush();
        }
    }

    fn flush(&mut self) {
        if self.flushed {
            return;
        }
        self.flushed = true;
        if self.samples.is_empty() || self.pcm_rate == 0 || self.pcm_channels == 0 {
            return;
        }
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let wav_path = std::env::temp_dir().join(format!(
            "lumina_opus_dump_{}_{}.wav",
            std::process::id(),
            millis
        ));
        let write_res =
            write_ieee_f32_wav(&wav_path, self.pcm_rate, self.pcm_channels, &self.samples);
        let underruns = self
            .inner
            .ring_buffer_underrun_count
            .load(Ordering::Relaxed);
        match write_res {
            Ok(()) => {
                tracing::info!(
                    wav_path = %wav_path.display(),
                    pcm_sample_rate = self.pcm_rate,
                    pcm_channels = self.pcm_channels,
                    dumped_samples = self.samples.len(),
                    max_sample_abs = self.max_sample_abs,
                    ring_buffer_underrun_count = underruns,
                    output_sample_rate = self.out_sample_rate,
                    output_channels = self.out_channels,
                    output_sample_format = %self.out_sample_format,
                    "[LuminaOpusDiag] Opus 5s raw PCM WAV dump completed"
                );
            }
            Err(err) => {
                tracing::warn!(
                    wav_path = %wav_path.display(),
                    error = %err,
                    max_sample_abs = self.max_sample_abs,
                    ring_buffer_underrun_count = underruns,
                    output_sample_rate = self.out_sample_rate,
                    output_channels = self.out_channels,
                    output_sample_format = %self.out_sample_format,
                    "[LuminaOpusDiag] Failed to write Opus WAV dump"
                );
            }
        }
        self.samples.clear();
        self.samples.shrink_to_fit();
    }
}

impl Drop for OpusDiagnosticDumper {
    fn drop(&mut self) {
        self.flush();
    }
}

/// Non-RT throttled logger for audio ring-buffer underruns (at most once per second).
///
/// Called exclusively from background decode threads — NEVER from audio output callbacks.
pub(crate) fn maybe_log_underrun_off_rt(
    inner: &PlayerInner,
    last_logged_count: &mut u64,
    last_logged_at: &mut Instant,
) {
    let count = inner.ring_buffer_underrun_count.load(Ordering::Relaxed);
    if count > *last_logged_count && last_logged_at.elapsed() >= Duration::from_secs(1) {
        let delta = count - *last_logged_count;
        let bms = inner.buffered_ms.load(Ordering::Relaxed);
        *last_logged_count = count;
        *last_logged_at = Instant::now();
        tracing::warn!(
            ring_buffer_underrun_count = count,
            underrun_delta = delta,
            buffered_ms = bms,
            "[LuminaAudio] Audio ring buffer underrun detected"
        );
        eprintln!("[LuminaAudio] ring_buffer_underrun_count={count} (+{delta}) buffered_ms={bms}");
    }
}
