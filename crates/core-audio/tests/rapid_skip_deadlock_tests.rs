use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use core_audio::player::AudioPlayer;
use core_audio::stream::{HttpRangeMediaSource, StreamSource};
use core_audio::streaming::{BlockingStreamBridge, ChunkedStreamProxy};
use core_types::{DeckTrackMetadata, StreamKey, StreamSourceSpec};
use tokio_util::sync::CancellationToken;

/// Generates a minimal valid PCM16 stereo WAV file containing a 440 Hz sine tone.
fn write_sine_wav(path: &Path, sample_rate: u32, duration_ms: u32) {
    let channels: u16 = 2;
    let bits_per_sample: u16 = 16;
    let total_frames = ((sample_rate as u64 * duration_ms as u64) / 1000).max(256) as usize;
    let block_align = channels * (bits_per_sample / 8);
    let byte_rate = sample_rate * block_align as u32;
    let data_bytes = (total_frames * block_align as usize) as u32;
    let riff_size = 36u32 + data_bytes;

    let mut file = std::fs::File::create(path).expect("create wav");
    file.write_all(b"RIFF").unwrap();
    file.write_all(&riff_size.to_le_bytes()).unwrap();
    file.write_all(b"WAVE").unwrap();
    file.write_all(b"fmt ").unwrap();
    file.write_all(&16u32.to_le_bytes()).unwrap();
    file.write_all(&1u16.to_le_bytes()).unwrap(); // PCM
    file.write_all(&channels.to_le_bytes()).unwrap();
    file.write_all(&sample_rate.to_le_bytes()).unwrap();
    file.write_all(&byte_rate.to_le_bytes()).unwrap();
    file.write_all(&block_align.to_le_bytes()).unwrap();
    file.write_all(&bits_per_sample.to_le_bytes()).unwrap();
    file.write_all(b"data").unwrap();
    file.write_all(&data_bytes.to_le_bytes()).unwrap();

    let mut buf = Vec::with_capacity(data_bytes as usize);
    for n in 0..total_frames {
        let t = (n as f64) / (sample_rate as f64);
        let sample = ((2.0 * std::f64::consts::PI * 440.0 * t).sin() * 14_000.0) as i16;
        let le = sample.to_le_bytes();
        buf.extend_from_slice(&le);
        buf.extend_from_slice(&le);
    }
    file.write_all(&buf).unwrap();
    file.flush().unwrap();
}

/// Spawns a local TCP server that either stalls before sending headers (`send_partial_body = false`)
/// or sends valid 200 OK headers + 64 bytes and then stalls indefinitely until shutdown.
fn spawn_stalled_http_server(send_partial_body: bool) -> (std::net::SocketAddr, Arc<AtomicBool>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock tcp");
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_bg = Arc::clone(&stop);

    thread::spawn(move || {
        let mut held_sockets = Vec::new();
        while !stop_bg.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let _ = stream.set_nonblocking(false);
                    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
                    let mut req = [0u8; 1024];
                    let _ = stream.read(&mut req);
                    if send_partial_body {
                        let resp = concat!(
                            "HTTP/1.1 200 OK\r\n",
                            "Content-Type: audio/wav\r\n",
                            "Content-Length: 1048576\r\n",
                            "\r\n"
                        );
                        let _ = stream.write_all(resp.as_bytes());
                        let _ = stream.write_all(&[0x42u8; 64]);
                        let _ = stream.flush();
                    }
                    // Keep socket open without closing so client stays blocked until cancelled.
                    held_sockets.push(stream);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(_) => break,
            }
        }
        drop(held_sockets);
    });

    (addr, stop)
}

#[test]
fn test_stalled_http_and_blocking_bridge_cancel_promptly() {
    // 1. Stalled HttpRangeMediaSource::open_with_token (headers never arrive).
    let (stall_open_addr, stop_open) = spawn_stalled_http_server(false);
    let url_open = format!("http://{stall_open_addr}/stall-open.flac");
    let cancel_open = CancellationToken::new();
    let cancel_open_bg = cancel_open.clone();

    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let jh = thread::spawn(move || {
        let _ = ready_tx.send(());
        HttpRangeMediaSource::open_with_token(
            &url_open,
            &HashMap::new(),
            cancel_open_bg,
            Duration::from_secs(30),
        )
    });
    ready_rx.recv().unwrap();
    thread::sleep(Duration::from_millis(40));

    let t0 = Instant::now();
    cancel_open.cancel();
    let res = jh.join().unwrap();
    let elapsed_open = t0.elapsed();
    assert!(res.is_err(), "cancelled open must return Err");
    assert!(
        elapsed_open < Duration::from_millis(50),
        "open_with_token cancel took {:?} (expected < 50ms)",
        elapsed_open
    );
    stop_open.store(true, Ordering::SeqCst);

    // 2. Stalled HttpRangeMediaSource::read() after headers + 64 bytes delivered.
    let (stall_body_addr, stop_body) = spawn_stalled_http_server(true);
    let url_body = format!("http://{stall_body_addr}/stall-body.wav");
    let cancel_body = CancellationToken::new();
    let mut media = HttpRangeMediaSource::open_with_token(
        &url_body,
        &HashMap::new(),
        cancel_body.clone(),
        Duration::from_secs(5),
    )
    .expect("open partial body source");
    // Drain the initial 64 bytes delivered with headers so the next read blocks on network.
    let mut initial = [0u8; 64];
    let _ = media.read(&mut initial);

    let (read_ready_tx, read_ready_rx) = std::sync::mpsc::channel();
    let jh_read = thread::spawn(move || {
        let _ = read_ready_tx.send(());
        let mut buf = [0u8; 512];
        media.read(&mut buf)
    });
    read_ready_rx.recv().unwrap();
    thread::sleep(Duration::from_millis(40));

    let t1 = Instant::now();
    cancel_body.cancel();
    let read_res = jh_read.join().unwrap();
    let elapsed_read = t1.elapsed();
    assert!(read_res.is_err(), "cancelled HttpRangeMediaSource::read must error");
    assert_eq!(
        read_res.unwrap_err().kind(),
        std::io::ErrorKind::Interrupted
    );
    assert!(
        elapsed_read < Duration::from_millis(50),
        "HttpRangeMediaSource::read cancel took {:?} (expected < 50ms)",
        elapsed_read
    );
    stop_body.store(true, Ordering::SeqCst);

    // 3. Stalled BlockingStreamBridge::read() over ChunkedStreamProxy.
    let (stall_chunk_addr, stop_chunk) = spawn_stalled_http_server(false);
    let url_chunk = format!("http://{stall_chunk_addr}/stall-chunk.flac");
    let cancel_chunk = CancellationToken::new();
    let proxy = Arc::new(
        ChunkedStreamProxy::new(url_chunk, &BTreeMap::new(), Some(65_536), None, None)
            .unwrap()
            .with_cancellation_token(cancel_chunk.clone()),
    );
    let mut bridge = BlockingStreamBridge::new(proxy).unwrap();
    let (br_tx, br_rx) = std::sync::mpsc::channel();
    let jh_bridge = thread::spawn(move || {
        let _ = br_tx.send(());
        let mut buf = [0u8; 1024];
        bridge.read(&mut buf)
    });
    br_rx.recv().unwrap();
    thread::sleep(Duration::from_millis(40));

    let t2 = Instant::now();
    cancel_chunk.cancel();
    let br_res = jh_bridge.join().unwrap();
    let elapsed_bridge = t2.elapsed();
    assert!(br_res.is_err(), "cancelled BlockingStreamBridge::read must error");
    assert_eq!(br_res.unwrap_err().kind(), std::io::ErrorKind::Interrupted);
    assert!(
        elapsed_bridge < Duration::from_millis(50),
        "BlockingStreamBridge::read cancel took {:?} (expected < 50ms)",
        elapsed_bridge
    );
    stop_chunk.store(true, Ordering::SeqCst);
}

#[test]
fn test_30_rapid_skips_mixed_rates_no_deadlock_minimal_reopens_no_thread_leaks() {
    let tmp_dir = std::env::temp_dir().join(format!(
        "lumina_rapid_skip_test_{}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&tmp_dir);

    let wav_44k: PathBuf = tmp_dir.join("track_44100.wav");
    let wav_48k: PathBuf = tmp_dir.join("track_48000.wav");
    let wav_96k: PathBuf = tmp_dir.join("track_96000.wav");
    write_sine_wav(&wav_44k, 44_100, 1500);
    write_sine_wav(&wav_48k, 48_000, 1500);
    write_sine_wav(&wav_96k, 96_000, 1500);

    let (stall_addr, stop_stall) = spawn_stalled_http_server(false);
    let stalled_url = format!("http://{stall_addr}/stalled-ytm.webm");

    let player = AudioPlayer::new_headless();
    let initial_epoch = player.playback_epoch();

    // Part A: Start a 48 kHz track and do 8 rapid same-rate skips -> hot-swap reuses output!
    let spec_48 = |idx: usize| StreamSourceSpec::LocalFile {
        key: StreamKey::new("local", format!("same-48-{idx}"), "native"),
        path: wav_48k.to_string_lossy().to_string(),
        loudness: None,
        album_loudness: None,
    };

    let (ep0, tok0) = player.begin_skip_transition();
    let dec0 = core_audio::player::open_decoder_for_source_spec(&spec_48(0), tok0.clone()).unwrap();
    player
        .start_opened_source_spec_with_metadata(&spec_48(0), dec0, "Local", ep0, tok0, None)
        .unwrap();
    let reopens_after_first = player.output_reopen_count();
    assert_eq!(reopens_after_first, 1);

    for i in 1..=8 {
        let t_skip = Instant::now();
        let (play_ep, cancel) = player.begin_skip_transition();
        assert!(
            t_skip.elapsed() < Duration::from_millis(20),
            "begin_skip_transition #{i} blocked for {:?}",
            t_skip.elapsed()
        );
        let spec = spec_48(i);
        let dec = core_audio::player::open_decoder_for_source_spec(&spec, cancel.clone()).unwrap();
        player
            .start_opened_source_spec_with_metadata(&spec, dec, "Local", play_ep, cancel, None)
            .unwrap();
    }
    assert_eq!(
        player.output_reopen_count(),
        1,
        "Same-rate skips must hot-swap without reopening output (reopens={})",
        player.output_reopen_count()
    );

    // Part B: 30 rapid skips in < 3s across 44.1 / 48 / 96 kHz + stalled HTTP streams,
    // settling on Track #30 (96 kHz local lossless).
    let burst_start = Instant::now();
    let mut spawn_handles = Vec::new();
    let mut last_epoch = player.playback_epoch();

    for i in 1..=30usize {
        let t_click = Instant::now();
        let cancel = CancellationToken::new();
        let caller_epoch = 100 + i as u64;
        let play_ep = player
            .begin_skip_transition_with_epoch(caller_epoch, cancel.clone())
            .expect("monotonic caller_epoch must be accepted");
        let click_dur = t_click.elapsed();
        assert!(
            click_dur < Duration::from_millis(20),
            "Rapid skip click #{i} blocked control path for {:?}",
            click_dur
        );

        let cur_epoch = player.playback_epoch();
        assert!(
            cur_epoch > last_epoch,
            "playback_epoch must advance monotonically on every skip ({cur_epoch} <= {last_epoch})"
        );
        last_epoch = cur_epoch;
        assert_eq!(player.dual_deck_status().playback_epoch, cur_epoch);

        let p = player.clone();
        let spec = if i == 30 {
            StreamSourceSpec::LocalFile {
                key: StreamKey::new("local", "final-track-30-96k", "native"),
                path: wav_96k.to_string_lossy().to_string(),
                loudness: None,
                album_loudness: None,
            }
        } else {
            match i % 4 {
                0 => StreamSourceSpec::DirectRange {
                    key: StreamKey::new("youtube_music", format!("ytm-{i}"), "251"),
                    url: stalled_url.clone(),
                    headers: BTreeMap::new(),
                    content_length: Some(500_000),
                    bitrate_bps: Some(160_000),
                    hint_extension: Some("webm".to_string()),
                    mime_type: Some("audio/webm".to_string()),
                    expire_at: None,
                    init_range_end: None,
                    index_range_start: None,
                    index_range_end: None,
                    loudness: None,
                    album_loudness: None,
                },
                1 => StreamSourceSpec::LocalFile {
                    key: StreamKey::new("local", format!("track-44k-{i}"), "native"),
                    path: wav_44k.to_string_lossy().to_string(),
                    loudness: None,
                    album_loudness: None,
                },
                2 => StreamSourceSpec::LocalFile {
                    key: StreamKey::new("local", format!("track-48k-{i}"), "native"),
                    path: wav_48k.to_string_lossy().to_string(),
                    loudness: None,
                    album_loudness: None,
                },
                _ => StreamSourceSpec::LocalFile {
                    key: StreamKey::new("local", format!("track-96k-{i}"), "native"),
                    path: wav_96k.to_string_lossy().to_string(),
                    loudness: None,
                    album_loudness: None,
                },
            }
        };
        let meta = DeckTrackMetadata {
            track_id: format!("track-{i}"),
            title: format!("Track #{i}"),
            artist: "Rapid Skip Test".to_string(),
            album: "Stress".to_string(),
            duration_ms: 1500,
            ..Default::default()
        };

        spawn_handles.push(thread::spawn(move || {
            if let Ok(dec) = core_audio::player::open_decoder_for_source_spec(&spec, cancel.clone())
            {
                let _ = p.start_opened_source_spec_with_metadata(
                    &spec,
                    dec,
                    "Stress",
                    play_ep,
                    cancel,
                    Some(meta),
                );
            }
        }));

        // Small realistic rapid-click spacing (~15 ms -> 30 clicks in ~450 ms, well under 3s).
        if i < 30 {
            thread::sleep(Duration::from_millis(15));
        }
    }

    for h in spawn_handles {
        h.join().expect("worker task must exit without panic/hang");
    }
    assert!(
        burst_start.elapsed() < Duration::from_secs(3),
        "30 rapid skips + settle took {:?} (expected < 3s)",
        burst_start.elapsed()
    );

    // Wait briefly for settled Track #30 (96 kHz) to emit audible frames.
    let wait_play = Instant::now();
    while player.nonzero_output_frames() == 0 && wait_play.elapsed() < Duration::from_secs(2) {
        thread::sleep(Duration::from_millis(10));
    }

    assert_eq!(player.state_name(), "Playing");
    assert!(
        player.nonzero_output_frames() > 0,
        "Settled Track #30 must produce audible output frames"
    );
    let active_meta = player
        .active_track_metadata()
        .expect("Settled Track #30 metadata must be committed");
    assert_eq!(active_meta.track_id, "track-30");
    assert_eq!(
        player.active_meta().unwrap().format.sample_rate_hz,
        96_000,
        "Settled Track #30 must be 96 kHz"
    );
    assert!(player.playback_epoch() > initial_epoch + 30);
    assert!(
        player.playback_epoch() >= 130,
        "player.playback_epoch() must honor caller_epoch floor (>= 130), got {}",
        player.playback_epoch()
    );

    // Verify stop() is strictly non-blocking and all decode threads exit cleanly (zero leaks).
    let t_stop = Instant::now();
    player.stop();
    assert!(
        t_stop.elapsed() < Duration::from_millis(20),
        "stop() blocked caller for {:?}",
        t_stop.elapsed()
    );

    let t_drain = Instant::now();
    while player.active_decode_thread_count() > 0 && t_drain.elapsed() < Duration::from_secs(1) {
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        player.active_decode_thread_count(),
        0,
        "Zero leaked decode threads expected after stop()"
    );

    player.shutdown();
    stop_stall.store(true, Ordering::SeqCst);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_skip_to_standby_and_concurrent_auto_standby_no_abba_deadlock() {
    let player = AudioPlayer::new_headless();
    let s1 = StreamSource::synth("s1", "Track 1", 3_000);
    let s2 = StreamSource::synth("s2", "Track 2", 3_000);
    let s3 = StreamSource::synth("s3", "Track 3", 3_000);

    player.play_stream(s1, "Synth").unwrap();
    player.prepare_standby(s2, "Synth").unwrap();

    // Wait for standby to become ready.
    let t0 = Instant::now();
    while player.deck_state(player.standby_deck()) != core_types::DeckState::StandbyReady
        && t0.elapsed() < Duration::from_secs(2)
    {
        thread::sleep(Duration::from_millis(5));
    }

    // Queue next spec so relay_loop can fire TriggerAutoStandby concurrently with skip_to_standby.
    let tmp_dir = std::env::temp_dir().join(format!(
        "lumina_abba_test_{}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&tmp_dir);
    let wav_44k = tmp_dir.join("auto_next.wav");
    write_sine_wav(&wav_44k, 44_100, 1200);
    let auto_spec = StreamSourceSpec::LocalFile {
        key: StreamKey::new("local", "auto-next", "native"),
        path: wav_44k.to_string_lossy().to_string(),
        loudness: None,
        album_loudness: None,
    };
    player.queue_next_spec(auto_spec, Some("Local".to_string()));

    let epoch_before = player.playback_epoch();
    let skipped = player.skip_to_standby().unwrap();
    assert!(
        skipped,
        "skip_to_standby should succeed while TriggerAutoStandby runs without AB-BA deadlock"
    );
    assert!(
        player.playback_epoch() > epoch_before,
        "skip_to_standby must bump playback_epoch"
    );

    // Hammer concurrent skip_to_standby() + prepare_standby() across threads to verify zero deadlock.
    let stress_start = Instant::now();
    let p_skip = player.clone();
    let p_prep = player.clone();
    let h1 = thread::spawn(move || {
        for _ in 0..8 {
            let _ = p_skip.skip_to_standby();
            thread::sleep(Duration::from_millis(2));
        }
    });
    let h2 = thread::spawn(move || {
        for _ in 0..8 {
            let _ = p_prep.prepare_standby(s3.clone(), "Synth");
            thread::sleep(Duration::from_millis(2));
        }
    });
    h1.join().unwrap();
    h2.join().unwrap();
    assert!(
        stress_start.elapsed() < Duration::from_secs(3),
        "Concurrent skip_to_standby + prepare_standby must never deadlock"
    );

    player.shutdown();
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[cfg(target_os = "windows")]
mod wasapi_skip_silence_tests {
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, RwLock};
    use std::thread;
    use std::time::{Duration, Instant};

    use core_audio::backend::wasapi_win::{
        run_wasapi_render_loop, WasapiExclusiveOpenSpec, WasapiHotSwapPayload, WasapiRenderControl,
        WasapiStreamOps, Win32Event,
    };
    use core_audio::buffer::SpscRingBuffer;
    use core_audio::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};
    use core_types::{
        AudioCodec, ChannelLayout, DeviceTransportKind, Endianness, Interleaving, OutputMode,
        SampleFormatKind, UnifiedAudioFormat,
    };
    use windows::core::HRESULT;
    use windows::Win32::Media::Audio::AUDCLNT_BUFFERFLAGS_SILENT;

    #[derive(Default)]
    struct FakeOpsState {
        start_calls: u32,
        stop_calls: u32,
        reset_calls: u32,
        release_calls: Vec<(u32, u32)>,
        rendered_buffers: Vec<Vec<u8>>,
        padding_queue: VecDeque<u32>,
    }

    struct FakeOps {
        buf_event: Arc<Win32Event>,
        buf: Vec<u8>,
        state: Arc<Mutex<FakeOpsState>>,
        clock_pos: u64,
    }

    impl FakeOps {
        fn new(buf_event: Arc<Win32Event>, period_bytes: usize, state: Arc<Mutex<FakeOpsState>>) -> Self {
            Self {
                buf_event,
                buf: vec![0u8; period_bytes],
                state,
                clock_pos: 0,
            }
        }
    }

    impl WasapiStreamOps for FakeOps {
        fn start(&mut self) -> Result<(), HRESULT> {
            self.state.lock().unwrap().start_calls += 1;
            Ok(())
        }
        fn stop(&mut self) -> Result<(), HRESULT> {
            self.state.lock().unwrap().stop_calls += 1;
            Ok(())
        }
        fn reset(&mut self) -> Result<(), HRESULT> {
            self.state.lock().unwrap().reset_calls += 1;
            Ok(())
        }
        fn reset_buf_event(&mut self) {
            self.buf_event.reset();
        }
        fn current_padding(&mut self) -> Result<u32, HRESULT> {
            Ok(self.state.lock().unwrap().padding_queue.pop_front().unwrap_or(0))
        }
        fn get_buffer(&mut self, _num_frames: u32) -> Result<*mut u8, HRESULT> {
            Ok(self.buf.as_mut_ptr())
        }
        fn release_buffer(&mut self, num_frames_written: u32, flags: u32) -> Result<(), HRESULT> {
            self.clock_pos += num_frames_written as u64;
            let mut st = self.state.lock().unwrap();
            st.release_calls.push((num_frames_written, flags));
            if num_frames_written > 0 && flags == 0 {
                st.rendered_buffers.push(self.buf.clone());
            }
            Ok(())
        }
        fn clock_frequency(&mut self) -> Option<u64> {
            Some(48_000)
        }
        fn clock_position(&mut self) -> Result<(u64, u64), HRESULT> {
            Ok((self.clock_pos, 1))
        }
    }

    fn make_ver(sample_rate: u32) -> AudioVerificationEngine {
        AudioVerificationEngine::new(VerificationConfig {
            source_format: UnifiedAudioFormat {
                codec: AudioCodec::Flac,
                sample_rate,
                valid_bits: 16,
                container_bits: 16,
                channels: 2,
                channel_layout: ChannelLayout::Stereo,
                sample_format: SampleFormatKind::Int16,
                endianness: Endianness::Little,
                interleaving: Interleaving::Interleaved,
                dsd_rate: None,
            },
            output_mode: OutputMode::WasapiExclusive,
            transport: DeviceTransportKind::UsbDac,
            target_rate_hz: sample_rate,
            target_channels: 2,
            target_valid_bits: 16,
            target_container_bits: 16,
            buffer_size_frames: 64,
            dsp_active: false,
            software_volume_unity: true,
            resampled: false,
            exclusive_unavailable_reason: None,
        })
    }

    #[test]
    fn test_wasapi_skip_silence_pcm_full_period_and_lock_free_hot_swap() {
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let stop_event = Arc::new(Win32Event::new_manual_reset().unwrap());
        let wake_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let current_session_id = Arc::new(AtomicU64::new(1));
        let ctrl = Arc::new(
            WasapiRenderControl::new(
                Arc::clone(&buf_event),
                stop_event,
                wake_event,
                48_000,
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicI32::new(2)),
                Arc::new(AtomicBool::new(false)),
                Arc::new(RwLock::new(None)),
                1,
                Arc::clone(&current_session_id),
            )
            .with_wait_timeout_ms(20),
        );
        let spec = WasapiExclusiveOpenSpec {
            device_id: None,
            sample_rate: 48_000,
            channels: 2,
            layout: ChannelLayout::Stereo,
            wire_format: WireSampleFormat::Int16Le,
            is_dop: false,
            buffer_frames_hint: 64,
        };
        let (mut prod1, mut cons1) = SpscRingBuffer::<u8>::new(4096);
        prod1.push_slice(&[0x22u8; 512]); // 2 periods of Track 1

        let state = Arc::new(Mutex::new(FakeOpsState::default()));
        let mut ops = FakeOps::new(Arc::clone(&buf_event), 64 * 4, Arc::clone(&state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_ver(48_000);
            run_wasapi_render_loop(&mut ops, &spec, 64, &mut cons1, &ver, &ctrl_th);
        });

        let t0 = Instant::now();
        while state.lock().unwrap().start_calls < 1 && t0.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }

        // Enter skip-silence and advance current_session_id (like commit_opened_decoder does
        // before coordinator calls push_hot_swap): loop MUST stay alive and emit silent periods!
        ctrl.enter_skip_silence();
        current_session_id.store(2, Ordering::SeqCst);

        for _ in 0..8 {
            buf_event.signal();
            thread::sleep(Duration::from_millis(5));
        }
        assert!(
            !ctrl.stopped.load(Ordering::Acquire),
            "WASAPI render loop must stay alive during skip_silence"
        );
        assert_eq!(
            ctrl.underrun_count.load(Ordering::Acquire),
            0,
            "skip_silence must not record underruns"
        );
        {
            let st = state.lock().unwrap();
            assert_eq!(st.start_calls, 1, "must not reopen IAudioClient during skip");
            assert_eq!(st.stop_calls, 0);
            let silent_flag = AUDCLNT_BUFFERFLAGS_SILENT.0 as u32;
            assert!(
                st.release_calls
                    .iter()
                    .any(|&(frames, flags)| frames == 64 && flags == silent_flag),
                "PCM skip_silence must release full period (64 frames) with AUDCLNT_BUFFERFLAGS_SILENT; got {:?}",
                st.release_calls
            );
            assert!(
                st.release_calls.iter().all(|&(frames, _)| frames == 64),
                "All non-EOF periods must preserve full-period ReleaseBuffer(64, ...)"
            );
        }

        // Lock-free hot-swap onto Track 2 on the SAME IAudioClient loop!
        let (mut prod2, cons2) = SpscRingBuffer::<u8>::new(4096);
        prod2.push_slice(&[0x44u8; 256]); // 1 exact period of Track 2
        let eof2 = Arc::new(AtomicBool::new(true));
        let ver2 = make_ver(48_000);
        let tap2 = ver2.attach_rt_tap(WireSampleFormat::Int16Le, 2, 48_000, 65_536);

        assert!(
            ctrl.push_hot_swap(WasapiHotSwapPayload {
                consumer: cons2,
                ver_tap: tap2,
                watermark_bytes: 0,
                eof_flag: Arc::clone(&eof2),
                fade_ctrl: None,
                session_id: 2,
                expected_format_stamp: 0,
            }),
            "Hot-swap onto live WASAPI loop must succeed"
        );

        // Signal period for Track 2 data, then period for Track 2 EOF.
        buf_event.signal();
        thread::sleep(Duration::from_millis(15));
        buf_event.signal();
        th.join().expect("render thread exits cleanly on Track 2 EOF");

        let st = state.lock().unwrap();
        assert_eq!(st.start_calls, 1, "Hot-swap must reuse live IAudioClient (start_calls == 1)");
        assert!(
            st.rendered_buffers.iter().any(|b| b.iter().all(|&x| x == 0x44)),
            "Track 2 audio bytes (0x44) must render after lock-free hot-swap"
        );
        assert_eq!(
            st.release_calls.last().copied(),
            Some((0, 0)),
            "Existing EOF-empty ReleaseBuffer(0, 0) invariant must remain intact"
        );
    }

    #[test]
    fn test_wasapi_skip_silence_dop_preserves_wire_markers() {
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let stop_event = Arc::new(Win32Event::new_manual_reset().unwrap());
        let wake_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl = Arc::new(
            WasapiRenderControl::new(
                Arc::clone(&buf_event),
                stop_event,
                wake_event,
                176_400,
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicI32::new(2)),
                Arc::new(AtomicBool::new(false)),
                Arc::new(RwLock::new(None)),
                1,
                Arc::new(AtomicU64::new(1)),
            )
            .with_wait_timeout_ms(20),
        );
        let spec = WasapiExclusiveOpenSpec {
            device_id: None,
            sample_rate: 176_400,
            channels: 2,
            layout: ChannelLayout::Stereo,
            wire_format: WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: false,
            },
            is_dop: true,
            buffer_frames_hint: 4,
        };
        let (_prod, mut cons) = SpscRingBuffer::<u8>::new(1024);
        let state = Arc::new(Mutex::new(FakeOpsState::default()));
        let mut ops = FakeOps::new(Arc::clone(&buf_event), 4 * 8, Arc::clone(&state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_ver(176_400);
            run_wasapi_render_loop(&mut ops, &spec, 4, &mut cons, &ver, &ctrl_th);
        });

        let t0 = Instant::now();
        while state.lock().unwrap().start_calls < 1 && t0.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }

        ctrl.enter_skip_silence();
        buf_event.signal();
        thread::sleep(Duration::from_millis(15));
        ctrl.stopped.store(true, Ordering::SeqCst);
        ctrl.stop_event.signal();
        th.join().unwrap();

        let st = state.lock().unwrap();
        assert!(
            st.release_calls.iter().all(|&(frames, flags)| frames == 4 && flags == 0),
            "DoP skip_silence must release full period with flags=0 (wire silence, never AUDCLNT_BUFFERFLAGS_SILENT); got {:?}",
            st.release_calls
        );
        assert!(st.rendered_buffers.len() >= 2);
        let skip_buf = st.rendered_buffers.last().unwrap();
        assert_eq!(&skip_buf[0..8], &[0x00, 0x69, 0x69, 0x05, 0x00, 0x69, 0x69, 0x05]);
        assert_eq!(&skip_buf[8..16], &[0x00, 0x69, 0x69, 0xFA, 0x00, 0x69, 0x69, 0xFA]);
    }

    #[test]
    fn test_wasapi_hot_swap_skip_silence_no_clobber_and_paused_reset() {
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let stop_event = Arc::new(Win32Event::new_manual_reset().unwrap());
        let wake_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let current_session_id = Arc::new(AtomicU64::new(1));
        let ctrl = Arc::new(
            WasapiRenderControl::new(
                Arc::clone(&buf_event),
                stop_event,
                wake_event,
                48_000,
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicI32::new(2)),
                Arc::new(AtomicBool::new(false)),
                Arc::new(RwLock::new(None)),
                1,
                Arc::clone(&current_session_id),
            )
            .with_wait_timeout_ms(15),
        );
        let spec = WasapiExclusiveOpenSpec {
            device_id: None,
            sample_rate: 48_000,
            channels: 2,
            layout: ChannelLayout::Stereo,
            wire_format: WireSampleFormat::Int16Le,
            is_dop: false,
            buffer_frames_hint: 64,
        };
        let (mut prod1, mut cons1) = SpscRingBuffer::<u8>::new(4096);
        prod1.push_slice(&[0x11u8; 512]);
        let state = Arc::new(Mutex::new(FakeOpsState::default()));
        let mut ops = FakeOps::new(Arc::clone(&buf_event), 64 * 4, Arc::clone(&state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_ver(48_000);
            run_wasapi_render_loop(&mut ops, &spec, 64, &mut cons1, &ver, &ctrl_th);
        });

        let t0 = Instant::now();
        while state.lock().unwrap().start_calls < 1 && t0.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }

        // 1. Skip-silence clobber test: enter_skip_silence() + newer session_id=3 arrives
        // BEFORE RT adopts stale hot-swap for session_id=2. `skip_silence` must stay true
        // and the render loop must stay alive (never exit on session mismatch!).
        ctrl.enter_skip_silence();
        current_session_id.store(3, Ordering::SeqCst);
        let (_prod2, cons2) = SpscRingBuffer::<u8>::new(4096);
        let ver2 = make_ver(48_000);
        let tap2 = ver2.attach_rt_tap(WireSampleFormat::Int16Le, 2, 48_000, 65_536);
        assert!(ctrl.push_hot_swap(WasapiHotSwapPayload {
            consumer: cons2,
            ver_tap: tap2,
            watermark_bytes: 0,
            eof_flag: Arc::new(AtomicBool::new(false)),
            fade_ctrl: None,
            session_id: 2,
            expected_format_stamp: 0,
        }));
        for _ in 0..4 {
            buf_event.signal();
            thread::sleep(Duration::from_millis(5));
        }
        assert!(
            ctrl.is_skip_silence(),
            "stale session_id=2 hot-swap must NOT clobber newer skip_silence (current_session_id=3)"
        );
        assert!(
            !ctrl.is_loop_exited() && !ctrl.stopped.load(Ordering::Acquire),
            "render loop must stay alive in skip_silence"
        );

        // 2. Paused hot-swap test: pause the stream, push session_id=3 hot-swap, then resume.
        // Adopting while paused must call ops.reset() and re-prime Track 3 cleanly on resume.
        ctrl.set_paused(true);
        let t_pause = Instant::now();
        while state.lock().unwrap().stop_calls < 1 && t_pause.elapsed() < Duration::from_millis(500)
        {
            thread::sleep(Duration::from_millis(2));
        }
        let resets_before = state.lock().unwrap().reset_calls;

        let (mut prod3, cons3) = SpscRingBuffer::<u8>::new(4096);
        prod3.push_slice(&[0x55u8; 256]);
        let ver3 = make_ver(48_000);
        let tap3 = ver3.attach_rt_tap(WireSampleFormat::Int16Le, 2, 48_000, 65_536);
        assert!(ctrl.push_hot_swap(WasapiHotSwapPayload {
            consumer: cons3,
            ver_tap: tap3,
            watermark_bytes: 0,
            eof_flag: Arc::new(AtomicBool::new(true)),
            fade_ctrl: None,
            session_id: 3,
            expected_format_stamp: 0,
        }));

        let t_reset = Instant::now();
        while state.lock().unwrap().reset_calls <= resets_before
            && t_reset.elapsed() < Duration::from_millis(500)
        {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(
            state.lock().unwrap().reset_calls > resets_before,
            "adopting hot-swap while paused must reset stale hardware buffer"
        );

        ctrl.set_paused(false);
        thread::sleep(Duration::from_millis(20));
        buf_event.signal();
        th.join().expect("render thread exits cleanly on Track 3 EOF");

        let st = state.lock().unwrap();
        assert!(
            st.rendered_buffers.iter().any(|b| b.iter().all(|&x| x == 0x55)),
            "Track 3 audio (0x55) must be primed cleanly on resume after paused hot-swap"
        );
    }

    #[test]
    fn test_wasapi_hot_swap_eof_toctou_returns_err_when_loop_exited() {
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let stop_event = Arc::new(Win32Event::new_manual_reset().unwrap());
        let wake_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let eof1 = Arc::new(AtomicBool::new(true));
        let ctrl = Arc::new(
            WasapiRenderControl::new(
                Arc::clone(&buf_event),
                stop_event,
                wake_event,
                48_000,
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicU64::new(0)),
                Arc::new(AtomicI32::new(2)),
                Arc::clone(&eof1),
                Arc::new(RwLock::new(None)),
                1,
                Arc::new(AtomicU64::new(1)),
            )
            .with_wait_timeout_ms(15),
        );
        let spec = WasapiExclusiveOpenSpec {
            device_id: None,
            sample_rate: 48_000,
            channels: 2,
            layout: ChannelLayout::Stereo,
            wire_format: WireSampleFormat::Int16Le,
            is_dop: false,
            buffer_frames_hint: 64,
        };
        let (_prod1, mut cons1) = SpscRingBuffer::<u8>::new(4096);
        let state = Arc::new(Mutex::new(FakeOpsState::default()));
        let mut ops = FakeOps::new(Arc::clone(&buf_event), 64 * 4, Arc::clone(&state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_ver(48_000);
            run_wasapi_render_loop(&mut ops, &spec, 64, &mut cons1, &ver, &ctrl_th);
        });
        buf_event.signal();
        th.join().expect("render thread exits on empty EOF");
        assert!(ctrl.is_loop_exited());

        let (_prod2, cons2) = SpscRingBuffer::<u8>::new(4096);
        let ver2 = make_ver(48_000);
        let tap2 = ver2.attach_rt_tap(WireSampleFormat::Int16Le, 2, 48_000, 65_536);
        let res = ctrl.try_push_hot_swap(WasapiHotSwapPayload {
            consumer: cons2,
            ver_tap: tap2,
            watermark_bytes: 0,
            eof_flag: Arc::new(AtomicBool::new(false)),
            fade_ctrl: None,
            session_id: 2,
            expected_format_stamp: 0,
        });
        assert!(
            res.is_err(),
            "try_push_hot_swap must return Err when render loop already exited on EOF so caller reopens IAudioClient"
        );
    }
}
