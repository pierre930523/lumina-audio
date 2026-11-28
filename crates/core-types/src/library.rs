use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{AudioFormat, FileStatus, MetadataPolicy, ProviderKind, ValidationError};

// ============================================================================
// Feature 9: CanonicalAlbum & AlbumVersion
// ============================================================================

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanonicalAlbum {
    pub id: String,
    pub title: String,
    pub sort_title: String,
    pub artist_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    pub release_year: Option<i32>,
    pub musicbrainz_release_group_id: Option<String>,
    pub cover_url: Option<String>,
    pub versions: Vec<AlbumVersion>,
    #[serde(default)]
    pub meta_policy: MetadataPolicy,
    #[serde(default)]
    pub has_user_edits: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_version_id: Option<String>,
    #[serde(default)]
    pub is_primary_locked: bool,
    #[serde(default)]
    pub preference: i32,
}

impl CanonicalAlbum {
    pub fn new(
        title: impl Into<String>,
        artist_name: impl Into<String>,
    ) -> Result<Self, ValidationError> {
        let t = title.into();
        let a = artist_name.into();
        if t.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "title",
                message: "album title cannot be empty",
            });
        }
        if a.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "artist_name",
                message: "artist name cannot be empty",
            });
        }

        let sort_title = Self::derive_sort_title(&t);

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            title: t.trim().to_string(),
            sort_title,
            artist_name: a.trim().to_string(),
            album_artist: None,
            release_year: None,
            musicbrainz_release_group_id: None,
            cover_url: None,
            versions: Vec::new(),
            meta_policy: MetadataPolicy::Inherit,
            has_user_edits: false,
            primary_version_id: None,
            is_primary_locked: false,
            preference: 0,
        })
    }

    pub fn with_id(
        id: impl Into<String>,
        title: impl Into<String>,
        artist_name: impl Into<String>,
    ) -> Result<Self, ValidationError> {
        let mut album = Self::new(title, artist_name)?;
        let id_str = id.into();
        if id_str.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "id",
                message: "album ID cannot be empty",
            });
        }
        album.id = id_str;
        Ok(album)
    }

    pub fn with_release_year(mut self, year: i32) -> Result<Self, ValidationError> {
        if !(1000..=3000).contains(&year) {
            return Err(ValidationError::InvalidReleaseYear(year));
        }
        self.release_year = Some(year);
        Ok(self)
    }

    pub fn with_musicbrainz_id(mut self, mb_id: impl Into<String>) -> Self {
        self.musicbrainz_release_group_id = Some(mb_id.into().trim().to_string());
        self
    }

    pub fn with_cover_url(mut self, url: impl Into<String>) -> Self {
        self.cover_url = Some(url.into().trim().to_string());
        self
    }

    pub fn with_album_artist(mut self, album_artist: impl Into<String>) -> Self {
        let raw = album_artist.into();
        let trimmed = raw.trim();
        self.album_artist = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn add_version(&mut self, version: AlbumVersion) {
        self.versions.push(version);
    }

    pub fn derive_sort_title(title: &str) -> String {
        let trimmed = title.trim();
        let lower = trimmed.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("the ") {
            trimmed[trimmed.len() - rest.len()..].trim().to_string()
        } else if let Some(rest) = lower.strip_prefix("a ") {
            trimmed[trimmed.len() - rest.len()..].trim().to_string()
        } else if let Some(rest) = lower.strip_prefix("an ") {
            trimmed[trimmed.len() - rest.len()..].trim().to_string()
        } else {
            trimmed.to_string()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlbumVersion {
    pub id: String,
    pub canonical_album_id: String,
    pub provider: ProviderKind,
    pub external_album_id: String,
    pub format: AudioFormat,
    pub edition_label: Option<String>,
    #[serde(default)]
    pub is_primary: bool,
    #[serde(default)]
    pub is_hidden: bool,
    #[serde(default)]
    pub quality_score: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manual_group_id: Option<String>,
    #[serde(default)]
    pub disc_count: u32,
    #[serde(default)]
    pub track_count: u32,
    #[serde(default)]
    pub has_manual_tracks: bool,
}

impl AlbumVersion {
    pub fn new(
        canonical_album_id: impl Into<String>,
        provider: ProviderKind,
        external_album_id: impl Into<String>,
        format: AudioFormat,
    ) -> Result<Self, ValidationError> {
        let cid = canonical_album_id.into();
        let eid = external_album_id.into();
        if cid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "canonical_album_id",
                message: "cannot be empty",
            });
        }
        if eid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "external_album_id",
                message: "cannot be empty",
            });
        }

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            canonical_album_id: cid.trim().to_string(),
            provider,
            external_album_id: eid.trim().to_string(),
            format,
            edition_label: None,
            is_primary: false,
            is_hidden: false,
            quality_score: 0.0,
            manual_group_id: None,
            disc_count: 1,
            track_count: 0,
            has_manual_tracks: false,
        })
    }

    pub fn with_edition_label(mut self, label: impl Into<String>) -> Self {
        self.edition_label = Some(label.into().trim().to_string());
        self
    }
}

// ============================================================================
// Feature 10: TrackSource
// ============================================================================

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackSource {
    pub id: String,
    pub version_id: String,
    pub provider: ProviderKind,
    pub external_track_id: String,
    pub title: String,
    pub disc_number: u16,
    pub track_number: u16,
    pub duration_ms: u64,
    pub format: AudioFormat,
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_album_db: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_track_peak: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replay_gain_album_peak: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_cache_key: Option<String>,
    #[serde(default)]
    pub has_lyrics: bool,
    #[serde(default)]
    pub file_status: FileStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manual_version_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manual_disc_number: Option<u32>,
    #[serde(default)]
    pub preference: i32,
    #[serde(default)]
    pub is_hidden: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_year: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bitrate_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size_bytes: Option<u64>,
}

impl TrackSource {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        version_id: impl Into<String>,
        provider: ProviderKind,
        external_track_id: impl Into<String>,
        title: impl Into<String>,
        disc_number: u16,
        track_number: u16,
        duration_ms: u64,
        format: AudioFormat,
    ) -> Result<Self, ValidationError> {
        let vid = version_id.into();
        let eid = external_track_id.into();
        let t = title.into();

        if vid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "version_id",
                message: "version ID cannot be empty",
            });
        }
        if eid.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "external_track_id",
                message: "external track ID cannot be empty",
            });
        }
        if t.trim().is_empty() {
            return Err(ValidationError::EmptyField {
                field: "title",
                message: "track title cannot be empty",
            });
        }
        if disc_number == 0 {
            return Err(ValidationError::InvalidDiscNumber(disc_number));
        }
        if track_number == 0 {
            return Err(ValidationError::InvalidTrackNumber(track_number));
        }
        if duration_ms == 0 {
            return Err(ValidationError::InvalidDuration(duration_ms));
        }

        Ok(Self {
            id: Uuid::new_v4().to_string(),
            version_id: vid.trim().to_string(),
            provider,
            external_track_id: eid.trim().to_string(),
            title: t.trim().to_string(),
            disc_number,
            track_number,
            duration_ms,
            format,
            isrc: None,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
            artist_name: None,
            album_artist: None,
            genre: None,
            composer: None,
            cover_url: None,
            artwork_cache_key: None,
            has_lyrics: false,
            file_status: FileStatus::Present,
            manual_version_id: None,
            manual_disc_number: None,
            preference: 0,
            is_hidden: false,
            release_year: None,
            bitrate_kbps: None,
            file_size_bytes: None,
        })
    }

    pub fn with_replay_gain(
        mut self,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Self {
        self.replay_gain_track_db = track_db;
        self.replay_gain_album_db = album_db;
        self.replay_gain_track_peak = track_peak;
        self.replay_gain_album_peak = album_peak;
        self
    }

    pub fn with_artist_name(mut self, artist_name: impl Into<String>) -> Self {
        let raw = artist_name.into();
        let trimmed = raw.trim();
        self.artist_name = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_album_artist(mut self, album_artist: impl Into<String>) -> Self {
        let raw = album_artist.into();
        let trimmed = raw.trim();
        self.album_artist = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_genre(mut self, genre: impl Into<String>) -> Self {
        let raw = genre.into();
        let trimmed = raw.trim();
        self.genre = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_composer(mut self, composer: impl Into<String>) -> Self {
        let raw = composer.into();
        let trimmed = raw.trim();
        self.composer = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_cover_url(mut self, cover_url: impl Into<String>) -> Self {
        let raw = cover_url.into();
        let trimmed = raw.trim();
        self.cover_url = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_artwork_cache_key(mut self, key: impl Into<String>) -> Self {
        let raw = key.into();
        let trimmed = raw.trim();
        self.artwork_cache_key = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        };
        self
    }

    pub fn with_has_lyrics(mut self, has_lyrics: bool) -> Self {
        self.has_lyrics = has_lyrics;
        self
    }

    pub fn with_isrc(mut self, isrc: impl Into<String>) -> Result<Self, ValidationError> {
        let raw = isrc.into();
        let cleaned: String = raw.chars().filter(|c| *c != '-').collect();
        if cleaned.len() != 12 || !cleaned.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(ValidationError::InvalidIsrc(raw));
        }
        self.isrc = Some(cleaned.to_ascii_uppercase());
        Ok(self)
    }

    pub fn formatted_duration(&self) -> String {
        let total_seconds = self.duration_ms / 1000;
        let hours = total_seconds / 3600;
        let minutes = (total_seconds % 3600) / 60;
        let seconds = total_seconds % 60;

        if hours > 0 {
            format!("{}:{:02}:{:02}", hours, minutes, seconds)
        } else {
            format!("{}:{:02}", minutes, seconds)
        }
    }
}
