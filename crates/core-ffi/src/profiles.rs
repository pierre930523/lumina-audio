use crate::engine::{EngineState, get_engine};
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};
use core_db::{ProfileRepository, SqlitePool, open_test_database};
use core_types::Profile;
use serde::Deserialize;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

fn ensure_db_pool(engine: &EngineState) -> anyhow::Result<SqlitePool> {
    if let Ok(guard) = engine.db_pool.read()
        && let Some(ref pool) = *guard
    {
        return Ok(pool.clone());
    }
    let pool = engine.runtime.block_on(open_test_database())?;
    if let Ok(mut guard) = engine.db_pool.write() {
        *guard = Some(pool.clone());
    }
    Ok(pool)
}

#[derive(Debug, Deserialize)]
struct CreateProfilePayload {
    name: String,
    avatar_color: Option<String>,
    is_default: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct UpdateProfilePayload {
    name: Option<String>,
    avatar_color: Option<String>,
    is_default: Option<bool>,
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_profile_list() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_profile_list", || {
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let list = engine
            .runtime
            .block_on(ProfileRepository::list_profiles(&pool))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let json_str = serde_json::to_string(&list)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_profile_create(profile_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_profile_create", || {
        if profile_json.is_null() {
            set_last_error("profile_json is null");
            return Ok(std::ptr::null_mut());
        }
        let raw = unsafe { CStr::from_ptr(profile_json).to_str()? };
        let req: CreateProfilePayload = serde_json::from_str(raw)?;
        let color = req.avatar_color.unwrap_or_else(|| "#007AFF".to_string());
        let profile = Profile::new(req.name, color, req.is_default.unwrap_or(false))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let created = engine
            .runtime
            .block_on(ProfileRepository::create_profile(&pool, &profile))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        if let Ok(mut active) = engine.active_profile_id.write()
            && (active.is_none() || created.is_default)
        {
            *active = Some(created.id.clone());
        }

        let json_str = serde_json::to_string(&created)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_profile_update(
    profile_id: *const c_char,
    profile_json: *const c_char,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_profile_update", || {
        if profile_id.is_null() || profile_json.is_null() {
            set_last_error("profile_id or profile_json is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let id = unsafe { CStr::from_ptr(profile_id).to_str()? };
        let raw = unsafe { CStr::from_ptr(profile_json).to_str()? };
        let req: UpdateProfilePayload = serde_json::from_str(raw)?;

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let existing = engine
            .runtime
            .block_on(ProfileRepository::get_profile(&pool, id))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("Profile not found: {id}"))?;

        let mut updated = existing;
        if let Some(name) = req.name {
            updated.name = name;
        }
        if let Some(color) = req.avatar_color {
            updated.avatar_color = color;
        }
        if let Some(is_def) = req.is_default {
            updated.is_default = is_def;
        }

        engine
            .runtime
            .block_on(ProfileRepository::update_profile(&pool, &updated))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_profile_delete(profile_id: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_profile_delete", || {
        if profile_id.is_null() {
            set_last_error("profile_id is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let id = unsafe { CStr::from_ptr(profile_id).to_str()? };

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        engine
            .runtime
            .block_on(ProfileRepository::delete_profile(&pool, id))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        if let Ok(mut active) = engine.active_profile_id.write()
            && active.as_deref() == Some(id)
        {
            *active = engine
                .runtime
                .block_on(ProfileRepository::get_default_profile(&pool))
                .ok()
                .map(|p| p.id);
        }
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_profile_switch(profile_id: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_profile_switch", || {
        if profile_id.is_null() {
            set_last_error("profile_id is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let id = unsafe { CStr::from_ptr(profile_id).to_str()? };

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;
        let existing = engine
            .runtime
            .block_on(ProfileRepository::get_profile(&pool, id))
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("Profile not found: {id}"))?;

        if let Ok(mut active) = engine.active_profile_id.write() {
            *active = Some(existing.id);
        }
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_profile_get_active() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_profile_get_active", || {
        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;

        let active_id = engine.active_profile_id.read().ok().and_then(|g| g.clone());
        let profile = if let Some(ref aid) = active_id {
            engine
                .runtime
                .block_on(ProfileRepository::get_profile(&pool, aid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?
        } else {
            engine
                .runtime
                .block_on(ProfileRepository::get_default_profile(&pool))
                .ok()
        };

        let resolved = match profile {
            Some(p) => p,
            None => {
                let list = engine
                    .runtime
                    .block_on(ProfileRepository::list_profiles(&pool))
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                if let Some(first) = list.into_iter().next() {
                    first
                } else {
                    engine
                        .runtime
                        .block_on(ProfileRepository::create_profile(
                            &pool,
                            &Profile::default_profile(),
                        ))
                        .map_err(|e| anyhow::anyhow!(e.to_string()))?
                }
            }
        };

        if let Ok(mut active) = engine.active_profile_id.write() {
            *active = Some(resolved.id.clone());
        }

        let json_str = serde_json::to_string(&resolved)?;
        Ok(string_to_c_char(&json_str))
    })
}
