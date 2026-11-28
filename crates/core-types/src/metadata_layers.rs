use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Three-Layer Non-Destructive Metadata Policy & Pure Resolver
// ============================================================================

/// Controls precedence between embedded file tags and cloud enrichment metadata.
///
/// Explicit user edits ALWAYS win over both `File` and `Cloud`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetadataPolicy {
    #[default]
    Inherit,
    File,
    Cloud,
}

impl MetadataPolicy {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Inherit => "inherit",
            Self::File => "file",
            Self::Cloud => "cloud",
        }
    }

    #[inline]
    pub const fn is_concrete(&self) -> bool {
        matches!(self, Self::File | Self::Cloud)
    }

    /// Resolves `Inherit` against a global `default_policy` (falling back to `File`
    /// if `default_policy` is itself `Inherit`).
    #[inline]
    pub const fn resolve_effective(self, default_policy: Self) -> Self {
        match self {
            Self::File => Self::File,
            Self::Cloud => Self::Cloud,
            Self::Inherit => match default_policy {
                Self::Cloud => Self::Cloud,
                Self::File | Self::Inherit => Self::File,
            },
        }
    }
}

impl fmt::Display for MetadataPolicy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for MetadataPolicy {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "inherit" => Ok(Self::Inherit),
            "file" => Ok(Self::File),
            "cloud" => Ok(Self::Cloud),
            _ => Err(ValidationError::EmptyField {
                field: "meta_policy",
                message: "meta_policy must be 'inherit', 'file', or 'cloud'",
            }),
        }
    }
}

#[inline]
fn clean_opt_str(val: Option<&String>) -> Option<String> {
    val.map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

#[inline]
fn pick_str(
    user: Option<&String>,
    preferred: Option<&String>,
    fallback: Option<&String>,
) -> Option<String> {
    clean_opt_str(user)
        .or_else(|| clean_opt_str(preferred))
        .or_else(|| clean_opt_str(fallback))
}

#[inline]
fn pick_year(user: Option<i32>, preferred: Option<i32>, fallback: Option<i32>) -> Option<i32> {
    let valid = |y: Option<i32>| y.filter(|yr| (1000..=3000).contains(yr));
    valid(user)
        .or_else(|| valid(preferred))
        .or_else(|| valid(fallback))
}

#[inline]
fn pick_pos_u16(user: Option<u16>, preferred: Option<u16>, fallback: Option<u16>) -> Option<u16> {
    let valid = |v: Option<u16>| v.filter(|&n| n > 0);
    valid(user)
        .or_else(|| valid(preferred))
        .or_else(|| valid(fallback))
}

/// Trait implemented by layered metadata payloads (`AlbumMetadataLayer`, `TrackMetadataLayer`).
pub trait LayeredMetadata: Sized + Default {
    fn is_empty(&self) -> bool;
    fn merge_from(&mut self, patch: &Self);
    fn resolve_with(
        preferred: Option<&Self>,
        fallback: Option<&Self>,
        user_edits: Option<&Self>,
    ) -> Self;
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumMetadataLayer {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_year: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub musicbrainz_release_group_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub editorial_bio: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merged_cover_path: Option<String>,
}

impl AlbumMetadataLayer {
    pub fn from_json_opt(raw: Option<&str>) -> Option<Self> {
        let s = raw?.trim();
        if s.is_empty() || s == "null" || s == "{}" {
            return None;
        }
        let parsed: Self = serde_json::from_str(s).ok()?;
        if parsed.is_empty() {
            None
        } else {
            Some(parsed)
        }
    }

    pub fn to_json_opt(&self) -> Option<String> {
        if self.is_empty() {
            None
        } else {
            serde_json::to_string(self).ok()
        }
    }
}

impl LayeredMetadata for AlbumMetadataLayer {
    fn is_empty(&self) -> bool {
        clean_opt_str(self.title.as_ref()).is_none()
            && clean_opt_str(self.sort_title.as_ref()).is_none()
            && clean_opt_str(self.album_artist.as_ref()).is_none()
            && self.release_year.is_none()
            && clean_opt_str(self.upc.as_ref()).is_none()
            && clean_opt_str(self.musicbrainz_release_group_id.as_ref()).is_none()
            && clean_opt_str(self.editorial_bio.as_ref()).is_none()
            && clean_opt_str(self.cover_url.as_ref()).is_none()
            && clean_opt_str(self.merged_cover_path.as_ref()).is_none()
    }

    fn merge_from(&mut self, patch: &Self) {
        if let Some(v) = clean_opt_str(patch.title.as_ref()) {
            self.title = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.sort_title.as_ref()) {
            self.sort_title = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.album_artist.as_ref()) {
            self.album_artist = Some(v);
        }
        if let Some(v) = patch.release_year.filter(|yr| (1000..=3000).contains(yr)) {
            self.release_year = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.upc.as_ref()) {
            self.upc = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.musicbrainz_release_group_id.as_ref()) {
            self.musicbrainz_release_group_id = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.editorial_bio.as_ref()) {
            self.editorial_bio = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.cover_url.as_ref()) {
            self.cover_url = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.merged_cover_path.as_ref()) {
            self.merged_cover_path = Some(v);
        }
    }

    fn resolve_with(
        preferred: Option<&Self>,
        fallback: Option<&Self>,
        user_edits: Option<&Self>,
    ) -> Self {
        Self {
            title: pick_str(
                user_edits.and_then(|l| l.title.as_ref()),
                preferred.and_then(|l| l.title.as_ref()),
                fallback.and_then(|l| l.title.as_ref()),
            ),
            sort_title: pick_str(
                user_edits.and_then(|l| l.sort_title.as_ref()),
                preferred.and_then(|l| l.sort_title.as_ref()),
                fallback.and_then(|l| l.sort_title.as_ref()),
            ),
            album_artist: pick_str(
                user_edits.and_then(|l| l.album_artist.as_ref()),
                preferred.and_then(|l| l.album_artist.as_ref()),
                fallback.and_then(|l| l.album_artist.as_ref()),
            ),
            release_year: pick_year(
                user_edits.and_then(|l| l.release_year),
                preferred.and_then(|l| l.release_year),
                fallback.and_then(|l| l.release_year),
            ),
            upc: pick_str(
                user_edits.and_then(|l| l.upc.as_ref()),
                preferred.and_then(|l| l.upc.as_ref()),
                fallback.and_then(|l| l.upc.as_ref()),
            ),
            musicbrainz_release_group_id: pick_str(
                user_edits.and_then(|l| l.musicbrainz_release_group_id.as_ref()),
                preferred.and_then(|l| l.musicbrainz_release_group_id.as_ref()),
                fallback.and_then(|l| l.musicbrainz_release_group_id.as_ref()),
            ),
            editorial_bio: pick_str(
                user_edits.and_then(|l| l.editorial_bio.as_ref()),
                preferred.and_then(|l| l.editorial_bio.as_ref()),
                fallback.and_then(|l| l.editorial_bio.as_ref()),
            ),
            cover_url: pick_str(
                user_edits.and_then(|l| l.cover_url.as_ref()),
                preferred.and_then(|l| l.cover_url.as_ref()),
                fallback.and_then(|l| l.cover_url.as_ref()),
            ),
            merged_cover_path: pick_str(
                user_edits.and_then(|l| l.merged_cover_path.as_ref()),
                preferred.and_then(|l| l.merged_cover_path.as_ref()),
                fallback.and_then(|l| l.merged_cover_path.as_ref()),
            ),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrackMetadataLayer {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artist_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disc_number: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_number: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_year: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub genre: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lyrics: Option<String>,
}

impl TrackMetadataLayer {
    pub fn from_json_opt(raw: Option<&str>) -> Option<Self> {
        let s = raw?.trim();
        if s.is_empty() || s == "null" || s == "{}" {
            return None;
        }
        let parsed: Self = serde_json::from_str(s).ok()?;
        if parsed.is_empty() {
            None
        } else {
            Some(parsed)
        }
    }

    pub fn to_json_opt(&self) -> Option<String> {
        if self.is_empty() {
            None
        } else {
            serde_json::to_string(self).ok()
        }
    }
}

impl LayeredMetadata for TrackMetadataLayer {
    fn is_empty(&self) -> bool {
        clean_opt_str(self.title.as_ref()).is_none()
            && clean_opt_str(self.artist_name.as_ref()).is_none()
            && clean_opt_str(self.album_artist.as_ref()).is_none()
            && clean_opt_str(self.album_title.as_ref()).is_none()
            && self.disc_number.filter(|&n| n > 0).is_none()
            && self.track_number.filter(|&n| n > 0).is_none()
            && self
                .release_year
                .filter(|y| (1000..=3000).contains(y))
                .is_none()
            && clean_opt_str(self.genre.as_ref()).is_none()
            && clean_opt_str(self.composer.as_ref()).is_none()
            && clean_opt_str(self.isrc.as_ref()).is_none()
            && clean_opt_str(self.lyrics.as_ref()).is_none()
    }

    fn merge_from(&mut self, patch: &Self) {
        if let Some(v) = clean_opt_str(patch.title.as_ref()) {
            self.title = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.artist_name.as_ref()) {
            self.artist_name = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.album_artist.as_ref()) {
            self.album_artist = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.album_title.as_ref()) {
            self.album_title = Some(v);
        }
        if let Some(v) = patch.disc_number.filter(|&n| n > 0) {
            self.disc_number = Some(v);
        }
        if let Some(v) = patch.track_number.filter(|&n| n > 0) {
            self.track_number = Some(v);
        }
        if let Some(v) = patch.release_year.filter(|y| (1000..=3000).contains(y)) {
            self.release_year = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.genre.as_ref()) {
            self.genre = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.composer.as_ref()) {
            self.composer = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.isrc.as_ref()) {
            self.isrc = Some(v);
        }
        if let Some(v) = clean_opt_str(patch.lyrics.as_ref()) {
            self.lyrics = Some(v);
        }
    }

    fn resolve_with(
        preferred: Option<&Self>,
        fallback: Option<&Self>,
        user_edits: Option<&Self>,
    ) -> Self {
        Self {
            title: pick_str(
                user_edits.and_then(|l| l.title.as_ref()),
                preferred.and_then(|l| l.title.as_ref()),
                fallback.and_then(|l| l.title.as_ref()),
            ),
            artist_name: pick_str(
                user_edits.and_then(|l| l.artist_name.as_ref()),
                preferred.and_then(|l| l.artist_name.as_ref()),
                fallback.and_then(|l| l.artist_name.as_ref()),
            ),
            album_artist: pick_str(
                user_edits.and_then(|l| l.album_artist.as_ref()),
                preferred.and_then(|l| l.album_artist.as_ref()),
                fallback.and_then(|l| l.album_artist.as_ref()),
            ),
            album_title: pick_str(
                user_edits.and_then(|l| l.album_title.as_ref()),
                preferred.and_then(|l| l.album_title.as_ref()),
                fallback.and_then(|l| l.album_title.as_ref()),
            ),
            disc_number: pick_pos_u16(
                user_edits.and_then(|l| l.disc_number),
                preferred.and_then(|l| l.disc_number),
                fallback.and_then(|l| l.disc_number),
            ),
            track_number: pick_pos_u16(
                user_edits.and_then(|l| l.track_number),
                preferred.and_then(|l| l.track_number),
                fallback.and_then(|l| l.track_number),
            ),
            release_year: pick_year(
                user_edits.and_then(|l| l.release_year),
                preferred.and_then(|l| l.release_year),
                fallback.and_then(|l| l.release_year),
            ),
            genre: pick_str(
                user_edits.and_then(|l| l.genre.as_ref()),
                preferred.and_then(|l| l.genre.as_ref()),
                fallback.and_then(|l| l.genre.as_ref()),
            ),
            composer: pick_str(
                user_edits.and_then(|l| l.composer.as_ref()),
                preferred.and_then(|l| l.composer.as_ref()),
                fallback.and_then(|l| l.composer.as_ref()),
            ),
            isrc: pick_str(
                user_edits.and_then(|l| l.isrc.as_ref()),
                preferred.and_then(|l| l.isrc.as_ref()),
                fallback.and_then(|l| l.isrc.as_ref()),
            ),
            lyrics: pick_str(
                user_edits.and_then(|l| l.lyrics.as_ref()),
                preferred.and_then(|l| l.lyrics.as_ref()),
                fallback.and_then(|l| l.lyrics.as_ref()),
            ),
        }
    }
}

/// Pure three-layer metadata resolver.
///
/// Strict precedence per field:
/// `user_edits > preferred_source (File or Cloud) > other_source`.
/// Empty or whitespace-only strings in a higher layer are treated as `None`.
pub fn resolve_effective_metadata<T: LayeredMetadata>(
    file_meta: Option<&T>,
    cloud_meta: Option<&T>,
    user_edits: Option<&T>,
    effective_policy: MetadataPolicy,
) -> T {
    match effective_policy {
        MetadataPolicy::Cloud => T::resolve_with(cloud_meta, file_meta, user_edits),
        MetadataPolicy::File | MetadataPolicy::Inherit => {
            T::resolve_with(file_meta, cloud_meta, user_edits)
        }
    }
}

pub fn resolve_effective_album_metadata(
    file_meta: Option<&AlbumMetadataLayer>,
    cloud_meta: Option<&AlbumMetadataLayer>,
    user_edits: Option<&AlbumMetadataLayer>,
    effective_policy: MetadataPolicy,
) -> AlbumMetadataLayer {
    resolve_effective_metadata(file_meta, cloud_meta, user_edits, effective_policy)
}

pub fn resolve_effective_track_metadata(
    file_meta: Option<&TrackMetadataLayer>,
    cloud_meta: Option<&TrackMetadataLayer>,
    user_edits: Option<&TrackMetadataLayer>,
    effective_policy: MetadataPolicy,
) -> TrackMetadataLayer {
    resolve_effective_metadata(file_meta, cloud_meta, user_edits, effective_policy)
}
