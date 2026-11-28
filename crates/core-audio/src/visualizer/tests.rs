use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

use super::ring_buffer::CacheAligned;
use super::tap::run_analysis_worker;
use super::*;
use crate::verification::WireSampleFormat;

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
    let sample_rate = Arc::new(AtomicU32::new(44_100));
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
    let sr_clone = Arc::clone(&sample_rate);
    let bands_clone = Arc::clone(&latest_bands);
    let stop_clone = Arc::clone(&stop_flag);

    let handle = thread::spawn(move || {
        run_analysis_worker(
            ring_clone,
            sr_clone,
            bands_clone,
            stop_clone,
            hann,
            band_edges,
        );
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
    assert!(
        bands[peak_band] > 0.4,
        "Peak band magnitude should be significant"
    );
    // Band 0 (30Hz) should be much lower than the 1000Hz peak
    assert!(bands[0] < bands[peak_band] * 0.5);
}

#[test]
fn test_spectrum_respects_dynamic_96khz_sample_rate() {
    let ring = Arc::new(VisualizerRingBuffer::new(RING_BUFFER_CAPACITY));
    let sample_rate = Arc::new(AtomicU32::new(96_000));
    let latest_bands = Arc::new(RwLock::new([0.0f32; NUM_BANDS]));
    let stop_flag = Arc::new(AtomicBool::new(false));
    let hann = generate_hann_window();
    let band_edges = generate_band_edges();

    // Generate 1000 Hz sine wave at 96 kHz
    let mut pcm = vec![0.0f32; 4096];
    for (i, sample) in pcm.iter_mut().enumerate().take(4096) {
        let t = i as f32 / 96_000.0;
        *sample = (2.0 * std::f32::consts::PI * 1000.0 * t).sin();
    }
    ring.push_slice(&pcm);

    let ring_clone = Arc::clone(&ring);
    let sr_clone = Arc::clone(&sample_rate);
    let bands_clone = Arc::clone(&latest_bands);
    let stop_clone = Arc::clone(&stop_flag);

    let handle = thread::spawn(move || {
        run_analysis_worker(
            ring_clone,
            sr_clone,
            bands_clone,
            stop_clone,
            hann,
            band_edges,
        );
    });

    thread::sleep(Duration::from_millis(50));
    stop_flag.store(true, Ordering::Relaxed);
    let _ = handle.join();

    let bands = latest_bands.read().unwrap();
    let peak_band = bands
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
        .map(|(idx, _)| idx)
        .unwrap();

    assert!(
        (32..=38).contains(&peak_band),
        "1000 Hz @ 96 kHz peak expected in bands 32-38, got band {}",
        peak_band
    );
}

#[test]
fn test_ring_buffer_cache_alignment_clear_request_and_producer_guard() {
    assert_eq!(std::mem::align_of::<CacheAligned<AtomicUsize>>(), 64);

    let ring = VisualizerRingBuffer::new(4096);
    let samples = vec![0.25f32; 2500];
    ring.push_slice(&samples);

    // Request clear from UI/other thread; tail is only updated on consumer side.
    ring.request_clear();
    let mut out = [0.0f32; FFT_SIZE];
    assert!(!ring.read_latest(&mut out));

    // Simulate contended producer: when producer_busy is already set, push_slice drops cleanly.
    ring.producer_busy.0.store(true, Ordering::Release);
    ring.push_slice(&samples);
    ring.producer_busy.0.store(false, Ordering::Release);
    assert!(!ring.read_latest(&mut out));
}
