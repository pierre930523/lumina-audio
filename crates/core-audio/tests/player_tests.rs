use std::f64::consts::PI;
use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use core_audio::{AudioPlayer, PlaybackLifecycleState};
use core_types::SignalQuality;

fn temp_wav_path(name: &str) -> PathBuf {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lumina_{name}_{ts}.wav"))
}

fn write_synthetic_wav_file(
    path: &std::path::Path,
    sample_rate: u32,
    channels: u16,
    num_frames: u32,
) {
    let mut buf = Vec::new();
    let bytes_per_sample = 2u16;
    let block_align = channels * bytes_per_sample;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = num_frames * (block_align as u32);

    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    for n in 0..num_frames {
        let t = n as f64 / sample_rate as f64;
        let s = (2.0 * PI * 440.0 * t).sin();
        let sample_i16 = (s * 24000.0) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample_i16.to_le_bytes());
        }
    }

    fs::write(path, buf).expect("write synthetic wav file");
}

#[test]
fn test_headless_player_streams_wav_and_switches_signal_path() {
    let wav_path = temp_wav_path("player_test");
    write_synthetic_wav_file(&wav_path, 48_000, 2, 96_000); // 2 seconds stereo 48kHz

    let player = AudioPlayer::new_headless();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Stopped as i32);

    // Non-existent path must return an error immediately
    let missing = wav_path.with_file_name("definitely_missing.wav");
    assert!(player.play_file(&missing, None).is_err());

    player
        .play_file(&wav_path, Some("Local WAV Test".to_string()))
        .expect("play_file should open synthetic WAV cleanly");
    assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);

    thread::sleep(Duration::from_millis(120));
    assert!(
        player.position_ms() > 0,
        "Expected position_ms > 0 after streaming, got {}",
        player.position_ms()
    );
    assert!(player.duration_ms() >= 1900, "Expected ~2000ms duration");

    // Default DSP active -> Enhanced signal path
    let sp_enhanced = player.current_signal_path();
    assert_eq!(sp_enhanced.overall, SignalQuality::Enhanced);

    // One-click DSP bypass -> Bit-perfect Lossless signal path
    assert!(player.toggle_dsp_bypass());
    let sp_lossless = player.current_signal_path();
    assert_eq!(sp_lossless.overall, SignalQuality::Lossless);

    // Pause, verify state and volume controls
    player.pause();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Paused as i32);
    player.set_volume(0.42);
    assert!((player.volume() - 0.42).abs() < 1e-4);

    // Seek updates position accurately
    player.seek_ms(500);
    assert_eq!(player.position_ms(), 500);

    player.resume();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);
    thread::sleep(Duration::from_millis(40));

    player.stop();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Stopped as i32);
    assert_eq!(player.position_ms(), 0);

    player.shutdown();
    let _ = fs::remove_file(wav_path);
}
