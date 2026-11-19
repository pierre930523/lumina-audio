/// Lookahead peak limiter with envelope follower and continuous soft clipper.
#[derive(Debug, Clone)]
pub struct LookaheadLimiter {
    lookahead_frames: usize,
    threshold: f64,
    attack_coeff: f64,
    release_coeff: f64,
    envelope: f64,
    delay_buf: Vec<f64>,
    channels: usize,
    delay_pos: usize,
    soft_clip_threshold: f64,
    enabled: bool,
}

impl LookaheadLimiter {
    pub const DEFAULT_LOOKAHEAD_SECS: f64 = 0.003; // 3 ms
    pub const DEFAULT_ATTACK_SECS: f64 = 0.001;    // 1 ms
    pub const DEFAULT_RELEASE_SECS: f64 = 0.100;   // 100 ms
    pub const DEFAULT_THRESHOLD: f64 = 0.9999;     // Just under 0 dBFS
    pub const SOFT_CLIP_THRESHOLD: f64 = 0.95;

    pub fn new(sample_rate_hz: f64, channels: usize) -> Self {
        let ch = channels.max(1);
        let lookahead_frames = ((sample_rate_hz * Self::DEFAULT_LOOKAHEAD_SECS).round() as usize).max(8);
        let attack_coeff = (-1.0 / (Self::DEFAULT_ATTACK_SECS * sample_rate_hz)).exp();
        let release_coeff = (-1.0 / (Self::DEFAULT_RELEASE_SECS * sample_rate_hz)).exp();

        let total_samples = (lookahead_frames + 1) * ch;

        Self {
            lookahead_frames,
            threshold: Self::DEFAULT_THRESHOLD,
            attack_coeff,
            release_coeff,
            envelope: 0.0,
            delay_buf: vec![0.0; total_samples],
            channels: ch,
            delay_pos: 0,
            soft_clip_threshold: Self::SOFT_CLIP_THRESHOLD,
            enabled: true,
        }
    }

    pub fn reset(&mut self) {
        self.delay_buf.fill(0.0);
        self.delay_pos = 0;
        self.envelope = 0.0;
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        if !enabled {
            self.reset();
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    pub fn lookahead_frames(&self) -> usize {
        self.lookahead_frames
    }

    /// Soft clipper transfer function with C^1 continuity and hard ceiling at +/-1.0.
    #[inline(always)]
    pub fn soft_clip(x: f64, threshold: f64) -> f64 {
        let abs_x = x.abs();
        if abs_x <= threshold {
            x
        } else {
            let margin = 1.0 - threshold;
            let compressed = threshold + margin * ((abs_x - threshold) / margin).tanh();
            if x.is_sign_negative() {
                -compressed
            } else {
                compressed
            }
        }
    }

    /// Processes a single frame of multi-channel audio in place.
    #[inline]
    pub fn process_frame(&mut self, frame: &mut [f64]) {
        if !self.enabled {
            return;
        }

        // 1. Calculate current frame peak
        let mut frame_peak = 0.0f64;
        for &s in frame.iter() {
            let abs_s = s.abs();
            if abs_s > frame_peak {
                frame_peak = abs_s;
            }
        }

        // 2. Smooth envelope follower
        if frame_peak > self.envelope {
            self.envelope = self.attack_coeff * self.envelope + (1.0 - self.attack_coeff) * frame_peak;
        } else {
            self.envelope = self.release_coeff * self.envelope + (1.0 - self.release_coeff) * frame_peak;
        }

        // 3. Compute gain reduction factor
        let gain = if self.envelope > self.threshold {
            self.threshold / self.envelope
        } else {
            1.0
        };

        // 4. Lookahead circular buffer delay
        let total_frames = self.delay_buf.len() / self.channels;
        let read_frame_idx = (self.delay_pos + total_frames - self.lookahead_frames) % total_frames;

        for ch in 0..self.channels.min(frame.len()) {
            let write_idx = self.delay_pos * self.channels + ch;
            let read_idx = read_frame_idx * self.channels + ch;

            let delayed_sample = self.delay_buf[read_idx];
            self.delay_buf[write_idx] = frame[ch];

            // Apply limiter gain and safety soft clipper
            let limited = delayed_sample * gain;
            frame[ch] = Self::soft_clip(limited, self.soft_clip_threshold);
        }

        self.delay_pos = (self.delay_pos + 1) % total_frames;
    }

    /// Processes an interleaved slice of multi-channel audio in place.
    pub fn process_interleaved(&mut self, samples: &mut [f64], channels: usize) {
        if !self.enabled || channels == 0 {
            return;
        }

        let frames = samples.len() / channels;
        for f in 0..frames {
            let offset = f * channels;
            let frame = &mut samples[offset..offset + channels];
            self.process_frame(frame);
        }
    }
}
