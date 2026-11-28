use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use core_types::{L2_TAIL_FINGERPRINT_LEN, L2HeadChunkRecord, StreamKey};

use super::dash_package::DashL2Package;

/// RAII lease protecting an actively open L2 cache file against watermark eviction and orphan sweeps.
#[derive(Debug)]
pub struct L2FileLease {
    pub(super) key: StreamKey,
    pub(super) leases: Arc<Mutex<HashMap<StreamKey, usize>>>,
}

impl L2FileLease {
    /// Returns the [`StreamKey`] protected by this lease.
    pub fn key(&self) -> &StreamKey {
        &self.key
    }
}

impl Clone for L2FileLease {
    fn clone(&self) -> Self {
        if let Ok(mut map) = self.leases.lock() {
            *map.entry(self.key.clone()).or_insert(0) += 1;
        }
        Self {
            key: self.key.clone(),
            leases: Arc::clone(&self.leases),
        }
    }
}

impl Drop for L2FileLease {
    fn drop(&mut self) {
        if let Ok(mut map) = self.leases.lock()
            && let Some(count) = map.get_mut(&self.key)
        {
            if *count <= 1 {
                map.remove(&self.key);
            } else {
                *count -= 1;
            }
        }
    }
}

/// Cache hit payload for a direct or Deezer-encrypted head chunk (`.head`).
#[derive(Debug)]
pub struct L2DirectHit {
    pub record: L2HeadChunkRecord,
    pub head_bytes: Bytes,
    pub total_content_length: Option<u64>,
    pub tail_fingerprint: Vec<u8>,
    pub lease: L2FileLease,
}

impl L2DirectHit {
    /// Returns the 64-byte tail fingerprint array if the cached chunk is at least 64 bytes.
    pub fn tail_fingerprint_64(&self) -> Option<[u8; L2_TAIL_FINGERPRINT_LEN]> {
        if self.tail_fingerprint.len() == L2_TAIL_FINGERPRINT_LEN {
            let mut out = [0u8; L2_TAIL_FINGERPRINT_LEN];
            out.copy_from_slice(&self.tail_fingerprint);
            Some(out)
        } else {
            None
        }
    }
}

/// Cache hit payload for a DASH initialization + opening segments package (`.dash.head`).
#[derive(Debug)]
pub struct L2DashHit {
    pub record: L2HeadChunkRecord,
    pub package: DashL2Package,
    pub tail_fingerprint: [u8; L2_TAIL_FINGERPRINT_LEN],
    pub lease: L2FileLease,
}

/// Summary returned by [`super::L2CacheManager::enforce_watermarks`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct L2EvictionReport {
    pub evicted_entries: u64,
    pub freed_bytes: u64,
    pub skipped_in_use: u64,
    pub remaining_bytes: u64,
}

/// Summary returned by [`super::L2CacheManager::run_orphan_sweep`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct L2OrphanSweepReport {
    pub deleted_tmp_files: u64,
    pub deleted_orphan_files: u64,
    pub removed_dangling_rows: u64,
}
