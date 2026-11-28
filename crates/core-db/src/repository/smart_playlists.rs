use chrono::Utc;
use core_types::{
    CreateSmartPlaylistRequest, FocusEntity, FocusFacet, FocusPredicateMode, FocusQuery,
    SmartPlaylistDto, SmartPlaylistEvaluationResponse, UpdateSmartPlaylistRequest,
};
use sqlx::{QueryBuilder, Sqlite, SqlitePool};
use uuid::Uuid;

use crate::error::{DbError, Result};
use crate::repository::CatalogTrackRow;
use crate::repository::focus::{
    FocusCompileScope, compile_focus_query_to_sql, parse_preference_value, push_track_order_by,
};
use crate::repository::tx::ImmediateTx;

const MAX_SMART_PLAYLIST_TRACKS: u32 = 10_000;

#[derive(Debug, sqlx::FromRow)]
struct SmartPlaylistRow {
    id: String,
    name: String,
    description: String,
    focus_query_json: String,
    exclude_banned: i32,
    limit_count: Option<i64>,
    is_pinned: i32,
    sort_order: i64,
    is_system_seed: i32,
    created_at: String,
    updated_at: String,
}

impl From<SmartPlaylistRow> for SmartPlaylistDto {
    fn from(r: SmartPlaylistRow) -> Self {
        Self {
            id: r.id,
            name: r.name,
            description: r.description,
            focus_query_json: r.focus_query_json,
            exclude_banned: r.exclude_banned != 0,
            limit_count: r.limit_count.and_then(|v| u32::try_from(v).ok()),
            is_pinned: r.is_pinned != 0,
            sort_order: r.sort_order,
            is_system_seed: r.is_system_seed != 0,
            created_at: r.created_at,
            updated_at: r.updated_at,
        }
    }
}

fn validate_focus_query_json(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(DbError::ConstraintViolation(
            "Smart playlist focus_query_json must not be empty".into(),
        ));
    }
    let _: FocusQuery = serde_json::from_str(trimmed).map_err(|e| {
        DbError::ConstraintViolation(format!("Invalid smart playlist focus_query_json: {e}"))
    })?;
    Ok(trimmed.to_string())
}

fn normalize_limit_count(limit: Option<u32>) -> Option<u32> {
    limit
        .filter(|&v| v > 0)
        .map(|v| v.min(MAX_SMART_PLAYLIST_TRACKS))
}

pub struct SmartPlaylistRepository;

impl SmartPlaylistRepository {
    pub async fn list_smart_playlists(pool: &SqlitePool) -> Result<Vec<SmartPlaylistDto>> {
        let rows: Vec<SmartPlaylistRow> = sqlx::query_as(
            "SELECT id, name, description, focus_query_json, exclude_banned, limit_count, \
                    is_pinned, sort_order, is_system_seed, created_at, updated_at \
             FROM smart_playlists \
             ORDER BY is_pinned DESC, sort_order ASC, created_at ASC, id ASC",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn get_smart_playlist(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<SmartPlaylistDto>> {
        let row: Option<SmartPlaylistRow> = sqlx::query_as(
            "SELECT id, name, description, focus_query_json, exclude_banned, limit_count, \
                    is_pinned, sort_order, is_system_seed, created_at, updated_at \
             FROM smart_playlists WHERE id = ?",
        )
        .bind(id.trim())
        .fetch_optional(pool)
        .await?;
        Ok(row.map(Into::into))
    }

    pub async fn create_smart_playlist(
        pool: &SqlitePool,
        req: &CreateSmartPlaylistRequest,
    ) -> Result<SmartPlaylistDto> {
        let name = req.name.trim();
        if name.is_empty() {
            return Err(DbError::ConstraintViolation(
                "Smart playlist name must not be empty".into(),
            ));
        }
        let focus_query_json = validate_focus_query_json(&req.focus_query_json)?;
        let limit_count = normalize_limit_count(req.limit_count);
        let description = req.description.trim().to_string();

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<SmartPlaylistDto> = async {
            let sort_order = match req.sort_order {
                Some(v) => v,
                None => {
                    let (next,): (i64,) = sqlx::query_as(
                        "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM smart_playlists",
                    )
                    .fetch_one(tx.conn())
                    .await?;
                    next
                }
            };
            let id = Uuid::new_v4().to_string();
            let now = Utc::now().to_rfc3339();
            sqlx::query(
                "INSERT INTO smart_playlists \
                     (id, name, description, focus_query_json, exclude_banned, limit_count, \
                      is_pinned, sort_order, is_system_seed, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)",
            )
            .bind(&id)
            .bind(name)
            .bind(&description)
            .bind(&focus_query_json)
            .bind(if req.exclude_banned { 1 } else { 0 })
            .bind(limit_count.map(i64::from))
            .bind(if req.is_pinned { 1 } else { 0 })
            .bind(sort_order)
            .bind(&now)
            .bind(&now)
            .execute(tx.conn())
            .await?;

            Ok(SmartPlaylistDto {
                id,
                name: name.to_string(),
                description,
                focus_query_json,
                exclude_banned: req.exclude_banned,
                limit_count,
                is_pinned: req.is_pinned,
                sort_order,
                is_system_seed: false,
                created_at: now.clone(),
                updated_at: now,
            })
        }
        .await;

        match res {
            Ok(created) => {
                tx.commit().await?;
                Ok(created)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    pub async fn update_smart_playlist(
        pool: &SqlitePool,
        req: &UpdateSmartPlaylistRequest,
    ) -> Result<SmartPlaylistDto> {
        let id = req.id.trim();
        if id.is_empty() {
            return Err(DbError::NotFound(
                "Smart playlist id must not be empty".into(),
            ));
        }

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<SmartPlaylistDto> = async {
            let existing: SmartPlaylistRow = sqlx::query_as(
                "SELECT id, name, description, focus_query_json, exclude_banned, limit_count, \
                        is_pinned, sort_order, is_system_seed, created_at, updated_at \
                 FROM smart_playlists WHERE id = ?",
            )
            .bind(id)
            .fetch_optional(tx.conn())
            .await?
            .ok_or_else(|| DbError::NotFound(format!("Smart playlist '{id}' not found")))?;

            let name = match req.name.as_deref() {
                Some(raw) => {
                    let trimmed = raw.trim();
                    if trimmed.is_empty() {
                        return Err(DbError::ConstraintViolation(
                            "Smart playlist name must not be empty".into(),
                        ));
                    }
                    trimmed.to_string()
                }
                None => existing.name,
            };

            let description = match req.description.as_deref() {
                Some(raw) => raw.trim().to_string(),
                None => existing.description,
            };

            let focus_query_json = match req.focus_query_json.as_deref() {
                Some(raw) => validate_focus_query_json(raw)?,
                None => existing.focus_query_json,
            };

            let exclude_banned = req.exclude_banned.unwrap_or(existing.exclude_banned != 0);
            let limit_count = if req.clear_limit {
                None
            } else if req.limit_count.is_some() {
                normalize_limit_count(req.limit_count)
            } else {
                existing.limit_count.and_then(|v| u32::try_from(v).ok())
            };
            let is_pinned = req.is_pinned.unwrap_or(existing.is_pinned != 0);
            let sort_order = req.sort_order.unwrap_or(existing.sort_order);
            let updated_at = Utc::now().to_rfc3339();

            sqlx::query(
                "UPDATE smart_playlists \
                 SET name = ?, description = ?, focus_query_json = ?, exclude_banned = ?, \
                     limit_count = ?, is_pinned = ?, sort_order = ?, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&name)
            .bind(&description)
            .bind(&focus_query_json)
            .bind(if exclude_banned { 1 } else { 0 })
            .bind(limit_count.map(i64::from))
            .bind(if is_pinned { 1 } else { 0 })
            .bind(sort_order)
            .bind(&updated_at)
            .bind(id)
            .execute(tx.conn())
            .await?;

            Ok(SmartPlaylistDto {
                id: existing.id,
                name,
                description,
                focus_query_json,
                exclude_banned,
                limit_count,
                is_pinned,
                sort_order,
                is_system_seed: existing.is_system_seed != 0,
                created_at: existing.created_at,
                updated_at,
            })
        }
        .await;

        match res {
            Ok(updated) => {
                tx.commit().await?;
                Ok(updated)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    pub async fn delete_smart_playlist(pool: &SqlitePool, id: &str) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = sqlx::query("DELETE FROM smart_playlists WHERE id = ?")
            .bind(id.trim())
            .execute(tx.conn())
            .await
            .map(|d| d.rows_affected() > 0)
            .map_err(DbError::from);
        match res {
            Ok(deleted) => {
                tx.commit().await?;
                Ok(deleted)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    pub async fn duplicate_smart_playlist(
        pool: &SqlitePool,
        id: &str,
        new_name: Option<&str>,
    ) -> Result<SmartPlaylistDto> {
        let source = Self::get_smart_playlist(pool, id).await?.ok_or_else(|| {
            DbError::NotFound(format!("Smart playlist '{}' not found", id.trim()))
        })?;

        let copy_name = new_name
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| format!("{} (Copy)", source.name));

        let req = CreateSmartPlaylistRequest {
            name: copy_name,
            description: source.description,
            focus_query_json: source.focus_query_json,
            exclude_banned: source.exclude_banned,
            limit_count: source.limit_count,
            is_pinned: source.is_pinned,
            sort_order: None,
        };
        Self::create_smart_playlist(pool, &req).await
    }

    /// Evaluates a Smart Playlist directly through `compile_focus_query_to_sql` (forced to
    /// `FocusEntity::Tracks`), automatically excluding `trk.preference = -1` when
    /// `exclude_banned` is enabled unless the FocusQuery explicitly includes `preference = -1`.
    pub async fn evaluate_smart_playlist_rows(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<SmartPlaylistEvaluationResponse<CatalogTrackRow>> {
        let playlist = Self::get_smart_playlist(pool, id).await?.ok_or_else(|| {
            DbError::NotFound(format!("Smart playlist '{}' not found", id.trim()))
        })?;

        let mut query: FocusQuery =
            serde_json::from_str(&playlist.focus_query_json).map_err(|e| {
                DbError::ConstraintViolation(format!(
                    "Invalid focus_query_json on smart playlist '{}': {e}",
                    playlist.id
                ))
            })?;
        query.entity = FocusEntity::Tracks;

        let has_explicit_banned_include = query.predicates.iter().any(|p| {
            p.facet == FocusFacet::Preference
                && p.mode == FocusPredicateMode::Include
                && parse_preference_value(&p.value) == Some(-1)
        });
        let apply_exclude_banned = playlist.exclude_banned && !has_explicit_banned_include;

        let scope = FocusCompileScope::for_tracks(query.include_hidden);

        let mut count_qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT COUNT(*) \
             FROM track_sources trk \
             JOIN album_versions ver ON ver.id = trk.version_id \
             JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
             LEFT JOIN artists art ON art.id = alb.primary_artist_id \
             WHERE trk.file_status = 'present'",
        );
        if !query.include_hidden {
            count_qb.push(" AND ver.is_hidden = 0 AND trk.is_hidden = 0");
        }
        if apply_exclude_banned {
            count_qb.push(" AND trk.preference != -1");
        }
        compile_focus_query_to_sql(&mut count_qb, &query, scope, None);
        let (total_i64,): (i64,) = count_qb.build_query_as().fetch_one(pool).await?;
        let total_matched = total_i64.max(0) as u64;

        if total_matched == 0 {
            return Ok(SmartPlaylistEvaluationResponse {
                playlist,
                total_matched: 0,
                tracks: Vec::new(),
            });
        }

        let eff_limit = playlist
            .limit_count
            .map(|l| l.clamp(1, MAX_SMART_PLAYLIST_TRACKS))
            .unwrap_or(MAX_SMART_PLAYLIST_TRACKS);

        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT trk.id, trk.title, \
                    COALESCE(NULLIF(trk.artist_name, ''), COALESCE(art.name, 'Unknown Artist')) AS artist, \
                    COALESCE(alb.title, 'Unknown Album') AS album, trk.duration_ms, trk.sample_rate_hz, \
                    trk.bit_depth, trk.channels, trk.codec, trk.is_dsd, trk.external_track_id, \
                    trk.artist_name, COALESCE(trk.album_artist, alb.album_artist) AS album_artist, trk.genre, \
                    COALESCE(trk.release_year, alb.release_year) AS release_year, trk.track_number, trk.disc_number, trk.composer, \
                    COALESCE(alb.cover_url, alb.merged_cover_path) AS cover_url, \
                    trk.metadata_hash, trk.embedded_lyrics, \
                    alb.id AS alb_id, art.id AS art_id, trk.preference, \
                    trk.is_hidden, trk.file_size, \
                    COALESCE(trk.bitrate_kbps, CASE WHEN trk.file_size > 0 AND trk.duration_ms > 0 THEN CAST(((trk.file_size * 8) / trk.duration_ms) AS INTEGER) ELSE NULL END) AS bitrate_kbps \
             FROM track_sources trk \
             JOIN album_versions ver ON ver.id = trk.version_id \
             JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
             LEFT JOIN artists art ON art.id = alb.primary_artist_id \
             WHERE trk.file_status = 'present'",
        );
        if !query.include_hidden {
            qb.push(" AND ver.is_hidden = 0 AND trk.is_hidden = 0");
        }
        if apply_exclude_banned {
            qb.push(" AND trk.preference != -1");
        }
        compile_focus_query_to_sql(&mut qb, &query, scope, None);
        push_track_order_by(&mut qb, query.sort);
        qb.push(" LIMIT ");
        qb.push_bind(eff_limit as i64);

        let tracks: Vec<CatalogTrackRow> = qb.build_query_as().fetch_all(pool).await?;
        Ok(SmartPlaylistEvaluationResponse {
            playlist,
            total_matched,
            tracks,
        })
    }
}
