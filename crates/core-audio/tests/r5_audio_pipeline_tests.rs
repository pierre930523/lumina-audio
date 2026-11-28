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
    AudioDecoder, AudioPlayer, BackendError, CoreAudioError, PlaybackLifecycleState, StreamSource,
    SymphoniaDecoder, SynthAudioDecoder, infer_extension_from_magic, parse_m3u_entries,
    parse_pls_entries, rank_sample_format, select_best_config_index,
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
    let chunk2 = decoder
        .next_chunk()
        .unwrap()
        .expect("post-seek synth chunk");
    assert!(!chunk2.is_empty());

    let player = AudioPlayer::new_headless();
    player
        .play_stream(
            StreamSource::synth("trk-001", "Time", 5_000),
            "Qobuz Hi-Res",
        )
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

    assert_eq!(
        player.current_signal_path().overall,
        SignalQuality::Enhanced
    );
    player.toggle_dsp_bypass();
    assert_eq!(
        player.current_signal_path().overall,
        SignalQuality::Lossless
    );

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
        .play_stream(
            StreamSource::synth("trk-001", "Time", 5_000),
            "Lumina Demo Synth",
        )
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
            .play_stream(
                StreamSource::synth("trk-001", "Time", 10_000),
                "Reroute Test",
            )
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
        assert_eq!(
            player.active_meta().unwrap().device_name,
            real_devices[0].name
        );

        player.stop();
    } else {
        // Fallback headless reroute verification on single/zero-device machines
        let hplayer = AudioPlayer::new_headless();
        hplayer
            .play_stream(
                StreamSource::synth("trk-001", "Time", 10_000),
                "Reroute Headless",
            )
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
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

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
    assert_eq!(
        infer_extension_from_magic(&[0xFF, 0xF1, 0x50, 0x80]),
        Some("aac")
    );
    assert_eq!(
        infer_extension_from_magic(&[0xFF, 0xF9, 0x50, 0x80]),
        Some("aac")
    );

    // MPEG Audio Layer III frames (layer bits != 00) and ID3v2 tags
    assert_eq!(
        infer_extension_from_magic(&[0xFF, 0xFB, 0x90, 0x00]),
        Some("mp3")
    );
    assert_eq!(infer_extension_from_magic(b"ID3\x04\x00\x00"), Some("mp3"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_playlist_parsing_and_http_resolution_plays_audio() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    let m3u_entries = parse_m3u_entries("#EXTM3U\n#EXTINF:-1,Radio\nhttp://example.com/live.aac\n");
    assert_eq!(m3u_entries, vec!["http://example.com/live.aac"]);

    let pls_entries = parse_pls_entries(
        "[playlist]\nNumberOfEntries=1\nFile1=http://example.com/live.mp3\nTitle1=Live\n",
    );
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
                        if let Some(end_pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
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
                        let body =
                            format!("[playlist]\nFile1=http://{addr}/sub.m3u\nNumberOfEntries=1\n");
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
fn test_opus_decodes_48khz_pcm() {
    let opus_ogg = build_minimal_ogg_opus_bytes();
    let mut decoder = SymphoniaDecoder::from_bytes(opus_ogg, Some("ogg"))
        .expect("Expected Ogg/Opus to decode via OpusSymphoniaDecoder");
    assert_eq!(decoder.format().codec, core_types::AudioCodec::Opus);
    assert_eq!(decoder.format().sample_rate_hz, 48_000);
    assert_eq!(decoder.format().channels, 2);

    let mut total_frames = 0usize;
    while let Some(chunk) = decoder.next_chunk().expect("decode opus chunk") {
        assert_eq!(chunk.sample_rate(), 48_000);
        assert_eq!(chunk.channels(), 2);
        total_frames += chunk.frames();
    }
    assert_eq!(
        total_frames, 648,
        "Expected 960 minus 312 pre-skip frames from minimal Opus packet"
    );
}

fn parse_http_headers(req_str: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in req_str.lines().skip(1) {
        if let Some((k, v)) = line.split_once(':') {
            out.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_http_headers_sent_on_probe_redirects_and_range_requests_and_ipv4() {
    use std::io::{Read as _, Seek as _, SeekFrom};
    use std::sync::{Arc, Mutex as StdMutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    // > 256 KiB WAV so reading offset 0 and seeking to 140_000 triggers separate 128 KiB Range chunks.
    let wav_bytes = Arc::new(build_wav_bytes(48_000, 2, 70_000));
    let listener = TokioTcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let observed = Arc::new(StdMutex::new(Vec::<(
        String,
        String,
        HashMap<String, String>,
        bool,
    )>::new()));
    let observed_srv = Arc::clone(&observed);

    let server_handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, peer)) = listener.accept().await else {
                break;
            };
            let wav_bytes = Arc::clone(&wav_bytes);
            let observed_conn = Arc::clone(&observed_srv);
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
                        if let Some(end_pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            total_read = end_pos + 4;
                            break;
                        }
                        if total_read == buf.len() {
                            break;
                        }
                    }

                    let req_str = String::from_utf8_lossy(&buf[..total_read]);
                    let first_line = req_str.lines().next().unwrap_or("");
                    let mut parts = first_line.split_whitespace();
                    let method = parts.next().unwrap_or("GET").to_string();
                    let path = parts.next().unwrap_or("/").to_string();
                    let hdrs = parse_http_headers(&req_str);

                    if let Ok(mut log) = observed_conn.lock() {
                        log.push((method.clone(), path.clone(), hdrs.clone(), peer.is_ipv4()));
                    }

                    if path == "/start.wav" {
                        let resp = format!(
                            "HTTP/1.1 302 Found\r\nLocation: http://{addr}/cdn/audio.wav\r\nContent-Length: 0\r\n\r\n"
                        );
                        if stream.write_all(resp.as_bytes()).await.is_err() {
                            return;
                        }
                    } else if path == "/cdn/audio.wav" {
                        let total_len = wav_bytes.len();
                        if method == "HEAD" {
                            // Omit Accept-Ranges so probe exercises GET Range: bytes=0-0 too.
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        } else if let Some(range_val) = hdrs.get("range")
                            && let Some(spec) = range_val.strip_prefix("bytes=")
                            && let Some((s_str, e_str)) = spec.split_once('-')
                        {
                            let start = s_str.parse::<usize>().unwrap_or(0).min(total_len - 1);
                            let end = if e_str.is_empty() {
                                total_len - 1
                            } else {
                                e_str
                                    .parse::<usize>()
                                    .unwrap_or(total_len - 1)
                                    .min(total_len - 1)
                            };
                            let slice = &wav_bytes[start..=end];
                            let resp = format!(
                                "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                                slice.len()
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err()
                                || stream.write_all(slice).await.is_err()
                            {
                                return;
                            }
                        } else {
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err()
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

    let mut headers = HashMap::new();
    headers.insert("User-Agent".to_string(), "LuminaTestAgent/2.0".to_string());
    headers.insert(
        "Accept".to_string(),
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".to_string(),
    );
    headers.insert("Accept-Language".to_string(), "en-US,en;q=0.5".to_string());
    headers.insert(
        "Referer".to_string(),
        "https://music.youtube.com/".to_string(),
    );
    headers.insert(
        "Cookie".to_string(),
        "VISITOR_INFO1_LIVE=abc123".to_string(),
    );

    let url = format!("http://{addr}/start.wav");
    let mut media = core_audio::HttpRangeMediaSource::open(&url, &headers)
        .expect("redirect + Range probe with caller headers should succeed");
    assert_eq!(media.resolved_url(), format!("http://{addr}/cdn/audio.wav"));

    let mut head_buf = [0u8; 16];
    media.read_exact(&mut head_buf).unwrap();
    assert_eq!(&head_buf[0..4], b"RIFF");

    media.seek(SeekFrom::Start(140_000)).unwrap();
    let mut second_chunk_buf = [0u8; 16];
    media.read_exact(&mut second_chunk_buf).unwrap();

    // Also verify IPv4-only DNS resolution on localhost (dual-stack Windows maps localhost to ::1 + 127.0.0.1).
    let localhost_url = format!("http://localhost:{}/cdn/audio.wav", addr.port());
    let mut localhost_media = core_audio::HttpRangeMediaSource::open(&localhost_url, &headers)
        .expect("localhost must resolve and connect over IPv4");
    let mut lh_buf = [0u8; 4];
    localhost_media.read_exact(&mut lh_buf).unwrap();
    assert_eq!(&lh_buf, b"RIFF");

    let log = observed.lock().unwrap().clone();
    assert!(
        log.len() >= 5,
        "Expected HEAD redirect + GET Range 0-0 + chunk 0 + chunk 1 + localhost requests, got {}",
        log.len()
    );
    let mut saw_range_second_chunk = false;
    for (method, path, hdrs, is_ipv4) in &log {
        assert!(*is_ipv4, "Expected IPv4 socket for {method} {path}");
        assert_eq!(
            hdrs.get("user-agent").map(String::as_str),
            Some("LuminaTestAgent/2.0"),
            "Missing/mismatched User-Agent on {method} {path}"
        );
        assert_eq!(
            hdrs.get("accept").map(String::as_str),
            Some("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
            "Missing/mismatched Accept on {method} {path}"
        );
        assert_eq!(
            hdrs.get("accept-language").map(String::as_str),
            Some("en-US,en;q=0.5"),
            "Missing/mismatched Accept-Language on {method} {path}"
        );
        assert_eq!(
            hdrs.get("referer").map(String::as_str),
            Some("https://music.youtube.com/"),
            "Referer overwritten/dropped on {method} {path}"
        );
        assert_eq!(
            hdrs.get("cookie").map(String::as_str),
            Some("VISITOR_INFO1_LIVE=abc123"),
            "Cookie dropped on {method} {path}"
        );
        if hdrs
            .get("range")
            .is_some_and(|r| r.starts_with("bytes=131072-"))
        {
            saw_range_second_chunk = true;
        }
    }
    assert!(
        saw_range_second_chunk,
        "Expected Range request for second 128KiB chunk"
    );

    server_handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_http_403_surfaces_explicit_http_403_in_media_source_and_player() {
    use std::sync::Arc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    let wav_bytes = Arc::new(build_wav_bytes(48_000, 2, 96_000)); // ~384 KiB (> 2 chunks)
    let listener = TokioTcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let wav_bytes = Arc::clone(&wav_bytes);
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
                        if let Some(end_pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            total_read = end_pos + 4;
                            break;
                        }
                        if total_read == buf.len() {
                            break;
                        }
                    }
                    let req_str = String::from_utf8_lossy(&buf[..total_read]);
                    let first_line = req_str.lines().next().unwrap_or("");
                    let mut parts = first_line.split_whitespace();
                    let method = parts.next().unwrap_or("GET");
                    let path = parts.next().unwrap_or("/");
                    let hdrs = parse_http_headers(&req_str);
                    let total_len = wav_bytes.len();

                    if path == "/always-403.m4a" {
                        let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                        if stream.write_all(resp.as_bytes()).await.is_err() {
                            return;
                        }
                    } else if path == "/head-ok-chunk0-403.wav" {
                        if method == "HEAD" {
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        } else {
                            let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                            if stream.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        }
                    } else if path == "/head-403-get-ok.wav" {
                        if method == "HEAD" {
                            let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                            if stream.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        } else if let Some(range_val) = hdrs.get("range")
                            && let Some(spec) = range_val.strip_prefix("bytes=")
                            && let Some((s_str, e_str)) = spec.split_once('-')
                        {
                            let start = s_str.parse::<usize>().unwrap_or(0).min(total_len - 1);
                            let end = e_str
                                .parse::<usize>()
                                .unwrap_or(total_len - 1)
                                .min(total_len - 1);
                            let slice = &wav_bytes[start..=end];
                            let resp = format!(
                                "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                                slice.len()
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err()
                                || stream.write_all(slice).await.is_err()
                            {
                                return;
                            }
                        }
                    } else if path == "/mid-range-403.wav" {
                        if method == "HEAD" {
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if stream.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        } else if let Some(range_val) = hdrs.get("range")
                            && let Some(spec) = range_val.strip_prefix("bytes=")
                            && let Some((s_str, e_str)) = spec.split_once('-')
                        {
                            let start = s_str.parse::<usize>().unwrap_or(0);
                            if start >= 131_072 {
                                let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                                if stream.write_all(resp.as_bytes()).await.is_err() {
                                    return;
                                }
                            } else {
                                let end = e_str
                                    .parse::<usize>()
                                    .unwrap_or(total_len - 1)
                                    .min(total_len - 1);
                                let slice = &wav_bytes[start..=end];
                                let resp = format!(
                                    "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                                    slice.len()
                                );
                                if stream.write_all(resp.as_bytes()).await.is_err()
                                    || stream.write_all(slice).await.is_err()
                                {
                                    return;
                                }
                            }
                        }
                    }
                    let _ = stream.flush().await;
                }
            });
        }
    });

    // 1. Open-time HTTP 403 in HttpRangeMediaSource and AudioPlayer
    let url_403 = format!("http://{addr}/always-403.m4a");
    let media_err = match core_audio::HttpRangeMediaSource::open(&url_403, &HashMap::new()) {
        Ok(_) => panic!("Expected HTTP 403 from HttpRangeMediaSource::open"),
        Err(e) => e,
    };
    assert!(
        media_err.to_string().contains("HTTP 403"),
        "Expected 'HTTP 403' in HttpRangeMediaSource error, got: {media_err}"
    );

    let player = AudioPlayer::new_headless();
    let play_err = player
        .play_stream(
            StreamSource::http(url_403, HashMap::new(), Some("m4a".to_string())),
            "YouTube Music",
        )
        .unwrap_err();
    assert!(
        play_err.to_string().contains("HTTP 403"),
        "Expected 'HTTP 403' in AudioPlayer::play_stream error, got: {play_err}"
    );

    // 2. HEAD 200 OK followed by Range 403 on chunk 0 during decoder open
    let head_ok_chunk0_403 = format!("http://{addr}/head-ok-chunk0-403.wav");
    let open_err = player
        .play_stream(
            StreamSource::http(head_ok_chunk0_403, HashMap::new(), Some("wav".to_string())),
            "YouTube Music",
        )
        .unwrap_err();
    assert!(
        open_err.to_string().contains("HTTP 403"),
        "Expected 'HTTP 403' when chunk 0 Range fails with 403, got: {open_err}"
    );

    // 3. Signed GET-only server rejecting HEAD with 403 while permitting GET Range
    let head_403_get_ok = format!("http://{addr}/head-403-get-ok.wav");
    player
        .play_stream(
            StreamSource::http(head_403_get_ok, HashMap::new(), Some("wav".to_string())),
            "Signed GET",
        )
        .expect("HEAD 403 should fall back to GET Range and succeed");
    player.stop();

    // 4. Mid-stream Range chunk 1 returns HTTP 403 during playback
    let mid_403 = format!("http://{addr}/mid-range-403.wav");
    player
        .play_stream(
            StreamSource::http(mid_403, HashMap::new(), Some("wav".to_string())),
            "YouTube Music",
        )
        .expect("Initial chunk 0 should start playback before mid-stream 403");

    let mut reached_403 = false;
    for _ in 0..80 {
        if player.state_code() == PlaybackLifecycleState::Error as i32
            && let Some(err) = player.last_error()
        {
            assert!(
                err.contains("HTTP 403"),
                "Expected 'HTTP 403' in mid-stream last_error, got: {err}"
            );
            reached_403 = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert!(
        reached_403,
        "Expected mid-stream Range 403 to surface Error state with 'HTTP 403', state={}, err={:?}",
        player.state_code(),
        player.last_error()
    );

    player.shutdown();
    server_handle.abort();
}

#[test]
fn test_symphonia_decoder_preserves_http_403_from_media_source_probe_and_seek() {
    use std::io::{Error, ErrorKind, Read, Seek, SeekFrom};
    use symphonia::core::io::MediaSource;

    struct Failing403Source {
        data: Vec<u8>,
        pos: u64,
        fail_after: usize,
    }

    impl Read for Failing403Source {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.pos as usize >= self.fail_after {
                return Err(Error::new(
                    ErrorKind::PermissionDenied,
                    "HTTP 403 fetching https://rr1.googlevideo.com/videoplayback",
                ));
            }
            let start = self.pos as usize;
            let avail = &self.data[start..self.fail_after.min(self.data.len())];
            let n = avail.len().min(buf.len());
            buf[..n].copy_from_slice(&avail[..n]);
            self.pos += n as u64;
            Ok(n)
        }
    }

    impl Seek for Failing403Source {
        fn seek(&mut self, style: SeekFrom) -> std::io::Result<u64> {
            let next = match style {
                SeekFrom::Start(n) => n as i64,
                SeekFrom::Current(d) => self.pos as i64 + d,
                SeekFrom::End(d) => self.data.len() as i64 + d,
            };
            if next < 0 {
                return Err(Error::new(ErrorKind::InvalidInput, "seek before start"));
            }
            self.pos = next as u64;
            Ok(self.pos)
        }
    }

    impl MediaSource for Failing403Source {
        fn is_seekable(&self) -> bool {
            true
        }
        fn byte_len(&self) -> Option<u64> {
            Some(self.data.len() as u64)
        }
    }

    // 1. Fail on very first read inside Symphonia Probe::next (offset 0) -> must preserve HTTP 403.
    let wav = build_wav_bytes(48_000, 2, 48_000);
    let err = match SymphoniaDecoder::from_media_source(
        Box::new(Failing403Source {
            data: wav.clone(),
            pos: 0,
            fail_after: 0,
        }),
        Some("m4a"),
        None,
    ) {
        Ok(_) => panic!("Expected ProbeFailed with HTTP 403"),
        Err(e) => e,
    };
    assert!(
        err.to_string().contains("HTTP 403"),
        "Expected 'HTTP 403' preserved across Symphonia probe, got: {err}"
    );

    // 2. Open succeeds when initial header is readable, then seek + next_chunk past fail_after surfaces HTTP 403.
    let mut dec = SymphoniaDecoder::from_media_source(
        Box::new(Failing403Source {
            data: wav,
            pos: 0,
            fail_after: 4096,
        }),
        Some("wav"),
        None,
    )
    .expect("WAV header within first 4KB should open");
    dec.seek(Duration::from_millis(500)).unwrap();
    let read_err = dec.next_chunk().unwrap_err();
    assert!(
        read_err.to_string().contains("HTTP 403"),
        "Expected 'HTTP 403' after seek past fail_after, got: {read_err}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_head_sends_connection_close_and_recovers_from_dropped_pooled_socket() {
    use std::io::{Read as _, Seek as _, SeekFrom};
    use std::sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    let wav_bytes = Arc::new(build_wav_bytes(48_000, 2, 70_000)); // > 256 KiB
    let listener = TokioTcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let head_conn_hdrs = Arc::new(StdMutex::new(Vec::<Option<String>>::new()));
    let head_conn_hdrs_srv = Arc::clone(&head_conn_hdrs);
    let dropped_once = Arc::new(AtomicBool::new(false));
    let dropped_once_srv = Arc::clone(&dropped_once);
    let chunk1_attempts = Arc::new(AtomicUsize::new(0));
    let chunk1_attempts_srv = Arc::clone(&chunk1_attempts);

    let server_handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let wav_bytes = Arc::clone(&wav_bytes);
            let head_hdrs = Arc::clone(&head_conn_hdrs_srv);
            let dropped = Arc::clone(&dropped_once_srv);
            let c1_attempts = Arc::clone(&chunk1_attempts_srv);
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
                        if let Some(end_pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            total_read = end_pos + 4;
                            break;
                        }
                        if total_read == buf.len() {
                            break;
                        }
                    }
                    let req_str = String::from_utf8_lossy(&buf[..total_read]);
                    let first_line = req_str.lines().next().unwrap_or("");
                    let method = first_line.split_whitespace().next().unwrap_or("GET");
                    let hdrs = parse_http_headers(&req_str);
                    let total_len = wav_bytes.len();

                    if method == "HEAD" {
                        if let Ok(mut g) = head_hdrs.lock() {
                            g.push(hdrs.get("connection").cloned());
                        }
                        let resp = format!(
                            "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\nConnection: close\r\n\r\n"
                        );
                        let _ = stream.write_all(resp.as_bytes()).await;
                        let _ = stream.flush().await;
                        let _ = stream.shutdown().await;
                        return;
                    } else if let Some(range_val) = hdrs.get("range")
                        && let Some(spec) = range_val.strip_prefix("bytes=")
                        && let Some((s_str, e_str)) = spec.split_once('-')
                    {
                        let start = s_str.parse::<usize>().unwrap_or(0);
                        // Simulate googlevideo closing/resetting a pooled keep-alive socket before chunk 1.
                        if start >= 131_072 {
                            c1_attempts.fetch_add(1, Ordering::Relaxed);
                            if !dropped.swap(true, Ordering::SeqCst) {
                                drop(stream);
                                return;
                            }
                        }
                        let start = start.min(total_len - 1);
                        let end = e_str
                            .parse::<usize>()
                            .unwrap_or(total_len - 1)
                            .min(total_len - 1);
                        let slice = &wav_bytes[start..=end];
                        let resp = format!(
                            "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                            slice.len()
                        );
                        if stream.write_all(resp.as_bytes()).await.is_err()
                            || stream.write_all(slice).await.is_err()
                        {
                            return;
                        }
                    }
                    let _ = stream.flush().await;
                }
            });
        }
    });

    let url = format!("http://{addr}/gvs.wav");
    let mut media = core_audio::HttpRangeMediaSource::open(&url, &HashMap::new())
        .expect("HEAD with Connection: close should open cleanly");
    let mut chunk0 = [0u8; 16];
    media.read_exact(&mut chunk0).unwrap();
    assert_eq!(&chunk0[0..4], b"RIFF");

    // First chunk 1 request hits a dropped pooled socket and must recover automatically on retry.
    media.seek(SeekFrom::Start(140_000)).unwrap();
    let mut chunk1 = [0u8; 16];
    media.read_exact(&mut chunk1).unwrap();
    assert_eq!(
        &chunk1,
        &build_wav_bytes(48_000, 2, 70_000)[140_000..140_016]
    );

    let recorded_head = head_conn_hdrs.lock().unwrap().clone();
    assert!(!recorded_head.is_empty());
    assert!(
        recorded_head.iter().all(|v| v.as_deref() == Some("close")),
        "Expected Connection: close on HEAD probe, got: {recorded_head:?}"
    );
    assert!(
        chunk1_attempts.load(Ordering::Relaxed) >= 2,
        "Expected stale socket retry on chunk 1"
    );

    server_handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_sequential_http_stream_survives_body_delay_longer_than_open_timeout() {
    use std::io::Read as _;
    use std::sync::Arc;
    use symphonia::core::io::MediaSource as _;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    let full_wav = Arc::new(build_wav_bytes(48_000, 2, 8_192));
    let expected_wav = Arc::clone(&full_wav);
    let split = full_wav.len() / 2;
    let listener = TokioTcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let full_wav = Arc::clone(&full_wav);
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let mut total_read = 0;
                loop {
                    let Ok(n) = stream.read(&mut buf[total_read..]).await else {
                        return;
                    };
                    if n == 0 {
                        return;
                    }
                    total_read += n;
                    if buf[..total_read].windows(4).any(|w| w == b"\r\n\r\n")
                        || total_read == buf.len()
                    {
                        break;
                    }
                }
                let req_str = String::from_utf8_lossy(&buf[..total_read]);
                let method = req_str
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().next())
                    .unwrap_or("GET");
                let total_len = full_wav.len();

                if method == "HEAD" {
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nAccept-Ranges: none\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\nConnection: close\r\n\r\n"
                    );
                    let _ = stream.write_all(resp.as_bytes()).await;
                    let _ = stream.flush().await;
                    let _ = stream.shutdown().await;
                } else {
                    let hdr = format!(
                        "HTTP/1.1 200 OK\r\nAccept-Ranges: none\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\nConnection: close\r\n\r\n"
                    );
                    if stream.write_all(hdr.as_bytes()).await.is_err()
                        || stream.write_all(&full_wav[..split]).await.is_err()
                        || stream.flush().await.is_err()
                    {
                        return;
                    }
                    // Exceed the 400ms open timeout before sending the rest of the body.
                    tokio::time::sleep(Duration::from_millis(700)).await;
                    let _ = stream.write_all(&full_wav[split..]).await;
                    let _ = stream.flush().await;
                    let _ = stream.shutdown().await;
                }
            });
        }
    });

    let url = format!("http://{addr}/slow-seq.wav");
    let mut media = core_audio::HttpRangeMediaSource::open_with_cancel(
        &url,
        &HashMap::new(),
        None,
        Duration::from_millis(400),
    )
    .expect("Sequential open should succeed before 400ms header timeout");
    assert!(
        !media.is_seekable(),
        "Expected Accept-Ranges: none + 200 OK to open in Sequential mode"
    );

    let mut received = Vec::new();
    media
        .read_to_end(&mut received)
        .expect("Sequential body read after 700ms (> 400ms open timeout) must not time out");
    assert_eq!(received.as_slice(), expected_wav.as_slice());

    server_handle.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_sequential_http_backward_seek_stays_playing_not_error() {
    use std::io::{ErrorKind, Read as _, Seek as _, SeekFrom};
    use std::sync::Arc;
    use symphonia::core::io::MediaSource as _;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener as TokioTcpListener;

    // 3s @ 192 kHz stereo PCM (~2.2 MiB) so headless playback advances well past the 256 KiB retained window.
    let wav_bytes = Arc::new(build_wav_bytes(192_000, 2, 192_000 * 3));
    let listener = TokioTcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_handle = tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let wav_bytes = Arc::clone(&wav_bytes);
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let mut total_read = 0;
                loop {
                    let Ok(n) = stream.read(&mut buf[total_read..]).await else {
                        return;
                    };
                    if n == 0 {
                        return;
                    }
                    total_read += n;
                    if buf[..total_read].windows(4).any(|w| w == b"\r\n\r\n")
                        || total_read == buf.len()
                    {
                        break;
                    }
                }
                let req_str = String::from_utf8_lossy(&buf[..total_read]);
                let method = req_str
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().next())
                    .unwrap_or("GET");

                if method == "HEAD" {
                    let resp = "HTTP/1.1 200 OK\r\nAccept-Ranges: none\r\nContent-Type: audio/wav\r\nConnection: close\r\n\r\n";
                    let _ = stream.write_all(resp.as_bytes()).await;
                    let _ = stream.flush().await;
                    let _ = stream.shutdown().await;
                } else {
                    let hdr = "HTTP/1.1 200 OK\r\nAccept-Ranges: none\r\nContent-Type: audio/wav\r\nConnection: close\r\n\r\n";
                    if stream.write_all(hdr.as_bytes()).await.is_err() {
                        return;
                    }
                    for chunk in wav_bytes.chunks(32 * 1024) {
                        if stream.write_all(chunk).await.is_err() {
                            return;
                        }
                        let _ = stream.flush().await;
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                    let _ = stream.shutdown().await;
                }
            });
        }
    });

    let url = format!("http://{addr}/live-seq.wav");
    let player = AudioPlayer::new_headless();
    player
        .play_stream(
            StreamSource::http(url.clone(), HashMap::new(), Some("wav".to_string())),
            "Sequential Stream",
        )
        .expect("Sequential loopback WAV stream should start playing");

    // Advance past 256 KiB (~365ms @ 192kHz stereo 16-bit = 280 KiB consumed + buffers).
    for _ in 0..80 {
        if player.nonzero_output_frames() >= 70_000 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
    assert!(
        player.nonzero_output_frames() >= 70_000,
        "Expected playback to advance past 256 KiB before seeking"
    );

    // Issue backward seek_ms(0) on non-seekable Sequential stream.
    player.seek_ms(0);
    tokio::time::sleep(Duration::from_millis(120)).await;
    assert_eq!(
        player.state_code(),
        PlaybackLifecycleState::Playing as i32,
        "Expected AudioPlayer to stay Playing (2) after unsupported sequential seek, last_error={:?}",
        player.last_error()
    );
    assert_ne!(
        player.state_code(),
        PlaybackLifecycleState::Error as i32,
        "AudioPlayer must not enter Error state on non-seekable sequential seek"
    );
    assert!(
        player.last_error().is_none(),
        "Expected no last_error after non-seekable sequential seek, got {:?}",
        player.last_error()
    );

    let frames_after_seek = player.nonzero_output_frames();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        player.nonzero_output_frames() > frames_after_seek,
        "Expected audio decoding/output to continue after rejected seek"
    );
    player.stop();
    player.shutdown();

    // Verify SequentialState directly returns ErrorKind::Unsupported for backward seek past retained
    // buffer and SeekFrom::End without Content-Length.
    let mut media = core_audio::HttpRangeMediaSource::open(&url, &HashMap::new())
        .expect("Sequential source open");
    assert!(!media.is_seekable());
    let mut prefix = vec![0u8; 300 * 1024];
    media
        .read_exact(&mut prefix)
        .expect("Read past 256 KiB history");
    let back_err = media.seek(SeekFrom::Start(270 * 1024)).unwrap_err();
    assert_eq!(back_err.kind(), ErrorKind::Unsupported);
    let end_err = media.seek(SeekFrom::End(0)).unwrap_err();
    assert_eq!(end_err.kind(), ErrorKind::Unsupported);

    server_handle.abort();
}
