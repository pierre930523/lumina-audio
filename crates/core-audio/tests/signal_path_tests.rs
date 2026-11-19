use core_audio::dsp::DspPipeline;
use core_audio::signal_path::SignalPathEngine;
use core_audio::{build_signal_path, DspPipelineConfig, PeqBand};
use core_types::{AudioCodec, AudioFormat, OutputBackendKind, SignalQuality};

#[test]
fn test_signal_path_scenario_1_pure_lossless() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let dsp = DspPipelineConfig {
        bypass: true,
        ..Default::default()
    };
    let path = build_signal_path(
        "Local FLAC",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "RME ADI-2 DAC",
    );

    assert_eq!(path.overall, SignalQuality::Lossless);
    assert_eq!(path.nodes.len(), 2);
    assert_eq!(path.nodes[0].stage, "Source");
    assert_eq!(path.nodes[1].stage, "Output");
    assert_eq!(path.nodes[0].quality, SignalQuality::Lossless);
    assert_eq!(path.nodes[1].quality, SignalQuality::Lossless);
}

#[test]
fn test_signal_path_scenario_2_enhanced_with_peq() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let dsp = DspPipelineConfig {
        bypass: false,
        peq_bands: vec![PeqBand {
            frequency_hz: 1000.0,
            gain_db: 3.0,
            q_factor: 1.41,
            enabled: true,
        }],
        ..Default::default()
    };
    let path = build_signal_path(
        "Local FLAC",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "RME ADI-2 DAC",
    );

    assert_eq!(path.overall, SignalQuality::Enhanced);
    let stages: Vec<&str> = path.nodes.iter().map(|n| n.stage.as_str()).collect();
    assert_eq!(stages, vec!["Source", "64-bit DSP", "Output"]);
}

#[test]
fn test_signal_path_scenario_3_enhanced_with_src() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 192000, 24, 2).unwrap();
    let dsp = DspPipelineConfig {
        bypass: true,
        ..Default::default()
    };
    let path = build_signal_path(
        "Qobuz 24/192",
        &fmt,
        &dsp,
        Some(96000),
        OutputBackendKind::WindowsWasapiExclusive,
        "DAC",
    );

    assert_eq!(path.overall, SignalQuality::Enhanced);
    let src_node = path.nodes.iter().find(|n| n.stage == "Sample Rate Conversion").unwrap();
    assert!(src_node.detail.contains("192000 Hz -> 96000 Hz"));
}

#[test]
fn test_signal_path_scenario_4_wasapi_shared_degradation() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();
    let dsp = DspPipelineConfig::default();
    let path = build_signal_path(
        "Local FLAC",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsWasapiShared,
        "Realtek Audio",
    );

    assert_eq!(path.overall, SignalQuality::HighQuality);
    let out_node = path.nodes.iter().find(|n| n.stage == "Output").unwrap();
    assert_eq!(out_node.quality, SignalQuality::HighQuality);
}

#[test]
fn test_signal_path_scenario_5_lossy_source_degradation() {
    let fmt = AudioFormat::pcm(AudioCodec::Mp3, 44100, 16, 2).unwrap();
    let dsp = DspPipelineConfig::default();
    let path = build_signal_path(
        "Streaming MP3",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "DAC",
    );

    assert_eq!(path.overall, SignalQuality::HighQuality);
    assert_eq!(path.nodes[0].quality, SignalQuality::HighQuality);
}

#[test]
fn test_signal_path_scenario_6_native_dsd_lossless() {
    let fmt = AudioFormat::dsd(AudioCodec::Dsf, 2822400, 2).unwrap();
    let dsp = DspPipelineConfig {
        bypass: true,
        ..Default::default()
    };
    let path = build_signal_path(
        "SACD Rip",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "DSD DAC",
    );

    assert_eq!(path.overall, SignalQuality::Lossless);
    assert!(path.nodes[0].detail.contains("DSD"));
}

#[test]
fn test_signal_path_scenario_8_strict_stage_ordering() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 192000, 24, 2).unwrap();
    let dsp = DspPipelineConfig {
        bypass: false,
        crossfeed_enabled: true,
        replay_gain_db: Some(-3.0),
        ..Default::default()
    };
    let path = build_signal_path(
        "Studio Master",
        &fmt,
        &dsp,
        Some(96000),
        OutputBackendKind::WindowsAsio,
        "DAC",
    );

    assert_eq!(path.overall, SignalQuality::Enhanced);
    let stages: Vec<&str> = path.nodes.iter().map(|n| n.stage.as_str()).collect();
    assert_eq!(
        stages,
        vec!["Source", "64-bit DSP", "Sample Rate Conversion", "Output"]
    );
}

#[test]
fn test_signal_path_scenario_9_wasapi_shared_overrides_dsp_enhanced() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let dsp = DspPipelineConfig {
        bypass: false,
        peq_bands: vec![PeqBand {
            frequency_hz: 500.0,
            gain_db: 2.0,
            q_factor: 1.0,
            enabled: true,
        }],
        ..Default::default()
    };
    let path = build_signal_path(
        "FLAC",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsWasapiShared,
        "Speakers",
    );

    // WASAPI Shared must degrade the overall quality from Enhanced to HighQuality!
    assert_eq!(path.overall, SignalQuality::HighQuality);
}

#[test]
fn test_signal_path_empty_source_label() {
    let fmt = AudioFormat::pcm(AudioCodec::Wav, 44100, 16, 2).unwrap();
    let dsp = DspPipelineConfig::default();
    let path = build_signal_path(
        "",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "DAC",
    );

    assert_eq!(path.nodes[0].stage, "Source");
    assert!(!path.nodes[0].detail.is_empty());
}

#[test]
fn test_signal_path_build_from_dsp_pipeline() {
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 48000, 24, 2).unwrap();
    let mut dsp = DspPipeline::new(48000.0, 2).unwrap();
    dsp.set_crossfeed_enabled(true);

    let path = SignalPathEngine::build_from_dsp(
        "Qobuz",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "DAC",
    );

    assert_eq!(path.overall, SignalQuality::Enhanced);

    // Now engage bypass
    dsp.set_bypass(true);
    let bypassed_path = SignalPathEngine::build_from_dsp(
        "Qobuz",
        &fmt,
        &dsp,
        None,
        OutputBackendKind::WindowsAsio,
        "DAC",
    );
    assert_eq!(bypassed_path.overall, SignalQuality::Lossless);
    assert_eq!(bypassed_path.nodes.len(), 2);
}
