use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use core_db::IngestionRepository;
use core_types::{BatchRescanSkippedResult, ScanProgressEvent, SkipReason};

use super::IngestionPipeline;
use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::cleanup::{
    infer_volume_or_mount_root, is_root_accessible, normalize_path_for_compare, path_under_root,
};
use crate::local::scanner::{is_scannable_audio, normalize_path};

impl IngestionPipeline {
    /// Removes `skipped_files` entries under an online root whose physical files no longer exist.
    pub(super) async fn clear_deleted_skipped_under_root(
        &self,
        provider_id: &str,
        norm_root: &str,
    ) {
        let Ok(all_skipped) = IngestionRepository::list_skipped_files(&self.pool, true).await
        else {
            return;
        };
        let root_cmp = normalize_path_for_compare(norm_root);
        let candidates: Vec<(String, String)> = all_skipped
            .into_iter()
            .filter(|rec| {
                rec.provider_id.eq_ignore_ascii_case(provider_id)
                    && path_under_root(&normalize_path_for_compare(&rec.file_path), &root_cmp)
            })
            .map(|rec| (rec.id, rec.file_path))
            .collect();

        if candidates.is_empty() {
            return;
        }

        let missing_ids: Vec<String> = tokio::task::spawn_blocking(move || {
            candidates
                .into_iter()
                .filter(|(_, fp)| {
                    matches!(
                        fs::symlink_metadata(Path::new(fp)),
                        Err(e) if e.kind() == ErrorKind::NotFound
                    )
                })
                .map(|(id, _)| id)
                .collect()
        })
        .await
        .unwrap_or_default();

        if missing_ids.is_empty() {
            return;
        }

        if let Ok((_wg, mut tx)) = self.write_coord.begin_immediate(&self.pool).await {
            if IngestionRepository::delete_skipped_by_ids_tx(tx.conn(), &missing_ids)
                .await
                .is_ok()
            {
                let _ = tx.commit().await;
            } else {
                let _ = tx.rollback().await;
            }
        }
    }

    /// Batch-rescans all non-dismissed `skipped_files`:
    /// - Offline roots are skipped safely (counted in `still_skipped`, never deleted).
    /// - Files confirmed deleted on disk (`NotFound` on an online root) are deleted from `skipped_files`
    ///   (`removed_missing`).
    /// - Scannable audio files are force-reprobed; newly valid files are imported and cleared (`resolved`).
    /// - Files that remain unsupported or corrupt stay in `skipped_files` (`still_skipped`).
    pub async fn rescan_all_skipped_files(
        &self,
    ) -> Result<BatchRescanSkippedResult, ProviderError> {
        let _scan_guard = self.scan_lock.lock().await;
        let records = IngestionRepository::list_skipped_files(&self.pool, false)
            .await
            .map_err(db_err)?;

        let total = records.len();
        if total == 0 {
            return Ok(BatchRescanSkippedResult::default());
        }

        let watched = IngestionRepository::list_watched_roots(&self.pool)
            .await
            .unwrap_or_default();
        let watched_paths: Vec<String> = watched
            .into_iter()
            .filter(|r| r.provider_id.eq_ignore_ascii_case("local"))
            .map(|r| r.root_path)
            .collect();

        let records_for_fs = records.clone();
        let (missing_ids, offline_ids, readable_dir_ids, scannable_by_provider, non_scannable_ids) =
            tokio::task::spawn_blocking(move || {
                let mut root_evals: Vec<(String, bool)> = watched_paths
                    .into_iter()
                    .map(|raw| {
                        let norm = normalize_path_for_compare(&raw);
                        let ok = is_root_accessible(Path::new(&raw));
                        (norm, ok)
                    })
                    .collect();
                root_evals.sort_by_key(|a| std::cmp::Reverse(a.0.len()));

                let mut inferred_cache: HashMap<String, bool> = HashMap::new();
                let mut missing_ids = Vec::new();
                let mut offline_ids = Vec::new();
                let mut readable_dir_ids = Vec::new();
                let mut scannable_by_provider: HashMap<String, Vec<(String, PathBuf, String)>> =
                    HashMap::new();
                let mut non_scannable_ids = Vec::new();

                for rec in records_for_fs {
                    let norm_fp = normalize_path_for_compare(&rec.file_path);
                    let root_online = if let Some((_, ok)) = root_evals
                        .iter()
                        .find(|(r, _)| path_under_root(&norm_fp, r))
                    {
                        *ok
                    } else if let Some(inferred) = infer_volume_or_mount_root(&rec.file_path) {
                        let inf_norm = normalize_path_for_compare(&inferred);
                        *inferred_cache
                            .entry(inf_norm)
                            .or_insert_with(|| is_root_accessible(Path::new(&inferred)))
                    } else {
                        true
                    };

                    if !root_online {
                        offline_ids.push(rec.id);
                        continue;
                    }

                    let path = PathBuf::from(&rec.file_path);
                    match fs::symlink_metadata(&path) {
                        Err(e) if e.kind() == ErrorKind::NotFound => {
                            missing_ids.push(rec.id);
                        }
                        Err(_) => {
                            non_scannable_ids.push((rec.id, rec.provider_id, rec.file_path));
                        }
                        Ok(meta) => {
                            if meta.is_dir() {
                                if fs::read_dir(&path).is_ok() {
                                    readable_dir_ids.push((rec.id, rec.provider_id, path));
                                } else {
                                    non_scannable_ids.push((
                                        rec.id,
                                        rec.provider_id,
                                        rec.file_path,
                                    ));
                                }
                            } else if is_scannable_audio(&path) {
                                scannable_by_provider
                                    .entry(rec.provider_id)
                                    .or_default()
                                    .push((rec.id, path, normalize_path(&rec.file_path)));
                            } else {
                                non_scannable_ids.push((rec.id, rec.provider_id, rec.file_path));
                            }
                        }
                    }
                }

                (
                    missing_ids,
                    offline_ids,
                    readable_dir_ids,
                    scannable_by_provider,
                    non_scannable_ids,
                )
            })
            .await
            .map_err(|e| {
                ProviderError::ScanError(format!("Batch skipped-file classification panicked: {e}"))
            })?;

        let mut removed_missing = 0usize;
        if !missing_ids.is_empty() {
            let (_wg, mut tx) = self
                .write_coord
                .begin_immediate(&self.pool)
                .await
                .map_err(db_err)?;
            match IngestionRepository::delete_skipped_by_ids_tx(tx.conn(), &missing_ids)
                .await
                .map_err(db_err)
            {
                Ok(n) => {
                    tx.commit().await.map_err(db_err)?;
                    removed_missing = n;
                }
                Err(e) => {
                    let _ = tx.rollback().await;
                    return Err(e);
                }
            }
        }

        let mut resolved = 0usize;
        let mut still_skipped = offline_ids.len() + non_scannable_ids.len();

        // Clear directories that became readable again.
        if !readable_dir_ids.is_empty() {
            let ids: Vec<String> = readable_dir_ids
                .iter()
                .map(|(id, _, _)| id.clone())
                .collect();
            let (_wg, mut tx) = self
                .write_coord
                .begin_immediate(&self.pool)
                .await
                .map_err(db_err)?;
            if let Ok(n) = IngestionRepository::delete_skipped_by_ids_tx(tx.conn(), &ids).await {
                let _ = tx.commit().await;
                resolved += n;
            } else {
                let _ = tx.rollback().await;
                still_skipped += ids.len();
            }
        }

        // Force-probe scannable audio files grouped by provider.
        for (provider_id, items) in scannable_by_provider {
            let mut active_skipped: HashSet<String> =
                IngestionRepository::list_active_skipped_paths(&self.pool)
                    .await
                    .unwrap_or_default()
                    .into_iter()
                    .map(normalize_path)
                    .collect();

            let paths: Vec<PathBuf> = items.iter().map(|(_, p, _)| p.clone()).collect();
            let mut progress = ScanProgressEvent {
                root_path: provider_id.clone(),
                ..Default::default()
            };

            self.probe_and_persist_files_with_options(
                &provider_id,
                paths,
                true,
                &mut active_skipped,
                &mut progress,
            )
            .await?;

            // Re-check which files are still present in non-dismissed skipped_files
            let remaining: HashSet<String> =
                IngestionRepository::list_skipped_files(&self.pool, false)
                    .await
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|r| r.provider_id.eq_ignore_ascii_case(&provider_id))
                    .map(|r| normalize_path_for_compare(&r.file_path))
                    .collect();

            for (_, _, norm_path) in items {
                let cmp = normalize_path_for_compare(&norm_path);
                if remaining.contains(&cmp) {
                    still_skipped += 1;
                } else {
                    resolved += 1;
                }
            }
        }

        // Refresh `last_seen_at` for non-scannable files is optional; leave existing rows intact.
        let _ = SkipReason::UnsupportedFormat;

        Ok(BatchRescanSkippedResult {
            total,
            resolved,
            removed_missing,
            still_skipped,
        })
    }
}
