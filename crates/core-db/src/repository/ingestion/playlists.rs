use chrono::Utc;
use core_types::{AlbumVersion, AudioFormat};
use sqlx::{SqliteConnection, SqlitePool};
use uuid::Uuid;

use super::IngestionRepository;
use super::models::{AlbumVersionTocRow, PlaylistRow, SidecarPlaylist, SidecarPlaylistEntry};
use crate::error::Result;
use crate::repository::library::{parse_audio_codec, parse_provider_kind};
use crate::repository::tx::ImmediateTx;

impl IngestionRepository {
    // -------------------------------------------------------------------------
    // Version TOC Signature & Missing Status Helpers
    // -------------------------------------------------------------------------

    pub async fn update_album_version_toc_tx(
        conn: &mut SqliteConnection,
        version_id: &str,
        toc_signature: &str,
        disc_count: u32,
        track_count: u32,
    ) -> Result<bool> {
        let res = sqlx::query(
            "UPDATE album_versions SET toc_signature = ?, disc_count = ?, track_count = ? WHERE id = ?",
        )
        .bind(toc_signature.trim())
        .bind(disc_count.max(1) as i64)
        .bind(track_count as i64)
        .bind(version_id.trim())
        .execute(&mut *conn)
        .await?;
        Ok(res.rows_affected() > 0)
    }

    pub async fn update_album_version_toc(
        pool: &SqlitePool,
        version_id: &str,
        toc_signature: &str,
        disc_count: u32,
        track_count: u32,
    ) -> Result<bool> {
        let mut conn = pool.acquire().await?;
        Self::update_album_version_toc_tx(
            &mut conn,
            version_id,
            toc_signature,
            disc_count,
            track_count,
        )
        .await
    }

    pub async fn find_versions_by_toc(
        pool: &SqlitePool,
        toc_signature: &str,
    ) -> Result<Vec<AlbumVersion>> {
        let rows: Vec<AlbumVersionTocRow> = sqlx::query_as(
            "SELECT id, canonical_album_id, provider_id, external_album_id, codec, \
             sample_rate_hz, bit_depth, channels, is_dsd, edition_label \
             FROM album_versions WHERE toc_signature = ?",
        )
        .bind(toc_signature.trim())
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| AlbumVersion {
                id: r.id,
                canonical_album_id: r.canonical_album_id,
                provider: parse_provider_kind(&r.provider_id),
                external_album_id: r.external_album_id,
                format: AudioFormat {
                    codec: parse_audio_codec(&r.codec),
                    sample_rate_hz: r.sample_rate_hz as u32,
                    bit_depth: r.bit_depth as u8,
                    channels: r.channels as u8,
                    is_dsd: r.is_dsd == 1,
                },
                edition_label: r.edition_label,
                is_primary: false,
                is_hidden: false,
                quality_score: 0.0,
                manual_group_id: None,
                disc_count: 1,
                track_count: 0,
                has_manual_tracks: false,
            })
            .collect())
    }

    pub async fn mark_track_source_missing_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        external_track_id: &str,
        missing_since: &str,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE track_sources SET file_status = 'missing', missing_since = COALESCE(missing_since, ?) \
             WHERE provider_id = ? AND external_track_id = ?",
        )
        .bind(missing_since)
        .bind(provider_id)
        .bind(external_track_id)
        .execute(&mut *conn)
        .await?;
        Ok(())
    }

    pub async fn list_present_track_durations_for_version_tx(
        conn: &mut SqliteConnection,
        version_id: &str,
    ) -> Result<Vec<(i64, i64)>> {
        let rows: Vec<(i64, i64)> = sqlx::query_as(
            "SELECT disc_number, duration_ms FROM track_sources \
             WHERE version_id = ? AND file_status = 'present' \
             ORDER BY disc_number ASC, track_number ASC, external_track_id ASC",
        )
        .bind(version_id)
        .fetch_all(&mut *conn)
        .await?;
        Ok(rows)
    }

    pub async fn get_track_and_album_by_external_id_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        external_track_id: &str,
    ) -> Result<Option<(String, String)>> {
        let row: Option<(String, String)> = sqlx::query_as(
            "SELECT ts.id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.provider_id = ? AND ts.external_track_id = ? LIMIT 1",
        )
        .bind(provider_id)
        .bind(external_track_id)
        .fetch_optional(&mut *conn)
        .await?;
        Ok(row)
    }

    pub async fn get_album_version_toc_info(
        pool: &SqlitePool,
        version_id: &str,
    ) -> Result<Option<(Option<String>, i64, Option<i64>)>> {
        let row: Option<(Option<String>, i64, Option<i64>)> = sqlx::query_as(
            "SELECT toc_signature, disc_count, track_count FROM album_versions WHERE id = ?",
        )
        .bind(version_id)
        .fetch_optional(pool)
        .await?;
        Ok(row)
    }

    pub async fn get_canonical_track_id_for_source(
        pool: &SqlitePool,
        source_id: &str,
    ) -> Result<Option<String>> {
        let row: Option<(Option<String>,)> =
            sqlx::query_as("SELECT canonical_track_id FROM track_sources WHERE id = ?")
                .bind(source_id)
                .fetch_optional(pool)
                .await?;
        Ok(row.and_then(|(id,)| id))
    }

    // -------------------------------------------------------------------------
    // Sidecar Playlists (.m3u / .m3u8)
    // -------------------------------------------------------------------------

    pub async fn upsert_sidecar_playlist(
        pool: &SqlitePool,
        provider_id: &str,
        source_path: &str,
        name: &str,
        entries: &[SidecarPlaylistEntry],
    ) -> Result<SidecarPlaylist> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        let track_count = entries.len() as i64;

        let res: Result<SidecarPlaylist> = async {
            let row: PlaylistRow = sqlx::query_as(
                "INSERT INTO playlists (id, provider_id, source_path, name, track_count, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(source_path) DO UPDATE SET \
                    provider_id = excluded.provider_id, \
                    name = excluded.name, \
                    track_count = excluded.track_count, \
                    updated_at = excluded.updated_at \
                 RETURNING id, provider_id, source_path, name, track_count, updated_at",
            )
            .bind(&id)
            .bind(provider_id.trim())
            .bind(source_path.trim())
            .bind(name.trim())
            .bind(track_count)
            .bind(&now)
            .fetch_one(tx.conn())
            .await?;

            sqlx::query("DELETE FROM playlist_items WHERE playlist_id = ?")
                .bind(&row.id)
                .execute(tx.conn())
                .await?;

            for (pos, entry) in entries.iter().enumerate() {
                sqlx::query(
                    "INSERT INTO playlist_items (playlist_id, position, raw_entry, resolved_track_source_id) \
                     VALUES (?, ?, ?, ?)",
                )
                .bind(&row.id)
                .bind(pos as i64)
                .bind(&entry.raw_entry)
                .bind(&entry.resolved_track_source_id)
                .execute(tx.conn())
                .await?;
            }

            Ok(row.into())
        }
        .await;

        match res {
            Ok(playlist) => {
                tx.commit().await?;
                Ok(playlist)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn list_sidecar_playlists(pool: &SqlitePool) -> Result<Vec<SidecarPlaylist>> {
        let rows: Vec<PlaylistRow> = sqlx::query_as(
            "SELECT id, provider_id, source_path, name, track_count, updated_at \
             FROM playlists ORDER BY name ASC",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }
}
