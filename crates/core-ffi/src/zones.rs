use crate::engine::get_engine;
use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, LUMINA_ERR_GENERAL,
    LUMINA_ERR_NULL_POINTER, LUMINA_OK,
};
use core_server::zones::{ZoneDiscoverRequest, ZoneGroupRequest};
use serde::Deserialize;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

#[derive(Debug, Deserialize)]
struct ZoneSyncInputJson {
    zone_id: String,
    clock_addr: Option<String>,
    samples: Option<usize>,
    use_sntp_binary: Option<bool>,
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_zone_list() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_zone_list", || {
        let engine = get_engine();
        let zones = engine.runtime.block_on(engine.zone_manager.list_zones());
        let json_str = serde_json::to_string(&zones)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_zone_discover() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_zone_discover", || {
        let engine = get_engine();
        let player = engine.player.read().ok().and_then(|g| g.clone());
        let zones = engine.runtime.block_on(
            engine
                .zone_manager
                .discover_zones(player.as_ref(), ZoneDiscoverRequest::default()),
        )?;
        let json_str = serde_json::to_string(&zones)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_zone_group(group_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_zone_group", || {
        if group_json.is_null() {
            set_last_error("group_json is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let raw = unsafe { CStr::from_ptr(group_json).to_str()? };
        let req: ZoneGroupRequest = serde_json::from_str(raw)?;
        let engine = get_engine();
        engine
            .runtime
            .block_on(engine.zone_manager.group_zones(req))?;
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_zone_set_volume(zone_id: *const c_char, volume: f32) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_zone_set_volume", || {
        if zone_id.is_null() {
            set_last_error("zone_id is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let zid = unsafe { CStr::from_ptr(zone_id).to_str()? };
        let engine = get_engine();
        engine
            .runtime
            .block_on(engine.zone_manager.set_zone_volume(zid, volume))?;
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_zone_sync_status(zone_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_zone_sync_status", || {
        if zone_id.is_null() {
            set_last_error("zone_id is null");
            return Ok(std::ptr::null_mut());
        }
        let raw = unsafe { CStr::from_ptr(zone_id).to_str()? };
        let engine = get_engine();

        let (zid, clock_addr, samples, use_sntp) =
            if raw.trim_start().starts_with('{') {
                let parsed: ZoneSyncInputJson = serde_json::from_str(raw)?;
                (
                    parsed.zone_id,
                    parsed.clock_addr,
                    parsed.samples.unwrap_or(5),
                    parsed.use_sntp_binary.unwrap_or(false),
                )
            } else {
                (raw.trim().to_string(), None, 5, false)
            };

        if let Some(addr) = clock_addr {
            let m = engine.runtime.block_on(engine.zone_manager.sync_zone_clock(
                &zid,
                Some(&addr),
                samples,
                15,
                use_sntp,
            ))?;
            let json_str = serde_json::to_string(&m)?;
            return Ok(string_to_c_char(&json_str));
        }

        let zone = engine
            .runtime
            .block_on(engine.zone_manager.get_zone(&zid))
            .ok_or_else(|| anyhow::anyhow!("Zone not found: {zid}"))?;
        let status = serde_json::json!({
            "zone_id": zone.id,
            "clock_sync_addr": zone.clock_sync_addr,
            "offset_us": zone.clock_offset_us.unwrap_or(0),
            "rtt_us": zone.rtt_us.unwrap_or(0),
            "drift_ppm": zone.drift_ppm.unwrap_or(0.0),
        });
        let json_str = serde_json::to_string(&status)?;
        Ok(string_to_c_char(&json_str))
    })
}
