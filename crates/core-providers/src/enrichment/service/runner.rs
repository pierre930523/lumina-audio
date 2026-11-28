use std::collections::{HashMap, HashSet};

use core_db::{DbWriteCoordinator, ImmediateTx, LibraryRepository, SqlitePool};
use core_types::{AlbumMetadataLayer, CanonicalAlbum, LayeredMetadata};

use super::phases::{EnrichmentDraft, run_discogs_phase, run_musicbrainz_phase};
use super::verify::{LocalAlbumSignals, is_unmatchable_local_album};
use super::{CreditEnrichmentService, EnrichedAlbumResult};
use crate::error::ProviderError;
use crate::library::db_err;

impl CreditEnrichmentService {
    pub(super) async fn enrich_album_internal(
        &self,
        pool: &SqlitePool,
        album_id: &str,
        mb_artist_cache: &mut HashMap<String, Option<String>>,
        dg_artist_cache: &mut HashMap<u64, (Option<String>, Option<String>)>,
    ) -> Result<(EnrichedAlbumResult, Vec<String>), ProviderError> {
        let detail = LibraryRepository::get_album_detail(pool, album_id)
            .await
            .map_err(db_err)?
            .ok_or_else(|| ProviderError::AlbumNotFound(format!("Album '{album_id}' not found")))?;

        if !self.config.force_refresh
            && detail.album.musicbrainz_release_group_id.is_some()
            && !detail.credits.is_empty()
        {
            return Ok((
                EnrichedAlbumResult {
                    album_id: album_id.to_string(),
                    skipped: true,
                    ..Default::default()
                },
                Vec::new(),
            ));
        }

        let had_mb_rg_initially = detail.album.musicbrainz_release_group_id.is_some();
        let title = detail.album.title.clone();
        let artist_name = detail
            .album
            .album_artist
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| detail.album.artist_name.clone());

        // Strict guard: never run fuzzy online lookups for Unknown/Various placeholder albums
        // unless the album already has an explicit embedded MusicBrainz Release Group ID.
        if !had_mb_rg_initially && is_unmatchable_local_album(&title, &artist_name) {
            return Ok((
                EnrichedAlbumResult {
                    album_id: album_id.to_string(),
                    skipped: true,
                    ..Default::default()
                },
                Vec::new(),
            ));
        }

        let signals = LocalAlbumSignals::from_detail(&detail);
        let first_isrc = detail
            .versions
            .iter()
            .flat_map(|v| v.tracks.iter())
            .find_map(|t| {
                t.isrc
                    .as_ref()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
            });

        let mut draft = EnrichmentDraft::new(detail.album.musicbrainz_release_group_id.clone());

        if let Some(ref mb) = self.musicbrainz {
            run_musicbrainz_phase(
                mb,
                &title,
                &artist_name,
                first_isrc.as_deref(),
                had_mb_rg_initially,
                self.config.fetch_artist_bios,
                &signals,
                mb_artist_cache,
                &mut draft,
            )
            .await;
        }

        if let Some(ref dg) = self.discogs {
            run_discogs_phase(
                dg,
                &title,
                &artist_name,
                self.config.fetch_artist_bios,
                &signals,
                dg_artist_cache,
                &mut draft,
            )
            .await;
        }

        let yielded_new_data = (!had_mb_rg_initially && draft.resolved_mb_rg_id.is_some())
            || draft.resolved_title.is_some()
            || draft.resolved_album_artist.is_some()
            || draft.resolved_release_year.is_some()
            || draft.resolved_upc.is_some()
            || draft.resolved_bio.is_some()
            || draft.resolved_cover.is_some()
            || draft.primary_artist_mbid.is_some()
            || draft.primary_artist_bio.is_some()
            || draft.primary_artist_image.is_some()
            || !draft.track_cloud_meta.is_empty()
            || !draft.credit_candidates.is_empty();

        if !draft.upstream_errors.is_empty() && !yielded_new_data {
            return Err(draft
                .last_upstream_err
                .unwrap_or_else(|| ProviderError::Network(draft.upstream_errors.join("; "))));
        }

        let write_coord = DbWriteCoordinator::for_pool(pool);
        let _write_guard = write_coord.write_lock().await;

        // Unique-safe persistence of musicbrainz_release_group_id (merge_on_mbid_match defaults to false)
        let mut target_album_id = album_id.to_string();
        let mut merged_into_album_id: Option<String> = None;
        let mut mb_rg_to_write = draft.resolved_mb_rg_id.clone();

        if let Some(ref rg_id) = draft.resolved_mb_rg_id {
            if let Some(other) =
                LibraryRepository::find_canonical_album_by_mb_release_group(pool, rg_id)
                    .await
                    .map_err(db_err)?
            {
                if other.id != album_id {
                    if self.config.merge_on_mbid_match {
                        if LibraryRepository::merge_canonical_albums(pool, &other.id, album_id)
                            .await
                            .map_err(db_err)?
                        {
                            target_album_id = other.id.clone();
                            merged_into_album_id = Some(other.id);
                        }
                    } else {
                        mb_rg_to_write = None;
                    }
                }
            }
        }

        // Strict write isolation inside ONE ImmediateTx:
        // Enrichment writes ONLY `cloud_meta_json` on albums & tracks (never `file_meta_json`
        // or `user_edits_json`); `core-db`'s 3-layer resolver recomputes effective display
        // columns, `primary_artist_id`, and `search_fts` according to `meta_policy`.
        let mut credit_artist_ids: Vec<(String, String)> =
            Vec::with_capacity(draft.credit_candidates.len());
        {
            let mut tx = ImmediateTx::begin(pool).await.map_err(db_err)?;
            let tx_res: Result<(), ProviderError> = async {
                if draft.primary_artist_mbid.is_some()
                    || draft.primary_artist_bio.is_some()
                    || draft.primary_artist_image.is_some()
                {
                    let _ = LibraryRepository::upsert_artist_by_mbid_or_name_tx(
                        tx.conn(),
                        &artist_name,
                        draft.primary_artist_mbid.as_deref(),
                        draft.primary_artist_bio.as_deref(),
                        draft.primary_artist_image.as_deref(),
                    )
                    .await
                    .map_err(db_err)?;
                }

                let cloud_album_layer = AlbumMetadataLayer {
                    title: draft.resolved_title.clone(),
                    sort_title: draft
                        .resolved_title
                        .as_deref()
                        .map(CanonicalAlbum::derive_sort_title),
                    album_artist: draft.resolved_album_artist.clone(),
                    release_year: draft.resolved_release_year,
                    upc: draft.resolved_upc.clone(),
                    musicbrainz_release_group_id: mb_rg_to_write.clone(),
                    editorial_bio: draft.resolved_bio.clone(),
                    cover_url: draft.resolved_cover.clone(),
                    merged_cover_path: draft.resolved_cover.clone(),
                };
                if !cloud_album_layer.is_empty() {
                    LibraryRepository::write_album_cloud_meta_tx(
                        tx.conn(),
                        &target_album_id,
                        &cloud_album_layer,
                    )
                    .await
                    .map_err(db_err)?;
                }

                if !draft.track_cloud_meta.is_empty() {
                    for ver in &detail.versions {
                        for trk in &ver.tracks {
                            if let Some(cloud_trk) = draft
                                .track_cloud_meta
                                .get(&(trk.disc_number, trk.track_number))
                            {
                                LibraryRepository::write_track_cloud_meta_tx(
                                    tx.conn(),
                                    &trk.id,
                                    cloud_trk,
                                )
                                .await
                                .map_err(db_err)?;
                            }
                        }
                    }
                }

                for credit in &draft.credit_candidates {
                    let artist = LibraryRepository::upsert_artist_by_mbid_or_name_tx(
                        tx.conn(),
                        &credit.artist_name,
                        credit.mbid.as_deref(),
                        credit.bio.as_deref(),
                        credit.image_url.as_deref(),
                    )
                    .await
                    .map_err(db_err)?;
                    credit_artist_ids.push((artist.id, credit.role.trim().to_string()));
                }

                Ok(())
            }
            .await;

            match tx_res {
                Ok(()) => tx.commit().await.map_err(db_err)?,
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(e);
                }
            }
        }

        let existing_credits = LibraryRepository::list_credits_for_album(pool, &target_album_id)
            .await
            .map_err(db_err)?;
        let mut existing_credit_set: HashSet<(String, String)> = existing_credits
            .into_iter()
            .map(|c| (c.artist_id, c.role.trim().to_string()))
            .collect();

        let mut credits_added = 0usize;
        for (artist_id, trimmed_role) in credit_artist_ids {
            LibraryRepository::upsert_album_credit(
                pool,
                &target_album_id,
                &artist_id,
                &trimmed_role,
            )
            .await
            .map_err(db_err)?;
            if existing_credit_set.insert((artist_id, trimmed_role)) {
                credits_added += 1;
            }
        }

        if draft.upstream_errors.is_empty() {
            LibraryRepository::mark_album_enriched(pool, &target_album_id)
                .await
                .map_err(db_err)?;
        }

        Ok((
            EnrichedAlbumResult {
                album_id: target_album_id,
                skipped: false,
                merged_into_album_id,
                mb_release_group_id: draft.resolved_mb_rg_id,
                credits_added,
            },
            draft.upstream_errors,
        ))
    }
}
