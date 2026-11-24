use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{ErrorKind, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use core_db::{DbError, L2AccessUpdate, L2HeadCacheRepository, L2HeadChunkRecord, SqlitePool};
use core_types::{
    L2CacheKind, L2_DEFAULT_HIGH_WATERMARK_BYTES, L2_DEFAULT_LOW_WATERMARK_BYTES,
    L2_MAX_TARGET_BYTES, L2_TAIL_FINGERPRINT_LEN, StreamKey, StreamProviderCapabilities,
};
use sha2::{Digest, Sha256, Sha512};
use tokio::sync::Mutex as AsyncMutex;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use super::{StreamError, streaming_runtime};

/// Magic header for binary-encoded L2 DASH head packages (`.dash.head`).
pub const L2_DASH_MAGIC: &[u8; 5] = b"L2DH\x01";

/// Maximum number of media segments cached inside a [`DashL2Package`].
pub const MAX_DASH_L2_SEGMENTS: usize = 2;

static TMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(1);

fn db_err_to_stream(err: DbError) -> StreamError {
    StreamError::Io(format!("L2 cache database error: {err}"))
}

fn unix_timestamp_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn sanitize_path_component(raw: &str, max_len: usize) -> String {
    let mut out = String::with_capacity(raw.len().min(max_len));
    for ch in raw.chars() {
        if out.len() >= max_len {
            break;
        }
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        out.push('_');
    }
    out
}

/// Builds the deterministic two-level SHA-256 relative path under `<root_dir>/cache/l2/...`.
///
/// Format:
/// - `DirectHead`: `cache/l2/<provider_id>/<hash2>/<hash4>_<safe_track_id>_<safe_quality_key>.head`
/// - `DashInitSegs`: `cache/l2/<provider_id>/<hash2>/<hash4>_<safe_track_id>_<safe_quality_key>.dash.head`
pub fn build_l2_rel_path(key: &StreamKey, kind: L2CacheKind) -> String {
    let mut hasher = Sha256::new();
    hasher.update(key.provider_id.as_bytes());
    hasher.update(b":");
    hasher.update(key.track_id.as_bytes());
    hasher.update(b":");
    hasher.update(key.quality_key.as_bytes());
    let digest = hasher.finalize();

    let mut hex_full = String::with_capacity(64);
    for byte in &digest {
        let _ = write!(&mut hex_full, "{byte:02x}");
    }
    let hash2 = &hex_full[0..2];
    let hash4 = &hex_full[0..4];

    let safe_provider = sanitize_path_component(&key.provider_id, 32);
    let safe_track = sanitize_path_component(&key.track_id, 64);
    let safe_quality = sanitize_path_component(&key.quality_key, 32);
    let ext = match kind {
        L2CacheKind::DirectHead => "head",
        L2CacheKind::DashInitSegs => "dash.head",
    };

    format!("cache/l2/{safe_provider}/{hash2}/{hash4}_{safe_track}_{safe_quality}.{ext}")
}

fn rel_path_to_abs(root_dir: &Path, rel_path: &str) -> PathBuf {
    let mut path = root_dir.to_path_buf();
    for segment in rel_path.split('/') {
        if !segment.is_empty() {
            path.push(segment);
        }
    }
    path
}

fn path_to_rel_string(root_dir: &Path, abs_path: &Path) -> Option<String> {
    let rel = abs_path.strip_prefix(root_dir).ok()?;
    let mut parts = Vec::new();
    for comp in rel.components() {
        if let Component::Normal(os) = comp {
            parts.push(os.to_string_lossy().into_owned());
        } else {
            return None;
        }
    }
    Some(parts.join("/"))
}

/// Configuration for [`L2CacheManager`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct L2CacheConfig {
    pub root_dir: PathBuf,
    pub high_watermark_bytes: u64,
    pub low_watermark_bytes: u64,
    pub min_stable_play_ms: u64,
    pub access_flush_interval: Duration,
    pub orphan_sweep_delay: Duration,
}

impl Default for L2CacheConfig {
    fn default() -> Self {
        Self {
            root_dir: PathBuf::from("."),
            high_watermark_bytes: L2_DEFAULT_HIGH_WATERMARK_BYTES,
            low_watermark_bytes: L2_DEFAULT_LOW_WATERMARK_BYTES,
            min_stable_play_ms: 5_000,
            access_flush_interval: Duration::from_secs(30),
            orphan_sweep_delay: Duration::from_secs(10),
        }
    }
}

impl L2CacheConfig {
    /// Creates a new configuration anchored at `root_dir` using default Phase 4 watermarks and intervals.
    pub fn new(root_dir: impl Into<PathBuf>) -> Self {
        Self {
            root_dir: root_dir.into(),
            ..Self::default()
        }
    }

    /// Sets the high and low disk-space eviction watermarks in bytes.
    pub fn with_watermarks(mut self, high_watermark_bytes: u64, low_watermark_bytes: u64) -> Self {
        self.high_watermark_bytes = high_watermark_bytes;
        self.low_watermark_bytes = low_watermark_bytes.min(high_watermark_bytes);
        self
    }

    /// Sets the minimum stable playback duration required before unpinned L2 admission.
    pub fn with_min_stable_play_ms(mut self, min_stable_play_ms: u64) -> Self {
        self.min_stable_play_ms = min_stable_play_ms;
        self
    }

    /// Sets how often deferred access timestamps and hit counts are flushed in one transaction.
    pub fn with_access_flush_interval(mut self, interval: Duration) -> Self {
        self.access_flush_interval = interval;
        self
    }

    /// Sets the startup delay before running the background orphan file sweep.
    pub fn with_orphan_sweep_delay(mut self, delay: Duration) -> Self {
        self.orphan_sweep_delay = delay;
        self
    }
}

/// Single media segment cached inside a [`DashL2Package`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashL2SegmentEntry {
    pub number: u64,
    pub start_ms: u64,
    pub duration_ms: u64,
    pub bytes: Vec<u8>,
}

/// Binary-serializable DASH L2 head package storing `init` + up to first 2 `.m4s` segments,
/// capped at `4 MiB` total payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashL2Package {
    pub mime_type: String,
    pub codecs: Option<String>,
    pub bandwidth: Option<u64>,
    pub total_duration_ms: Option<u64>,
    pub init_bytes: Vec<u8>,
    pub segments: Vec<DashL2SegmentEntry>,
}

impl DashL2Package {
    /// Returns the total raw media payload bytes (`init_bytes + sum(segments)`).
    pub fn payload_bytes(&self) -> usize {
        self.init_bytes.len().saturating_add(
            self.segments
                .iter()
                .map(|s| s.bytes.len())
                .sum::<usize>(),
        )
    }

    /// Trims `segments` to at most 2 entries whose combined payload stays within `max_payload_bytes`.
    pub fn trim_to_budget(&mut self, max_payload_bytes: usize) {
        let cap = max_payload_bytes.min(L2_MAX_TARGET_BYTES as usize);
        if self.init_bytes.len() > cap {
            self.segments.clear();
            return;
        }
        let mut used = self.init_bytes.len();
        let mut kept = 0usize;
        for seg in self.segments.iter().take(MAX_DASH_L2_SEGMENTS) {
            if used.saturating_add(seg.bytes.len()) <= cap {
                used += seg.bytes.len();
                kept += 1;
            } else {
                break;
            }
        }
        self.segments.truncate(kept);
    }

    /// Computes a deterministic 64-byte integrity fingerprint for this package.
    pub fn tail_fingerprint(&self) -> [u8; L2_TAIL_FINGERPRINT_LEN] {
        let mut hasher = Sha512::new();
        hasher.update(L2_DASH_MAGIC);

        hasher.update((self.mime_type.len() as u32).to_le_bytes());
        hasher.update(self.mime_type.as_bytes());

        match &self.codecs {
            Some(c) => {
                hasher.update([1u8]);
                hasher.update((c.len() as u32).to_le_bytes());
                hasher.update(c.as_bytes());
            }
            None => hasher.update([0u8]),
        }

        match self.bandwidth {
            Some(bw) => {
                hasher.update([1u8]);
                hasher.update(bw.to_le_bytes());
            }
            None => hasher.update([0u8]),
        }

        match self.total_duration_ms {
            Some(dur) => {
                hasher.update([1u8]);
                hasher.update(dur.to_le_bytes());
            }
            None => hasher.update([0u8]),
        }

        hasher.update((self.init_bytes.len() as u32).to_le_bytes());
        hasher.update(&self.init_bytes);

        hasher.update([self.segments.len().min(u8::MAX as usize) as u8]);
        for seg in &self.segments {
            hasher.update(seg.number.to_le_bytes());
            hasher.update(seg.start_ms.to_le_bytes());
            hasher.update(seg.duration_ms.to_le_bytes());
            hasher.update((seg.bytes.len() as u32).to_le_bytes());
            hasher.update(&seg.bytes);
        }

        let digest = hasher.finalize();
        let mut out = [0u8; L2_TAIL_FINGERPRINT_LEN];
        out.copy_from_slice(&digest[..L2_TAIL_FINGERPRINT_LEN]);
        out
    }

    /// Serializes this package into the `L2DH\x01` binary format, enforcing max 2 segments and `4 MiB` payload.
    pub fn encode(&self) -> Result<Vec<u8>, StreamError> {
        if self.segments.len() > MAX_DASH_L2_SEGMENTS {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package supports at most {MAX_DASH_L2_SEGMENTS} segments, got {}",
                self.segments.len()
            )));
        }
        let payload_len = self.payload_bytes();
        if payload_len > L2_MAX_TARGET_BYTES as usize {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package payload {payload_len} exceeds {} byte cap",
                L2_MAX_TARGET_BYTES
            )));
        }
        if self.init_bytes.is_empty() && self.segments.is_empty() {
            return Err(StreamError::InvalidManifest(
                "DashL2Package cannot be completely empty".to_string(),
            ));
        }

        let mime_len = u32::try_from(self.mime_type.len())
            .map_err(|_| StreamError::InvalidManifest("mime_type too long".to_string()))?;
        let init_len = u32::try_from(self.init_bytes.len())
            .map_err(|_| StreamError::InvalidManifest("init_bytes too long".to_string()))?;

        let mut out = Vec::with_capacity(64 + self.mime_type.len() + payload_len);
        out.extend_from_slice(L2_DASH_MAGIC);

        out.extend_from_slice(&mime_len.to_le_bytes());
        out.extend_from_slice(self.mime_type.as_bytes());

        match &self.codecs {
            Some(codecs) => {
                let len = u32::try_from(codecs.len())
                    .map_err(|_| StreamError::InvalidManifest("codecs too long".to_string()))?;
                out.push(1);
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(codecs.as_bytes());
            }
            None => out.push(0),
        }

        match self.bandwidth {
            Some(bw) => {
                out.push(1);
                out.extend_from_slice(&bw.to_le_bytes());
            }
            None => out.push(0),
        }

        match self.total_duration_ms {
            Some(dur) => {
                out.push(1);
                out.extend_from_slice(&dur.to_le_bytes());
            }
            None => out.push(0),
        }

        out.extend_from_slice(&init_len.to_le_bytes());
        out.extend_from_slice(&self.init_bytes);

        out.push(self.segments.len() as u8);
        for seg in &self.segments {
            let seg_len = u32::try_from(seg.bytes.len())
                .map_err(|_| StreamError::InvalidManifest("segment bytes too long".to_string()))?;
            out.extend_from_slice(&seg.number.to_le_bytes());
            out.extend_from_slice(&seg.start_ms.to_le_bytes());
            out.extend_from_slice(&seg.duration_ms.to_le_bytes());
            out.extend_from_slice(&seg_len.to_le_bytes());
            out.extend_from_slice(&seg.bytes);
        }

        Ok(out)
    }

    /// Decodes a `L2DH\x01` binary package from disk bytes.
    pub fn decode(bytes: &[u8]) -> Result<Self, StreamError> {
        let mut cursor = BinaryCursor::new(bytes);
        let magic = cursor.read_exact(L2_DASH_MAGIC.len())?;
        if magic != L2_DASH_MAGIC {
            return Err(StreamError::InvalidManifest(
                "Invalid DashL2Package magic header".to_string(),
            ));
        }

        let mime_type = cursor.read_string()?;
        let codecs = if cursor.read_u8()? != 0 {
            Some(cursor.read_string()?)
        } else {
            None
        };
        let bandwidth = if cursor.read_u8()? != 0 {
            Some(cursor.read_u64_le()?)
        } else {
            None
        };
        let total_duration_ms = if cursor.read_u8()? != 0 {
            Some(cursor.read_u64_le()?)
        } else {
            None
        };

        let init_len = cursor.read_u32_le()? as usize;
        if init_len > L2_MAX_TARGET_BYTES as usize {
            return Err(StreamError::InvalidManifest(
                "DashL2Package init_bytes exceeds max cap".to_string(),
            ));
        }
        let init_bytes = cursor.read_exact(init_len)?.to_vec();

        let seg_count = cursor.read_u8()? as usize;
        if seg_count > MAX_DASH_L2_SEGMENTS {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package segment count {seg_count} exceeds max {MAX_DASH_L2_SEGMENTS}"
            )));
        }

        let mut total_payload = init_bytes.len();
        let mut segments = Vec::with_capacity(seg_count);
        for _ in 0..seg_count {
            let number = cursor.read_u64_le()?;
            let start_ms = cursor.read_u64_le()?;
            let duration_ms = cursor.read_u64_le()?;
            let seg_len = cursor.read_u32_le()? as usize;
            total_payload = total_payload.saturating_add(seg_len);
            if total_payload > L2_MAX_TARGET_BYTES as usize {
                return Err(StreamError::InvalidManifest(
                    "DashL2Package payload exceeds 4 MiB cap".to_string(),
                ));
            }
            let seg_bytes = cursor.read_exact(seg_len)?.to_vec();
            segments.push(DashL2SegmentEntry {
                number,
                start_ms,
                duration_ms,
                bytes: seg_bytes,
            });
        }

        if cursor.remaining() != 0 {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package has {} trailing bytes",
                cursor.remaining()
            )));
        }

        Ok(Self {
            mime_type,
            codecs,
            bandwidth,
            total_duration_ms,
            init_bytes,
            segments,
        })
    }
}

struct BinaryCursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> BinaryCursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8], StreamError> {
        let end = self.pos.checked_add(len).ok_or_else(|| {
            StreamError::InvalidManifest("DashL2Package offset overflow".to_string())
        })?;
        if end > self.data.len() {
            return Err(StreamError::InvalidManifest(
                "Unexpected EOF decoding DashL2Package".to_string(),
            ));
        }
        let slice = &self.data[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn read_u8(&mut self) -> Result<u8, StreamError> {
        Ok(self.read_exact(1)?[0])
    }

    fn read_u32_le(&mut self) -> Result<u32, StreamError> {
        let bytes = self.read_exact(4)?;
        Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn read_u64_le(&mut self) -> Result<u64, StreamError> {
        let bytes = self.read_exact(8)?;
        Ok(u64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]))
    }

    fn read_string(&mut self) -> Result<String, StreamError> {
        let len = self.read_u32_le()? as usize;
        if len > L2_MAX_TARGET_BYTES as usize {
            return Err(StreamError::InvalidManifest(
                "DashL2Package string field too large".to_string(),
            ));
        }
        let raw = self.read_exact(len)?;
        std::str::from_utf8(raw)
            .map(str::to_string)
            .map_err(|e| StreamError::InvalidManifest(format!("Invalid UTF-8 in DashL2Package: {e}")))
    }
}

/// Validates whether a stream qualifies for L2 persistent head-chunk admission.
///
/// Rejects providers without L2 support (`apple_music`, `local`, unknown), containers whose seek
/// table sits at EOF or beyond `target_bytes`, and unpinned plays shorter than `min_stable_play_ms`.
pub fn should_admit_to_l2(
    key: &StreamKey,
    target_bytes: u64,
    played_ms: u64,
    min_stable_play_ms: u64,
    pin_level: i64,
    index_range_end: Option<u64>,
    seek_table_at_eof: bool,
) -> bool {
    if target_bytes == 0 {
        return false;
    }
    if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
        return false;
    }
    if seek_table_at_eof {
        return false;
    }
    if let Some(idx_end) = index_range_end
        && idx_end > target_bytes
    {
        return false;
    }
    pin_level > 0 || played_ms >= min_stable_play_ms
}

/// RAII lease protecting an actively open L2 cache file against watermark eviction and orphan sweeps.
#[derive(Debug)]
pub struct L2FileLease {
    key: StreamKey,
    leases: Arc<Mutex<HashMap<StreamKey, usize>>>,
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

/// Summary returned by [`L2CacheManager::enforce_watermarks`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct L2EvictionReport {
    pub evicted_entries: u64,
    pub freed_bytes: u64,
    pub skipped_in_use: u64,
    pub remaining_bytes: u64,
}

/// Summary returned by [`L2CacheManager::run_orphan_sweep`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct L2OrphanSweepReport {
    pub deleted_tmp_files: u64,
    pub deleted_orphan_files: u64,
    pub removed_dangling_rows: u64,
}

#[derive(Clone)]
struct SharedL2State {
    pool: SqlitePool,
    config: L2CacheConfig,
    active_leases: Arc<Mutex<HashMap<StreamKey, usize>>>,
    pending_access: Arc<Mutex<HashMap<StreamKey, L2AccessUpdate>>>,
    eviction_lock: Arc<AsyncMutex<()>>,
    cancel: CancellationToken,
}

/// Disk + SQLite L2 head-chunk cache manager with atomic `.tmp -> rename` writes, batched
/// access-timestamp flushing, dual-watermark eviction, lease protection, and orphan sweeping.
pub struct L2CacheManager {
    state: SharedL2State,
    bg_handles: Mutex<Vec<JoinHandle<()>>>,
}

impl L2CacheManager {
    /// Initializes the L2 cache manager and starts background access-flush and delayed orphan-sweep
    /// tasks when a Tokio runtime is available.
    pub fn new(pool: SqlitePool, mut config: L2CacheConfig) -> Result<Self, StreamError> {
        config.low_watermark_bytes = config.low_watermark_bytes.min(config.high_watermark_bytes);
        fs::create_dir_all(&config.root_dir)?;

        let state = SharedL2State {
            pool,
            config,
            active_leases: Arc::new(Mutex::new(HashMap::new())),
            pending_access: Arc::new(Mutex::new(HashMap::new())),
            eviction_lock: Arc::new(AsyncMutex::new(())),
            cancel: CancellationToken::new(),
        };

        let mut handles = Vec::new();
        let rt_handle = tokio::runtime::Handle::try_current()
            .ok()
            .or_else(|| streaming_runtime().ok().map(|rt| rt.handle().clone()));

        if let Some(handle) = rt_handle {
            let flush_state = state.clone();
            let flush_interval = flush_state.config.access_flush_interval;
            if !flush_interval.is_zero() {
                handles.push(handle.spawn(async move {
                    loop {
                        tokio::select! {
                            biased;
                            _ = flush_state.cancel.cancelled() => break,
                            _ = tokio::time::sleep(flush_interval) => {
                                let _ = flush_pending_access_inner(&flush_state).await;
                            }
                        }
                    }
                }));
            }

            let sweep_state = state.clone();
            let sweep_delay = sweep_state.config.orphan_sweep_delay;
            handles.push(handle.spawn(async move {
                if !sweep_delay.is_zero() {
                    tokio::select! {
                        biased;
                        _ = sweep_state.cancel.cancelled() => return,
                        _ = tokio::time::sleep(sweep_delay) => {}
                    }
                }
                if !sweep_state.cancel.is_cancelled() {
                    let _ = run_orphan_sweep_inner(&sweep_state).await;
                }
            }));
        }

        Ok(Self {
            state,
            bg_handles: Mutex::new(handles),
        })
    }

    /// Returns a reference to the active [`L2CacheConfig`].
    pub fn config(&self) -> &L2CacheConfig {
        &self.state.config
    }

    /// Returns a reference to the backing [`SqlitePool`].
    pub fn pool(&self) -> &SqlitePool {
        &self.state.pool
    }

    /// Resolves a relative L2 path into an absolute filesystem path under `config.root_dir`.
    pub fn resolve_rel_path(&self, rel_path: &str) -> PathBuf {
        rel_path_to_abs(&self.state.config.root_dir, rel_path)
    }

    /// Acquires an RAII [`L2FileLease`] protecting `key` from eviction and orphan deletion.
    pub fn acquire_lease(&self, key: &StreamKey) -> L2FileLease {
        if let Ok(mut map) = self.state.active_leases.lock() {
            *map.entry(key.clone()).or_insert(0) += 1;
        }
        L2FileLease {
            key: key.clone(),
            leases: Arc::clone(&self.state.active_leases),
        }
    }

    /// Returns `true` if one or more active [`L2FileLease`] guards currently hold `key`.
    pub fn is_in_use(&self, key: &StreamKey) -> bool {
        self.state
            .active_leases
            .lock()
            .map(|map| map.get(key).copied().unwrap_or(0) > 0)
            .unwrap_or(false)
    }

    /// Atomically persists a raw direct (or Deezer encrypted) head buffer to disk and SQLite,
    /// enforcing high/low watermarks afterward.
    pub async fn store_direct_head(
        &self,
        key: &StreamKey,
        data: &[u8],
        total_content_length: Option<u64>,
        pin_level: i64,
    ) -> Result<Option<L2HeadChunkRecord>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }
        if data.is_empty() {
            return Ok(None);
        }
        if data.len() as u64 > L2_MAX_TARGET_BYTES {
            return Err(StreamError::Unsupported(format!(
                "L2 direct head chunk size {} exceeds {} byte cap",
                data.len(),
                L2_MAX_TARGET_BYTES
            )));
        }

        let _write_lease = self.acquire_lease(key);
        let fp_len = data.len().min(L2_TAIL_FINGERPRINT_LEN);
        let tail_fingerprint = data[data.len() - fp_len..].to_vec();
        let bytes = Bytes::copy_from_slice(data);
        let cached_bytes = bytes.len() as i64;
        let rel_path = build_l2_rel_path(key, L2CacheKind::DirectHead);
        let abs_path = self.resolve_rel_path(&rel_path);

        write_file_atomic(abs_path.clone(), bytes).await?;

        let now = unix_timestamp_secs();
        let record = L2HeadChunkRecord {
            provider_id: key.provider_id.clone(),
            track_id: key.track_id.clone(),
            quality_key: key.quality_key.clone(),
            cache_kind: L2CacheKind::DirectHead.as_str().to_string(),
            file_rel_path: rel_path,
            cached_bytes,
            total_content_length: total_content_length.map(|v| v as i64),
            tail_fingerprint,
            pin_level,
            last_accessed_at: now,
            access_count: 1,
            created_at: now,
        };

        if let Err(err) = L2HeadCacheRepository::upsert(&self.state.pool, &record).await {
            let _ = remove_file_if_exists(abs_path).await;
            return Err(db_err_to_stream(err));
        }

        self.clear_pending_access(key);
        drop(_write_lease);
        let _ = self.enforce_watermarks().await?;
        Ok(Some(record))
    }

    /// Atomically persists a [`DashL2Package`] (`init` + up to 2 segments, capped at `4 MiB`)
    /// to disk and SQLite, enforcing high/low watermarks afterward.
    pub async fn store_dash_head(
        &self,
        key: &StreamKey,
        pkg: &DashL2Package,
        pin_level: i64,
    ) -> Result<Option<L2HeadChunkRecord>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }
        if pkg.init_bytes.is_empty() && pkg.segments.is_empty() {
            return Ok(None);
        }

        let _write_lease = self.acquire_lease(key);
        let encoded = pkg.encode()?;
        let tail_fingerprint = pkg.tail_fingerprint().to_vec();
        let cached_bytes = encoded.len() as i64;
        let rel_path = build_l2_rel_path(key, L2CacheKind::DashInitSegs);
        let abs_path = self.resolve_rel_path(&rel_path);

        write_file_atomic(abs_path.clone(), Bytes::from(encoded)).await?;

        let now = unix_timestamp_secs();
        let record = L2HeadChunkRecord {
            provider_id: key.provider_id.clone(),
            track_id: key.track_id.clone(),
            quality_key: key.quality_key.clone(),
            cache_kind: L2CacheKind::DashInitSegs.as_str().to_string(),
            file_rel_path: rel_path,
            cached_bytes,
            total_content_length: None,
            tail_fingerprint,
            pin_level,
            last_accessed_at: now,
            access_count: 1,
            created_at: now,
        };

        if let Err(err) = L2HeadCacheRepository::upsert(&self.state.pool, &record).await {
            let _ = remove_file_if_exists(abs_path).await;
            return Err(db_err_to_stream(err));
        }

        self.clear_pending_access(key);
        drop(_write_lease);
        let _ = self.enforce_watermarks().await?;
        Ok(Some(record))
    }

    /// Looks up a cached direct head chunk, acquiring an [`L2FileLease`] before reading disk bytes,
    /// verifying size and tail fingerprint, and queuing access stats in memory without writing SQLite.
    pub async fn lookup_direct_head(
        &self,
        key: &StreamKey,
    ) -> Result<Option<L2DirectHit>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }

        let lease = self.acquire_lease(key);
        let Some(record) = L2HeadCacheRepository::get(&self.state.pool, key)
            .await
            .map_err(db_err_to_stream)?
        else {
            return Ok(None);
        };

        if L2CacheKind::parse(&record.cache_kind) != Some(L2CacheKind::DirectHead) {
            return Ok(None);
        }

        let abs_path = self.resolve_rel_path(&record.file_rel_path);
        let raw_bytes = match read_file_bytes(abs_path.clone()).await {
            Ok(Some(b)) => b,
            Ok(None) => {
                let _ = L2HeadCacheRepository::delete(&self.state.pool, key).await;
                return Ok(None);
            }
            Err(e) => return Err(e),
        };

        let expected_len = record.cached_bytes.max(0) as usize;
        let fp = &record.tail_fingerprint;
        let tail_ok = raw_bytes.len() == expected_len
            && !fp.is_empty()
            && raw_bytes.len() >= fp.len()
            && &raw_bytes[raw_bytes.len() - fp.len()..] == fp.as_slice();

        if !tail_ok {
            let _ = L2HeadCacheRepository::delete(&self.state.pool, key).await;
            let _ = remove_file_if_exists(abs_path).await;
            return Ok(None);
        }

        self.record_pending_access(key);
        let total_content_length = record
            .total_content_length
            .and_then(|v| u64::try_from(v).ok());
        let tail_fingerprint = record.tail_fingerprint.clone();

        Ok(Some(L2DirectHit {
            record,
            head_bytes: raw_bytes,
            total_content_length,
            tail_fingerprint,
            lease,
        }))
    }

    /// Looks up a cached DASH head package, acquiring an [`L2FileLease`] before reading disk bytes,
    /// decoding & verifying the integrity fingerprint, and queuing access stats in memory.
    pub async fn lookup_dash_head(&self, key: &StreamKey) -> Result<Option<L2DashHit>, StreamError> {
        if !StreamProviderCapabilities::for_provider(&key.provider_id).supports_l2_head_cache {
            return Ok(None);
        }

        let lease = self.acquire_lease(key);
        let Some(record) = L2HeadCacheRepository::get(&self.state.pool, key)
            .await
            .map_err(db_err_to_stream)?
        else {
            return Ok(None);
        };

        if L2CacheKind::parse(&record.cache_kind) != Some(L2CacheKind::DashInitSegs) {
            return Ok(None);
        }

        let abs_path = self.resolve_rel_path(&record.file_rel_path);
        let raw_bytes = match read_file_bytes(abs_path.clone()).await {
            Ok(Some(b)) => b,
            Ok(None) => {
                let _ = L2HeadCacheRepository::delete(&self.state.pool, key).await;
                return Ok(None);
            }
            Err(e) => return Err(e),
        };

        let expected_len = record.cached_bytes.max(0) as usize;
        let decoded = if raw_bytes.len() == expected_len {
            DashL2Package::decode(&raw_bytes).ok()
        } else {
            None
        };

        let Some(package) = decoded else {
            let _ = L2HeadCacheRepository::delete(&self.state.pool, key).await;
            let _ = remove_file_if_exists(abs_path).await;
            return Ok(None);
        };

        let tail_fingerprint = package.tail_fingerprint();
        if tail_fingerprint.as_slice() != record.tail_fingerprint.as_slice() {
            let _ = L2HeadCacheRepository::delete(&self.state.pool, key).await;
            let _ = remove_file_if_exists(abs_path).await;
            return Ok(None);
        }

        self.record_pending_access(key);
        Ok(Some(L2DashHit {
            record,
            package,
            tail_fingerprint,
            lease,
        }))
    }

    /// Deletes the SQLite metadata row (first) and backing `.head`/`.dash.head` file on disk.
    pub async fn delete_entry(&self, key: &StreamKey) -> Result<bool, StreamError> {
        self.clear_pending_access(key);
        let existing = L2HeadCacheRepository::get(&self.state.pool, key)
            .await
            .map_err(db_err_to_stream)?;
        let deleted_row = L2HeadCacheRepository::delete(&self.state.pool, key)
            .await
            .map_err(db_err_to_stream)?;

        let mut removed_file = false;
        if let Some(rec) = existing {
            removed_file = remove_file_if_exists(self.resolve_rel_path(&rec.file_rel_path)).await?;
        } else {
            for kind in [L2CacheKind::DirectHead, L2CacheKind::DashInitSegs] {
                let rel = build_l2_rel_path(key, kind);
                if remove_file_if_exists(self.resolve_rel_path(&rel)).await? {
                    removed_file = true;
                }
            }
        }
        Ok(deleted_row || removed_file)
    }

    /// Flushes all buffered in-memory access timestamp/count increments in a single SQLite transaction.
    pub async fn flush_pending_access(&self) -> Result<u64, StreamError> {
        flush_pending_access_inner(&self.state).await
    }

    /// Enforces the dual-watermark policy: when total bytes exceed `high_watermark_bytes`, evicts
    /// unleased entries ordered by `(pin_level ASC, last_accessed_at ASC, created_at ASC)` down to
    /// `low_watermark_bytes` (deleting SQLite rows before unlinking disk files).
    pub async fn enforce_watermarks(&self) -> Result<L2EvictionReport, StreamError> {
        let _guard = self.state.eviction_lock.lock().await;
        let mut total_bytes = L2HeadCacheRepository::total_cached_bytes(&self.state.pool)
            .await
            .map_err(db_err_to_stream)?;

        if total_bytes <= self.state.config.high_watermark_bytes {
            return Ok(L2EvictionReport {
                evicted_entries: 0,
                freed_bytes: 0,
                skipped_in_use: 0,
                remaining_bytes: total_bytes,
            });
        }

        let candidates = L2HeadCacheRepository::list_eviction_candidates(&self.state.pool, 1024)
            .await
            .map_err(db_err_to_stream)?;

        let mut evicted_entries = 0u64;
        let mut freed_bytes = 0u64;
        let mut skipped_in_use = 0u64;

        for candidate in candidates {
            if total_bytes <= self.state.config.low_watermark_bytes {
                break;
            }
            let key = candidate.stream_key();
            if self.is_in_use(&key) {
                skipped_in_use += 1;
                continue;
            }

            // Delete SQLite metadata first so a crash never leaves a dangling index pointing to missing bytes.
            let deleted = L2HeadCacheRepository::delete(&self.state.pool, &key)
                .await
                .map_err(db_err_to_stream)?;
            self.clear_pending_access(&key);

            let abs_path = self.resolve_rel_path(&candidate.file_rel_path);
            let _ = remove_file_if_exists(abs_path).await?;

            if deleted {
                let bytes = candidate.cached_bytes.max(0) as u64;
                total_bytes = total_bytes.saturating_sub(bytes);
                evicted_entries += 1;
                freed_bytes = freed_bytes.saturating_add(bytes);
            }
        }

        let remaining_bytes = L2HeadCacheRepository::total_cached_bytes(&self.state.pool)
            .await
            .map_err(db_err_to_stream)?;

        Ok(L2EvictionReport {
            evicted_entries,
            freed_bytes,
            skipped_in_use,
            remaining_bytes,
        })
    }

    /// Sweeps stale `.tmp` files, unreferenced `.head`/`.dash.head` files, and dangling SQLite rows.
    pub async fn run_orphan_sweep(&self) -> Result<L2OrphanSweepReport, StreamError> {
        run_orphan_sweep_inner(&self.state).await
    }

    /// Cancels background tasks and flushes all pending access updates to SQLite.
    pub async fn shutdown(&self) -> Result<(), StreamError> {
        self.state.cancel.cancel();
        let handles = {
            self.bg_handles
                .lock()
                .map(|mut g| std::mem::take(&mut *g))
                .unwrap_or_default()
        };
        for handle in handles {
            let _ = handle.await;
        }
        let _ = self.flush_pending_access().await?;
        Ok(())
    }

    fn record_pending_access(&self, key: &StreamKey) {
        let now = unix_timestamp_secs();
        if let Ok(mut pending) = self.state.pending_access.lock() {
            pending
                .entry(key.clone())
                .and_modify(|update| {
                    update.last_accessed_at = update.last_accessed_at.max(now);
                    update.access_delta = update.access_delta.saturating_add(1);
                })
                .or_insert(L2AccessUpdate {
                    key: key.clone(),
                    last_accessed_at: now,
                    access_delta: 1,
                });
        }
    }

    fn clear_pending_access(&self, key: &StreamKey) {
        if let Ok(mut pending) = self.state.pending_access.lock() {
            pending.remove(key);
        }
    }
}

impl Drop for L2CacheManager {
    fn drop(&mut self) {
        self.state.cancel.cancel();
    }
}

async fn flush_pending_access_inner(state: &SharedL2State) -> Result<u64, StreamError> {
    let updates: Vec<L2AccessUpdate> = {
        let mut pending = state
            .pending_access
            .lock()
            .map_err(|_| StreamError::Io("L2 pending_access lock poisoned".to_string()))?;
        if pending.is_empty() {
            return Ok(0);
        }
        pending.drain().map(|(_, v)| v).collect()
    };

    match L2HeadCacheRepository::batch_update_access(&state.pool, &updates).await {
        Ok(affected) => Ok(affected),
        Err(err) => {
            if let Ok(mut pending) = state.pending_access.lock() {
                for update in updates {
                    pending
                        .entry(update.key.clone())
                        .and_modify(|cur| {
                            cur.last_accessed_at = cur.last_accessed_at.max(update.last_accessed_at);
                            cur.access_delta = cur.access_delta.saturating_add(update.access_delta);
                        })
                        .or_insert(update);
                }
            }
            Err(db_err_to_stream(err))
        }
    }
}

async fn run_orphan_sweep_inner(state: &SharedL2State) -> Result<L2OrphanSweepReport, StreamError> {
    let records = L2HeadCacheRepository::list_all_records(&state.pool)
        .await
        .map_err(db_err_to_stream)?;

    let known_rel_paths: HashSet<String> = records
        .iter()
        .map(|r| r.file_rel_path.clone())
        .collect();

    let leased_rel_paths: HashSet<String> = {
        let guard = state
            .active_leases
            .lock()
            .map_err(|_| StreamError::Io("L2 active_leases lock poisoned".to_string()))?;
        let mut paths = HashSet::with_capacity(guard.len() * 2);
        for key in guard.keys() {
            paths.insert(build_l2_rel_path(key, L2CacheKind::DirectHead));
            paths.insert(build_l2_rel_path(key, L2CacheKind::DashInitSegs));
        }
        paths
    };

    let root_dir = state.config.root_dir.clone();
    let (deleted_tmp_files, deleted_orphan_files) = tokio::task::spawn_blocking(move || {
        sweep_disk_files(&root_dir, &known_rel_paths, &leased_rel_paths)
    })
    .await
    .map_err(|e| StreamError::Io(format!("L2 orphan sweep task panicked: {e}")))??;

    let mut removed_dangling_rows = 0u64;
    for rec in records {
        let abs_path = rel_path_to_abs(&state.config.root_dir, &rec.file_rel_path);
        let exists = tokio::task::spawn_blocking(move || abs_path.is_file())
            .await
            .unwrap_or(false);
        if !exists
            && L2HeadCacheRepository::delete(&state.pool, &rec.stream_key())
                .await
                .map_err(db_err_to_stream)?
        {
            removed_dangling_rows += 1;
        }
    }

    Ok(L2OrphanSweepReport {
        deleted_tmp_files,
        deleted_orphan_files,
        removed_dangling_rows,
    })
}

fn sweep_disk_files(
    root_dir: &Path,
    known_rel_paths: &HashSet<String>,
    leased_rel_paths: &HashSet<String>,
) -> Result<(u64, u64), StreamError> {
    let l2_dir = root_dir.join("cache").join("l2");
    if !l2_dir.exists() {
        return Ok((0, 0));
    }

    let mut deleted_tmp = 0u64;
    let mut deleted_orphans = 0u64;
    let mut dirs = vec![l2_dir];

    while let Some(dir) = dirs.pop() {
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            if meta.is_dir() {
                dirs.push(path);
                continue;
            }
            if !meta.is_file() {
                continue;
            }
            let file_name = entry.file_name().to_string_lossy().into_owned();
            if file_name.contains(".tmp.") || file_name.ends_with(".tmp") {
                if let Some(rel) = path_to_rel_string(root_dir, &path) {
                    let base_rel = rel
                        .split_once(".tmp")
                        .map(|(prefix, _)| prefix.to_string())
                        .unwrap_or(rel);
                    if leased_rel_paths.contains(&base_rel) {
                        continue;
                    }
                }
                if fs::remove_file(&path).is_ok() {
                    deleted_tmp += 1;
                }
                continue;
            }
            if file_name.ends_with(".head")
                && let Some(rel) = path_to_rel_string(root_dir, &path)
                && !known_rel_paths.contains(&rel)
                && !leased_rel_paths.contains(&rel)
                && fs::remove_file(&path).is_ok()
            {
                deleted_orphans += 1;
            }
        }
    }

    Ok((deleted_tmp, deleted_orphans))
}

async fn write_file_atomic(abs_path: PathBuf, data: Bytes) -> Result<(), StreamError> {
    tokio::task::spawn_blocking(move || -> Result<(), StreamError> {
        let parent = abs_path.parent().ok_or_else(|| {
            StreamError::Io(format!("Invalid L2 cache file path: {}", abs_path.display()))
        })?;
        fs::create_dir_all(parent)?;

        let file_name = abs_path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| {
                StreamError::Io(format!("Invalid L2 cache filename: {}", abs_path.display()))
            })?;
        let seq = TMP_FILE_COUNTER.fetch_add(1, Ordering::SeqCst);
        let tmp_path = parent.join(format!("{file_name}.tmp.{}.{seq}", std::process::id()));

        {
            let mut file = File::create(&tmp_path)?;
            file.write_all(&data)?;
            file.sync_all()?;
        }

        if let Err(err) = fs::rename(&tmp_path, &abs_path) {
            let _ = fs::remove_file(&tmp_path);
            return Err(StreamError::Io(format!(
                "Failed to atomically rename L2 temp file '{}' -> '{}': {err}",
                tmp_path.display(),
                abs_path.display()
            )));
        }
        Ok(())
    })
    .await
    .map_err(|e| StreamError::Io(format!("L2 atomic write task failed: {e}")))?
}

async fn read_file_bytes(abs_path: PathBuf) -> Result<Option<Bytes>, StreamError> {
    tokio::task::spawn_blocking(move || match fs::read(&abs_path) {
        Ok(bytes) => Ok(Some(Bytes::from(bytes))),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(None),
        Err(err) => Err(StreamError::Io(format!(
            "Failed reading L2 file '{}': {err}",
            abs_path.display()
        ))),
    })
    .await
    .map_err(|e| StreamError::Io(format!("L2 read task failed: {e}")))?
}

async fn remove_file_if_exists(abs_path: PathBuf) -> Result<bool, StreamError> {
    tokio::task::spawn_blocking(move || match fs::remove_file(&abs_path) {
        Ok(()) => Ok(true),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(false),
        Err(err) => Err(StreamError::Io(format!(
            "Failed deleting L2 file '{}': {err}",
            abs_path.display()
        ))),
    })
    .await
    .map_err(|e| StreamError::Io(format!("L2 delete task failed: {e}")))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use core_db::open_test_database;
    use core_types::{L2_DEEZER_STRIPE_ALIGNMENT, L2_MIN_TARGET_BYTES, compute_l2_target_bytes};
    use tempfile::TempDir;

    fn test_config(dir: &TempDir) -> L2CacheConfig {
        L2CacheConfig::new(dir.path())
            .with_access_flush_interval(Duration::from_secs(3600))
            .with_orphan_sweep_delay(Duration::from_secs(3600))
    }

    #[test]
    fn test_two_level_hash_paths_and_sanitization() {
        let key = StreamKey::new("qobuz", "track/12:34?", "hi_res:192");
        let direct_rel = build_l2_rel_path(&key, L2CacheKind::DirectHead);
        let dash_rel = build_l2_rel_path(&key, L2CacheKind::DashInitSegs);

        let mut hasher = Sha256::new();
        hasher.update(b"qobuz:track/12:34?:hi_res:192");
        let digest = hasher.finalize();
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        let h2 = &hex[0..2];
        let h4 = &hex[0..4];

        assert_eq!(
            direct_rel,
            format!("cache/l2/qobuz/{h2}/{h4}_track_12_34__hi_res_192.head")
        );
        assert_eq!(
            dash_rel,
            format!("cache/l2/qobuz/{h2}/{h4}_track_12_34__hi_res_192.dash.head")
        );
    }

    #[test]
    fn test_dynamic_target_bytes_and_admission_gate() {
        assert_eq!(
            compute_l2_target_bytes("youtube_music", Some(128_000), Some(4_000_000), false),
            L2_MIN_TARGET_BYTES
        );
        assert_eq!(
            compute_l2_target_bytes("qobuz", Some(4_608_000), Some(80_000_000), false),
            L2_MAX_TARGET_BYTES
        );
        let dz = compute_l2_target_bytes("deezer", Some(1_411_200), Some(30_000_000), false);
        assert_eq!(dz % L2_DEEZER_STRIPE_ALIGNMENT, 0);

        let apple_key = StreamKey::new("apple_music", "999", "lossless");
        assert!(!should_admit_to_l2(
            &apple_key, 524_288, 15_000, 5_000, 1, None, false
        ));

        let local_key = StreamKey::new("local", "/music/a.flac", "native");
        assert!(!should_admit_to_l2(
            &local_key, 524_288, 15_000, 5_000, 1, None, false
        ));

        let ytm_key = StreamKey::new("youtube_music", "abc", "opus_160");
        // Short skip (< min_stable_play_ms) rejected unless pinned
        assert!(!should_admit_to_l2(
            &ytm_key, 524_288, 2_500, 5_000, 0, Some(1_200), false
        ));
        assert!(should_admit_to_l2(
            &ytm_key, 524_288, 2_500, 5_000, 1, Some(1_200), false
        ));
        // Index beyond target_bytes or seek table at EOF rejected
        assert!(!should_admit_to_l2(
            &ytm_key,
            524_288,
            10_000,
            5_000,
            0,
            Some(600_000),
            false
        ));
        assert!(!should_admit_to_l2(
            &ytm_key, 524_288, 10_000, 5_000, 0, None, true
        ));
        assert!(should_admit_to_l2(
            &ytm_key,
            524_288,
            5_000,
            5_000,
            0,
            Some(1_105),
            false
        ));
    }

    #[test]
    fn test_dash_l2_package_binary_roundtrip_and_caps() {
        let pkg = DashL2Package {
            mime_type: "audio/mp4".to_string(),
            codecs: Some("flac".to_string()),
            bandwidth: Some(2_400_000),
            total_duration_ms: Some(180_000),
            init_bytes: vec![0xAA; 1024],
            segments: vec![
                DashL2SegmentEntry {
                    number: 1,
                    start_ms: 0,
                    duration_ms: 4_000,
                    bytes: vec![0x11; 4096],
                },
                DashL2SegmentEntry {
                    number: 2,
                    start_ms: 4_000,
                    duration_ms: 4_000,
                    bytes: vec![0x22; 4096],
                },
            ],
        };

        let encoded = pkg.encode().unwrap();
        assert!(encoded.starts_with(L2_DASH_MAGIC));
        let decoded = DashL2Package::decode(&encoded).unwrap();
        assert_eq!(decoded, pkg);
        assert_eq!(decoded.tail_fingerprint(), pkg.tail_fingerprint());

        // >2 segments must be rejected by encode()
        let mut too_many = pkg.clone();
        too_many.segments.push(DashL2SegmentEntry {
            number: 3,
            start_ms: 8_000,
            duration_ms: 4_000,
            bytes: vec![0x33; 128],
        });
        assert!(too_many.encode().is_err());

        // >4 MiB payload must be rejected by encode(), and trim_to_budget caps it cleanly
        let mut huge = DashL2Package {
            mime_type: "audio/mp4".to_string(),
            codecs: Some("flac".to_string()),
            bandwidth: Some(4_600_000),
            total_duration_ms: Some(240_000),
            init_bytes: vec![0x01; 1024],
            segments: vec![
                DashL2SegmentEntry {
                    number: 1,
                    start_ms: 0,
                    duration_ms: 4_000,
                    bytes: vec![0x02; 2_500_000],
                },
                DashL2SegmentEntry {
                    number: 2,
                    start_ms: 4_000,
                    duration_ms: 4_000,
                    bytes: vec![0x03; 2_500_000],
                },
            ],
        };
        assert!(huge.encode().is_err());
        huge.trim_to_budget(L2_MAX_TARGET_BYTES as usize);
        assert_eq!(huge.segments.len(), 1);
        assert!(huge.encode().is_ok());
    }

    #[tokio::test]
    async fn test_atomic_store_lookup_deferred_access_flush_and_apple_skip() {
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();
        let mgr = L2CacheManager::new(pool.clone(), test_config(&tmp)).unwrap();

        let apple_key = StreamKey::new("apple_music", "123", "lossless");
        assert!(
            mgr.store_direct_head(&apple_key, &[1u8; 512], Some(1000), 0)
                .await
                .unwrap()
                .is_none()
        );

        let key = StreamKey::new("qobuz", "777", "27");
        let payload: Vec<u8> = (0..1024).map(|i| (i % 251) as u8).collect();
        let stored = mgr
            .store_direct_head(&key, &payload, Some(10_000_000), 0)
            .await
            .unwrap()
            .expect("qobuz entry must store");

        let abs_path = mgr.resolve_rel_path(&stored.file_rel_path);
        assert!(abs_path.is_file());
        assert_eq!(stored.tail_fingerprint, payload[payload.len() - 64..]);

        // Hot lookup must NOT synchronously update SQLite access_count.
        let hit1 = mgr.lookup_direct_head(&key).await.unwrap().unwrap();
        assert_eq!(&hit1.head_bytes[..], &payload[..]);
        assert!(mgr.is_in_use(&key));
        let row_before_flush = L2HeadCacheRepository::get(&pool, &key).await.unwrap().unwrap();
        assert_eq!(row_before_flush.access_count, 1);

        drop(hit1);
        assert!(!mgr.is_in_use(&key));

        let hit2 = mgr.lookup_direct_head(&key).await.unwrap().unwrap();
        drop(hit2);

        // Batch flush persists both hits in a single transaction.
        let flushed = mgr.flush_pending_access().await.unwrap();
        assert_eq!(flushed, 1);
        let row_after_flush = L2HeadCacheRepository::get(&pool, &key).await.unwrap().unwrap();
        assert_eq!(row_after_flush.access_count, 3);

        mgr.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_dual_watermark_eviction_skips_leased_and_pinned() {
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();
        let cfg = test_config(&tmp).with_watermarks(2500, 1500);
        let mgr = L2CacheManager::new(pool.clone(), cfg).unwrap();

        let k_leased = StreamKey::new("qobuz", "t_leased", "27");
        let k_old_unleased = StreamKey::new("qobuz", "t_old", "27");
        let k_pinned = StreamKey::new("tidal", "t_pinned", "HI_RES");
        let k_newest = StreamKey::new("deezer", "t_new", "FLAC");

        mgr.store_direct_head(&k_leased, &vec![1u8; 700], Some(9000), 0)
            .await
            .unwrap();
        mgr.store_direct_head(&k_old_unleased, &vec![2u8; 900], Some(9000), 0)
            .await
            .unwrap();
        mgr.store_direct_head(&k_pinned, &vec![3u8; 400], Some(9000), 1)
            .await
            .unwrap();

        // Set explicit last_accessed_at timestamps directly via repository so eviction ordering
        // is deterministic (pinned=50, leased=100, old=200).
        for (key, ts) in [(&k_leased, 100i64), (&k_old_unleased, 200), (&k_pinned, 50)] {
            let mut rec = L2HeadCacheRepository::get(&pool, key).await.unwrap().unwrap();
            rec.last_accessed_at = ts;
            L2HeadCacheRepository::upsert(&pool, &rec).await.unwrap();
        }

        let lease = mgr.acquire_lease(&k_leased);

        // Storing k_newest (800 bytes) pushes total = 700 + 900 + 400 + 800 = 2800 > 2500 high watermark.
        // k_leased (700) is skipped due to active lease -> k_old_unleased (900) and k_newest (800) are evicted
        // -> remaining = 2800 - 1700 = 1100 <= 1500 low watermark, so k_pinned (400) survives!
        mgr.store_direct_head(&k_newest, &vec![4u8; 800], Some(9000), 0)
            .await
            .unwrap();

        // Leased and pinned entries MUST survive.
        assert!(L2HeadCacheRepository::get(&pool, &k_leased).await.unwrap().is_some());
        assert!(L2HeadCacheRepository::get(&pool, &k_pinned).await.unwrap().is_some());
        // Unleased oldest MUST be evicted.
        assert!(
            L2HeadCacheRepository::get(&pool, &k_old_unleased)
                .await
                .unwrap()
                .is_none()
        );
        let old_file = mgr.resolve_rel_path(&build_l2_rel_path(&k_old_unleased, L2CacheKind::DirectHead));
        assert!(!old_file.exists());

        drop(lease);
        let report = mgr.enforce_watermarks().await.unwrap();
        assert!(report.remaining_bytes <= 1500);
        assert!(L2HeadCacheRepository::get(&pool, &k_pinned).await.unwrap().is_some());

        mgr.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_orphan_sweep_cleans_tmp_unreferenced_and_dangling_rows() {
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();
        let mgr = L2CacheManager::new(pool.clone(), test_config(&tmp)).unwrap();

        // Valid stored entry
        let k_valid = StreamKey::new("qobuz", "valid", "27");
        mgr.store_direct_head(&k_valid, &[9u8; 256], Some(1024), 0)
            .await
            .unwrap();

        // Entry whose file gets deleted externally -> dangling SQLite row
        let k_dangling = StreamKey::new("qobuz", "dangling", "27");
        let rec_dangling = mgr
            .store_direct_head(&k_dangling, &[8u8; 256], Some(1024), 0)
            .await
            .unwrap()
            .unwrap();
        fs::remove_file(mgr.resolve_rel_path(&rec_dangling.file_rel_path)).unwrap();

        // Stray .tmp file and stray unreferenced .head + .dash.head files
        let stray_dir = tmp.path().join("cache").join("l2").join("qobuz").join("aa");
        fs::create_dir_all(&stray_dir).unwrap();
        let stray_tmp = stray_dir.join("aa11_x_27.head.tmp.999.1");
        let stray_head = stray_dir.join("aa11_orphan_27.head");
        let stray_dash = stray_dir.join("aa11_orphan_27.dash.head");
        fs::write(&stray_tmp, b"partial").unwrap();
        fs::write(&stray_head, b"orphan").unwrap();
        fs::write(&stray_dash, b"orphan-dash").unwrap();

        // Leased unreferenced file must NOT be deleted by orphan sweep
        let k_leased_new = StreamKey::new("tidal", "leased_uncommitted", "LOSSLESS");
        let leased_rel = build_l2_rel_path(&k_leased_new, L2CacheKind::DirectHead);
        let leased_abs = mgr.resolve_rel_path(&leased_rel);
        fs::create_dir_all(leased_abs.parent().unwrap()).unwrap();
        fs::write(&leased_abs, b"writing").unwrap();
        let _lease = mgr.acquire_lease(&k_leased_new);

        let report = mgr.run_orphan_sweep().await.unwrap();
        assert_eq!(report.deleted_tmp_files, 1);
        assert_eq!(report.deleted_orphan_files, 2);
        assert_eq!(report.removed_dangling_rows, 1);

        assert!(!stray_tmp.exists());
        assert!(!stray_head.exists());
        assert!(!stray_dash.exists());
        assert!(leased_abs.is_file());
        assert!(L2HeadCacheRepository::get(&pool, &k_valid).await.unwrap().is_some());
        assert!(L2HeadCacheRepository::get(&pool, &k_dangling).await.unwrap().is_none());

        mgr.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_dash_head_store_lookup_and_corruption_cleanup() {
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();
        let mgr = L2CacheManager::new(pool.clone(), test_config(&tmp)).unwrap();

        let key = StreamKey::new("tidal", "dash_1", "HI_RES");
        let pkg = DashL2Package {
            mime_type: "audio/mp4".to_string(),
            codecs: Some("flac".to_string()),
            bandwidth: Some(3_200_000),
            total_duration_ms: Some(120_000),
            init_bytes: vec![0x10; 256],
            segments: vec![
                DashL2SegmentEntry {
                    number: 1,
                    start_ms: 0,
                    duration_ms: 4_000,
                    bytes: vec![0x20; 512],
                },
                DashL2SegmentEntry {
                    number: 2,
                    start_ms: 4_000,
                    duration_ms: 4_000,
                    bytes: vec![0x30; 512],
                },
            ],
        };

        let rec = mgr.store_dash_head(&key, &pkg, 0).await.unwrap().unwrap();
        assert_eq!(rec.cache_kind, "dash_init_segs");
        assert!(rec.file_rel_path.ends_with(".dash.head"));

        // Direct lookup must NOT match a dash_init_segs entry.
        assert!(mgr.lookup_direct_head(&key).await.unwrap().is_none());

        let hit = mgr.lookup_dash_head(&key).await.unwrap().unwrap();
        assert_eq!(hit.package, pkg);
        assert!(mgr.is_in_use(&key));
        drop(hit);

        // Corrupt a byte on disk; next lookup detects fingerprint mismatch and cleans up.
        let abs = mgr.resolve_rel_path(&rec.file_rel_path);
        let mut disk_bytes = fs::read(&abs).unwrap();
        let last = disk_bytes.len() - 1;
        disk_bytes[last] ^= 0xFF;
        fs::write(&abs, &disk_bytes).unwrap();

        assert!(mgr.lookup_dash_head(&key).await.unwrap().is_none());
        assert!(!abs.exists());
        assert!(L2HeadCacheRepository::get(&pool, &key).await.unwrap().is_none());

        mgr.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_background_access_flush_and_delayed_orphan_sweep() {
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();

        let stray_dir = tmp.path().join("cache").join("l2").join("qobuz").join("bb");
        fs::create_dir_all(&stray_dir).unwrap();
        let stray_tmp = stray_dir.join("bb22_stray_27.head.tmp.1.1");
        fs::write(&stray_tmp, b"stale_tmp").unwrap();

        let cfg = L2CacheConfig::new(tmp.path())
            .with_access_flush_interval(Duration::from_millis(30))
            .with_orphan_sweep_delay(Duration::from_millis(20));
        let mgr = L2CacheManager::new(pool.clone(), cfg).unwrap();

        let key = StreamKey::new("qobuz", "bg_flush", "27");
        mgr.store_direct_head(&key, &[5u8; 256], Some(1024), 0)
            .await
            .unwrap();
        let hit = mgr.lookup_direct_head(&key).await.unwrap().unwrap();
        drop(hit);

        // Wait briefly for the 20ms delayed orphan sweep & 30ms access flush tasks to run.
        tokio::time::sleep(Duration::from_millis(120)).await;

        assert!(!stray_tmp.exists());
        let row = L2HeadCacheRepository::get(&pool, &key).await.unwrap().unwrap();
        assert_eq!(row.access_count, 2);

        mgr.shutdown().await.unwrap();
    }
}
