use core_types::{AlbumMetadataLayer, LayeredMetadata};
use sqlx::SqlitePool;
use std::collections::HashMap;

use super::LibraryRepository;
use super::helpers::normalize_match_key;
use super::models::{DedupAlbumCandidateRow, MergeAlbumSourceRow};
use crate::error::Result;
use crate::repository::tx::ImmediateTx;

#[derive(sqlx::FromRow)]
struct TargetAlbumLayersRow {
    file_meta_json: Option<String>,
    cloud_meta_json: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
}

fn merge_album_layer_json(target_raw: Option<&str>, source_raw: Option<&str>) -> Option<String> {
    let mut merged = AlbumMetadataLayer::from_json_opt(source_raw).unwrap_or_default();
    if let Some(target_layer) = AlbumMetadataLayer::from_json_opt(target_raw) {
        merged.merge_from(&target_layer);
    }
    merged.to_json_opt()
}

impl LibraryRepository {
    pub async fn merge_canonical_albums(
        pool: &SqlitePool,
        target_album_id: &str,
        source_album_id: &str,
    ) -> Result<bool> {
        if target_album_id == source_album_id {
            return Ok(false);
        }

        let mut tx = ImmediateTx::begin(pool).await?;

        let target_layers: Option<TargetAlbumLayersRow> = sqlx::query_as(
            "SELECT file_meta_json, cloud_meta_json, user_edits_json, meta_policy \
             FROM canonical_albums WHERE id = ?",
        )
        .bind(target_album_id)
        .fetch_optional(tx.conn())
        .await?;
        let source_row: Option<MergeAlbumSourceRow> = sqlx::query_as(
            "SELECT primary_artist_id, album_artist, release_year, upc, musicbrainz_release_group_id, \
             editorial_bio, cover_url, merged_cover_path, normalized_title, normalized_artist, enriched_at, \
             file_meta_json, cloud_meta_json, user_edits_json, meta_policy \
             FROM canonical_albums WHERE id = ?",
        )
        .bind(source_album_id)
        .fetch_optional(tx.conn())
        .await?;

        let (Some(tgt), Some(src)) = (target_layers, source_row) else {
            tx.rollback().await?;
            return Ok(false);
        };

        let merged_file =
            merge_album_layer_json(tgt.file_meta_json.as_deref(), src.file_meta_json.as_deref());
        let merged_cloud = merge_album_layer_json(
            tgt.cloud_meta_json.as_deref(),
            src.cloud_meta_json.as_deref(),
        );
        let merged_user = merge_album_layer_json(
            tgt.user_edits_json.as_deref(),
            src.user_edits_json.as_deref(),
        );
        let merged_policy = if tgt.meta_policy != "inherit" {
            tgt.meta_policy
        } else {
            src.meta_policy.clone()
        };

        let res: Result<()> = async {
            // Clear source's UNIQUE musicbrainz_release_group_id first so COALESCE onto target cannot collide.
            sqlx::query(
                "UPDATE canonical_albums SET musicbrainz_release_group_id = NULL WHERE id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "UPDATE canonical_albums SET \
                    primary_artist_id = COALESCE(primary_artist_id, ?), \
                    album_artist = COALESCE(album_artist, ?), \
                    release_year = COALESCE(release_year, ?), \
                    upc = COALESCE(upc, ?), \
                    musicbrainz_release_group_id = COALESCE(musicbrainz_release_group_id, ?), \
                    editorial_bio = COALESCE(editorial_bio, ?), \
                    cover_url = COALESCE(cover_url, ?), \
                    merged_cover_path = COALESCE(merged_cover_path, ?), \
                    normalized_title = COALESCE(normalized_title, ?), \
                    normalized_artist = COALESCE(normalized_artist, ?), \
                    enriched_at = COALESCE(enriched_at, ?), \
                    file_meta_json = ?, \
                    cloud_meta_json = ?, \
                    user_edits_json = ?, \
                    meta_policy = ? \
                 WHERE id = ?",
            )
            .bind(&src.primary_artist_id)
            .bind(&src.album_artist)
            .bind(src.release_year)
            .bind(&src.upc)
            .bind(&src.musicbrainz_release_group_id)
            .bind(&src.editorial_bio)
            .bind(&src.cover_url)
            .bind(&src.merged_cover_path)
            .bind(&src.normalized_title)
            .bind(&src.normalized_artist)
            .bind(&src.enriched_at)
            .bind(&merged_file)
            .bind(&merged_cloud)
            .bind(&merged_user)
            .bind(&merged_policy)
            .bind(target_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "INSERT OR IGNORE INTO metadata_overrides \
                    (entity_type, entity_id, field_name, value_json, source_layer, updated_at) \
                 SELECT entity_type, ?, field_name, value_json, source_layer, updated_at \
                 FROM metadata_overrides \
                 WHERE entity_type = 'album' AND entity_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "DELETE FROM metadata_overrides WHERE entity_type = 'album' AND entity_id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "UPDATE album_versions SET canonical_album_id = ? WHERE canonical_album_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "UPDATE canonical_tracks SET canonical_album_id = ? WHERE canonical_album_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query("UPDATE artwork_cache SET album_id = ? WHERE album_id = ?")
                .bind(target_album_id)
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            sqlx::query(
                "INSERT OR IGNORE INTO album_credits (canonical_album_id, artist_id, role) \
                 SELECT ?, artist_id, role FROM album_credits WHERE canonical_album_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query("DELETE FROM album_credits WHERE canonical_album_id = ?")
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            sqlx::query(
                "INSERT OR IGNORE INTO profile_favorites (profile_id, item_type, item_id, created_at) \
                 SELECT profile_id, item_type, ?, created_at FROM profile_favorites \
                 WHERE item_type = 'album' AND item_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "INSERT OR IGNORE INTO tag_items (tag_id, entity_type, entity_id, created_at) \
                 SELECT tag_id, entity_type, ?, created_at FROM tag_items \
                 WHERE entity_type = 'album_group' AND entity_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query(
                "DELETE FROM tag_items WHERE entity_type = 'album_group' AND entity_id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            super::rebuild_step4::migrate_album_step4_refs_tx(
                tx.conn(),
                target_album_id,
                source_album_id,
            )
            .await?;

            let migrated = sqlx::query(
                "INSERT OR IGNORE INTO artwork_overrides (target_kind, target_id, image_path, updated_at) \
                 SELECT target_kind, ?, image_path, updated_at FROM artwork_overrides \
                 WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(target_album_id)
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            if migrated.rows_affected() > 0 {
                sqlx::query("DELETE FROM artwork_cache WHERE album_id = ?")
                    .bind(target_album_id)
                    .execute(tx.conn())
                    .await?;
            }

            sqlx::query(
                "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id = ?",
            )
            .bind(source_album_id)
            .execute(tx.conn())
            .await?;

            sqlx::query("DELETE FROM search_fts WHERE entity_type = 'album' AND entity_id = ?")
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            sqlx::query("DELETE FROM canonical_albums WHERE id = ?")
                .bind(source_album_id)
                .execute(tx.conn())
                .await?;

            let _ = Self::resolve_primary_version_tx(tx.conn(), target_album_id).await?;

            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(true)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn deduplicate_canonical_albums(pool: &SqlitePool) -> Result<usize> {
        let rows: Vec<DedupAlbumCandidateRow> = sqlx::query_as(
            "SELECT ca.id, ca.title, ar.name AS artist_name, ca.normalized_title, \
             ca.normalized_artist, ca.upc, ca.musicbrainz_release_group_id, \
             COALESCE(ca.cover_url, ca.merged_cover_path) AS cover_url \
             FROM canonical_albums ca \
             LEFT JOIN artists ar ON ca.primary_artist_id = ar.id \
             WHERE NOT EXISTS ( \
                 SELECT 1 FROM album_versions av \
                 WHERE av.canonical_album_id = ca.id \
                   AND av.manual_group_id IS NOT NULL \
             ) \
             ORDER BY ca.created_at ASC, ca.id ASC",
        )
        .fetch_all(pool)
        .await?;

        if rows.len() < 2 {
            return Ok(0);
        }

        let n = rows.len();
        let mut idx_by_id = HashMap::with_capacity(n);
        for (i, r) in rows.iter().enumerate() {
            idx_by_id.insert(r.id.as_str(), i);
        }

        let mut parent: Vec<usize> = (0..n).collect();
        fn find(parent: &mut [usize], mut x: usize) -> usize {
            while parent[x] != x {
                parent[x] = parent[parent[x]];
                x = parent[x];
            }
            x
        }
        fn union(parent: &mut [usize], a: usize, b: usize) {
            let ra = find(parent, a);
            let rb = find(parent, b);
            if ra != rb {
                parent[rb] = ra;
            }
        }

        let mut by_mb: HashMap<String, usize> = HashMap::new();
        let mut by_upc: HashMap<String, usize> = HashMap::new();
        let mut by_norm: HashMap<(String, String), usize> = HashMap::new();

        for (i, r) in rows.iter().enumerate() {
            if let Some(mb) = r
                .musicbrainz_release_group_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                let key = mb.to_ascii_lowercase();
                if let Some(&prev) = by_mb.get(&key) {
                    union(&mut parent, prev, i);
                } else {
                    by_mb.insert(key, i);
                }
            }
            if let Some(upc) = r.upc.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
                let key = upc.to_string();
                if let Some(&prev) = by_upc.get(&key) {
                    union(&mut parent, prev, i);
                } else {
                    by_upc.insert(key, i);
                }
            }

            let nt = r
                .normalized_title
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| normalize_match_key(&r.title));
            let na = r
                .normalized_artist
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| normalize_match_key(r.artist_name.as_deref().unwrap_or("")));

            if !nt.is_empty() && !na.is_empty() {
                let key = (nt, na);
                if let Some(&prev) = by_norm.get(&key) {
                    union(&mut parent, prev, i);
                } else {
                    by_norm.insert(key, i);
                }
            }
        }

        let isrc_rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT av.canonical_album_id, UPPER(REPLACE(ts.isrc, '-', '')) \
             FROM track_sources ts \
             JOIN album_versions av ON ts.version_id = av.id \
             WHERE ts.isrc IS NOT NULL AND TRIM(ts.isrc) != ''",
        )
        .fetch_all(pool)
        .await?;

        let mut by_isrc: HashMap<String, usize> = HashMap::new();
        for (alb_id, isrc) in isrc_rows {
            if let Some(&idx) = idx_by_id.get(alb_id.as_str()) {
                if let Some(&prev) = by_isrc.get(&isrc) {
                    union(&mut parent, prev, idx);
                } else {
                    by_isrc.insert(isrc, idx);
                }
            }
        }

        let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
        for i in 0..n {
            let root = find(&mut parent, i);
            groups.entry(root).or_default().push(i);
        }

        let mut merged_count = 0usize;
        for (_, mut members) in groups {
            if members.len() < 2 {
                continue;
            }
            members.sort_by_key(|&idx| {
                let r = &rows[idx];
                let score = usize::from(r.musicbrainz_release_group_id.is_some()) * 4
                    + usize::from(r.upc.is_some()) * 2
                    + usize::from(r.cover_url.is_some());
                (std::cmp::Reverse(score), idx)
            });

            let target_id = &rows[members[0]].id;
            for &src_idx in &members[1..] {
                let src_id = &rows[src_idx].id;
                if Self::merge_canonical_albums(pool, target_id, src_id).await? {
                    merged_count += 1;
                }
            }
        }

        Ok(merged_count)
    }
}
