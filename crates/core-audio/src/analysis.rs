use std::fs::File;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use core_types::{TrackAnalysisResult, TrackCorruptionStatus};

use crate::decoder::dsd::decimation::DsdChannelDecimator;
use crate::decoder::pcm::AudioChunk;
use crate::decoder::source_opener::open_decoder_for_path;

fn format_utc_now_rfc3339() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let hh = rem / 3_600;
    let mm = (rem % 3_600) / 60;
    let ss = rem % 60;
    // Howard Hinnant's civil-from-days algorithm
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = y + if m <= 2 { 1 } else { 0 };
    format!("{year:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

const WAVEFORM_BUCKETS: usize = 64;
const COARSE_PEAK_CAP: usize = 4096;

#[derive(Clone, Copy)]
struct BiquadCoeffs {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

#[derive(Clone, Copy, Default)]
struct BiquadState {
    z1: f64,
    z2: f64,
}

impl BiquadState {
    #[inline]
    fn process(&mut self, c: &BiquadCoeffs, x: f64) -> f64 {
        let y = c.b0 * x + self.z1;
        self.z1 = c.b1 * x - c.a1 * y + self.z2;
        self.z2 = c.b2 * x - c.a2 * y;
        y
    }
}

fn bs1770_shelf_coeffs(sample_rate_hz: u32) -> BiquadCoeffs {
    let fs = (sample_rate_hz.max(8_000)) as f64;
    let db = 3.999843853973347_f64;
    let f0 = 1681.974450955533_f64.min(fs * 0.45);
    let q = 0.7071752369554196_f64;
    let k = (std::f64::consts::PI * f0 / fs).tan();
    let vh = 10.0_f64.powf(db / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    BiquadCoeffs {
        b0: (vh + vb * k / q + k * k) / a0,
        b1: 2.0 * (k * k - vh) / a0,
        b2: (vh - vb * k / q + k * k) / a0,
        a1: 2.0 * (k * k - 1.0) / a0,
        a2: (1.0 - k / q + k * k) / a0,
    }
}

fn bs1770_highpass_coeffs(sample_rate_hz: u32) -> BiquadCoeffs {
    let fs = (sample_rate_hz.max(8_000)) as f64;
    let f0 = 38.13547087602444_f64.min(fs * 0.45);
    let q = 0.5003270373238773_f64;
    let w0 = 2.0 * std::f64::consts::PI * f0 / fs;
    let cos_w0 = w0.cos();
    let alpha = w0.sin() / (2.0 * q);
    let a0 = 1.0 + alpha;
    BiquadCoeffs {
        b0: (1.0 + cos_w0) * 0.5 / a0,
        b1: -(1.0 + cos_w0) / a0,
        b2: (1.0 + cos_w0) * 0.5 / a0,
        a1: -2.0 * cos_w0 / a0,
        a2: (1.0 - alpha) / a0,
    }
}

struct KWeightMeter {
    channels: usize,
    shelf: BiquadCoeffs,
    hp: BiquadCoeffs,
    shelf_state: Vec<BiquadState>,
    hp_state: Vec<BiquadState>,
    step_frames: usize,
    step_acc: Vec<f64>,
    step_count: usize,
    ring_steps: [[f64; 4]; 8],
    ring_pos: usize,
    block_powers: Vec<f64>,
    total_energy: f64,
    total_frames: u64,
    max_abs: f64,
}

impl KWeightMeter {
    fn new(sample_rate_hz: u32, channels: u16) -> Self {
        let ch = (channels.max(1) as usize).min(8);
        let step_frames = ((sample_rate_hz.max(8_000) as f64) * 0.1).round().max(1.0) as usize;
        Self {
            channels: ch,
            shelf: bs1770_shelf_coeffs(sample_rate_hz),
            hp: bs1770_highpass_coeffs(sample_rate_hz),
            shelf_state: vec![BiquadState::default(); ch],
            hp_state: vec![BiquadState::default(); ch],
            step_frames,
            step_acc: vec![0.0; ch],
            step_count: 0,
            ring_steps: [[0.0; 4]; 8],
            ring_pos: 0,
            block_powers: Vec::new(),
            total_energy: 0.0,
            total_frames: 0,
            max_abs: 0.0,
        }
    }

    #[inline]
    fn channel_weight(ch: usize, total_ch: usize) -> f64 {
        if total_ch >= 5 && (ch == 3 || ch == 4) {
            1.41
        } else {
            1.0
        }
    }

    fn feed_interleaved_f64(&mut self, samples: &[f64], raw_channels: usize) {
        let ch_stride = raw_channels.max(1);
        for frame in samples.chunks_exact(ch_stride) {
            self.total_frames += 1;
            for (c, &s) in frame.iter().take(self.channels).enumerate() {
                let abs = s.abs();
                if abs > self.max_abs {
                    self.max_abs = abs;
                }
                let s1 = self.shelf_state[c].process(&self.shelf, s);
                let s2 = self.hp_state[c].process(&self.hp, s1);
                let sq = s2 * s2;
                self.step_acc[c] += sq;
                self.total_energy += Self::channel_weight(c, self.channels) * sq;
            }
            self.step_count += 1;
            if self.step_count >= self.step_frames {
                let slot = self.ring_pos % 4;
                for c in 0..self.channels {
                    self.ring_steps[c][slot] = self.step_acc[c] / (self.step_count as f64);
                    self.step_acc[c] = 0.0;
                }
                self.step_count = 0;
                self.ring_pos += 1;
                if self.ring_pos >= 4 {
                    let mut block_sum = 0.0;
                    for c in 0..self.channels {
                        let mean_ch = (self.ring_steps[c][0]
                            + self.ring_steps[c][1]
                            + self.ring_steps[c][2]
                            + self.ring_steps[c][3])
                            * 0.25;
                        block_sum += Self::channel_weight(c, self.channels) * mean_ch;
                    }
                    self.block_powers.push(block_sum);
                }
            }
        }
    }

    fn finalize_lufs(&self) -> Option<f64> {
        if self.total_frames == 0 {
            return None;
        }
        let abs_thresh_power = 10.0_f64.powf((-70.0 + 0.691) / 10.0);
        let gated_abs: Vec<f64> = self
            .block_powers
            .iter()
            .copied()
            .filter(|&p| p >= abs_thresh_power)
            .collect();
        if gated_abs.is_empty() {
            let mean_ungated = self.total_energy / (self.total_frames as f64);
            if mean_ungated <= 1e-12 {
                return Some(-70.0);
            }
            return Some((-0.691 + 10.0 * mean_ungated.log10()).max(-70.0));
        }

        let avg_abs = gated_abs.iter().sum::<f64>() / (gated_abs.len() as f64);
        let rel_lufs = -0.691 + 10.0 * avg_abs.log10() - 10.0;
        let rel_thresh_power = 10.0_f64.powf((rel_lufs + 0.691) / 10.0);

        let gated_rel: Vec<f64> = gated_abs
            .into_iter()
            .filter(|&p| p >= rel_thresh_power)
            .collect();
        let final_mean = if gated_rel.is_empty() {
            avg_abs
        } else {
            gated_rel.iter().sum::<f64>() / (gated_rel.len() as f64)
        };
        if final_mean <= 1e-12 {
            Some(-70.0)
        } else {
            Some((-0.691 + 10.0 * final_mean.log10()).clamp(-70.0, 6.0))
        }
    }
}

fn downsample_waveform(coarse_peaks: &[f32], buckets: usize) -> Vec<f32> {
    if coarse_peaks.is_empty() || buckets == 0 {
        return Vec::new();
    }
    let max_val = coarse_peaks.iter().copied().fold(0.0_f32, f32::max);
    let scale = if max_val > 1e-6 { 1.0 / max_val } else { 1.0 };

    let mut out = Vec::with_capacity(buckets);
    let len = coarse_peaks.len();
    for b in 0..buckets {
        let start = (b * len) / buckets;
        let end = (((b + 1) * len) / buckets).max(start + 1).min(len);
        let peak = coarse_peaks[start..end]
            .iter()
            .copied()
            .fold(0.0_f32, f32::max);
        out.push((peak * scale).clamp(0.02, 1.0));
    }
    out
}

fn compact_coarse_peaks(peaks: &mut Vec<f32>) {
    if peaks.len() < COARSE_PEAK_CAP {
        return;
    }
    let mut compacted = Vec::with_capacity(peaks.len().div_ceil(2));
    for pair in peaks.chunks(2) {
        let m = pair.iter().copied().fold(0.0_f32, f32::max);
        compacted.push(m);
    }
    *peaks = compacted;
}

/// Runs a full offline integrity, EBU R128 / ITU-R BS.1770 loudness, true peak,
/// and waveform peak scan over a local audio file.
///
/// Decodes every audio frame sequentially using `core-audio`'s PCM/DSD decoders without touching
/// hardware output or modifying files on disk.
pub fn analyze_local_track(path: &Path, track_id: &str) -> TrackAnalysisResult {
    let analyzed_at = Some(format_utc_now_rfc3339());
    let file_size = match File::open(path) {
        Ok(f) => f.metadata().map(|m| m.len()).ok(),
        Err(e) => {
            return TrackAnalysisResult {
                track_id: track_id.to_string(),
                corruption_status: TrackCorruptionStatus::Unreadable,
                analysis_error: Some(format!("Cannot open audio file: {e}")),
                analyzed_at,
                ..Default::default()
            };
        }
    };

    let mut decoder = match open_decoder_for_path(path) {
        Ok(d) => d,
        Err(e) => {
            return TrackAnalysisResult {
                track_id: track_id.to_string(),
                corruption_status: TrackCorruptionStatus::Corrupt,
                analysis_error: Some(format!("Decoder failed to open container: {e}")),
                analyzed_at,
                ..Default::default()
            };
        }
    };

    let fmt = decoder.format().clone();
    let eff_rate = if fmt.is_dsd {
        (fmt.sample_rate_hz / 8).max(8_000)
    } else {
        fmt.sample_rate_hz.max(8_000)
    };
    let mut meter = KWeightMeter::new(eff_rate, u16::from(fmt.channels));
    let mut dsd_decimators: Vec<DsdChannelDecimator> = if fmt.is_dsd {
        (0..fmt.channels.max(1))
            .map(|_| DsdChannelDecimator::new())
            .collect()
    } else {
        Vec::new()
    };

    let mut coarse_peaks: Vec<f32> = Vec::with_capacity(512);
    let mut frames_decoded: u64 = 0;

    loop {
        match decoder.next_chunk() {
            Ok(Some(chunk)) => {
                if chunk.is_empty() {
                    continue;
                }
                match chunk {
                    AudioChunk::DsdBitstream {
                        bytes,
                        channels,
                        is_lsb_first,
                        ..
                    } => {
                        let ch = (channels.max(1) as usize).min(dsd_decimators.len().max(1));
                        let mut pcm_f64 = Vec::with_capacity(bytes.len());
                        for frame in bytes.chunks_exact(ch) {
                            for (c, &b) in frame.iter().enumerate() {
                                let sample = dsd_decimators[c].translate_byte(b, is_lsb_first);
                                pcm_f64.push(sample);
                            }
                        }
                        if !pcm_f64.is_empty() {
                            frames_decoded += (pcm_f64.len() / ch) as u64;
                            let chunk_peak = pcm_f64
                                .iter()
                                .fold(0.0_f32, |acc, &v| acc.max(v.abs() as f32));
                            coarse_peaks.push(chunk_peak);
                            compact_coarse_peaks(&mut coarse_peaks);
                            meter.feed_interleaved_f64(&pcm_f64, ch);
                        }
                    }
                    other => {
                        let ch = other.channels().max(1) as usize;
                        let pcm_f64 = other.to_f64_interleaved();
                        if !pcm_f64.is_empty() {
                            frames_decoded += (pcm_f64.len() / ch) as u64;
                            let chunk_peak = pcm_f64
                                .iter()
                                .fold(0.0_f32, |acc, &v| acc.max(v.abs() as f32));
                            coarse_peaks.push(chunk_peak);
                            compact_coarse_peaks(&mut coarse_peaks);
                            meter.feed_interleaved_f64(&pcm_f64, ch);
                        }
                    }
                }
            }
            Ok(None) => break,
            Err(e) => {
                return TrackAnalysisResult {
                    track_id: track_id.to_string(),
                    corruption_status: TrackCorruptionStatus::Corrupt,
                    analysis_error: Some(format!("Stream decode error: {e}")),
                    waveform_peaks: downsample_waveform(&coarse_peaks, WAVEFORM_BUCKETS),
                    analyzed_at,
                    ..Default::default()
                };
            }
        }
    }

    if frames_decoded == 0 {
        return TrackAnalysisResult {
            track_id: track_id.to_string(),
            corruption_status: TrackCorruptionStatus::Corrupt,
            analysis_error: Some("Audio stream contained 0 decodable frames".to_string()),
            analyzed_at,
            ..Default::default()
        };
    }

    let integrated_lufs = meter.finalize_lufs();
    let max_abs = meter.max_abs;
    let true_peak_db = if max_abs > 1e-12 {
        Some(20.0 * max_abs.log10())
    } else {
        Some(-120.0)
    };
    let replay_gain_track_db = integrated_lufs.map(|lufs| -18.0 - lufs);
    let replay_gain_track_peak = Some(max_abs);
    let duration_ms = ((frames_decoded as f64 / (eff_rate as f64)) * 1000.0).round() as u64;
    let bitrate_kbps = match (file_size, duration_ms) {
        (Some(sz), dur) if sz > 0 && dur > 0 => u32::try_from((sz.saturating_mul(8)) / dur)
            .ok()
            .filter(|&b| b > 0),
        _ => None,
    };

    TrackAnalysisResult {
        track_id: track_id.to_string(),
        corruption_status: TrackCorruptionStatus::Ok,
        analysis_error: None,
        integrated_lufs,
        true_peak_db,
        replay_gain_track_db,
        replay_gain_track_peak,
        waveform_peaks: downsample_waveform(&coarse_peaks, WAVEFORM_BUCKETS),
        bitrate_kbps,
        analyzed_at,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn write_test_wav(path: &Path, sample_rate: u32, seconds: f32, amp: f32) {
        let num_samples = (sample_rate as f32 * seconds) as usize;
        let data_bytes = (num_samples * 2 * 2) as u32;
        let mut f = File::create(path).unwrap();
        f.write_all(b"RIFF").unwrap();
        f.write_all(&(36 + data_bytes).to_le_bytes()).unwrap();
        f.write_all(b"WAVEfmt ").unwrap();
        f.write_all(&16u32.to_le_bytes()).unwrap();
        f.write_all(&1u16.to_le_bytes()).unwrap();
        f.write_all(&2u16.to_le_bytes()).unwrap();
        f.write_all(&sample_rate.to_le_bytes()).unwrap();
        f.write_all(&(sample_rate * 4).to_le_bytes()).unwrap();
        f.write_all(&4u16.to_le_bytes()).unwrap();
        f.write_all(&16u16.to_le_bytes()).unwrap();
        f.write_all(b"data").unwrap();
        f.write_all(&data_bytes.to_le_bytes()).unwrap();
        for i in 0..num_samples {
            let t = i as f32 / sample_rate as f32;
            let val = ((2.0 * std::f32::consts::PI * 1000.0 * t).sin() * amp * 32767.0) as i16;
            f.write_all(&val.to_le_bytes()).unwrap();
            f.write_all(&val.to_le_bytes()).unwrap();
        }
    }

    #[test]
    fn test_analyze_local_track_valid_wav_produces_lufs_and_waveform() {
        let tmp = tempfile::Builder::new().suffix(".wav").tempfile().unwrap();
        write_test_wav(tmp.path(), 44_100, 1.0, 0.5);
        let res = analyze_local_track(tmp.path(), "trk-1");
        assert_eq!(res.corruption_status, TrackCorruptionStatus::Ok);
        assert!(res.analysis_error.is_none());
        let lufs = res.integrated_lufs.expect("lufs computed");
        assert!(lufs > -20.0 && lufs < 0.0, "unexpected lufs: {lufs}");
        assert!(res.replay_gain_track_db.is_some());
        assert_eq!(res.waveform_peaks.len(), 64);
        assert!(res.waveform_peaks.iter().all(|&p| (0.0..=1.0).contains(&p)));
    }

    #[test]
    fn test_analyze_local_track_detects_corrupt_or_missing_file() {
        let missing = Path::new("definitely_does_not_exist_123456.flac");
        let res_missing = analyze_local_track(missing, "trk-m");
        assert_eq!(
            res_missing.corruption_status,
            TrackCorruptionStatus::Unreadable
        );

        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"not valid audio bytes").unwrap();
        let res_bad = analyze_local_track(tmp.path(), "trk-b");
        assert_eq!(res_bad.corruption_status, TrackCorruptionStatus::Corrupt);
    }
}
