use sqlx::{QueryBuilder, Sqlite, SqliteConnection};
use std::collections::HashSet;

use crate::error::Result;

pub(super) async fn delete_in_chunks_tx(
    conn: &mut SqliteConnection,
    sql_prefix: &str,
    ids: &[String],
) -> Result<usize> {
    let mut total = 0usize;
    for chunk in ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(sql_prefix);
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(")");
        total += qb.build().execute(&mut *conn).await?.rows_affected() as usize;
    }
    Ok(total)
}

pub(super) async fn collect_cache_paths_tx(
    conn: &mut SqliteConnection,
    sql_prefix: &str,
    ids: &[String],
    seen_paths: &mut HashSet<String>,
    invalidated_artwork_paths: &mut Vec<String>,
) -> Result<()> {
    for chunk in ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(sql_prefix);
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(")");
        let rows: Vec<(String,)> = qb.build_query_as().fetch_all(&mut *conn).await?;
        for (path,) in rows {
            if seen_paths.insert(path.clone()) {
                invalidated_artwork_paths.push(path);
            }
        }
    }
    Ok(())
}

pub(super) async fn delete_track_batch_with_refs_tx(
    conn: &mut SqliteConnection,
    track_ids: &[String],
    seen_paths: &mut HashSet<String>,
    invalidated_artwork_paths: &mut Vec<String>,
) -> Result<()> {
    if track_ids.is_empty() {
        return Ok(());
    }
    collect_cache_paths_tx(
        conn,
        "SELECT cache_path FROM artwork_cache WHERE track_id IN (",
        track_ids,
        seen_paths,
        invalidated_artwork_paths,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM artwork_overrides WHERE target_kind = 'track' AND target_id IN (",
        track_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM metadata_overrides WHERE entity_type = 'track' AND entity_id IN (",
        track_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM artwork_cache WHERE track_id IN (",
        track_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM search_fts WHERE entity_type = 'track' AND entity_id IN (",
        track_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM profile_favorites WHERE item_type = 'track' AND item_id IN (",
        track_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM tag_items WHERE entity_type = 'track' AND entity_id IN (",
        track_ids,
    )
    .await?;
    delete_in_chunks_tx(conn, "DELETE FROM track_sources WHERE id IN (", track_ids).await?;
    Ok(())
}

pub(super) async fn delete_album_batch_with_refs_tx(
    conn: &mut SqliteConnection,
    album_ids: &[String],
    seen_paths: &mut HashSet<String>,
    invalidated_artwork_paths: &mut Vec<String>,
) -> Result<()> {
    if album_ids.is_empty() {
        return Ok(());
    }
    collect_cache_paths_tx(
        conn,
        "SELECT cache_path FROM artwork_cache WHERE album_id IN (",
        album_ids,
        seen_paths,
        invalidated_artwork_paths,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM artwork_overrides WHERE target_kind = 'album' AND target_id IN (",
        album_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM metadata_overrides WHERE entity_type = 'album' AND entity_id IN (",
        album_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM artwork_cache WHERE album_id IN (",
        album_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM search_fts WHERE entity_type = 'album' AND entity_id IN (",
        album_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM profile_favorites WHERE item_type = 'album' AND item_id IN (",
        album_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM tag_items WHERE entity_type = 'album_group' AND entity_id IN (",
        album_ids,
    )
    .await?;
    delete_in_chunks_tx(
        conn,
        "DELETE FROM canonical_albums WHERE id IN (",
        album_ids,
    )
    .await?;
    Ok(())
}

/// Deletes artists unreferenced by any `canonical_albums`, `album_credits`, or `track_artists`,
/// and purges stale `search_fts` entries for missing/deleted tracks, empty albums, and orphan artists.
pub(super) async fn prune_orphan_artists_and_stale_fts_tx(
    conn: &mut SqliteConnection,
) -> Result<usize> {
    let orphan_artist_rows: Vec<(String,)> = sqlx::query_as(
        "SELECT a.id FROM artists a \
         WHERE NOT EXISTS (SELECT 1 FROM canonical_albums ca WHERE ca.primary_artist_id = a.id) \
           AND NOT EXISTS (SELECT 1 FROM album_credits ac WHERE ac.artist_id = a.id) \
           AND NOT EXISTS (SELECT 1 FROM track_artists ta WHERE ta.artist_id = a.id)",
    )
    .fetch_all(&mut *conn)
    .await?;

    let orphan_artist_ids: Vec<String> = orphan_artist_rows.into_iter().map(|(id,)| id).collect();
    if !orphan_artist_ids.is_empty() {
        delete_in_chunks_tx(
            conn,
            "DELETE FROM metadata_overrides WHERE entity_type = 'artist' AND entity_id IN (",
            &orphan_artist_ids,
        )
        .await?;
        delete_in_chunks_tx(
            conn,
            "DELETE FROM profile_favorites WHERE item_type = 'artist' AND item_id IN (",
            &orphan_artist_ids,
        )
        .await?;
        delete_in_chunks_tx(
            conn,
            "DELETE FROM search_fts WHERE entity_type = 'artist' AND entity_id IN (",
            &orphan_artist_ids,
        )
        .await?;
        delete_in_chunks_tx(
            conn,
            "DELETE FROM artists WHERE id IN (",
            &orphan_artist_ids,
        )
        .await?;
    }

    sqlx::query(
        "DELETE FROM tag_items \
         WHERE entity_type = 'artist' \
           AND entity_id NOT IN (SELECT id FROM artists)",
    )
    .execute(&mut *conn)
    .await?;

    sqlx::query(
        "DELETE FROM search_fts \
         WHERE entity_type = 'track' \
           AND NOT EXISTS ( \
               SELECT 1 FROM track_sources ts \
               WHERE ts.id = search_fts.entity_id AND ts.file_status = 'present' \
           )",
    )
    .execute(&mut *conn)
    .await?;

    sqlx::query(
        "DELETE FROM search_fts \
         WHERE entity_type = 'album' \
           AND NOT EXISTS ( \
               SELECT 1 FROM album_versions av \
               JOIN track_sources ts ON ts.version_id = av.id \
               WHERE av.canonical_album_id = search_fts.entity_id \
                 AND av.is_hidden = 0 \
                 AND ts.file_status = 'present' \
           )",
    )
    .execute(&mut *conn)
    .await?;

    sqlx::query(
        "DELETE FROM search_fts \
         WHERE entity_type = 'artist' \
           AND NOT EXISTS ( \
               SELECT 1 FROM canonical_albums ca \
               JOIN album_versions av ON av.canonical_album_id = ca.id \
               JOIN track_sources ts ON ts.version_id = av.id \
               WHERE ca.primary_artist_id = search_fts.entity_id AND ts.file_status = 'present' \
           ) \
           AND NOT EXISTS ( \
               SELECT 1 FROM track_artists ta \
               JOIN track_sources ts ON ts.canonical_track_id = ta.canonical_track_id \
               WHERE ta.artist_id = search_fts.entity_id AND ts.file_status = 'present' \
           ) \
           AND NOT EXISTS ( \
               SELECT 1 FROM album_credits ac \
               JOIN album_versions av ON av.canonical_album_id = ac.canonical_album_id \
               JOIN track_sources ts ON ts.version_id = av.id \
               WHERE ac.artist_id = search_fts.entity_id AND ts.file_status = 'present' \
           )",
    )
    .execute(&mut *conn)
    .await?;

    Ok(orphan_artist_ids.len())
}
