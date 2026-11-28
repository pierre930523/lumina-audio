use core_types::{AudioCodec, AudioFormat, FileStatus, TrackSource};
use sqlx::SqlitePool;
use std::str::FromStr;

use super::LibraryRepository;
use super::helpers::{parse_audio_codec, parse_provider_kind};
use super::models::{TrackFileCacheInfo, TrackSourceRow};
use crate::error::Result;
use crate::repository::ingestion::IngestionRepository;

impl LibraryRepository {
    pub async fn get_track_embedded_lyrics(
        pool: &SqlitePool,
        track_id: &str,
    ) -> Result<Option<String>> {
        let row: Option<(Option<String>,)> =
            sqlx::query_as("SELECT embedded_lyrics FROM track_sources WHERE id = ?")
                .bind(track_id)
                .fetch_optional(pool)
                .await?;

        Ok(row.and_then(|(lyrics,)| lyrics))
    }

    pub async fn get_track_file_cache_info(
        pool: &SqlitePool,
        provider_id: &str,
        external_track_id: &str,
    ) -> Result<Option<TrackFileCacheInfo>> {
        let row: Option<TrackFileCacheInfo> = sqlx::query_as(
            "SELECT id AS track_id, version_id, external_track_id, file_mtime, file_size, metadata_hash \
             FROM track_sources WHERE provider_id = ? AND external_track_id = ? LIMIT 1",
        )
        .bind(provider_id)
        .bind(external_track_id)
        .fetch_optional(pool)
        .await?;

        Ok(row)
    }

    pub async fn list_track_file_cache_info(
        pool: &SqlitePool,
        provider_id: &str,
    ) -> Result<Vec<TrackFileCacheInfo>> {
        let rows: Vec<TrackFileCacheInfo> = sqlx::query_as(
            "SELECT id AS track_id, version_id, external_track_id, file_mtime, file_size, metadata_hash \
             FROM track_sources WHERE provider_id = ?",
        )
        .bind(provider_id)
        .fetch_all(pool)
        .await?;

        Ok(rows)
    }

    pub async fn update_track_file_cache_info(
        pool: &SqlitePool,
        track_id: &str,
        file_mtime: Option<i64>,
        file_size: Option<i64>,
        metadata_hash: Option<&str>,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources SET file_mtime = ?, file_size = ?, metadata_hash = ? WHERE id = ?",
        )
        .bind(file_mtime)
        .bind(file_size)
        .bind(metadata_hash)
        .bind(track_id)
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    pub async fn update_track_source_replay_gain(
        pool: &SqlitePool,
        track_id: &str,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE track_sources SET \
                replay_gain_track_db = ?, \
                replay_gain_album_db = ?, \
                replay_gain_track_peak = ?, \
                replay_gain_album_peak = ? \
             WHERE id = ?",
        )
        .bind(track_db)
        .bind(album_db)
        .bind(track_peak)
        .bind(album_peak)
        .bind(track_id)
        .execute(pool)
        .await?;

        Ok(res.rows_affected() > 0)
    }

    pub async fn find_track_sources_by_version(
        pool: &SqlitePool,
        version_id: &str,
    ) -> Result<Vec<TrackSource>> {
        Self::find_track_sources_by_version_with_options(pool, version_id, true).await
    }

    pub async fn find_track_sources_by_version_with_options(
        pool: &SqlitePool,
        version_id: &str,
        include_hidden: bool,
    ) -> Result<Vec<TrackSource>> {
        let sql = if include_hidden {
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics, \
             file_status, manual_version_id, manual_disc_number, preference, \
             is_hidden, release_year, bitrate_kbps, file_size \
             FROM track_sources WHERE version_id = ? AND file_status = 'present' \
             ORDER BY disc_number ASC, track_number ASC, external_track_id ASC, title ASC"
        } else {
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics, \
             file_status, manual_version_id, manual_disc_number, preference, \
             is_hidden, release_year, bitrate_kbps, file_size \
             FROM track_sources WHERE version_id = ? AND file_status = 'present' AND is_hidden = 0 \
             ORDER BY disc_number ASC, track_number ASC, external_track_id ASC, title ASC"
        };
        let rows: Vec<TrackSourceRow> =
            sqlx::query_as(sql).bind(version_id).fetch_all(pool).await?;

        let mut tracks = Self::map_track_rows(rows)?;
        IngestionRepository::apply_track_overrides_batch(pool, &mut tracks).await?;
        Ok(tracks)
    }

    pub async fn find_track_sources_by_isrc(
        pool: &SqlitePool,
        isrc: &str,
    ) -> Result<Vec<TrackSource>> {
        let rows: Vec<TrackSourceRow> = sqlx::query_as(
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics, \
             file_status, manual_version_id, manual_disc_number, preference, \
             is_hidden, release_year, bitrate_kbps, file_size \
             FROM track_sources WHERE isrc = ?",
        )
        .bind(isrc)
        .fetch_all(pool)
        .await?;

        let mut tracks = Self::map_track_rows(rows)?;
        IngestionRepository::apply_track_overrides_batch(pool, &mut tracks).await?;
        Ok(tracks)
    }

    pub async fn find_track_source_by_id(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<TrackSource>> {
        let row: Option<TrackSourceRow> = sqlx::query_as(
            "SELECT id, version_id, provider_id, external_track_id, title, disc_number, \
             track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics, \
             file_status, manual_version_id, manual_disc_number, preference, \
             is_hidden, release_year, bitrate_kbps, file_size \
             FROM track_sources WHERE id = ?",
        )
        .bind(id)
        .fetch_optional(pool)
        .await?;

        match row {
            Some(r) => {
                let mut list = Self::map_track_rows(vec![r])?;
                IngestionRepository::apply_track_overrides_batch(pool, &mut list).await?;
                Ok(list.into_iter().next())
            }
            None => Ok(None),
        }
    }

    fn map_track_rows(rows: Vec<TrackSourceRow>) -> Result<Vec<TrackSource>> {
        let mut tracks = Vec::with_capacity(rows.len());
        for row in rows {
            let provider = parse_provider_kind(&row.provider_id);
            let codec = parse_audio_codec(&row.codec);
            let is_dsd = row.is_dsd != 0 || matches!(codec, AudioCodec::Dsf | AudioCodec::Dsdiff);
            let channels = row.channels.clamp(1, u8::MAX as i64) as u8;
            let file_size_bytes = row.file_size.and_then(|s| u64::try_from(s).ok());
            let duration_ms = row.duration_ms.max(0) as u64;
            let bitrate_kbps = row
                .bitrate_kbps
                .and_then(|b| u32::try_from(b).ok())
                .filter(|&b| b > 0)
                .or_else(|| match (file_size_bytes, duration_ms) {
                    (Some(sz), dur) if sz > 0 && dur > 0 => {
                        u32::try_from((sz.saturating_mul(8)) / dur)
                            .ok()
                            .filter(|&b| b > 0)
                    }
                    _ => None,
                });

            tracks.push(TrackSource {
                id: row.id,
                version_id: row.version_id,
                provider,
                external_track_id: row.external_track_id,
                title: row.title,
                disc_number: row.disc_number as u16,
                track_number: row.track_number as u16,
                duration_ms,
                format: AudioFormat {
                    codec,
                    sample_rate_hz: row.sample_rate_hz as u32,
                    bit_depth: row.bit_depth as u8,
                    channels,
                    is_dsd,
                },
                isrc: row.isrc,
                replay_gain_track_db: row.replay_gain_track_db,
                replay_gain_album_db: row.replay_gain_album_db,
                replay_gain_track_peak: row.replay_gain_track_peak,
                replay_gain_album_peak: row.replay_gain_album_peak,
                artist_name: row.artist_name,
                album_artist: row.album_artist,
                genre: row.genre,
                composer: row.composer,
                cover_url: None,
                artwork_cache_key: None,
                has_lyrics: row.has_lyrics != 0,
                file_status: FileStatus::from_str(&row.file_status).unwrap_or(FileStatus::Present),
                manual_version_id: row.manual_version_id,
                manual_disc_number: row
                    .manual_disc_number
                    .and_then(|d| u32::try_from(d).ok())
                    .filter(|&d| d > 0),
                preference: row.preference,
                is_hidden: row.is_hidden != 0,
                release_year: row.release_year,
                bitrate_kbps,
                file_size_bytes,
            });
        }
        Ok(tracks)
    }
}
