use serde::{Deserialize, Serialize};

// ============================================================================
// Content Fingerprint & TOC Signature
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ContentFingerprint {
    pub hash_hex: String,
    pub audio_byte_len: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct TocSignature {
    pub disc_count: u32,
    pub track_count: u32,
    pub durations_ms: Vec<u64>,
    pub digest: String,
}

impl TocSignature {
    /// Builds a deterministic TOC signature from disc count and ordered track durations (in ms).
    ///
    /// Uses a dependency-free 128-bit dual-lane FNV-1a digest prefixed with `toc1:d<discs>:n<tracks>:`
    /// so equal duration sequences always yield the same compact indexable string across platforms.
    pub fn from_durations(disc_count: u32, durations_ms: Vec<u64>) -> Self {
        let disc_count = disc_count.max(1);
        let track_count = durations_ms.len() as u32;
        let digest = compute_toc_digest(disc_count, &durations_ms);
        Self {
            disc_count,
            track_count,
            durations_ms,
            digest,
        }
    }
}

fn compute_toc_digest(disc_count: u32, durations_ms: &[u64]) -> String {
    const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut h1: u64 = 0xcbf2_9ce4_8422_2325;
    let mut h2: u64 = 0xaf63_dc4c_8601_ec8c;

    let mix = |state: &mut u64, bytes: &[u8]| {
        for &b in bytes {
            *state ^= u64::from(b);
            *state = state.wrapping_mul(FNV_PRIME);
        }
    };

    mix(&mut h1, &disc_count.to_le_bytes());
    mix(&mut h1, &(durations_ms.len() as u32).to_le_bytes());
    mix(&mut h2, &(durations_ms.len() as u32).to_be_bytes());
    mix(&mut h2, &disc_count.to_be_bytes());

    for (idx, &dur) in durations_ms.iter().enumerate() {
        mix(&mut h1, &dur.to_le_bytes());
        mix(&mut h2, &(idx as u64).to_be_bytes());
        mix(&mut h2, &dur.to_be_bytes());
    }

    format!(
        "toc1:d{disc_count}:n{}:{h1:016x}{h2:016x}",
        durations_ms.len()
    )
}
