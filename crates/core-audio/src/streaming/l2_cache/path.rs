use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{ErrorKind, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use core_types::{
    L2_DEFAULT_HIGH_WATERMARK_BYTES, L2_DEFAULT_LOW_WATERMARK_BYTES, L2CacheKind,
    L2CacheStoreError, StreamKey, StreamProviderCapabilities,
};
use sha2::{Digest, Sha256};

use super::super::StreamError;

static TMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(1);

pub(super) fn store_err_to_stream(err: L2CacheStoreError) -> StreamError {
    StreamError::Io(format!("L2 cache store error: {err}"))
}

pub(super) fn unix_timestamp_secs() -> i64 {
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

pub(super) fn rel_path_to_abs(root_dir: &Path, rel_path: &str) -> PathBuf {
    let mut path = root_dir.to_path_buf();
    for segment in rel_path.split('/') {
        if !segment.is_empty() {
            path.push(segment);
        }
    }
    path
}

pub(super) fn path_to_rel_string(root_dir: &Path, abs_path: &Path) -> Option<String> {
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

/// Configuration for [`super::L2CacheManager`].
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

pub(super) async fn write_file_atomic(abs_path: PathBuf, data: Bytes) -> Result<(), StreamError> {
    tokio::task::spawn_blocking(move || -> Result<(), StreamError> {
        let parent = abs_path.parent().ok_or_else(|| {
            StreamError::Io(format!(
                "Invalid L2 cache file path: {}",
                abs_path.display()
            ))
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

pub(super) async fn read_file_bytes(abs_path: PathBuf) -> Result<Option<Bytes>, StreamError> {
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

pub(super) async fn remove_file_if_exists(abs_path: PathBuf) -> Result<bool, StreamError> {
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
