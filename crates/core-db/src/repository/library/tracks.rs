use core_types::{TrackMetadataLayer, TrackSource};
use sqlx::{SqliteConnection, SqlitePool};

use super::LibraryRepository;
use crate::error::Result;
use crate::repository::folders::FolderRepository;
use crate::repository::tx::ImmediateTx;

fn track_file_meta_json(track: &TrackSource, embedded_lyrics: Option<&str>) -> Option<String> {
    TrackMetadataLayer {
        title: Some(track.title.clone()),
        artist_name: track.artist_name.clone(),
        album_artist: track.album_artist.clone(),
        album_title: None,
        disc_number: Some(track.disc_number).filter(|&n| n > 0),
        track_number: Some(track.track_number).filter(|&n| n > 0),
        release_year: track.release_year,
        genre: track.genre.clone(),
        composer: track.composer.clone(),
        isrc: track.isrc.clone(),
        lyrics: embedded_lyrics
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string),
    }
    .to_json_opt()
}

async fn sync_local_folder_for_upsert_tx(
    conn: &mut SqliteConnection,
    provider_str: &str,
    external_track_id: &str,
    force_present: bool,
) -> Result<Option<String>> {
    if !provider_str.eq_ignore_ascii_case("local") {
        return Ok(None);
    }

    let prev: Option<(Option<String>, String)> = sqlx::query_as(
        "SELECT folder_id, file_status FROM track_sources \
         WHERE provider_id = ? AND external_track_id = ?",
    )
    .bind(provider_str)
    .bind(external_track_id)
    .fetch_optional(&mut *conn)
    .await?;

    let (old_folder_id, was_present, is_present) = match prev {
        Some((fid, status)) => {
            let prev_present = status == "present";
            (
                fid,
                prev_present,
                if force_present { true } else { prev_present },
            )
        }
        None => (None, false, true),
    };

    FolderRepository::sync_track_folder_tx(
        conn,
        provider_str,
        external_track_id,
        None,
        old_folder_id.as_deref(),
        was_present,
        is_present,
    )
    .await
}

async fn upsert_basic_track_tx(
    conn: &mut SqliteConnection,
    track: &TrackSource,
    mark_present: bool,
) -> Result<(String, bool)> {
    let provider_str = track.provider.as_str();
    let codec_str = track.format.codec.as_str();
    let channels = track.format.channels.max(1) as i64;
    let is_dsd = if track.format.is_dsd || track.format.codec.is_dsd() {
        1i32
    } else {
        0i32
    };
    let folder_id =
        sync_local_folder_for_upsert_tx(conn, provider_str, &track.external_track_id, mark_present)
            .await?;

    let sql = if mark_present {
        "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
         disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
         replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
         artist_name, album_artist, genre, composer, channels, is_dsd, folder_id, added_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now')) \
         ON CONFLICT(provider_id, external_track_id) DO UPDATE SET \
            version_id = CASE \
                WHEN track_sources.manual_version_id IS NOT NULL \
                     AND EXISTS (SELECT 1 FROM album_versions av WHERE av.id = track_sources.manual_version_id) \
                THEN track_sources.manual_version_id \
                ELSE excluded.version_id \
            END, \
            title = excluded.title, \
            disc_number = COALESCE(track_sources.manual_disc_number, excluded.disc_number), \
            track_number = excluded.track_number, \
            duration_ms = excluded.duration_ms, \
            sample_rate_hz = excluded.sample_rate_hz, \
            bit_depth = excluded.bit_depth, \
            codec = excluded.codec, \
            isrc = excluded.isrc, \
            replay_gain_track_db = excluded.replay_gain_track_db, \
            replay_gain_album_db = excluded.replay_gain_album_db, \
            replay_gain_track_peak = excluded.replay_gain_track_peak, \
            replay_gain_album_peak = excluded.replay_gain_album_peak, \
            artist_name = excluded.artist_name, \
            album_artist = excluded.album_artist, \
            genre = excluded.genre, \
            composer = excluded.composer, \
            channels = excluded.channels, \
            is_dsd = excluded.is_dsd, \
            folder_id = excluded.folder_id, \
            added_at = COALESCE(track_sources.added_at, datetime('now')), \
            file_status = 'present', \
            missing_since = NULL \
         RETURNING id, CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics"
    } else {
        "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
         disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
         replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
         artist_name, album_artist, genre, composer, channels, is_dsd, folder_id, added_at) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now')) \
         ON CONFLICT(provider_id, external_track_id) DO UPDATE SET \
            version_id = CASE \
                WHEN track_sources.manual_version_id IS NOT NULL \
                     AND EXISTS (SELECT 1 FROM album_versions av WHERE av.id = track_sources.manual_version_id) \
                THEN track_sources.manual_version_id \
                ELSE excluded.version_id \
            END, \
            title = excluded.title, \
            disc_number = COALESCE(track_sources.manual_disc_number, excluded.disc_number), \
            track_number = excluded.track_number, \
            duration_ms = excluded.duration_ms, \
            sample_rate_hz = excluded.sample_rate_hz, \
            bit_depth = excluded.bit_depth, \
            codec = excluded.codec, \
            isrc = excluded.isrc, \
            replay_gain_track_db = excluded.replay_gain_track_db, \
            replay_gain_album_db = excluded.replay_gain_album_db, \
            replay_gain_track_peak = excluded.replay_gain_track_peak, \
            replay_gain_album_peak = excluded.replay_gain_album_peak, \
            artist_name = excluded.artist_name, \
            album_artist = excluded.album_artist, \
            genre = excluded.genre, \
            composer = excluded.composer, \
            channels = excluded.channels, \
            is_dsd = excluded.is_dsd, \
            folder_id = excluded.folder_id, \
            added_at = COALESCE(track_sources.added_at, datetime('now')) \
         RETURNING id, CASE WHEN embedded_lyrics IS NOT NULL AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '' THEN 1 ELSE 0 END AS has_lyrics"
    };

    let (persisted_id, has_lyrics): (String, i32) = sqlx::query_as(sql)
        .bind(&track.id)
        .bind(&track.version_id)
        .bind(provider_str)
        .bind(&track.external_track_id)
        .bind(&track.title)
        .bind(track.disc_number as i64)
        .bind(track.track_number as i64)
        .bind(track.duration_ms as i64)
        .bind(track.format.sample_rate_hz as i64)
        .bind(track.format.bit_depth as i64)
        .bind(codec_str)
        .bind(&track.isrc)
        .bind(track.replay_gain_track_db)
        .bind(track.replay_gain_album_db)
        .bind(track.replay_gain_track_peak)
        .bind(track.replay_gain_album_peak)
        .bind(&track.artist_name)
        .bind(&track.album_artist)
        .bind(&track.genre)
        .bind(&track.composer)
        .bind(channels)
        .bind(is_dsd)
        .bind(&folder_id)
        .fetch_one(&mut *conn)
        .await?;

    Ok((persisted_id, has_lyrics != 0))
}

impl LibraryRepository {
    pub async fn insert_track_source(
        pool: &SqlitePool,
        track: &TrackSource,
    ) -> Result<TrackSource> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = upsert_basic_track_tx(tx.conn(), track, false).await;
        let (persisted_id, has_lyrics) = match res {
            Ok(v) => {
                tx.commit().await?;
                v
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        };

        let mut persisted = track.clone();
        persisted.id = persisted_id;
        persisted.has_lyrics = has_lyrics;
        Ok(persisted)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn upsert_track_source_with_cache_tx(
        conn: &mut SqliteConnection,
        track: &TrackSource,
        embedded_lyrics: Option<&str>,
        file_mtime: Option<i64>,
        file_size: Option<i64>,
        metadata_hash: Option<&str>,
        content_fingerprint: Option<&str>,
        audio_byte_len: Option<i64>,
    ) -> Result<String> {
        let provider_str = track.provider.as_str();
        let codec_str = track.format.codec.as_str();
        let channels = track.format.channels.max(1) as i64;
        let is_dsd = if track.format.is_dsd || track.format.codec.is_dsd() {
            1i32
        } else {
            0i32
        };
        let clean_fp = content_fingerprint.map(str::trim).filter(|s| !s.is_empty());
        let file_meta_json = track_file_meta_json(track, embedded_lyrics);
        let folder_id =
            sync_local_folder_for_upsert_tx(conn, provider_str, &track.external_track_id, true)
                .await?;

        let (persisted_id, has_other_layers): (String, i32) = sqlx::query_as(
            "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
             disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc, \
             replay_gain_track_db, replay_gain_album_db, replay_gain_track_peak, replay_gain_album_peak, \
             artist_name, album_artist, genre, composer, channels, is_dsd, \
             embedded_lyrics, file_mtime, file_size, metadata_hash, \
             content_fingerprint, audio_byte_len, file_status, missing_since, file_meta_json, \
             release_year, bitrate_kbps, folder_id, added_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'present', NULL, ?, ?, ?, ?, datetime('now')) \
             ON CONFLICT(provider_id, external_track_id) DO UPDATE SET \
                version_id = CASE \
                    WHEN track_sources.manual_version_id IS NOT NULL \
                         AND EXISTS (SELECT 1 FROM album_versions av WHERE av.id = track_sources.manual_version_id) \
                    THEN track_sources.manual_version_id \
                    ELSE excluded.version_id \
                END, \
                title = excluded.title, \
                disc_number = COALESCE(track_sources.manual_disc_number, excluded.disc_number), \
                track_number = excluded.track_number, \
                duration_ms = excluded.duration_ms, \
                sample_rate_hz = excluded.sample_rate_hz, \
                bit_depth = excluded.bit_depth, \
                codec = excluded.codec, \
                isrc = excluded.isrc, \
                replay_gain_track_db = excluded.replay_gain_track_db, \
                replay_gain_album_db = excluded.replay_gain_album_db, \
                replay_gain_track_peak = excluded.replay_gain_track_peak, \
                replay_gain_album_peak = excluded.replay_gain_album_peak, \
                artist_name = excluded.artist_name, \
                album_artist = excluded.album_artist, \
                genre = excluded.genre, \
                composer = excluded.composer, \
                channels = excluded.channels, \
                is_dsd = excluded.is_dsd, \
                embedded_lyrics = excluded.embedded_lyrics, \
                file_mtime = excluded.file_mtime, \
                file_size = excluded.file_size, \
                metadata_hash = excluded.metadata_hash, \
                content_fingerprint = COALESCE(excluded.content_fingerprint, track_sources.content_fingerprint), \
                audio_byte_len = COALESCE(excluded.audio_byte_len, track_sources.audio_byte_len), \
                file_status = 'present', \
                missing_since = NULL, \
                file_meta_json = excluded.file_meta_json, \
                release_year = COALESCE(excluded.release_year, track_sources.release_year), \
                bitrate_kbps = COALESCE(excluded.bitrate_kbps, track_sources.bitrate_kbps), \
                folder_id = excluded.folder_id, \
                added_at = COALESCE(track_sources.added_at, datetime('now')) \
             RETURNING id, CASE WHEN cloud_meta_json IS NOT NULL OR user_edits_json IS NOT NULL OR manual_disc_number IS NOT NULL THEN 1 ELSE 0 END",
        )
        .bind(&track.id)
        .bind(&track.version_id)
        .bind(provider_str)
        .bind(&track.external_track_id)
        .bind(&track.title)
        .bind(track.disc_number as i64)
        .bind(track.track_number as i64)
        .bind(track.duration_ms as i64)
        .bind(track.format.sample_rate_hz as i64)
        .bind(track.format.bit_depth as i64)
        .bind(codec_str)
        .bind(&track.isrc)
        .bind(track.replay_gain_track_db)
        .bind(track.replay_gain_album_db)
        .bind(track.replay_gain_track_peak)
        .bind(track.replay_gain_album_peak)
        .bind(&track.artist_name)
        .bind(&track.album_artist)
        .bind(&track.genre)
        .bind(&track.composer)
        .bind(channels)
        .bind(is_dsd)
        .bind(embedded_lyrics)
        .bind(file_mtime)
        .bind(file_size)
        .bind(metadata_hash)
        .bind(clean_fp)
        .bind(audio_byte_len)
        .bind(&file_meta_json)
        .bind(track.release_year)
        .bind(track.bitrate_kbps.map(i64::from))
        .bind(&folder_id)
        .fetch_one(&mut *conn)
        .await?;

        if has_other_layers != 0 {
            let default_policy = Self::get_default_metadata_policy_tx(conn).await?;
            let _ = Self::recompute_track_effective_tx(conn, &persisted_id, default_policy).await?;
        }

        Ok(persisted_id)
    }

    pub async fn upsert_track_source_with_cache(
        pool: &SqlitePool,
        track: &TrackSource,
        embedded_lyrics: Option<&str>,
        file_mtime: Option<i64>,
        file_size: Option<i64>,
        metadata_hash: Option<&str>,
    ) -> Result<TrackSource> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = Self::upsert_track_source_with_cache_tx(
            tx.conn(),
            track,
            embedded_lyrics,
            file_mtime,
            file_size,
            metadata_hash,
            None,
            None,
        )
        .await;
        let persisted_id = match res {
            Ok(id) => {
                tx.commit().await?;
                id
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        };

        let mut persisted = track.clone();
        persisted.id = persisted_id;
        persisted.has_lyrics = embedded_lyrics.is_some_and(|s| !s.trim().is_empty());
        Ok(persisted)
    }

    /// Upserts a track source while preserving any existing `embedded_lyrics`, `file_mtime`,
    /// `file_size`, `metadata_hash`, `content_fingerprint`, and `audio_byte_len`.
    pub async fn upsert_track_source_preserving_lyrics_tx(
        conn: &mut SqliteConnection,
        track: &TrackSource,
    ) -> Result<()> {
        let _ = upsert_basic_track_tx(conn, track, true).await?;
        Ok(())
    }

    /// Updates `file_mtime`, `file_size`, and `embedded_lyrics` inside a transaction.
    pub async fn update_track_source_cache_and_lyrics_tx(
        conn: &mut SqliteConnection,
        provider_id: &str,
        external_track_id: &str,
        file_mtime: i64,
        file_size: i64,
        embedded_lyrics: Option<&str>,
    ) -> Result<()> {
        sqlx::query(
            "UPDATE track_sources \
             SET file_mtime = ?, \
                 file_size = ?, \
                 embedded_lyrics = ? \
             WHERE provider_id = ? AND external_track_id = ?",
        )
        .bind(file_mtime)
        .bind(file_size)
        .bind(embedded_lyrics)
        .bind(provider_id)
        .bind(external_track_id)
        .execute(&mut *conn)
        .await?;
        Ok(())
    }

    /// Persists the `record_label` metadata field for a single `track_sources` row.
    pub async fn update_track_record_label_tx(
        conn: &mut SqliteConnection,
        track_source_id: &str,
        record_label: Option<&str>,
    ) -> Result<()> {
        let clean = record_label.map(str::trim).filter(|s| !s.is_empty());
        sqlx::query("UPDATE track_sources SET record_label = ? WHERE id = ?")
            .bind(clean)
            .bind(track_source_id.trim())
            .execute(&mut *conn)
            .await?;
        Ok(())
    }

    /// Persists the `record_label` metadata field for a `canonical_albums` row without
    /// clearing an existing non-null label when `record_label` is `None`.
    pub async fn update_album_record_label_tx(
        conn: &mut SqliteConnection,
        canonical_album_id: &str,
        record_label: Option<&str>,
    ) -> Result<()> {
        let clean = record_label.map(str::trim).filter(|s| !s.is_empty());
        sqlx::query(
            "UPDATE canonical_albums \
             SET record_label = COALESCE(?, record_label) \
             WHERE id = ?",
        )
        .bind(clean)
        .bind(canonical_album_id.trim())
        .execute(&mut *conn)
        .await?;
        Ok(())
    }

    /// High-throughput batch track insertion wrapped in an immediate transaction.
    pub async fn insert_track_sources_batch(
        pool: &SqlitePool,
        tracks: &[TrackSource],
    ) -> Result<()> {
        let mut tx = ImmediateTx::begin(pool).await?;

        let res: Result<()> = async {
            for track in tracks {
                let _ = upsert_basic_track_tx(tx.conn(), track, true).await?;
            }
            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Ok(())
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
