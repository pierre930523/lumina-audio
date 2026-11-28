use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock, RwLock};

use core_types::{AudioExportProgress, AudioExportRequest, AudioExportStatus};
use sqlx::SqlitePool;
use uuid::Uuid;

use super::catalog_export::{ExportTrackRow, resolve_export_tracks};
use crate::error::{DbError, Result};

struct AudioExportJob {
    progress: AudioExportProgress,
    cancelled: Arc<AtomicBool>,
}

static EXPORT_JOBS: OnceLock<RwLock<HashMap<String, AudioExportJob>>> = OnceLock::new();

fn job_registry() -> &'static RwLock<HashMap<String, AudioExportJob>> {
    EXPORT_JOBS.get_or_init(|| RwLock::new(HashMap::new()))
}

fn update_job_progress(job_id: &str, f: impl FnOnce(&mut AudioExportProgress)) {
    if let Ok(mut map) = job_registry().write()
        && let Some(job) = map.get_mut(job_id)
    {
        f(&mut job.progress);
    }
}

fn sanitize_component(raw: &str, fallback: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if matches!(ch, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || ch.is_control() {
            out.push('_');
        } else {
            out.push(ch);
        }
    }
    let trimmed = out.trim().trim_end_matches(['.', ' ']);
    if trimmed.is_empty() {
        return fallback.to_string();
    }
    // Bound component length safely on UTF-8 char boundaries for Windows MAX_PATH hygiene.
    let mut clipped: String = trimmed.chars().take(96).collect();
    while clipped.ends_with(['.', ' ']) {
        clipped.pop();
    }
    if clipped.is_empty() {
        fallback.to_string()
    } else {
        clipped
    }
}

fn sanitize_m3u8_filename(raw: Option<&str>) -> String {
    let base = raw
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| sanitize_component(s, "playlist"))
        .unwrap_or_else(|| "playlist.m3u8".to_string());
    if base.to_ascii_lowercase().ends_with(".m3u8") {
        base
    } else {
        format!("{base}.m3u8")
    }
}

fn allocate_unique_rel_path(
    dest_root: &Path,
    subdir: Option<&Path>,
    stem: &str,
    ext: &str,
    overwrite_existing: bool,
    used_lower: &mut HashSet<String>,
) -> (PathBuf, String) {
    let mut attempt = 1usize;
    loop {
        let filename = if attempt == 1 {
            format!("{stem}.{ext}")
        } else {
            format!("{stem} ({attempt}).{ext}")
        };
        let rel = match subdir {
            Some(dir) => dir.join(&filename),
            None => PathBuf::from(&filename),
        };
        let rel_forward = rel.to_string_lossy().replace('\\', "/");
        let lower_key = rel_forward.to_ascii_lowercase();
        let disk_exists = !overwrite_existing && dest_root.join(&rel).exists();
        if !used_lower.contains(&lower_key) && !disk_exists {
            used_lower.insert(lower_key);
            return (rel, rel_forward);
        }
        attempt += 1;
    }
}

async fn run_audio_export_task(
    job_id: String,
    req: AudioExportRequest,
    tracks: Vec<ExportTrackRow>,
    cancelled: Arc<AtomicBool>,
) {
    let dest_root = PathBuf::from(req.destination_dir.trim());
    let mut used_lower: HashSet<String> = HashSet::new();
    let mut m3u8_entries: Vec<(u64, String, String, String)> = Vec::new();
    let mut copied_tracks = 0u64;
    let mut skipped_tracks = 0u64;
    let mut failed_tracks = 0u64;
    let mut bytes_copied = 0u64;

    for (idx, track) in tracks.iter().enumerate() {
        if cancelled.load(Ordering::SeqCst) {
            update_job_progress(&job_id, |p| {
                p.status = AudioExportStatus::Cancelled;
                p.current_file = None;
            });
            return;
        }

        let src_path = Path::new(&track.file_path);
        if !track.provider_id.eq_ignore_ascii_case("local") || !src_path.is_file() {
            skipped_tracks += 1;
            let reason = if !track.provider_id.eq_ignore_ascii_case("local") {
                format!(
                    "Skipped non-local track '{}' (provider: {})",
                    track.title, track.provider_id
                )
            } else {
                format!("Skipped missing local file: {}", track.file_path)
            };
            update_job_progress(&job_id, |p| {
                p.skipped_tracks = skipped_tracks;
                p.errors.push(reason);
            });
            continue;
        }

        let ext = src_path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.trim().to_ascii_lowercase())
            .filter(|e| !e.is_empty())
            .unwrap_or_else(|| "audio".to_string());

        let safe_artist = sanitize_component(&track.artist, "Unknown Artist");
        let safe_title = sanitize_component(&track.title, "Untitled");
        let stem = format!("{:02} - {} - {}", idx + 1, safe_artist, safe_title);

        let subdir = if req.preserve_structure {
            let safe_album_artist = sanitize_component(
                if track.album_artist.trim().is_empty() {
                    &track.artist
                } else {
                    &track.album_artist
                },
                "Unknown Artist",
            );
            let safe_album = sanitize_component(&track.album, "Unknown Album");
            Some(PathBuf::from(safe_album_artist).join(safe_album))
        } else {
            None
        };

        let (rel_path, rel_forward) = allocate_unique_rel_path(
            &dest_root,
            subdir.as_deref(),
            &stem,
            &ext,
            req.overwrite_existing,
            &mut used_lower,
        );
        let full_dst = dest_root.join(&rel_path);
        if let Some(parent) = full_dst.parent()
            && let Err(err) = tokio::fs::create_dir_all(parent).await
        {
            failed_tracks += 1;
            update_job_progress(&job_id, |p| {
                p.failed_tracks = failed_tracks;
                p.errors
                    .push(format!("Failed to create dir for '{}': {err}", track.title));
            });
            continue;
        }

        update_job_progress(&job_id, |p| {
            p.current_file = Some(rel_forward.clone());
        });

        match tokio::fs::copy(src_path, &full_dst).await {
            Ok(bytes) => {
                copied_tracks += 1;
                bytes_copied = bytes_copied.saturating_add(bytes);
                let dur_secs = (track.duration_ms.max(0) as u64) / 1000;
                m3u8_entries.push((
                    dur_secs,
                    track.artist.clone(),
                    track.title.clone(),
                    rel_forward,
                ));
                update_job_progress(&job_id, |p| {
                    p.copied_tracks = copied_tracks;
                    p.bytes_copied = bytes_copied;
                });
            }
            Err(err) => {
                failed_tracks += 1;
                update_job_progress(&job_id, |p| {
                    p.failed_tracks = failed_tracks;
                    p.errors
                        .push(format!("Failed to copy '{}': {err}", track.file_path));
                });
            }
        }
    }

    if cancelled.load(Ordering::SeqCst) {
        update_job_progress(&job_id, |p| {
            p.status = AudioExportStatus::Cancelled;
            p.current_file = None;
        });
        return;
    }

    let mut m3u8_written: Option<String> = None;
    if req.generate_m3u8 && !m3u8_entries.is_empty() {
        let m3u8_name = sanitize_m3u8_filename(req.playlist_filename.as_deref());
        let m3u8_path = dest_root.join(&m3u8_name);
        let mut content = String::from("#EXTM3U\n");
        for (secs, artist, title, rel) in &m3u8_entries {
            content.push_str(&format!("#EXTINF:{secs},{artist} - {title}\n{rel}\n"));
        }
        match tokio::fs::write(&m3u8_path, content.as_bytes()).await {
            Ok(()) => {
                m3u8_written = Some(m3u8_path.to_string_lossy().to_string());
            }
            Err(err) => {
                update_job_progress(&job_id, |p| {
                    p.errors.push(format!("Failed to write m3u8: {err}"));
                });
            }
        }
    }

    let final_status = if copied_tracks == 0 && failed_tracks > 0 {
        AudioExportStatus::Failed
    } else {
        AudioExportStatus::Completed
    };

    update_job_progress(&job_id, |p| {
        p.status = final_status;
        p.current_file = None;
        p.m3u8_path = m3u8_written;
    });
}

pub struct AudioExportManager;

impl AudioExportManager {
    pub async fn start_audio_export(
        pool: &SqlitePool,
        req: AudioExportRequest,
    ) -> Result<AudioExportProgress> {
        let dest_trimmed = req.destination_dir.trim();
        if dest_trimmed.is_empty() {
            return Err(DbError::ConstraintViolation(
                "Audio export destination_dir must not be empty".into(),
            ));
        }

        let tracks = resolve_export_tracks(pool, &req.source).await?;
        tokio::fs::create_dir_all(dest_trimmed).await?;

        let job_id = Uuid::new_v4().to_string();
        let initial = AudioExportProgress {
            job_id: job_id.clone(),
            status: AudioExportStatus::Running,
            destination_dir: dest_trimmed.to_string(),
            total_tracks: tracks.len() as u64,
            copied_tracks: 0,
            skipped_tracks: 0,
            failed_tracks: 0,
            bytes_copied: 0,
            current_file: None,
            m3u8_path: None,
            errors: Vec::new(),
        };
        let cancelled = Arc::new(AtomicBool::new(false));

        if let Ok(mut map) = job_registry().write() {
            map.insert(
                job_id.clone(),
                AudioExportJob {
                    progress: initial.clone(),
                    cancelled: Arc::clone(&cancelled),
                },
            );
        }

        tokio::spawn(run_audio_export_task(job_id, req, tracks, cancelled));
        Ok(initial)
    }

    pub fn get_audio_export_progress(job_id: &str) -> Option<AudioExportProgress> {
        job_registry()
            .read()
            .ok()
            .and_then(|map| map.get(job_id).map(|j| j.progress.clone()))
    }

    pub fn cancel_audio_export(job_id: &str) -> bool {
        if let Ok(map) = job_registry().read()
            && let Some(job) = map.get(job_id)
        {
            job.cancelled.store(true, Ordering::SeqCst);
            return true;
        }
        false
    }
}
