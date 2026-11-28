use std::collections::{HashMap, HashSet};

use core_db::{LibraryRepository, SqlitePool, normalize_match_key};

use crate::error::ProviderError;
use crate::library::db_err;

const COMPILATION_ARTIST_KEYS: &[&str] = &[
    "various artists",
    "various",
    "va",
    "v a",
    "compilation",
    "群星",
    "合辑",
    "合輯",
    "オムニバス",
];

/// Returns `true` when `artist_name` or `album_artist` indicates a compilation album.
pub(crate) fn is_compilation_artist(artist_name: &str, album_artist: Option<&str>) -> bool {
    let check = |raw: &str| {
        let norm = normalize_match_key(raw);
        !norm.is_empty() && COMPILATION_ARTIST_KEYS.contains(&norm.as_str())
    };
    if let Some(aa) = album_artist {
        if check(aa) {
            return true;
        }
    }
    check(artist_name)
}

/// Normalizes an ISRC string by removing hyphens, trimming whitespace, and uppercasing.
pub(crate) fn normalize_isrc(raw: &str) -> Option<String> {
    let clean: String = raw
        .chars()
        .filter(|c| *c != '-')
        .collect::<String>()
        .trim()
        .to_ascii_uppercase();
    (!clean.is_empty()).then_some(clean)
}

/// Anti-pollution ISRC matching policy:
/// - Never merges a compilation with a non-compilation studio album.
/// - Never merges a 1-track single with a multi-track album via ISRC.
/// - Requires compatible track counts (`min_tracks / max_tracks >= 0.60`).
/// - Requires `>= 60%` ISRC overlap relative to the larger ISRC set.
pub(crate) fn isrc_sets_compatible(
    isrcs_a: &HashSet<String>,
    tracks_a: usize,
    is_comp_a: bool,
    isrcs_b: &HashSet<String>,
    tracks_b: usize,
    is_comp_b: bool,
) -> bool {
    if is_comp_a != is_comp_b {
        return false;
    }
    if isrcs_a.is_empty() || isrcs_b.is_empty() {
        return false;
    }

    let shared = isrcs_a.intersection(isrcs_b).count();
    if shared == 0 {
        return false;
    }

    let eff_tracks_a = tracks_a.max(isrcs_a.len()).max(1);
    let eff_tracks_b = tracks_b.max(isrcs_b.len()).max(1);
    let min_tracks = eff_tracks_a.min(eff_tracks_b);
    let max_tracks = eff_tracks_a.max(eff_tracks_b);

    // A single sharing 1 ISRC with a multi-track album must never merge via ISRC.
    if min_tracks == 1 && max_tracks > 1 {
        return false;
    }
    // Track counts must be within 60% of each other (e.g. standard vs deluxe OK; 2 vs 12 rejected).
    if min_tracks * 10 < max_tracks * 6 {
        return false;
    }

    let denom = isrcs_a.len().max(isrcs_b.len()).max(1);
    shared * 100 >= denom * 60
}

/// Filters SQLite candidate album IDs returned by `find_canonical_album_ids_by_isrcs`,
/// keeping ONLY albums that have at least one version satisfying `isrc_sets_compatible`.
pub(crate) async fn filter_isrc_candidate_albums(
    pool: &SqlitePool,
    candidate_ids: Vec<String>,
    incoming_isrcs: &HashSet<String>,
    incoming_track_count: usize,
    incoming_is_comp: bool,
) -> Result<Vec<String>, ProviderError> {
    if candidate_ids.is_empty() || incoming_isrcs.is_empty() {
        return Ok(Vec::new());
    }

    let mut verified = Vec::new();
    for alb_id in candidate_ids {
        let Some(cand_album) = LibraryRepository::find_canonical_album_by_id(pool, &alb_id)
            .await
            .map_err(db_err)?
        else {
            continue;
        };

        let cand_is_comp =
            is_compilation_artist(&cand_album.artist_name, cand_album.album_artist.as_deref());
        if cand_is_comp != incoming_is_comp {
            continue;
        }

        let mut matched_version = false;
        for ver in &cand_album.versions {
            let tracks = LibraryRepository::find_track_sources_by_version(pool, &ver.id)
                .await
                .map_err(db_err)?;
            if tracks.is_empty() {
                continue;
            }
            let ver_isrcs: HashSet<String> = tracks
                .iter()
                .filter_map(|t| t.isrc.as_deref().and_then(normalize_isrc))
                .collect();
            if isrc_sets_compatible(
                incoming_isrcs,
                incoming_track_count,
                incoming_is_comp,
                &ver_isrcs,
                tracks.len(),
                cand_is_comp,
            ) {
                matched_version = true;
                break;
            }
        }

        if matched_version {
            verified.push(alb_id);
        }
    }
    Ok(verified)
}

/// Lightweight summary of a persisted album within the current batch for safe intra-batch ISRC matching.
pub(crate) struct BatchAlbumIsrcEntry {
    pub(crate) album_id: String,
    pub(crate) isrcs: HashSet<String>,
    pub(crate) track_count: usize,
    pub(crate) is_compilation: bool,
}

pub(crate) fn find_compatible_batch_album_by_isrc(
    entries: &[BatchAlbumIsrcEntry],
    incoming_isrcs: &HashSet<String>,
    incoming_track_count: usize,
    incoming_is_comp: bool,
) -> Option<String> {
    if incoming_isrcs.is_empty() {
        return None;
    }
    entries
        .iter()
        .find(|e| {
            isrc_sets_compatible(
                incoming_isrcs,
                incoming_track_count,
                incoming_is_comp,
                &e.isrcs,
                e.track_count,
                e.is_compilation,
            )
        })
        .map(|e| e.album_id.clone())
}

/// Checks whether a candidate album in SQLite is compatible (compilation vs non-compilation)
/// with the incoming album before adding it as a merge target.
pub(crate) async fn is_candidate_album_compatible(
    pool: &SqlitePool,
    candidate_id: &str,
    incoming_is_comp: bool,
    cache: &mut HashMap<String, bool>,
) -> Result<bool, ProviderError> {
    if let Some(&cand_comp) = cache.get(candidate_id) {
        return Ok(cand_comp == incoming_is_comp);
    }
    let Some(cand) = LibraryRepository::find_canonical_album_by_id(pool, candidate_id)
        .await
        .map_err(db_err)?
    else {
        return Ok(false);
    };
    let cand_comp = is_compilation_artist(&cand.artist_name, cand.album_artist.as_deref());
    cache.insert(candidate_id.to_string(), cand_comp);
    Ok(cand_comp == incoming_is_comp)
}
