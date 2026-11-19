use std::collections::HashMap;
use std::f64::consts::PI;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static REAL_WASAPI_GUARD: Mutex<()> = Mutex::new(());

fn read_http_request(stream: &mut TcpStream) -> String {
    let mut buf = Vec::with_capacity(2048);
    let mut tmp = [0u8; 512];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.windows(4).any(|w| w == b"\r\n\r\n") || buf.len() >= 16384 {
                    break;
                }
            }
        }
    }
    String::from_utf8_lossy(&buf).into_owned()
}

use core_audio::{
    infer_extension_from_magic, parse_m3u_entries, parse_pls_entries, rank_sample_format,
    select_best_config_index, AudioDecoder, AudioPlayer, BackendError, CoreAudioError, DecoderError,
    PlaybackLifecycleState, StreamSource, SymphoniaDecoder, SynthAudioDecoder,
};
use core_types::{OutputBackendKind, SignalQuality};
use cpal::SampleFormat;

fn temp_file(name: &str, ext: &str) -> PathBuf {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lumina_r5_{name}_{ts}.{ext}"))
}

fn build_wav_bytes(sample_rate: u32, channels: u16, num_frames: u32) -> Vec<u8> {
    let mut buf = Vec::new();
    let block_align = channels * 2;
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
        let sample = ((2.0 * PI * 440.0 * t).sin() * 20000.0) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample.to_le_bytes());
        }
    }
    buf
}

fn ogg_crc32(data: &[u8]) -> u32 {
    let mut crc: u32 = 0;
    for &b in data {
        crc ^= (b as u32) << 24;
        for _ in 0..8 {
            if (crc & 0x8000_0000) != 0 {
                crc = (crc << 1) ^ 0x04c1_1db7;
            } else {
                crc <<= 1;
            }
        }
    }
    crc
}

fn build_ogg_page(
    header_type: u8,
    granule_pos: u64,
    serial: u32,
    seq: u32,
    payload: &[u8],
) -> Vec<u8> {
    assert!(payload.len() < 255);
    let mut page = Vec::new();
    page.extend_from_slice(b"OggS");
    page.push(0); // version
    page.push(header_type);
    page.extend_from_slice(&granule_pos.to_le_bytes());
    page.extend_from_slice(&serial.to_le_bytes());
    page.extend_from_slice(&seq.to_le_bytes());
    page.extend_from_slice(&0u32.to_le_bytes()); // crc placeholder
    page.push(1); // 1 segment
    page.push(payload.len() as u8);
    page.extend_from_slice(payload);

    let crc = ogg_crc32(&page);
    page[22..26].copy_from_slice(&crc.to_le_bytes());
    page
}

fn build_minimal_ogg_opus_bytes() -> Vec<u8> {
    let mut opus_head = Vec::new();
    opus_head.extend_from_slice(b"OpusHead");
    opus_head.push(1); // version
    opus_head.push(2); // channels
    opus_head.extend_from_slice(&312u16.to_le_bytes()); // pre-skip
    opus_head.extend_from_slice(&48_000u32.to_le_bytes()); // input sample rate
    opus_head.extend_from_slice(&0i16.to_le_bytes()); // output gain
    opus_head.push(0); // channel mapping family

    let mut opus_tags = Vec::new();
    opus_tags.extend_from_slice(b"OpusTags");
    opus_tags.extend_from_slice(&6u32.to_le_bytes());
    opus_tags.extend_from_slice(b"Lumina");
    opus_tags.extend_from_slice(&0u32.to_le_bytes()); // 0 user comments

    let mut out = Vec::new();
    out.extend_from_slice(&build_ogg_page(0x02, 0, 1, 0, &opus_head));
    out.extend_from_slice(&build_ogg_page(0x00, 0, 1, 1, &opus_tags));
    out.extend_from_slice(&build_ogg_page(0x04, 960, 1, 2, &[0xF8, 0xFF, 0xFE]));
    out
}

#[test]
fn test_select_best_config_index_avoids_u8_trap_and_ranks_formats() {
    // WASAPI lists U8 first, then I16, I24, I32, F32, F64
    let wasapi_order = vec![
        (2, 44_100, 192_000, SampleFormat::U8),
        (2, 44_100, 192_000, SampleFormat::I16),
        (2, 44_100, 192_000, SampleFormat::I24),
        (2, 44_100, 192_000, SampleFormat::I32),
        (2, 44_100, 192_000, SampleFormat::F32),
        (2, 44_100, 192_000, SampleFormat::F64),
    ];
    assert_eq!(
        select_best_config_index(&wasapi_order, 48_000, 2),
        Some(4),
        "Should pick F32 instead of locking onto U8 at index 0"
    );

    // Without F32/F64/I32, should prefer I24 over U8 and I16
    let int_only = vec![
        (2, 48_000, 48_000, SampleFormat::U8),
        (2, 48_000, 48_000, SampleFormat::I16),
        (2, 48_000, 48_000, SampleFormat::I24),
    ];
    assert_eq!(select_best_config_index(&int_only, 48_000, 2), Some(2));

    // U8-only device is still supported as last resort
    let u8_only = vec![(2, 48_000, 48_000, SampleFormat::U8)];
    assert_eq!(select_best_config_index(&u8_only, 48_000, 2), Some(0));

    // All 7 ranked formats are accepted
    for fmt in [
        SampleFormat::F32,
        SampleFormat::F64,
        SampleFormat::I32,
        SampleFormat::I24,
        SampleFormat::I16,
        SampleFormat::U16,
        SampleFormat::U8,
    ] {
        assert!(rank_sample_format(fmt).is_some());
    }
}

#[test]
fn test_synth_decoder_and_headless_pipeline_produces_nonzero_output() {
    let mut decoder = SynthAudioDecoder::new("trk-001", "Time", 5_000, 48_000, 2);
    assert_eq!(decoder.duration(), Some(Duration::from_millis(5_000)));
    let chunk = decoder.next_chunk().unwrap().expect("synth chunk");
    let f64s = chunk.to_f64_interleaved();
    assert!(!f64s.is_empty());
    let rms = (f64s.iter().map(|s| s * s).sum::<f64>() / f64s.len() as f64).sqrt();
    assert!(rms > 0.01, "Expected audible synth RMS, got {rms}");
    assert!(f64s.iter().all(|s| s.abs() < 1.0));

    decoder.seek(Duration::from_millis(2_500)).unwrap();
    let chunk2 = decoder.next_chunk().unwrap().expect("post-seek synth chunk");
    assert!(!chunk2.is_empty());

    let player = AudioPlayer::new_headless();
    player
        .play_stream(StreamSource::synth("trk-001", "Time", 5_000), "Qobuz Hi-Res")
        .expect("play synth stream");
    assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);
    assert_eq!(player.duration_ms(), 5_000);

    thread::sleep(Duration::from_millis(120));
    assert!(player.position_ms() > 0);
    assert!(
        player.nonzero_output_frames() > 0,
        "Expected non-zero output frames in headless synth pipeline"
    );

    player.seek_ms(2_000);
    assert!(player.position_ms() >= 2_000);

    assert_eq!(player.current_signal_path().overall, SignalQuality::Enhanced);
    player.toggle_dsp_bypass();
    assert_eq!(player.current_signal_path().overall, SignalQuality::Lossless);

    player.pause();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Paused as i32);
    player.resume();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);

    player.stop();
    player.shutdown();
}

#[test]
fn test_non_headless_wasapi_playback_not_virtual_and_nonzero() {
    let _guard = REAL_WASAPI_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let player = AudioPlayer::new();
    let devices = player.list_output_devices();
    let real_devices: Vec<_> = devices
        .iter()
        .filter(|d| d.id != "virtual-exclusive-dac")
        .collect();

    if real_devices.is_empty() {
        player.shutdown();
        return;
    }

    // Selecting virtual-exclusive-dac when real devices exist must fail cleanly
    let virt_err = player
        .select_output_device(
            Some("virtual-exclusive-dac"),
            Some(OutputBackendKind::WindowsWasapiExclusive),
        )
        .unwrap_err();
    assert!(matches!(
        virt_err,
        CoreAudioError::Backend(BackendError::DeviceNotFound(_))
    ));

    // Selecting missing device must fail
    let missing_err = player
        .select_output_device(Some("definitely-nonexistent-dac"), None)
        .unwrap_err();
    assert!(matches!(
        missing_err,
        CoreAudioError::Backend(BackendError::DeviceNotFound(_))
    ));

    // 1. Play synthesized demo track on real Windows WASAPI device
    player
        .play_stream(StreamSource::synth("trk-001", "Time", 5_000), "Lumina Demo Synth")
        .expect("non-headless synth playback should succeed on WASAPI");

    for _ in 0..40 {
        if player.position_ms() > 0 && player.nonzero_output_frames() > 0 {
            break;
        }
        thread::sleep(Duration::from_millis(25));
    }
    let meta = player.active_meta().expect("active_meta");
    assert_ne!(
        meta.device_name, "Virtual Exclusive DAC",
        "Non-headless playback must NOT fall back to Virtual Exclusive DAC"
    );
    assert!(player.position_ms() > 0, "Expected position_ms > 0");
    assert!(
        player.nonzero_output_frames() > 0,
        "Expected non-zero PCM frames delivered to cpal callback"
    );

    // 2. Play a real 48 kHz WAV file on real Windows WASAPI device
    let wav_path = temp_file("wasapi_wav", "wav");
    fs::write(&wav_path, build_wav_bytes(48_000, 2, 96_000)).unwrap();
    player
        .play_file(&wav_path, Some("Local Library".to_string()))
        .expect("non-headless WAV playback should succeed");
    for _ in 0..40 {
        if player.position_ms() > 0 && player.nonzero_output_frames() > 0 {
            break;
        }
        thread::sleep(Duration::from_millis(25));
    }

    let wav_meta = player.active_meta().expect("wav active_meta");
    assert_ne!(wav_meta.device_name, "Virtual Exclusive DAC");
    assert!(player.position_ms() > 0);
    assert!(player.nonzero_output_frames() > 0);

    player.stop();
    player.shutdown();
    let _ = fs::remove_file(wav_path);
}

#[test]
fn test_live_select_output_device_reroute_preserves_state_and_position() {
    let _guard = REAL_WASAPI_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let player = AudioPlayer::new();
    let real_devices: Vec<_> = player
        .list_output_devices()
        .into_iter()
        .filter(|d| d.id != "virtual-exclusive-dac")
        .collect();

    if real_devices.len() >= 2 {
        player
            .select_output_device(Some(&real_devices[0].id), Some(real_devices[0].backend))
            .unwrap();
        player
            .play_stream(StreamSource::synth("trk-001", "Time", 10_000), "Reroute Test")
            .unwrap();
        thread::sleep(Duration::from_millis(120));
        let pos_before = player.position_ms();
        assert!(pos_before > 0);

        player
            .select_output_device(Some(&real_devices[1].id), Some(real_devices[1].backend))
            .expect("live reroute while playing should succeed");
        assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);
        let meta = player.active_meta().unwrap();
        assert_eq!(meta.device_name, real_devices[1].name);
        assert!(player.position_ms() >= pos_before);

        player.pause();
        assert_eq!(player.state_code(), PlaybackLifecycleState::Paused as i32);
        player
            .select_output_device(Some(&real_devices[0].id), Some(real_devices[0].backend))
            .expect("live reroute while paused should succeed");
        assert_eq!(player.state_code(), PlaybackLifecycleState::Paused as i32);
        assert_eq!(player.active_meta().unwrap().device_name, real_devices[0].name);

        player.stop();
    } else {
        // Fallback headless reroute verification on single/zero-device machines
        let hplayer = AudioPlayer::new_headless();
        hplayer
            .play_stream(StreamSource::synth("trk-001", "Time", 10_000), "Reroute Headless")
            .unwrap();
        thread::sleep(Duration::from_millis(80));
        let pos_before = hplayer.position_ms();
        hplayer
            .select_output_device(
                Some("virtual-exclusive-dac"),
                Some(OutputBackendKind::WindowsWasapiExclusive),
            )
            .unwrap();
        assert_eq!(hplayer.state_code(), PlaybackLifecycleState::Playing as i32);
        assert!(hplayer.position_ms() >= pos_before);
        hplayer.stop();
        hplayer.shutdown();
    }

    player.shutdown();
}

#[test]
fn test_decode_error_sets_error_state_and_last_error() {
    // Serve a valid WAV header + partial audio with a larger Content-Length, then drop the socket
    // only AFTER play_stream() succeeds so decode_loop encounters the mid-stream truncation error.
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    let wav = build_wav_bytes(48_000, 2, 48_000);
    let initial_slice = wav[..44 + 16_384].to_vec();
    let declared_len = wav.len();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let drop_gate = Arc::new(AtomicBool::new(false));
    let drop_gate_srv = Arc::clone(&drop_gate);

    let server_handle = thread::spawn(move || {
        for _ in 0..4 {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let req_str = read_http_request(&mut stream);
            let method = req_str.split_whitespace().next().unwrap_or("GET");
            if method == "HEAD" {
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {declared_len}\r\nConnection: close\r\n\r\n"
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.flush();
            } else {
                let hdr = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {declared_len}\r\nConnection: close\r\n\r\n"
                );
                let _ = stream.write_all(hdr.as_bytes());
                let _ = stream.write_all(&initial_slice);
                let _ = stream.flush();
                while !drop_gate_srv.load(Ordering::Acquire) {
                    thread::sleep(Duration::from_millis(5));
                }
                let _ = stream.shutdown(std::net::Shutdown::Both);
                break;
            }
        }
    });

    let player = AudioPlayer::new_headless();
    let url = format!("http://{addr}/midfail.wav");
    player
        .play_stream(
            StreamSource::http(url, HashMap::new(), Some("wav".to_string())),
            "Midstream Fail",
        )
        .expect("header probe succeeds before mid-stream truncation");
    drop_gate.store(true, Ordering::Release);

    let mut reached_error = false;
    for _ in 0..60 {
        if player.state_code() == PlaybackLifecycleState::Error as i32 {
            reached_error = true;
            break;
        }
        thread::sleep(Duration::from_millis(25));
    }
    assert!(
        reached_error,
        "Expected state_code == Error (4) on decode error, got state_code={}, last_error={:?}",
        player.state_code(),
        player.last_error()
    );
    assert!(
        player.last_error().is_some(),
        "Expected last_error to be populated on decode error"
    );

    player.shutdown();
    let _ = server_handle.join();
}

#[test]
fn test_infer_extension_from_magic_adts_aac_vs_mp3() {
    // ADTS AAC frames (layer bits == 00)
    assert_eq!(infer_extension_from_magic(&[0xFF, 0xF1, 0x50, 0x80]), Some("aac"));
    assert_eq!(infer_extension_from_magic(&[0xFF, 0xF9, 0x50, 0x80]), Some("aac"));

    // MPEG Audio Layer III frames (layer bits != 00) and ID3v2 tags
    assert_eq!(infer_extension_from_magic(&[0xFF, 0xFB, 0x90, 0x00]), Some("mp3"));
    assert_eq!(infer_extension_from_magic(b"ID3\x04\x00\x00"), Some("mp3"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_playlist_parsing_and_http_resolution_plays_audio() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    let m3u_entries = parse_m3u_entries("#EXTM3U\n#EXTINF:-1,Radio\nhttp://example.com/live.aac\n");
    assert_eq!(m3u_entries, vec!["http://example.com/live.aac"]);

    let pls_entries = parse_pls_entries("[playlist]\nNumberOfEntries=1\nFile1=http://example.com/live.mp3\nTitle1=Live\n");
    assert_eq!(pls_entries, vec!["http://example.com/live.mp3"]);

    let wav_bytes = std::sync::Arc::new(build_wav_bytes(48_000, 2, 48_000));
    let listener = TokioTcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let wav_bytes = std::sync::Arc::clone(&wav_bytes);
            tokio::spawn(async move {
                let mut buf = vec![0u8; 16384];
                loop {
                    let mut total_read = 0;
                    loop {
                        let Ok(n) = stream.read(&mut buf[total_read..]).await else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        total_read += n;
                        if let Some(end_pos) = buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n") {
                            total_read = end_pos + 4;
                            break;
                        }
                        if total_read == buf.len() {
                            break;
                        }
                    }
                    let req_str = String::from_utf8_lossy(&buf[..total_read]);
                    let first_line = req_str.lines().next().unwrap_or("");
                    let parts: Vec<&str> = first_line.split_whitespace().collect();
                    let method = parts.first().copied().unwrap_or("GET");
                    let path = parts.get(1).copied().unwrap_or("/");

                    if path == "/radio.pls" {
                        let body = format!("[playlist]\nFile1=http://{addr}/sub.m3u\nNumberOfEntries=1\n");
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: audio/x-scpls\r\nContent-Length: {}\r\n\r\n{}",
                            body.len(),
                            body
                        );
                        if stream.write_all(resp.as_bytes()).await.is_err() {
                            return;
                        }
                    } else if path == "/sub.m3u" {
                        let body = "#EXTM3U\n/stream.wav\n";
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\nContent-Length: {}\r\n\r\n{}",
                            body.len(),
                            body
                        );
                        if stream.write_all(resp.as_bytes()).await.is_err() {
                            return;
                        }
                    } else if path == "/stream.wav" {
                        if method == "HEAD" {
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {}\r\n\r\n",
                                wav_bytes.len()
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        } else {
                            let hdr = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {}\r\n\r\n",
                                wav_bytes.len()
                            );
                            if stream.write_all(hdr.as_bytes()).await.is_err()
                                || stream.write_all(&wav_bytes).await.is_err()
                            {
                                return;
                            }
                        }
                    }
                    let _ = stream.flush().await;
                }
            });
        }
    });

    let player = AudioPlayer::new_headless();
    let pls_url = format!("http://{addr}/radio.pls");
    player
        .play_stream(
            StreamSource::http(pls_url, HashMap::new(), Some("pls".to_string())),
            "Internet Radio",
        )
        .expect("nested .pls -> .m3u -> relative .wav should resolve and play");

    tokio::time::sleep(Duration::from_millis(120)).await;
    assert!(player.position_ms() > 0);
    assert!(player.nonzero_output_frames() > 0);

    player.stop();
    player.shutdown();
    server_handle.abort();
}

#[test]
fn test_opus_returns_explicit_unsupported_format() {
    let opus_ogg = build_minimal_ogg_opus_bytes();
    let err = match SymphoniaDecoder::from_bytes(opus_ogg, Some("ogg")) {
        Ok(_) => panic!("Expected Opus to return UnsupportedFormat error"),
        Err(e) => e,
    };
    match err {
        DecoderError::UnsupportedFormat(msg) => {
            assert!(
                msg.contains("Opus"),
                "Expected Opus unsupported message, got: {msg}"
            );
        }
        other => panic!("Expected DecoderError::UnsupportedFormat, got {other:?}"),
    }
}
