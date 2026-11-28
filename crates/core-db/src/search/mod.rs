//! FTS5 Full-Text Search Engine.

pub mod sanitizer;
pub mod sync;

pub use sanitizer::sanitize_fts5_query;
pub use sync::{
    delete_fts_entry, delete_fts_entry_conn, rebuild_search_index, rebuild_search_index_conn,
    sync_album_fts, sync_album_fts_conn, sync_artist_fts, sync_artist_fts_conn,
    sync_single_album_fts_visibility_conn, sync_track_fts, sync_track_fts_conn,
};

use crate::error::Result;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SearchResult {
    pub entity_type: String, // "artist", "album", "track"
    pub entity_id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub rank: f64,
}

#[derive(sqlx::FromRow)]
struct SearchResultRow {
    entity_type: String,
    entity_id: String,
    title: String,
    subtitle: Option<String>,
    rank: f64,
}

impl From<SearchResultRow> for SearchResult {
    fn from(row: SearchResultRow) -> Self {
        Self {
            entity_type: row.entity_type,
            entity_id: row.entity_id,
            title: row.title,
            subtitle: row.subtitle,
            rank: row.rank,
        }
    }
}

/// Searches the music library using SQLite FTS5 with automatic query sanitization and BM25 ranking.
pub async fn search_library(pool: &SqlitePool, query: &str) -> Result<Vec<SearchResult>> {
    search_library_with_limit(pool, query, 50).await
}

/// Searches the music library with a custom limit.
pub async fn search_library_with_limit(
    pool: &SqlitePool,
    query: &str,
    limit: u32,
) -> Result<Vec<SearchResult>> {
    let sanitized = sanitize_fts5_query(query);
    if sanitized.is_empty() {
        return Ok(Vec::new());
    }

    let rows = sqlx::query_as::<_, SearchResultRow>(
        r#"
        SELECT entity_type, entity_id, title, subtitle, rank
        FROM search_fts
        WHERE search_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        "#,
    )
    .bind(&sanitized)
    .bind(limit as i64)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(SearchResult::from).collect())
}
