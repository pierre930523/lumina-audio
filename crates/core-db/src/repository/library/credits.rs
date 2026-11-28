use core_types::AlbumCreditDetail;
use sqlx::SqlitePool;

use super::LibraryRepository;
use super::models::{AlbumCredit, AlbumCreditRow, ArtistCreditDetailRow};
use crate::error::Result;

impl LibraryRepository {
    pub async fn insert_album_credit(
        pool: &SqlitePool,
        album_id: &str,
        artist_id: &str,
        role: &str,
    ) -> Result<i64> {
        Self::upsert_album_credit(pool, album_id, artist_id, role).await
    }

    pub async fn upsert_album_credit(
        pool: &SqlitePool,
        album_id: &str,
        artist_id: &str,
        role: &str,
    ) -> Result<i64> {
        let trimmed_role = role.trim();
        let res = sqlx::query(
            "INSERT INTO album_credits (canonical_album_id, artist_id, role) \
             VALUES (?, ?, ?) \
             ON CONFLICT(canonical_album_id, artist_id, role) DO NOTHING",
        )
        .bind(album_id)
        .bind(artist_id)
        .bind(trimmed_role)
        .execute(pool)
        .await?;

        if res.rows_affected() > 0 {
            return Ok(res.last_insert_rowid());
        }

        let existing: (i64,) = sqlx::query_as(
            "SELECT id FROM album_credits \
             WHERE canonical_album_id = ? AND artist_id = ? AND role = ? LIMIT 1",
        )
        .bind(album_id)
        .bind(artist_id)
        .bind(trimmed_role)
        .fetch_one(pool)
        .await?;

        Ok(existing.0)
    }

    pub async fn list_credits_for_album(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Vec<AlbumCredit>> {
        let rows: Vec<AlbumCreditRow> = sqlx::query_as(
            "SELECT c.id, c.canonical_album_id, c.artist_id, c.role, a.name AS artist_name \
             FROM album_credits c \
             JOIN artists a ON c.artist_id = a.id \
             WHERE c.canonical_album_id = ?",
        )
        .bind(album_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| AlbumCredit {
                id: Some(r.id),
                canonical_album_id: r.canonical_album_id,
                artist_id: r.artist_id,
                role: r.role,
                artist_name: Some(r.artist_name),
            })
            .collect())
    }

    pub async fn list_credits_for_artist(
        pool: &SqlitePool,
        artist_id: &str,
    ) -> Result<Vec<AlbumCreditDetail>> {
        let rows: Vec<ArtistCreditDetailRow> = sqlx::query_as(
            "SELECT c.artist_id, a.name AS artist_name, c.role, \
             ca.id AS album_id, ca.title AS album_title \
             FROM album_credits c \
             JOIN artists a ON c.artist_id = a.id \
             JOIN canonical_albums ca ON c.canonical_album_id = ca.id \
             WHERE c.artist_id = ? \
             ORDER BY ca.release_year ASC, ca.sort_title ASC, c.role ASC",
        )
        .bind(artist_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| AlbumCreditDetail {
                artist_id: r.artist_id,
                artist_name: r.artist_name,
                role: r.role,
                album_id: Some(r.album_id),
                album_title: Some(r.album_title),
            })
            .collect())
    }
}
