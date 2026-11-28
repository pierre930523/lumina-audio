use core_types::{
    FileStatus, MetadataLayer, MetadataOverride, SkipReason, SkippedFile, WatchMode, WatchedRoot,
};
use std::str::FromStr;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RelinkCandidate {
    pub track_source_id: String,
    pub version_id: String,
    pub external_track_id: String,
    pub file_status: FileStatus,
    pub canonical_track_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SidecarPlaylistEntry {
    pub raw_entry: String,
    pub resolved_track_source_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SidecarPlaylist {
    pub id: String,
    pub provider_id: String,
    pub source_path: String,
    pub name: String,
    pub track_count: u32,
    pub updated_at: String,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct WatchedRootRow {
    pub(super) id: String,
    pub(super) provider_id: String,
    pub(super) root_path: String,
    pub(super) watch_mode: String,
    pub(super) poll_interval_sec: i64,
    pub(super) is_online: i32,
    pub(super) last_scan_at: Option<String>,
    pub(super) updated_at: String,
}

impl From<WatchedRootRow> for WatchedRoot {
    fn from(r: WatchedRootRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            root_path: r.root_path,
            watch_mode: WatchMode::from_str(&r.watch_mode).unwrap_or(WatchMode::NativeOs),
            poll_interval_sec: r.poll_interval_sec.max(0) as u32,
            is_online: r.is_online != 0,
            last_scan_at: r.last_scan_at,
            updated_at: r.updated_at,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct SkippedFileRow {
    pub(super) id: String,
    pub(super) provider_id: String,
    pub(super) file_path: String,
    pub(super) reason_code: String,
    pub(super) detail: String,
    pub(super) file_size: Option<i64>,
    pub(super) file_mtime: Option<i64>,
    pub(super) first_seen_at: String,
    pub(super) last_seen_at: String,
    pub(super) dismissed: i32,
}

impl From<SkippedFileRow> for SkippedFile {
    fn from(r: SkippedFileRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            file_path: r.file_path,
            reason: SkipReason::from_str(&r.reason_code).unwrap_or(SkipReason::IoError),
            detail: r.detail,
            file_size: r.file_size.and_then(|v| u64::try_from(v).ok()),
            file_mtime: r.file_mtime,
            first_seen_at: r.first_seen_at,
            last_seen_at: r.last_seen_at,
            dismissed: r.dismissed != 0,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct MetadataOverrideRow {
    pub(super) entity_type: String,
    pub(super) entity_id: String,
    pub(super) field_name: String,
    pub(super) value_json: String,
    pub(super) source_layer: String,
    pub(super) updated_at: String,
}

impl From<MetadataOverrideRow> for MetadataOverride {
    fn from(r: MetadataOverrideRow) -> Self {
        Self {
            entity_type: r.entity_type,
            entity_id: r.entity_id,
            field_name: r.field_name,
            value_json: r.value_json,
            source_layer: MetadataLayer::from_str(&r.source_layer)
                .unwrap_or(MetadataLayer::UserEdit),
            updated_at: r.updated_at,
        }
    }
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct RelinkCandidateRow {
    pub(super) id: String,
    pub(super) version_id: String,
    pub(super) external_track_id: String,
    pub(super) file_status: String,
    pub(super) canonical_track_id: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct CanonicalTrackRow {
    pub(super) id: String,
    pub(super) canonical_album_id: String,
    pub(super) title: String,
    pub(super) sort_title: String,
    pub(super) artist_name: String,
    pub(super) album_artist: Option<String>,
    pub(super) disc_number: i64,
    pub(super) track_number: i64,
    pub(super) duration_ms: i64,
    pub(super) isrc: Option<String>,
    pub(super) musicbrainz_recording_id: Option<String>,
    pub(super) genre: Option<String>,
    pub(super) composer: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct SourceReferenceRow {
    pub(super) id: String,
    pub(super) provider_id: String,
    pub(super) external_track_id: String,
    pub(super) codec: String,
    pub(super) sample_rate_hz: i64,
    pub(super) bit_depth: i64,
    pub(super) channels: i64,
    pub(super) is_dsd: i32,
    pub(super) file_status: String,
    pub(super) content_fingerprint: Option<String>,
    pub(super) audio_byte_len: Option<i64>,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct AlbumVersionTocRow {
    pub(super) id: String,
    pub(super) canonical_album_id: String,
    pub(super) provider_id: String,
    pub(super) external_album_id: String,
    pub(super) codec: String,
    pub(super) sample_rate_hz: i64,
    pub(super) bit_depth: i64,
    pub(super) channels: i64,
    pub(super) is_dsd: i32,
    pub(super) edition_label: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
pub(super) struct PlaylistRow {
    pub(super) id: String,
    pub(super) provider_id: String,
    pub(super) source_path: String,
    pub(super) name: String,
    pub(super) track_count: i64,
    pub(super) updated_at: String,
}

impl From<PlaylistRow> for SidecarPlaylist {
    fn from(r: PlaylistRow) -> Self {
        Self {
            id: r.id,
            provider_id: r.provider_id,
            source_path: r.source_path,
            name: r.name,
            track_count: r.track_count.max(0) as u32,
            updated_at: r.updated_at,
        }
    }
}
