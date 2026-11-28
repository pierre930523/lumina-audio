use std::collections::{HashMap, HashSet};

use core_db::{ImmediateTx, IngestionRepository, LibraryRepository, SqlitePool};
use core_types::{SkipReason, TocSignature};
use tracing::warn;

use super::probe::ProbedTrackItem;
use crate::error::ProviderError;
use crate::library::db_err;

/// Resolved live manual lock for an existing track: `(manual_version_id, canonical_album_id, manual_disc_number)`.
#[derive(Debug, Clone)]
pub(crate) struct LiveManualTrackLock {
    pub(crate) version_id: String,
    pub(crate) album_id: String,
    pub(crate) manual_disc_number: Option<u32>,
}

/// Batch-fetches manual track locks for `external_track_ids` and verifies each locked version
/// still exists in SQLite (returning its live `(version_id, canonical_album_id)`).
pub(crate) async fn load_live_manual_track_locks_tx(
    tx: &mut ImmediateTx,
    provider_id: &str,
    external_track_ids: &[String],
) -> Result<HashMap<String, LiveManualTrackLock>, ProviderError> {
    let raw = LibraryRepository::get_manual_track_locks_batch_tx(
        tx.conn(),
        provider_id,
        external_track_ids,
    )
    .await
    .map_err(db_err)?;

    let mut live = HashMap::with_capacity(raw.len());
    for (ext_id, (manual_ver_opt, manual_disc)) in raw {
        let Some(manual_ver_id) = manual_ver_opt else {
            continue;
        };
        if let Ok(Some((_, album_id))) = IngestionRepository::get_track_and_album_by_external_id_tx(
            tx.conn(),
            provider_id,
            &ext_id,
        )
        .await
        {
            live.insert(
                ext_id,
                LiveManualTrackLock {
                    version_id: manual_ver_id,
                    album_id,
                    manual_disc_number: manual_disc,
                },
            );
        }
    }
    Ok(live)
}

/// Returns `true` if `album_id` has a manual group lock, memoizing results in `cache`.
pub(crate) async fn is_album_group_locked_cached(
    pool: &SqlitePool,
    album_id: &str,
    cache: &mut HashMap<String, bool>,
) -> Result<bool, ProviderError> {
    if let Some(&locked) = cache.get(album_id) {
        return Ok(locked);
    }
    let locked = LibraryRepository::album_has_manual_group_lock(pool, album_id)
        .await
        .map_err(db_err)?;
    cache.insert(album_id.to_string(), locked);
    Ok(locked)
}

/// Looks up `manual_group_id` for an existing `(provider_id, external_album_id)` version.
pub(crate) async fn lookup_version_manual_group_pool(
    pool: &SqlitePool,
    provider_id: &str,
    external_album_id: &str,
) -> Result<Option<(String, Option<String>)>, ProviderError> {
    let mut conn = pool.acquire().await.map_err(db_err)?;
    LibraryRepository::version_manual_group_id_tx(&mut conn, provider_id, external_album_id)
        .await
        .map_err(db_err)
}

/// Recomputes version scores & primary versions for every album in `touched_album_ids`.
pub(crate) async fn resolve_primaries_for_albums_tx(
    tx: &mut ImmediateTx,
    touched_album_ids: &HashSet<String>,
) {
    let mut sorted: Vec<&String> = touched_album_ids.iter().collect();
    sorted.sort();
    for album_id in sorted {
        if let Err(e) = LibraryRepository::resolve_primary_version_tx(tx.conn(), album_id).await {
            warn!("Failed to resolve primary version for album '{album_id}': {e}");
        }
    }
}

/// Updates `skipped_files` quarantine status for a probed track (non-fatal `GarbledTags` warning
/// or clearing a previously skipped path on successful import).
pub(crate) async fn sync_probed_track_skip_status_tx(
    tx: &mut ImmediateTx,
    provider_id: &str,
    norm_path: &str,
    probed: &ProbedTrackItem,
    active_skipped: &HashSet<String>,
    cleared_skipped_in_tx: &mut Vec<String>,
) {
    if let Some(ref garbled) = probed.garbled_reason {
        if let Err(e) = IngestionRepository::record_skipped_file_tx(
            tx.conn(),
            provider_id,
            norm_path,
            SkipReason::GarbledTags,
            garbled,
            Some(probed.file_size.max(0) as u64),
            Some(probed.file_mtime),
        )
        .await
        {
            warn!("Failed to record GarbledTags warning for '{norm_path}': {e}");
        }
    } else if active_skipped.contains(norm_path) {
        if let Err(e) =
            IngestionRepository::clear_skipped_for_path_tx(tx.conn(), provider_id, norm_path).await
        {
            warn!("Failed to clear skipped record for '{norm_path}': {e}");
        } else {
            cleared_skipped_in_tx.push(norm_path.to_string());
        }
    }
}

/// Recomputes TOC signatures across all present tracks for each version in `touched_version_ids`.
pub(crate) async fn recompute_version_tocs_tx(
    tx: &mut ImmediateTx,
    touched_version_ids: &HashSet<String>,
) -> Result<(), ProviderError> {
    for ver_id in touched_version_ids {
        let rows =
            IngestionRepository::list_present_track_durations_for_version_tx(tx.conn(), ver_id)
                .await
                .map_err(db_err)?;

        if !rows.is_empty() {
            let max_disc = rows
                .iter()
                .map(|(d, _)| (*d).max(1) as u32)
                .max()
                .unwrap_or(1);
            let distinct_discs: HashSet<i64> = rows.iter().map(|(d, _)| *d).collect();
            let disc_count = max_disc.max(distinct_discs.len() as u32).max(1);
            let durations: Vec<u64> = rows.iter().map(|(_, dur)| (*dur).max(0) as u64).collect();
            let toc = TocSignature::from_durations(disc_count, durations);
            if let Err(e) = IngestionRepository::update_album_version_toc_tx(
                tx.conn(),
                ver_id,
                &toc.digest,
                disc_count,
                toc.track_count,
            )
            .await
            {
                warn!("Failed to update TOC signature for version '{ver_id}': {e}");
            }
        }
    }
    Ok(())
}
