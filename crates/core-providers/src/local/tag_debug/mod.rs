mod format;
mod inspect;

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::mapper::AlbumKey;
use super::metadata::ExtractedMetadata;

pub use format::format_tag_inspection_report;
pub use inspect::inspect_audio_tags;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawTagField {
    pub key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub declared_encoding: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_hex: Option<String>,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TagBlockInspection {
    pub tag_format: String,
    pub priority_rank: u8,
    pub detected_encoding: String,
    pub fields: Vec<RawTagField>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedMetadataSummary {
    pub title: String,
    pub artist: String,
    pub artists: Vec<String>,
    pub album: String,
    pub album_artist: Option<String>,
    pub track_number: u16,
    pub disc_number: u16,
    pub release_year: Option<i32>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub compilation: Option<bool>,
    pub duration_ms: u64,
    pub format: String,
}

impl From<&ExtractedMetadata> for ParsedMetadataSummary {
    fn from(m: &ExtractedMetadata) -> Self {
        Self {
            title: m.title.clone(),
            artist: m.artist.clone(),
            artists: m.artists.clone(),
            album: m.album.clone(),
            album_artist: m.album_artist.clone(),
            track_number: m.track_number,
            disc_number: m.disc_number,
            release_year: m.release_year,
            genre: m.genre.clone(),
            composer: m.composer.clone(),
            isrc: m.isrc.clone(),
            upc: m.upc.clone(),
            musicbrainz_release_group_id: m.musicbrainz_release_group_id.clone(),
            edition_label: m.edition_label.clone(),
            compilation: m.compilation,
            duration_ms: m.duration_ms,
            format: m.format.to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TagInspectionReport {
    pub file_path: String,
    pub extension: String,
    pub tag_blocks: Vec<TagBlockInspection>,
    pub resolved_encodings: BTreeMap<String, String>,
    pub parsed_metadata: ParsedMetadataSummary,
    pub album_key: AlbumKey,
    pub warnings: Vec<String>,
}
