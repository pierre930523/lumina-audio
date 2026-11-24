use std::collections::HashMap;
use std::f64::consts::PI;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use core_audio::dsp::DspPipeline;
use core_audio::{
    parse_autoeq_profile_dto, parse_autoeq_txt, AudioPlayer, BackendError, CoreAudioError,
    PlaybackLifecycleState, StreamSource,
};
use core_types::{
    CrossfeedConfig, DspPipelineConfig, OutputBackendKind, PeqBandConfig, PeqFilterKind,
    ReplayGainConfig, ReplayGainMode, SignalQuality,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

fn build_synthetic_wav(sample_rate: u32, channels: u16, num_frames: u32) -> Vec<u8> {
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
        let sample_i16 = (s * 20000.0) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample_i16.to_le_bytes());
        }
    }
    buf
}

fn build_synthetic_dsf(num_blocks: usize) -> Vec<u8> {
    let block_size = 4096u32;
    let channels = 2u16;
    let sample_rate = 2_822_400u32;
    let data_len = (num_blocks as u64) * (block_size as u64) * (channels as u64);
    let sample_count = (num_blocks as u64) * (block_size as u64) * 8;
    let file_size = 28 + 52 + 12 + data_len;

    let mut buf = Vec::with_capacity(file_size as usize);
    // 'DSD ' chunk (28 bytes)
    buf.extend_from_slice(b"DSD ");
    buf.extend_from_slice(&28u64.to_le_bytes());
    buf.extend_from_slice(&file_size.to_le_bytes());
    buf.extend_from_slice(&0u64.to_le_bytes());

    // 'fmt ' chunk (52 bytes)
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&52u64.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes()); // version
    buf.extend_from_slice(&0u32.to_le_bytes()); // format id (DSD raw)
    buf.extend_from_slice(&2u32.to_le_bytes()); // channel type (stereo)
    buf.extend_from_slice(&(channels as u32).to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes()); // bits per sample
    buf.extend_from_slice(&sample_count.to_le_bytes());
    buf.extend_from_slice(&block_size.to_le_bytes());
    buf.extend_from_slice(&0u32.to_le_bytes()); // reserved

    // 'data' chunk (12 + data_len bytes)
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&(12 + data_len).to_le_bytes());
    buf.resize(file_size as usize, 0x69); // DSD silence pattern
    buf
}

#[derive(Clone, Copy)]
enum MockServerMode {
    RangeWithAuth,
    NonRange200Only,
}

async fn spawn_mock_audio_http_server(
    payload: Vec<u8>,
    content_type: &'static str,
    required_auth: Option<&'static str>,
    mode: MockServerMode,
) -> (String, Arc<AtomicUsize>, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let payload = Arc::new(payload);
    let range_hits = Arc::new(AtomicUsize::new(0));
    let hits_clone = Arc::clone(&range_hits);

    let handle = tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let payload = Arc::clone(&payload);
            let hits = Arc::clone(&hits_clone);
            tokio::spawn(async move {
                let mut req_buf = vec![0u8; 16384];
                loop {
                    let mut total_read = 0;
                    loop {
                        let Ok(n) = socket.read(&mut req_buf[total_read..]).await else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        total_read += n;
                        if let Some(end_pos) = req_buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n") {
                            total_read = end_pos + 4;
                            break;
                        }
                        if total_read == req_buf.len() {
                            break;
                        }
                    }

                    let req_str = String::from_utf8_lossy(&req_buf[..total_read]);
                    let mut lines = req_str.lines();
                    let req_line = lines.next().unwrap_or("");
                    let method = req_line.split_whitespace().next().unwrap_or("GET");

                    let mut auth_hdr: Option<String> = None;
                    let mut range_hdr: Option<String> = None;
                    for line in lines {
                        if let Some((k, v)) = line.split_once(':') {
                            if k.trim().eq_ignore_ascii_case("authorization") {
                                auth_hdr = Some(v.trim().to_string());
                            } else if k.trim().eq_ignore_ascii_case("range") {
                                range_hdr = Some(v.trim().to_string());
                            }
                        }
                    }

                    if let Some(expected) = required_auth
                        && auth_hdr.as_deref() != Some(expected)
                    {
                        let resp = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
                        if socket.write_all(resp.as_bytes()).await.is_err() {
                            return;
                        }
                        let _ = socket.flush().await;
                        continue;
                    }

                    let total_len = payload.len();
                    match (mode, method) {
                        (MockServerMode::NonRange200Only, "HEAD") => {
                            let resp = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n";
                            if socket.write_all(resp.as_bytes()).await.is_err() {
                                return;
                            }
                        }
                        (MockServerMode::NonRange200Only, _) => {
                            let header = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if socket.write_all(header.as_bytes()).await.is_err()
                                || socket.write_all(&payload).await.is_err()
                            {
                                return;
                            }
                        }
                        (MockServerMode::RangeWithAuth, "HEAD") => {
                            let header = format!(
                                "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: {content_type}\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if socket.write_all(header.as_bytes()).await.is_err() {
                                return;
                            }
                        }
                        (MockServerMode::RangeWithAuth, _) => {
                            if let Some(r) = range_hdr
                                && let Some(spec) = r.strip_prefix("bytes=")
                                && let Some((s_str, e_str)) = spec.split_once('-')
                            {
                                let start = s_str.parse::<usize>().unwrap_or(0).min(total_len.saturating_sub(1));
                                let end = if e_str.is_empty() {
                                    total_len.saturating_sub(1)
                                } else {
                                    e_str.parse::<usize>().unwrap_or(total_len - 1).min(total_len - 1)
                                };
                                hits.fetch_add(1, Ordering::Relaxed);
                                let slice = &payload[start..=end];
                                let header = format!(
                                    "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: {content_type}\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                                    slice.len()
                                );
                                if socket.write_all(header.as_bytes()).await.is_err()
                                    || socket.write_all(slice).await.is_err()
                                {
                                    return;
                                }
                            } else {
                                let header = format!(
                                    "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: {content_type}\r\nContent-Length: {total_len}\r\n\r\n"
                                );
                                if socket.write_all(header.as_bytes()).await.is_err()
                                    || socket.write_all(&payload).await.is_err()
                                {
                                    return;
                                }
                            }
                        }
                    }
                    let _ = socket.flush().await;
                }
            });
        }
    });

    (format!("http://{addr}"), range_hits, handle)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_f35_http_range_stream_inside_tokio_runtime_and_auth_check() {
    let wav = build_synthetic_wav(48_000, 2, 96_000); // 2 seconds
    let (base_url, range_hits, server_task) = spawn_mock_audio_http_server(
        wav,
        "audio/wav",
        Some("Bearer lumina-stream-token"),
        MockServerMode::RangeWithAuth,
    )
    .await;

    let player = AudioPlayer::new_headless();

    // Missing/wrong auth header must fail cleanly
    let bad_stream = StreamSource::http(
        format!("{base_url}/track.wav"),
        HashMap::new(),
        Some("wav".to_string()),
    );
    assert!(player.play_stream(bad_stream, "Unauthorized Test").is_err());

    // Valid auth header inside a Tokio multi-thread runtime must NOT panic
    let mut headers = HashMap::new();
    headers.insert(
        "Authorization".to_string(),
        "Bearer lumina-stream-token".to_string(),
    );
    let stream = StreamSource::http(
        format!("{base_url}/stream/track?token=abc"),
        headers,
        Some("wav".to_string()),
    )
    .with_replay_gain(Some(-4.5), Some(-5.2), Some(0.95), Some(0.98));

    player
        .play_stream(stream, "Qobuz Stream")
        .expect("play_stream should succeed inside Tokio runtime");

    assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);
    assert!(player.duration_ms() >= 1900);

    tokio::time::sleep(Duration::from_millis(120)).await;
    assert!(
        player.position_ms() > 0,
        "Expected HTTP stream playback position_ms > 0"
    );
    assert!(
        range_hits.load(Ordering::Relaxed) >= 1,
        "Expected 206 Partial Content range requests"
    );

    player.seek_ms(800);
    assert_eq!(player.position_ms(), 800);
    tokio::time::sleep(Duration::from_millis(60)).await;

    let sp = player.current_signal_path();
    assert!(sp.nodes[0].detail.contains("Qobuz Stream"));

    player.stop();
    assert_eq!(player.state_code(), PlaybackLifecycleState::Stopped as i32);
    player.shutdown();
    server_task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_f35_http_non_range_fallback_and_magic_detection() {
    let wav = build_synthetic_wav(44_100, 2, 44_100); // 1 second
    let (base_url, _hits, server_task) = spawn_mock_audio_http_server(
        wav,
        "application/octet-stream",
        None,
        MockServerMode::NonRange200Only,
    )
    .await;

    let player = AudioPlayer::new_headless();
    // No extension in URL and no hint_extension -> relies on magic prefix detection
    let stream = StreamSource::http(
        format!("{base_url}/opaque-audio-endpoint"),
        HashMap::new(),
        None,
    );

    player
        .play_stream(stream, "Non-Range Fallback")
        .expect("non-range HTTP stream with magic detection should decode");
    assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(player.position_ms() > 0);

    player.stop();
    player.shutdown();
    server_task.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_f35_http_dsf_range_stream_playback() {
    // 64 blocks * 4096 bytes * 8 bits / 2_822_400 Hz = ~0.74 seconds of DSD64
    let dsf = build_synthetic_dsf(64);
    let (base_url, _hits, server_task) = spawn_mock_audio_http_server(
        dsf,
        "audio/dsf",
        None,
        MockServerMode::RangeWithAuth,
    )
    .await;

    let player = AudioPlayer::new_headless();
    let stream = StreamSource::http(
        format!("{base_url}/sacd-track"),
        HashMap::new(),
        None, // detect "DSD " magic bytes automatically
    );

    player
        .play_stream(stream, "WebDAV DSD64")
        .expect("DSF over HTTP range stream should open cleanly");
    let meta = player.active_meta().expect("active_meta should be populated");
    assert!(meta.format.is_dsd);
    assert_eq!(meta.format.sample_rate_hz, 2_822_400);

    // Allow bounded time for debug-mode DSD64 software decimation to reach the 500 ms startup watermark.
    for _ in 0..60 {
        if player.position_ms() > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(player.position_ms() > 0);

    player.stop();
    player.shutdown();
    server_task.abort();
}

fn temp_wav_path(name: &str) -> PathBuf {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lumina_m7a_{name}_{ts}.wav"))
}

#[test]
fn test_f36_autoeq_parsing_live_dsp_wiring_and_signal_path() {
    // 1. AutoEQ parsing with attached units and Preamp
    let autoeq_txt = r#"
Preamp: -4.5dB
Filter 1: ON PK Fc 63Hz Gain 4.0dB Q 1.20
Filter 2: ON LSC Fc 105 Hz Gain 3.5 dB Q 0.71
Filter 3: ON HSC Fc 8000 Hz Gain -2.0 dB Q 0.71
Filter 4: OFF PK Fc 500 Hz Gain -1.5 dB Q 2.0
"#;
    let (preamp, bands) = parse_autoeq_profile_dto(autoeq_txt).unwrap();
    assert_eq!(preamp, -4.5);
    assert_eq!(bands.len(), 4);
    assert_eq!(bands[0].frequency_hz, 63.0);
    assert_eq!(bands[0].gain_db, 4.0);
    assert_eq!(bands[1].filter_type, PeqFilterKind::LowShelf);
    assert_eq!(bands[2].filter_type, PeqFilterKind::HighShelf);
    assert!(!bands[3].enabled);

    let bands_only = parse_autoeq_txt(autoeq_txt).unwrap();
    assert_eq!(bands_only.len(), 4);

    // Invalid / empty AutoEQ text rejected
    assert!(parse_autoeq_txt("").is_err());
    assert!(parse_autoeq_txt("Preamp: -2.0 dB\n# no filters").is_err());
    assert!(parse_autoeq_txt("Filter 1: ON PK Fc notanumber Hz Gain 1 dB Q 1").is_err());

    // 2. DspPipeline::is_dsp_active reflects user DSP accurately
    let mut pipe = DspPipeline::new(48_000.0, 2).unwrap();
    assert!(!pipe.is_dsp_active());
    pipe.set_crossfeed_enabled(true);
    assert!(pipe.is_dsp_active());
    pipe.set_crossfeed_enabled(false);
    assert!(!pipe.is_dsp_active());

    // 3. Live DSP wiring on AudioPlayer
    let wav_path = temp_wav_path("dsp_live");
    fs::write(&wav_path, build_synthetic_wav(48_000, 2, 96_000)).unwrap();

    let player = AudioPlayer::new_headless();
    let stream = StreamSource::local_file(&wav_path).with_replay_gain(
        Some(-6.0),
        Some(-3.0),
        Some(0.8),
        Some(0.9),
    );
    player.play_stream(stream, "Local FLAC").unwrap();

    // Starts with default 2-band PEQ -> Enhanced
    let initial_sp = player.current_signal_path();
    assert_eq!(initial_sp.overall, SignalQuality::Enhanced);
    let dsp_node = initial_sp
        .nodes
        .iter()
        .find(|n| n.stage == "64-bit DSP")
        .expect("default DSP node present");
    assert!(dsp_node.detail.contains("PEQ (2 bands)"));

    // Invalid DSP config must be rejected without corrupting state
    let invalid_cfg = DspPipelineConfig {
        bypass: false,
        peq_bands: vec![PeqBandConfig {
            filter_type: PeqFilterKind::Peaking,
            frequency_hz: 0.0,
            gain_db: 3.0,
            q_factor: 1.0,
            enabled: true,
        }],
        ..Default::default()
    };
    assert!(player.set_dsp_config(invalid_cfg).is_err());

    // Flat empty DSP config -> Lossless (64-bit DSP node omitted)
    player.set_dsp_config(DspPipelineConfig::default()).unwrap();
    thread::sleep(Duration::from_millis(30));
    let flat_sp = player.current_signal_path();
    assert_eq!(flat_sp.overall, SignalQuality::Lossless);
    assert!(!flat_sp.nodes.iter().any(|n| n.stage == "64-bit DSP"));

    // Enable AutoEQ PEQ + Crossfeed + ReplayGain Track
    let active_cfg = DspPipelineConfig {
        bypass: false,
        peq_bands: bands_only,
        crossfeed: CrossfeedConfig {
            enabled: true,
            cutoff_hz: 700.0,
            feed_level_db: -6.0,
        },
        replay_gain: ReplayGainConfig {
            mode: ReplayGainMode::Track,
            preamp_db: 0.0,
            prevent_clipping: true,
        },
    };
    player.set_dsp_config(active_cfg.clone()).unwrap();
    thread::sleep(Duration::from_millis(40));

    let active_sp = player.current_signal_path();
    assert_eq!(active_sp.overall, SignalQuality::Enhanced);
    let active_dsp_node = active_sp
        .nodes
        .iter()
        .find(|n| n.stage == "64-bit DSP")
        .unwrap();
    assert!(active_dsp_node.detail.contains("PEQ (3 bands)"));
    assert!(active_dsp_node.detail.contains("Crossfeed"));
    assert!(active_dsp_node.detail.contains("ReplayGain (-6.0 dB)"));

    // Switch ReplayGain mode to Album -> -3.0 dB reflected in SignalPath
    let mut album_cfg = active_cfg;
    album_cfg.replay_gain.mode = ReplayGainMode::Album;
    player.set_dsp_config(album_cfg).unwrap();
    let album_sp = player.current_signal_path();
    let album_dsp_node = album_sp
        .nodes
        .iter()
        .find(|n| n.stage == "64-bit DSP")
        .unwrap();
    assert!(album_dsp_node.detail.contains("ReplayGain (-3.0 dB)"));

    // ReplayGain anti-clipping check (+6 dB on 0.8 peak -> clamped to 1.0/0.8 = +1.9 dB)
    let boost_stream = StreamSource::local_file(&wav_path).with_replay_gain(
        Some(6.0),
        None,
        Some(0.8),
        None,
    );
    player.play_stream(boost_stream, "Clip Guard Test").unwrap();
    let mut track_boost_cfg = player.get_dsp_config();
    track_boost_cfg.replay_gain.mode = ReplayGainMode::Track;
    track_boost_cfg.replay_gain.prevent_clipping = true;
    player.set_dsp_config(track_boost_cfg).unwrap();
    let clamped_sp = player.current_signal_path();
    let clamped_node = clamped_sp
        .nodes
        .iter()
        .find(|n| n.stage == "64-bit DSP")
        .unwrap();
    assert!(clamped_node.detail.contains("ReplayGain (+1.9 dB)"));

    // Bypass -> Lossless and syncs get_dsp_config().bypass
    assert!(player.toggle_dsp_bypass());
    assert!(player.get_dsp_config().bypass);
    assert_eq!(player.current_signal_path().overall, SignalQuality::Lossless);

    player.stop();
    player.shutdown();
    let _ = fs::remove_file(wav_path);
}

#[test]
fn test_f40_output_device_enumeration_and_selection() {
    let headless_player = AudioPlayer::new_headless();
    let headless_devices = headless_player.list_output_devices();
    assert!(!headless_devices.is_empty());
    assert!(headless_devices.iter().any(|d| d.id == "virtual-exclusive-dac"));

    // Selecting virtual DAC succeeds
    headless_player
        .select_output_device(
            Some("virtual-exclusive-dac"),
            Some(OutputBackendKind::WindowsWasapiExclusive),
        )
        .unwrap();

    // Selecting non-existent device fails with DeviceNotFound
    let err = headless_player
        .select_output_device(Some("definitely-non-existent-device"), None)
        .unwrap_err();
    match err {
        CoreAudioError::Backend(BackendError::DeviceNotFound(id)) => {
            assert_eq!(id, "definitely-non-existent-device");
        }
        other => panic!("Expected DeviceNotFound, got {other:?}"),
    }

    // Resetting to system default succeeds
    headless_player.select_output_device(None, None).unwrap();

    // Non-headless enumeration always returns at least one device (real cpal or virtual fallback)
    let real_player = AudioPlayer::new();
    let real_devices = real_player.list_output_devices();
    assert!(!real_devices.is_empty());
    for dev in &real_devices {
        assert!(!dev.id.is_empty());
        assert!(!dev.name.is_empty());
        assert!(!dev.supported_sample_rates.is_empty());
        assert!(!dev.supported_bit_depths.is_empty());
    }

    // Selecting a valid enumerated device succeeds
    let first_id = real_devices[0].id.clone();
    real_player
        .select_output_device(Some(&first_id), Some(real_devices[0].backend))
        .unwrap();
    real_player.select_output_device(None, None).unwrap();

    headless_player.shutdown();
    real_player.shutdown();
}
