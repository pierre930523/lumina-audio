use std::collections::{HashMap, HashSet};

use core_db::{
    CatalogQueryRepository, ImmediateTx, IngestionRepository, LibraryRepository, RelinkCandidate,
    SqlitePool, TrackFileCacheInfo, normalize_match_key,
};
use core_types::{CanonicalAlbum, TrackSource};

use super::IngestionPipeline;
use super::commit_locks::{is_album_group_locked_cached, lookup_version_manual_group_pool};
use super::probe::ProbedTrackItem;
use crate::error::ProviderError;
use crate::library::db_err;
use crate::library::match_policy::{
    filter_isrc_candidate_albums, is_candidate_album_compatible, is_compilation_artist,
    normalize_isrc,
};
use crate::local::mapper::{AlbumSyncMetadata, extract_edition_label};

pub(super) struct ResolvedCanonicalAlbum {
    pub(super) primary_id: Option<String>,
    pub(super) is_group_locked: bool,
    pub(super) upc: Option<String>,
    pub(super) mb_rg_id: Option<String>,
    pub(super) base_title: String,
    pub(super) is_unknown: bool,
    pub(super) is_compilation: bool,
    pub(super) isrcs: HashSet<String>,
    pub(super) track_count: usize,
}

impl IngestionPipeline {
    /// Resolves canonical album candidates and performs safe anti-pollution merges.
    ///
    /// MUST be called while holding `self.write_coord.write_lock()` so no concurrent writer can
    /// interleave between candidate resolution and the immediately following `ImmediateTx` commit.
    pub(super) async fn resolve_canonical_album_under_write_lock(
        &self,
        album: &CanonicalAlbum,
        tracks_by_version: &HashMap<&str, Vec<&TrackSource>>,
        album_meta: &HashMap<String, AlbumSyncMetadata>,
    ) -> Result<ResolvedCanonicalAlbum, ProviderError> {
        let artist_name = if album.artist_name.trim().is_empty() {
            "Unknown Artist"
        } else {
            album.artist_name.trim()
        };
        let is_compilation = is_compilation_artist(artist_name, album.album_artist.as_deref());

        let mut album_isrcs: Vec<String> = Vec::new();
        let mut isrc_set: HashSet<String> = HashSet::new();
        let mut max_ver_tracks = 0usize;
        for ver in &album.versions {
            if let Some(ver_tracks) = tracks_by_version.get(ver.id.as_str()) {
                max_ver_tracks = max_ver_tracks.max(ver_tracks.len());
                for t in ver_tracks {
                    if let Some(ref isrc) = t.isrc {
                        if let Some(clean) = normalize_isrc(isrc) {
                            if isrc_set.insert(clean.clone()) {
                                album_isrcs.push(clean);
                            }
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
        for ver in &album.versions {
            if let Some((_, Some(manual_gid))) = lookup_version_manual_group_pool(
                &self.pool,
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
                    &self.pool,
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

        // If every version in this mapped album is pinned to a manual group, skip auto-matching/merging.
        if !has_unlocked_version && !locked_version_groups.is_empty() {
            return Ok(ResolvedCanonicalAlbum {
                primary_id: locked_version_groups.into_iter().next(),
                is_group_locked: true,
                upc,
                mb_rg_id,
                base_title,
                is_unknown,
                is_compilation,
                isrcs: isrc_set,
                track_count: max_ver_tracks,
            });
        }

        if let Some(ref rg) = mb_rg_id
            && let Some(found) =
                LibraryRepository::find_canonical_album_by_mb_release_group(&self.pool, rg)
                    .await
                    .map_err(db_err)?
            && !is_album_group_locked_cached(&self.pool, &found.id, &mut lock_cache).await?
        {
            let cand_comp =
                is_compilation_artist(&found.artist_name, found.album_artist.as_deref());
            comp_cache.insert(found.id.clone(), cand_comp);
            if cand_comp == is_compilation && seen_candidates.insert(found.id.clone()) {
                candidate_ids.push(found.id);
            }
        }
        if let Some(ref u) = upc
            && let Some(found) = LibraryRepository::find_canonical_album_by_upc(&self.pool, u)
                .await
                .map_err(db_err)?
            && !is_album_group_locked_cached(&self.pool, &found.id, &mut lock_cache).await?
        {
            let cand_comp =
                is_compilation_artist(&found.artist_name, found.album_artist.as_deref());
            comp_cache.insert(found.id.clone(), cand_comp);
            if cand_comp == is_compilation && seen_candidates.insert(found.id.clone()) {
                candidate_ids.push(found.id);
            }
        }
        if !album_isrcs.is_empty() {
            let raw_ids =
                LibraryRepository::find_canonical_album_ids_by_isrcs(&self.pool, &album_isrcs)
                    .await
                    .map_err(db_err)?;
            let verified_ids = filter_isrc_candidate_albums(
                &self.pool,
                raw_ids,
                &isrc_set,
                max_ver_tracks,
                is_compilation,
            )
            .await?;
            for id in verified_ids {
                if !is_album_group_locked_cached(&self.pool, &id, &mut lock_cache).await?
                    && seen_candidates.insert(id.clone())
                {
                    candidate_ids.push(id);
                }
            }
        }
        if !is_unknown {
            for found in LibraryRepository::find_canonical_albums_by_normalized_key(
                &self.pool,
                &base_title,
                artist_name,
            )
            .await
            .map_err(db_err)?
            {
                if is_album_group_locked_cached(&self.pool, &found.id, &mut lock_cache).await? {
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

        let primary_id = candidate_ids.first().cloned();
        let primary_locked = match primary_id.as_deref() {
            Some(pid) => is_album_group_locked_cached(&self.pool, pid, &mut lock_cache).await?,
            None => false,
        };
        if let Some(ref primary) = primary_id
            && !primary_locked
        {
            for secondary_id in candidate_ids.iter().skip(1) {
                if is_album_group_locked_cached(&self.pool, secondary_id, &mut lock_cache).await? {
                    continue;
                }
                if is_candidate_album_compatible(
                    &self.pool,
                    secondary_id,
                    is_compilation,
                    &mut comp_cache,
                )
                .await?
                {
                    let _ = LibraryRepository::merge_canonical_albums(
                        &self.pool,
                        primary,
                        secondary_id,
                    )
                    .await
                    .map_err(db_err)?;
                }
            }
        }

        Ok(ResolvedCanonicalAlbum {
            primary_id,
            is_group_locked: primary_locked,
            upc,
            mb_rg_id,
            base_title,
            is_unknown,
            is_compilation,
            isrcs: isrc_set,
            track_count: max_ver_tracks,
        })
    }
}

pub(super) async fn lookup_relink_candidate(
    pool: &SqlitePool,
    provider_id: &str,
    norm_path: &str,
    existing_cache: &HashMap<String, TrackFileCacheInfo>,
    item_by_norm: &HashMap<String, ProbedTrackItem>,
    relink_candidates: &mut HashMap<String, RelinkCandidate>,
) {
    if existing_cache.contains_key(norm_path) {
        return;
    }
    let Some(probed) = item_by_norm.get(norm_path) else {
        return;
    };
    if let Ok(Some(cand)) = IngestionRepository::find_relink_candidate_by_fingerprint(
        pool,
        provider_id,
        &probed.fingerprint.hash_hex,
        probed.fingerprint.audio_byte_len,
        norm_path,
    )
    .await
    {
        relink_candidates.insert(norm_path.to_string(), cand);
    }
}

pub(super) async fn try_relink_moved_track_tx(
    tx: &mut ImmediateTx,
    norm_path: &str,
    authoritative_ver_id: &str,
    trk: &TrackSource,
    probed: &ProbedTrackItem,
    relink_candidates: &HashMap<String, RelinkCandidate>,
    used_relink_ids: &mut HashSet<String>,
) -> Result<Option<String>, ProviderError> {
    let Some(cand) = relink_candidates.get(norm_path) else {
        return Ok(None);
    };
    if !used_relink_ids.insert(cand.track_source_id.clone()) {
        return Ok(None);
    }
    let relinked = IngestionRepository::relink_moved_track_source_tx(
        tx.conn(),
        &cand.track_source_id,
        norm_path,
        authoritative_ver_id,
        Some(probed.file_mtime),
        Some(probed.file_size),
    )
    .await
    .map_err(db_err)?;

    if !relinked {
        return Ok(None);
    }

    let _ = LibraryRepository::upsert_track_source_with_cache_tx(
        tx.conn(),
        trk,
        probed.meta.embedded_lyrics.as_deref(),
        Some(probed.file_mtime),
        Some(probed.file_size),
        Some(&probed.fingerprint.hash_hex),
        Some(&probed.fingerprint.hash_hex),
        Some(probed.fingerprint.audio_byte_len.min(i64::MAX as u64) as i64),
    )
    .await
    .map_err(db_err)?;

    Ok(Some(cand.track_source_id.clone()))
}
