mod models;
mod phases;
mod runner;
#[cfg(test)]
mod tests;
mod verify;

pub use models::{EnrichedAlbumResult, EnrichmentConfig, EnrichmentReport};
pub use verify::{MIN_MB_SEARCH_SCORE, is_unmatchable_local_album};

use std::collections::{HashMap, HashSet};

use core_db::{LibraryRepository, SqlitePool, rebuild_search_index};
use tracing::warn;

use super::discogs::DiscogsClient;
use super::musicbrainz::MusicBrainzClient;
use crate::error::ProviderError;
use crate::library::db_err;

pub struct CreditEnrichmentService {
    pub(super) musicbrainz: Option<MusicBrainzClient>,
    pub(super) discogs: Option<DiscogsClient>,
    pub(super) config: EnrichmentConfig,
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

    pub async fn enrich_library(
        &self,
        pool: &SqlitePool,
    ) -> Result<EnrichmentReport, ProviderError> {
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
