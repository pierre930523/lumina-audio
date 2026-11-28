use std::collections::HashSet;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::Instant;

use core_types::{ScanLifecycleState, ScanProgressEvent, SkipReason};
use tokio::sync::broadcast;

use super::PROGRESS_THROTTLE;
use crate::local::ignore::{
    classify_unsupported_container, is_playlist_sidecar, should_ignore_name,
};
use crate::local::scanner::{
    DetailedScanOutput, ScanSkippedCandidate, is_scannable_audio, normalize_path, read_size_mtime,
};

/// Discovers audio files, playlist sidecars, and skipped candidates under `root`.
///
/// - Avoids calling `fs::canonicalize` on every subdirectory unless `follow_symlinks` is `true`
///   (uses normalized path strings for cycle-free traversal when symlinks are skipped).
/// - Emits 200ms-throttled `ScanLifecycleState::Discovering` progress updates on `progress_tx`.
pub(super) fn discover_root_with_progress(
    root: &Path,
    follow_symlinks: bool,
    progress_tx: Option<&broadcast::Sender<ScanProgressEvent>>,
    scan_id: &str,
    root_label: &str,
) -> DetailedScanOutput {
    let mut output = DetailedScanOutput::default();
    let mut visited_dirs: HashSet<String> = HashSet::new();
    let mut last_emit = Instant::now();

    traverse_dir(
        root,
        follow_symlinks,
        &mut visited_dirs,
        &mut output,
        progress_tx,
        scan_id,
        root_label,
        &mut last_emit,
    );

    output
}

#[allow(clippy::too_many_arguments)]
fn traverse_dir(
    current: &Path,
    follow_symlinks: bool,
    visited_dirs: &mut HashSet<String>,
    output: &mut DetailedScanOutput,
    progress_tx: Option<&broadcast::Sender<ScanProgressEvent>>,
    scan_id: &str,
    root_label: &str,
    last_emit: &mut Instant,
) {
    let visit_key = if follow_symlinks {
        match fs::canonicalize(current) {
            Ok(p) => normalize_path(&p),
            Err(e) => {
                if e.kind() == ErrorKind::PermissionDenied {
                    output.skipped_candidates.push(ScanSkippedCandidate {
                        path: current.to_path_buf(),
                        reason: SkipReason::PermissionDenied,
                        detail: format!("Permission denied accessing directory: {e}"),
                        file_size: None,
                        file_mtime: None,
                    });
                }
                return;
            }
        }
    } else {
        normalize_path(current)
    };

    if !visited_dirs.insert(visit_key) {
        return;
    }

    if let Some(tx) = progress_tx {
        if last_emit.elapsed() >= PROGRESS_THROTTLE {
            let _ = tx.send(ScanProgressEvent {
                scan_id: scan_id.to_string(),
                root_path: root_label.to_string(),
                state: ScanLifecycleState::Discovering,
                total_estimated: Some(output.audio_files.len() as u64),
                skipped: output.skipped_candidates.len() as u64,
                current_path: Some(normalize_path(current)),
                ..Default::default()
            });
            *last_emit = Instant::now();
        }
    }

    let entries = match fs::read_dir(current) {
        Ok(iter) => iter,
        Err(e) => {
            let reason = if e.kind() == ErrorKind::PermissionDenied {
                SkipReason::PermissionDenied
            } else {
                SkipReason::IoError
            };
            output.skipped_candidates.push(ScanSkippedCandidate {
                path: current.to_path_buf(),
                reason,
                detail: format!("Failed to read directory: {e}"),
                file_size: None,
                file_mtime: None,
            });
            return;
        }
    };

    for entry_res in entries {
        let entry = match entry_res {
            Ok(e) => e,
            Err(e) => {
                let reason = if e.kind() == ErrorKind::PermissionDenied {
                    SkipReason::PermissionDenied
                } else {
                    SkipReason::IoError
                };
                output.skipped_candidates.push(ScanSkippedCandidate {
                    path: current.to_path_buf(),
                    reason,
                    detail: format!("Failed to read directory entry: {e}"),
                    file_size: None,
                    file_mtime: None,
                });
                continue;
            }
        };

        let path = entry.path();
        let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if should_ignore_name(file_name) {
            continue;
        }

        let file_type = match entry.file_type() {
            Ok(ft) => ft,
            Err(e) => {
                let reason = if e.kind() == ErrorKind::PermissionDenied {
                    SkipReason::PermissionDenied
                } else {
                    SkipReason::IoError
                };
                output.skipped_candidates.push(ScanSkippedCandidate {
                    path,
                    reason,
                    detail: format!("Failed to inspect file type: {e}"),
                    file_size: None,
                    file_mtime: None,
                });
                continue;
            }
        };

        if file_type.is_symlink() && !follow_symlinks {
            continue;
        }

        let is_dir =
            file_type.is_dir() || (file_type.is_symlink() && follow_symlinks && path.is_dir());

        if is_dir {
            traverse_dir(
                &path,
                follow_symlinks,
                visited_dirs,
                output,
                progress_tx,
                scan_id,
                root_label,
                last_emit,
            );
        } else if file_type.is_file()
            || (file_type.is_symlink() && follow_symlinks && path.is_file())
        {
            classify_discovered_file(path, output);
        }
    }
}

fn classify_discovered_file(path: PathBuf, output: &mut DetailedScanOutput) {
    if is_scannable_audio(&path) {
        output.audio_files.push(path);
    } else if is_playlist_sidecar(&path) {
        output.playlist_files.push(path);
    } else if let Some(reason) = classify_unsupported_container(&path) {
        let (file_size, file_mtime) = read_size_mtime(&path);
        let detail = match reason {
            SkipReason::UnsplitCueOrIso => {
                "Unsplit CUE sheet or disc ISO image is not directly playable".to_string()
            }
            _ => format!(
                "Unsupported audio container (.{})",
                path.extension()
                    .and_then(|e| e.to_str())
                    .unwrap_or("unknown")
            ),
        };
        output.skipped_candidates.push(ScanSkippedCandidate {
            path,
            reason,
            detail,
            file_size,
            file_mtime,
        });
    }
}
