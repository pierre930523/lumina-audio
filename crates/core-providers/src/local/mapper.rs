use std::collections::HashMap;
use std::path::PathBuf;

use core_db::normalize_match_key;
use core_types::{AlbumVersion, CanonicalAlbum, ProviderKind, TrackSource};
use serde::{Deserialize, Serialize};

use super::metadata::{
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, ExtractedMetadata,
};
use super::scanner::{find_folder_cover, normalize_path};
use crate::error::ProviderError;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AlbumSyncMetadata {
    pub upc: Option<String>,
}

const EDITION_KEYWORDS: &[&str] = &[
    "remaster",
    "remastered",
    "deluxe",
    "super deluxe",
    "anniversary",
    "expanded",
    "special edition",
    "collector",
    "limited",
    "bonus",
    "mono",
    "stereo",
    "hi-res",
    "hires",
    "24-bit",
    "24bit",
    "16-bit",
    "16bit",
    "96khz",
    "192khz",
    "44.1khz",
    "dsd",
    "sacd",
    "mqa",
    "explicit",
    "clean",
    "live",
    "acoustic",
    "edition",
    "version",
    "japan",
    "japanese",
    "uk edition",
    "us edition",
];

/// Splits trailing edition suffixes such as `(2011 Remaster)` or `[Deluxe Edition]`
/// from an album title while leaving non-edition titles intact.
pub fn extract_edition_label(title: &str) -> (String, Option<String>) {
    let mut current = title.trim().to_string();
    let mut editions: Vec<String> = Vec::new();

    loop {
        let trimmed = current.trim_end();
        let pair = if trimmed.ends_with(')') {
            trimmed.rfind('(').map(|idx| (idx, ')'))
        } else if trimmed.ends_with(']') {
            trimmed.rfind('[').map(|idx| (idx, ']'))
        } else {
            None
        };

        let Some((open_idx, _)) = pair else {
            break;
        };

        let prefix = trimmed[..open_idx].trim();
        if prefix.is_empty() {
            break;
        }

        let inner = trimmed[open_idx + 1..trimmed.len() - 1].trim();
        let inner_lower = inner.to_ascii_lowercase();
        let looks_like_edition = EDITION_KEYWORDS
            .iter()
            .any(|kw| contains_keyword_with_boundary(&inner_lower, kw));

        if !looks_like_edition {
            break;
        }

        editions.push(inner.to_string());
        current = prefix.to_string();
    }

    if editions.is_empty() {
        (title.trim().to_string(), None)
    } else {
        editions.reverse();
        (current, Some(editions.join(" / ")))
    }
}

pub fn normalize_album_base_title(title: &str) -> String {
    let (base, _) = extract_edition_label(title);
    normalize_match_key(&base)
}

fn contains_keyword_with_boundary(haystack: &str, kw: &str) -> bool {
    haystack.match_indices(kw).any(|(start, _)| {
        let before_ok = haystack[..start]
            .chars()
            .next_back()
            .is_none_or(|c| !c.is_alphanumeric());
        let after_ok = haystack[start + kw.len()..]
            .chars()
            .next()
            .is_none_or(|c| !c.is_alphanumeric());
        before_ok && after_ok
    })
}

pub type MappedScanWithMetadata = (
    Vec<CanonicalAlbum>,
    Vec<TrackSource>,
    HashMap<String, AlbumSyncMetadata>,
);

pub struct AlbumMapper;

impl AlbumMapper {
    pub fn map_scanned_items(
        items: Vec<(PathBuf, ExtractedMetadata)>,
        provider: ProviderKind,
    ) -> Result<(Vec<CanonicalAlbum>, Vec<TrackSource>), ProviderError> {
        let (albums, tracks, _) = Self::map_scanned_items_with_metadata(items, provider)?;
        Ok((albums, tracks))
    }

    pub fn map_scanned_items_with_metadata(
        items: Vec<(PathBuf, ExtractedMetadata)>,
        provider: ProviderKind,
    ) -> Result<MappedScanWithMetadata, ProviderError> {
        let mut grouped: HashMap<(String, String), Vec<(PathBuf, ExtractedMetadata)>> =
            HashMap::new();

        for (path, mut meta) in items {
            if meta.title.trim().is_empty() {
                let (fallback, _) = derive_title_and_track_from_filename(&path);
                meta.title = if fallback.trim().is_empty() {
                    "Unknown Title".to_string()
                } else {
                    fallback
                };
            }
            if meta.artist.trim().is_empty() {
                let (_, fallback) = derive_album_and_artist_from_dir(&path);
                meta.artist = if fallback.trim().is_empty() {
                    "Unknown Artist".to_string()
                } else {
                    fallback
                };
            }
            if meta.album.trim().is_empty() {
                let (fallback, _) = derive_album_and_artist_from_dir(&path);
                meta.album = if fallback.trim().is_empty() {
                    "Unknown Album".to_string()
                } else {
                    fallback
                };
            }
            if let Some(ref aa) = meta.album_artist {
                if aa.trim().is_empty() {
                    meta.album_artist = None;
                }
            }

            let artist_key_raw = meta
                .album_artist
                .as_ref()
                .cloned()
                .unwrap_or_else(|| meta.artist.clone());
            let norm_artist = normalize_match_key(&artist_key_raw);
            let norm_album = normalize_album_base_title(&meta.album);

            // Safety guard: never collapse distinct "Unknown Album" / "Unknown Artist" folders.
            let is_unknown = norm_album.is_empty()
                || norm_artist.is_empty()
                || norm_album == "unknown album"
                || norm_artist == "unknown artist";

            let group_key = if is_unknown {
                let dir_key = path
                    .parent()
                    .map(normalize_path)
                    .unwrap_or_else(|| normalize_path(&path));
                (format!("__unknown__:{dir_key}"), norm_album)
            } else {
                (norm_artist, norm_album)
            };

            grouped.entry(group_key).or_default().push((path, meta));
        }

        let mut canonical_albums = Vec::new();
        let mut all_tracks = Vec::new();
        let mut sync_metadata: HashMap<String, AlbumSyncMetadata> = HashMap::new();

        for ((group_artist_key, group_album_key), mut track_items) in grouped {
            track_items.sort_by(|(pa, ma), (pb, mb)| {
                (ma.disc_number, ma.track_number, normalize_path(pa))
                    .cmp(&(mb.disc_number, mb.track_number, normalize_path(pb)))
            });

            let representative_artist = track_items
                .iter()
                .find_map(|(_, m)| m.album_artist.clone())
                .unwrap_or_else(|| track_items[0].1.artist.clone());

            let (base_title, derived_edition) = extract_edition_label(&track_items[0].1.album);
            let canonical_title = if base_title.is_empty() {
                track_items[0].1.album.clone()
            } else {
                base_title
            };

            let mut album = match CanonicalAlbum::new(&canonical_title, &representative_artist) {
                Ok(alb) => alb,
                Err(e) => {
                    tracing::warn!(
                        "Skipping invalid album '{canonical_title}' by '{representative_artist}': {e}"
                    );
                    continue;
                }
            };

            if let Some(year) = track_items.iter().find_map(|(_, m)| m.release_year) {
                if let Ok(alb) = album.clone().with_release_year(year) {
                    album = alb;
                }
            }

            if let Some(mb_rg_id) = track_items
                .iter()
                .find_map(|(_, m)| m.musicbrainz_release_group_id.clone())
            {
                album = album.with_musicbrainz_id(mb_rg_id);
            }

            if let Some(cover_url) = track_items.iter().find_map(|(_, m)| m.cover_url.clone()) {
                album = album.with_cover_url(cover_url);
            } else if let Some(first_path) = track_items.first().map(|(p, _)| p) {
                if let Some(parent) = first_path.parent() {
                    if let Some(cover_path) = find_folder_cover(parent) {
                        album = album.with_cover_url(normalize_path(&cover_path));
                    }
                }
            }

            let album_upc = track_items.iter().find_map(|(_, m)| m.upc.clone());

            // Group by directory + canonical album group key so distinct albums
            // sharing a flat folder never collide on (provider_id, external_album_id).
            let mut version_groups: HashMap<String, Vec<(PathBuf, ExtractedMetadata)>> =
                HashMap::new();
            for (path, meta) in track_items {
                let dir_key = path
                    .parent()
                    .map(normalize_path)
                    .unwrap_or_else(|| "default".to_string());
                let version_key = format!("{dir_key}::{group_artist_key}::{group_album_key}");
                version_groups.entry(version_key).or_default().push((path, meta));
            }

            for (external_album_id, tracks_in_version) in version_groups {
                let representative_format = tracks_in_version
                    .first()
                    .map(|(_, m)| m.format.clone())
                    .unwrap_or_else(core_types::AudioFormat::cd_quality);

                let version_edition = tracks_in_version
                    .iter()
                    .find_map(|(_, m)| m.edition_label.clone())
                    .or_else(|| {
                        tracks_in_version
                            .first()
                            .and_then(|(_, m)| extract_edition_label(&m.album).1)
                    })
                    .or_else(|| derived_edition.clone());

                let mut version = match AlbumVersion::new(
                    &album.id,
                    provider,
                    &external_album_id,
                    representative_format,
                ) {
                    Ok(v) => v,
                    Err(e) => {
                        tracing::warn!(
                            "Skipping invalid album version '{external_album_id}': {e}"
                        );
                        continue;
                    }
                };
                if let Some(label) = version_edition {
                    version = version.with_edition_label(label);
                }

                let mut version_has_tracks = false;
                for (path, meta) in tracks_in_version {
                    let external_track_id = normalize_path(&path);
                    let track_res = TrackSource::new(
                        &version.id,
                        provider,
                        external_track_id,
                        &meta.title,
                        meta.disc_number,
                        meta.track_number,
                        meta.duration_ms,
                        meta.format,
                    );

                    let mut track = match track_res {
                        Ok(t) => t,
                        Err(e) => {
                            tracing::warn!("Skipping invalid track {:?} ({}): {e}", path, meta.title);
                            continue;
                        }
                    };

                    track = track.with_artist_name(&meta.artist);
                    if let Some(ref aa) = meta.album_artist {
                        track = track.with_album_artist(aa);
                    }
                    if let Some(ref g) = meta.genre {
                        track = track.with_genre(g);
                    }
                    if let Some(ref c) = meta.composer {
                        track = track.with_composer(c);
                    }
                    if meta.embedded_lyrics.is_some() {
                        track = track.with_has_lyrics(true);
                    }

                    if let Some(isrc) = meta.isrc {
                        if let Ok(t) = track.clone().with_isrc(isrc) {
                            track = t;
                        }
                    }

                    if meta.replay_gain_track_db.is_some()
                        || meta.replay_gain_album_db.is_some()
                        || meta.replay_gain_track_peak.is_some()
                        || meta.replay_gain_album_peak.is_some()
                    {
                        track = track.with_replay_gain(
                            meta.replay_gain_track_db,
                            meta.replay_gain_album_db,
                            meta.replay_gain_track_peak,
                            meta.replay_gain_album_peak,
                        );
                    }

                    all_tracks.push(track);
                    version_has_tracks = true;
                }

                if version_has_tracks {
                    album.add_version(version);
                }
            }

            if !album.versions.is_empty() {
                if let Some(upc) = album_upc {
                    sync_metadata.insert(album.id.clone(), AlbumSyncMetadata { upc: Some(upc) });
                }
                canonical_albums.push(album);
            }
        }

        Ok((canonical_albums, all_tracks, sync_metadata))
    }
}
