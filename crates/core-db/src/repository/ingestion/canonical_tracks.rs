use chrono::Utc;
use core_types::{CanonicalAlbum, CanonicalTrack, FileStatus, SourceReference, TrackSource};
use sqlx::{SqliteConnection, SqlitePool};
use std::str::FromStr;
use uuid::Uuid;

use super::IngestionRepository;
use super::models::{CanonicalTrackRow, SourceReferenceRow};
use crate::error::Result;
use crate::repository::library::{
    Artist, LibraryRepository, normalize_match_key, parse_audio_codec, parse_provider_kind,
};

impl IngestionRepository {
    pub async fn upsert_canonical_track_for_source_tx(
        conn: &mut SqliteConnection,
        track_source_id: &str,
        canonical_album_id: &str,
        track: &TrackSource,
        artist_names: &[String],
    ) -> Result<(String, bool)> {
        let now = Utc::now().to_rfc3339();
        let primary_artist = artist_names
            .first()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                track
                    .artist_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            })
            .or_else(|| {
                track
                    .album_artist
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            })
            .unwrap_or("Unknown Artist")
            .to_string();

        // 1. Existing link on track_sources
        let existing_link: Option<(Option<String>,)> =
            sqlx::query_as("SELECT canonical_track_id FROM track_sources WHERE id = ?")
                .bind(track_source_id)
                .fetch_optional(&mut *conn)
                .await?;
        let mut canonical_track_id = existing_link.and_then(|(cid,)| cid);

        // 2. Match by ISRC within album
        if canonical_track_id.is_none()
            && let Some(ref isrc) = track.isrc
        {
            let clean_isrc = isrc.trim();
            if !clean_isrc.is_empty() {
                let row: Option<(String,)> = sqlx::query_as(
                    "SELECT id FROM canonical_tracks \
                     WHERE canonical_album_id = ? AND isrc = ? LIMIT 1",
                )
                .bind(canonical_album_id)
                .bind(clean_isrc)
                .fetch_optional(&mut *conn)
                .await?;
                canonical_track_id = row.map(|(id,)| id);
            }
        }

        // 3. Match by (canonical_album_id, disc_number, track_number) + normalized title
        if canonical_track_id.is_none() {
            let norm_target = normalize_match_key(&track.title);
            let candidates: Vec<(String, String)> = sqlx::query_as(
                "SELECT id, title FROM canonical_tracks \
                 WHERE canonical_album_id = ? AND disc_number = ? AND track_number = ?",
            )
            .bind(canonical_album_id)
            .bind(track.disc_number as i64)
            .bind(track.track_number as i64)
            .fetch_all(&mut *conn)
            .await?;

            for (cid, existing_title) in candidates {
                if normalize_match_key(&existing_title) == norm_target {
                    canonical_track_id = Some(cid);
                    break;
                }
            }
        }

        let (resolved_id, created) = if let Some(cid) = canonical_track_id {
            let sort_title = CanonicalAlbum::derive_sort_title(&track.title);
            sqlx::query(
                "UPDATE canonical_tracks SET \
                    canonical_album_id = ?, \
                    title = ?, \
                    sort_title = ?, \
                    artist_name = ?, \
                    album_artist = ?, \
                    disc_number = ?, \
                    track_number = ?, \
                    duration_ms = ?, \
                    isrc = ?, \
                    genre = ?, \
                    composer = ?, \
                    updated_at = ? \
                 WHERE id = ?",
            )
            .bind(canonical_album_id)
            .bind(&track.title)
            .bind(&sort_title)
            .bind(&primary_artist)
            .bind(&track.album_artist)
            .bind(track.disc_number as i64)
            .bind(track.track_number as i64)
            .bind(track.duration_ms as i64)
            .bind(&track.isrc)
            .bind(&track.genre)
            .bind(&track.composer)
            .bind(&now)
            .bind(&cid)
            .execute(&mut *conn)
            .await?;
            (cid, false)
        } else {
            let new_id = Uuid::new_v4().to_string();
            let sort_title = CanonicalAlbum::derive_sort_title(&track.title);
            sqlx::query(
                "INSERT INTO canonical_tracks (id, canonical_album_id, title, sort_title, artist_name, \
                 album_artist, disc_number, track_number, duration_ms, isrc, genre, composer, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&new_id)
            .bind(canonical_album_id)
            .bind(&track.title)
            .bind(&sort_title)
            .bind(&primary_artist)
            .bind(&track.album_artist)
            .bind(track.disc_number as i64)
            .bind(track.track_number as i64)
            .bind(track.duration_ms as i64)
            .bind(&track.isrc)
            .bind(&track.genre)
            .bind(&track.composer)
            .bind(&now)
            .bind(&now)
            .execute(&mut *conn)
            .await?;
            (new_id, true)
        };

        sqlx::query("UPDATE track_sources SET canonical_track_id = ? WHERE id = ?")
            .bind(&resolved_id)
            .bind(track_source_id)
            .execute(&mut *conn)
            .await?;

        let names_to_link: Vec<String> = if artist_names.is_empty() {
            vec![primary_artist]
        } else {
            artist_names.to_vec()
        };
        let _ =
            Self::link_track_artists_tx(conn, &resolved_id, &names_to_link, "performer").await?;

        Ok((resolved_id, created))
    }

    pub async fn upsert_canonical_track_for_source(
        pool: &SqlitePool,
        track_source_id: &str,
        canonical_album_id: &str,
        track: &TrackSource,
        artist_names: &[String],
    ) -> Result<CanonicalTrack> {
        let mut tx = crate::repository::tx::ImmediateTx::begin(pool).await?;
        let res = Self::upsert_canonical_track_for_source_tx(
            tx.conn(),
            track_source_id,
            canonical_album_id,
            track,
            artist_names,
        )
        .await;

        let resolved_id = match res {
            Ok((id, _)) => {
                tx.commit().await?;
                id
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        };

        Ok(Self::get_canonical_track_with_sources(pool, &resolved_id)
            .await?
            .expect("canonical_track just inserted/updated must exist"))
    }

    pub async fn link_track_artists_tx(
        conn: &mut SqliteConnection,
        canonical_track_id: &str,
        artist_names: &[String],
        role: &str,
    ) -> Result<Vec<Artist>> {
        let mut linked = Vec::new();
        let clean_role = if role.trim().is_empty() {
            "performer"
        } else {
            role.trim()
        };

        sqlx::query("DELETE FROM track_artists WHERE canonical_track_id = ? AND role = ?")
            .bind(canonical_track_id)
            .bind(clean_role)
            .execute(&mut *conn)
            .await?;

        for (pos, raw_name) in artist_names.iter().enumerate() {
            let trimmed = raw_name.trim();
            if trimmed.is_empty() {
                continue;
            }
            let artist = LibraryRepository::upsert_artist_by_mbid_or_name_tx(
                conn, trimmed, None, None, None,
            )
            .await?;

            sqlx::query(
                "INSERT INTO track_artists (canonical_track_id, artist_id, role, position) \
                 VALUES (?, ?, ?, ?) \
                 ON CONFLICT(canonical_track_id, artist_id, role) DO UPDATE SET \
                    position = excluded.position",
            )
            .bind(canonical_track_id)
            .bind(&artist.id)
            .bind(clean_role)
            .bind(pos as i64)
            .execute(&mut *conn)
            .await?;

            linked.push(artist);
        }

        Ok(linked)
    }

    pub async fn link_track_artists(
        pool: &SqlitePool,
        canonical_track_id: &str,
        artist_names: &[String],
        role: &str,
    ) -> Result<Vec<Artist>> {
        let mut tx = crate::repository::tx::ImmediateTx::begin(pool).await?;
        let res =
            Self::link_track_artists_tx(tx.conn(), canonical_track_id, artist_names, role).await;
        match res {
            Ok(linked) => {
                tx.commit().await?;
                Ok(linked)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }

    pub async fn get_canonical_track_with_sources(
        pool: &SqlitePool,
        canonical_track_id: &str,
    ) -> Result<Option<CanonicalTrack>> {
        let row: Option<CanonicalTrackRow> = sqlx::query_as(
            "SELECT id, canonical_album_id, title, sort_title, artist_name, album_artist, \
             disc_number, track_number, duration_ms, isrc, musicbrainz_recording_id, genre, composer \
             FROM canonical_tracks WHERE id = ?",
        )
        .bind(canonical_track_id)
        .fetch_optional(pool)
        .await?;

        let Some(row) = row else {
            return Ok(None);
        };

        let artist_rows: Vec<(String,)> = sqlx::query_as(
            "SELECT a.name FROM track_artists ta \
             JOIN artists a ON a.id = ta.artist_id \
             WHERE ta.canonical_track_id = ? \
             ORDER BY ta.position ASC, a.name ASC",
        )
        .bind(&row.id)
        .fetch_all(pool)
        .await?;

        let artist_names: Vec<String> = artist_rows.into_iter().map(|(n,)| n).collect();
        let sources = Self::get_sources_for_canonical_track(pool, &row.id).await?;

        Ok(Some(CanonicalTrack {
            id: row.id,
            canonical_album_id: row.canonical_album_id,
            title: row.title,
            sort_title: row.sort_title,
            artist_name: row.artist_name,
            album_artist: row.album_artist,
            artist_names,
            disc_number: row.disc_number.max(1) as u32,
            track_number: row.track_number.max(1) as u32,
            duration_ms: row.duration_ms.max(0) as u64,
            isrc: row.isrc,
            musicbrainz_recording_id: row.musicbrainz_recording_id,
            genre: row.genre,
            composer: row.composer,
            sources,
        }))
    }

    pub async fn get_sources_for_canonical_track(
        pool: &SqlitePool,
        canonical_track_id: &str,
    ) -> Result<Vec<SourceReference>> {
        let rows: Vec<SourceReferenceRow> = sqlx::query_as(
            "SELECT id, provider_id, external_track_id, codec, sample_rate_hz, bit_depth, \
             channels, is_dsd, file_status, content_fingerprint, audio_byte_len \
             FROM track_sources \
             WHERE canonical_track_id = ? \
             ORDER BY sample_rate_hz DESC, bit_depth DESC, provider_id ASC",
        )
        .bind(canonical_track_id)
        .fetch_all(pool)
        .await?;

        Ok(rows
            .into_iter()
            .map(|r| SourceReference {
                source_id: r.id,
                provider: parse_provider_kind(&r.provider_id),
                external_id: r.external_track_id,
                codec: parse_audio_codec(&r.codec),
                sample_rate_hz: r.sample_rate_hz.max(0) as u32,
                bit_depth: if r.bit_depth > 0 {
                    Some(r.bit_depth.min(i64::from(u16::MAX)) as u16)
                } else {
                    None
                },
                bitrate_kbps: None,
                channels: Some(r.channels.clamp(1, i64::from(u8::MAX)) as u8),
                is_dsd: r.is_dsd != 0,
                file_status: FileStatus::from_str(&r.file_status).unwrap_or(FileStatus::Present),
                content_fingerprint: r.content_fingerprint,
                audio_byte_len: r.audio_byte_len.and_then(|v| u64::try_from(v).ok()),
            })
            .collect())
    }
}
