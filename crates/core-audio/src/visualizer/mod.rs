use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::thread;
use std::time::Duration;

use rustfft::num_complex::Complex;
use rustfft::FftPlanner;

use crate::verification::WireSampleFormat;

pub const FFT_SIZE: usize = 2048;
pub const NUM_BANDS: usize = 64;
pub const RING_BUFFER_CAPACITY: usize = 16384;
pub const MIN_FREQ: f32 = 30.0;
pub const MAX_FREQ: f32 = 18000.0;
pub const ATTACK_COEFF: f32 = 0.70;
pub const RELEASE_COEFF: f32 = 0.88;

/// Lock-free single-producer single-consumer circular buffer for mono f32 PCM samples.
/// Designed for real-time audio thread: pushing is strictly non-blocking, lock-free, zero-alloc.
pub struct VisualizerRingBuffer {
    buffer: Box<[UnsafeCell<f32>]>,
    capacity: usize,
    mask: usize,
    head: AtomicUsize,
    tail: AtomicUsize,
}

unsafe impl Send for VisualizerRingBuffer {}
unsafe impl Sync for VisualizerRingBuffer {}

impl VisualizerRingBuffer {
    pub fn new(capacity: usize) -> Self {
        let cap = capacity.max(FFT_SIZE * 2).next_power_of_two();
        let mut v = Vec::with_capacity(cap);
        for _ in 0..cap {
            v.push(UnsafeCell::new(0.0f32));
        }
        Self {
            buffer: v.into_boxed_slice(),
            capacity: cap,
            mask: cap - 1,
            head: AtomicUsize::new(0),
            tail: AtomicUsize::new(0),
        }
    }

    /// Audio thread: non-blocking push. Never blocks or allocates.
    /// If capacity is exceeded, only writes what fits and returns immediately.
    pub fn push_slice(&self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);
        let used = head.wrapping_sub(tail);
        let free = self.capacity.saturating_sub(used);
        let count = samples.len().min(free);
        if count == 0 {
            return;
        }

        for (i, &s) in samples[..count].iter().enumerate() {
            let idx = (head.wrapping_add(i)) & self.mask;
            unsafe {
                *self.buffer[idx].get() = s;
            }
        }
        self.head.store(head.wrapping_add(count), Ordering::Release);
    }

    /// Analysis worker thread: reads latest 2048 samples up to current head.
    /// Returns true if at least FFT_SIZE samples are available.
    /// Advances tail with 50% overlap hop to maintain strict lip-sync without drift.
    pub fn read_latest(&self, out: &mut [f32; FFT_SIZE]) -> bool {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Relaxed);
        let available = head.wrapping_sub(tail);
        if available < FFT_SIZE {
            return false;
        }

        // Read the most recent FFT_SIZE samples up to head
        let start = head.wrapping_sub(FFT_SIZE);
        for (i, dst) in out.iter_mut().enumerate() {
            let idx = (start.wrapping_add(i)) & self.mask;
            unsafe {
                *dst = *self.buffer[idx].get();
            }
        }

        // Retain 50% overlap (1024 samples) for next frame, preventing lag accumulation
        let new_tail = head.wrapping_sub(FFT_SIZE / 2);
        self.tail.store(new_tail, Ordering::Release);
        true
    }

    /// Clears the ring buffer.
    pub fn clear(&self) {
        let head = self.head.load(Ordering::Relaxed);
        self.tail.store(head, Ordering::Release);
    }
}

/// Generates a precomputed 2048-point Hann window.
pub fn generate_hann_window() -> [f32; FFT_SIZE] {
    let mut w = [0.0f32; FFT_SIZE];
    let n_minus_1 = (FFT_SIZE - 1) as f32;
    for (n, slot) in w.iter_mut().enumerate() {
        *slot = 0.5 * (1.0 - (2.0 * std::f32::consts::PI * (n as f32) / n_minus_1).cos());
    }
    w
}

/// Generates 65 logarithmic frequency band edges (~30 Hz to 18 kHz) using formula:
/// f_edge[m] = 30.0 * (18000.0 / 30.0)^(m / 64)
pub fn generate_band_edges() -> [f32; NUM_BANDS + 1] {
    let mut edges = [0.0f32; NUM_BANDS + 1];
    let ratio = MAX_FREQ / MIN_FREQ;
    for (m, slot) in edges.iter_mut().enumerate() {
        *slot = MIN_FREQ * ratio.powf(m as f32 / NUM_BANDS as f32);
    }
    edges
}

/// Non-blocking read-only sidechain tap for real-time visualizer spectrum analysis.
pub struct VisualizerTap {
    enabled: AtomicBool,
    ring: Arc<VisualizerRingBuffer>,
    sample_rate: AtomicU32,
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
            sample_rate: AtomicU32::new(44_100),
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
            self.ring.clear();
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
        let latest_bands = Arc::clone(&self.latest_bands);
        let stop_flag = Arc::clone(&self.worker_stop);

        // Precompute Hann window and logarithmic band edges
        let hann = generate_hann_window();
        let band_edges = generate_band_edges();

        let _ = thread::Builder::new()
            .name("lumina-visualizer-fft".to_string())
            .spawn(move || {
                run_analysis_worker(ring, latest_bands, stop_flag, hann, band_edges);
            });

        self.worker_started.store(true, Ordering::Release);
    }

    /// Pure read-only tap invoked on hardware output delivery.
    /// Strictly non-blocking, zero-allocation, lock-free.
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

        self.sample_rate.store(sample_rate.max(8000), Ordering::Relaxed);

        let total_frames = wire_bytes.len() / bytes_per_frame;
        const SCRATCH_FRAMES: usize = 1024;
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
        WireSampleFormat::Int16Le => {
            i16::from_le_bytes([bytes[0], bytes[1]]) as f32 / 32768.0
        }
        WireSampleFormat::Int24PackedLe => {
            let raw = (bytes[0] as i32) | ((bytes[1] as i32) << 8) | ((bytes[2] as i8 as i32) << 16);
            raw as f32 / 8388608.0
        }
        WireSampleFormat::Int24In32MsbLe | WireSampleFormat::Int32Le => {
            let raw = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            raw as f32 / 2147483648.0
        }
        WireSampleFormat::Float32Le => {
            f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
        }
        WireSampleFormat::Float64Le => {
            f64::from_le_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]) as f32
        }
        _ => 0.0,
    }
}

/// Background worker thread loop: calculates FFT and 64 logarithmic bands.
/// Automatically enters low-power sleep when silent or disabled to ensure zero extra CPU overhead.
fn run_analysis_worker(
    ring: Arc<VisualizerRingBuffer>,
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
        if ring.read_latest(&mut pcm_in) {
            silence_count = 0;

            // 1. Apply Hann window to input PCM
            for n in 0..FFT_SIZE {
                complex_buf[n] = Complex::new(pcm_in[n] * hann[n], 0.0);
            }

            // 2. Perform 2048-point forward FFT
            fft.process(&mut complex_buf);

            // 3. Map complex magnitudes into 64 logarithmic frequency bands
            // Assuming nominal 44.1kHz or 48kHz sampling rate for bin mapping (approx ~22Hz per bin)
            // Nyquist index is FFT_SIZE / 2 = 1024
            let delta_f = 44100.0f32 / (FFT_SIZE as f32);

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ring_buffer_push_and_read() {
        let ring = VisualizerRingBuffer::new(4096);
        let samples = vec![0.5f32; 2500];
        ring.push_slice(&samples);

        let mut out = [0.0f32; FFT_SIZE];
        let read = ring.read_latest(&mut out);
        assert!(read, "Expected to read 2048 samples");
        for &val in out.iter() {
            assert!((val - 0.5).abs() < 1e-5);
        }
    }

    #[test]
    fn test_band_edges_monotonic_and_within_range() {
        let edges = generate_band_edges();
        assert_eq!(edges.len(), 65);
        assert!((edges[0] - 30.0).abs() < 0.1);
        assert!((edges[64] - 18000.0).abs() < 1.0);

        for i in 0..64 {
            assert!(
                edges[i] < edges[i + 1],
                "Band edges must be strictly increasing: {} vs {}",
                edges[i],
                edges[i + 1]
            );
        }
    }

    #[test]
    fn test_native_dsd_and_dop_bypass() {
        let tap = VisualizerTap::new();
        tap.set_enabled(true);

        // Feed Native DSD wire bytes
        let dsd_bytes = vec![0xAAu8; 4096];
        tap.feed_wire(
            &dsd_bytes,
            WireSampleFormat::NativeDsd { channels: 2 },
            2,
            2_822_400,
        );

        // Ring buffer must receive zero samples
        let mut out = [0.0f32; FFT_SIZE];
        assert!(
            !tap.ring.read_latest(&mut out),
            "Native DSD must bypass ring buffer completely"
        );

        // Feed DoP wire bytes
        let dop_bytes = vec![0x05u8; 4096];
        tap.feed_wire(
            &dop_bytes,
            WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: false,
            },
            2,
            176_400,
        );
        assert!(
            !tap.ring.read_latest(&mut out),
            "DoP must bypass ring buffer completely"
        );
    }

    #[test]
    fn test_pcm_wire_formats_feed() {
        let tap = VisualizerTap::new();
        tap.set_enabled(true);

        // Test Int16Le: 2 channels, 1024 frames = 4096 bytes
        let mut i16_bytes = Vec::with_capacity(4096);
        for i in 0..1024 {
            let s = ((i % 100) as i16) * 100;
            i16_bytes.extend_from_slice(&s.to_le_bytes());
            i16_bytes.extend_from_slice(&s.to_le_bytes());
        }
        tap.feed_wire(&i16_bytes, WireSampleFormat::Int16Le, 2, 44_100);

        let mut out = [0.0f32; FFT_SIZE];
        // 1024 frames is less than FFT_SIZE (2048), so read_latest should be false
        assert!(!tap.ring.read_latest(&mut out));

        // Push another 1024 frames
        tap.feed_wire(&i16_bytes, WireSampleFormat::Int16Le, 2, 44_100);
        // Total 2048 frames now available
        assert!(tap.ring.read_latest(&mut out));
    }

    #[test]
    fn test_spectrum_frequency_response_1000hz() {
        let ring = Arc::new(VisualizerRingBuffer::new(RING_BUFFER_CAPACITY));
        let latest_bands = Arc::new(RwLock::new([0.0f32; NUM_BANDS]));
        let stop_flag = Arc::new(AtomicBool::new(false));
        let hann = generate_hann_window();
        let band_edges = generate_band_edges();

        // Generate 1000 Hz sine wave at 44.1 kHz
        let mut pcm = vec![0.0f32; 4096];
        for (i, sample) in pcm.iter_mut().enumerate().take(4096) {
            let t = i as f32 / 44100.0;
            *sample = (2.0 * std::f32::consts::PI * 1000.0 * t).sin();
        }
        ring.push_slice(&pcm);

        let ring_clone = Arc::clone(&ring);
        let bands_clone = Arc::clone(&latest_bands);
        let stop_clone = Arc::clone(&stop_flag);

        let handle = thread::spawn(move || {
            run_analysis_worker(ring_clone, bands_clone, stop_clone, hann, band_edges);
        });

        // Allow worker to compute FFT
        thread::sleep(Duration::from_millis(50));
        stop_flag.store(true, Ordering::Relaxed);
        let _ = handle.join();

        let bands = latest_bands.read().unwrap();
        // 1000 Hz is expected near band 34-36
        let peak_band = bands
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .map(|(idx, _)| idx)
            .unwrap();

        assert!(
            (32..=38).contains(&peak_band),
            "1000 Hz peak expected in bands 32-38, got band {}",
            peak_band
        );
        assert!(bands[peak_band] > 0.4, "Peak band magnitude should be significant");
        // Band 0 (30Hz) should be much lower than the 1000Hz peak
        assert!(bands[0] < bands[peak_band] * 0.5);
    }
}
