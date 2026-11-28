use core_types::{
    AlbumVersion, AlbumVersionOpResult, AudioCodec, AudioFormat, FileStatus, TrackSource,
    compute_version_quality_score_with_context,
};
use sqlx::{SqliteConnection, SqlitePool};
use std::collections::{HashMap, HashSet};

use super::LibraryRepository;
use super::helpers::{parse_audio_codec, parse_provider_kind};
use crate::error::{DbError, Result};
use crate::search::sync_single_album_fts_visibility_conn;
use crate::write_coordinator::DbWriteCoordinator;

#[derive(Debug, sqlx::FromRow)]
struct ScoringVersionRow {
    id: String,
    canonical_album_id: String,
    provider_id: String,
    external_album_id: String,
    codec: String,
    sample_rate_hz: i64,
    bit_depth: i64,
    channels: i64,
    is_dsd: i32,
    edition_label: Option<String>,
    is_hidden: i32,
    manual_group_id: Option<String>,
}

#[derive(Debug, sqlx::FromRow)]
struct ScoringTrackRow {
    id: String,
    version_id: String,
    provider_id: String,
    external_track_id: String,
    title: String,
    disc_number: i64,
    manual_disc_number: Option<i64>,
    track_number: i64,
    duration_ms: i64,
    sample_rate_hz: i64,
    bit_depth: i64,
    channels: i64,
    codec: String,
    is_dsd: i32,
}

struct EvaluatedVersion {
    id: String,
    is_hidden: bool,
    present_count: usize,
    is_local: bool,
    sample_rate_hz: i64,
    bit_depth: i64,
    quality_score: f64,
}

impl LibraryRepository {
    /// Recomputes `quality_score`, `track_count`, and `disc_count` for all versions in `group_id`
    /// and updates `canonical_albums.primary_version_id` (+ `is_primary_locked` when invalidated).
    pub async fn resolve_primary_version_tx(
        conn: &mut SqliteConnection,
        group_id: &str,
    ) -> Result<Option<String>> {
        let gid = group_id.trim();
        let group_row: Option<(Option<String>, i32)> = sqlx::query_as(
            "SELECT primary_version_id, is_primary_locked FROM canonical_albums WHERE id = ?",
        )
        .bind(gid)
        .fetch_optional(&mut *conn)
        .await?;

        let Some((current_primary, current_locked)) = group_row else {
            return Ok(None);
        };

        let ver_rows: Vec<ScoringVersionRow> = sqlx::query_as(
            "SELECT id, canonical_album_id, provider_id, external_album_id, codec, \
                    sample_rate_hz, bit_depth, channels, is_dsd, edition_label, \
                    is_hidden, manual_group_id \
             FROM album_versions WHERE canonical_album_id = ?",
        )
        .bind(gid)
        .fetch_all(&mut *conn)
        .await?;

        if ver_rows.is_empty() {
            sqlx::query(
                "UPDATE canonical_albums SET primary_version_id = NULL, is_primary_locked = 0 WHERE id = ?",
            )
            .bind(gid)
            .execute(&mut *conn)
            .await?;
            return Ok(None);
        }

        let track_rows: Vec<ScoringTrackRow> = sqlx::query_as(
            "SELECT ts.id, ts.version_id, ts.provider_id, ts.external_track_id, ts.title, \
                    ts.disc_number, ts.manual_disc_number, ts.track_number, ts.duration_ms, \
                    ts.sample_rate_hz, ts.bit_depth, ts.channels, ts.codec, ts.is_dsd \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE av.canonical_album_id = ? AND ts.file_status = 'present'",
        )
        .bind(gid)
        .fetch_all(&mut *conn)
        .await?;

        let mut tracks_by_ver: HashMap<String, Vec<TrackSource>> = HashMap::new();
        for tr in track_rows {
            let codec = parse_audio_codec(&tr.codec);
            let is_dsd = tr.is_dsd != 0 || matches!(codec, AudioCodec::Dsf | AudioCodec::Dsdiff);
            let mut ts = TrackSource {
                id: tr.id,
                version_id: tr.version_id.clone(),
                provider: parse_provider_kind(&tr.provider_id),
                external_track_id: tr.external_track_id,
                title: tr.title,
                disc_number: tr.disc_number.clamp(1, i64::from(u16::MAX)) as u16,
                track_number: tr.track_number.clamp(1, i64::from(u16::MAX)) as u16,
                duration_ms: tr.duration_ms.max(0) as u64,
                format: AudioFormat {
                    codec,
                    sample_rate_hz: tr.sample_rate_hz.max(0) as u32,
                    bit_depth: tr.bit_depth.clamp(0, i64::from(u8::MAX)) as u8,
                    channels: tr.channels.clamp(1, i64::from(u8::MAX)) as u8,
                    is_dsd,
                },
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
                manual_disc_number: tr
                    .manual_disc_number
                    .and_then(|d| u32::try_from(d).ok())
                    .filter(|&d| d > 0),
                preference: 0,
                is_hidden: false,
                release_year: None,
                bitrate_kbps: None,
                file_size_bytes: None,
            };
            if let Some(md) = ts.manual_disc_number {
                ts.disc_number = md.min(u32::from(u16::MAX)) as u16;
            }
            tracks_by_ver.entry(tr.version_id).or_default().push(ts);
        }

        let group_max_tracks = tracks_by_ver
            .values()
            .map(Vec::len)
            .max()
            .filter(|&m| m > 0);

        let mut evaluated = Vec::with_capacity(ver_rows.len());
        for vr in ver_rows {
            let present_tracks = tracks_by_ver.remove(&vr.id).unwrap_or_default();
            let present_count = present_tracks.len();
            let disc_set: HashSet<u32> = present_tracks
                .iter()
                .map(|t| {
                    t.manual_disc_number
                        .unwrap_or_else(|| u32::from(t.disc_number))
                        .max(1)
                })
                .collect();
            let disc_count = disc_set.len().max(1) as i64;

            let codec = parse_audio_codec(&vr.codec);
            let is_dsd = vr.is_dsd != 0 || codec.is_dsd();
            let ver_dto = AlbumVersion {
                id: vr.id.clone(),
                canonical_album_id: vr.canonical_album_id,
                provider: parse_provider_kind(&vr.provider_id),
                external_album_id: vr.external_album_id,
                format: AudioFormat {
                    codec,
                    sample_rate_hz: vr.sample_rate_hz.max(0) as u32,
                    bit_depth: vr.bit_depth.clamp(0, i64::from(u8::MAX)) as u8,
                    channels: vr.channels.clamp(1, i64::from(u8::MAX)) as u8,
                    is_dsd,
                },
                edition_label: vr.edition_label,
                is_primary: false,
                is_hidden: vr.is_hidden != 0,
                quality_score: 0.0,
                manual_group_id: vr.manual_group_id,
                disc_count: disc_count as u32,
                track_count: present_count as u32,
                has_manual_tracks: false,
            };

            let score = compute_version_quality_score_with_context(
                &ver_dto,
                &present_tracks,
                group_max_tracks,
            );

            sqlx::query(
                "UPDATE album_versions \
                 SET quality_score = ?, track_count = ?, disc_count = ? \
                 WHERE id = ?",
            )
            .bind(score)
            .bind(present_count as i64)
            .bind(disc_count)
            .bind(&vr.id)
            .execute(&mut *conn)
            .await?;

            evaluated.push(EvaluatedVersion {
                id: vr.id,
                is_hidden: vr.is_hidden != 0,
                present_count,
                is_local: vr.provider_id.eq_ignore_ascii_case("local"),
                sample_rate_hz: vr.sample_rate_hz,
                bit_depth: vr.bit_depth,
                quality_score: score,
            });
        }

        // Keep locked primary if it still belongs to this group, is visible, and has >0 present tracks.
        if current_locked != 0
            && let Some(ref cur_id) = current_primary
            && evaluated
                .iter()
                .any(|v| v.id == *cur_id && !v.is_hidden && v.present_count > 0)
        {
            return Ok(Some(cur_id.clone()));
        }

        let mut candidates: Vec<&EvaluatedVersion> = evaluated
            .iter()
            .filter(|v| v.present_count > 0 && !v.is_hidden)
            .collect();
        if candidates.is_empty() {
            candidates = evaluated.iter().filter(|v| v.present_count > 0).collect();
        }

        candidates.sort_by(|a, b| {
            b.quality_score
                .total_cmp(&a.quality_score)
                .then_with(|| b.present_count.cmp(&a.present_count))
                .then_with(|| b.is_local.cmp(&a.is_local))
                .then_with(|| b.sample_rate_hz.cmp(&a.sample_rate_hz))
                .then_with(|| b.bit_depth.cmp(&a.bit_depth))
                .then_with(|| a.id.cmp(&b.id))
        });

        let chosen = candidates.first().map(|v| v.id.clone());
        sqlx::query(
            "UPDATE canonical_albums SET primary_version_id = ?, is_primary_locked = 0 WHERE id = ?",
        )
        .bind(&chosen)
        .bind(gid)
        .execute(&mut *conn)
        .await?;

        Ok(chosen)
    }

    pub async fn resolve_primary_version(
        pool: &SqlitePool,
        group_id: &str,
    ) -> Result<Option<String>> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::resolve_primary_version_tx(tx.conn(), group_id).await;
        match res {
            Ok(id) => {
                tx.commit().await?;
                Ok(id)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Pins `version_id` as the locked primary version of `group_id` (validating >0 present tracks,
    /// unhiding if hidden, setting `is_primary_locked = 1`, and syncing FTS).
    pub async fn set_primary_version_tx(
        conn: &mut SqliteConnection,
        group_id: &str,
        version_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let gid = group_id.trim();
        let vid = version_id.trim();
        let row: Option<(String, i64)> = sqlx::query_as(
            "SELECT av.canonical_album_id, \
                    (SELECT COUNT(*) FROM track_sources ts WHERE ts.version_id = av.id AND ts.file_status = 'present') \
             FROM album_versions av WHERE av.id = ?",
        )
        .bind(vid)
        .fetch_optional(&mut *conn)
        .await?;

        let Some((actual_gid, present_cnt)) = row else {
            return Err(DbError::NotFound(format!(
                "album_version '{vid}' not found"
            )));
        };
        if actual_gid != gid {
            return Err(DbError::ConstraintViolation(format!(
                "album_version '{vid}' does not belong to album group '{gid}'"
            )));
        }
        if present_cnt <= 0 {
            return Err(DbError::ConstraintViolation(format!(
                "album_version '{vid}' has no present tracks and cannot be set as primary"
            )));
        }

        sqlx::query("UPDATE album_versions SET is_hidden = 0 WHERE id = ?")
            .bind(vid)
            .execute(&mut *conn)
            .await?;

        sqlx::query(
            "UPDATE canonical_albums SET primary_version_id = ?, is_primary_locked = 1 WHERE id = ?",
        )
        .bind(vid)
        .bind(gid)
        .execute(&mut *conn)
        .await?;

        let primary = Self::resolve_primary_version_tx(conn, gid).await?;
        sync_single_album_fts_visibility_conn(conn, gid).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: vec![gid.to_string()],
            affected_version_ids: vec![vid.to_string()],
            primary_version_id: primary,
            ..Default::default()
        })
    }

    pub async fn set_primary_version(
        pool: &SqlitePool,
        group_id: &str,
        version_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::set_primary_version_tx(tx.conn(), group_id, version_id).await;
        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Clears `is_primary_locked` on `group_id` and re-selects primary version automatically.
    pub async fn reset_primary_version_tx(
        conn: &mut SqliteConnection,
        group_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let gid = group_id.trim();
        let res = sqlx::query("UPDATE canonical_albums SET is_primary_locked = 0 WHERE id = ?")
            .bind(gid)
            .execute(&mut *conn)
            .await?;
        if res.rows_affected() == 0 {
            return Err(DbError::NotFound(format!(
                "canonical_album '{gid}' not found"
            )));
        }

        let primary = Self::resolve_primary_version_tx(conn, gid).await?;
        sync_single_album_fts_visibility_conn(conn, gid).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: vec![gid.to_string()],
            affected_version_ids: primary.iter().cloned().collect(),
            primary_version_id: primary,
            ..Default::default()
        })
    }

    pub async fn reset_primary_version(
        pool: &SqlitePool,
        group_id: &str,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::reset_primary_version_tx(tx.conn(), group_id).await;
        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    /// Hides or unhides an `album_versions` row. If hiding the current primary version,
    /// clears `is_primary_locked`, auto-switches primary to the best remaining visible version,
    /// and updates `search_fts` visibility.
    pub async fn set_version_hidden_tx(
        conn: &mut SqliteConnection,
        version_id: &str,
        is_hidden: bool,
    ) -> Result<AlbumVersionOpResult> {
        let vid = version_id.trim();
        let row: Option<(String, Option<String>)> = sqlx::query_as(
            "SELECT av.canonical_album_id, ca.primary_version_id \
             FROM album_versions av \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE av.id = ?",
        )
        .bind(vid)
        .fetch_optional(&mut *conn)
        .await?;

        let Some((gid, current_primary)) = row else {
            return Err(DbError::NotFound(format!(
                "album_version '{vid}' not found"
            )));
        };

        sqlx::query("UPDATE album_versions SET is_hidden = ? WHERE id = ?")
            .bind(if is_hidden { 1i32 } else { 0i32 })
            .bind(vid)
            .execute(&mut *conn)
            .await?;

        if is_hidden && current_primary.as_deref() == Some(vid) {
            sqlx::query("UPDATE canonical_albums SET is_primary_locked = 0 WHERE id = ?")
                .bind(&gid)
                .execute(&mut *conn)
                .await?;
        }

        let primary = Self::resolve_primary_version_tx(conn, &gid).await?;
        sync_single_album_fts_visibility_conn(conn, &gid).await?;

        Ok(AlbumVersionOpResult {
            affected_group_ids: vec![gid],
            affected_version_ids: vec![vid.to_string()],
            primary_version_id: primary,
            ..Default::default()
        })
    }

    pub async fn set_version_hidden(
        pool: &SqlitePool,
        version_id: &str,
        is_hidden: bool,
    ) -> Result<AlbumVersionOpResult> {
        let coord = DbWriteCoordinator::for_pool(pool);
        let (_guard, mut tx) = coord.begin_immediate(pool).await?;
        let res = Self::set_version_hidden_tx(tx.conn(), version_id, is_hidden).await;
        match res {
            Ok(out) => {
                tx.commit().await?;
                Ok(out)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
