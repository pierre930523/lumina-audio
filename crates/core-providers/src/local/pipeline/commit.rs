use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use core_db::{
    ImmediateTx, IngestionRepository, LibraryRepository, RelinkCandidate, TrackFileCacheInfo,
    normalize_match_key, sync_artist_fts_conn,
};
use core_types::{AlbumVersion, CanonicalAlbum, ProviderKind, ScanProgressEvent, TrackSource};
use tracing::warn;

use super::IngestionPipeline;
use super::commit_locks::{
    load_live_manual_track_locks_tx, recompute_version_tocs_tx, resolve_primaries_for_albums_tx,
    sync_probed_track_skip_status_tx,
};
use super::commit_meta::{
    build_album_file_layer, finalize_probed_track_layers_tx, persist_album_file_layer_tx,
};
use super::probe::ProbedTrackItem;
use super::relink::{ResolvedCanonicalAlbum, lookup_relink_candidate, try_relink_moved_track_tx};
use crate::error::ProviderError;
use crate::library::db_err;
use crate::library::match_policy::{BatchAlbumIsrcEntry, find_compatible_batch_album_by_isrc};
use crate::local::artwork::{
    VersionAssetsBatch, index_assets_for_committed_versions, record_version_asset_source,
};
use crate::local::mapper::AlbumMapper;
use crate::local::metadata::{ExtractedMetadata, split_artists};
use crate::local::scanner::normalize_path;

struct PreparedVersion<'a> {
    version: &'a AlbumVersion,
    tracks: Vec<(&'a TrackSource, String)>,
}

struct PreparedAlbum<'a> {
    album: &'a CanonicalAlbum,
    versions: Vec<PreparedVersion<'a>>,
    resolved: ResolvedCanonicalAlbum,
}

impl IngestionPipeline {
    pub(super) async fn persist_probed_batch(
        &self,
        provider_id: &str,
        batch: Vec<ProbedTrackItem>,
        existing_cache: &HashMap<String, TrackFileCacheInfo>,
        active_skipped: &mut HashSet<String>,
        progress: &mut ScanProgressEvent,
    ) -> Result<HashSet<String>, ProviderError> {
        if batch.is_empty() {
            return Ok(HashSet::new());
        }

        let provider_kind = provider_id
            .parse::<ProviderKind>()
            .unwrap_or(ProviderKind::Local);

        let mut item_by_norm: HashMap<String, ProbedTrackItem> =
            HashMap::with_capacity(batch.len());
        let mut to_map: Vec<(PathBuf, ExtractedMetadata)> = Vec::with_capacity(batch.len());
        for item in batch {
            to_map.push((item.path.clone(), item.meta.clone()));
            item_by_norm.insert(item.norm_path.clone(), item);
        }

        // Offload AlbumMapper (which may inspect directories for folder cover art) off Tokio workers.
        let (albums, tracks, album_meta) = tokio::task::spawn_blocking(move || {
            AlbumMapper::map_scanned_items_with_metadata(to_map, provider_kind)
        })
        .await
        .map_err(|e| ProviderError::ScanError(format!("AlbumMapper worker panicked: {e}")))??;

        let mut tracks_by_version: HashMap<&str, Vec<&TrackSource>> = HashMap::new();
        for trk in &tracks {
            tracks_by_version
                .entry(trk.version_id.as_str())
                .or_default()
                .push(trk);
        }

        // Bottom-up filter: retain ONLY versions with >= 1 valid probed track and albums with >= 1 version.
        let mut valid_albums: Vec<(&CanonicalAlbum, Vec<PreparedVersion<'_>>)> =
            Vec::with_capacity(albums.len());
        let mut relink_candidates: HashMap<String, RelinkCandidate> = HashMap::new();

        for album in &albums {
            let mut valid_versions = Vec::new();
            for ver in &album.versions {
                if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                    let mut valid_tracks = Vec::new();
                    for track in ver_tracks {
                        let norm_path = normalize_path(&track.external_track_id);
                        if item_by_norm.contains_key(&norm_path) {
                            valid_tracks.push((*track, norm_path));
                        }
                    }
                    if !valid_tracks.is_empty() {
                        valid_versions.push(PreparedVersion {
                            version: ver,
                            tracks: valid_tracks,
                        });
                    }
                }
            }
            if valid_versions.is_empty() {
                continue;
            }

            // Disk existence checks for fingerprint relink happen BEFORE acquiring the DB write lock.
            for pv in &valid_versions {
                for (_, norm_path) in &pv.tracks {
                    lookup_relink_candidate(
                        &self.pool,
                        provider_id,
                        norm_path,
                        existing_cache,
                        &item_by_norm,
                        &mut relink_candidates,
                    )
                    .await;
                }
            }

            valid_albums.push((album, valid_versions));
        }

        if valid_albums.is_empty() {
            return Ok(HashSet::new());
        }

        // Acquire the single-writer lock BEFORE resolving canonical album candidates and hold it
        // continuously through ImmediateTx commit, eliminating TOCTOU album resolution/merge races.
        let _write_guard = self.write_coord.write_lock().await;

        let mut prepared_albums: Vec<PreparedAlbum<'_>> = Vec::with_capacity(valid_albums.len());
        for (album, valid_versions) in valid_albums {
            let resolved = self
                .resolve_canonical_album_under_write_lock(album, &tracks_by_version, &album_meta)
                .await?;
            prepared_albums.push(PreparedAlbum {
                album,
                versions: valid_versions,
                resolved,
            });
        }

        let mut tx = ImmediateTx::begin(&self.pool).await.map_err(db_err)?;
        let mut added_delta = 0u64;
        let mut updated_delta = 0u64;
        let mut cleared_skipped_in_tx: Vec<String> = Vec::new();
        let mut touched_album_ids: HashSet<String> = HashSet::new();
        let mut version_assets_batch = VersionAssetsBatch::new();

        let all_batch_ext_ids: Vec<String> = prepared_albums
            .iter()
            .flat_map(|pa| pa.versions.iter())
            .flat_map(|pv| pv.tracks.iter().map(|(t, _)| t.external_track_id.clone()))
            .collect();

        let batch_res: Result<(), ProviderError> = async {
            let manual_track_locks =
                load_live_manual_track_locks_tx(&mut tx, provider_id, &all_batch_ext_ids).await?;
            let mut fts_artists: Vec<(String, String, Option<String>)> = Vec::new();
            let mut touched_version_ids: HashSet<String> = HashSet::new();
            let mut batch_album_by_key: HashMap<(String, String), String> = HashMap::new();
            let mut batch_isrc_entries: Vec<BatchAlbumIsrcEntry> = Vec::new();
            let mut used_relink_ids: HashSet<String> = HashSet::new();

            for pa in &prepared_albums {
                let album = pa.album;
                let res = &pa.resolved;
                let has_any_unlocked_track = pa.versions.iter().any(|pv| {
                    pv.tracks
                        .iter()
                        .any(|(t, _)| !manual_track_locks.contains_key(&t.external_track_id))
                });
                let artist_name = if album.artist_name.trim().is_empty() {
                    "Unknown Artist"
                } else {
                    album.artist_name.trim()
                };
                let effective_album_title = if !res.is_unknown && !res.base_title.is_empty() {
                    res.base_title.as_str()
                } else {
                    album.title.as_str()
                };

                let (target_album_id_opt, is_new_album) = if has_any_unlocked_track {
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
                    let resolved_existing = res
                        .primary_id
                        .clone()
                        .or_else(|| {
                            if res.is_group_locked {
                                None
                            } else {
                                find_compatible_batch_album_by_isrc(
                                    &batch_isrc_entries,
                                    &res.isrcs,
                                    res.track_count,
                                    res.is_compilation,
                                )
                            }
                        })
                        .or_else(|| {
                            if !res.is_unknown && !res.is_group_locked {
                                batch_album_by_key.get(&norm_pair).cloned()
                            } else {
                                None
                            }
                        });

                    let (tid, is_new) = if let Some(primary_id) = resolved_existing {
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
                        (shell.id, true)
                    };

                    if !res.is_group_locked {
                        if !res.is_unknown {
                            batch_album_by_key
                                .entry(norm_pair)
                                .or_insert_with(|| tid.clone());
                        }
                        if !res.isrcs.is_empty() {
                            batch_isrc_entries.push(BatchAlbumIsrcEntry {
                                album_id: tid.clone(),
                                isrcs: res.isrcs.clone(),
                                track_count: res.track_count,
                                is_compilation: res.is_compilation,
                            });
                        }
                    }
                    touched_album_ids.insert(tid.clone());
                    (Some(tid), is_new)
                } else {
                    (res.primary_id.clone(), false)
                };

                let mut unlocked_used_target = false;
                for pv in &pa.versions {
                    let has_unlocked_in_ver = pv
                        .tracks
                        .iter()
                        .any(|(t, _)| !manual_track_locks.contains_key(&t.external_track_id));

                    let (default_ver_id, default_alb_id) = if has_unlocked_in_ver {
                        let target_alb = target_album_id_opt
                            .as_ref()
                            .expect("target_album_id exists when unlocked tracks present");
                        let pinned_group = LibraryRepository::version_manual_group_id_tx(
                            tx.conn(),
                            provider_id,
                            &pv.version.external_album_id,
                        )
                        .await
                        .map_err(db_err)?
                        .and_then(|(_, mg)| mg);
                        let ver_album_id = pinned_group.unwrap_or_else(|| target_alb.clone());
                        if ver_album_id == *target_alb {
                            unlocked_used_target = true;
                        }
                        let mut ver_to_save = pv.version.clone();
                        ver_to_save.canonical_album_id = ver_album_id.clone();

                        let authoritative_ver_id =
                            LibraryRepository::insert_album_version_tx(tx.conn(), &ver_to_save)
                                .await
                                .map_err(db_err)?;
                        touched_version_ids.insert(authoritative_ver_id.clone());
                        touched_album_ids.insert(ver_album_id.clone());
                        (Some(authoritative_ver_id), Some(ver_album_id))
                    } else {
                        (None, None)
                    };

                    for (track, norm_path) in &pv.tracks {
                        let Some(probed) = item_by_norm.get(norm_path) else {
                            continue;
                        };
                        let locked = manual_track_locks.get(&track.external_track_id);
                        let (track_ver_id, track_alb_id) = if let Some(lock) = locked {
                            touched_version_ids.insert(lock.version_id.clone());
                            touched_album_ids.insert(lock.album_id.clone());
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

                        // GarbledTags is a non-fatal quarantine warning; track is still imported.
                        sync_probed_track_skip_status_tx(
                            &mut tx,
                            provider_id,
                            norm_path,
                            probed,
                            active_skipped,
                            &mut cleared_skipped_in_tx,
                        )
                        .await;

                        let already_at_path = existing_cache.contains_key(norm_path);
                        let persisted_id = if !already_at_path {
                            let relinked = try_relink_moved_track_tx(
                                &mut tx,
                                norm_path,
                                track_ver_id,
                                &trk,
                                probed,
                                &relink_candidates,
                                &mut used_relink_ids,
                            )
                            .await?;
                            if relinked.is_some() {
                                updated_delta += 1;
                            }
                            relinked
                        } else {
                            None
                        };

                        let final_track_id = if let Some(pid) = persisted_id {
                            pid
                        } else {
                            let saved_id = LibraryRepository::upsert_track_source_with_cache_tx(
                                tx.conn(),
                                &trk,
                                probed.meta.embedded_lyrics.as_deref(),
                                Some(probed.file_mtime),
                                Some(probed.file_size),
                                Some(&probed.fingerprint.hash_hex),
                                Some(&probed.fingerprint.hash_hex),
                                Some(probed.fingerprint.audio_byte_len.min(i64::MAX as u64) as i64),
                            )
                            .await
                            .map_err(db_err)?;
                            if already_at_path {
                                updated_delta += 1;
                            } else {
                                added_delta += 1;
                            }
                            saved_id
                        };

                        let artists_list = if probed.meta.artists.is_empty() {
                            split_artists(&probed.meta.artist)
                        } else {
                            probed.meta.artists.clone()
                        };
                        let canonical_track_id = match IngestionRepository::upsert_canonical_track_for_source_tx(
                            tx.conn(),
                            &final_track_id,
                            track_alb_id,
                            &trk,
                            &artists_list,
                        )
                        .await
                        {
                            Ok((ct_id, _)) => Some(ct_id),
                            Err(e) => {
                                warn!(
                                    "Failed to upsert canonical track for source '{final_track_id}' ({norm_path}): {e}"
                                );
                                None
                            }
                        };

                        finalize_probed_track_layers_tx(
                            &mut tx,
                            provider_id,
                            &final_track_id,
                            track_alb_id,
                            canonical_track_id.as_deref(),
                            &file_layer_trk,
                            probed.meta.release_year,
                            probed.meta.embedded_lyrics.as_deref(),
                            &artists_list,
                            &probed.path,
                            probed.meta.record_label.as_deref(),
                        )
                        .await?;
                        if provider_id.eq_ignore_ascii_case("local") {
                            record_version_asset_source(
                                &mut version_assets_batch,
                                track_ver_id,
                                &final_track_id,
                                &probed.path,
                            );
                        }
                    }
                }

                // Write album `file_meta_json` AFTER tracks are present so `recompute_album_effective_tx`
                // preserves `cloud_meta_json` / `user_edits_json` and syncs effective album & artist FTS.
                if unlocked_used_target
                    && let Some(ref target_album_id) = target_album_id_opt
                {
                    let album_file_layer = build_album_file_layer(
                        album,
                        effective_album_title,
                        artist_name,
                        res.upc.as_deref(),
                        res.mb_rg_id.as_deref(),
                    );
                    let _ = persist_album_file_layer_tx(
                        &mut tx,
                        target_album_id,
                        provider_id,
                        is_new_album,
                        &album_file_layer,
                    )
                    .await?;
                }
            }

            recompute_version_tocs_tx(&mut tx, &touched_version_ids).await?;
            resolve_primaries_for_albums_tx(&mut tx, &touched_album_ids).await;

            // Ensure base artists are synced in FTS5; album & track FTS entries are already
            // synced by `recompute_album_effective_tx` / `recompute_track_effective_tx` with
            // resolved 3-layer metadata.
            let mut seen_art = HashSet::new();
            for (aid, name, bio) in &fts_artists {
                if seen_art.insert(aid.as_str()) {
                    sync_artist_fts_conn(tx.conn(), aid, name, bio.as_deref())
                        .await
                        .map_err(db_err)?;
                }
            }

            Ok(())
        }
        .await;

        match batch_res {
            Ok(()) => {
                tx.commit().await.map_err(db_err)?;
                drop(_write_guard);
                if !version_assets_batch.is_empty() {
                    index_assets_for_committed_versions(&self.pool, version_assets_batch).await;
                }
                progress.added += added_delta;
                progress.updated += updated_delta;
                for p in cleared_skipped_in_tx {
                    active_skipped.remove(&p);
                }
                tokio::task::yield_now().await;
                Ok(touched_album_ids)
            }
            Err(e) => {
                let _ = tx.rollback().await;
                Err(e)
            }
        }
    }
}
