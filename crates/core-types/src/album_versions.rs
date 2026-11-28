use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::{AlbumVersion, AudioCodec, FileStatus, ProviderKind, TrackSource};

fn default_album_limit() -> u32 {
    100
}

// ============================================================================
// Step 2: Album Group & Version Quality Scoring
// ============================================================================

/// Computes the deterministic quality score for an `AlbumVersion` from its present tracks.
pub fn compute_version_quality_score(version: &AlbumVersion, tracks: &[TrackSource]) -> f64 {
    compute_version_quality_score_with_context(version, tracks, None)
}

/// Computes the deterministic quality score for an `AlbumVersion`, optionally comparing
/// completeness against `group_max_tracks` (the highest present track count among sibling versions).
pub fn compute_version_quality_score_with_context(
    version: &AlbumVersion,
    tracks: &[TrackSource],
    group_max_tracks: Option<usize>,
) -> f64 {
    let present: Vec<&TrackSource> = tracks
        .iter()
        .filter(|t| t.file_status == FileStatus::Present)
        .collect();
    if present.is_empty() {
        return 0.0;
    }

    let present_count = present.len();

    // Per-disc completeness span: sum of max(max_track_number, disc_track_count)
    let mut per_disc: HashMap<u32, (usize, usize)> = HashMap::new();
    for track in &present {
        let disc = track
            .manual_disc_number
            .unwrap_or_else(|| u32::from(track.disc_number))
            .max(1);
        let entry = per_disc.entry(disc).or_insert((0, 0));
        entry.0 = entry.0.max(usize::from(track.track_number));
        entry.1 += 1;
    }
    let declared_span: usize = per_disc
        .values()
        .map(|&(max_num, cnt)| max_num.max(cnt))
        .sum();
    let ref_span = group_max_tracks
        .map_or(declared_span, |m| declared_span.max(m))
        .max(1);

    let completeness = 200.0 * (present_count as f64 / ref_span as f64).clamp(0.0, 1.0)
        + 20.0 * (present_count as f64).min(30.0).ln_1p();

    let is_dsd = version.format.is_dsd || version.format.codec.is_dsd();
    let is_lossless = is_dsd || version.format.codec.is_lossless();

    let codec_score = if is_lossless {
        400.0
    } else {
        match version.format.codec {
            AudioCodec::Opus | AudioCodec::Aac => 120.0,
            AudioCodec::Mp3 => 100.0,
            _ => 100.0,
        }
    };

    let resolution_score = if is_dsd {
        let sr = version.format.sample_rate_hz;
        if sr >= 22_579_200 {
            220.0
        } else if sr >= 11_289_600 {
            205.0
        } else if sr >= 5_644_800 {
            185.0
        } else {
            160.0
        }
    } else if is_lossless {
        let bit_bonus = if version.format.bit_depth >= 32 {
            60.0
        } else if version.format.bit_depth >= 24 {
            50.0
        } else if version.format.bit_depth >= 16 {
            20.0
        } else {
            0.0
        };
        let sr = version.format.sample_rate_hz;
        let sr_bonus = if sr >= 352_800 {
            150.0
        } else if sr >= 176_400 {
            130.0
        } else if sr >= 88_200 {
            100.0
        } else if sr >= 44_100 {
            40.0
        } else {
            0.0
        };
        bit_bonus + sr_bonus
    } else {
        0.0
    };

    let provider_score = match version.provider {
        ProviderKind::Local => 50.0,
        ProviderKind::Smb | ProviderKind::WebDav => 40.0,
        ProviderKind::Qobuz
        | ProviderKind::Tidal
        | ProviderKind::Deezer
        | ProviderKind::AppleMusic => 20.0,
        ProviderKind::YouTubeMusic => 0.0,
    };

    completeness + codec_score + resolution_score + provider_score
}

// ============================================================================
// Step 2: Album Group / Version Mutation & Query DTOs
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiscMappingEntry {
    #[serde(alias = "source_version_id")]
    pub version_id: String,
    #[serde(alias = "disc_number", alias = "disc_offset")]
    pub disc_start: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergeAlbumVersionsRequest {
    pub target_version_id: String,
    pub source_version_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_edition_label: Option<String>,
    #[serde(default)]
    pub disc_mapping: Vec<DiscMappingEntry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitTargetMode {
    #[default]
    SameGroup,
    NewGroup,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SplitTrackGroup {
    pub track_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SplitAlbumVersionRequest {
    pub version_id: String,
    pub track_groups: Vec<SplitTrackGroup>,
    #[serde(default)]
    pub target_mode: SplitTargetMode,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GroupAlternateVersionsRequest {
    pub version_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_group_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_version_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetVersionHiddenRequest {
    pub version_id: String,
    pub is_hidden: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetPrimaryVersionRequest {
    pub group_id: String,
    pub version_id: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumVersionOpResult {
    #[serde(default)]
    pub affected_group_ids: Vec<String>,
    #[serde(default)]
    pub affected_version_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_version_id: Option<String>,
    #[serde(default)]
    pub moved_tracks: usize,
    #[serde(default)]
    pub pruned_versions: usize,
    #[serde(default)]
    pub pruned_albums: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumListOptions {
    #[serde(default = "default_album_limit")]
    pub limit: u32,
    #[serde(default)]
    pub offset: u32,
    #[serde(default)]
    pub include_hidden: bool,
}

impl Default for AlbumListOptions {
    fn default() -> Self {
        Self {
            limit: default_album_limit(),
            offset: 0,
            include_hidden: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AlbumGroupSummaryRow {
    pub id: String,
    pub group_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub primary_version_id: Option<String>,
    pub title: String,
    pub artist: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub release_year: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album_artist: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    pub track_count: u32,
    #[serde(default)]
    pub disc_count: u32,
    #[serde(default)]
    pub version_count: u32,
    #[serde(default)]
    pub hidden_version_count: u32,
    #[serde(default)]
    pub is_primary: bool,
    #[serde(default)]
    pub is_primary_locked: bool,
    #[serde(default)]
    pub is_hidden: bool,
    #[serde(default)]
    pub is_manual_group: bool,
    #[serde(default)]
    pub quality_score: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample_rate_hz: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u8>,
    #[serde(default)]
    pub is_dsd: bool,
    #[serde(default)]
    pub preference: i32,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AudioFormat;

    fn make_track(
        ver_id: &str,
        disc: u16,
        num: u16,
        fmt: AudioFormat,
        status: FileStatus,
    ) -> TrackSource {
        let mut t = TrackSource::new(
            ver_id,
            ProviderKind::Local,
            format!("/music/{ver_id}/d{disc}t{num}.flac"),
            format!("Track {num}"),
            disc,
            num,
            200_000,
            fmt,
        )
        .unwrap();
        t.file_status = status;
        t
    }

    #[test]
    fn test_zero_present_tracks_scores_zero() {
        let fmt = AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 2).unwrap();
        let ver = AlbumVersion::new("alb-1", ProviderKind::Local, "/music/a", fmt.clone()).unwrap();
        let missing = vec![make_track(&ver.id, 1, 1, fmt, FileStatus::Missing)];
        assert_eq!(compute_version_quality_score(&ver, &[]), 0.0);
        assert_eq!(compute_version_quality_score(&ver, &missing), 0.0);
    }

    #[test]
    fn test_hires_flac_beats_cd_flac_beats_mp3() {
        let hires_fmt = AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 2).unwrap();
        let cd_fmt = AudioFormat::cd_quality();
        let mp3_fmt = AudioFormat::pcm(AudioCodec::Mp3, 44_100, 16, 2).unwrap();

        let v_hires =
            AlbumVersion::new("alb-1", ProviderKind::Local, "/hires", hires_fmt.clone()).unwrap();
        let v_cd = AlbumVersion::new("alb-1", ProviderKind::Local, "/cd", cd_fmt.clone()).unwrap();
        let v_mp3 =
            AlbumVersion::new("alb-1", ProviderKind::Local, "/mp3", mp3_fmt.clone()).unwrap();

        let t_hires: Vec<_> = (1..=10)
            .map(|i| make_track(&v_hires.id, 1, i, hires_fmt.clone(), FileStatus::Present))
            .collect();
        let t_cd: Vec<_> = (1..=10)
            .map(|i| make_track(&v_cd.id, 1, i, cd_fmt.clone(), FileStatus::Present))
            .collect();
        let t_mp3: Vec<_> = (1..=10)
            .map(|i| make_track(&v_mp3.id, 1, i, mp3_fmt.clone(), FileStatus::Present))
            .collect();

        let s_hires = compute_version_quality_score_with_context(&v_hires, &t_hires, Some(10));
        let s_cd = compute_version_quality_score_with_context(&v_cd, &t_cd, Some(10));
        let s_mp3 = compute_version_quality_score_with_context(&v_mp3, &t_mp3, Some(10));

        assert!(s_hires > s_cd, "hires {s_hires} should beat cd {s_cd}");
        assert!(s_cd > s_mp3, "cd {s_cd} should beat mp3 {s_mp3}");
    }

    #[test]
    fn test_complete_cd_beats_partial_hires_and_dsd_tier_ordering() {
        let hires_fmt = AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 2).unwrap();
        let cd_fmt = AudioFormat::cd_quality();
        let v_hires =
            AlbumVersion::new("alb-1", ProviderKind::Local, "/hires", hires_fmt.clone()).unwrap();
        let v_cd = AlbumVersion::new("alb-1", ProviderKind::Local, "/cd", cd_fmt.clone()).unwrap();

        let t_hires = vec![make_track(
            &v_hires.id,
            1,
            1,
            hires_fmt,
            FileStatus::Present,
        )];
        let t_cd: Vec<_> = (1..=10)
            .map(|i| make_track(&v_cd.id, 1, i, cd_fmt.clone(), FileStatus::Present))
            .collect();

        let s_hires = compute_version_quality_score_with_context(&v_hires, &t_hires, Some(10));
        let s_cd = compute_version_quality_score_with_context(&v_cd, &t_cd, Some(10));
        assert!(
            s_cd > s_hires,
            "complete CD ({s_cd}) should beat 1-track partial hi-res ({s_hires})"
        );

        let dsd512 = AudioFormat::dsd(AudioCodec::Dsf, 22_579_200, 2).unwrap();
        let dsd64 = AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 2).unwrap();
        let v_512 =
            AlbumVersion::new("alb-1", ProviderKind::Local, "/dsd512", dsd512.clone()).unwrap();
        let v_64 =
            AlbumVersion::new("alb-1", ProviderKind::Local, "/dsd64", dsd64.clone()).unwrap();
        let t_512 = vec![make_track(&v_512.id, 1, 1, dsd512, FileStatus::Present)];
        let t_64 = vec![make_track(&v_64.id, 1, 1, dsd64, FileStatus::Present)];
        assert!(
            compute_version_quality_score(&v_512, &t_512)
                > compute_version_quality_score(&v_64, &t_64)
        );
    }

    #[test]
    fn test_provider_preference_local_over_nas_over_streaming() {
        let fmt = AudioFormat::cd_quality();
        let v_local = AlbumVersion::new("alb-1", ProviderKind::Local, "/l", fmt.clone()).unwrap();
        let v_smb = AlbumVersion::new("alb-1", ProviderKind::Smb, "smb://l", fmt.clone()).unwrap();
        let v_qobuz = AlbumVersion::new("alb-1", ProviderKind::Qobuz, "q1", fmt.clone()).unwrap();
        let v_ytm =
            AlbumVersion::new("alb-1", ProviderKind::YouTubeMusic, "y1", fmt.clone()).unwrap();

        let tracks = vec![make_track("v", 1, 1, fmt, FileStatus::Present)];
        let sl = compute_version_quality_score(&v_local, &tracks);
        let ss = compute_version_quality_score(&v_smb, &tracks);
        let sq = compute_version_quality_score(&v_qobuz, &tracks);
        let sy = compute_version_quality_score(&v_ytm, &tracks);
        assert!(sl > ss && ss > sq && sq > sy);
    }
}
