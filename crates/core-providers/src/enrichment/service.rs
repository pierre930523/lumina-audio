use std::collections::{HashMap, HashSet};

use core_db::{rebuild_search_index, LibraryRepository, SqlitePool};
use serde::{Deserialize, Serialize};
use tracing::warn;

use super::discogs::{clean_discogs_artist_name, extract_discogs_credits, DiscogsClient};
use super::musicbrainz::{extract_mb_credits, MusicBrainzClient};
use crate::error::ProviderError;
use crate::library::db_err;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnrichmentConfig {
    pub force_refresh: bool,
    pub fetch_artist_bios: bool,
    pub merge_on_mbid_match: bool,
    pub rebuild_search_index: bool,
    pub max_albums_per_run: usize,
}

impl Default for EnrichmentConfig {
    fn default() -> Self {
        Self {
            force_refresh: false,
            fetch_artist_bios: true,
            merge_on_mbid_match: true,
            rebuild_search_index: true,
            max_albums_per_run: 100,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnrichedAlbumResult {
    pub album_id: String,
    pub skipped: bool,
    pub merged_into_album_id: Option<String>,
    pub mb_release_group_id: Option<String>,
    pub credits_added: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnrichmentReport {
    pub albums_processed: usize,
    pub albums_enriched: usize,
    pub albums_skipped: usize,
    pub albums_merged: usize,
    pub credits_added: usize,
    pub errors: Vec<String>,
}

struct CreditRowCandidate {
    artist_name: String,
    mbid: Option<String>,
    bio: Option<String>,
    image_url: Option<String>,
    role: String,
}

pub struct CreditEnrichmentService {
    musicbrainz: Option<MusicBrainzClient>,
    discogs: Option<DiscogsClient>,
    config: EnrichmentConfig,
}

impl CreditEnrichmentService {
    pub fn new(
        musicbrainz: Option<MusicBrainzClient>,
        discogs: Option<DiscogsClient>,
        config: EnrichmentConfig,
    ) -> Self {
        Self {
            musicbrainz,
            discogs,
            config,
        }
    }

    pub async fn enrich_album(
        &self,
        pool: &SqlitePool,
        album_id: &str,
    ) -> Result<EnrichedAlbumResult, ProviderError> {
        let mut mb_artist_cache: HashMap<String, Option<String>> = HashMap::new();
        let mut dg_artist_cache: HashMap<u64, (Option<String>, Option<String>)> = HashMap::new();
        let (result, _) = self
            .enrich_album_internal(pool, album_id, &mut mb_artist_cache, &mut dg_artist_cache)
            .await?;
        Ok(result)
    }

    async fn enrich_album_internal(
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
        let artist_name = detail.album.artist_name.clone();
        let mut resolved_mb_rg_id = detail.album.musicbrainz_release_group_id.clone();
        let mut resolved_upc: Option<String> = None;
        let mut resolved_bio: Option<String> = None;
        let mut resolved_cover: Option<String> = None;
        let mut primary_artist_mbid: Option<String> = None;
        let mut credit_candidates: Vec<CreditRowCandidate> = Vec::new();
        let mut seen_credit_keys: HashSet<(String, String)> = HashSet::new();
        let mut upstream_errors: Vec<String> = Vec::new();
        let mut last_upstream_err: Option<ProviderError> = None;

        let mut record_upstream_err = |stage: &str, err: ProviderError| {
            if !matches!(
                err,
                ProviderError::AlbumNotFound(_) | ProviderError::TrackNotFound(_)
            ) {
                upstream_errors.push(format!("{stage}: {err}"));
                last_upstream_err = Some(err);
            }
        };

        let first_isrc = detail
            .versions
            .iter()
            .flat_map(|v| v.tracks.iter())
            .find_map(|t| t.isrc.as_ref().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()));

        // Phase 1: MusicBrainz lookup
        if let Some(ref mb) = self.musicbrainz {
            let mut chosen_release_id: Option<String> = None;

            if resolved_mb_rg_id.is_none() {
                if let Some(ref isrc) = first_isrc {
                    match mb.lookup_by_isrc(isrc).await {
                        Ok(isrc_res) => {
                            for rec in isrc_res.recordings {
                                if let Some(rel) = rec.releases.into_iter().next() {
                                    if let Some(ref rg) = rel.release_group {
                                        resolved_mb_rg_id = Some(rg.id.clone());
                                    }
                                    chosen_release_id = Some(rel.id);
                                    break;
                                }
                            }
                        }
                        Err(e) => record_upstream_err("MusicBrainz ISRC lookup", e),
                    }
                }
            }

            if resolved_mb_rg_id.is_none() && chosen_release_id.is_none() {
                match mb.search_release_groups(&title, &artist_name, 3).await {
                    Ok(groups) => {
                        if let Some(first) = groups.into_iter().next() {
                            resolved_mb_rg_id = Some(first.id);
                        }
                    }
                    Err(e) => record_upstream_err("MusicBrainz search", e),
                }
            }

            if chosen_release_id.is_none() {
                if let Some(ref rg_id) = resolved_mb_rg_id {
                    match mb.lookup_release_group(rg_id).await {
                        Ok(rg_detail) => {
                            if let Some(rel) = rg_detail.releases.into_iter().next() {
                                chosen_release_id = Some(rel.id);
                            }
                        }
                        Err(e) => record_upstream_err("MusicBrainz release-group lookup", e),
                    }
                }
            }

            if let Some(ref rel_id) = chosen_release_id {
                match mb.lookup_release_with_credits(rel_id).await {
                    Ok(rel_detail) => {
                        if resolved_mb_rg_id.is_none() {
                            if let Some(ref rg) = rel_detail.release_group {
                                resolved_mb_rg_id = Some(rg.id.clone());
                            }
                        }
                        if let Some(bc) =
                            rel_detail.barcode.as_deref().map(str::trim).filter(|s| !s.is_empty())
                        {
                            resolved_upc = Some(bc.to_string());
                        }
                        if let Some(ac) = rel_detail.artist_credit.first() {
                            if let Some(ref a) = ac.artist {
                                if !a.id.trim().is_empty() {
                                    primary_artist_mbid = Some(a.id.trim().to_string());
                                }
                            }
                        }

                        for cand in extract_mb_credits(&rel_detail) {
                            let key = (
                                cand.artist_name.to_ascii_lowercase(),
                                cand.role.to_ascii_lowercase(),
                            );
                            if seen_credit_keys.insert(key) {
                                let bio = if self.config.fetch_artist_bios {
                                    if let Some(ref mbid) = cand.artist_mbid {
                                        if let Some(cached) = mb_artist_cache.get(mbid) {
                                            cached.clone()
                                        } else {
                                            let fetched = mb
                                                .lookup_artist(mbid)
                                                .await
                                                .ok()
                                                .and_then(|ad| ad.disambiguation)
                                                .map(|s| s.trim().to_string())
                                                .filter(|s| !s.is_empty());
                                            mb_artist_cache.insert(mbid.clone(), fetched.clone());
                                            fetched
                                        }
                                    } else {
                                        None
                                    }
                                } else {
                                    None
                                };

                                credit_candidates.push(CreditRowCandidate {
                                    artist_name: cand.artist_name,
                                    mbid: cand.artist_mbid,
                                    bio,
                                    image_url: None,
                                    role: cand.role,
                                });
                            }
                        }
                    }
                    Err(e) => record_upstream_err("MusicBrainz release lookup", e),
                }
            }
        }

        // Phase 2: Discogs lookup
        if let Some(ref dg) = self.discogs {
            match dg
                .search_releases(&title, &artist_name, resolved_upc.as_deref(), 3)
                .await
            {
                Ok(results) => {
                    if let Some(first) = results.into_iter().next() {
                        match dg.get_release(first.id).await {
                            Ok(rel) => {
                                let extracted = extract_discogs_credits(&rel);
                                if resolved_upc.is_none() {
                                    resolved_upc = extracted.upc;
                                }
                                if resolved_bio.is_none() {
                                    resolved_bio = extracted.editorial_bio;
                                }
                                if resolved_cover.is_none() {
                                    resolved_cover = extracted.cover_url;
                                }

                                if (resolved_bio.is_none() || resolved_cover.is_none())
                                    && rel.master_id.or(first.master_id).is_some()
                                {
                                    let mid = rel.master_id.or(first.master_id).unwrap();
                                    match dg.get_master(mid).await {
                                        Ok(master) => {
                                            if resolved_bio.is_none() {
                                                resolved_bio = master
                                                    .notes
                                                    .as_deref()
                                                    .map(str::trim)
                                                    .filter(|s| !s.is_empty())
                                                    .map(str::to_string);
                                            }
                                            if resolved_cover.is_none() {
                                                resolved_cover = master
                                                    .images
                                                    .first()
                                                    .map(|i| i.uri.trim().to_string())
                                                    .filter(|s| !s.is_empty());
                                            }
                                        }
                                        Err(e) => record_upstream_err("Discogs master lookup", e),
                                    }
                                }

                                // Also fetch primary artist profile/image if available
                                if self.config.fetch_artist_bios {
                                    if let Some(first_art) = rel.artists.first() {
                                        if let Some(aid) = first_art.id {
                                            let (bio, img) =
                                                fetch_discogs_artist_cached(dg, aid, dg_artist_cache)
                                                    .await;
                                            if bio.is_some() || img.is_some() {
                                                let clean =
                                                    clean_discogs_artist_name(&first_art.name);
                                                if !clean.is_empty() {
                                                    let _ =
                                                        LibraryRepository::upsert_artist_by_mbid_or_name(
                                                            pool,
                                                            &clean,
                                                            primary_artist_mbid.as_deref(),
                                                            bio.as_deref(),
                                                            img.as_deref(),
                                                        )
                                                        .await;
                                                }
                                            }
                                        }
                                    }
                                }

                                for cand in extracted.credits {
                                    let key = (
                                        cand.artist_name.to_ascii_lowercase(),
                                        cand.role.to_ascii_lowercase(),
                                    );
                                    if seen_credit_keys.insert(key) {
                                        let (bio, img) = if self.config.fetch_artist_bios {
                                            if let Some(aid) = cand.discogs_artist_id {
                                                fetch_discogs_artist_cached(
                                                    dg,
                                                    aid,
                                                    dg_artist_cache,
                                                )
                                                .await
                                            } else {
                                                (None, None)
                                            }
                                        } else {
                                            (None, None)
                                        };

                                        credit_candidates.push(CreditRowCandidate {
                                            artist_name: cand.artist_name,
                                            mbid: None,
                                            bio,
                                            image_url: img,
                                            role: cand.role,
                                        });
                                    }
                                }
                            }
                            Err(e) => record_upstream_err("Discogs release lookup", e),
                        }
                    }
                }
                Err(e) => record_upstream_err("Discogs search", e),
            }
        }

        let yielded_new_data = (!had_mb_rg_initially && resolved_mb_rg_id.is_some())
            || resolved_upc.is_some()
            || resolved_bio.is_some()
            || resolved_cover.is_some()
            || primary_artist_mbid.is_some()
            || !credit_candidates.is_empty();

        if !upstream_errors.is_empty() && !yielded_new_data {
            return Err(last_upstream_err
                .unwrap_or_else(|| ProviderError::Network(upstream_errors.join("; "))));
        }

        // Update primary artist MBID if resolved
        if let Some(ref pa_mbid) = primary_artist_mbid {
            let _ = LibraryRepository::upsert_artist_by_mbid_or_name(
                pool,
                &artist_name,
                Some(pa_mbid),
                None,
                None,
            )
            .await;
        }

        // Unique-safe persistence of musicbrainz_release_group_id
        let mut target_album_id = album_id.to_string();
        let mut merged_into_album_id: Option<String> = None;
        let mut mb_rg_to_write = resolved_mb_rg_id.clone();

        if let Some(ref rg_id) = resolved_mb_rg_id {
            if let Some(other) = LibraryRepository::find_canonical_album_by_mb_release_group(pool, rg_id)
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

        let cover_to_write = if detail.album.cover_url.is_none() {
            resolved_cover.as_deref()
        } else {
            None
        };

        LibraryRepository::update_canonical_album_metadata(
            pool,
            &target_album_id,
            resolved_upc.as_deref(),
            mb_rg_to_write.as_deref(),
            resolved_bio.as_deref(),
            cover_to_write,
        )
        .await
        .map_err(db_err)?;

        let existing_credits = LibraryRepository::list_credits_for_album(pool, &target_album_id)
            .await
            .map_err(db_err)?;
        let mut existing_credit_set: HashSet<(String, String)> = existing_credits
            .into_iter()
            .map(|c| (c.artist_id, c.role.trim().to_string()))
            .collect();

        let mut credits_added = 0usize;
        for credit in credit_candidates {
            let artist = LibraryRepository::upsert_artist_by_mbid_or_name(
                pool,
                &credit.artist_name,
                credit.mbid.as_deref(),
                credit.bio.as_deref(),
                credit.image_url.as_deref(),
            )
            .await
            .map_err(db_err)?;

            let trimmed_role = credit.role.trim().to_string();
            LibraryRepository::upsert_album_credit(
                pool,
                &target_album_id,
                &artist.id,
                &trimmed_role,
            )
            .await
            .map_err(db_err)?;

            if existing_credit_set.insert((artist.id, trimmed_role)) {
                credits_added += 1;
            }
        }

        if upstream_errors.is_empty() {
            LibraryRepository::mark_album_enriched(pool, &target_album_id)
                .await
                .map_err(db_err)?;
        }

        Ok((
            EnrichedAlbumResult {
                album_id: target_album_id,
                skipped: false,
                merged_into_album_id,
                mb_release_group_id: resolved_mb_rg_id,
                credits_added,
            },
            upstream_errors,
        ))
    }

    pub async fn enrich_library(&self, pool: &SqlitePool) -> Result<EnrichmentReport, ProviderError> {
        let mut report = EnrichmentReport::default();
        let mut mb_artist_cache: HashMap<String, Option<String>> = HashMap::new();
        let mut dg_artist_cache: HashMap<u64, (Option<String>, Option<String>)> = HashMap::new();

        // Pre-collect album IDs before mutating rows so merges cannot shift OFFSET pagination boundaries.
        let mut target_albums: Vec<(String, String)> = Vec::new();
        let page_size = 100u32;
        let mut offset = 0u32;
        loop {
            let albums = LibraryRepository::list_canonical_albums(pool, page_size, offset)
                .await
                .map_err(db_err)?;
            if albums.is_empty() {
                break;
            }
            let fetched = albums.len();
            for alb in albums {
                target_albums.push((alb.id, alb.title));
            }
            if fetched < page_size as usize {
                break;
            }
            offset += page_size;
        }

        let mut processed = 0usize;
        let mut merged_away_ids: HashSet<String> = HashSet::new();

        for (album_id, album_title) in target_albums {
            if processed >= self.config.max_albums_per_run {
                break;
            }
            if merged_away_ids.contains(&album_id) {
                continue;
            }
            processed += 1;
            report.albums_processed += 1;

            match self
                .enrich_album_internal(pool, &album_id, &mut mb_artist_cache, &mut dg_artist_cache)
                .await
            {
                Ok((res, warnings)) => {
                    if res.skipped {
                        report.albums_skipped += 1;
                    } else {
                        report.albums_enriched += 1;
                    }
                    if res.merged_into_album_id.is_some() {
                        merged_away_ids.insert(album_id.clone());
                        report.albums_merged += 1;
                    }
                    report.credits_added += res.credits_added;
                    for w in warnings {
                        report.errors.push(format!("{album_id}: {w}"));
                    }
                }
                Err(e) => {
                    warn!("Enrichment failed for album '{album_title}' ({album_id}): {e}");
                    report.errors.push(format!("{album_id}: {e}"));
                }
            }
        }

        if self.config.rebuild_search_index && report.albums_enriched > 0 {
            let _ = rebuild_search_index(pool).await.map_err(db_err)?;
        }

        Ok(report)
    }
}

async fn fetch_discogs_artist_cached(
    dg: &DiscogsClient,
    artist_id: u64,
    cache: &mut HashMap<u64, (Option<String>, Option<String>)>,
) -> (Option<String>, Option<String>) {
    if let Some(cached) = cache.get(&artist_id) {
        return cached.clone();
    }
    let val = match dg.get_artist(artist_id).await {
        Ok(art) => {
            let bio = art
                .profile
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let img = art
                .images
                .first()
                .map(|i| i.uri.trim().to_string())
                .filter(|s| !s.is_empty());
            (bio, img)
        }
        Err(_) => (None, None),
    };
    cache.insert(artist_id, val.clone());
    val
}
