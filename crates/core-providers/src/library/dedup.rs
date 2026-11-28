use std::collections::{HashMap, HashSet};

use core_db::{
    CatalogQueryRepository, DbWriteCoordinator, ImmediateTx, LibraryRepository, SqlitePool,
    normalize_match_key, rebuild_search_index_conn,
};

use crate::error::ProviderError;
use crate::local::pipeline::{is_album_group_locked_cached, lookup_version_manual_group_pool};
use crate::local::{AlbumSyncMetadata, extract_edition_label};

use super::match_policy::{
    filter_isrc_candidate_albums, is_candidate_album_compatible, is_compilation_artist,
    isrc_sets_compatible, normalize_isrc,
};
use super::{AlbumEntry, ResolvedChunkAlbum, SyncPersistReport, db_err};

/// Resolves canonical album candidates and performs safe anti-pollution merges for a chunk.
///
/// MUST be called while holding `DbWriteCoordinator::write_lock()` so no concurrent writer can
/// interleave between candidate resolution and the following `ImmediateTx` commit.
pub(super) async fn resolve_chunk_candidates_under_write_lock<'a>(
    pool: &SqlitePool,
    chunk: &'a [AlbumEntry<'a>],
    album_meta: &HashMap<String, AlbumSyncMetadata>,
    report: &mut SyncPersistReport,
) -> Result<Vec<ResolvedChunkAlbum<'a>>, ProviderError> {
    let mut resolved_chunk: Vec<ResolvedChunkAlbum<'_>> = Vec::with_capacity(chunk.len());
    for entry in chunk {
        let album = entry.album;
        let artist_name = if album.artist_name.trim().is_empty() {
            "Unknown Artist"
        } else {
            album.artist_name.trim()
        };
        let is_compilation = is_compilation_artist(artist_name, album.album_artist.as_deref());

        let mut album_isrcs: Vec<String> = Vec::new();
        let mut isrc_set: HashSet<String> = HashSet::new();
        let mut max_version_tracks = 0usize;
        for (_, ver_tracks) in &entry.versions {
            max_version_tracks = max_version_tracks.max(ver_tracks.len());
            for (_, t) in ver_tracks {
                if let Some(ref isrc) = t.isrc {
                    if let Some(clean) = normalize_isrc(isrc) {
                        if isrc_set.insert(clean.clone()) {
                            album_isrcs.push(clean);
                        }
                    }
                }
            }
        }

        let upc = album_meta
            .get(&album.id)
            .and_then(|m| m.upc.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let mb_rg_id = album
            .musicbrainz_release_group_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);

        let (base_title, _) = extract_edition_label(&album.title);
        let norm_title = normalize_match_key(&base_title);
        let norm_artist = normalize_match_key(artist_name);
        let is_unknown = norm_title.is_empty()
            || norm_artist.is_empty()
            || norm_title == "unknown album"
            || norm_artist == "unknown artist";

        let mut candidate_ids: Vec<String> = Vec::new();
        let mut seen_candidates: HashSet<String> = HashSet::new();
        let mut comp_cache: HashMap<String, bool> = HashMap::new();
        let mut lock_cache: HashMap<String, bool> = HashMap::new();
        let mut locked_version_groups: Vec<String> = Vec::new();
        let mut has_unlocked_version = false;

        // Match existing album_versions(provider_id, external_album_id) FIRST so user edits,
        // cloud policy renames, or manual group locks survive rescans in place.
        for (ver, _) in &entry.versions {
            if let Some((_, Some(manual_gid))) = lookup_version_manual_group_pool(
                pool,
                ver.provider.as_str(),
                &ver.external_album_id,
            )
            .await?
            {
                lock_cache.insert(manual_gid.clone(), true);
                if !locked_version_groups.contains(&manual_gid) {
                    locked_version_groups.push(manual_gid);
                }
                continue;
            }
            has_unlocked_version = true;
            if let Some((_, existing_album_id)) =
                CatalogQueryRepository::find_album_version_by_external_id(
                    pool,
                    ver.provider.as_str(),
                    &ver.external_album_id,
                )
                .await
                .map_err(db_err)?
                && seen_candidates.insert(existing_album_id.clone())
            {
                candidate_ids.push(existing_album_id);
            }
        }

        if !has_unlocked_version && !locked_version_groups.is_empty() {
            resolved_chunk.push(ResolvedChunkAlbum {
                entry,
                primary_id: locked_version_groups.into_iter().next(),
                is_group_locked: true,
                upc,
                mb_rg_id,
                base_title,
                is_unknown,
                is_compilation,
                isrcs: isrc_set,
                max_version_tracks,
            });
            continue;
        }

        if let Some(ref rg) = mb_rg_id
            && let Some(found) =
                LibraryRepository::find_canonical_album_by_mb_release_group(pool, rg)
                    .await
                    .map_err(db_err)?
            && !is_album_group_locked_cached(pool, &found.id, &mut lock_cache).await?
        {
            let cand_comp =
                is_compilation_artist(&found.artist_name, found.album_artist.as_deref());
            comp_cache.insert(found.id.clone(), cand_comp);
            if cand_comp == is_compilation && seen_candidates.insert(found.id.clone()) {
                candidate_ids.push(found.id);
            }
        }
        if let Some(ref u) = upc
            && let Some(found) = LibraryRepository::find_canonical_album_by_upc(pool, u)
                .await
                .map_err(db_err)?
            && !is_album_group_locked_cached(pool, &found.id, &mut lock_cache).await?
        {
            let cand_comp =
                is_compilation_artist(&found.artist_name, found.album_artist.as_deref());
            comp_cache.insert(found.id.clone(), cand_comp);
            if cand_comp == is_compilation && seen_candidates.insert(found.id.clone()) {
                candidate_ids.push(found.id);
            }
        }
        if !album_isrcs.is_empty() {
            let raw_ids = LibraryRepository::find_canonical_album_ids_by_isrcs(pool, &album_isrcs)
                .await
                .map_err(db_err)?;
            let verified_ids = filter_isrc_candidate_albums(
                pool,
                raw_ids,
                &isrc_set,
                max_version_tracks,
                is_compilation,
            )
            .await?;
            for id in verified_ids {
                if !is_album_group_locked_cached(pool, &id, &mut lock_cache).await?
                    && seen_candidates.insert(id.clone())
                {
                    candidate_ids.push(id);
                }
            }
        }
        if !is_unknown {
            let titles: Vec<&str> = if base_title != album.title {
                vec![&album.title, &base_title]
            } else {
                vec![&album.title]
            };
            for title_cand in titles {
                for found in LibraryRepository::find_canonical_albums_by_normalized_key(
                    pool,
                    title_cand,
                    artist_name,
                )
                .await
                .map_err(db_err)?
                {
                    if is_album_group_locked_cached(pool, &found.id, &mut lock_cache).await? {
                        continue;
                    }
                    let cand_comp =
                        is_compilation_artist(&found.artist_name, found.album_artist.as_deref());
                    comp_cache.insert(found.id.clone(), cand_comp);
                    if cand_comp == is_compilation && seen_candidates.insert(found.id.clone()) {
                        candidate_ids.push(found.id);
                    }
                }
            }
        }

        let primary_id = candidate_ids.first().cloned();
        let primary_locked = match primary_id.as_deref() {
            Some(pid) => is_album_group_locked_cached(pool, pid, &mut lock_cache).await?,
            None => false,
        };
        if let Some(ref pid) = primary_id
            && !primary_locked
        {
            for secondary_id in candidate_ids.iter().skip(1) {
                if is_album_group_locked_cached(pool, secondary_id, &mut lock_cache).await? {
                    continue;
                }
                if is_candidate_album_compatible(
                    pool,
                    secondary_id,
                    is_compilation,
                    &mut comp_cache,
                )
                .await?
                    && LibraryRepository::merge_canonical_albums(pool, pid, secondary_id)
                        .await
                        .map_err(db_err)?
                {
                    report.albums_merged += 1;
                }
            }
        }

        resolved_chunk.push(ResolvedChunkAlbum {
            entry,
            primary_id,
            is_group_locked: primary_locked,
            upc,
            mb_rg_id,
            base_title,
            is_unknown,
            is_compilation,
            isrcs: isrc_set,
            max_version_tracks,
        });
    }
    Ok(resolved_chunk)
}

pub(super) async fn deduplicate_library(pool: &SqlitePool) -> Result<usize, ProviderError> {
    let write_coord = DbWriteCoordinator::for_pool(pool);
    let _write_guard = write_coord.write_lock().await;

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

    let upc_rows = CatalogQueryRepository::list_album_upcs(pool)
        .await
        .map_err(db_err)?;
    let mut upc_by_album_id: HashMap<String, String> = HashMap::with_capacity(upc_rows.len());
    for (alb_id, upc) in upc_rows {
        let clean = upc.trim().to_string();
        if !clean.is_empty() {
            upc_by_album_id.insert(alb_id, clean);
        }
    }

    let is_comp: Vec<bool> = all_albums
        .iter()
        .map(|a| is_compilation_artist(&a.artist_name, a.album_artist.as_deref()))
        .collect();

    let mut by_mb: HashMap<(String, bool), usize> = HashMap::new();
    let mut by_upc: HashMap<(String, bool), usize> = HashMap::new();
    let mut by_norm: HashMap<(String, String, bool), usize> = HashMap::new();

    // Track per-album version ISRC sets & track counts for >= 60% overlap verification.
    let locked_album_ids = LibraryRepository::list_manually_locked_album_ids(pool)
        .await
        .map_err(db_err)?;
    let mut album_version_isrcs: Vec<Vec<(HashSet<String>, usize)>> = vec![Vec::new(); n];
    let mut isrc_to_albums: HashMap<String, Vec<usize>> = HashMap::new();

    for (i, alb) in all_albums.iter().enumerate() {
        // Respect Step 2 manual group/ungroup/split locks: never auto-merge locked groups.
        if locked_album_ids.contains(&alb.id) {
            continue;
        }
        let comp = is_comp[i];
        if let Some(ref mb) = alb.musicbrainz_release_group_id {
            let key = mb.trim().to_ascii_lowercase();
            if !key.is_empty() {
                if let Some(&prev) = by_mb.get(&(key.clone(), comp)) {
                    union(&mut parent, prev, i);
                } else {
                    by_mb.insert((key, comp), i);
                }
            }
        }

        if let Some(upc) = upc_by_album_id.get(&alb.id) {
            if let Some(&prev) = by_upc.get(&(upc.clone(), comp)) {
                union(&mut parent, prev, i);
            } else {
                by_upc.insert((upc.clone(), comp), i);
            }
        }

        let (base_title, _) = extract_edition_label(&alb.title);
        let nt = normalize_match_key(&base_title);
        let na = normalize_match_key(&alb.artist_name);
        let is_unknown =
            nt.is_empty() || na.is_empty() || nt == "unknown album" || na == "unknown artist";
        if !is_unknown {
            if let Some(&prev) = by_norm.get(&(nt.clone(), na.clone(), comp)) {
                union(&mut parent, prev, i);
            } else {
                by_norm.insert((nt, na, comp), i);
            }
        }

        for ver in &alb.versions {
            let tracks = LibraryRepository::find_track_sources_by_version(pool, &ver.id)
                .await
                .map_err(db_err)?;
            if tracks.is_empty() {
                continue;
            }
            let mut ver_isrcs: HashSet<String> = HashSet::new();
            for trk in &tracks {
                if let Some(ref isrc) = trk.isrc {
                    if let Some(clean) = normalize_isrc(isrc) {
                        isrc_to_albums.entry(clean.clone()).or_default().push(i);
                        ver_isrcs.insert(clean);
                    }
                }
            }
            if !ver_isrcs.is_empty() {
                album_version_isrcs[i].push((ver_isrcs, tracks.len()));
            }
        }
    }

    // Verified ISRC overlap merge: >= 60% overlap + compatible track count + compilation guard.
    let mut checked_pairs: HashSet<(usize, usize)> = HashSet::new();
    for indices in isrc_to_albums.values() {
        if indices.len() < 2 {
            continue;
        }
        let mut uniq: Vec<usize> = indices.clone();
        uniq.sort_unstable();
        uniq.dedup();
        for a_pos in 0..uniq.len() {
            for b_pos in (a_pos + 1)..uniq.len() {
                let a = uniq[a_pos];
                let b = uniq[b_pos];
                if !checked_pairs.insert((a, b)) || is_comp[a] != is_comp[b] {
                    continue;
                }
                let compatible = album_version_isrcs[a].iter().any(|(isrcs_a, trks_a)| {
                    album_version_isrcs[b].iter().any(|(isrcs_b, trks_b)| {
                        isrc_sets_compatible(
                            isrcs_a, *trks_a, is_comp[a], isrcs_b, *trks_b, is_comp[b],
                        )
                    })
                });
                if compatible {
                    union(&mut parent, a, b);
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
        let mut tx = ImmediateTx::begin(pool).await.map_err(db_err)?;
        let tx_res: Result<(), ProviderError> = async {
            let _ = LibraryRepository::prune_orphan_albums_and_versions_tx(tx.conn(), None)
                .await
                .map_err(db_err)?;
            let _ = rebuild_search_index_conn(tx.conn()).await.map_err(db_err)?;
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

    Ok(merged_count)
}
