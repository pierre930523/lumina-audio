//! Repository search index synchronization helpers.

use crate::error::Result;
use crate::repository::ImmediateTx;
use sqlx::{Sqlite, SqliteConnection, SqlitePool, Transaction};

/// Syncs an artist entity into search_fts on an arbitrary SQLite connection.
pub async fn sync_artist_fts_conn(
    conn: &mut SqliteConnection,
    artist_id: &str,
    name: &str,
    biography: Option<&str>,
) -> Result<()> {
    delete_fts_entry_conn(conn, "artist", artist_id).await?;
    let subtitle = biography.unwrap_or("Artist");
    sqlx::query(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('artist', ?, ?, ?)",
    )
    .bind(artist_id)
    .bind(name)
    .bind(subtitle)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Syncs an artist entity into search_fts.
pub async fn sync_artist_fts(
    tx: &mut Transaction<'_, Sqlite>,
    artist_id: &str,
    name: &str,
    biography: Option<&str>,
) -> Result<()> {
    sync_artist_fts_conn(tx, artist_id, name, biography).await
}

/// Syncs a canonical album entity into search_fts on an arbitrary SQLite connection.
pub async fn sync_album_fts_conn(
    conn: &mut SqliteConnection,
    album_id: &str,
    title: &str,
    artist_name: Option<&str>,
    release_year: Option<i32>,
) -> Result<()> {
    delete_fts_entry_conn(conn, "album", album_id).await?;
    let artist_str = artist_name.unwrap_or("");
    let subtitle = match release_year {
        Some(yr) => format!("{} ({})", artist_str, yr),
        None => artist_str.to_string(),
    };
    sqlx::query(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('album', ?, ?, ?)",
    )
    .bind(album_id)
    .bind(title)
    .bind(subtitle)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Syncs a canonical album entity into search_fts.
pub async fn sync_album_fts(
    tx: &mut Transaction<'_, Sqlite>,
    album_id: &str,
    title: &str,
    artist_name: Option<&str>,
    release_year: Option<i32>,
) -> Result<()> {
    sync_album_fts_conn(tx, album_id, title, artist_name, release_year).await
}

/// Syncs a track source entity into search_fts on an arbitrary SQLite connection.
pub async fn sync_track_fts_conn(
    conn: &mut SqliteConnection,
    track_id: &str,
    title: &str,
    artist_name: Option<&str>,
    album_title: Option<&str>,
) -> Result<()> {
    delete_fts_entry_conn(conn, "track", track_id).await?;
    let subtitle = match (artist_name, album_title) {
        (Some(art), Some(alb)) => format!("{} - {}", art, alb),
        (Some(art), None) => art.to_string(),
        (None, Some(alb)) => alb.to_string(),
        (None, None) => "Track".to_string(),
    };
    sqlx::query(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
    )
    .bind(track_id)
    .bind(title)
    .bind(subtitle)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Syncs a track source entity into search_fts.
pub async fn sync_track_fts(
    tx: &mut Transaction<'_, Sqlite>,
    track_id: &str,
    title: &str,
    artist_name: Option<&str>,
    album_title: Option<&str>,
) -> Result<()> {
    sync_track_fts_conn(tx, track_id, title, artist_name, album_title).await
}

/// Deletes an entity entry from search_fts on an arbitrary SQLite connection.
pub async fn delete_fts_entry_conn(
    conn: &mut SqliteConnection,
    entity_type: &str,
    entity_id: &str,
) -> Result<()> {
    sqlx::query("DELETE FROM search_fts WHERE entity_type = ? AND entity_id = ?")
        .bind(entity_type)
        .bind(entity_id)
        .execute(&mut *conn)
        .await?;
    Ok(())
}

/// Deletes an entity entry from search_fts.
pub async fn delete_fts_entry(
    tx: &mut Transaction<'_, Sqlite>,
    entity_type: &str,
    entity_id: &str,
) -> Result<()> {
    delete_fts_entry_conn(tx, entity_type, entity_id).await
}

/// Syncs or removes a single album's `search_fts` entry based on whether it has at least one
/// visible (`is_hidden = 0`) version with a `file_status = 'present'` track.
pub async fn sync_single_album_fts_visibility_conn(
    conn: &mut SqliteConnection,
    album_id: &str,
) -> Result<()> {
    let row: Option<(String, Option<String>, Option<i32>, i32)> = sqlx::query_as(
        "SELECT alb.title, art.name, alb.release_year, \
                CASE WHEN EXISTS ( \
                    SELECT 1 FROM album_versions av \
                    JOIN track_sources ts ON ts.version_id = av.id \
                    WHERE av.canonical_album_id = alb.id \
                      AND av.is_hidden = 0 \
                      AND ts.is_hidden = 0 \
                      AND ts.file_status = 'present' \
                ) THEN 1 ELSE 0 END AS is_visible \
         FROM canonical_albums alb \
         LEFT JOIN artists art ON art.id = alb.primary_artist_id \
         WHERE alb.id = ?",
    )
    .bind(album_id)
    .fetch_optional(&mut *conn)
    .await?;

    match row {
        Some((title, artist_name, release_year, is_visible)) if is_visible != 0 => {
            sync_album_fts_conn(conn, album_id, &title, artist_name.as_deref(), release_year).await
        }
        _ => delete_fts_entry_conn(conn, "album", album_id).await,
    }
}

/// Rebuilds the complete `search_fts` virtual table on an existing connection/transaction.
/// Excludes orphan artists, empty/missing-only/all-hidden albums, and non-present tracks.
pub async fn rebuild_search_index_conn(conn: &mut SqliteConnection) -> Result<usize> {
    sqlx::query("DELETE FROM search_fts")
        .execute(&mut *conn)
        .await?;

    // Batch insert active artists (at least one present track via album, track_artists, or credits)
    sqlx::query(
        r#"
        INSERT INTO search_fts (entity_type, entity_id, title, subtitle)
        SELECT 'artist', a.id, a.name, coalesce(a.biography, 'Artist')
        FROM artists a
        WHERE EXISTS (
            SELECT 1
            FROM canonical_albums ca
            JOIN album_versions av ON av.canonical_album_id = ca.id
            JOIN track_sources ts ON ts.version_id = av.id
            WHERE ca.primary_artist_id = a.id
              AND ts.file_status = 'present'
        )
        OR EXISTS (
            SELECT 1
            FROM track_artists ta
            JOIN track_sources ts ON ts.canonical_track_id = ta.canonical_track_id
            WHERE ta.artist_id = a.id
              AND ts.file_status = 'present'
        )
        OR EXISTS (
            SELECT 1
            FROM album_credits ac
            JOIN album_versions av ON av.canonical_album_id = ac.canonical_album_id
            JOIN track_sources ts ON ts.version_id = av.id
            WHERE ac.artist_id = a.id
              AND ts.file_status = 'present'
        )
        "#,
    )
    .execute(&mut *conn)
    .await?;

    // Batch insert canonical albums that have at least one visible present version
    sqlx::query(
        r#"
        INSERT INTO search_fts (entity_type, entity_id, title, subtitle)
        SELECT 'album', alb.id, alb.title,
               coalesce(art.name, '') || CASE WHEN alb.release_year IS NOT NULL THEN ' (' || alb.release_year || ')' ELSE '' END
        FROM canonical_albums alb
        LEFT JOIN artists art ON art.id = alb.primary_artist_id
        WHERE EXISTS (
            SELECT 1
            FROM album_versions av
            JOIN track_sources ts ON ts.version_id = av.id
            WHERE av.canonical_album_id = alb.id
              AND av.is_hidden = 0
              AND ts.is_hidden = 0
              AND ts.file_status = 'present'
        )
        "#,
    )
    .execute(&mut *conn)
    .await?;

    // Batch insert visible present tracks
    sqlx::query(
        r#"
        INSERT INTO search_fts (entity_type, entity_id, title, subtitle)
        SELECT DISTINCT 'track', trk.id, trk.title,
               coalesce(NULLIF(TRIM(trk.artist_name, char(9, 10, 13, 32)), ''), art.name, '') || ' - ' || alb.title
        FROM track_sources trk
        JOIN album_versions ver ON ver.id = trk.version_id
        JOIN canonical_albums alb ON alb.id = ver.canonical_album_id
        LEFT JOIN artists art ON art.id = alb.primary_artist_id
        WHERE trk.file_status = 'present'
          AND ver.is_hidden = 0
          AND trk.is_hidden = 0
        "#,
    )
    .execute(&mut *conn)
    .await?;

    let count: (i64,) = sqlx::query_as("SELECT count(*) FROM search_fts")
        .fetch_one(&mut *conn)
        .await?;

    Ok(count.0 as usize)
}

/// Rebuilds the complete search_fts virtual table from relational data.
pub async fn rebuild_search_index(pool: &SqlitePool) -> Result<usize> {
    let mut tx = ImmediateTx::begin(pool).await?;

    let res = rebuild_search_index_conn(tx.conn()).await;

    match res {
        Ok(count) => {
            tx.commit().await?;
            Ok(count)
        }
        Err(e) => {
            let _ = tx.rollback().await;
            Err(e)
        }
    }
}
