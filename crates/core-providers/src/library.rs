use std::collections::{HashMap, HashSet};

use core_db::{normalize_match_key, rebuild_search_index, LibraryRepository, SqlitePool};
use core_types::{AlbumDetail, ArtistDetail, CanonicalAlbum, TrackSource};
use serde::{Deserialize, Serialize};

use crate::error::ProviderError;
use crate::local::{extract_edition_label, AlbumSyncMetadata};
use crate::traits::SyncResult;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncPersistReport {
    pub albums_inserted: usize,
    pub albums_matched: usize,
    pub albums_merged: usize,
    pub versions_upserted: usize,
    pub tracks_upserted: usize,
    pub search_index_entries: usize,
}

pub struct LibrarySyncService;

impl LibrarySyncService {
    pub async fn persist_sync_result(
        pool: &SqlitePool,
        result: &SyncResult,
    ) -> Result<SyncPersistReport, ProviderError> {
        Self::persist_sync_result_with_metadata(pool, result, &HashMap::new()).await
    }

    pub async fn persist_sync_result_with_metadata(
        pool: &SqlitePool,
        result: &SyncResult,
        album_meta: &HashMap<String, AlbumSyncMetadata>,
    ) -> Result<SyncPersistReport, ProviderError> {
        Self::persist_provider_albums(pool, &result.albums, &result.tracks, album_meta).await
    }

    pub async fn persist_provider_albums(
        pool: &SqlitePool,
        albums: &[CanonicalAlbum],
        tracks: &[TrackSource],
        album_meta: &HashMap<String, AlbumSyncMetadata>,
    ) -> Result<SyncPersistReport, ProviderError> {
        let mut report = SyncPersistReport::default();
        let mut tracks_by_version: HashMap<&str, Vec<(usize, &TrackSource)>> = HashMap::new();
        for (idx, trk) in tracks.iter().enumerate() {
            tracks_by_version
                .entry(trk.version_id.as_str())
                .or_default()
                .push((idx, trk));
        }

        let mut version_id_map: HashMap<String, String> = HashMap::new();
        let mut inserted_track_indices: HashSet<usize> = HashSet::new();

        for album in albums {
            let artist_name = if album.artist_name.trim().is_empty() {
                "Unknown Artist"
            } else {
                album.artist_name.trim()
            };

            let artist =
                LibraryRepository::upsert_artist_by_mbid_or_name(pool, artist_name, None, None, None)
                    .await
                    .map_err(db_err)?;

            let mut album_isrcs: Vec<String> = Vec::new();
            for ver in &album.versions {
                if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                    for (_, t) in ver_tracks {
                        if let Some(ref isrc) = t.isrc {
                            let clean = isrc.trim();
                            if !clean.is_empty() {
                                album_isrcs.push(clean.to_string());
                            }
                        }
                    }
                }
            }

            let upc = album_meta
                .get(&album.id)
                .and_then(|m| m.upc.as_deref())
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let mb_rg_id = album
                .musicbrainz_release_group_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());

            let (base_title, _) = extract_edition_label(&album.title);
            let norm_title = normalize_match_key(&base_title);
            let norm_artist = normalize_match_key(artist_name);
            let is_unknown = norm_title.is_empty()
                || norm_artist.is_empty()
                || norm_title == "unknown album"
                || norm_artist == "unknown artist";

            // Collect all existing candidate album IDs across MBID, UPC, ISRCs, and normalized title+artist
            let mut candidate_ids: Vec<String> = Vec::new();
            let mut seen_candidates: HashSet<String> = HashSet::new();

            if let Some(rg) = mb_rg_id {
                if let Some(found) = LibraryRepository::find_canonical_album_by_mb_release_group(pool, rg)
                    .await
                    .map_err(db_err)?
                {
                    if seen_candidates.insert(found.id.clone()) {
                        candidate_ids.push(found.id);
                    }
                }
            }
            if let Some(u) = upc {
                if let Some(found) = LibraryRepository::find_canonical_album_by_upc(pool, u)
                    .await
                    .map_err(db_err)?
                {
                    if seen_candidates.insert(found.id.clone()) {
                        candidate_ids.push(found.id);
                    }
                }
            }
            if !album_isrcs.is_empty() {
                let by_isrc = LibraryRepository::find_canonical_album_ids_by_isrcs(pool, &album_isrcs)
                    .await
                    .map_err(db_err)?;
                for id in by_isrc {
                    if seen_candidates.insert(id.clone()) {
                        candidate_ids.push(id);
                    }
                }
            }
            if !is_unknown {
                for found in LibraryRepository::find_canonical_albums_by_normalized_key(
                    pool,
                    &album.title,
                    artist_name,
                )
                .await
                .map_err(db_err)?
                {
                    if seen_candidates.insert(found.id.clone()) {
                        candidate_ids.push(found.id);
                    }
                }
                if base_title != album.title {
                    for found in LibraryRepository::find_canonical_albums_by_normalized_key(
                        pool,
                        &base_title,
                        artist_name,
                    )
                    .await
                    .map_err(db_err)?
                    {
                        if seen_candidates.insert(found.id.clone()) {
                            candidate_ids.push(found.id);
                        }
                    }
                }
            }

            let target_album_id = if let Some(primary_id) = candidate_ids.first().cloned() {
                for secondary_id in candidate_ids.iter().skip(1) {
                    if LibraryRepository::merge_canonical_albums(pool, &primary_id, secondary_id)
                        .await
                        .map_err(db_err)?
                    {
                        report.albums_merged += 1;
                    }
                }

                let existing = LibraryRepository::find_canonical_album_by_id(pool, &primary_id)
                    .await
                    .map_err(db_err)?;

                let mb_to_set = match (&existing, mb_rg_id) {
                    (Some(ex), Some(rg)) if ex.musicbrainz_release_group_id.is_none() => Some(rg),
                    _ => None,
                };
                let cover_to_set = match (&existing, album.cover_url.as_deref()) {
                    (Some(ex), Some(c)) if ex.cover_url.is_none() && !c.trim().is_empty() => {
                        Some(c)
                    }
                    _ => None,
                };

                if upc.is_some() || mb_to_set.is_some() || cover_to_set.is_some() {
                    LibraryRepository::update_canonical_album_metadata(
                        pool,
                        &primary_id,
                        upc,
                        mb_to_set,
                        None,
                        cover_to_set,
                    )
                    .await
                    .map_err(db_err)?;
                }

                report.albums_matched += 1;
                primary_id
            } else {
                let mut shell = album.clone();
                shell.versions = Vec::new();
                if !is_unknown && base_title != shell.title {
                    shell.title = base_title.clone();
                    shell.sort_title = CanonicalAlbum::derive_sort_title(&base_title);
                }

                LibraryRepository::insert_canonical_album(pool, &shell, Some(&artist.id))
                    .await
                    .map_err(db_err)?;

                if upc.is_some() {
                    LibraryRepository::update_canonical_album_metadata(
                        pool,
                        &shell.id,
                        upc,
                        None,
                        None,
                        None,
                    )
                    .await
                    .map_err(db_err)?;
                }

                report.albums_inserted += 1;
                shell.id
            };

            let existing_versions =
                LibraryRepository::list_versions_for_album(pool, &target_album_id)
                    .await
                    .map_err(db_err)?;

            for ver in &album.versions {
                let mut ver_to_save = ver.clone();
                ver_to_save.canonical_album_id = target_album_id.clone();

                if let Some(matched_ver) = existing_versions
                    .iter()
                    .find(|v| v.provider == ver.provider && v.external_album_id == ver.external_album_id)
                {
                    ver_to_save.id = matched_ver.id.clone();
                }

                LibraryRepository::insert_album_version(pool, &ver_to_save)
                    .await
                    .map_err(db_err)?;

                // Re-query to obtain the authoritative ID in case ON CONFLICT retained an existing row ID.
                let updated_versions =
                    LibraryRepository::list_versions_for_album(pool, &target_album_id)
                        .await
                        .map_err(db_err)?;
                let authoritative_id = updated_versions
                    .into_iter()
                    .find(|v| {
                        v.provider == ver.provider && v.external_album_id == ver.external_album_id
                    })
                    .map(|v| v.id)
                    .unwrap_or_else(|| ver_to_save.id.clone());

                version_id_map.insert(ver.id.clone(), authoritative_id.clone());
                report.versions_upserted += 1;

                // Persist this version's tracks immediately so subsequent albums in the same batch
                // discover overlapping ISRCs via `find_canonical_album_ids_by_isrcs`.
                if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                    for (idx, track) in ver_tracks {
                        let mut trk = (*track).clone();
                        trk.version_id = authoritative_id.clone();
                        LibraryRepository::insert_track_source(pool, &trk)
                            .await
                            .map_err(db_err)?;
                        inserted_track_indices.insert(*idx);
                        report.tracks_upserted += 1;
                    }
                }
            }
        }

        for (idx, track) in tracks.iter().enumerate() {
            if inserted_track_indices.contains(&idx) {
                continue;
            }
            let mut trk = track.clone();
            if let Some(authoritative_ver_id) = version_id_map.get(&track.version_id) {
                trk.version_id = authoritative_ver_id.clone();
            }
            LibraryRepository::insert_track_source(pool, &trk)
                .await
                .map_err(db_err)?;
            report.tracks_upserted += 1;
        }

        report.search_index_entries = rebuild_search_index(pool).await.map_err(db_err)?;
        Ok(report)
    }

    /// Deduplicates existing canonical albums in SQLite across MBID, ISRC, and normalized
    /// title+artist (including edition stripping), while protecting `"Unknown Album"` /
    /// `"Unknown Artist"` entries from false merges.
    pub async fn deduplicate_library(pool: &SqlitePool) -> Result<usize, ProviderError> {
        let mut all_albums = Vec::new();
        let page_size = 500u32;
        let mut offset = 0u32;
        loop {
            let page = LibraryRepository::list_canonical_albums(pool, page_size, offset)
                .await
                .map_err(db_err)?;
            let count = page.len();
            all_albums.extend(page);
            if count < page_size as usize {
                break;
            }
            offset += page_size;
        }

        if all_albums.len() < 2 {
            return Ok(0);
        }

        let n = all_albums.len();
        let mut parent: Vec<usize> = (0..n).collect();
        fn find(parent: &mut [usize], mut x: usize) -> usize {
            while parent[x] != x {
                parent[x] = parent[parent[x]];
                x = parent[x];
            }
            x
        }
        fn union(parent: &mut [usize], a: usize, b: usize) {
            let ra = find(parent, a);
            let rb = find(parent, b);
            if ra != rb {
                parent[rb] = ra;
            }
        }

        let upc_rows: Vec<(String, String)> = sqlx::query_as(
            "SELECT id, upc FROM canonical_albums WHERE upc IS NOT NULL AND TRIM(upc) != ''",
        )
        .fetch_all(pool)
        .await
        .map_err(db_err)?;
        let mut upc_by_album_id: HashMap<String, String> = HashMap::with_capacity(upc_rows.len());
        for (alb_id, upc) in upc_rows {
            let clean = upc.trim().to_string();
            if !clean.is_empty() {
                upc_by_album_id.insert(alb_id, clean);
            }
        }

        let mut by_mb: HashMap<String, usize> = HashMap::new();
        let mut by_upc: HashMap<String, usize> = HashMap::new();
        let mut by_norm: HashMap<(String, String), usize> = HashMap::new();
        let mut by_isrc: HashMap<String, usize> = HashMap::new();

        for (i, alb) in all_albums.iter().enumerate() {
            if let Some(ref mb) = alb.musicbrainz_release_group_id {
                let key = mb.trim().to_ascii_lowercase();
                if !key.is_empty() {
                    if let Some(&prev) = by_mb.get(&key) {
                        union(&mut parent, prev, i);
                    } else {
                        by_mb.insert(key, i);
                    }
                }
            }

            if let Some(upc) = upc_by_album_id.get(&alb.id) {
                if let Some(&prev) = by_upc.get(upc) {
                    union(&mut parent, prev, i);
                } else {
                    by_upc.insert(upc.clone(), i);
                }
            }

            let (base_title, _) = extract_edition_label(&alb.title);
            let nt = normalize_match_key(&base_title);
            let na = normalize_match_key(&alb.artist_name);
            let is_unknown = nt.is_empty()
                || na.is_empty()
                || nt == "unknown album"
                || na == "unknown artist";
            if !is_unknown {
                if let Some(&prev) = by_norm.get(&(nt.clone(), na.clone())) {
                    union(&mut parent, prev, i);
                } else {
                    by_norm.insert((nt, na), i);
                }
            }

            for ver in &alb.versions {
                let tracks = LibraryRepository::find_track_sources_by_version(pool, &ver.id)
                    .await
                    .map_err(db_err)?;
                for trk in tracks {
                    if let Some(ref isrc) = trk.isrc {
                        let clean = isrc.replace('-', "").trim().to_ascii_uppercase();
                        if !clean.is_empty() {
                            if let Some(&prev) = by_isrc.get(&clean) {
                                union(&mut parent, prev, i);
                            } else {
                                by_isrc.insert(clean, i);
                            }
                        }
                    }
                }
            }
        }

        let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
        for i in 0..n {
            groups.entry(find(&mut parent, i)).or_default().push(i);
        }

        let mut merged_count = 0usize;
        for (_, mut members) in groups {
            if members.len() < 2 {
                continue;
            }
            members.sort_by_key(|&idx| {
                let a = &all_albums[idx];
                let score = usize::from(a.musicbrainz_release_group_id.is_some()) * 4
                    + usize::from(upc_by_album_id.contains_key(&a.id)) * 2
                    + usize::from(a.cover_url.is_some()) * 2
                    + a.versions.len();
                (std::cmp::Reverse(score), idx)
            });

            let target_id = &all_albums[members[0]].id;
            for &src_idx in &members[1..] {
                let src_id = &all_albums[src_idx].id;
                if LibraryRepository::merge_canonical_albums(pool, target_id, src_id)
                    .await
                    .map_err(db_err)?
                {
                    merged_count += 1;
                }
            }
        }

        if merged_count > 0 {
            let _ = rebuild_search_index(pool).await.map_err(db_err)?;
        }

        Ok(merged_count)
    }

    pub async fn list_canonical_albums(
        pool: &SqlitePool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        LibraryRepository::list_canonical_albums(pool, limit, offset)
            .await
            .map_err(db_err)
    }

    pub async fn get_album_detail(
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<Option<AlbumDetail>, ProviderError> {
        LibraryRepository::get_album_detail(pool, album_id)
            .await
            .map_err(db_err)
    }

    pub async fn get_artist_detail(
        pool: &SqlitePool,
        artist_id: &str,
    ) -> Result<Option<ArtistDetail>, ProviderError> {
        LibraryRepository::get_artist_detail(pool, artist_id)
            .await
            .map_err(db_err)
    }

    pub async fn rescan_tags(
        pool: &SqlitePool,
        dir_or_null: Option<&str>,
        force: bool,
    ) -> Result<core_types::RescanReport, ProviderError> {
        use crate::local::{AlbumMapper, DirectoryScanner, MetadataExtractor, normalize_path};
        use std::fs;
        use std::path::{Path, PathBuf};

        let mut report = core_types::RescanReport::default();

        let roots: Vec<PathBuf> = if let Some(d) = dir_or_null {
            let p = PathBuf::from(d.trim());
            if p.exists() {
                vec![p]
            } else {
                Vec::new()
            }
        } else {
            let rows: Vec<(String,)> = sqlx::query_as(
                "SELECT DISTINCT external_track_id FROM track_sources WHERE provider_id = 'local'",
            )
            .fetch_all(pool)
            .await
            .map_err(db_err)?;

            let mut dirs = HashSet::new();
            for (p_str,) in rows {
                if let Some(parent) = Path::new(&p_str).parent() {
                    dirs.insert(parent.to_path_buf());
                }
            }
            dirs.into_iter().collect()
        };

        let mut scanner = DirectoryScanner::new(false);
        let mut audio_files = Vec::new();
        for r in &roots {
            audio_files.extend(scanner.scan_directory(r));
        }

        let mut seen = HashSet::new();
        audio_files.retain(|p| seen.insert(normalize_path(p)));

        let existing_paths: HashSet<String> = audio_files.iter().map(normalize_path).collect();

        // 1. Prune missing local tracks
        let prune_rep = LibraryRepository::prune_missing_local_tracks(pool, dir_or_null, &existing_paths)
            .await
            .map_err(db_err)?;
        report.pruned = prune_rep.tracks_pruned;

        // 2. Incremental or forced tag rescan
        let mut items_to_persist = Vec::new();

        for file_path in audio_files {
            report.scanned += 1;
            let norm_path = normalize_path(&file_path);

            let (cur_mtime, cur_size) = match fs::metadata(&file_path) {
                Ok(m) => {
                    let mt = m
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    let sz = m.len() as i64;
                    (mt, sz)
                }
                Err(e) => {
                    report.errors.push(format!("Failed to read metadata for {norm_path}: {e}"));
                    continue;
                }
            };

            let cached_info = LibraryRepository::get_track_file_cache_info(pool, "local", &norm_path)
                .await
                .map_err(db_err)?;

            let needs_update = force
                || cached_info.is_none()
                || cached_info.as_ref().and_then(|c| c.file_mtime) != Some(cur_mtime)
                || cached_info.as_ref().and_then(|c| c.file_size) != Some(cur_size);

            if !needs_update {
                report.unchanged_cached += 1;
                continue;
            }

            match MetadataExtractor::extract(&file_path) {
                Ok(meta) => {
                    items_to_persist.push((file_path, meta, cur_mtime, cur_size));
                }
                Err(e) => {
                    report.errors.push(format!("Failed to extract metadata for {norm_path}: {e}"));
                }
            }
        }

        if !items_to_persist.is_empty() {
            let to_map: Vec<(PathBuf, crate::local::ExtractedMetadata)> = items_to_persist
                .iter()
                .map(|(p, m, _, _)| (p.clone(), m.clone()))
                .collect();

            let (albums, tracks, album_meta) =
                AlbumMapper::map_scanned_items_with_metadata(to_map, core_types::ProviderKind::Local)?;

            let persist_rep = Self::persist_provider_albums(pool, &albums, &tracks, &album_meta).await?;
            report.updated = persist_rep.tracks_upserted;

            // Update mtime/size cache info in SQLite
            for (p, _, mt, sz) in items_to_persist {
                let norm = normalize_path(&p);
                if let Ok(Some(info)) = LibraryRepository::get_track_file_cache_info(pool, "local", &norm).await {
                    let _ = LibraryRepository::update_track_file_cache_info(pool, &info.track_id, Some(mt), Some(sz), None).await;
                }
            }
        }

        rebuild_search_index(pool).await.map_err(db_err)?;
        Ok(report)
    }
}

pub(crate) fn db_err(e: impl std::fmt::Display) -> ProviderError {
    ProviderError::Other(format!("Database error: {e}"))
}
