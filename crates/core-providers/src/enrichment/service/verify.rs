use std::collections::HashSet;

use core_db::normalize_match_key;
use core_types::AlbumDetail;

use super::super::discogs::{DiscogsRelease, DiscogsSearchResult, clean_discogs_artist_name};
use super::super::musicbrainz::{MbArtistCredit, MbRelease, MbReleaseDetail, MbReleaseGroup};
use crate::local::mapper::normalize_album_base_title;

/// Minimum MusicBrainz Lucene search score required to accept a fuzzy release-group match.
pub const MIN_MB_SEARCH_SCORE: u8 = 90;

const MIN_TITLE_SIMILARITY: f64 = 0.80;
const MIN_ARTIST_SIMILARITY: f64 = 0.75;

#[derive(Debug, Clone)]
pub(super) struct LocalAlbumSignals {
    pub(super) norm_title: String,
    pub(super) norm_artist: String,
    pub(super) track_count: usize,
    pub(super) total_duration_ms: u64,
}

impl LocalAlbumSignals {
    pub(super) fn from_detail(detail: &AlbumDetail) -> Self {
        let primary_version = detail.versions.iter().max_by_key(|v| v.tracks.len());
        let (track_count, total_duration_ms) = match primary_version {
            Some(v) => (v.tracks.len(), v.tracks.iter().map(|t| t.duration_ms).sum()),
            None => (0, 0),
        };
        let effective_artist = detail
            .album
            .album_artist
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(detail.album.artist_name.as_str());

        Self {
            norm_title: normalize_album_base_title(&detail.album.title),
            norm_artist: normalize_match_key(effective_artist),
            track_count,
            total_duration_ms,
        }
    }
}

/// Guards against attempting fuzzy online lookups on placeholder / unmatchable local albums.
pub fn is_unmatchable_local_album(title: &str, artist: &str) -> bool {
    let nt = normalize_album_base_title(title);
    let na = normalize_match_key(artist);
    if nt.is_empty() || na.is_empty() {
        return true;
    }
    if matches!(
        nt.as_str(),
        "unknown" | "unknown album" | "untitled" | "audio" | "music"
    ) {
        return true;
    }
    if matches!(
        na.as_str(),
        "unknown" | "unknown artist" | "various" | "various artists" | "va"
    ) {
        return true;
    }
    false
}

/// Verifies a MusicBrainz `release-group` search candidate against local album title, artist, and score.
pub(super) fn verify_mb_release_group(
    local: &LocalAlbumSignals,
    candidate: &MbReleaseGroup,
) -> bool {
    if let Some(score) = candidate.score {
        if score < MIN_MB_SEARCH_SCORE {
            return false;
        }
    }
    let cand_title = normalize_album_base_title(&candidate.title);
    if text_similarity(&local.norm_title, &cand_title) < MIN_TITLE_SIMILARITY {
        return false;
    }
    if !candidate.artist_credit.is_empty()
        && !artist_credits_match(&local.norm_artist, &candidate.artist_credit)
    {
        return false;
    }
    true
}

/// Verifies a MusicBrainz `release` candidate (from ISRC lookup or release-group releases list)
/// against local album title, artist (when present), track count, and duration tolerance.
pub(super) fn verify_mb_release(local: &LocalAlbumSignals, candidate: &MbRelease) -> bool {
    let cand_title = normalize_album_base_title(&candidate.title);
    let rg_title = candidate
        .release_group
        .as_ref()
        .map(|rg| normalize_album_base_title(&rg.title))
        .unwrap_or_default();

    let title_ok = text_similarity(&local.norm_title, &cand_title) >= MIN_TITLE_SIMILARITY
        || (!rg_title.is_empty()
            && text_similarity(&local.norm_title, &rg_title) >= MIN_TITLE_SIMILARITY);
    if !title_ok {
        return false;
    }

    if !candidate.artist_credit.is_empty()
        && !artist_credits_match(&local.norm_artist, &candidate.artist_credit)
    {
        return false;
    }

    let cand_tracks = candidate_mb_track_count(candidate);
    if cand_tracks > 0
        && local.track_count > 0
        && !track_counts_compatible(local.track_count, cand_tracks)
    {
        return false;
    }

    let cand_duration_ms = candidate_mb_duration_ms(&candidate.media);
    cand_duration_ms == 0
        || local.total_duration_ms == 0
        || durations_compatible(local.total_duration_ms, cand_duration_ms, local.track_count)
}

/// Verifies a full `MbReleaseDetail` before committing its credits, barcode, or MBID.
pub(super) fn verify_mb_release_detail(
    local: &LocalAlbumSignals,
    detail: &MbReleaseDetail,
) -> bool {
    let cand_title = normalize_album_base_title(&detail.title);
    let rg_title = detail
        .release_group
        .as_ref()
        .map(|rg| normalize_album_base_title(&rg.title))
        .unwrap_or_default();

    let title_ok = text_similarity(&local.norm_title, &cand_title) >= MIN_TITLE_SIMILARITY
        || (!rg_title.is_empty()
            && text_similarity(&local.norm_title, &rg_title) >= MIN_TITLE_SIMILARITY);
    if !title_ok {
        return false;
    }

    if !detail.artist_credit.is_empty()
        && !artist_credits_match(&local.norm_artist, &detail.artist_credit)
    {
        return false;
    }

    let cand_tracks: usize = detail
        .media
        .iter()
        .map(|m| {
            if !m.tracks.is_empty() {
                m.tracks.len()
            } else {
                m.track_count.unwrap_or(0) as usize
            }
        })
        .sum();
    if cand_tracks > 0
        && local.track_count > 0
        && !track_counts_compatible(local.track_count, cand_tracks)
    {
        return false;
    }

    let cand_duration_ms = candidate_mb_duration_ms(&detail.media);
    cand_duration_ms == 0
        || local.total_duration_ms == 0
        || durations_compatible(local.total_duration_ms, cand_duration_ms, local.track_count)
}

/// Verifies a Discogs search result (`"Artist - Album Title"`) before fetching full release details.
pub(super) fn verify_discogs_search_result(
    local: &LocalAlbumSignals,
    cand: &DiscogsSearchResult,
) -> bool {
    let raw = cand.title.trim();
    if raw.is_empty() {
        return false;
    }
    if let Some((art_part, title_part)) = raw.split_once(" - ") {
        let norm_art = normalize_match_key(&clean_discogs_artist_name(art_part));
        let norm_title = normalize_album_base_title(title_part);
        text_similarity(&local.norm_artist, &norm_art) >= MIN_ARTIST_SIMILARITY
            && text_similarity(&local.norm_title, &norm_title) >= MIN_TITLE_SIMILARITY
    } else {
        let norm_title = normalize_album_base_title(raw);
        text_similarity(&local.norm_title, &norm_title) >= MIN_TITLE_SIMILARITY
    }
}

/// Verifies a full `DiscogsRelease` against local title, artist, and track count.
pub(super) fn verify_discogs_release(local: &LocalAlbumSignals, release: &DiscogsRelease) -> bool {
    let cand_title = normalize_album_base_title(&release.title);
    if text_similarity(&local.norm_title, &cand_title) < MIN_TITLE_SIMILARITY {
        return false;
    }
    if !release.artists.is_empty() {
        let joined: String = release
            .artists
            .iter()
            .map(|a| clean_discogs_artist_name(&a.name))
            .collect::<Vec<_>>()
            .join(" ");
        let norm_joined = normalize_match_key(&joined);
        let any_matches = release.artists.iter().any(|a| {
            let na = normalize_match_key(&clean_discogs_artist_name(&a.name));
            text_similarity(&local.norm_artist, &na) >= MIN_ARTIST_SIMILARITY
        });
        if !any_matches && text_similarity(&local.norm_artist, &norm_joined) < MIN_ARTIST_SIMILARITY
        {
            return false;
        }
    }
    release.tracklist.is_empty()
        || local.track_count == 0
        || track_counts_compatible(local.track_count, release.tracklist.len())
}

/// Returns `true` if `candidate_name` matches the local album's primary artist name.
pub(super) fn artist_names_match(local_norm_artist: &str, candidate_name: &str) -> bool {
    let norm_cand = normalize_match_key(candidate_name);
    text_similarity(local_norm_artist, &norm_cand) >= MIN_ARTIST_SIMILARITY
}

fn artist_credits_match(local_norm_artist: &str, credits: &[MbArtistCredit]) -> bool {
    let combined: String = credits
        .iter()
        .filter_map(|ac| {
            ac.name
                .as_deref()
                .or_else(|| ac.artist.as_ref().map(|a| a.name.as_str()))
        })
        .collect::<Vec<_>>()
        .join(" ");
    let norm_combined = normalize_match_key(&combined);
    if text_similarity(local_norm_artist, &norm_combined) >= MIN_ARTIST_SIMILARITY {
        return true;
    }
    credits.iter().any(|ac| {
        ac.name
            .as_deref()
            .or_else(|| ac.artist.as_ref().map(|a| a.name.as_str()))
            .is_some_and(|n| {
                text_similarity(local_norm_artist, &normalize_match_key(n)) >= MIN_ARTIST_SIMILARITY
            })
    })
}

fn candidate_mb_track_count(rel: &MbRelease) -> usize {
    let from_media: usize = rel
        .media
        .iter()
        .map(|m| {
            if !m.tracks.is_empty() {
                m.tracks.len()
            } else {
                m.track_count.unwrap_or(0) as usize
            }
        })
        .sum();
    if from_media > 0 {
        from_media
    } else {
        rel.track_count.unwrap_or(0) as usize
    }
}

fn candidate_mb_duration_ms(media: &[super::super::musicbrainz::MbMedium]) -> u64 {
    media
        .iter()
        .flat_map(|m| m.tracks.iter())
        .filter_map(|t| {
            t.length
                .or_else(|| t.recording.as_ref().and_then(|r| r.length))
        })
        .sum()
}

fn track_counts_compatible(local_count: usize, cand_count: usize) -> bool {
    if local_count == 0 || cand_count == 0 {
        return true;
    }
    let diff = local_count.abs_diff(cand_count);
    let max_c = local_count.max(cand_count) as f64;
    let min_c = local_count.min(cand_count) as f64;
    // Allow minor bonus-track differences (+/- 2 tracks or >= 75% overlap), reject huge mismatches
    // (e.g., 1-track single vs 20-track compilation, or 10-track studio album vs 40-track boxset).
    diff <= 2 || (min_c / max_c) >= 0.75
}

fn durations_compatible(local_ms: u64, cand_ms: u64, track_count: usize) -> bool {
    if local_ms == 0 || cand_ms == 0 {
        return true;
    }
    let diff = local_ms.abs_diff(cand_ms);
    let max_d = local_ms.max(cand_ms) as f64;
    let per_track_tol = (track_count.max(1) as u64) * 15_000;
    diff <= per_track_tol || (diff as f64 / max_d) <= 0.15
}

/// Computes normalized similarity in `[0.0, 1.0]` combining exact match, token Dice overlap,
/// and character-bigram Dice similarity (works accurately for both Latin and CJK scripts).
pub(super) fn text_similarity(a: &str, b: &str) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }

    let a_tokens: HashSet<&str> = a.split_whitespace().collect();
    let b_tokens: HashSet<&str> = b.split_whitespace().collect();
    let token_dice = if !a_tokens.is_empty() && !b_tokens.is_empty() {
        let inter = a_tokens.intersection(&b_tokens).count();
        (2.0 * inter as f64) / ((a_tokens.len() + b_tokens.len()) as f64)
    } else {
        0.0
    };

    let a_chars: Vec<char> = a.chars().filter(|c| !c.is_whitespace()).collect();
    let b_chars: Vec<char> = b.chars().filter(|c| !c.is_whitespace()).collect();
    let char_dice = if a_chars.len() >= 2 && b_chars.len() >= 2 {
        let a_bi: HashSet<(char, char)> = a_chars.windows(2).map(|w| (w[0], w[1])).collect();
        let b_bi: HashSet<(char, char)> = b_chars.windows(2).map(|w| (w[0], w[1])).collect();
        let inter = a_bi.intersection(&b_bi).count();
        (2.0 * inter as f64) / ((a_bi.len() + b_bi.len()) as f64)
    } else if a_chars == b_chars {
        1.0
    } else {
        0.0
    };

    token_dice.max(char_dice)
}
