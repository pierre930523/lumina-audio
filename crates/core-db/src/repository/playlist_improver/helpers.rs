use std::cmp::Ordering;
use std::path::Path;

use core_types::PlaylistTrackSummary;

use crate::repository::library::{normalize_local_path_for_compare, normalize_match_key};

pub(crate) const DURATION_TOLERANCE_MS: u64 = 3_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DiskCheckMode {
    /// Checks local file existence only when the path is absolute and its non-root parent dir exists.
    Smart,
    /// Always checks `Path::exists()` for local provider tracks.
    Always,
    /// Never checks disk; relies exclusively on `file_status == 'present'`.
    Never,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub(crate) struct TrackJoinedRow {
    pub track_id: String,
    pub version_id: String,
    pub canonical_album_id: String,
    pub canonical_track_id: Option<String>,
    pub external_track_id: String,
    pub title: String,
    pub artist_name: String,
    pub album_title: String,
    pub provider_id: String,
    pub codec: String,
    pub sample_rate_hz: i64,
    pub bit_depth: i64,
    pub is_dsd: i32,
    pub duration_ms: i64,
    pub quality_score: f64,
    pub file_status: String,
    pub isrc: Option<String>,
    pub disc_number: i64,
    pub track_number: i64,
    pub is_hidden: i32,
}

#[derive(Debug, Clone)]
pub(crate) struct AnalyzedTrack {
    pub summary: PlaylistTrackSummary,
    pub canonical_track_id: Option<String>,
    pub external_track_id: String,
    pub disc_number: i64,
    pub track_number: i64,
    pub is_hidden: bool,
    pub norm_title: String,
    pub norm_artist: String,
    pub norm_isrc: Option<String>,
    pub effective_score: f64,
}

impl AnalyzedTrack {
    pub(crate) fn from_joined_row(row: TrackJoinedRow) -> Self {
        let is_dsd = row.is_dsd != 0 || is_dsd_codec(&row.codec);
        let sample_rate_hz = row.sample_rate_hz.max(0) as u32;
        let bit_depth = row.bit_depth.clamp(0, i64::from(u16::MAX)) as u16;
        let duration_ms = row.duration_ms.max(0) as u64;
        let file_path = if is_local_provider(&row.provider_id) {
            Some(row.external_track_id.clone())
        } else {
            None
        };
        let norm_title = normalize_match_key(&row.title);
        let norm_artist = normalize_match_key(&row.artist_name);
        let norm_isrc = row
            .isrc
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| s.to_ascii_uppercase());
        let effective_score = if row.quality_score > 0.0 {
            row.quality_score
        } else {
            intrinsic_track_quality_score(
                &row.codec,
                sample_rate_hz,
                bit_depth,
                is_dsd,
                &row.provider_id,
            )
        };

        let summary = PlaylistTrackSummary {
            track_id: row.track_id,
            version_id: row.version_id,
            canonical_album_id: row.canonical_album_id,
            title: row.title,
            artist_name: row.artist_name,
            album_title: row.album_title,
            provider_id: row.provider_id,
            codec: row.codec,
            sample_rate_hz,
            bit_depth,
            is_dsd,
            duration_ms,
            quality_score: row.quality_score,
            file_status: row.file_status,
            isrc: row.isrc,
            file_path,
        };

        Self {
            summary,
            canonical_track_id: row.canonical_track_id,
            external_track_id: row.external_track_id,
            disc_number: row.disc_number,
            track_number: row.track_number,
            is_hidden: row.is_hidden != 0,
            norm_title,
            norm_artist,
            norm_isrc,
            effective_score,
        }
    }
}

pub(crate) fn is_dsd_codec(codec: &str) -> bool {
    matches!(
        codec.trim().to_ascii_lowercase().as_str(),
        "dsf" | "dsdiff" | "dsd"
    )
}

pub(crate) fn is_lossless_codec(codec: &str, is_dsd: bool) -> bool {
    if is_dsd {
        return true;
    }
    matches!(
        codec.trim().to_ascii_lowercase().as_str(),
        "flac"
            | "alac"
            | "wav"
            | "aiff"
            | "aif"
            | "ape"
            | "wv"
            | "wavpack"
            | "pcm"
            | "dsf"
            | "dsdiff"
            | "dsd"
    )
}

pub(crate) fn is_local_provider(provider_id: &str) -> bool {
    provider_id.trim().eq_ignore_ascii_case("local")
}

pub(crate) fn is_streaming_provider(provider_id: &str) -> bool {
    matches!(
        provider_id.trim().to_ascii_lowercase().as_str(),
        "qobuz"
            | "tidal"
            | "deezer"
            | "apple_music"
            | "applemusic"
            | "youtube_music"
            | "youtubemusic"
            | "ytm"
    )
}

pub(crate) fn provider_rank(provider_id: &str) -> u8 {
    match provider_id.trim().to_ascii_lowercase().as_str() {
        "local" => 3,
        "smb" | "web_dav" | "webdav" => 2,
        "qobuz" | "tidal" | "deezer" | "apple_music" | "applemusic" => 1,
        _ => 0,
    }
}

pub(crate) fn intrinsic_track_quality_score(
    codec: &str,
    sample_rate_hz: u32,
    bit_depth: u16,
    is_dsd: bool,
    provider_id: &str,
) -> f64 {
    let dsd = is_dsd || is_dsd_codec(codec);
    let lossless = is_lossless_codec(codec, dsd);

    let codec_score = if lossless {
        400.0
    } else {
        match codec.trim().to_ascii_lowercase().as_str() {
            "opus" | "aac" | "m4a" | "ogg" | "vorbis" => 120.0,
            _ => 100.0,
        }
    };

    let resolution_score = if dsd {
        if sample_rate_hz >= 22_579_200 {
            220.0
        } else if sample_rate_hz >= 11_289_600 {
            205.0
        } else if sample_rate_hz >= 5_644_800 {
            185.0
        } else {
            160.0
        }
    } else if lossless {
        let bit_bonus = if bit_depth >= 32 {
            60.0
        } else if bit_depth >= 24 {
            50.0
        } else if bit_depth >= 16 {
            20.0
        } else {
            0.0
        };
        let sr_bonus = if sample_rate_hz >= 352_800 {
            150.0
        } else if sample_rate_hz >= 176_400 {
            130.0
        } else if sample_rate_hz >= 88_200 {
            100.0
        } else if sample_rate_hz >= 44_100 {
            40.0
        } else {
            0.0
        };
        bit_bonus + sr_bonus
    } else {
        0.0
    };

    let provider_score = match provider_rank(provider_id) {
        3 => 50.0,
        2 => 40.0,
        1 => 20.0,
        _ => 0.0,
    };

    codec_score + resolution_score + provider_score
}

/// Compares two tracks by quality (`Ordering::Greater` means `a` is better than `b`).
pub(crate) fn compare_track_quality(a: &AnalyzedTrack, b: &AnalyzedTrack) -> Ordering {
    let a_lossless = is_lossless_codec(&a.summary.codec, a.summary.is_dsd);
    let b_lossless = is_lossless_codec(&b.summary.codec, b.summary.is_dsd);

    a.effective_score
        .total_cmp(&b.effective_score)
        .then_with(|| a_lossless.cmp(&b_lossless))
        .then_with(|| a.summary.is_dsd.cmp(&b.summary.is_dsd))
        .then_with(|| a.summary.sample_rate_hz.cmp(&b.summary.sample_rate_hz))
        .then_with(|| a.summary.bit_depth.cmp(&b.summary.bit_depth))
        .then_with(|| {
            provider_rank(&a.summary.provider_id).cmp(&provider_rank(&b.summary.provider_id))
        })
        .then_with(|| (!a.is_hidden).cmp(&(!b.is_hidden)))
        .then_with(|| b.summary.track_id.cmp(&a.summary.track_id))
}

pub(crate) fn is_local_file_missing(
    provider_id: &str,
    external_track_id: &str,
    mode: DiskCheckMode,
) -> bool {
    if !is_local_provider(provider_id) || mode == DiskCheckMode::Never {
        return false;
    }
    let trimmed = external_track_id.trim();
    if trimmed.is_empty() {
        return true;
    }
    let path = Path::new(trimmed);
    match mode {
        DiskCheckMode::Never => false,
        DiskCheckMode::Always => !path.exists(),
        DiskCheckMode::Smart => {
            path.is_absolute()
                && path
                    .parent()
                    .is_some_and(|dir| dir.parent().is_some() && dir.exists())
                && !path.exists()
        }
    }
}

pub(crate) fn is_track_healthy(track: &AnalyzedTrack, mode: DiskCheckMode) -> bool {
    track.summary.file_status.eq_ignore_ascii_case("present")
        && !is_local_file_missing(&track.summary.provider_id, &track.external_track_id, mode)
}

pub(crate) fn durations_compatible(a_ms: u64, b_ms: u64) -> bool {
    a_ms.abs_diff(b_ms) <= DURATION_TOLERANCE_MS
}

pub(crate) fn durations_compatible_or_unknown(a_ms: u64, b_ms: u64) -> bool {
    a_ms == 0 || b_ms == 0 || durations_compatible(a_ms, b_ms)
}

#[derive(Debug, Clone)]
pub(crate) struct RawEntryHints {
    pub norm_path: String,
    pub norm_title: String,
    pub norm_artist_title: Option<(String, String)>,
    pub norm_parent_dir: Option<String>,
}

const AUDIO_EXTENSIONS: &[&str] = &[
    ".flac", ".mp3", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".alac", ".ogg", ".opus", ".dsf",
    ".dff", ".ape", ".wv", ".wma",
];

fn strip_leading_track_number(stem: &str) -> &str {
    let trimmed = stem.trim();
    let bytes = trimmed.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i == 0 {
        return trimmed;
    }
    // Optional disc-track pattern like "1-02" or "1.02"
    if i < bytes.len() && (bytes[i] == b'-' || bytes[i] == b'.') {
        let sep = i;
        let mut j = sep + 1;
        while j < bytes.len() && bytes[j].is_ascii_digit() {
            j += 1;
        }
        if j > sep + 1 {
            i = j;
        }
    }
    let rest = &trimmed[i..];
    let stripped = rest.trim_start_matches([' ', '-', '.', '_']);
    if stripped.is_empty() {
        trimmed
    } else {
        stripped
    }
}

pub(crate) fn parse_raw_entry_hints(raw_entry: &str) -> RawEntryHints {
    let norm_path = normalize_local_path_for_compare(raw_entry);
    let unified = raw_entry.trim().replace('\\', "/");
    let parts: Vec<&str> = unified.split('/').filter(|p| !p.is_empty()).collect();

    let filename = parts.last().copied().unwrap_or("");
    let norm_parent_dir = if parts.len() >= 2 {
        let dir = normalize_match_key(parts[parts.len() - 2]);
        if dir.is_empty() { None } else { Some(dir) }
    } else {
        None
    };

    let lower = filename.to_ascii_lowercase();
    let without_ext = AUDIO_EXTENSIONS
        .iter()
        .find_map(|ext| {
            lower
                .ends_with(ext)
                .then(|| &filename[..filename.len() - ext.len()])
        })
        .unwrap_or(filename);

    let cleaned = strip_leading_track_number(without_ext);
    let norm_artist_title = cleaned.split_once(" - ").and_then(|(artist, title)| {
        let na = normalize_match_key(artist);
        let nt = normalize_match_key(title);
        if !na.is_empty() && !nt.is_empty() {
            Some((na, nt))
        } else {
            None
        }
    });
    let norm_title = normalize_match_key(cleaned);

    RawEntryHints {
        norm_path,
        norm_title,
        norm_artist_title,
        norm_parent_dir,
    }
}
