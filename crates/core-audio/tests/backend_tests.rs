use core_audio::backend::{
    asio::AsioBackend, mock::MockBackend, wasapi::WasapiBackend, AudioOutputBackend, BackendConfig,
    BackendState,
};
use core_types::{AudioCodec, AudioFormat, OutputBackendKind};

#[test]
fn test_mock_backend_lifecycle_and_recording() {
    let mut backend = MockBackend::new("Test DAC", OutputBackendKind::WindowsAsio);
    assert_eq!(backend.state(), BackendState::Uninitialized);

    let format = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let config = BackendConfig::new(format.clone(), 256).unwrap();

    // Open
    backend.open(&config).expect("Open failed");
    assert_eq!(backend.state(), BackendState::Ready);
    assert_eq!(backend.latency_frames(), 256);

    // Start
    backend.start().expect("Start failed");
    assert_eq!(backend.state(), BackendState::Playing);

    // Write samples
    let test_samples: Vec<f64> = vec![0.1, -0.1, 0.5, -0.5, 0.9, -0.9];
    let written = backend.write_interleaved_f64(&test_samples).unwrap();
    assert_eq!(written, 3); // 6 samples / 2 channels = 3 frames
    assert_eq!(backend.frames_written(), 3);

    // Verify recorded samples
    backend.assert_exact_f64(&test_samples, 1e-9);

    // Pause & Resume
    backend.pause().expect("Pause failed");
    assert_eq!(backend.state(), BackendState::Paused);

    // Writing while paused should fail with InvalidState
    assert!(backend.write_interleaved_f64(&test_samples).is_err());

    backend.resume().expect("Resume failed");
    assert_eq!(backend.state(), BackendState::Playing);

    // Stop & Close
    backend.stop().expect("Stop failed");
    assert_eq!(backend.state(), BackendState::Stopped);

    backend.close().expect("Close failed");
    assert_eq!(backend.state(), BackendState::Uninitialized);
}

#[test]
fn test_mock_backend_buffer_size_validation_and_underflow() {
    let mut backend = MockBackend::new("Test DAC", OutputBackendKind::WindowsAsio);
    let format = AudioFormat::pcm(AudioCodec::Wav, 48000, 16, 2).unwrap();

    // Valid sizes: 32, 64, 128, 256, 512, 1024, 2048, 4096
    assert!(BackendConfig::new(format.clone(), 32).is_ok());
    assert!(BackendConfig::new(format.clone(), 512).is_ok());
    assert!(BackendConfig::new(format.clone(), 4096).is_ok());

    // Invalid sizes: not power of two or out of range
    assert!(BackendConfig::new(format.clone(), 100).is_err());
    assert!(BackendConfig::new(format.clone(), 16).is_err());
    assert!(BackendConfig::new(format.clone(), 8192).is_err());

    // Underflow simulation
    assert_eq!(backend.underflow_count(), 0);
    backend.simulate_underflow(3);
    assert_eq!(backend.underflow_count(), 3);
}

#[test]
fn test_mock_backend_fault_injection() {
    let mut backend = MockBackend::new("Fault DAC", OutputBackendKind::WindowsAsio);
    let format = AudioFormat::pcm(AudioCodec::Wav, 48000, 16, 2).unwrap();
    let config = BackendConfig::new(format, 128).unwrap();

    // 1. Fail on open
    backend.set_fail_on_open(true);
    assert!(backend.open(&config).is_err());
    assert_eq!(backend.state(), BackendState::Error);

    // Reset
    backend.set_fail_on_open(false);
    backend.open(&config).unwrap();

    // 2. Fail on start
    backend.set_fail_on_start(true);
    assert!(backend.start().is_err());
    assert_eq!(backend.state(), BackendState::Error);
}

#[test]
fn test_asio_backend_stride_and_device_properties() {
    let asio = AsioBackend::new("RME Fireface ASIO");
    let dev = asio.current_device().unwrap();
    assert_eq!(dev.backend, OutputBackendKind::WindowsAsio);
    assert!(dev.is_exclusive);
    assert!(dev.supports_native_dsd);

    // 256 frames * 2 channels * 4 bytes (24-in-32 container) = 2048 bytes
    let stride = AsioBackend::calculate_buffer_stride(256, 2, 4);
    assert_eq!(stride, 2048);
}

#[test]
fn test_wasapi_backend_device_properties() {
    let wasapi = WasapiBackend::new();
    let dev = wasapi.current_device().unwrap();
    assert_eq!(dev.backend, OutputBackendKind::WindowsWasapiExclusive);
    assert!(dev.is_exclusive);
}

#[cfg(target_os = "windows")]
mod windows_backend_tests {
    use std::collections::VecDeque;
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, RwLock};
    use std::thread;
    use std::time::{Duration, Instant};

    use core_audio::backend::asio_win::{
        asio_silence_byte, fill_asio_buffer_silence, AsioCallbackSignals, AsioRenderCore,
        AsioSamples, AsioTimeStamp, ASIO_OK, ASIO_ST_DSD_INT8_LSB8, ASIO_ST_INT32_LSB,
        K_ASIO_BUFFER_SIZE_CHANGE, K_ASIO_ENGINE_VERSION, K_ASIO_LATENCIES_CHANGED,
        K_ASIO_RESET_REQUEST, K_ASIO_RESYNC_REQUEST, K_ASIO_SELECTOR_SUPPORTED,
        K_ASIO_SUPPORTS_TIME_CODE, K_ASIO_SUPPORTS_TIME_INFO,
    };
    use core_audio::backend::wasapi_win::{
        fill_wasapi_wire_silence, probe_wasapi_endpoints, run_wasapi_render_loop,
        WasapiClockState, WasapiExclusiveOpenSpec, WasapiExclusiveSession, WasapiRenderControl,
        WasapiStreamOps, Win32Event,
    };
    use core_audio::buffer::SpscRingBuffer;
    use core_audio::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};
    use core_types::{
        AudioFormat, ChannelLayout, DeviceTransportKind, OutputMode, UnifiedAudioFormat,
    };
    use windows::core::HRESULT;
    use windows::Win32::Media::Audio::AUDCLNT_E_DEVICE_INVALIDATED;

    fn make_test_verification() -> AudioVerificationEngine {
        AudioVerificationEngine::new(VerificationConfig {
            source_format: UnifiedAudioFormat::from_audio_format(&AudioFormat::cd_quality()),
            output_mode: OutputMode::WasapiExclusive,
            transport: DeviceTransportKind::Virtual,
            target_rate_hz: 48_000,
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

    #[derive(Default)]
    struct FakeWasapiState {
        start_calls: u32,
        stop_calls: u32,
        reset_calls: u32,
        reset_event_calls: u32,
        release_calls: Vec<u32>,
        rendered_buffers: Vec<Vec<u8>>,
        padding_queue: VecDeque<u32>,
        sticky_padding: Option<u32>,
        clock_freq: u64,
        clock_positions: VecDeque<(u64, u64)>,
        fail_start_hr: Option<HRESULT>,
        fail_stop_hr: Option<HRESULT>,
        fail_reset_hr: Option<HRESULT>,
        fail_padding_hr: Option<HRESULT>,
        fail_get_buffer_hr: Option<HRESULT>,
        fail_release_hr: Option<HRESULT>,
    }

    struct FakeWasapiOps {
        buf_event: Arc<Win32Event>,
        buffer_bytes: usize,
        staging: Vec<u8>,
        state: Arc<Mutex<FakeWasapiState>>,
    }

    impl FakeWasapiOps {
        fn new(buf_event: Arc<Win32Event>, buffer_bytes: usize, state: Arc<Mutex<FakeWasapiState>>) -> Self {
            Self {
                buf_event,
                buffer_bytes,
                staging: vec![0u8; buffer_bytes],
                state,
            }
        }
    }

    impl WasapiStreamOps for FakeWasapiOps {
        fn start(&mut self) -> Result<(), HRESULT> {
            let mut st = self.state.lock().unwrap();
            st.start_calls += 1;
            if let Some(hr) = st.fail_start_hr.take() {
                return Err(hr);
            }
            Ok(())
        }

        fn stop(&mut self) -> Result<(), HRESULT> {
            let mut st = self.state.lock().unwrap();
            st.stop_calls += 1;
            if let Some(hr) = st.fail_stop_hr.take() {
                return Err(hr);
            }
            Ok(())
        }

        fn reset(&mut self) -> Result<(), HRESULT> {
            let mut st = self.state.lock().unwrap();
            st.reset_calls += 1;
            if let Some(hr) = st.fail_reset_hr.take() {
                return Err(hr);
            }
            Ok(())
        }

        fn reset_buf_event(&mut self) {
            self.buf_event.reset();
            self.state.lock().unwrap().reset_event_calls += 1;
        }

        fn current_padding(&mut self) -> Result<u32, HRESULT> {
            let mut st = self.state.lock().unwrap();
            if let Some(hr) = st.fail_padding_hr.take() {
                return Err(hr);
            }
            if let Some(p) = st.padding_queue.pop_front() {
                Ok(p)
            } else {
                Ok(st.sticky_padding.unwrap_or(0))
            }
        }

        fn get_buffer(&mut self, num_frames: u32) -> Result<*mut u8, HRESULT> {
            let mut st = self.state.lock().unwrap();
            if let Some(hr) = st.fail_get_buffer_hr.take() {
                return Err(hr);
            }
            let _ = num_frames;
            if self.staging.len() < self.buffer_bytes {
                self.staging.resize(self.buffer_bytes, 0);
            }
            Ok(self.staging.as_mut_ptr())
        }

        fn release_buffer(&mut self, num_frames_written: u32, _flags: u32) -> Result<(), HRESULT> {
            let mut st = self.state.lock().unwrap();
            st.release_calls.push(num_frames_written);
            if let Some(hr) = st.fail_release_hr.take() {
                return Err(hr);
            }
            if num_frames_written > 0 {
                st.rendered_buffers.push(self.staging[..self.buffer_bytes].to_vec());
            }
            Ok(())
        }

        fn clock_frequency(&mut self) -> Option<u64> {
            let f = self.state.lock().unwrap().clock_freq;
            if f > 0 { Some(f) } else { None }
        }

        fn clock_position(&mut self) -> Result<(u64, u64), HRESULT> {
            let mut st = self.state.lock().unwrap();
            if let Some(pair) = st.clock_positions.pop_front() {
                Ok(pair)
            } else {
                Err(HRESULT(-1))
            }
        }
    }

    fn make_pcm16_spec(frames: u32) -> WasapiExclusiveOpenSpec {
        WasapiExclusiveOpenSpec {
            device_id: None,
            sample_rate: 48_000,
            channels: 2,
            layout: ChannelLayout::Stereo,
            wire_format: WireSampleFormat::Int16Le,
            is_dop: false,
            buffer_frames_hint: frames,
        }
    }

    fn make_ctrl(
        buf_event: Arc<Win32Event>,
        sample_rate: u32,
        state_code: i32,
    ) -> Arc<WasapiRenderControl> {
        Arc::new(WasapiRenderControl::new(
            buf_event,
            Arc::new(Win32Event::new_manual_reset().unwrap()),
            Arc::new(Win32Event::new_auto_reset().unwrap()),
            sample_rate,
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicI32::new(state_code)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(RwLock::new(None)),
            1,
            Arc::new(AtomicU64::new(1)),
        ))
    }

    #[test]
    fn test_wasapi_pause_resume_wake_no_deadlock() {
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl = make_ctrl(Arc::clone(&buf_event), 48_000, 2);
        let spec = make_pcm16_spec(64);
        let (mut prod, mut cons) = SpscRingBuffer::<u8>::new(4096);
        prod.push_slice(&vec![0x11u8; 64 * 4 * 4]);

        let fake_state = Arc::new(Mutex::new(FakeWasapiState::default()));
        let mut ops = FakeWasapiOps::new(Arc::clone(&buf_event), 64 * 4, Arc::clone(&fake_state));
        let ctrl_th = Arc::clone(&ctrl);
        let spec_th = spec.clone();

        let th = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops, &spec_th, 64, &mut cons, &ver, &ctrl_th);
        });

        // Initial start.
        let deadline = Instant::now() + Duration::from_secs(1);
        while fake_state.lock().unwrap().start_calls < 1 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(fake_state.lock().unwrap().start_calls, 1);

        // Pause: must wake immediately via wake_event and call Stop() (without buf_event!).
        ctrl.set_paused(true);
        let pause_start = Instant::now();
        while fake_state.lock().unwrap().stop_calls < 1
            && pause_start.elapsed() < Duration::from_millis(500)
        {
            thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(fake_state.lock().unwrap().stop_calls, 1);

        // Remain paused with NO buf_event signals (simulating stopped WASAPI client).
        thread::sleep(Duration::from_millis(40));
        assert_eq!(fake_state.lock().unwrap().start_calls, 1);

        // Resume: must wake via wake_event in < 50ms (would deadlock in old WAIT_TIMEOUT loop!)
        let resume_t0 = Instant::now();
        ctrl.set_paused(false);
        while fake_state.lock().unwrap().start_calls < 2
            && resume_t0.elapsed() < Duration::from_millis(500)
        {
            thread::sleep(Duration::from_millis(1));
        }
        let wake_elapsed = resume_t0.elapsed();
        assert_eq!(fake_state.lock().unwrap().start_calls, 2);
        assert!(
            wake_elapsed < Duration::from_millis(50),
            "Resume took {wake_elapsed:?}, expected < 50ms"
        );

        ctrl.stopped.store(true, Ordering::SeqCst);
        ctrl.stop_event.signal();
        th.join().unwrap();
    }

    #[test]
    fn test_wasapi_post_seek_flush_playing_and_paused() {
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl = make_ctrl(Arc::clone(&buf_event), 48_000, 2);
        let spec = make_pcm16_spec(32); // 128 bytes per period
        let (mut prod, mut cons) = SpscRingBuffer::<u8>::new(4096);
        let ring_ctrl = prod.control();

        // Pre-seek audio: 0x11 bytes across multiple periods.
        prod.push_slice(&[0x11u8; 128 * 4]);

        let fake_state = Arc::new(Mutex::new(FakeWasapiState {
            clock_freq: 48_000,
            clock_positions: VecDeque::from([(100, 1000), (200, 2000), (32, 3000)]),
            ..Default::default()
        }));
        let mut ops = FakeWasapiOps::new(Arc::clone(&buf_event), 128, Arc::clone(&fake_state));
        let ctrl_th = Arc::clone(&ctrl);
        let spec_th = spec.clone();

        let th = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops, &spec_th, 32, &mut cons, &ver, &ctrl_th);
        });

        // Drive one buffer event so clock becomes valid at pos=100.
        thread::sleep(Duration::from_millis(10));
        buf_event.signal();
        let wait_t = Instant::now();
        while ctrl.clock_snapshot().is_none() && wait_t.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(ctrl.clock_snapshot().unwrap().clock_epoch, 0);

        // Seek while playing: bump ring epoch, push post-seek 0x22 bytes, flush WASAPI.
        ring_ctrl.request_flush();
        assert_eq!(prod.sync_epoch(), 1);
        prod.push_slice(&[0x22u8; 128 * 2]);

        ctrl.flush().expect("Playing flush failed");
        {
            let st = fake_state.lock().unwrap();
            assert!(st.stop_calls >= 1);
            assert_eq!(st.reset_calls, 1);
            assert_eq!(st.reset_event_calls, 1);
            assert_eq!(st.start_calls, 2);
            // The post-flush primed buffer (last rendered) must contain ONLY 0x22 (no 0x11!).
            let last = st.rendered_buffers.last().unwrap();
            assert!(last.iter().all(|&b| b == 0x22), "Stale pre-seek bytes leaked into primed buffer");
        }
        assert_eq!(ctrl.clock_snapshot().unwrap().clock_epoch, 1);
        assert_eq!(ctrl.clock_snapshot().unwrap().position, 0);

        // Now test seek while PAUSED: pause -> push stale 0x44 -> flush -> stays stopped -> push 0x33 -> resume.
        ctrl.set_paused(true);
        let t_pause = Instant::now();
        while fake_state.lock().unwrap().stop_calls < 2 && t_pause.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }
        prod.push_slice(&[0x44u8; 128 * 2]);
        ring_ctrl.request_flush();
        assert_eq!(prod.sync_epoch(), 2);
        ctrl.flush().expect("Paused flush failed");
        assert_eq!(fake_state.lock().unwrap().reset_calls, 2);
        // Must NOT call Start() while still paused!
        assert_eq!(fake_state.lock().unwrap().start_calls, 2);

        // Push post-seek 0x33 bytes and resume -> prime + Start() must render ONLY 0x33.
        prod.push_slice(&[0x33u8; 128]);
        ctrl.set_paused(false);
        let t_res = Instant::now();
        while fake_state.lock().unwrap().start_calls < 3 && t_res.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }
        {
            let st = fake_state.lock().unwrap();
            let last = st.rendered_buffers.last().unwrap();
            assert!(last.iter().all(|&b| b == 0x33), "Paused-seek resume leaked stale bytes");
        }

        ctrl.stopped.store(true, Ordering::SeqCst);
        ctrl.stop_event.signal();
        th.join().unwrap();
    }

    #[test]
    fn test_wasapi_dop_and_native_dsd_silence_priming() {
        // 1. Direct fill_wasapi_wire_silence checks
        let mut dsd_buf = [0u8; 16];
        let mut phase = false;
        fill_wasapi_wire_silence(&mut dsd_buf, WireSampleFormat::NativeDsd { channels: 2 }, 2, &mut phase);
        assert!(dsd_buf.iter().all(|&b| b == 0x69));

        // 2 frames stereo DoP = 2 * 2 * 4 = 16 bytes
        let mut dop_buf = [0u8; 16];
        phase = false;
        fill_wasapi_wire_silence(
            &mut dop_buf,
            WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: false,
            },
            2,
            &mut phase,
        );
        // Frame 0: L=[0x00, 0x69, 0x69, 0x05], R=[0x00, 0x69, 0x69, 0x05]
        // Frame 1: L=[0x00, 0x69, 0x69, 0xFA], R=[0x00, 0x69, 0x69, 0xFA]
        assert_eq!(&dop_buf[0..8], &[0x00, 0x69, 0x69, 0x05, 0x00, 0x69, 0x69, 0x05]);
        assert_eq!(&dop_buf[8..16], &[0x00, 0x69, 0x69, 0xFA, 0x00, 0x69, 0x69, 0xFA]);
        assert!(!phase);

        // 2. Through run_wasapi_render_loop underrun/priming in DoP mode.
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl = make_ctrl(Arc::clone(&buf_event), 176_400, 2);
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
        let fake_state = Arc::new(Mutex::new(FakeWasapiState::default()));
        let mut ops = FakeWasapiOps::new(Arc::clone(&buf_event), 4 * 8, Arc::clone(&fake_state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops, &spec, 4, &mut cons, &ver, &ctrl_th);
        });

        let t0 = Instant::now();
        while fake_state.lock().unwrap().rendered_buffers.is_empty() && t0.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }
        {
            let st = fake_state.lock().unwrap();
            let primed = &st.rendered_buffers[0];
            assert_eq!(primed.len(), 32);
            assert_eq!(&primed[0..8], &[0x00, 0x69, 0x69, 0x05, 0x00, 0x69, 0x69, 0x05]);
            assert_eq!(&primed[8..16], &[0x00, 0x69, 0x69, 0xFA, 0x00, 0x69, 0x69, 0xFA]);
        }

        ctrl.stopped.store(true, Ordering::SeqCst);
        ctrl.stop_event.signal();
        th.join().unwrap();
    }

    #[test]
    fn test_wasapi_eof_padding_drain_and_bounded_timeout() {
        // Case 1: Padding drains 256 -> 128 -> 0 before transitioning Playing (2) -> Ended (8).
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl = make_ctrl(Arc::clone(&buf_event), 48_000, 2);
        ctrl.set_eof_state_code(8);
        let spec = make_pcm16_spec(64);
        let (mut prod, mut cons) = SpscRingBuffer::<u8>::new(1024);
        // Prime takes 1 period (256 bytes); leave empty for the next event.
        prod.push_slice(&[0x55u8; 256]);
        ctrl.eof_flag.store(true, Ordering::SeqCst);

        let fake_state = Arc::new(Mutex::new(FakeWasapiState {
            padding_queue: VecDeque::from([256, 128, 0]),
            ..Default::default()
        }));
        let mut ops = FakeWasapiOps::new(Arc::clone(&buf_event), 256, Arc::clone(&fake_state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops, &spec, 64, &mut cons, &ver, &ctrl_th);
        });

        let t0 = Instant::now();
        while fake_state.lock().unwrap().start_calls < 1 && t0.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }
        buf_event.signal();
        th.join().unwrap();

        assert!(ctrl.is_eof_drained());
        assert_eq!(ctrl.state_code.load(Ordering::Acquire), 8);
        // ReleaseBuffer(0, 0) must have been called on EOF instead of an extra silence period.
        let rel = &fake_state.lock().unwrap().release_calls;
        assert_eq!(rel.as_slice(), &[64, 0]);

        // Case 2: Stuck hardware padding (never returns 0) must exit cleanly via bounded timeout.
        let buf_event2 = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl2 = make_ctrl(Arc::clone(&buf_event2), 48_000, 2);
        let spec2 = make_pcm16_spec(64);
        let (_prod2, mut cons2) = SpscRingBuffer::<u8>::new(1024);
        ctrl2.eof_flag.store(true, Ordering::SeqCst);

        let fake_state2 = Arc::new(Mutex::new(FakeWasapiState {
            sticky_padding: Some(64),
            ..Default::default()
        }));
        let mut ops2 = FakeWasapiOps::new(Arc::clone(&buf_event2), 256, Arc::clone(&fake_state2));
        let ctrl2_th = Arc::clone(&ctrl2);

        let t_start = Instant::now();
        let th2 = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops2, &spec2, 64, &mut cons2, &ver, &ctrl2_th);
        });
        thread::sleep(Duration::from_millis(10));
        buf_event2.signal();
        th2.join().unwrap();
        assert!(t_start.elapsed() < Duration::from_secs(1));
        assert!(ctrl2.is_eof_drained());
        assert_eq!(ctrl2.state_code.load(Ordering::Acquire), 1);
    }

    #[test]
    fn test_wasapi_clock_math_monotonicity_and_reset_epoch() {
        let clock = WasapiClockState::new(96_000);
        assert!(clock.snapshot().is_none());

        // Hardware reports byte frequency 768_000 (96kHz * 2ch * 4B) while sample_rate is 96_000.
        clock.set_frequency(768_000);
        clock.record_position(384_000, 5_000_000);

        let snap = clock.snapshot().unwrap();
        assert_eq!(snap.position, 384_000);
        assert_eq!(snap.frequency, 768_000);
        assert_eq!(snap.clock_epoch, 0);
        assert_eq!(clock.hardware_position_frames(), Some(48_000));
        assert_eq!(clock.clock_position_ns(), Some(500_000_000));

        // Backward driver jitter within same epoch must be clamped monotonically.
        clock.record_position(300_000, 5_100_000);
        assert_eq!(clock.snapshot().unwrap().position, 384_000);

        // Reset bumps epoch and resets raw position to 0.
        clock.on_reset();
        let snap2 = clock.snapshot().unwrap();
        assert_eq!(snap2.clock_epoch, 1);
        assert_eq!(snap2.position, 0);
        assert_eq!(clock.hardware_position_frames(), Some(0));

        clock.record_position(76_800, 6_000_000);
        assert_eq!(clock.hardware_position_frames(), Some(9_600));
    }

    #[test]
    fn test_wasapi_device_invalidation_and_flush_unblock() {
        // Test 1: Invalidation on GetBuffer marks device_lost & state=4.
        let buf_event = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl = make_ctrl(Arc::clone(&buf_event), 48_000, 2);
        let spec = make_pcm16_spec(64);
        let (mut prod, mut cons) = SpscRingBuffer::<u8>::new(1024);
        prod.push_slice(&[0x11u8; 512]);

        let fake_state = Arc::new(Mutex::new(FakeWasapiState::default()));
        let mut ops = FakeWasapiOps::new(Arc::clone(&buf_event), 256, Arc::clone(&fake_state));
        let ctrl_th = Arc::clone(&ctrl);

        let th = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops, &spec, 64, &mut cons, &ver, &ctrl_th);
        });

        let t0 = Instant::now();
        while fake_state.lock().unwrap().start_calls < 1 && t0.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }

        // Inject AUDCLNT_E_DEVICE_INVALIDATED on Reset so a concurrent flush() returns Err without hanging!
        fake_state.lock().unwrap().fail_reset_hr = Some(AUDCLNT_E_DEVICE_INVALIDATED);
        let flush_res = ctrl.flush();
        assert!(flush_res.is_err(), "Flush must return Err on AUDCLNT_E_DEVICE_INVALIDATED");
        th.join().unwrap();

        assert!(ctrl.is_device_lost());
        assert_eq!(ctrl.state_code.load(Ordering::Acquire), 4);
        assert!(ctrl.last_error.read().unwrap().is_some());

        // Test 2: Invalidation on GetBuffer during playback.
        let buf_event2 = Arc::new(Win32Event::new_auto_reset().unwrap());
        let ctrl2 = make_ctrl(Arc::clone(&buf_event2), 48_000, 2);
        let spec2 = make_pcm16_spec(64);
        let (_prod2, mut cons2) = SpscRingBuffer::<u8>::new(1024);
        let fake_state2 = Arc::new(Mutex::new(FakeWasapiState::default()));
        let mut ops2 = FakeWasapiOps::new(Arc::clone(&buf_event2), 256, Arc::clone(&fake_state2));
        let ctrl2_th = Arc::clone(&ctrl2);

        let th2 = thread::spawn(move || {
            let ver = make_test_verification();
            run_wasapi_render_loop(&mut ops2, &spec2, 64, &mut cons2, &ver, &ctrl2_th);
        });
        let t1 = Instant::now();
        while fake_state2.lock().unwrap().start_calls < 1 && t1.elapsed() < Duration::from_millis(500) {
            thread::sleep(Duration::from_millis(2));
        }
        fake_state2.lock().unwrap().fail_get_buffer_hr = Some(AUDCLNT_E_DEVICE_INVALIDATED);
        buf_event2.signal();
        th2.join().unwrap();
        assert!(ctrl2.is_device_lost());
        assert_eq!(ctrl2.state_code.load(Ordering::Acquire), 4);
    }

    #[test]
    fn test_wasapi_live_hardware_smoke() {
        let probes = probe_wasapi_endpoints();
        let Some(ep) = probes
            .into_iter()
            .find(|p| p.exclusive_available && p.supported_rates.contains(&48_000))
        else {
            // No exclusive-capable endpoint on this host/CI runner; skip cleanly.
            return;
        };

        let wire = if ep.supported_bit_depths.contains(&16) {
            WireSampleFormat::Int16Le
        } else {
            WireSampleFormat::Int32Le
        };
        let spec = WasapiExclusiveOpenSpec {
            device_id: Some(ep.id),
            sample_rate: 48_000,
            channels: 2,
            layout: ChannelLayout::Stereo,
            wire_format: wire,
            is_dop: false,
            buffer_frames_hint: 480,
        };
        let (mut prod, cons) = SpscRingBuffer::<u8>::new(65_536);
        prod.push_slice(&vec![0u8; 480 * 2 * wire.bytes_per_sample() * 4]);
        let ver = make_test_verification();
        let session = match WasapiExclusiveSession::open_and_start(
            spec,
            cons,
            ver,
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicI32::new(2)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(RwLock::new(None)),
            1,
            Arc::new(AtomicU64::new(1)),
        ) {
            Ok(s) => s,
            Err(_) => return, // Endpoint busy or exclusive denied at open; skip cleanly.
        };

        thread::sleep(Duration::from_millis(30));
        session.set_paused(true);
        thread::sleep(Duration::from_millis(20));
        let _ = session.flush();
        session.set_paused(false);
        thread::sleep(Duration::from_millis(30));
        let _ = session.hardware_position_frames();
        session.stop();
    }

    #[test]
    fn test_asio_silence_fill_pcm_dsd_and_dop() {
        assert_eq!(asio_silence_byte(WireSampleFormat::Int16Le), 0x00);
        assert_eq!(asio_silence_byte(WireSampleFormat::NativeDsd { channels: 2 }), 0x69);

        let mut phase = false;
        let mut pcm = [0xAAu8; 16];
        fill_asio_buffer_silence(&mut pcm, WireSampleFormat::Int32Le, 4, &mut phase);
        assert!(pcm.iter().all(|&b| b == 0x00));

        let mut dsd = [0u8; 16];
        fill_asio_buffer_silence(&mut dsd, WireSampleFormat::NativeDsd { channels: 2 }, 1, &mut phase);
        assert!(dsd.iter().all(|&b| b == 0x69));

        // 4 samples in 32-bit DoP planar channel buffer (16 bytes).
        let mut dop32 = [0u8; 16];
        phase = false;
        fill_asio_buffer_silence(
            &mut dop32,
            WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: false,
            },
            4,
            &mut phase,
        );
        assert_eq!(
            dop32,
            [
                0x00, 0x69, 0x69, 0x05,
                0x00, 0x69, 0x69, 0xFA,
                0x00, 0x69, 0x69, 0x05,
                0x00, 0x69, 0x69, 0xFA,
            ]
        );
        assert!(!phase);

        // 24-bit packed ASIO channel buffer (drv_bps == 3): 2 samples = 6 bytes.
        let mut dop24 = [0u8; 6];
        phase = false;
        fill_asio_buffer_silence(
            &mut dop24,
            WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: false,
            },
            3,
            &mut phase,
        );
        assert_eq!(dop24, [0x69, 0x69, 0x05, 0x69, 0x69, 0xFA]);
    }

    #[test]
    fn test_asio_samples_hi_lo_64bit_conversion() {
        for &val in &[0u64, 1, u32::MAX as u64, 1u64 << 32, 0x1234_5678_9ABC_DEF0] {
            let s = AsioSamples::from_u64(val);
            assert_eq!(s.to_u64(), val);
            assert_eq!(s.hi, (val >> 32) as u32);
            assert_eq!(s.lo, val as u32);
        }

        // Verify raw Win64 C struct memory layout: `hi` at offset +0, `lo` at offset +4.
        let s = AsioSamples {
            hi: 0x0000_0001,
            lo: 0x0000_0200,
        };
        let bytes: [u8; 8] = unsafe { std::mem::transmute(s) };
        assert_eq!(&bytes[0..4], &0x0000_0001u32.to_le_bytes());
        assert_eq!(&bytes[4..8], &0x0000_0200u32.to_le_bytes());
        assert_eq!(s.to_u64(), (1u64 << 32) | 0x200);
    }

    #[test]
    fn test_asio_message_selector_and_reset_resync_dispatch() {
        let sig = AsioCallbackSignals::new(96_000);

        for sel in 1..=7 {
            assert_eq!(sig.handle_asio_message(K_ASIO_SELECTOR_SUPPORTED, sel), 1);
        }
        assert_eq!(
            sig.handle_asio_message(K_ASIO_SELECTOR_SUPPORTED, K_ASIO_SUPPORTS_TIME_CODE),
            0
        );
        assert_eq!(sig.handle_asio_message(K_ASIO_SELECTOR_SUPPORTED, 99), 0);
        assert_eq!(sig.handle_asio_message(K_ASIO_ENGINE_VERSION, 0), 2);
        assert_eq!(sig.handle_asio_message(K_ASIO_SUPPORTS_TIME_INFO, 0), 1);

        assert!(!sig.resync_requested.load(Ordering::Acquire));
        assert_eq!(sig.handle_asio_message(K_ASIO_RESYNC_REQUEST, 0), 1);
        assert!(sig.resync_requested.load(Ordering::Acquire));
        assert_eq!(sig.resync_count.load(Ordering::Acquire), 1);

        assert_eq!(sig.handle_asio_message(K_ASIO_LATENCIES_CHANGED, 0), 1);
        assert!(sig.latencies_changed.load(Ordering::Acquire));

        assert_eq!(sig.handle_asio_message(K_ASIO_RESET_REQUEST, 0), 1);
        assert!(sig.reset_requested.load(Ordering::Acquire));

        assert_eq!(sig.handle_asio_message(K_ASIO_BUFFER_SIZE_CHANGE, 1024), 1);
        assert_eq!(sig.requested_buffer_size.load(Ordering::Acquire), 1024);
    }

    #[test]
    fn test_asio_double_buffer_flush_state_machine() {
        // Test 1: PCM32 flush while playing clears ring + BOTH half-buffers 0 and 1.
        let (mut prod, cons) = SpscRingBuffer::<u8>::new(4096);
        let ring_ctrl = prod.control();
        let buf_frames = 16usize;
        let signals = Arc::new(AsioCallbackSignals::new(48_000));
        let paused = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicBool::new(false));
        let state_code = Arc::new(AtomicI32::new(2));
        let eof_flag = Arc::new(AtomicBool::new(false));
        let cur_sid = Arc::new(AtomicU64::new(1));

        let mut core = AsioRenderCore::new(
            cons,
            make_test_verification(),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
            Arc::clone(&state_code),
            Arc::clone(&eof_flag),
            Arc::clone(&paused),
            Arc::clone(&stopped),
            Arc::clone(&cur_sid),
            1,
            Arc::clone(&signals),
            buf_frames,
            2,
            48_000,
            ASIO_ST_INT32_LSB,
            WireSampleFormat::Int32Le,
        );

        let mut ch0_b0 = vec![0xAAu8; buf_frames * 4];
        let mut ch0_b1 = vec![0xAAu8; buf_frames * 4];
        let mut ch1_b0 = vec![0xAAu8; buf_frames * 4];
        let mut ch1_b1 = vec![0xAAu8; buf_frames * 4];
        let bufs = [
            [ch0_b0.as_mut_ptr(), ch0_b1.as_mut_ptr()],
            [ch1_b0.as_mut_ptr(), ch1_b1.as_mut_ptr()],
        ];

        // Push stale pre-seek data.
        prod.push_slice(&vec![0x11u8; buf_frames * 2 * 4 * 2]);

        // Request flush on both ring buffer and ASIO signals.
        ring_ctrl.request_flush();
        let req = signals.request_flush();
        assert_eq!(req, 1);

        assert!(core.process_buffer_switch(0, &bufs));
        assert_eq!(signals.flush_completed_epoch.load(Ordering::Acquire), 1);
        assert!(ch0_b0.iter().all(|&b| b == 0x00));
        assert!(ch0_b1.iter().all(|&b| b == 0x00));
        assert!(ch1_b0.iter().all(|&b| b == 0x00));
        assert!(ch1_b1.iter().all(|&b| b == 0x00));
        assert!(core.consumer.is_empty());

        // Producer syncs and pushes post-seek 0x55 data; next switch renders ONLY 0x55.
        assert_eq!(prod.sync_epoch(), 1);
        prod.push_slice(&vec![0x55u8; buf_frames * 2 * 4]);
        assert!(core.process_buffer_switch(1, &bufs));
        assert!(ch0_b1.iter().all(|&b| b == 0x55));
        assert!(ch1_b1.iter().all(|&b| b == 0x55));

        // Test 2: Native DSD flush while PAUSED zeroes BOTH buffers with 0x69.
        let (mut dsd_prod, dsd_cons) = SpscRingBuffer::<u8>::new(4096);
        let dsd_ring_ctrl = dsd_prod.control();
        let dsd_sig = Arc::new(AsioCallbackSignals::new(2_822_400));
        let dsd_paused = Arc::new(AtomicBool::new(true));
        let mut dsd_core = AsioRenderCore::new(
            dsd_cons,
            make_test_verification(),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicI32::new(3)),
            Arc::new(AtomicBool::new(false)),
            Arc::clone(&dsd_paused),
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicU64::new(1)),
            1,
            Arc::clone(&dsd_sig),
            64, // 64 DSD bit frames = 8 bytes
            2,
            2_822_400,
            ASIO_ST_DSD_INT8_LSB8,
            WireSampleFormat::NativeDsd { channels: 2 },
        );
        let mut d0_b0 = vec![0x11u8; 64];
        let mut d0_b1 = vec![0x11u8; 64];
        let mut d1_b0 = vec![0x11u8; 64];
        let mut d1_b1 = vec![0x11u8; 64];
        let dsd_bufs = [
            [d0_b0.as_mut_ptr(), d0_b1.as_mut_ptr()],
            [d1_b0.as_mut_ptr(), d1_b1.as_mut_ptr()],
        ];
        dsd_prod.push_slice(&[0x22u8; 256]);
        dsd_ring_ctrl.request_flush();
        dsd_sig.request_flush();
        assert!(dsd_core.process_buffer_switch(0, &dsd_bufs));
        assert_eq!(dsd_sig.flush_completed_epoch.load(Ordering::Acquire), 1);
        assert!(d0_b0.iter().all(|&b| b == 0x69));
        assert!(d0_b1.iter().all(|&b| b == 0x69));
        assert!(d1_b0.iter().all(|&b| b == 0x69));
        assert!(d1_b1.iter().all(|&b| b == 0x69));
    }

    #[test]
    fn test_asio_eof_drain_delays_completion_until_hardware_period_finishes() {
        let (mut prod, cons) = SpscRingBuffer::<u8>::new(4096);
        let buf_frames = 8usize;
        let signals = Arc::new(AsioCallbackSignals::new(48_000));
        signals.eof_target_state.store(8, Ordering::SeqCst);
        let state_code = Arc::new(AtomicI32::new(2));
        let eof_flag = Arc::new(AtomicBool::new(true));

        let mut core = AsioRenderCore::new(
            cons,
            make_test_verification(),
            Arc::new(AtomicU64::new(0)),
            Arc::new(AtomicU64::new(0)),
            Arc::clone(&state_code),
            Arc::clone(&eof_flag),
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicBool::new(false)),
            Arc::new(AtomicU64::new(1)),
            1,
            Arc::clone(&signals),
            buf_frames,
            2,
            48_000,
            ASIO_ST_INT32_LSB,
            WireSampleFormat::Int32Le,
        );

        let mut ch0_b0 = vec![0u8; buf_frames * 4];
        let mut ch0_b1 = vec![0u8; buf_frames * 4];
        let mut ch1_b0 = vec![0u8; buf_frames * 4];
        let mut ch1_b1 = vec![0u8; buf_frames * 4];
        let bufs = [
            [ch0_b0.as_mut_ptr(), ch0_b1.as_mut_ptr()],
            [ch1_b0.as_mut_ptr(), ch1_b1.as_mut_ptr()],
        ];

        // Push 1.5 periods (12 frames = 96 bytes).
        prod.push_slice(&[0x33u8; 12 * 2 * 4]);

        // Switch 0: renders first 8 frames.
        core.process_buffer_switch(0, &bufs);
        assert_eq!(state_code.load(Ordering::Acquire), 2);
        assert!(!signals.eof_drained.load(Ordering::Acquire));

        // Switch 1: renders remaining 4 tail frames + 4 silence frames.
        core.process_buffer_switch(1, &bufs);
        assert_eq!(state_code.load(Ordering::Acquire), 2);
        assert!(!signals.eof_drained.load(Ordering::Acquire));

        // Switch 2 (first silence period while tail is playing on DAC): MUST stay Playing (2)!
        core.process_buffer_switch(0, &bufs);
        assert_eq!(state_code.load(Ordering::Acquire), 2);
        assert!(!signals.eof_drained.load(Ordering::Acquire));

        // Switch 3 (second silence period completes drain): transitions 2 -> 8 and sets eof_drained!
        core.process_buffer_switch(1, &bufs);
        assert!(signals.eof_drained.load(Ordering::Acquire));
        assert_eq!(state_code.load(Ordering::Acquire), 8);
    }

    #[test]
    fn test_asio_mock_vtbl_get_sample_position_and_output_ready() {
        #[repr(C)]
        struct MockAsioVtbl {
            // IUnknown (0..2)
            query_interface: usize,
            add_ref: usize,
            release: usize,
            // IASIO (3..23)
            init: usize,
            get_driver_name: usize,
            get_driver_version: usize,
            get_error_message: usize,
            start: usize,
            stop: usize,
            get_channels: usize,
            get_latencies: usize,
            get_buffer_size: usize,
            can_sample_rate: usize,
            get_sample_rate: usize,
            set_sample_rate: usize,
            get_clock_sources: usize,
            set_clock_source: usize,
            get_sample_position:
                unsafe extern "C" fn(*mut c_void, *mut AsioSamples, *mut AsioTimeStamp) -> i32,
            get_channel_info: usize,
            create_buffers: usize,
            dispose_buffers: usize,
            control_panel: usize,
            future: usize,
            output_ready: unsafe extern "C" fn(*mut c_void) -> i32,
        }

        #[repr(C)]
        struct MockAsioObj {
            vtbl: *const MockAsioVtbl,
            output_ready_count: AtomicU32,
        }

        unsafe extern "C" fn mock_get_sample_position(
            _this: *mut c_void,
            s_pos: *mut AsioSamples,
            t_stamp: *mut AsioTimeStamp,
        ) -> i32 {
            unsafe {
                *s_pos = AsioSamples::from_u64(0x0000_0002_0000_1234);
                *t_stamp = AsioTimeStamp::from_u64(987_654_321_000);
            }
            ASIO_OK
        }

        unsafe extern "C" fn mock_output_ready(this: *mut c_void) -> i32 {
            let obj = unsafe { &*(this as *const MockAsioObj) };
            obj.output_ready_count.fetch_add(1, Ordering::Relaxed);
            ASIO_OK
        }

        let vtbl = MockAsioVtbl {
            query_interface: 0,
            add_ref: 0,
            release: 0,
            init: 0,
            get_driver_name: 0,
            get_driver_version: 0,
            get_error_message: 0,
            start: 0,
            stop: 0,
            get_channels: 0,
            get_latencies: 0,
            get_buffer_size: 0,
            can_sample_rate: 0,
            get_sample_rate: 0,
            set_sample_rate: 0,
            get_clock_sources: 0,
            set_clock_source: 0,
            get_sample_position: mock_get_sample_position,
            get_channel_info: 0,
            create_buffers: 0,
            dispose_buffers: 0,
            control_panel: 0,
            future: 0,
            output_ready: mock_output_ready,
        };
        let mut obj = MockAsioObj {
            vtbl: &vtbl,
            output_ready_count: AtomicU32::new(0),
        };
        let raw = (&mut obj as *mut MockAsioObj) as *mut c_void;

        let mut pos = AsioSamples::default();
        let mut ts = AsioTimeStamp::default();
        let rc = unsafe { ((*obj.vtbl).get_sample_position)(raw, &mut pos, &mut ts) };
        assert_eq!(rc, ASIO_OK);
        assert_eq!(pos.to_u64(), 0x0000_0002_0000_1234);
        assert_eq!(ts.to_u64(), 987_654_321_000);

        let rc2 = unsafe { ((*obj.vtbl).output_ready)(raw) };
        assert_eq!(rc2, ASIO_OK);
        assert_eq!(obj.output_ready_count.load(Ordering::Relaxed), 1);

        // Verify slot indices against Steinberg COM layout (3 IUnknown + 21 IASIO = 24 slots).
        assert_eq!(
            std::mem::size_of::<MockAsioVtbl>(),
            24 * std::mem::size_of::<usize>()
        );
    }
}
