//! Repository search index synchronization helpers.

use crate::error::Result;
use crate::repository::ImmediateTx;
use sqlx::{Sqlite, SqlitePool, Transaction};

/// Syncs an artist entity into search_fts.
pub async fn sync_artist_fts(
    tx: &mut Transaction<'_, Sqlite>,
    artist_id: &str,
    name: &str,
    biography: Option<&str>,
) -> Result<()> {
    delete_fts_entry(tx, "artist", artist_id).await?;
    let subtitle = biography.unwrap_or("Artist");
    sqlx::query(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('artist', ?, ?, ?)",
    )
    .bind(artist_id)
    .bind(name)
    .bind(subtitle)
    .execute(&mut **tx)
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
    delete_fts_entry(tx, "album", album_id).await?;
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
    .execute(&mut **tx)
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
    delete_fts_entry(tx, "track", track_id).await?;
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
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Deletes an entity entry from search_fts.
pub async fn delete_fts_entry(
    tx: &mut Transaction<'_, Sqlite>,
    entity_type: &str,
    entity_id: &str,
) -> Result<()> {
    sqlx::query("DELETE FROM search_fts WHERE entity_type = ? AND entity_id = ?")
        .bind(entity_type)
        .bind(entity_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// Rebuilds the complete search_fts virtual table from relational data.
pub async fn rebuild_search_index(pool: &SqlitePool) -> Result<usize> {
    let mut tx = ImmediateTx::begin(pool).await?;

    let res: Result<usize> = async {
        sqlx::query("DELETE FROM search_fts").execute(tx.conn()).await?;

        // Batch insert artists
        sqlx::query(
            r#"
            INSERT INTO search_fts (entity_type, entity_id, title, subtitle)
            SELECT 'artist', id, name, coalesce(biography, 'Artist')
            FROM artists
            "#,
        )
        .execute(tx.conn())
        .await?;

        // Batch insert canonical albums
        sqlx::query(
            r#"
            INSERT INTO search_fts (entity_type, entity_id, title, subtitle)
            SELECT 'album', alb.id, alb.title,
                   coalesce(art.name, '') || CASE WHEN alb.release_year IS NOT NULL THEN ' (' || alb.release_year || ')' ELSE '' END
            FROM canonical_albums alb
            LEFT JOIN artists art ON art.id = alb.primary_artist_id
            "#,
        )
        .execute(tx.conn())
        .await?;

        // Batch insert tracks
        sqlx::query(
            r#"
            INSERT INTO search_fts (entity_type, entity_id, title, subtitle)
            SELECT DISTINCT 'track', trk.id, trk.title,
                   coalesce(NULLIF(TRIM(trk.artist_name, char(9, 10, 13, 32)), ''), art.name, '') || ' - ' || alb.title
            FROM track_sources trk
            JOIN album_versions ver ON ver.id = trk.version_id
            JOIN canonical_albums alb ON alb.id = ver.canonical_album_id
            LEFT JOIN artists art ON art.id = alb.primary_artist_id
            "#,
        )
        .execute(tx.conn())
        .await?;

        let count: (i64,) = sqlx::query_as("SELECT count(*) FROM search_fts")
            .fetch_one(tx.conn())
            .await?;

        Ok(count.0 as usize)
    }
    .await;

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
