use std::f64::consts::PI;

/// Generates a sine wave signal: s[n] = A * sin(2*pi * f/fs * n).
pub fn generate_sine(
    sample_rate: u32,
    freq_hz: f64,
    num_frames: usize,
    amplitude: f64,
) -> Vec<f64> {
    let mut out = Vec::with_capacity(num_frames);
    let fs = sample_rate as f64;
    for n in 0..num_frames {
        let t = n as f64 / fs;
        let s = amplitude * (2.0 * PI * freq_hz * t).sin();
        out.push(s);
    }
    out
}

/// Generates a Dirac impulse signal: delta[n] = 1.0 at n = impulse_index, 0.0 elsewhere.
pub fn generate_impulse(num_frames: usize, impulse_index: usize) -> Vec<f64> {
    let mut out = vec![0.0; num_frames];
    if impulse_index < num_frames {
        out[impulse_index] = 1.0;
    }
    out
}

/// Generates a band-limited or full square wave: s[n] = A * sgn(sin(2*pi * f/fs * n)).
pub fn generate_square(
    sample_rate: u32,
    freq_hz: f64,
    num_frames: usize,
    amplitude: f64,
) -> Vec<f64> {
    let mut out = Vec::with_capacity(num_frames);
    let fs = sample_rate as f64;
    for n in 0..num_frames {
        let t = n as f64 / fs;
        let s = (2.0 * PI * freq_hz * t).sin();
        let val = if s >= 0.0 { amplitude } else { -amplitude };
        out.push(val);
    }
    out
}

/// Generates digital silence (all zeros).
pub fn generate_silence(num_frames: usize) -> Vec<f64> {
    vec![0.0; num_frames]
}

/// Generates a stereo sine pair with independent frequencies.
pub fn generate_stereo_sine(
    sample_rate: u32,
    l_freq: f64,
    r_freq: f64,
    num_frames: usize,
) -> (Vec<f64>, Vec<f64>) {
    let l = generate_sine(sample_rate, l_freq, num_frames, 1.0);
    let r = generate_sine(sample_rate, r_freq, num_frames, 1.0);
    (l, r)
}

/// Calculates the DTFT magnitude response in decibels (dB) of an impulse response h[n] at `eval_freq_hz`.
/// H(e^{j w}) = sum_{n=0}^{N-1} h[n] * e^{-j w n}
/// |H(w)|_dB = 20 * log10(|H(e^{j w})|)
pub fn calculate_dtft_magnitude_db(
    impulse_response: &[f64],
    eval_freq_hz: f64,
    sample_rate_hz: f64,
) -> f64 {
    let w = 2.0 * PI * (eval_freq_hz / sample_rate_hz);
    let mut real_acc = 0.0;
    let mut imag_acc = 0.0;

    for (n, &h) in impulse_response.iter().enumerate() {
        let angle = w * (n as f64);
        real_acc += h * angle.cos();
        imag_acc -= h * angle.sin();
    }

    let mag_sq = real_acc * real_acc + imag_acc * imag_acc;
    if mag_sq <= 1e-24 {
        return -240.0;
    }

    10.0 * mag_sq.log10()
}
