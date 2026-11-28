use core_audio::{AudioDeviceManager, AudioFormatManager};
use core_types::{
    AudioCodec, AudioDeviceCapabilities, ChannelLayout, DeviceTransportKind, DsdOutputMode,
    DsdRate, Endianness, Interleaving, OutputBackendKind, OutputMode, PlaybackEnginePolicy,
    SampleFormatKind, UnifiedAudioFormat,
};

#[test]
fn test_real_windows_device_and_asio_hardware_probe() {
    let devices = AudioDeviceManager::list_devices();
    println!("Discovered {} audio devices:", devices.len());
    for d in &devices {
        println!(
            "  - {} [id={}] backend={:?} transport={:?} default={} excl={} asio={} native_dsd={} dop={} max_dsd={:?} rates={:?} bits={:?} note={:?}",
            d.name,
            d.device_id,
            d.backend,
            d.transport,
            d.is_default,
            d.exclusive_available,
            d.asio_available,
            d.supports_native_dsd,
            d.supports_dop,
            d.max_dsd_rate,
            d.supported_sample_rates,
            d.supported_bit_depths,
            d.probe_note
        );
    }

    // Even if this machine has zero active audio endpoints (CI), list_devices() must not panic,
    // and non-ASIO devices must never falsely claim asio_available=true.
    for d in &devices {
        if d.backend != OutputBackendKind::WindowsAsio {
            assert!(
                !d.asio_available && !d.supports_native_dsd,
                "Non-ASIO endpoint '{}' falsely claimed ASIO/Native DSD",
                d.name
            );
        }
        if d.transport == DeviceTransportKind::Bluetooth {
            assert!(
                !d.exclusive_available && !d.supports_dop,
                "Bluetooth device '{}' must never claim exclusive bit-perfect or DoP",
                d.name
            );
        }
    }
}

#[test]
fn test_format_negotiation_matrix_no_silent_resampling() {
    let usb_dac = AudioDeviceCapabilities {
        device_id: "usb-dac-1".into(),
        name: "FiiO Q series USB DAC".into(),
        backend: OutputBackendKind::WindowsWasapiExclusive,
        transport: DeviceTransportKind::UsbDac,
        is_default: true,
        is_exclusive: true,
        supported_sample_rates: vec![44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
        supported_bit_depths: vec![16, 24, 32],
        supported_container_bits: vec![16, 32],
        supported_channels: vec![2],
        supported_output_modes: vec![
            OutputMode::WasapiExclusive,
            OutputMode::DoPOverWasapiExclusive,
            OutputMode::WasapiShared,
        ],
        supports_native_dsd: false,
        supports_dop: true,
        supports_float32: false,
        max_dsd_rate: Some(DsdRate::Dsd128),
        asio_available: false,
        asio_driver_name: None,
        exclusive_available: true,
        probe_note: None,
    };

    let src_24_96 = UnifiedAudioFormat {
        codec: AudioCodec::Flac,
        sample_rate: 96_000,
        channels: 2,
        channel_layout: ChannelLayout::Stereo,
        sample_format: SampleFormatKind::Int24In32,
        container_bits: 32,
        valid_bits: 24,
        endianness: Endianness::Little,
        interleaving: Interleaving::Interleaved,
        dsd_rate: None,
    };

    let strict_policy = PlaybackEnginePolicy {
        strict_bit_perfect: true,
        allow_shared_fallback: false,
        dsd_output_mode: DsdOutputMode::Auto,
        preferred_buffer_frames: 512,
    };

    let neg = AudioFormatManager::negotiate(&src_24_96, &usb_dac, &strict_policy)
        .expect("24/96 must negotiate bit-exact WASAPI Exclusive");
    assert_eq!(neg.output_mode, OutputMode::WasapiExclusive);
    assert_eq!(neg.target_sample_rate, 96_000);
    assert!(!neg.requires_resampling);
    assert!(neg.is_bit_perfect_candidate);
    assert!(neg.requires_dsp_bypass);
    assert!(neg.requires_unity_volume);

    // Unsupported rate 384kHz under strict_bit_perfect + !allow_shared_fallback MUST error rather than silently resample!
    let mut unsupported_384 = src_24_96.clone();
    unsupported_384.sample_rate = 384_000;
    let err = AudioFormatManager::negotiate(&unsupported_384, &usb_dac, &strict_policy)
        .expect_err("Strict mode without fallback must reject unsupported sample rate");
    assert!(
        err.contains("384000") || err.contains("Strict"),
        "Unexpected err: {err}"
    );

    // Even if allow_shared_fallback is true, strict_bit_perfect=true MUST still reject fallback.
    let strict_with_fallback_flag = PlaybackEnginePolicy {
        strict_bit_perfect: true,
        allow_shared_fallback: true,
        ..strict_policy
    };
    let strict_err =
        AudioFormatManager::negotiate(&unsupported_384, &usb_dac, &strict_with_fallback_flag)
            .expect_err(
                "Strict Bit-Perfect must unconditionally reject shared/resampling fallback",
            );
    assert!(
        strict_err.contains("384000") || strict_err.contains("Strict"),
        "Unexpected strict err: {strict_err}"
    );

    // In non-strict mode with shared fallback allowed, degradation_reason must be explicit
    let fallback_policy = PlaybackEnginePolicy {
        strict_bit_perfect: false,
        allow_shared_fallback: true,
        ..strict_policy
    };
    let deg = AudioFormatManager::negotiate(&unsupported_384, &usb_dac, &fallback_policy)
        .expect("Fallback negotiation must succeed with explicit reason");
    assert_eq!(deg.output_mode, OutputMode::WasapiShared);
    assert!(deg.degradation_reason.is_some());
    assert!(!deg.is_bit_perfect_candidate);
    assert!(deg.requires_resampling);

    // DSD64 over USB DAC -> DoP at 176.4kHz
    let dsd64 = UnifiedAudioFormat {
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
    let dop = AudioFormatManager::negotiate(&dsd64, &usb_dac, &strict_policy)
        .expect("DSD64 must negotiate DoP over USB DAC");
    assert_eq!(dop.output_mode, OutputMode::DoPOverWasapiExclusive);
    assert_eq!(dop.target_sample_rate, 176_400);
    assert!(!dop.requires_resampling);
    assert!(dop.is_bit_perfect_candidate);

    // Bluetooth endpoint must never accept DoP or exclusive
    let bt = AudioDeviceCapabilities {
        device_id: "bt-1".into(),
        name: "WH-1000XM5".into(),
        backend: OutputBackendKind::WindowsWasapiShared,
        transport: DeviceTransportKind::Bluetooth,
        is_default: false,
        is_exclusive: false,
        supported_sample_rates: vec![48_000],
        supported_bit_depths: vec![16],
        supported_container_bits: vec![32],
        supported_channels: vec![2],
        supported_output_modes: vec![OutputMode::WasapiShared, OutputMode::DsdToPcm],
        supports_native_dsd: false,
        supports_dop: false,
        supports_float32: false,
        max_dsd_rate: None,
        asio_available: false,
        asio_driver_name: None,
        exclusive_available: false,
        probe_note: None,
    };
    let bt_dop_err = AudioFormatManager::negotiate(
        &dsd64,
        &bt,
        &PlaybackEnginePolicy {
            dsd_output_mode: DsdOutputMode::DoP,
            ..strict_policy
        },
    )
    .expect_err("Bluetooth must reject forced DoP");
    assert!(!bt_dop_err.is_empty());
}
