use core_types::{
    AudioCodec, AudioFormat, MetadataPolicy, TrackCorruptionStatus, TrackFileInfo,
    TrackMetadataLayer, resolve_effective_track_metadata,
};
use sqlx::SqlitePool;
use std::path::Path;
use std::str::FromStr;

use super::LibraryRepository;
use super::helpers::{parse_audio_codec, parse_provider_kind};
use crate::error::Result;

#[derive(Debug, sqlx::FromRow)]
struct TrackFileInfoDbRow {
    id: String,
    version_id: String,
    album_group_id: String,
    provider_id: String,
    external_track_id: String,
    title: String,
    artist_name: Option<String>,
    album_artist: Option<String>,
    album_title: String,
    disc_number: i64,
    track_number: i64,
    duration_ms: i64,
    sample_rate_hz: i64,
    bit_depth: i64,
    channels: i64,
    codec: String,
    is_dsd: i32,
    isrc: Option<String>,
    genre: Option<String>,
    composer: Option<String>,
    release_year: Option<i32>,
    album_release_year: Option<i32>,
    embedded_lyrics: Option<String>,
    replay_gain_track_db: Option<f64>,
    replay_gain_track_peak: Option<f64>,
    file_mtime: Option<i64>,
    file_size: Option<i64>,
    bitrate_kbps: Option<i64>,
    is_hidden: i32,
    preference: i32,
    corruption_status: String,
    analysis_error: Option<String>,
    integrated_lufs: Option<f64>,
    true_peak_db: Option<f64>,
    waveform_peaks_json: Option<String>,
    analyzed_at: Option<String>,
    file_meta_json: Option<String>,
    cloud_meta_json: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
}

fn derive_container_format(codec: &str, file_path: &str, provider_id: &str) -> String {
    if provider_id.eq_ignore_ascii_case("local")
        && let Some(ext) = Path::new(file_path).extension().and_then(|s| s.to_str())
    {
        let trimmed = ext.trim();
        if !trimmed.is_empty() {
            return trimmed.to_ascii_uppercase();
        }
    }
    codec.trim().to_ascii_uppercase()
}

fn parse_waveform_peaks(raw: Option<&str>) -> Vec<f32> {
    let Some(s) = raw.map(str::trim).filter(|s| !s.is_empty()) else {
        return Vec::new();
    };
    serde_json::from_str::<Vec<f32>>(s).unwrap_or_default()
}

impl LibraryRepository {
    /// Loads detailed technical file properties, analysis state, and 3-layer metadata
    /// for a single `track_sources.id`.
    pub async fn get_track_file_info(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Option<TrackFileInfo>> {
        let tid = track_id.trim();
        if tid.is_empty() {
            return Ok(None);
        }

        let row: Option<TrackFileInfoDbRow> = sqlx::query_as(
            "SELECT ts.id, ts.version_id, av.canonical_album_id AS album_group_id, \
                    ts.provider_id, ts.external_track_id, ts.title, ts.artist_name, \
                    COALESCE(ts.album_artist, ca.album_artist) AS album_artist, \
                    ca.title AS album_title, ts.disc_number, ts.track_number, \
                    ts.duration_ms, ts.sample_rate_hz, ts.bit_depth, ts.channels, ts.codec, ts.is_dsd, \
                    ts.isrc, ts.genre, ts.composer, ts.release_year, ca.release_year AS album_release_year, \
                    ts.embedded_lyrics, ts.replay_gain_track_db, ts.replay_gain_track_peak, \
                    ts.file_mtime, ts.file_size, ts.bitrate_kbps, ts.is_hidden, ts.preference, \
                    ts.corruption_status, ts.analysis_error, ts.integrated_lufs, ts.true_peak_db, \
                    ts.waveform_peaks_json, ts.analyzed_at, \
                    ts.file_meta_json, ts.cloud_meta_json, ts.user_edits_json, ts.meta_policy \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE ts.id = ?",
        )
        .bind(tid)
        .fetch_optional(pool)
        .await?;

        let Some(row) = row else {
            return Ok(None);
        };

        let default_policy = Self::get_default_metadata_policy(pool).await?;
        let policy = MetadataPolicy::from_str(&row.meta_policy).unwrap_or(MetadataPolicy::Inherit);
        let effective_policy = policy.resolve_effective(default_policy);

        let provider = parse_provider_kind(&row.provider_id);
        let is_local_file = row.provider_id.eq_ignore_ascii_case("local");

        let mut file_size_bytes = row.file_size.and_then(|s| u64::try_from(s).ok());
        let mut file_mtime = row.file_mtime;
        if is_local_file
            && (file_size_bytes.is_none() || file_mtime.is_none())
            && let Ok(meta) = std::fs::metadata(&row.external_track_id)
        {
            if file_size_bytes.is_none() {
                file_size_bytes = Some(meta.len());
            }
            if file_mtime.is_none()
                && let Ok(mod_time) = meta.modified()
                && let Ok(dur) = mod_time.duration_since(std::time::UNIX_EPOCH)
            {
                file_mtime = Some(dur.as_secs() as i64);
            }
        }

        let duration_ms = row.duration_ms.max(0) as u64;
        let bitrate_kbps = row
            .bitrate_kbps
            .and_then(|b| u32::try_from(b).ok())
            .filter(|&b| b > 0)
            .or_else(|| match (file_size_bytes, duration_ms) {
                (Some(sz), dur) if sz > 0 && dur > 0 => u32::try_from((sz.saturating_mul(8)) / dur)
                    .ok()
                    .filter(|&b| b > 0),
                _ => None,
            });

        let codec_enum = parse_audio_codec(&row.codec);
        let is_dsd = row.is_dsd != 0 || matches!(codec_enum, AudioCodec::Dsf | AudioCodec::Dsdiff);
        let format = AudioFormat {
            codec: codec_enum,
            sample_rate_hz: row.sample_rate_hz.max(0) as u32,
            bit_depth: row.bit_depth.clamp(0, u8::MAX as i64) as u8,
            channels: row.channels.clamp(1, u8::MAX as i64) as u8,
            is_dsd,
        };

        let file_layer = match TrackMetadataLayer::from_json_opt(row.file_meta_json.as_deref()) {
            Some(l) => Some(l),
            None if row.file_meta_json.is_none() => Some(TrackMetadataLayer {
                title: Some(row.title.clone()),
                artist_name: row.artist_name.clone(),
                album_artist: row.album_artist.clone(),
                album_title: Some(row.album_title.clone()),
                disc_number: u16::try_from(row.disc_number).ok().filter(|&n| n > 0),
                track_number: u16::try_from(row.track_number).ok().filter(|&n| n > 0),
                release_year: row.release_year.or(row.album_release_year),
                genre: row.genre.clone(),
                composer: row.composer.clone(),
                isrc: row.isrc.clone(),
                lyrics: row.embedded_lyrics.clone(),
            }),
            None => None,
        };
        let cloud_layer = TrackMetadataLayer::from_json_opt(row.cloud_meta_json.as_deref());
        let user_edits_layer = TrackMetadataLayer::from_json_opt(row.user_edits_json.as_deref());
        let has_user_edits = user_edits_layer.is_some();

        let mut effective_layer = resolve_effective_track_metadata(
            file_layer.as_ref(),
            cloud_layer.as_ref(),
            user_edits_layer.as_ref(),
            effective_policy,
        );
        if effective_layer.title.is_none() {
            effective_layer.title = Some(row.title.clone());
        }
        if effective_layer.album_title.is_none() {
            effective_layer.album_title = Some(row.album_title.clone());
        }
        if effective_layer.release_year.is_none() {
            effective_layer.release_year = row.album_release_year;
        }

        let has_non_empty =
            |opt: Option<&String>| opt.map(|s| s.trim()).is_some_and(|s| !s.is_empty());
        let resolved_lyrics_source =
            if has_non_empty(user_edits_layer.as_ref().and_then(|l| l.lyrics.as_ref())) {
                Some("user_edit".to_string())
            } else if effective_policy == MetadataPolicy::Cloud
                && has_non_empty(cloud_layer.as_ref().and_then(|l| l.lyrics.as_ref()))
            {
                Some("cloud".to_string())
            } else if has_non_empty(file_layer.as_ref().and_then(|l| l.lyrics.as_ref())) {
                Some("embedded".to_string())
            } else if has_non_empty(effective_layer.lyrics.as_ref()) {
                Some(
                    if effective_policy == MetadataPolicy::Cloud {
                        "cloud"
                    } else {
                        "embedded"
                    }
                    .to_string(),
                )
            } else {
                None
            };

        Ok(Some(TrackFileInfo {
            track_id: row.id,
            version_id: row.version_id,
            album_group_id: row.album_group_id,
            provider_id: provider.as_str().to_string(),
            container_format: derive_container_format(
                &row.codec,
                &row.external_track_id,
                &row.provider_id,
            ),
            file_path: row.external_track_id,
            is_local_file,
            format,
            duration_ms,
            bitrate_kbps,
            file_size_bytes,
            file_mtime,
            is_hidden: row.is_hidden != 0,
            preference: row.preference,
            corruption_status: TrackCorruptionStatus::from_str(&row.corruption_status)
                .unwrap_or_default(),
            analysis_error: row.analysis_error,
            integrated_lufs: row.integrated_lufs,
            true_peak_db: row.true_peak_db,
            replay_gain_track_db: row.replay_gain_track_db,
            replay_gain_track_peak: row.replay_gain_track_peak,
            waveform_peaks: parse_waveform_peaks(row.waveform_peaks_json.as_deref()),
            analyzed_at: row.analyzed_at,
            meta_policy: policy,
            effective_policy,
            has_user_edits,
            file_layer,
            cloud_layer,
            user_edits_layer,
            effective_layer,
            resolved_lyrics_source,
        }))
    }

    /// Returns user-edited or cloud-preferred inline lyrics from SQLite when set,
    /// so `LyricsManager::get_lyrics` prioritizes manual/cloud track lyrics over file tags
    /// without modifying the original audio file.
    pub async fn get_track_lyrics_override(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Option<String>> {
        let tid = track_id.trim();
        if tid.is_empty() {
            return Ok(None);
        }
        let row: Option<(Option<String>, Option<String>, String)> = sqlx::query_as(
            "SELECT user_edits_json, cloud_meta_json, meta_policy FROM track_sources WHERE id = ?",
        )
        .bind(tid)
        .fetch_optional(pool)
        .await?;
        let Some((user_raw, cloud_raw, policy_raw)) = row else {
            return Ok(None);
        };
        if let Some(lyrics) = TrackMetadataLayer::from_json_opt(user_raw.as_deref())
            .and_then(|l| l.lyrics)
            .filter(|s| !s.trim().is_empty())
        {
            return Ok(Some(lyrics));
        }
        let default_policy = Self::get_default_metadata_policy(pool).await?;
        let policy = MetadataPolicy::from_str(&policy_raw).unwrap_or(MetadataPolicy::Inherit);
        if policy.resolve_effective(default_policy) == MetadataPolicy::Cloud
            && let Some(lyrics) = TrackMetadataLayer::from_json_opt(cloud_raw.as_deref())
                .and_then(|l| l.lyrics)
                .filter(|s| !s.trim().is_empty())
        {
            return Ok(Some(lyrics));
        }
        Ok(None)
    }
}
