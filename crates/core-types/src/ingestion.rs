use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::{AudioCodec, ProviderKind, ValidationError};

fn default_one_u16() -> u16 {
    1
}

fn default_one_u32() -> u32 {
    1
}

// ============================================================================
// Skipped Files Quarantine
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SkipReason {
    CorruptHeader,
    PermissionDenied,
    UnsupportedFormat,
    UnsplitCueOrIso,
    GarbledTags,
    IoError,
}

impl SkipReason {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::CorruptHeader => "corrupt_header",
            Self::PermissionDenied => "permission_denied",
            Self::UnsupportedFormat => "unsupported_format",
            Self::UnsplitCueOrIso => "unsplit_cue_or_iso",
            Self::GarbledTags => "garbled_tags",
            Self::IoError => "io_error",
        }
    }
}

impl fmt::Display for SkipReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for SkipReason {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "corrupt_header" => Ok(Self::CorruptHeader),
            "permission_denied" => Ok(Self::PermissionDenied),
            "unsupported_format" => Ok(Self::UnsupportedFormat),
            "unsplit_cue_or_iso" => Ok(Self::UnsplitCueOrIso),
            "garbled_tags" => Ok(Self::GarbledTags),
            "io_error" => Ok(Self::IoError),
            _ => Err(ValidationError::EmptyField {
                field: "reason",
                message: "unknown skip reason",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkippedFile {
    pub id: String,
    pub provider_id: String,
    pub file_path: String,
    pub reason: SkipReason,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_mtime: Option<i64>,
    pub first_seen_at: String,
    pub last_seen_at: String,
    #[serde(default)]
    pub dismissed: bool,
}

// ============================================================================
// Scan Progress & Watched Roots
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanLifecycleState {
    #[default]
    Idle,
    Discovering,
    Probing,
    Persisting,
    Watching,
    Completed,
    Failed,
}

impl ScanLifecycleState {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Discovering => "discovering",
            Self::Probing => "probing",
            Self::Persisting => "persisting",
            Self::Watching => "watching",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }
}

impl fmt::Display for ScanLifecycleState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ScanProgressEvent {
    pub scan_id: String,
    pub root_path: String,
    pub state: ScanLifecycleState,
    #[serde(default)]
    pub scanned: u64,
    #[serde(default)]
    pub added: u64,
    #[serde(default)]
    pub updated: u64,
    #[serde(default)]
    pub unchanged: u64,
    #[serde(default)]
    pub skipped: u64,
    #[serde(default)]
    pub pruned: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_estimated: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WatchMode {
    #[default]
    NativeOs,
    NasPolling,
    Manual,
}

impl WatchMode {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::NativeOs => "native_os",
            Self::NasPolling => "nas_polling",
            Self::Manual => "manual",
        }
    }
}

impl fmt::Display for WatchMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for WatchMode {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "native_os" | "native" => Ok(Self::NativeOs),
            "nas_polling" | "poll" | "polling" => Ok(Self::NasPolling),
            "manual" => Ok(Self::Manual),
            _ => Err(ValidationError::EmptyField {
                field: "watch_mode",
                message: "unknown watch mode",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WatchedRoot {
    pub id: String,
    pub provider_id: String,
    pub root_path: String,
    pub watch_mode: WatchMode,
    pub poll_interval_sec: u32,
    pub is_online: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_scan_at: Option<String>,
    pub updated_at: String,
}

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

    format!("toc1:d{disc_count}:n{}:{h1:016x}{h2:016x}", durations_ms.len())
}

// ============================================================================
// Layered Metadata Precedence & Non-Destructive Overrides
// ============================================================================

/// Precedence order: `FileTag < CloudEnrichment < UserEdit`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetadataLayer {
    FileTag = 0,
    CloudEnrichment = 1,
    UserEdit = 2,
}

impl MetadataLayer {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::FileTag => "file_tag",
            Self::CloudEnrichment => "cloud_enrichment",
            Self::UserEdit => "user_edit",
        }
    }

    #[inline]
    pub const fn rank(&self) -> u8 {
        *self as u8
    }
}

impl fmt::Display for MetadataLayer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for MetadataLayer {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "file_tag" | "file" => Ok(Self::FileTag),
            "cloud_enrichment" | "cloud" => Ok(Self::CloudEnrichment),
            "user_edit" | "user" => Ok(Self::UserEdit),
            _ => Err(ValidationError::EmptyField {
                field: "source_layer",
                message: "unknown metadata layer",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MetadataOverride {
    pub entity_type: String,
    pub entity_id: String,
    pub field_name: String,
    pub value_json: String,
    pub source_layer: MetadataLayer,
    pub updated_at: String,
}

// ============================================================================
// Canonical Track, Artist & SourceReference
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileStatus {
    #[default]
    Present,
    Missing,
    Quarantined,
}

impl FileStatus {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Present => "present",
            Self::Missing => "missing",
            Self::Quarantined => "quarantined",
        }
    }
}

impl fmt::Display for FileStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for FileStatus {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "present" => Ok(Self::Present),
            "missing" => Ok(Self::Missing),
            "quarantined" => Ok(Self::Quarantined),
            _ => Err(ValidationError::EmptyField {
                field: "file_status",
                message: "unknown file status",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceReference {
    pub source_id: String,
    pub provider: ProviderKind,
    pub external_id: String,
    pub codec: AudioCodec,
    pub sample_rate_hz: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<u8>,
    #[serde(default)]
    pub is_dsd: bool,
    #[serde(default)]
    pub file_status: FileStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_byte_len: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalTrack {
    pub id: String,
    pub canonical_album_id: String,
    pub title: String,
    pub sort_title: String,
    pub artist_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default)]
    pub artist_names: Vec<String>,
    pub disc_number: u32,
    pub track_number: u32,
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_recording_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default)]
    pub sources: Vec<SourceReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalArtist {
    pub id: String,
    pub name: String,
    pub sort_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub biography: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
}

// ============================================================================
// External Streaming Catalog Ingest DTOs (Metadata-Only, Zero Stream URLs)
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalTrackIngest {
    pub external_track_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default = "default_one_u16")]
    pub disc_number: u16,
    #[serde(default = "default_one_u16")]
    pub track_number: u16,
    #[serde(default)]
    pub duration_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<AudioCodec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample_rate_hz: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalAlbumIngest {
    pub external_album_id: String,
    pub title: String,
    pub artist_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_year: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition_label: Option<String>,
    #[serde(default = "default_one_u32")]
    pub disc_count: u32,
    #[serde(default)]
    pub tracks: Vec<ExternalTrackIngest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalCatalogIngestBatch {
    pub provider: ProviderKind,
    #[serde(default)]
    pub albums: Vec<ExternalAlbumIngest>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_metadata_layer_precedence_and_roundtrip() {
        assert!(MetadataLayer::FileTag < MetadataLayer::CloudEnrichment);
        assert!(MetadataLayer::CloudEnrichment < MetadataLayer::UserEdit);

        for layer in [
            MetadataLayer::FileTag,
            MetadataLayer::CloudEnrichment,
            MetadataLayer::UserEdit,
        ] {
            let s = layer.as_str();
            assert_eq!(MetadataLayer::from_str(s).unwrap(), layer);
            let json = serde_json::to_string(&layer).unwrap();
            assert_eq!(serde_json::from_str::<MetadataLayer>(&json).unwrap(), layer);
        }
    }

    #[test]
    fn test_toc_signature_determinism_and_order_sensitivity() {
        let t1 = TocSignature::from_durations(2, vec![180_000, 245_120, 312_500]);
        let t2 = TocSignature::from_durations(2, vec![180_000, 245_120, 312_500]);
        let t3 = TocSignature::from_durations(2, vec![180_000, 312_500, 245_120]);
        let t4 = TocSignature::from_durations(1, vec![180_000, 245_120, 312_500]);

        assert_eq!(t1, t2);
        assert_eq!(t1.track_count, 3);
        assert_ne!(t1.digest, t3.digest);
        assert_ne!(t1.digest, t4.digest);
    }

    #[test]
    fn test_ingestion_dto_snake_case_serde() {
        let skipped = SkippedFile {
            id: "skip-1".to_string(),
            provider_id: "local".to_string(),
            file_path: "D:/Music/album.cue".to_string(),
            reason: SkipReason::UnsplitCueOrIso,
            detail: "Unsplit CUE sheet".to_string(),
            file_size: Some(2048),
            file_mtime: Some(1_700_000_000),
            first_seen_at: "2026-01-01T00:00:00Z".to_string(),
            last_seen_at: "2026-01-01T00:00:00Z".to_string(),
            dismissed: false,
        };
        let v = serde_json::to_value(&skipped).unwrap();
        assert_eq!(v["reason"], "unsplit_cue_or_iso");
        assert_eq!(serde_json::from_value::<SkippedFile>(v).unwrap(), skipped);

        let batch = ExternalCatalogIngestBatch {
            provider: ProviderKind::YouTubeMusic,
            albums: vec![ExternalAlbumIngest {
                external_album_id: "MPREb_123".to_string(),
                title: "Test Album".to_string(),
                artist_name: "Test Artist".to_string(),
                album_artist: None,
                release_year: Some(2025),
                upc: None,
                cover_url: Some("https://img.example/1.jpg".to_string()),
                edition_label: None,
                disc_count: 1,
                tracks: vec![ExternalTrackIngest {
                    external_track_id: "dQw4w9WgXcQ".to_string(),
                    title: "Track 1".to_string(),
                    artist_name: Some("Test Artist".to_string()),
                    album_artist: None,
                    disc_number: 1,
                    track_number: 1,
                    duration_ms: 212_000,
                    isrc: Some("USRC17607839".to_string()),
                    genre: None,
                    composer: None,
                    codec: Some(AudioCodec::Opus),
                    sample_rate_hz: Some(48000),
                    bit_depth: None,
                    bitrate_kbps: Some(160),
                }],
            }],
        };
        let bj = serde_json::to_value(&batch).unwrap();
        assert_eq!(bj["provider"], "youtube_music");
        assert_eq!(
            serde_json::from_value::<ExternalCatalogIngestBatch>(bj).unwrap(),
            batch
        );
    }
}
