pub mod ring_buffer;
pub mod tap;

#[cfg(test)]
mod tests;

pub const FFT_SIZE: usize = 2048;
pub const NUM_BANDS: usize = 64;
pub const RING_BUFFER_CAPACITY: usize = 16384;
pub const MIN_FREQ: f32 = 30.0;
pub const MAX_FREQ: f32 = 18000.0;
pub const ATTACK_COEFF: f32 = 0.70;
pub const RELEASE_COEFF: f32 = 0.88;

pub use ring_buffer::{VisualizerRingBuffer, generate_band_edges, generate_hann_window};
pub use tap::{VisualizerTap, global_tap, init_global_tap, try_global_tap};
