use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::thread;
use std::time::Duration;

use rustfft::FftPlanner;
use rustfft::num_complex::Complex;

use crate::verification::WireSampleFormat;

use super::ring_buffer::{VisualizerRingBuffer, generate_band_edges, generate_hann_window};
use super::{ATTACK_COEFF, FFT_SIZE, NUM_BANDS, RELEASE_COEFF, RING_BUFFER_CAPACITY};

/// Non-blocking read-only sidechain tap for real-time visualizer spectrum analysis.
pub struct VisualizerTap {
    enabled: AtomicBool,
    pub(super) ring: Arc<VisualizerRingBuffer>,
    sample_rate: Arc<AtomicU32>,
    latest_bands: Arc<RwLock<[f32; NUM_BANDS]>>,
    worker_started: AtomicBool,
    worker_spawn_lock: Mutex<()>,
    worker_stop: Arc<AtomicBool>,
}

impl Default for VisualizerTap {
    fn default() -> Self {
        Self::new()
    }
}

impl VisualizerTap {
    pub fn new() -> Self {
        Self {
            enabled: AtomicBool::new(true),
            ring: Arc::new(VisualizerRingBuffer::new(RING_BUFFER_CAPACITY)),
            sample_rate: Arc::new(AtomicU32::new(44_100)),
            latest_bands: Arc::new(RwLock::new([0.0f32; NUM_BANDS])),
            worker_started: AtomicBool::new(false),
            worker_spawn_lock: Mutex::new(()),
            worker_stop: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Sets the visualizer tap enabled state.
    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
        if enabled {
            self.ensure_worker_started();
        } else {
            // Never mutate consumer-owned `tail` directly from the UI thread;
            // signal the consumer worker to clear safely on its own thread.
            self.ring.request_clear();
        }
    }

    /// Returns whether the visualizer tap is currently enabled.
    #[inline]
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    /// Retrieves a snapshot of the latest 64 smoothed frequency bands normalized to [0.0, 1.0].
    pub fn get_latest_bands(&self, out: &mut [f32; NUM_BANDS]) -> bool {
        if self.enabled.load(Ordering::Relaxed) {
            self.ensure_worker_started();
        }
        if let Ok(guard) = self.latest_bands.read() {
            out.copy_from_slice(&*guard);
            true
        } else {
            false
        }
    }

    /// Ensures the independent analysis worker thread is running.
    /// Must only be called from non-real-time control/UI threads (never inside an audio callback).
    pub(crate) fn ensure_worker_started(&self) {
        if self.worker_started.load(Ordering::Acquire) {
            return;
        }
        let _guard = self.worker_spawn_lock.lock().unwrap();
        if self.worker_started.load(Ordering::Acquire) {
            return;
        }

        let ring = Arc::clone(&self.ring);
        let sample_rate = Arc::clone(&self.sample_rate);
        let latest_bands = Arc::clone(&self.latest_bands);
        let stop_flag = Arc::clone(&self.worker_stop);

        // Precompute Hann window and logarithmic band edges
        let hann = generate_hann_window();
        let band_edges = generate_band_edges();

        let _ = thread::Builder::new()
            .name("lumina-visualizer-fft".to_string())
            .spawn(move || {
                run_analysis_worker(ring, sample_rate, latest_bands, stop_flag, hann, band_edges);
            });

        self.worker_started.store(true, Ordering::Release);
    }

    /// Pure read-only tap invoked on hardware output delivery.
    /// Strictly non-blocking, zero-allocation, lock-free, low-stack (1 KiB scratch).
    /// Safely bypasses Native DSD, DoP, or non-PCM without forced transcoding.
    #[inline]
    pub fn feed_wire(
        &self,
        wire_bytes: &[u8],
        wire: WireSampleFormat,
        channels: u16,
        sample_rate: u32,
    ) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }

        // Format tolerance: Immediately bypass Native DSD or DoP or non-PCM
        if matches!(
            wire,
            WireSampleFormat::NativeDsd { .. } | WireSampleFormat::Dop24In32MsbLe { .. }
        ) {
            return;
        }

        // Check if wire format is a recognized PCM format
        let bytes_per_sample = wire.bytes_per_sample();
        let ch = (channels as usize).max(1);
        let bytes_per_frame = bytes_per_sample * ch;
        if bytes_per_frame == 0 || wire_bytes.len() < bytes_per_frame {
            return;
        }

        self.sample_rate
            .store(sample_rate.max(8000), Ordering::Relaxed);

        let total_frames = wire_bytes.len() / bytes_per_frame;
        const SCRATCH_FRAMES: usize = 256;
        let mut mono_scratch = [0.0f32; SCRATCH_FRAMES];

        let mut offset = 0;
        while offset < total_frames {
            let batch = (total_frames - offset).min(SCRATCH_FRAMES);
            for (i, slot) in mono_scratch.iter_mut().enumerate().take(batch) {
                let frame_idx = offset + i;
                let byte_pos = frame_idx * bytes_per_frame;
                let frame_slice = &wire_bytes[byte_pos..byte_pos + bytes_per_frame];

                let s0 = extract_channel_f32(frame_slice, wire, 0);
                let s1 = if ch > 1 {
                    extract_channel_f32(frame_slice, wire, 1)
                } else {
                    s0
                };
                *slot = (s0 + s1) * 0.5;
            }
            self.ring.push_slice(&mono_scratch[..batch]);
            offset += batch;
        }
    }
}

impl Drop for VisualizerTap {
    fn drop(&mut self) {
        self.worker_stop.store(true, Ordering::Relaxed);
    }
}

/// Global singleton accessor for the visualizer sidechain tap.
static GLOBAL_TAP: OnceLock<VisualizerTap> = OnceLock::new();

/// Initializes the global visualizer tap and starts its background FFT analysis worker.
/// Must be called from non-real-time control/setup threads before entering RT audio callbacks.
pub fn init_global_tap() -> &'static VisualizerTap {
    let tap = GLOBAL_TAP.get_or_init(VisualizerTap::new);
    tap.ensure_worker_started();
    tap
}

/// Strictly real-time-safe accessor for the global visualizer tap.
/// Returns `None` if [`init_global_tap`] has not yet been called; never allocates, locks, or spawns.
#[inline]
pub fn try_global_tap() -> Option<&'static VisualizerTap> {
    GLOBAL_TAP.get()
}

/// Non-RT global singleton accessor for the visualizer sidechain tap.
pub fn global_tap() -> &'static VisualizerTap {
    GLOBAL_TAP.get_or_init(VisualizerTap::new)
}

/// Extracts a single normalized f32 sample from raw wire frame bytes for channel `ch_idx`.
#[inline(always)]
fn extract_channel_f32(frame_slice: &[u8], wire: WireSampleFormat, ch_idx: usize) -> f32 {
    let bps = wire.bytes_per_sample();
    let pos = ch_idx * bps;
    if pos + bps > frame_slice.len() {
        return 0.0;
    }
    let bytes = &frame_slice[pos..pos + bps];

    match wire {
        WireSampleFormat::Int16Le => i16::from_le_bytes([bytes[0], bytes[1]]) as f32 / 32768.0,
        WireSampleFormat::Int24PackedLe => {
            let raw =
                (bytes[0] as i32) | ((bytes[1] as i32) << 8) | ((bytes[2] as i8 as i32) << 16);
            raw as f32 / 8388608.0
        }
        WireSampleFormat::Int24In32MsbLe | WireSampleFormat::Int32Le => {
            let raw = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            raw as f32 / 2147483648.0
        }
        WireSampleFormat::Float32Le => f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
        WireSampleFormat::Float64Le => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]) as f32,
        _ => 0.0,
    }
}

/// Background worker thread loop: calculates FFT and 64 logarithmic bands.
/// Automatically enters low-power sleep when silent or disabled to ensure zero extra CPU overhead.
pub(super) fn run_analysis_worker(
    ring: Arc<VisualizerRingBuffer>,
    sample_rate: Arc<AtomicU32>,
    latest_bands: Arc<RwLock<[f32; NUM_BANDS]>>,
    stop_flag: Arc<AtomicBool>,
    hann: [f32; FFT_SIZE],
    band_edges: [f32; NUM_BANDS + 1],
) {
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FFT_SIZE);

    let mut pcm_in = [0.0f32; FFT_SIZE];
    let mut complex_buf = vec![Complex::new(0.0f32, 0.0f32); FFT_SIZE];
    let mut smoothed = [0.0f32; NUM_BANDS];
    let mut raw_bands = [0.0f32; NUM_BANDS];
    let mut silence_count: u32 = 0;

    while !stop_flag.load(Ordering::Relaxed) {
        if ring.service_clear_request() {
            smoothed.fill(0.0);
            if let Ok(mut guard) = latest_bands.write() {
                guard.copy_from_slice(&smoothed);
            }
        }

        if ring.read_latest(&mut pcm_in) {
            silence_count = 0;

            // 1. Apply Hann window to input PCM
            for n in 0..FFT_SIZE {
                complex_buf[n] = Complex::new(pcm_in[n] * hann[n], 0.0);
            }

            // 2. Perform 2048-point forward FFT
            fft.process(&mut complex_buf);

            // 3. Map complex magnitudes into 64 logarithmic frequency bands using live sample rate
            // Nyquist index is FFT_SIZE / 2 = 1024
            let sr = sample_rate.load(Ordering::Relaxed).max(8_000) as f32;
            let delta_f = sr / (FFT_SIZE as f32);

            for m in 0..NUM_BANDS {
                let f_low = band_edges[m];
                let f_high = band_edges[m + 1];

                let k_start = ((f_low / delta_f).floor() as usize).clamp(1, 1023);
                let k_end = ((f_high / delta_f).ceil() as usize).clamp(k_start + 1, 1024);

                let mut sum = 0.0f32;
                let mut peak = 0.0f32;
                for c in complex_buf.iter().take(k_end).skip(k_start) {
                    let mag = (c.re * c.re + c.im * c.im).sqrt();
                    sum += mag;
                    if mag > peak {
                        peak = mag;
                    }
                }
                let count = (k_end - k_start) as f32;
                let avg = sum / count;

                // Blend peak and average for responsive visuals across the spectrum
                let amp = (0.7 * peak + 0.3 * avg) / 512.0;

                // 4. Decibel log conversion and dynamic normalization to [0.0, 1.0]
                // Dynamic range: -60 dB to 0 dB
                let db = 20.0 * (amp + 1e-6).log10();
                let norm = ((db - (-60.0)) / 60.0).clamp(0.0, 1.0);
                raw_bands[m] = norm;
            }

            // 5. Ballistics dampening: attack 0.70, release 0.88
            for m in 0..NUM_BANDS {
                let target = raw_bands[m];
                if target > smoothed[m] {
                    smoothed[m] += (target - smoothed[m]) * ATTACK_COEFF;
                } else {
                    smoothed[m] *= RELEASE_COEFF;
                }
                if smoothed[m] < 1e-4 {
                    smoothed[m] = 0.0;
                }
            }

            // Publish latest smoothed bands
            if let Ok(mut guard) = latest_bands.write() {
                guard.copy_from_slice(&smoothed);
            }

            thread::sleep(Duration::from_millis(15));
        } else {
            // No new audio frames available (silence, pause, or visualizer inactive)
            silence_count = silence_count.saturating_add(1);

            // Ballistics decay during silence
            let mut any_nonzero = false;
            for s in smoothed.iter_mut() {
                *s *= RELEASE_COEFF;
                if *s < 1e-4 {
                    *s = 0.0;
                } else {
                    any_nonzero = true;
                }
            }

            if let Ok(mut guard) = latest_bands.write() {
                guard.copy_from_slice(&smoothed);
            }

            if !any_nonzero && silence_count > 30 {
                // True zero extra CPU overhead: sleep longer when completely silent
                thread::sleep(Duration::from_millis(60));
            } else {
                thread::sleep(Duration::from_millis(16));
            }
        }
    }
}
