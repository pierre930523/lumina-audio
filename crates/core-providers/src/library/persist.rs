use std::collections::{HashMap, HashSet};

use core_db::{
    DbWriteCoordinator, ImmediateTx, IngestionRepository, LibraryRepository, SqlitePool,
    normalize_match_key, sync_artist_fts_conn,
};
use core_types::{CanonicalAlbum, TrackSource};
use tracing::warn;

use crate::error::ProviderError;
use crate::local::AlbumSyncMetadata;
use crate::local::metadata::split_artists;
use crate::local::pipeline::{
    LiveManualTrackLock, build_album_file_layer, build_track_file_layer,
    load_live_manual_track_locks_tx, persist_album_file_layer_tx, remove_invalidated_artwork_files,
    resolve_primaries_for_albums_tx,
};

use super::dedup::resolve_chunk_candidates_under_write_lock;
use super::match_policy::{BatchAlbumIsrcEntry, find_compatible_batch_album_by_isrc};
use super::sync_helpers::persist_remaining_tracks;
use super::{AlbumEntry, DB_BATCH_TRACKS, SyncPersistReport, db_err};

pub(super) async fn persist_provider_albums_inner(
    pool: &SqlitePool,
    albums: &[CanonicalAlbum],
    tracks: &[TrackSource],
    album_meta: &HashMap<String, AlbumSyncMetadata>,
    run_orphan_prune: bool,
) -> Result<(SyncPersistReport, HashSet<String>), ProviderError> {
    let write_coord = DbWriteCoordinator::for_pool(pool);
    let mut report = SyncPersistReport::default();
    let mut all_touched_albums: HashSet<String> = HashSet::new();
    let mut tracks_by_version: HashMap<&str, Vec<(usize, &TrackSource)>> = HashMap::new();
    for (idx, trk) in tracks.iter().enumerate() {
        tracks_by_version
            .entry(trk.version_id.as_str())
            .or_default()
            .push((idx, trk));
    }

    // Bottom-up filter: only keep versions that have >= 1 track and albums that have >= 1 version.
    let mut filtered_albums: Vec<AlbumEntry<'_>> = Vec::with_capacity(albums.len());
    for album in albums {
        let mut valid_versions = Vec::new();
        let mut album_track_count = 0usize;
        for ver in &album.versions {
            if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                if !ver_tracks.is_empty() {
                    album_track_count += ver_tracks.len();
                    valid_versions.push((ver, ver_tracks.clone()));
                }
            }
        }
        if !valid_versions.is_empty() {
            filtered_albums.push(AlbumEntry {
                album,
                versions: valid_versions,
                track_count: album_track_count,
            });
        }
    }

    let mut version_id_map: HashMap<String, String> = HashMap::new();
    let mut inserted_track_indices: HashSet<usize> = HashSet::new();

    // Partition filtered albums into chunks of ~200 tracks per ImmediateTx under DbWriteCoordinator.
    let mut start_idx = 0usize;
    while start_idx < filtered_albums.len() {
        let mut end_idx = start_idx;
        let mut chunk_tracks = 0usize;
        while end_idx < filtered_albums.len() {
            let next_count = filtered_albums[end_idx].track_count;
            if end_idx > start_idx && chunk_tracks + next_count > DB_BATCH_TRACKS {
                break;
            }
            chunk_tracks += next_count;
            end_idx += 1;
            if chunk_tracks >= DB_BATCH_TRACKS {
                break;
            }
        }
        let chunk = &filtered_albums[start_idx..end_idx];
        start_idx = end_idx;

        // Hold single-writer lock across BOTH candidate resolution AND ImmediateTx commit!
        let _write_guard = write_coord.write_lock().await;
        let resolved_chunk =
            resolve_chunk_candidates_under_write_lock(pool, chunk, album_meta, &mut report).await?;

        let mut tx = ImmediateTx::begin(pool).await.map_err(db_err)?;
        let mut batch_by_norm: HashMap<(String, String), String> = HashMap::new();
        let mut batch_by_mb: HashMap<String, String> = HashMap::new();
        let mut batch_by_upc: HashMap<String, String> = HashMap::new();
        let mut batch_isrc_entries: Vec<BatchAlbumIsrcEntry> = Vec::new();
        let mut fts_artists: Vec<(String, String, Option<String>)> = Vec::new();
        let mut chunk_touched_albums: HashSet<String> = HashSet::new();

        let tx_res: Result<(), ProviderError> = async {
            let mut ext_by_provider: HashMap<&str, Vec<String>> = HashMap::new();
            for rca in &resolved_chunk {
                for (ver, ver_tracks) in &rca.entry.versions {
                    let list = ext_by_provider.entry(ver.provider.as_str()).or_default();
                    for (_, t) in ver_tracks {
                        list.push(t.external_track_id.clone());
                    }
                }
            }
            let mut manual_locks: HashMap<(String, String), LiveManualTrackLock> = HashMap::new();
            for (prov, ext_ids) in ext_by_provider {
                for (ext_id, lock) in
                    load_live_manual_track_locks_tx(&mut tx, prov, &ext_ids).await?
                {
                    manual_locks.insert((prov.to_string(), ext_id), lock);
                }
            }

            for rca in &resolved_chunk {
                let album = rca.entry.album;
                let has_any_unlocked = rca.entry.versions.iter().any(|(ver, ver_tracks)| {
                    let prov = ver.provider.as_str().to_string();
                    ver_tracks
                        .iter()
                        .any(|(_, t)| !manual_locks.contains_key(&(prov.clone(), t.external_track_id.clone())))
                });
                let artist_name = if album.artist_name.trim().is_empty() {
                    "Unknown Artist"
                } else {
                    album.artist_name.trim()
                };
                let effective_album_title = if !rca.is_unknown && !rca.base_title.is_empty() {
                    rca.base_title.as_str()
                } else {
                    album.title.as_str()
                };
                let incoming_provider = rca
                    .entry
                    .versions
                    .first()
                    .map(|(v, _)| v.provider.as_str())
                    .unwrap_or("local");

                let (target_album_id_opt, is_new_album, fallback_artist_name) = if has_any_unlocked {
                    let artist = LibraryRepository::upsert_artist_by_mbid_or_name_tx(
                        tx.conn(),
                        artist_name,
                        None,
                        None,
                        None,
                    )
                    .await
                    .map_err(db_err)?;
                    fts_artists.push((
                        artist.id.clone(),
                        artist.name.clone(),
                        artist.biography.clone(),
                    ));

                    let norm_pair = (
                        normalize_match_key(effective_album_title),
                        normalize_match_key(artist_name),
                    );
                    let matched_in_batch = if rca.is_group_locked {
                        None
                    } else {
                        rca.mb_rg_id
                            .as_deref()
                            .and_then(|rg| batch_by_mb.get(&rg.to_ascii_lowercase()).cloned())
                            .or_else(|| {
                                rca.upc
                                    .as_deref()
                                    .and_then(|u| batch_by_upc.get(u).cloned())
                            })
                            .or_else(|| {
                                find_compatible_batch_album_by_isrc(
                                    &batch_isrc_entries,
                                    &rca.isrcs,
                                    rca.max_version_tracks,
                                    rca.is_compilation,
                                )
                            })
                            .or_else(|| {
                                if !rca.is_unknown {
                                    batch_by_norm.get(&norm_pair).cloned()
                                } else {
                                    None
                                }
                            })
                    };

                    let resolved_primary = rca.primary_id.clone().or(matched_in_batch);
                    let (tid, is_new) = if let Some(primary_id) = resolved_primary {
                        report.albums_matched += 1;
                        (primary_id, false)
                    } else {
                        let mut shell = album.clone();
                        shell.versions = Vec::new();
                        if effective_album_title != shell.title {
                            shell.title = effective_album_title.to_string();
                            shell.sort_title =
                                CanonicalAlbum::derive_sort_title(effective_album_title);
                        }
                        LibraryRepository::insert_canonical_album_tx(
                            tx.conn(),
                            &shell,
                            Some(&artist.id),
                        )
                        .await
                        .map_err(db_err)?;
                        report.albums_inserted += 1;
                        (shell.id, true)
                    };

                    if !rca.is_group_locked {
                        if let Some(ref rg) = rca.mb_rg_id {
                            batch_by_mb
                                .entry(rg.to_ascii_lowercase())
                                .or_insert_with(|| tid.clone());
                        }
                        if let Some(ref u) = rca.upc {
                            batch_by_upc
                                .entry(u.clone())
                                .or_insert_with(|| tid.clone());
                        }
                        if !rca.isrcs.is_empty() {
                            batch_isrc_entries.push(BatchAlbumIsrcEntry {
                                album_id: tid.clone(),
                                isrcs: rca.isrcs.clone(),
                                track_count: rca.max_version_tracks,
                                is_compilation: rca.is_compilation,
                            });
                        }
                        if !rca.is_unknown {
                            batch_by_norm
                                .entry(norm_pair)
                                .or_insert_with(|| tid.clone());
                        }
                    }
                    chunk_touched_albums.insert(tid.clone());
                    (Some(tid), is_new, artist.name)
                } else {
                    (rca.primary_id.clone(), false, artist_name.to_string())
                };

                let mut unlocked_used_target = false;
                for (ver, ver_tracks) in &rca.entry.versions {
                    let prov_str = ver.provider.as_str().to_string();
                    let has_unlocked_in_ver = ver_tracks.iter().any(|(_, t)| {
                        !manual_locks.contains_key(&(prov_str.clone(), t.external_track_id.clone()))
                    });

                    let (default_ver_id, default_alb_id) = if has_unlocked_in_ver {
                        let target_alb = target_album_id_opt
                            .as_ref()
                            .expect("target_album_id exists when unlocked tracks present");
                        let pinned_group = LibraryRepository::version_manual_group_id_tx(
                            tx.conn(),
                            ver.provider.as_str(),
                            &ver.external_album_id,
                        )
                        .await
                        .map_err(db_err)?
                        .and_then(|(_, mg)| mg);
                        let ver_album_id = pinned_group.unwrap_or_else(|| target_alb.clone());
                        if ver_album_id == *target_alb {
                            unlocked_used_target = true;
                        }
                        let mut ver_to_save = (*ver).clone();
                        ver_to_save.canonical_album_id = ver_album_id.clone();

                        let authoritative_id =
                            LibraryRepository::insert_album_version_tx(tx.conn(), &ver_to_save)
                                .await
                                .map_err(db_err)?;

                        version_id_map.insert(ver.id.clone(), authoritative_id.clone());
                        report.versions_upserted += 1;
                        chunk_touched_albums.insert(ver_album_id.clone());

                        if let Some(meta) = album_meta.get(&album.id) {
                            if let Some(vmeta) = meta.version_metadata.get(&ver.id) {
                                if let Some(ref toc) = vmeta.toc_signature {
                                    let _ = IngestionRepository::update_album_version_toc_tx(
                                        tx.conn(),
                                        &authoritative_id,
                                        &toc.digest,
                                        vmeta.disc_count.max(1),
                                        vmeta.track_count,
                                    )
                                    .await;
                                }
                            } else if let Some(ref toc) = meta.toc_signature {
                                let _ = IngestionRepository::update_album_version_toc_tx(
                                    tx.conn(),
                                    &authoritative_id,
                                    &toc.digest,
                                    meta.disc_count.max(1),
                                    meta.track_count,
                                )
                                .await;
                            }
                        }
                        (Some(authoritative_id), Some(ver_album_id))
                    } else {
                        (None, None)
                    };

                    for (idx, track) in ver_tracks {
                        let locked = manual_locks
                            .get(&(prov_str.clone(), track.external_track_id.clone()));
                        let (track_ver_id, track_alb_id) = if let Some(lock) = locked {
                            chunk_touched_albums.insert(lock.album_id.clone());
                            (lock.version_id.as_str(), lock.album_id.as_str())
                        } else {
                            let (Some(vid), Some(aid)) =
                                (default_ver_id.as_deref(), default_alb_id.as_deref())
                            else {
                                continue;
                            };
                            (vid, aid)
                        };
                        let mut trk = (*track).clone();
                        trk.version_id = track_ver_id.to_string();
                        let file_layer_trk = trk.clone();
                        if let Some(md) = locked.and_then(|l| l.manual_disc_number) {
                            trk.disc_number = md.min(u32::from(u16::MAX)) as u16;
                        }
                        LibraryRepository::upsert_track_source_preserving_lyrics_tx(
                            tx.conn(),
                            &trk,
                        )
                        .await
                        .map_err(db_err)?;
                        let saved_id = IngestionRepository::get_track_and_album_by_external_id_tx(
                            tx.conn(),
                            trk.provider.as_str(),
                            &trk.external_track_id,
                        )
                        .await
                        .ok()
                        .flatten()
                        .map(|(id, _)| id)
                        .unwrap_or_else(|| trk.id.clone());
                        let artists_list = trk
                            .artist_name
                            .as_deref()
                            .map(split_artists)
                            .filter(|list| !list.is_empty())
                            .unwrap_or_else(|| vec![fallback_artist_name.clone()]);
                        let canonical_track_id = match IngestionRepository::upsert_canonical_track_for_source_tx(
                            tx.conn(),
                            &saved_id,
                            track_alb_id,
                            &trk,
                            &artists_list,
                        )
                        .await
                        {
                            Ok((ct_id, _)) => Some(ct_id),
                            Err(e) => {
                                warn!("Failed to upsert canonical track for source '{saved_id}': {e}");
                                None
                            }
                        };

                        let track_file_layer =
                            build_track_file_layer(&file_layer_trk, file_layer_trk.release_year, None);
                        LibraryRepository::write_track_file_meta_tx(
                            tx.conn(),
                            &saved_id,
                            &track_file_layer,
                        )
                        .await
                        .map_err(db_err)?;

                        if let Some(ref ct_id) = canonical_track_id
                            && artists_list.len() > 1
                        {
                            let _ = IngestionRepository::link_track_artists_tx(
                                tx.conn(),
                                ct_id,
                                &artists_list,
                                "performer",
                            )
                            .await;
                        }

                        inserted_track_indices.insert(*idx);
                        report.tracks_upserted += 1;
                        report.search_index_entries += 1;
                    }
                }

                if unlocked_used_target
                    && let Some(ref target_album_id) = target_album_id_opt
                {
                    let album_file_layer = build_album_file_layer(
                        album,
                        effective_album_title,
                        artist_name,
                        rca.upc.as_deref(),
                        rca.mb_rg_id.as_deref(),
                    );
                    if persist_album_file_layer_tx(
                        &mut tx,
                        target_album_id,
                        incoming_provider,
                        is_new_album,
                        &album_file_layer,
                    )
                    .await?
                    {
                        report.search_index_entries += 1;
                    }
                }
            }

            resolve_primaries_for_albums_tx(&mut tx, &chunk_touched_albums).await;

            // Ensure base artists are synced in FTS5; album & track FTS entries were already
            // synced by `recompute_album_effective_tx` / `recompute_track_effective_tx`.
            let mut seen_art = HashSet::new();
            for (aid, name, bio) in &fts_artists {
                if seen_art.insert(aid.as_str()) {
                    sync_artist_fts_conn(tx.conn(), aid, name, bio.as_deref())
                        .await
                        .map_err(db_err)?;
                    report.search_index_entries += 1;
                }
            }

            Ok(())
        }
        .await;

        match tx_res {
            Ok(()) => {
                tx.commit().await.map_err(db_err)?;
                all_touched_albums.extend(chunk_touched_albums);
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
        drop(_write_guard);
        tokio::task::yield_now().await;
    }

    // Persist any standalone tracks whose version_id mapped to an inserted version.
    let remaining_tracks: Vec<&TrackSource> = tracks
        .iter()
        .enumerate()
        .filter(|(idx, _)| !inserted_track_indices.contains(idx))
        .map(|(_, t)| t)
        .collect();
    persist_remaining_tracks(
        pool,
        &write_coord,
        &remaining_tracks,
        &version_id_map,
        &mut report,
    )
    .await?;

    // Unconditional orphan cleanup & primary resolution at the end of provider album persistence.
    if run_orphan_prune {
        let invalidated = {
            let (_wg, mut tx) = write_coord.begin_immediate(pool).await.map_err(db_err)?;
            match LibraryRepository::prune_orphan_albums_and_versions_tx(tx.conn(), None)
                .await
                .map_err(db_err)
            {
                Ok(rep) => {
                    resolve_primaries_for_albums_tx(&mut tx, &all_touched_albums).await;
                    tx.commit().await.map_err(db_err)?;
                    rep.invalidated_artwork_paths
                }
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(e);
                }
            }
        };
        remove_invalidated_artwork_files(invalidated).await;
    }

    Ok((report, all_touched_albums))
}
