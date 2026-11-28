use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use core_types::{AlbumVersion, CanonicalAlbum, ProviderKind, TocSignature, TrackSource};

use super::{
    AlbumKey, AlbumSyncMetadata, MappedScanWithMetadata, VersionSyncMetadata, compute_album_key,
};
use crate::error::ProviderError;
use crate::local::encoding::sanitize_tag_text;
use crate::local::metadata::{
    ExtractedMetadata, derive_album_and_artist_from_dir, derive_title_and_track_from_filename,
    extract_disc_number_from_dir_name,
};
use crate::local::scanner::{find_folder_cover, normalize_path};

type MappedTrackEntry = (PathBuf, ExtractedMetadata, AlbumKey);

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
        let mut prepared: Vec<MappedTrackEntry> = Vec::with_capacity(items.len());

        for (path, mut meta) in items {
            meta.title = sanitize_tag_text(&meta.title);
            meta.artist = sanitize_tag_text(&meta.artist);
            meta.album = sanitize_tag_text(&meta.album);
            meta.album_artist = meta
                .album_artist
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty());

            if meta.title.is_empty() {
                let (fallback, _) = derive_title_and_track_from_filename(&path);
                let clean = sanitize_tag_text(&fallback);
                meta.title = if clean.is_empty() {
                    "Unknown Title".to_string()
                } else {
                    clean
                };
            }
            if meta.artist.is_empty() {
                let (_, fallback) = derive_album_and_artist_from_dir(&path);
                let clean = sanitize_tag_text(&fallback);
                meta.artist = if clean.is_empty() {
                    "Unknown Artist".to_string()
                } else {
                    clean
                };
            }
            if meta.album.is_empty() {
                let (fallback, _) = derive_album_and_artist_from_dir(&path);
                let clean = sanitize_tag_text(&fallback);
                meta.album = if clean.is_empty() {
                    "Unknown Album".to_string()
                } else {
                    clean
                };
            }

            let key = compute_album_key(&meta, &path);

            // If disc_number defaulted to 1 and the album title explicitly carries a disc suffix
            // (e.g. "The Wall (Disc 2)"), promote disc_number to preserve ordering across discs.
            if meta.disc_number <= 1 {
                if let Some(title_disc) = key.inferred_disc_from_title {
                    if title_disc > 1 {
                        meta.disc_number = title_disc;
                    }
                }
            }

            prepared.push((path, meta, key));
        }

        // Detect multi-artist folders sharing the same normalized ALBUM tag (without ALBUMARTIST
        // or TCMP) and promote them to Compilation ("Various Artists") — or to a dominant >=75%
        // primary artist — instead of shattering into N 1-track albums.
        consolidate_multi_artist_folders(&mut prepared);

        let mut grouped: HashMap<(String, String), Vec<MappedTrackEntry>> = HashMap::new();
        for (path, meta, key) in prepared {
            grouped
                .entry((key.group_artist_key.clone(), key.group_album_key.clone()))
                .or_default()
                .push((path, meta, key));
        }

        let mut canonical_albums = Vec::new();
        let mut all_tracks = Vec::new();
        let mut sync_metadata: HashMap<String, AlbumSyncMetadata> = HashMap::new();

        for ((_group_artist_key, _group_album_key), mut track_items) in grouped {
            track_items.sort_by(|(pa, ma, _), (pb, mb, _)| {
                (ma.disc_number, ma.track_number, normalize_path(pa)).cmp(&(
                    mb.disc_number,
                    mb.track_number,
                    normalize_path(pb),
                ))
            });

            let explicit_album_artist = track_items
                .iter()
                .find_map(|(_, m, _)| m.album_artist.clone())
                .or_else(|| {
                    track_items
                        .iter()
                        .any(|(_, m, _)| m.compilation == Some(true))
                        .then(|| "Various Artists".to_string())
                });

            let representative_artist =
                resolve_representative_artist(&track_items, explicit_album_artist.as_deref());

            let canonical_title = track_items[0].2.canonical_title.clone();
            let derived_edition = track_items
                .iter()
                .find_map(|(_, _, k)| k.edition_label.clone());

            let mut album = match CanonicalAlbum::new(&canonical_title, &representative_artist) {
                Ok(alb) => alb,
                Err(e) => {
                    tracing::warn!(
                        "Skipping invalid album '{canonical_title}' by '{representative_artist}': {e}"
                    );
                    continue;
                }
            };

            if let Some(ref aa) = explicit_album_artist {
                album = album.with_album_artist(aa);
            }

            if let Some(year) = track_items.iter().find_map(|(_, m, _)| m.release_year) {
                if let Ok(alb) = album.clone().with_release_year(year) {
                    album = alb;
                }
            }

            if let Some(mb_rg_id) = track_items
                .iter()
                .find_map(|(_, m, _)| m.musicbrainz_release_group_id.clone())
            {
                album = album.with_musicbrainz_id(mb_rg_id);
            }

            if let Some(cover_url) = track_items.iter().find_map(|(_, m, _)| m.cover_url.clone()) {
                album = album.with_cover_url(cover_url);
            } else if let Some(first_path) = track_items.first().map(|(p, _, _)| p) {
                if let Some(parent) = first_path.parent() {
                    let cover = find_folder_cover(parent).or_else(|| {
                        let is_disc = parent
                            .file_name()
                            .and_then(|n| n.to_str())
                            .and_then(extract_disc_number_from_dir_name)
                            .is_some();
                        if is_disc {
                            parent.parent().and_then(find_folder_cover)
                        } else {
                            None
                        }
                    });
                    if let Some(cover_path) = cover {
                        album = album.with_cover_url(normalize_path(&cover_path));
                    }
                }
            }

            let album_upc = track_items.iter().find_map(|(_, m, _)| m.upc.clone());

            // Group by effective album root directory + canonical album group key so multi-disc
            // subfolders (CD1/CD2, Disc 1/Disc 2, Part 1/Part 2) collapse into ONE AlbumVersion.
            let mut version_groups: HashMap<String, Vec<MappedTrackEntry>> = HashMap::new();
            for (path, meta, key) in track_items {
                version_groups
                    .entry(key.external_album_id.clone())
                    .or_default()
                    .push((path, meta, key));
            }

            let mut album_version_meta: HashMap<String, VersionSyncMetadata> = HashMap::new();
            let mut primary_toc: Option<TocSignature> = None;
            let mut primary_disc_count: u32 = 1;
            let mut primary_track_count: u32 = 0;

            for (external_album_id, mut tracks_in_version) in version_groups {
                tracks_in_version.sort_by(|(pa, ma, _), (pb, mb, _)| {
                    (ma.disc_number, ma.track_number, normalize_path(pa)).cmp(&(
                        mb.disc_number,
                        mb.track_number,
                        normalize_path(pb),
                    ))
                });

                let representative_format = tracks_in_version
                    .first()
                    .map(|(_, m, _)| m.format.clone())
                    .unwrap_or_else(core_types::AudioFormat::cd_quality);

                let version_edition = tracks_in_version
                    .iter()
                    .find_map(|(_, m, _)| m.edition_label.clone())
                    .or_else(|| {
                        tracks_in_version
                            .iter()
                            .find_map(|(_, _, k)| k.edition_label.clone())
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
                        tracing::warn!("Skipping invalid album version '{external_album_id}': {e}");
                        continue;
                    }
                };
                if let Some(label) = version_edition {
                    version = version.with_edition_label(label);
                }

                let mut version_has_tracks = false;
                let mut version_durations_ms: Vec<u64> =
                    Vec::with_capacity(tracks_in_version.len());
                let mut distinct_discs: HashSet<u16> = HashSet::new();
                let mut max_disc: u16 = 1;

                for (path, meta, _key) in tracks_in_version {
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
                            tracing::warn!(
                                "Skipping invalid track {:?} ({}): {e}",
                                path,
                                meta.title
                            );
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

                    distinct_discs.insert(track.disc_number);
                    max_disc = max_disc.max(track.disc_number);
                    version_durations_ms.push(track.duration_ms);
                    all_tracks.push(track);
                    version_has_tracks = true;
                }

                if version_has_tracks {
                    let disc_count = u32::from(max_disc).max(distinct_discs.len() as u32).max(1);
                    let track_count = version_durations_ms.len() as u32;
                    let toc = TocSignature::from_durations(disc_count, version_durations_ms);

                    if primary_toc.is_none() {
                        primary_toc = Some(toc.clone());
                        primary_disc_count = disc_count;
                        primary_track_count = track_count;
                    }

                    album_version_meta.insert(
                        version.id.clone(),
                        VersionSyncMetadata {
                            toc_signature: Some(toc),
                            disc_count,
                            track_count,
                        },
                    );
                    album.add_version(version);
                }
            }

            if !album.versions.is_empty() {
                sync_metadata.insert(
                    album.id.clone(),
                    AlbumSyncMetadata {
                        upc: album_upc,
                        toc_signature: primary_toc,
                        disc_count: primary_disc_count,
                        track_count: primary_track_count,
                        version_metadata: album_version_meta,
                    },
                );
                canonical_albums.push(album);
            }
        }

        Ok((canonical_albums, all_tracks, sync_metadata))
    }
}

/// Detects folders sharing the same normalized `ALBUM` tag across multiple distinct track artists
/// when neither `ALBUMARTIST` nor `TCMP` is set. Promotes them to Compilation (`"Various Artists"`)
/// — or to a dominant `>= 75%` primary artist — so multi-artist albums never shatter into N
/// 1-track albums.
fn consolidate_multi_artist_folders(prepared: &mut [MappedTrackEntry]) {
    let mut dir_album_buckets: HashMap<(String, String), Vec<usize>> = HashMap::new();
    for (idx, (_, _, key)) in prepared.iter().enumerate() {
        if key.is_unknown_fallback || key.group_album_key.is_empty() {
            continue;
        }
        dir_album_buckets
            .entry((key.effective_dir_key.clone(), key.group_album_key.clone()))
            .or_default()
            .push(idx);
    }

    for indices in dir_album_buckets.values() {
        if indices.len() < 2 {
            continue;
        }
        // Respect explicit ALBUMARTIST when present on any track in the folder.
        if indices
            .iter()
            .any(|&i| prepared[i].1.album_artist.is_some())
        {
            continue;
        }
        if indices
            .iter()
            .any(|&i| prepared[i].1.compilation == Some(false))
        {
            continue;
        }

        let any_explicit_comp = indices
            .iter()
            .any(|&i| prepared[i].1.compilation == Some(true));

        let mut artist_counts: HashMap<String, (usize, String)> = HashMap::new();
        for &i in indices {
            let norm_key = prepared[i].2.group_artist_key.clone();
            let display = primary_artist_for_meta(&prepared[i].1).to_string();
            let entry = artist_counts.entry(norm_key).or_insert((0, display));
            entry.0 += 1;
        }

        if !any_explicit_comp && artist_counts.len() < 2 {
            continue;
        }

        let total = indices.len();
        let dominant = artist_counts.values().max_by_key(|(cnt, _)| *cnt).cloned();

        let promote_to_va = any_explicit_comp
            || dominant
                .as_ref()
                .is_none_or(|(max_cnt, _)| *max_cnt * 100 < total * 75);

        if promote_to_va {
            for &i in indices {
                prepared[i].1.compilation = Some(true);
                let new_key = compute_album_key(&prepared[i].1, &prepared[i].0);
                prepared[i].2 = new_key;
            }
        } else if let Some((_, majority_artist)) = dominant {
            for &i in indices {
                prepared[i].1.album_artist = Some(majority_artist.clone());
                let new_key = compute_album_key(&prepared[i].1, &prepared[i].0);
                prepared[i].2 = new_key;
            }
        }
    }
}

fn primary_artist_for_meta(meta: &ExtractedMetadata) -> &str {
    meta.artists
        .first()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let a = meta.artist.trim();
            if a.is_empty() { "Unknown Artist" } else { a }
        })
}

/// Resolves the canonical album artist preferring explicit `ALBUMARTIST` / `Various Artists`,
/// then the majority primary artist (`artists[0]`) across tracks instead of raw
/// `track_items[0].artist` (preventing `"Artist feat. Guest"` pollution).
fn resolve_representative_artist(
    track_items: &[MappedTrackEntry],
    explicit_album_artist: Option<&str>,
) -> String {
    if let Some(aa) = explicit_album_artist {
        let trimmed = aa.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    let mut counts: HashMap<String, (usize, usize, String)> = HashMap::new();
    for (order, (_, meta, _)) in track_items.iter().enumerate() {
        let primary = primary_artist_for_meta(meta);
        let key = primary.to_lowercase();
        let entry = counts
            .entry(key)
            .or_insert_with(|| (0, order, primary.to_string()));
        entry.0 += 1;
    }

    counts
        .into_values()
        .max_by(|(cnt_a, ord_a, _), (cnt_b, ord_b, _)| {
            cnt_a.cmp(cnt_b).then_with(|| ord_b.cmp(ord_a))
        })
        .map(|(_, _, name)| name)
        .unwrap_or_else(|| "Unknown Artist".to_string())
}
