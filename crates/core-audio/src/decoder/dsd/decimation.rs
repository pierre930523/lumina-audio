pub const DSD_SILENCE_BYTE: u8 = 0x69; // 01101001 ultrasonic carrier pattern

const HTAPS: usize = 48;
const FIFOSIZE: usize = 16;
const FIFOMASK: usize = FIFOSIZE - 1;
const CTABLES: usize = HTAPS.div_ceil(8); // 6 tables

#[allow(clippy::excessive_precision)]
const HTAPS_COEFFS: [f64; HTAPS] = [
    0.09950731974056658,
    0.09562845727714668,
    0.08819647126516944,
    0.07782552527068175,
    0.06534876523171299,
    0.05172629311427257,
    0.0379429484910187,
    0.02490921351762261,
    0.0133774746265897,
    0.003883043418804416,
    -0.003284703416210726,
    -0.008080250212687497,
    -0.01067241812471033,
    -0.01139427235000863,
    -0.0106813877974587,
    -0.009007905078766049,
    -0.006828859761015335,
    -0.004535184322001496,
    -0.002425035959059578,
    -0.0006922187080790708,
    0.0005700762133516592,
    0.001353838005269448,
    0.001713709169690937,
    0.001742046839472948,
    0.001545601648013235,
    0.001226696225277855,
    0.0008704322683580222,
    0.0005381636200535649,
    0.000266446345425276,
    7.002968738383528e-05,
    -5.279407053811266e-05,
    -0.0001140625650874684,
    -0.0001304796361231895,
    -0.0001189970287491285,
    -9.396247155265073e-05,
    -6.577634378272832e-05,
    -4.07492895872535e-05,
    -2.17407957554587e-05,
    -9.163058931391722e-06,
    -2.017460145032201e-06,
    1.249721855219005e-06,
    2.166655190537392e-06,
    1.930520892991082e-06,
    1.319400334374195e-06,
    7.410039764949091e-07,
    3.423230509967409e-07,
    1.244182214744588e-07,
    3.130441005359396e-08,
];

/// Sebastian Gesemann's 96-tap FIR Decimator for high-quality DSD-to-PCM conversion.
/// Decimates 8 DSD 1-bit samples (1 byte) into 1 64-bit float PCM sample (factor of 8).
/// Provides > 160 dB stopband rejection.
#[derive(Debug, Clone)]
pub struct DsdChannelDecimator {
    fifo: [u8; FIFOSIZE],
    fifopos: usize,
    tables: [[f64; 256]; CTABLES],
}

impl Default for DsdChannelDecimator {
    fn default() -> Self {
        Self::new()
    }
}

impl DsdChannelDecimator {
    pub fn new() -> Self {
        let mut tables = [[0.0f64; 256]; CTABLES];
        for t in 0..CTABLES {
            let k = (HTAPS - t * 8).min(8);
            for (e, slot) in tables[CTABLES - 1 - t].iter_mut().enumerate() {
                let mut acc = 0.0;
                for m in 0..k {
                    let bit = (((e >> (7 - m)) & 1) as i32) * 2 - 1;
                    acc += (bit as f64) * HTAPS_COEFFS[t * 8 + m];
                }
                *slot = acc;
            }
        }

        let mut decimator = Self {
            fifo: [DSD_SILENCE_BYTE; FIFOSIZE],
            fifopos: 0,
            tables,
        };
        decimator.reset();
        decimator
    }

    pub fn reset(&mut self) {
        self.fifo.fill(DSD_SILENCE_BYTE);
        self.fifopos = 0;
    }

    /// Translates a single DSD byte (8 1-bit samples) into one 64-bit float PCM sample.
    /// Handles LSB-to-MSB bit order conversion if `is_lsb_first` is true (e.g. for DSF).
    #[inline]
    pub fn translate_byte(&mut self, mut byte: u8, is_lsb_first: bool) -> f64 {
        if is_lsb_first {
            byte = byte.reverse_bits();
        }

        self.fifo[self.fifopos] = byte;
        let p_idx = (self.fifopos.wrapping_sub(CTABLES)) & FIFOMASK;
        self.fifo[p_idx] = self.fifo[p_idx].reverse_bits();

        let mut acc = 0.0;
        for i in 0..CTABLES {
            let b1 = self.fifo[(self.fifopos.wrapping_sub(i)) & FIFOMASK] as usize;
            let b2 = self.fifo
                [(self.fifopos.wrapping_sub(CTABLES * 2 - 1).wrapping_add(i)) & FIFOMASK]
                as usize;
            acc += self.tables[i][b1] + self.tables[i][b2];
        }

        self.fifopos = (self.fifopos + 1) & FIFOMASK;
        acc
    }
}

/// Stereo pair decimator for 2-channel DSD streams.
#[derive(Debug, Clone, Default)]
pub struct DsdStereoDecimator {
    pub left: DsdChannelDecimator,
    pub right: DsdChannelDecimator,
}

impl DsdStereoDecimator {
    pub fn new() -> Self {
        Self {
            left: DsdChannelDecimator::new(),
            right: DsdChannelDecimator::new(),
        }
    }

    pub fn reset(&mut self) {
        self.left.reset();
        self.right.reset();
    }

    /// Decimates one byte for left channel and one byte for right channel into an interleaved (L, R) frame.
    #[inline]
    pub fn translate_stereo_bytes(
        &mut self,
        left_byte: u8,
        right_byte: u8,
        is_lsb_first: bool,
    ) -> (f64, f64) {
        let l = self.left.translate_byte(left_byte, is_lsb_first);
        let r = self.right.translate_byte(right_byte, is_lsb_first);
        (l, r)
    }

    /// Decimates a contiguous byte-interleaved buffer `[L0, R0, L1, R1, ...]` into interleaved `[L0, R0, L1, R1, ...]`.
    pub fn decimate_interleaved(&mut self, bytes: &[u8], is_lsb_first: bool) -> Vec<f64> {
        let pairs = bytes.len() / 2;
        let mut out = Vec::with_capacity(pairs * 2);
        for i in 0..pairs {
            let l_byte = bytes[i * 2];
            let r_byte = bytes[i * 2 + 1];
            let (l, r) = self.translate_stereo_bytes(l_byte, r_byte, is_lsb_first);
            out.push(l);
            out.push(r);
        }
        out
    }
}
