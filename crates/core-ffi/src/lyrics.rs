use crate::engine::get_engine;
use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, LUMINA_ERR_GENERAL,
    LUMINA_ERR_NULL_POINTER, LUMINA_OK,
};
use core_providers::{LyricsManager, LyricsResult, LyricsTarget};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

fn parse_target(target_json: *const c_char) -> Result<LyricsTarget, anyhow::Error> {
    if target_json.is_null() {
        return Err(anyhow::anyhow!("target is null"));
    }
    let s = unsafe { CStr::from_ptr(target_json) }.to_str()?.trim();
    if s.is_empty() {
        return Err(anyhow::anyhow!("target is empty"));
    }
    if s.starts_with('{') {
        let t: LyricsTarget = serde_json::from_str(s)?;
        Ok(t)
    } else if s.contains('/')
        || s.contains('\\')
        || s.ends_with(".flac")
        || s.ends_with(".mp3")
        || s.ends_with(".wav")
        || s.ends_with(".m4a")
        || s.ends_with(".dsf")
        || s.ends_with(".dff")
    {
        Ok(LyricsTarget {
            file_path: Some(s.to_string()),
            track_id: None,
        })
    } else {
        Ok(LyricsTarget {
            track_id: Some(s.to_string()),
            file_path: None,
        })
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_lyrics_get(target_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_lyrics_get", || {
        let target = match parse_target(target_json) {
            Ok(t) => t,
            Err(_) => {
                let empty = LyricsResult::empty();
                return Ok(string_to_c_char(&serde_json::to_string(&empty)?));
            }
        };

        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());

        let res = engine
            .runtime
            .block_on(LyricsManager::get_lyrics(&target, maybe_pool.as_ref()));

        let json_str = serde_json::to_string(&res)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_lyrics_set_user_file(
    target_json: *const c_char,
    file_path: *const c_char,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_lyrics_set_user_file", || {
        if file_path.is_null() {
            set_last_error("file_path is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let fp = unsafe { CStr::from_ptr(file_path) }.to_str()?.trim();
        let target = parse_target(target_json)?;

        let engine = get_engine();
        let pool = crate::library::ensure_db_pool(&engine)?;

        engine
            .runtime
            .block_on(LyricsManager::set_user_override(&target, fp, &pool))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_lyrics_clear_user_file(target_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_lyrics_clear_user_file", || {
        let target = parse_target(target_json)?;
        let engine = get_engine();
        let pool = crate::library::ensure_db_pool(&engine)?;

        engine
            .runtime
            .block_on(LyricsManager::clear_user_override(&target, &pool))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        Ok(LUMINA_OK)
    })
}
