use std::path::{Path, PathBuf};

use super::models::{LyricsManager, LyricsResult, LyricsSource, LyricsTarget};
use crate::error::ProviderError;

impl LyricsManager {
    /// Loads lyrics for a given file and optional DB pool, following the strict priority chain:
    /// 1. User-specified file override (app_preferences DB table or explicit override path)
    /// 2. Embedded synchronized lyrics (MP3 SYLT, FLAC/Ogg SYNCEDLYRICS)
    /// 3. Same-name `.lrc` sidecar
    /// 4. Embedded unsynchronized lyrics (MP3 USLT, FLAC/Ogg LYRICS / UNSYNCEDLYRICS, MP4 ©lyr, WAV id3 chunk)
    /// 5. Same-name `.txt` sidecar
    /// 6. None (clean empty state)
    pub async fn get_lyrics(
        target: &LyricsTarget,
        pool: Option<&core_db::SqlitePool>,
    ) -> LyricsResult {
        // Resolve target file path and track id
        let (file_path_buf, track_id) = Self::resolve_target(target, pool).await;

        // 1. Check user override (external file override OR inline user/cloud DB edit)
        if let Some(user_override_path) = Self::get_user_override(target, pool).await {
            let p = Path::new(&user_override_path);
            if p.is_file() {
                if let Ok(bytes) = std::fs::read(p) {
                    if let Some(res) = Self::parse_lyrics_bytes(&bytes, p, LyricsSource::UserFile) {
                        return res;
                    }
                }
            }
        }
        if let (Some(p), Some(tid)) = (pool, track_id.as_deref())
            && let Ok(Some(edited_lyrics)) =
                core_db::LibraryRepository::get_track_lyrics_override(p, tid).await
        {
            let source = if edited_lyrics.contains('[') && edited_lyrics.contains(']') {
                LyricsSource::EmbeddedSynced
            } else {
                LyricsSource::EmbeddedUnsynced
            };
            if let Some(res) = Self::parse_lyrics_str(&edited_lyrics, source)
                && res.found
            {
                return res;
            }
        }

        let Some(path) = file_path_buf else {
            return LyricsResult::empty();
        };

        if !path.is_file() {
            return LyricsResult::empty();
        }

        // Extract embedded lyrics read-only without modifying PCM
        let embedded = Self::extract_embedded_lyrics(&path);

        // 2. Embedded synchronized lyrics
        if let Some(ref emb_synced) = embedded.synced {
            if let Some(res) = Self::parse_lyrics_str(emb_synced, LyricsSource::EmbeddedSynced) {
                if res.found {
                    return res;
                }
            }
        }

        // 3. Same-name .lrc sidecar
        let lrc_path = path.with_extension("lrc");
        if lrc_path.is_file() {
            if let Ok(bytes) = std::fs::read(&lrc_path) {
                if let Some(res) =
                    Self::parse_lyrics_bytes(&bytes, &lrc_path, LyricsSource::SidecarLrc)
                {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // Also check .LRC uppercase
        let lrc_upper = path.with_extension("LRC");
        if lrc_upper != lrc_path && lrc_upper.is_file() {
            if let Ok(bytes) = std::fs::read(&lrc_upper) {
                if let Some(res) =
                    Self::parse_lyrics_bytes(&bytes, &lrc_upper, LyricsSource::SidecarLrc)
                {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // 3b. Same-name .ttml / .TTML sidecar
        let ttml_path = path.with_extension("ttml");
        if ttml_path.is_file() {
            if let Ok(bytes) = std::fs::read(&ttml_path) {
                if let Some(res) =
                    Self::parse_lyrics_bytes(&bytes, &ttml_path, LyricsSource::SidecarTtml)
                {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        let ttml_upper = path.with_extension("TTML");
        if ttml_upper != ttml_path && ttml_upper.is_file() {
            if let Ok(bytes) = std::fs::read(&ttml_upper) {
                if let Some(res) =
                    Self::parse_lyrics_bytes(&bytes, &ttml_upper, LyricsSource::SidecarTtml)
                {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // 4. Embedded unsynchronized lyrics (or database cached embedded_lyrics)
        if let Some(ref emb_unsynced) = embedded.unsynced {
            if let Some(res) = Self::parse_lyrics_str(emb_unsynced, LyricsSource::EmbeddedUnsynced)
            {
                if res.found {
                    return res;
                }
            }
        }

        // Fallback: DB embedded_lyrics cache if track_id is known
        if let (Some(p), Some(tid)) = (pool, track_id.as_deref()) {
            if let Ok(Some(db_lyrics)) =
                core_db::LibraryRepository::get_track_embedded_lyrics(p, tid).await
            {
                if !db_lyrics.trim().is_empty() {
                    let source = if db_lyrics.contains('[') && db_lyrics.contains(']') {
                        LyricsSource::EmbeddedSynced
                    } else {
                        LyricsSource::EmbeddedUnsynced
                    };
                    if let Some(res) = Self::parse_lyrics_str(&db_lyrics, source) {
                        if res.found {
                            return res;
                        }
                    }
                }
            }
        }

        // 5. Same-name .txt sidecar
        let txt_path = path.with_extension("txt");
        if txt_path.is_file() {
            if let Ok(bytes) = std::fs::read(&txt_path) {
                if let Some(res) =
                    Self::parse_lyrics_bytes(&bytes, &txt_path, LyricsSource::SidecarTxt)
                {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        let txt_upper = path.with_extension("TXT");
        if txt_upper != txt_path && txt_upper.is_file() {
            if let Ok(bytes) = std::fs::read(&txt_upper) {
                if let Some(res) =
                    Self::parse_lyrics_bytes(&bytes, &txt_upper, LyricsSource::SidecarTxt)
                {
                    if res.found {
                        return res;
                    }
                }
            }
        }

        // 6. None
        LyricsResult::empty()
    }

    /// Sets a user lyrics file override for a track or file path.
    pub async fn set_user_override(
        target: &LyricsTarget,
        file_path: &str,
        pool: &core_db::SqlitePool,
    ) -> Result<(), ProviderError> {
        let key = Self::override_pref_key(target, pool).await;
        core_db::LibraryRepository::set_preference(pool, &key, file_path)
            .await
            .map_err(|e| ProviderError::Other(e.to_string()))?;
        Ok(())
    }

    /// Clears any user lyrics file override for a track or file path.
    pub async fn clear_user_override(
        target: &LyricsTarget,
        pool: &core_db::SqlitePool,
    ) -> Result<bool, ProviderError> {
        let key = Self::override_pref_key(target, pool).await;
        core_db::LibraryRepository::delete_preference(pool, &key)
            .await
            .map_err(|e| ProviderError::Other(e.to_string()))
    }

    async fn get_user_override(
        target: &LyricsTarget,
        pool: Option<&core_db::SqlitePool>,
    ) -> Option<String> {
        let pool = pool?;
        let key = Self::override_pref_key(target, pool).await;
        core_db::LibraryRepository::get_preference(pool, &key)
            .await
            .ok()
            .flatten()
            .filter(|s| !s.trim().is_empty())
    }

    async fn override_pref_key(target: &LyricsTarget, pool: &core_db::SqlitePool) -> String {
        if let Some(ref tid) = target.track_id {
            if !tid.trim().is_empty() {
                return format!("lyrics_override:track:{}", tid.trim());
            }
        }
        if let Some(ref fp) = target.file_path {
            // Try resolving track ID from DB first
            if let Ok(Some(track)) =
                core_db::LibraryRepository::get_track_file_cache_info(pool, "local", fp).await
            {
                return format!("lyrics_override:track:{}", track.track_id);
            }
            return format!("lyrics_override:path:{}", normalize_path(fp));
        }
        "lyrics_override:unknown".to_string()
    }

    async fn resolve_target(
        target: &LyricsTarget,
        pool: Option<&core_db::SqlitePool>,
    ) -> (Option<PathBuf>, Option<String>) {
        if let Some(ref fp) = target.file_path {
            let p = PathBuf::from(fp);
            let tid = target.track_id.clone();
            return (Some(p), tid);
        }

        if let (Some(tid), Some(p)) = (&target.track_id, pool) {
            if let Ok(Some(ts)) = core_db::LibraryRepository::find_track_source_by_id(p, tid).await
            {
                return (Some(PathBuf::from(ts.external_track_id)), Some(tid.clone()));
            }
        }

        (None, target.track_id.clone())
    }
}

fn normalize_path(path: &str) -> String {
    path.trim().replace('\\', "/").to_lowercase()
}
