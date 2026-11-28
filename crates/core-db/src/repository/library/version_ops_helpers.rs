use chrono::Utc;
use core_types::{AlbumMetadataLayer, CanonicalAlbum, LayeredMetadata};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

use super::LibraryRepository;
use super::helpers::normalize_match_key;
use crate::error::{DbError, Result};
use crate::search::sync_single_album_fts_visibility_conn;

#[derive(Debug, sqlx::FromRow)]
pub(super) struct VersionMetaRow {
    pub(super) id: String,
    pub(super) canonical_album_id: String,
    pub(super) provider_id: String,
    pub(super) codec: String,
    pub(super) sample_rate_hz: i64,
    pub(super) bit_depth: i64,
    pub(super) channels: i64,
    pub(super) is_dsd: i32,
    pub(super) edition_label: Option<String>,
}

pub(super) async fn load_version_meta_tx(
    conn: &mut SqliteConnection,
    version_id: &str,
) -> Result<VersionMetaRow> {
    sqlx::query_as(
        "SELECT id, canonical_album_id, provider_id, codec, sample_rate_hz, \
                bit_depth, channels, is_dsd, edition_label \
         FROM album_versions WHERE id = ?",
    )
    .bind(version_id.trim())
    .fetch_optional(&mut *conn)
    .await?
    .ok_or_else(|| DbError::NotFound(format!("album_version '{version_id}' not found")))
}

pub(super) async fn finalize_groups_tx(
    conn: &mut SqliteConnection,
    candidate_groups: &HashSet<String>,
    preferred_group_id: &str,
) -> Result<(Vec<String>, Option<String>)> {
    let mut surviving = Vec::new();
    let mut preferred_primary = None;
    let mut sorted_groups: Vec<&String> = candidate_groups.iter().collect();
    sorted_groups.sort();

    for gid in sorted_groups {
        let exists: Option<(String,)> =
            sqlx::query_as("SELECT id FROM canonical_albums WHERE id = ?")
                .bind(gid)
                .fetch_optional(&mut *conn)
                .await?;
        if exists.is_some() {
            let primary = LibraryRepository::resolve_primary_version_tx(conn, gid).await?;
            sync_single_album_fts_visibility_conn(conn, gid).await?;
            if gid == preferred_group_id {
                preferred_primary = primary;
            }
            surviving.push(gid.clone());
        }
    }

    Ok((surviving, preferred_primary))
}

#[derive(Debug, sqlx::FromRow)]
struct CloneAlbumRow {
    title: String,
    sort_title: String,
    primary_artist_id: Option<String>,
    album_artist: Option<String>,
    release_year: Option<i32>,
    upc: Option<String>,
    editorial_bio: Option<String>,
    cover_url: Option<String>,
    merged_cover_path: Option<String>,
    normalized_title: Option<String>,
    normalized_artist: Option<String>,
    enriched_at: Option<String>,
    file_meta_json: Option<String>,
    cloud_meta_json: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
}

/// Clones a `canonical_albums` row into a fresh group ID with `musicbrainz_release_group_id = NULL`,
/// `primary_version_id = NULL`, and `is_primary_locked = 0`, also copying `album_credits`.
pub(super) async fn clone_canonical_album_tx(
    conn: &mut SqliteConnection,
    source_album_id: &str,
    override_title: Option<&str>,
) -> Result<String> {
    let row: Option<CloneAlbumRow> = sqlx::query_as(
        "SELECT title, sort_title, primary_artist_id, album_artist, release_year, upc, \
                editorial_bio, cover_url, merged_cover_path, normalized_title, normalized_artist, \
                enriched_at, file_meta_json, cloud_meta_json, user_edits_json, meta_policy \
         FROM canonical_albums WHERE id = ?",
    )
    .bind(source_album_id)
    .fetch_optional(&mut *conn)
    .await?;

    let Some(src) = row else {
        return Err(DbError::NotFound(format!(
            "canonical_album '{source_album_id}' not found"
        )));
    };

    let new_id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let clean_override = override_title.map(str::trim).filter(|s| !s.is_empty());

    let (title, sort_title, norm_title, user_edits_json) = if let Some(new_title) = clean_override {
        let st = CanonicalAlbum::derive_sort_title(new_title);
        let nt = normalize_match_key(new_title);
        let mut user_layer =
            AlbumMetadataLayer::from_json_opt(src.user_edits_json.as_deref()).unwrap_or_default();
        user_layer.merge_from(&AlbumMetadataLayer {
            title: Some(new_title.to_string()),
            sort_title: Some(st.clone()),
            ..Default::default()
        });
        (
            new_title.to_string(),
            st,
            Some(nt),
            user_layer.to_json_opt(),
        )
    } else {
        (
            src.title,
            src.sort_title,
            src.normalized_title,
            src.user_edits_json,
        )
    };

    sqlx::query(
        "INSERT INTO canonical_albums ( \
            id, title, sort_title, primary_artist_id, album_artist, release_year, upc, \
            musicbrainz_release_group_id, editorial_bio, cover_url, merged_cover_path, \
            normalized_title, normalized_artist, enriched_at, created_at, \
            file_meta_json, cloud_meta_json, user_edits_json, meta_policy, \
            primary_version_id, is_primary_locked \
         ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0)",
    )
    .bind(&new_id)
    .bind(&title)
    .bind(&sort_title)
    .bind(&src.primary_artist_id)
    .bind(&src.album_artist)
    .bind(src.release_year)
    .bind(&src.upc)
    .bind(&src.editorial_bio)
    .bind(&src.cover_url)
    .bind(&src.merged_cover_path)
    .bind(&norm_title)
    .bind(&src.normalized_artist)
    .bind(&src.enriched_at)
    .bind(&now)
    .bind(&src.file_meta_json)
    .bind(&src.cloud_meta_json)
    .bind(&user_edits_json)
    .bind(&src.meta_policy)
    .execute(&mut *conn)
    .await?;

    sqlx::query(
        "INSERT OR IGNORE INTO album_credits (canonical_album_id, artist_id, role) \
         SELECT ?, artist_id, role FROM album_credits WHERE canonical_album_id = ?",
    )
    .bind(&new_id)
    .bind(source_album_id)
    .execute(&mut *conn)
    .await?;

    Ok(new_id)
}

/// Migrates `album_credits`, `profile_favorites`, `artwork_overrides`, and `artwork_cache`
/// from `source_album_id` to `target_album_id` when a source group is merged or emptied.
pub(super) async fn migrate_album_group_refs_tx(
    conn: &mut SqliteConnection,
    target_album_id: &str,
    source_album_id: &str,
) -> Result<()> {
    if target_album_id == source_album_id {
        return Ok(());
    }

    sqlx::query(
        "INSERT OR IGNORE INTO album_credits (canonical_album_id, artist_id, role) \
         SELECT ?, artist_id, role FROM album_credits WHERE canonical_album_id = ?",
    )
    .bind(target_album_id)
    .bind(source_album_id)
    .execute(&mut *conn)
    .await?;

    sqlx::query(
        "INSERT OR IGNORE INTO profile_favorites (profile_id, item_type, item_id, created_at) \
         SELECT profile_id, item_type, ?, created_at FROM profile_favorites \
         WHERE item_type = 'album' AND item_id = ?",
    )
    .bind(target_album_id)
    .bind(source_album_id)
    .execute(&mut *conn)
    .await?;

    sqlx::query(
        "INSERT OR IGNORE INTO artwork_overrides (target_kind, target_id, image_path, updated_at) \
         SELECT target_kind, ?, image_path, updated_at FROM artwork_overrides \
         WHERE target_kind = 'album' AND target_id = ?",
    )
    .bind(target_album_id)
    .bind(source_album_id)
    .execute(&mut *conn)
    .await?;

    sqlx::query("UPDATE artwork_cache SET album_id = ? WHERE album_id = ?")
        .bind(target_album_id)
        .bind(source_album_id)
        .execute(&mut *conn)
        .await?;

    super::rebuild_step4::migrate_album_step4_refs_tx(conn, target_album_id, source_album_id)
        .await?;

    Ok(())
}

/// Migrates `canonical_tracks.canonical_album_id` for `track_ids` to `target_album_id`.
/// If a `canonical_track` is still shared by tracks in another album group, detaches the moved
/// track's `canonical_track_id` to `NULL` so neither group corrupts the other.
pub(super) async fn migrate_canonical_tracks_for_track_ids_tx(
    conn: &mut SqliteConnection,
    track_ids: &[String],
    target_album_id: &str,
) -> Result<()> {
    if track_ids.is_empty() {
        return Ok(());
    }

    let moved_set: HashSet<&str> = track_ids.iter().map(String::as_str).collect();
    let mut ct_ids: HashSet<String> = HashSet::new();

    for chunk in track_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT DISTINCT canonical_track_id FROM track_sources \
             WHERE canonical_track_id IS NOT NULL AND id IN (",
        );
        let mut sep = qb.separated(", ");
        for tid in chunk {
            sep.push_bind(tid);
        }
        sep.push_unseparated(")");
        let rows: Vec<(String,)> = qb.build_query_as().fetch_all(&mut *conn).await?;
        for (ctid,) in rows {
            ct_ids.insert(ctid);
        }
    }

    for ctid in ct_ids {
        let linked_tracks: Vec<(String, String)> = sqlx::query_as(
            "SELECT ts.id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.canonical_track_id = ?",
        )
        .bind(&ctid)
        .fetch_all(&mut *conn)
        .await?;

        let shared_with_other_group = linked_tracks
            .iter()
            .any(|(tid, aid)| !moved_set.contains(tid.as_str()) && aid != target_album_id);

        if shared_with_other_group {
            for (tid, _) in &linked_tracks {
                if moved_set.contains(tid.as_str()) {
                    sqlx::query("UPDATE track_sources SET canonical_track_id = NULL WHERE id = ?")
                        .bind(tid)
                        .execute(&mut *conn)
                        .await?;
                }
            }
        } else {
            sqlx::query("UPDATE canonical_tracks SET canonical_album_id = ? WHERE id = ?")
                .bind(target_album_id)
                .bind(&ctid)
                .execute(&mut *conn)
                .await?;
        }
    }

    Ok(())
}

/// Derives representative `(codec, sample_rate_hz, bit_depth, channels, is_dsd)` from `track_ids`.
pub(super) async fn derive_representative_format_tx(
    conn: &mut SqliteConnection,
    track_ids: &[String],
    fallback: (&str, i64, i64, i64, i32),
) -> Result<(String, i64, i64, i64, i32)> {
    if track_ids.is_empty() {
        return Ok((
            fallback.0.to_string(),
            fallback.1,
            fallback.2,
            fallback.3,
            fallback.4,
        ));
    }
    let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
        "SELECT codec, sample_rate_hz, bit_depth, channels, is_dsd \
         FROM track_sources WHERE id IN (",
    );
    let mut sep = qb.separated(", ");
    for tid in track_ids.iter().take(500) {
        sep.push_bind(tid);
    }
    sep.push_unseparated(
        ") ORDER BY is_dsd DESC, sample_rate_hz DESC, bit_depth DESC, id ASC LIMIT 1",
    );
    let row: Option<(String, i64, i64, i64, i32)> =
        qb.build_query_as().fetch_optional(&mut *conn).await?;
    Ok(row.unwrap_or_else(|| {
        (
            fallback.0.to_string(),
            fallback.1,
            fallback.2,
            fallback.3,
            fallback.4,
        )
    }))
}

// ============================================================================
// Scanner & Dedup Compatibility Helpers (for `core-providers`)
// ============================================================================

impl LibraryRepository {
    /// Batch-fetches manual track locks `(manual_version_id, manual_disc_number)` for existing
    /// tracks keyed by `external_track_id`.
    pub async fn get_manual_track_locks_batch_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        external_track_ids: &[String],
    ) -> Result<HashMap<String, (Option<String>, Option<u32>)>> {
        let mut out = HashMap::new();
        if external_track_ids.is_empty() {
            return Ok(out);
        }
        let prov = provider_id.trim();
        for chunk in external_track_ids.chunks(450) {
            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                "SELECT external_track_id, manual_version_id, manual_disc_number \
                 FROM track_sources \
                 WHERE provider_id = ",
            );
            qb.push_bind(prov);
            qb.push(
                " AND (manual_version_id IS NOT NULL OR manual_disc_number IS NOT NULL) \
                  AND external_track_id IN (",
            );
            let mut sep = qb.separated(", ");
            for ext_id in chunk {
                sep.push_bind(ext_id);
            }
            sep.push_unseparated(")");
            let rows: Vec<(String, Option<String>, Option<i64>)> =
                qb.build_query_as().fetch_all(&mut *conn).await?;
            for (ext_id, mvid, mdisc) in rows {
                let disc_u32 = mdisc.and_then(|d| u32::try_from(d).ok()).filter(|&d| d > 0);
                out.insert(ext_id, (mvid, disc_u32));
            }
        }
        Ok(out)
    }

    pub async fn get_manual_track_locks_batch(
        pool: &SqlitePool,
        provider_id: &str,
        external_track_ids: &[String],
    ) -> Result<HashMap<String, (Option<String>, Option<u32>)>> {
        let mut conn = pool.acquire().await?;
        Self::get_manual_track_locks_batch_tx(&mut conn, provider_id, external_track_ids).await
    }

    /// Returns `true` if `album_id` contains at least one version with `manual_group_id IS NOT NULL`.
    pub async fn album_has_manual_group_lock_tx(
        conn: &mut SqliteConnection,
        album_id: &str,
    ) -> Result<bool> {
        let row: Option<(i32,)> = sqlx::query_as(
            "SELECT 1 FROM album_versions \
             WHERE canonical_album_id = ? AND manual_group_id IS NOT NULL LIMIT 1",
        )
        .bind(album_id.trim())
        .fetch_optional(&mut *conn)
        .await?;
        Ok(row.is_some())
    }

    pub async fn album_has_manual_group_lock(pool: &SqlitePool, album_id: &str) -> Result<bool> {
        let mut conn = pool.acquire().await?;
        Self::album_has_manual_group_lock_tx(&mut conn, album_id).await
    }

    /// Returns the set of `canonical_album_id`s that have at least one version with a manual group lock.
    pub async fn list_manually_locked_album_ids_tx(
        conn: &mut SqliteConnection,
    ) -> Result<HashSet<String>> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT DISTINCT canonical_album_id FROM album_versions WHERE manual_group_id IS NOT NULL",
        )
        .fetch_all(&mut *conn)
        .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    pub async fn list_manually_locked_album_ids(pool: &SqlitePool) -> Result<HashSet<String>> {
        let mut conn = pool.acquire().await?;
        Self::list_manually_locked_album_ids_tx(&mut conn).await
    }

    /// Looks up `(version_id, manual_group_id)` for an existing `(provider_id, external_album_id)`.
    pub async fn version_manual_group_id_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        external_album_id: &str,
    ) -> Result<Option<(String, Option<String>)>> {
        let row: Option<(String, Option<String>)> = sqlx::query_as(
            "SELECT id, manual_group_id FROM album_versions \
             WHERE provider_id = ? AND external_album_id = ? LIMIT 1",
        )
        .bind(provider_id.trim())
        .bind(external_album_id.trim())
        .fetch_optional(&mut *conn)
        .await?;
        Ok(row)
    }
}
