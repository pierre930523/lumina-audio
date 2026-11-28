use std::collections::HashMap;

use core_db::{DbWriteCoordinator, IngestionRepository, SqlitePool};
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ExternalCatalogIngestBatch,
    TocSignature, TrackSource,
};

use super::{IngestionPipeline, SKIPPED_BATCH_CHUNK};
use crate::error::ProviderError;
use crate::library::{LibrarySyncService, SyncPersistReport};
use crate::local::mapper::{AlbumSyncMetadata, VersionSyncMetadata, extract_edition_label};
use crate::local::metadata::split_artists;

impl IngestionPipeline {
    /// Canonical ingestion handoff for external streaming catalogs (metadata + platform IDs only,
    /// zero stream URLs). Merges versions across local & streaming while preserving `metadata_overrides`.
    pub async fn ingest_external_catalog(
        pool: &SqlitePool,
        batch: &ExternalCatalogIngestBatch,
    ) -> Result<SyncPersistReport, ProviderError> {
        let mut albums: Vec<CanonicalAlbum> = Vec::with_capacity(batch.albums.len());
        let mut tracks: Vec<TrackSource> = Vec::new();
        let mut album_meta: HashMap<String, AlbumSyncMetadata> = HashMap::new();
        let mut track_artists_by_ext: HashMap<String, Vec<String>> = HashMap::new();

        for ext_alb in &batch.albums {
            if ext_alb.tracks.is_empty() {
                continue;
            }
            let title = if ext_alb.title.trim().is_empty() {
                "Unknown Album"
            } else {
                ext_alb.title.trim()
            };
            let artist = if ext_alb.artist_name.trim().is_empty() {
                "Unknown Artist"
            } else {
                ext_alb.artist_name.trim()
            };

            let (base_title, extracted_edition) = extract_edition_label(title);
            let mut album = CanonicalAlbum::new(
                if base_title.is_empty() {
                    title
                } else {
                    &base_title
                },
                artist,
            )?;
            if let Some(ref aa) = ext_alb.album_artist {
                album = album.with_album_artist(aa);
            }
            if let Some(yr) = ext_alb.release_year {
                if let Ok(a) = album.clone().with_release_year(yr) {
                    album = a;
                }
            }
            if let Some(ref cover) = ext_alb.cover_url {
                if !cover.trim().is_empty() {
                    album = album.with_cover_url(cover);
                }
            }

            let rep_format = ext_alb
                .tracks
                .first()
                .map(|t| {
                    let codec = t.codec.unwrap_or(AudioCodec::Flac);
                    let sr = t.sample_rate_hz.unwrap_or(44_100).max(8_000);
                    let bd = t.bit_depth.unwrap_or(16).clamp(8, 32);
                    if codec.is_dsd() {
                        AudioFormat::dsd(codec, sr, 2).unwrap_or_else(|_| AudioFormat::cd_quality())
                    } else {
                        AudioFormat::pcm(codec, sr, bd, 2)
                            .unwrap_or_else(|_| AudioFormat::cd_quality())
                    }
                })
                .unwrap_or_else(AudioFormat::cd_quality);

            let mut version = AlbumVersion::new(
                &album.id,
                batch.provider,
                &ext_alb.external_album_id,
                rep_format,
            )?;
            if let Some(ed) = ext_alb
                .edition_label
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or(extracted_edition)
            {
                version = version.with_edition_label(ed);
            }

            let mut sorted_tracks = ext_alb.tracks.clone();
            sorted_tracks.sort_by_key(|t| (t.disc_number, t.track_number));

            let mut durations: Vec<u64> = Vec::with_capacity(sorted_tracks.len());
            let mut max_disc: u32 = ext_alb.disc_count.max(1);

            for ext_trk in sorted_tracks {
                let codec = ext_trk.codec.unwrap_or(AudioCodec::Flac);
                let sr = ext_trk.sample_rate_hz.unwrap_or(44_100).max(8_000);
                let bd = ext_trk.bit_depth.unwrap_or(16).clamp(8, 32);
                let fmt = if codec.is_dsd() {
                    AudioFormat::dsd(codec, sr, 2).unwrap_or_else(|_| AudioFormat::cd_quality())
                } else {
                    AudioFormat::pcm(codec, sr, bd, 2).unwrap_or_else(|_| AudioFormat::cd_quality())
                };

                let disc = ext_trk.disc_number.max(1);
                let trk_num = ext_trk.track_number.max(1);
                let dur = ext_trk.duration_ms.max(1);
                max_disc = max_disc.max(u32::from(disc));

                let mut trk = TrackSource::new(
                    &version.id,
                    batch.provider,
                    &ext_trk.external_track_id,
                    if ext_trk.title.trim().is_empty() {
                        "Unknown Title"
                    } else {
                        ext_trk.title.trim()
                    },
                    disc,
                    trk_num,
                    dur,
                    fmt,
                )?;
                let trk_artist = ext_trk
                    .artist_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or(artist);
                trk = trk.with_artist_name(trk_artist);
                track_artists_by_ext
                    .insert(ext_trk.external_track_id.clone(), split_artists(trk_artist));
                if let Some(ref aa) = ext_trk.album_artist {
                    trk = trk.with_album_artist(aa);
                }
                if let Some(ref g) = ext_trk.genre {
                    trk = trk.with_genre(g);
                }
                if let Some(ref c) = ext_trk.composer {
                    trk = trk.with_composer(c);
                }
                if let Some(ref isrc) = ext_trk.isrc {
                    if let Ok(t) = trk.clone().with_isrc(isrc) {
                        trk = t;
                    }
                }
                durations.push(dur);
                tracks.push(trk);
            }

            let toc = if !durations.is_empty() {
                Some(TocSignature::from_durations(max_disc, durations))
            } else {
                None
            };
            let track_count = ext_alb.tracks.len() as u32;
            let mut vmap = HashMap::new();
            vmap.insert(
                version.id.clone(),
                VersionSyncMetadata {
                    toc_signature: toc.clone(),
                    disc_count: max_disc,
                    track_count,
                },
            );
            album_meta.insert(
                album.id.clone(),
                AlbumSyncMetadata {
                    upc: ext_alb.upc.clone(),
                    toc_signature: toc,
                    disc_count: max_disc,
                    track_count,
                    version_metadata: vmap,
                },
            );

            album.add_version(version);
            albums.push(album);
        }

        if albums.is_empty() {
            return Ok(SyncPersistReport::default());
        }

        let report =
            LibrarySyncService::persist_provider_albums(pool, &albums, &tracks, &album_meta)
                .await?;

        // Link persisted streaming TrackSources into canonical_tracks & track_artists in chunked ImmediateTx batches
        let write_coord = DbWriteCoordinator::for_pool(pool);
        let provider_str = batch.provider.as_str();
        for chunk in tracks.chunks(SKIPPED_BATCH_CHUNK) {
            if let Ok((_wg, mut tx)) = write_coord.begin_immediate(pool).await {
                let mut ok = true;
                for trk in chunk {
                    let row = IngestionRepository::get_track_and_album_by_external_id_tx(
                        tx.conn(),
                        provider_str,
                        &trk.external_track_id,
                    )
                    .await
                    .unwrap_or(None);

                    if let Some((track_id, canonical_album_id)) = row {
                        let artists = track_artists_by_ext
                            .get(&trk.external_track_id)
                            .cloned()
                            .unwrap_or_default();
                        if IngestionRepository::upsert_canonical_track_for_source_tx(
                            tx.conn(),
                            &track_id,
                            &canonical_album_id,
                            trk,
                            &artists,
                        )
                        .await
                        .is_err()
                        {
                            ok = false;
                            break;
                        }
                    }
                }
                if ok {
                    let _ = tx.commit().await;
                } else {
                    let _ = tx.rollback().await;
                }
            }
            tokio::task::yield_now().await;
        }

        Ok(report)
    }
}
