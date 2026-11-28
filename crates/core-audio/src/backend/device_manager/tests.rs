use super::*;
use crate::player::AudioPlayer;
use crate::stream::StreamSource;
use crate::verification::{AudioVerificationEngine, VerificationConfig, WireSampleFormat};
use core_types::{
    AudioCodec, AudioDeviceCapabilities, AudioDeviceDescription, ChannelLayout,
    DeviceTransportKind, DsdOutputMode, DsdRate, Endianness, Interleaving, OutputBackendKind,
    OutputMode, PlaybackEnginePolicy, SampleFormatKind, UnifiedAudioFormat, VerificationStatus,
};
use std::collections::HashSet;

#[test]
fn test_device_manager_separates_wasapi_exclusive_shared_and_asio_without_duplicates() {
    let with_meta = AudioDeviceManager::list_devices_with_meta();
    let mut seen_ids = HashSet::new();
    let mut seen_pairs = HashSet::new();

    for (cap, _meta) in &with_meta {
        assert!(
            seen_ids.insert(cap.device_id.clone()),
            "Duplicate device_id emitted: {}",
            cap.device_id
        );
        let phys = AudioDeviceManager::strip_mode_prefix(&cap.device_id).to_string();
        assert!(
            seen_pairs.insert((phys.clone(), cap.backend)),
            "Duplicate (endpoint, backend) emitted: {} {:?}",
            phys,
            cap.backend
        );
        if cap.backend == OutputBackendKind::WindowsWasapiShared {
            assert!(
                !cap.exclusive_available && !cap.is_exclusive,
                "WASAPI Shared entry '{}' must never claim exclusive_available",
                cap.name
            );
            assert!(
                cap.device_id.starts_with("wasapi-shared::"),
                "WASAPI Shared entry must use distinct mode prefix"
            );
        } else if cap.backend == OutputBackendKind::WindowsWasapiExclusive {
            assert!(
                cap.exclusive_available && cap.is_exclusive,
                "WASAPI Exclusive entry '{}' must have exclusive_available=true",
                cap.name
            );
        }
    }
}

#[test]
fn test_wasapi_shared_negotiation_and_verification_never_bit_perfect() {
    let shared_cap = AudioDeviceCapabilities {
        device_id: "wasapi-shared::dev-1".into(),
        name: "Speakers (Realtek)".into(),
        backend: OutputBackendKind::WindowsWasapiShared,
        transport: DeviceTransportKind::Speakers,
        is_default: true,
        is_exclusive: false,
        supported_sample_rates: vec![48_000],
        supported_bit_depths: vec![32],
        supported_container_bits: vec![32],
        supported_channels: vec![2],
        supported_output_modes: vec![OutputMode::WasapiShared, OutputMode::DsdToPcm],
        supports_native_dsd: false,
        supports_dop: false,
        supports_float32: true,
        max_dsd_rate: None,
        asio_available: false,
        asio_driver_name: None,
        exclusive_available: false,
        probe_note: Some("Windows Shared Mixer (48000 Hz)".into()),
    };

    let src = UnifiedAudioFormat {
        codec: AudioCodec::Flac,
        sample_rate: 48_000,
        channels: 2,
        channel_layout: ChannelLayout::Stereo,
        sample_format: SampleFormatKind::Int24In32,
        container_bits: 32,
        valid_bits: 24,
        endianness: Endianness::Little,
        interleaving: Interleaving::Interleaved,
        dsd_rate: None,
    };

    let neg = AudioFormatManager::negotiate(
        &src,
        &shared_cap,
        &PlaybackEnginePolicy {
            strict_bit_perfect: false,
            allow_shared_fallback: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(neg.output_mode, OutputMode::WasapiShared);
    assert!(!neg.is_bit_perfect_candidate);

    // BP-1: Even if allow_shared_fallback is left true, strict_bit_perfect MUST reject shared fallback.
    let strict_res = AudioFormatManager::negotiate(
        &src,
        &shared_cap,
        &PlaybackEnginePolicy {
            strict_bit_perfect: true,
            allow_shared_fallback: true,
            ..Default::default()
        },
    );
    assert!(strict_res.is_err());

    let ver = AudioVerificationEngine::new(VerificationConfig {
        source_format: src,
        output_mode: OutputMode::WasapiShared,
        transport: DeviceTransportKind::Speakers,
        target_rate_hz: 48_000,
        target_channels: 2,
        target_valid_bits: 32,
        target_container_bits: 32,
        buffer_size_frames: 480,
        dsp_active: false,
        software_volume_unity: true,
        resampled: false,
        exclusive_unavailable_reason: None,
    });
    ver.record_backend_input_wire(&[0u8; 32], WireSampleFormat::Float32Le, 2, 48_000);
    let snap = ver.snapshot("WindowsWasapiShared", "Speakers (Realtek)");
    assert_ne!(snap.verification.status, VerificationStatus::BitPerfect);
}

#[test]
fn test_dop_negotiation_preserves_dsf_lsb_and_dsdiff_msb_bit_order() {
    let cap = AudioDeviceManager::virtual_device_capabilities();
    let policy = PlaybackEnginePolicy {
        strict_bit_perfect: true,
        dsd_output_mode: DsdOutputMode::DoP,
        ..Default::default()
    };

    let dsf = UnifiedAudioFormat {
        codec: AudioCodec::Dsf,
        sample_rate: 2_822_400,
        channels: 2,
        channel_layout: ChannelLayout::Stereo,
        sample_format: SampleFormatKind::DsdU8,
        container_bits: 8,
        valid_bits: 1,
        endianness: Endianness::Little,
        interleaving: Interleaving::Interleaved,
        dsd_rate: Some(DsdRate::Dsd64),
    };
    let neg_dsf = AudioFormatManager::negotiate(&dsf, &cap, &policy).unwrap();
    assert_eq!(
        neg_dsf.wire_format,
        WireSampleFormat::Dop24In32MsbLe {
            channels: 2,
            is_lsb_first: true,
        }
    );

    let dsdiff = UnifiedAudioFormat {
        codec: AudioCodec::Dsdiff,
        endianness: Endianness::Big,
        ..dsf
    };
    let neg_dff = AudioFormatManager::negotiate(&dsdiff, &cap, &policy).unwrap();
    assert_eq!(
        neg_dff.wire_format,
        WireSampleFormat::Dop24In32MsbLe {
            channels: 2,
            is_lsb_first: false,
        }
    );
}

#[test]
fn test_player_device_selection_errors_and_buffer_frames_policy() {
    let player = AudioPlayer::new_headless();
    player
        .play_stream(StreamSource::synth("t-buf", "Buffer Test", 5_000), "Synth")
        .unwrap();

    assert!(
        player
            .select_output_device(Some("missing-dac-999"), None)
            .is_err()
    );
    player.set_preferred_buffer_frames(1024).unwrap();
    assert_eq!(player.preferred_buffer_frames(), 1024);

    // Selecting System Output (None) mid-playback succeeds and re-initializes cleanly
    player.select_output_device(None, None).unwrap();

    // Switching to explicit WASAPI Shared clears Strict Bit-Perfect and restores normal volume
    player.set_volume(0.40);
    player.set_strict_bit_perfect(true).unwrap();
    assert!(player.is_strict_bit_perfect());
    assert!((player.volume() - 1.0).abs() < 1e-4);

    player
        .select_output_device(None, Some(OutputBackendKind::WindowsWasapiShared))
        .unwrap();
    assert!(!player.is_strict_bit_perfect());
    assert!((player.volume() - 0.40).abs() < 1e-4);

    player.stop();
    player.shutdown();
}

#[test]
fn test_device_info_builders_merge_extra_meta() {
    let desc = AudioDeviceDescription {
        id: "wasapi-excl::dac-test".into(),
        name: "Test USB DAC".into(),
        backend: OutputBackendKind::WindowsWasapiExclusive,
        is_default: false,
        is_exclusive: true,
        supported_sample_rates: vec![44_100, 96_000, 192_000],
        supported_bit_depths: vec![16, 24],
        supports_native_dsd: true,
    };
    let meta = DeviceExtraMeta {
        is_os_default: true,
        is_hdmi: false,
        hardware_supports_exclusive: true,
        buffer_size_supported: true,
        min_buffer_frames: Some(64),
        max_buffer_frames: Some(2048),
        default_buffer_frames: Some(512),
        buffer_granularity: Some(64),
    };
    let info = AudioDeviceManager::to_device_info(&desc, Some(&meta), true);
    assert_eq!(info.id, "wasapi-excl::dac-test");
    assert!(info.is_default);
    assert!(info.is_active);
    assert!(info.supports_exclusive);
    assert!(info.supports_dsd);
    assert_eq!(info.min_buffer_frames, 64);
    assert_eq!(info.max_buffer_frames, 2048);
    assert_eq!(info.default_buffer_frames, 512);
    assert_eq!(info.buffer_granularity, 64);

    let cap = AudioDeviceManager::virtual_device_capabilities();
    let cap_info = AudioDeviceManager::capabilities_to_device_info(&cap, &meta, false);
    assert_eq!(cap_info.id, "virtual-hifi-dac");
    assert!(cap_info.supports_dop);
    assert_eq!(cap_info.max_channels, 8);
    assert!(!cap_info.is_active);
}
