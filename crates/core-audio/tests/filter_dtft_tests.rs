use core_audio::dsp::{
    AutoEqParser, BiquadCoefficients, BiquadFilter, CrossfeedFilter, DspPipeline, FilterType,
    LookaheadLimiter, ParametricBand, ReplayGain, ReplayGainConfig, ReplayGainMode,
};
use core_audio::test_utils::{calculate_dtft_magnitude_db, generate_impulse, generate_sine};

#[test]
fn test_peaking_eq_dtft_mathematical_response() {
    let sample_rate = 48000.0;
    let f0 = 1000.0;
    let gain_db = 6.0;
    let q = std::f64::consts::SQRT_2;

    let coeffs = BiquadCoefficients::compute(FilterType::Peaking, sample_rate, f0, gain_db, q)
        .expect("Biquad computation failed");

    assert!(coeffs.is_stable(), "Filter must be stable");

    // 1. Direct formula response check
    let resp_at_f0 = coeffs.frequency_response_db(f0, sample_rate);
    assert!(
        (resp_at_f0 - gain_db).abs() < 0.05,
        "Response at f0 expected ~{gain_db} dB, got {resp_at_f0}"
    );

    let resp_at_dc = coeffs.frequency_response_db(20.0, sample_rate);
    assert!(
        resp_at_dc.abs() < 0.05,
        "Response at DC expected ~0 dB, got {resp_at_dc}"
    );

    let resp_at_nyquist = coeffs.frequency_response_db(20000.0, sample_rate);
    assert!(
        resp_at_nyquist.abs() < 0.05,
        "Response at high frequency expected ~0 dB, got {resp_at_nyquist}"
    );

    // 2. Feed Dirac impulse into actual filter and compute DTFT
    let num_frames = 2048;
    let impulse = generate_impulse(num_frames, 0);
    let mut filter = BiquadFilter::new(coeffs, 1);
    let mut h = Vec::with_capacity(num_frames);
    for x in impulse {
        h.push(filter.process_sample(0, x));
    }

    let dtft_f0 = calculate_dtft_magnitude_db(&h, f0, sample_rate);
    assert!(
        (dtft_f0 - gain_db).abs() < 0.05,
        "DTFT magnitude at f0 expected ~{gain_db} dB, got {dtft_f0}"
    );

    let dtft_20 = calculate_dtft_magnitude_db(&h, 20.0, sample_rate);
    assert!(
        dtft_20.abs() < 0.05,
        "DTFT magnitude at 20 Hz expected ~0 dB, got {dtft_20}"
    );

    // 3. Cut response check (-6 dB)
    let cut_coeffs =
        BiquadCoefficients::compute(FilterType::Peaking, sample_rate, f0, -6.0, q).unwrap();
    let cut_f0 = cut_coeffs.frequency_response_db(f0, sample_rate);
    assert!(
        (cut_f0 - (-6.0)).abs() < 0.05,
        "Cut at f0 expected -6 dB, got {cut_f0}"
    );
}

#[test]
fn test_low_shelf_dtft_response() {
    let sample_rate = 48000.0;
    let f0 = 100.0;
    let gain_db = 6.0;
    let q = std::f64::consts::FRAC_1_SQRT_2;

    let coeffs = BiquadCoefficients::compute(FilterType::LowShelf, sample_rate, f0, gain_db, q)
        .expect("LowShelf computation failed");
    assert!(coeffs.is_stable());

    // Passband (20 Hz) should have full boost (+6 dB)
    let resp_passband = coeffs.frequency_response_db(20.0, sample_rate);
    assert!(
        (resp_passband - gain_db).abs() < 0.1,
        "Passband expected ~{gain_db} dB, got {resp_passband}"
    );

    // Stopband (10 kHz) should be ~0 dB
    let resp_stopband = coeffs.frequency_response_db(10000.0, sample_rate);
    assert!(
        resp_stopband.abs() < 0.05,
        "Stopband expected ~0 dB, got {resp_stopband}"
    );
}

#[test]
fn test_high_shelf_dtft_response() {
    let sample_rate = 48000.0;
    let f0 = 10000.0;
    let gain_db = -4.0;
    let q = std::f64::consts::FRAC_1_SQRT_2;

    let coeffs = BiquadCoefficients::compute(FilterType::HighShelf, sample_rate, f0, gain_db, q)
        .expect("HighShelf computation failed");
    assert!(coeffs.is_stable());

    // High passband (20 kHz) should have attenuation (-4 dB)
    let resp_high = coeffs.frequency_response_db(20000.0, sample_rate);
    assert!(
        (resp_high - gain_db).abs() < 0.1,
        "High shelf passband expected ~{gain_db} dB, got {resp_high}"
    );

    // Stopband (100 Hz) should be ~0 dB
    let resp_low = coeffs.frequency_response_db(100.0, sample_rate);
    assert!(
        resp_low.abs() < 0.05,
        "High shelf stopband expected ~0 dB, got {resp_low}"
    );
}

#[test]
fn test_butterworth_low_pass_response() {
    let sample_rate = 48000.0;
    let fc = 1000.0;
    let q = 1.0 / std::f64::consts::SQRT_2; // 0.7071 Butterworth

    let coeffs = BiquadCoefficients::compute(FilterType::LowPass, sample_rate, fc, 0.0, q)
        .expect("LPF computation failed");
    assert!(coeffs.is_stable());

    // Cutoff frequency fc should be exactly -3.01 dB
    let resp_fc = coeffs.frequency_response_db(fc, sample_rate);
    assert!(
        (resp_fc - (-3.0103)).abs() < 0.1,
        "LPF at fc expected -3.01 dB, got {resp_fc}"
    );

    // DC should be ~0 dB
    let resp_dc = coeffs.frequency_response_db(20.0, sample_rate);
    assert!(
        resp_dc.abs() < 0.05,
        "LPF at DC expected 0 dB, got {resp_dc}"
    );

    // 10 kHz (one decade above fc) should have ~-40 dB attenuation for 2nd order Butterworth
    let resp_high = coeffs.frequency_response_db(10000.0, sample_rate);
    assert!(
        resp_high < -35.0,
        "LPF at 10 kHz expected < -35 dB, got {resp_high}"
    );
}

#[test]
fn test_autoeq_parser_and_peq_cascade() {
    let autoeq_text = r#"
Preamp: -6.0 dB
Filter 1: ON PK Fc 32 Hz Gain 4.5 dB Q 1.41
Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.71
Filter 3: ON HSC Fc 10000 Hz Gain -2.0 dB Q 0.71
Filter 4: OFF PK Fc 450 Hz Gain -1.2 dB Q 2.0
"#;

    let profile = AutoEqParser::parse(autoeq_text).expect("Failed to parse AutoEQ profile");
    assert_eq!(profile.preamp_db, -6.0);
    assert_eq!(profile.bands.len(), 4);

    assert_eq!(profile.bands[0].filter_type, FilterType::Peaking);
    assert_eq!(profile.bands[0].frequency_hz, 32.0);
    assert_eq!(profile.bands[0].gain_db, 4.5);
    assert!(profile.bands[0].enabled);

    assert_eq!(profile.bands[1].filter_type, FilterType::LowShelf);
    assert_eq!(profile.bands[1].frequency_hz, 105.0);
    assert_eq!(profile.bands[1].gain_db, 5.5);

    assert_eq!(profile.bands[3].filter_type, FilterType::Peaking);
    assert!(!profile.bands[3].enabled);

    let peq = profile
        .to_peq(48000.0, 2)
        .expect("Failed to construct PEQ from AutoEQ");
    let resp_at_32 = peq.frequency_response_db(32.0);
    // At 32 Hz, both the 32 Hz peaking filter and 105 Hz low shelf contribute gain
    assert!(
        resp_at_32 > 8.0,
        "Expected composite gain > 8 dB at 32 Hz, got {resp_at_32}"
    );
}

#[test]
fn test_crossfeed_filter_itd_and_mono_invariance() {
    let sample_rate = 48000.0;
    let mut crossfeed = CrossfeedFilter::new(sample_rate).expect("Crossfeed creation failed");

    // 1. Mono invariance: left == right preserves identical left and right output
    let mono_val = 0.707;
    let (l_out, r_out) = crossfeed.process_stereo(mono_val, mono_val);
    assert_eq!(
        l_out, r_out,
        "Mono signal should produce identical left and right"
    );

    // 2. Left-only impulse response test
    crossfeed.reset();
    let num_frames = 64;
    let mut out_l = Vec::new();
    let mut out_r = Vec::new();

    for n in 0..num_frames {
        let in_l = if n == 0 { 1.0 } else { 0.0 };
        let (yl, yr) = crossfeed.process_stereo(in_l, 0.0);
        out_l.push(yl);
        out_r.push(yr);
    }

    // For n < delay, right channel must be strictly zero (causal delay)
    let delay = crossfeed.delay_samples();
    assert!(
        (12..=14).contains(&delay),
        "Delay samples expected ~13, got {delay}"
    );
    for &val in out_r.iter().take(delay) {
        assert_eq!(
            val, 0.0,
            "Expected silence on right channel before delay {delay}"
        );
    }
    // At n = delay, impulse arrives at cross channel
    assert!(
        out_r[delay] > 0.0,
        "Impulse should arrive on right channel at n = {delay}"
    );

    // Direct left impulse should appear at n=0
    assert!(
        out_l[0] > 0.8,
        "Direct path expected at n=0, got {}",
        out_l[0]
    );
}

#[test]
fn test_replaygain_linear_gain_and_peak_clamping() {
    // 1. -6 dB gain without peak
    let rg1 = ReplayGain::from_gain_db(-6.0, 0.0);
    let expected_linear = 10.0f64.powf(-6.0 / 20.0);
    assert!(
        (rg1.linear_gain() - expected_linear).abs() < 1e-6,
        "Linear gain mismatch: expected {expected_linear}, got {}",
        rg1.linear_gain()
    );

    // 2. +6 dB gain with peak = 0.9. Gain would be 1.995 * 0.9 = 1.795 > 1.0 -> should clamp to 1.0 / 0.9 = 1.111
    let config = ReplayGainConfig {
        mode: ReplayGainMode::Track,
        preamp_db: 0.0,
        track_gain_db: Some(6.0),
        track_peak: Some(0.9),
        album_gain_db: None,
        album_peak: None,
        prevent_clipping: true,
    };
    let rg2 = ReplayGain::new(config);
    assert!(
        (rg2.linear_gain() - (1.0 / 0.9)).abs() < 1e-4,
        "Expected gain clamped to ~1.111, got {}",
        rg2.linear_gain()
    );
}

#[test]
fn test_lookahead_limiter_and_soft_clipper() {
    let sample_rate = 48000.0;
    let mut limiter = LookaheadLimiter::new(sample_rate, 2);

    // Feed an overloaded sine wave with amplitude 2.0 (+6 dBFS)
    let frames = 1000;
    let sine = generate_sine(48000, 1000.0, frames, 2.0);
    let mut stereo_buf = Vec::with_capacity(frames * 2);
    for s in sine {
        stereo_buf.push(s);
        stereo_buf.push(s);
    }

    limiter.process_interleaved(&mut stereo_buf, 2);

    // After attack time (~48 samples), peak should strictly be <= 1.0001
    for (i, &s) in stereo_buf[100..].iter().enumerate() {
        assert!(
            s.abs() <= 1.0001,
            "Limiter failed to constrain peak at sample {i}: got {s}"
        );
    }
}

#[test]
fn test_dsp_pipeline_hard_bypass_zero_modification() {
    let sample_rate = 48000.0;
    let mut pipeline = DspPipeline::new(sample_rate, 2).expect("Pipeline creation failed");

    // Configure active PEQ band (+10 dB)
    pipeline
        .set_peq_bands(vec![ParametricBand {
            filter_type: FilterType::Peaking,
            frequency_hz: 1000.0,
            gain_db: 10.0,
            q_factor: 1.0,
            enabled: true,
        }])
        .unwrap();

    // Enable crossfeed and limiter
    pipeline.set_crossfeed_enabled(true);
    pipeline.set_limiter_enabled(true);

    // Turn ON bypass
    pipeline.set_bypass(true);
    assert!(pipeline.is_bypassed());
    assert!(!pipeline.is_dsp_active());

    // Generate pseudo-random samples
    let original: Vec<f64> = (0..500).map(|n| (n as f64 * 123.456).sin() * 0.8).collect();

    let mut processed = original.clone();
    pipeline.process_interleaved(&mut processed);

    // Bit-exact identity check
    assert_eq!(
        original, processed,
        "Bypass mode must NOT modify audio samples in any way"
    );
}
