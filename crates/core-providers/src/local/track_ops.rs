use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use core_db::{DbWriteCoordinator, ImmediateTx, LibraryRepository, SqlitePool};
use core_types::{
    DeleteTrackResult, ReidentifyTrackResult, TrackDeleteMode, TrackFileInfo, TrackMetadataLayer,
};

use crate::enrichment::{
    CreditEnrichmentService, DiscogsClient, DiscogsConfig, EnrichmentConfig, MusicBrainzClient,
    MusicBrainzConfig,
};
use crate::error::ProviderError;
use crate::library::db_err;
use crate::local::fingerprint::compute_content_fingerprint;
use crate::local::metadata::{ExtractOptions, parse_audio_metadata};

fn clean_opt(val: Option<&str>) -> Option<String> {
    val.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn parse_year_from_date(raw: Option<&str>) -> Option<i32> {
    let s = raw?.trim();
    if s.len() < 4 {
        return None;
    }
    s[..4]
        .parse::<i32>()
        .ok()
        .filter(|y| (1000..=3000).contains(y))
}

fn join_mb_artist_credits(
    credits: &[crate::enrichment::musicbrainz::MbArtistCredit],
) -> Option<String> {
    let joined: Vec<String> = credits
        .iter()
        .filter_map(|c| {
            c.name
                .as_deref()
                .or_else(|| c.artist.as_ref().map(|a| a.name.as_str()))
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        })
        .collect();
    if joined.is_empty() {
        None
    } else {
        Some(joined.join(", "))
    }
}

/// Rescans a single local track from disk, updating its technical fields and `file_meta_json`
/// plus clearing stale artwork cache rows, while leaving `user_edits_json` and `cloud_meta_json`
/// intact and immediately recomputing effective display fields.
pub async fn rescan_single_track(
    pool: &SqlitePool,
    cache_dir: &Path,
    track_id: &str,
) -> Result<TrackFileInfo, ProviderError> {
    let tid = track_id.trim();
    if tid.is_empty() {
        return Err(ProviderError::InvalidConfig(
            "track_id cannot be empty".to_string(),
        ));
    }

    let existing = LibraryRepository::find_track_source_by_id(pool, tid)
        .await
        .map_err(db_err)?
        .ok_or_else(|| ProviderError::Other(format!("Track '{tid}' not found")))?;

    if !existing.provider.as_str().eq_ignore_ascii_case("local") {
        return Err(ProviderError::InvalidConfig(
            "Only local files can be rescanned from disk".to_string(),
        ));
    }

    let path = PathBuf::from(&existing.external_track_id);
    if !path.is_file() {
        return Err(ProviderError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("Audio file not found: {}", path.display()),
        )));
    }

    let probe_path = path.clone();
    let probed = tokio::task::spawn_blocking(move || {
        let meta = parse_audio_metadata(
            &probe_path,
            ExtractOptions {
                include_pictures: true,
            },
        )?;
        let fp = compute_content_fingerprint(&probe_path)?;
        let fs_meta = std::fs::metadata(&probe_path)?;
        let file_size = i64::try_from(fs_meta.len()).ok();
        let file_mtime = fs_meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .and_then(|d| i64::try_from(d.as_secs()).ok());
        Ok::<_, ProviderError>((meta, fp, file_size, file_mtime))
    })
    .await
    .map_err(|e| ProviderError::ScanError(format!("Track probe panicked: {e}")))??;

    let (meta, fp, file_size, file_mtime) = probed;
    let duration_ms = if meta.duration_ms > 0 {
        meta.duration_ms
    } else {
        existing.duration_ms
    };
    let bitrate_kbps = match (file_size, duration_ms) {
        (Some(sz), dur) if sz > 0 && dur > 0 => {
            u32::try_from(((sz as u64).saturating_mul(8)) / dur)
                .ok()
                .filter(|&b| b > 0)
        }
        _ => None,
    };

    let file_layer = TrackMetadataLayer {
        title: clean_opt(Some(&meta.title)).or_else(|| Some(existing.title.clone())),
        artist_name: clean_opt(Some(&meta.artist)),
        album_artist: clean_opt(meta.album_artist.as_deref()),
        album_title: clean_opt(Some(&meta.album)),
        disc_number: Some(meta.disc_number).filter(|&n| n > 0),
        track_number: Some(meta.track_number).filter(|&n| n > 0),
        release_year: meta.release_year,
        genre: clean_opt(meta.genre.as_deref()),
        composer: clean_opt(meta.composer.as_deref()),
        isrc: clean_opt(meta.isrc.as_deref()),
        lyrics: clean_opt(meta.embedded_lyrics.as_deref()),
    };

    let write_coord = DbWriteCoordinator::for_pool(pool);
    let _guard = write_coord.write_lock().await;

    let (_albums, invalidated_paths) = LibraryRepository::apply_single_track_rescan(
        pool,
        tid,
        &file_layer,
        &meta.format,
        duration_ms,
        bitrate_kbps,
        file_mtime,
        file_size,
        Some(&fp.hash_hex),
        meta.replay_gain_track_db,
        meta.replay_gain_album_db,
        meta.replay_gain_track_peak,
        meta.replay_gain_album_peak,
    )
    .await
    .map_err(db_err)?;

    for raw in invalidated_paths {
        let p = Path::new(&raw);
        let full = if p.is_absolute() {
            p.to_path_buf()
        } else {
            cache_dir.join(p)
        };
        let _ = std::fs::remove_file(full);
    }

    LibraryRepository::get_track_file_info(pool, tid)
        .await
        .map_err(db_err)?
        .ok_or_else(|| ProviderError::Other(format!("Track '{tid}' disappeared after rescan")))
}

/// Re-identifies a single track via MusicBrainz (ISRC / recording search + album enrichment
/// fallback) and writes discovered cloud tags ONLY into `cloud_meta_json` so manual edits in
/// `user_edits_json` are never overwritten.
pub async fn reidentify_single_track(
    pool: &SqlitePool,
    track_id: &str,
    mb_base_url: Option<&str>,
    dg_base_url: Option<&str>,
    dg_token: Option<&str>,
) -> Result<ReidentifyTrackResult, ProviderError> {
    let tid = track_id.trim();
    let info = LibraryRepository::get_track_file_info(pool, tid)
        .await
        .map_err(db_err)?
        .ok_or_else(|| ProviderError::Other(format!("Track '{tid}' not found")))?;

    let mut mb_cfg = MusicBrainzConfig::default();
    if let Some(base) = clean_opt(mb_base_url) {
        mb_cfg.base_url = base;
        mb_cfg.min_interval_ms = 0;
    }
    let mb = MusicBrainzClient::new(mb_cfg)?;

    let mut dg_cfg = DiscogsConfig::default();
    if let Some(base) = clean_opt(dg_base_url) {
        dg_cfg.base_url = base;
        dg_cfg.min_interval_ms = 0;
    }
    if let Some(tok) = clean_opt(dg_token) {
        dg_cfg.token = Some(tok);
    }
    let dg = if dg_base_url.is_some() || dg_cfg.token.is_some() {
        Some(DiscogsClient::new(dg_cfg)?)
    } else {
        None
    };

    let mut cloud_patch = TrackMetadataLayer::default();
    let mut matched_mb_recording_id: Option<String> = None;
    let mut matched_source: Option<String> = None;

    let search_title = info
        .effective_layer
        .title
        .clone()
        .or_else(|| info.file_layer.as_ref().and_then(|l| l.title.clone()))
        .unwrap_or_default();
    let search_artist = info
        .effective_layer
        .artist_name
        .clone()
        .or_else(|| info.effective_layer.album_artist.clone())
        .unwrap_or_default();
    let isrc = info
        .effective_layer
        .isrc
        .clone()
        .or_else(|| info.file_layer.as_ref().and_then(|l| l.isrc.clone()));

    if let Some(ref code) = isrc
        && let Ok(lookup) = mb.lookup_by_isrc(code).await
        && let Some(rec) = lookup.recordings.first()
    {
        matched_mb_recording_id = Some(rec.id.clone());
        matched_source = Some("MusicBrainz (ISRC)".to_string());
        cloud_patch.title = clean_opt(Some(&rec.title));
        cloud_patch.artist_name = join_mb_artist_credits(&rec.artist_credit);
        cloud_patch.isrc = Some(code.clone());
        if let Some(rel) = rec.releases.first() {
            cloud_patch.album_title = clean_opt(Some(&rel.title));
            cloud_patch.release_year = parse_year_from_date(rel.date.as_deref());
            cloud_patch.album_artist = join_mb_artist_credits(&rel.artist_credit);
        }
    }

    if matched_mb_recording_id.is_none()
        && !search_title.is_empty()
        && let Ok(recs) = mb.search_recordings(&search_title, &search_artist, 5).await
        && let Some(rec) = recs.into_iter().find(|r| {
            r.score.unwrap_or(100) >= 70 || r.title.trim().eq_ignore_ascii_case(search_title.trim())
        })
    {
        matched_mb_recording_id = Some(rec.id.clone());
        matched_source = Some("MusicBrainz".to_string());
        cloud_patch.title = clean_opt(Some(&rec.title));
        cloud_patch.artist_name = join_mb_artist_credits(&rec.artist_credit);
        if let Some(rel) = rec.releases.first() {
            cloud_patch.album_title = clean_opt(Some(&rel.title));
            cloud_patch.release_year = parse_year_from_date(rel.date.as_deref());
            cloud_patch.album_artist = join_mb_artist_credits(&rel.artist_credit);
        }
    }

    if !info.album_group_id.is_empty() {
        let cfg = EnrichmentConfig {
            force_refresh: true,
            ..Default::default()
        };
        let svc = CreditEnrichmentService::new(Some(mb), dg, cfg);
        if let Ok(album_res) = svc.enrich_album(pool, &info.album_group_id).await
            && !album_res.skipped
            && matched_source.is_none()
        {
            matched_source = Some("MusicBrainz / Discogs (Album)".to_string());
        }
    }

    if !core_types::LayeredMetadata::is_empty(&cloud_patch) {
        let write_coord = DbWriteCoordinator::for_pool(pool);
        let _guard = write_coord.write_lock().await;
        let mut tx = ImmediateTx::begin(pool).await.map_err(db_err)?;
        let res = LibraryRepository::write_track_cloud_meta_tx(tx.conn(), tid, &cloud_patch)
            .await
            .map_err(db_err);
        match res {
            Ok(_) => tx.commit().await.map_err(db_err)?,
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(e);
            }
        }
    }

    let refreshed = LibraryRepository::get_track_file_info(pool, tid)
        .await
        .map_err(db_err)?;
    let matched = matched_source.is_some();

    Ok(ReidentifyTrackResult {
        track_id: tid.to_string(),
        matched,
        source: matched_source,
        musicbrainz_recording_id: matched_mb_recording_id,
        message: if matched {
            None
        } else {
            Some("No matching cloud recording found; manual edits preserved".to_string())
        },
        file_info: refreshed,
    })
}

/// Moves a local file to the operating system's Recycle Bin / Trash cleanly with zero external crates.
pub fn move_file_to_os_trash(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("File does not exist: {}", path.display()));
    }

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows::Win32::UI::Shell::{
            FO_DELETE, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT,
            SHFILEOPSTRUCTW, SHFileOperationW,
        };
        use windows::core::PCWSTR;

        let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
        wide.push(0);
        wide.push(0);
        let mut op = SHFILEOPSTRUCTW {
            hwnd: Default::default(),
            wFunc: FO_DELETE,
            pFrom: PCWSTR(wide.as_ptr()),
            pTo: PCWSTR::null(),
            fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT).0 as u16,
            fAnyOperationsAborted: false.into(),
            hNameMappings: std::ptr::null_mut(),
            lpszProgressTitle: PCWSTR::null(),
        };
        let code = unsafe { SHFileOperationW(&mut op) };
        if code != 0 || op.fAnyOperationsAborted.as_bool() {
            return Err(format!(
                "SHFileOperationW failed deleting '{}' (code={code})",
                path.display()
            ));
        }
        Ok(())
    }

    #[cfg(target_os = "macos")]
    {
        let posix = path
            .to_string_lossy()
            .replace('\\', "\\\\")
            .replace('"', "\\\"");
        let script = format!("tell application \"Finder\" to delete POSIX file \"{posix}\"");
        let status = std::process::Command::new("osascript")
            .args(["-e", &script])
            .status()
            .map_err(|e| format!("Failed to spawn osascript: {e}"))?;
        if !status.success() {
            return Err(format!("Finder move-to-trash exited with status {status}"));
        }
        return Ok(());
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let status = std::process::Command::new("gio")
            .arg("trash")
            .arg(path)
            .status()
            .or_else(|_| {
                std::process::Command::new("kioclient5")
                    .arg("move")
                    .arg(path)
                    .arg("trash:/")
                    .status()
            })
            .map_err(|e| format!("Failed to move file to trash: {e}"))?;
        if !status.success() {
            return Err(format!("Trash command exited with status {status}"));
        }
        Ok(())
    }
}

/// Deletes a single track from the SQLite library, optionally moving the underlying local file
/// to the OS Recycle Bin / Trash first.
pub async fn delete_single_track(
    pool: &SqlitePool,
    cache_dir: &Path,
    track_id: &str,
    mode: TrackDeleteMode,
) -> Result<DeleteTrackResult, ProviderError> {
    let tid = track_id.trim();
    let existing = LibraryRepository::find_track_source_by_id(pool, tid)
        .await
        .map_err(db_err)?
        .ok_or_else(|| ProviderError::Other(format!("Track '{tid}' not found")))?;

    let is_local = existing.provider.as_str().eq_ignore_ascii_case("local");
    let mut moved_to_trash = false;
    let mut warning: Option<String> = None;

    if mode == TrackDeleteMode::MoveToTrash && is_local {
        let disk_path = PathBuf::from(&existing.external_track_id);
        if disk_path.exists() {
            tokio::task::spawn_blocking(move || move_file_to_os_trash(&disk_path))
                .await
                .map_err(|e| ProviderError::Other(format!("Trash worker panicked: {e}")))?
                .map_err(ProviderError::Other)?;
            moved_to_trash = true;
        } else {
            warning = Some(
                "Audio file was already missing on disk; removed library entry only".to_string(),
            );
        }
    }

    let write_coord = DbWriteCoordinator::for_pool(pool);
    let _guard = write_coord.write_lock().await;
    let (mut result, _path, _is_local, invalidated_paths) =
        LibraryRepository::delete_track_from_library(pool, tid, mode)
            .await
            .map_err(db_err)?;

    for raw in invalidated_paths {
        let p = Path::new(&raw);
        let full = if p.is_absolute() {
            p.to_path_buf()
        } else {
            cache_dir.join(p)
        };
        let _ = std::fs::remove_file(full);
    }

    result.moved_to_trash = moved_to_trash;
    result.warning = warning;
    Ok(result)
}
