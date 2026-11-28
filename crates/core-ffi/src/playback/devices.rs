use crate::engine::{EngineState, get_engine};
use crate::error::{
    LUMINA_ERR_AUDIO_BACKEND, LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_OK,
    catch_unwind_ffi, set_last_error, set_last_structured_error, string_to_c_char,
};
use core_audio::device_manager::AudioDeviceManager;
use core_types::{
    AudioDeviceInfo, AudioEngineOutputInfo, DsdOutputMode, LuminaError, LuminaErrorCode,
    OutputBackendKind,
};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::Ordering;

pub(super) fn build_device_infos(engine: &EngineState) -> Vec<AudioDeviceInfo> {
    let active_id = engine.active_device_id.read().ok().and_then(|g| g.clone());
    if let Some(p) = engine.player_clone() {
        let caps_with_meta = p.list_device_capabilities_with_meta();
        if !caps_with_meta.is_empty() {
            return caps_with_meta
                .into_iter()
                .map(|(cap, meta)| {
                    let is_active = match active_id.as_deref() {
                        Some(id) => id == cap.device_id,
                        None => cap.is_default || meta.is_os_default,
                    };
                    AudioDeviceManager::capabilities_to_device_info(&cap, &meta, is_active)
                })
                .collect();
        }
        return p
            .list_output_devices()
            .into_iter()
            .map(|d| {
                let is_active = match active_id.as_deref() {
                    Some(id) => id == d.id,
                    None => d.is_default,
                };
                AudioDeviceManager::to_device_info(&d, None, is_active)
            })
            .collect();
    }
    AudioDeviceManager::list_device_infos(active_id.as_deref())
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_list_devices() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_audio_list_devices", || {
        let engine = get_engine();
        let active_id = engine.active_device_id.read().ok().and_then(|g| g.clone());
        let devices = if let Some(p) = engine.player_clone() {
            p.list_output_devices()
        } else {
            let real = core_audio::enumerate_cpal_devices();
            if real.is_empty() {
                let tmp = core_audio::AudioPlayer::new_headless();
                let list = tmp.list_output_devices();
                tmp.shutdown();
                list
            } else {
                real
            }
        };
        let mut enriched = Vec::with_capacity(devices.len());
        for dev in devices {
            let is_active = match active_id.as_deref() {
                Some(id) => id == dev.id,
                None => dev.is_default,
            };
            let info = AudioDeviceManager::to_device_info(&dev, None, is_active);
            let mut val = serde_json::to_value(&dev)?;
            if let (Some(obj), Ok(serde_json::Value::Object(info_obj))) =
                (val.as_object_mut(), serde_json::to_value(&info))
            {
                for (k, v) in info_obj {
                    obj.entry(k).or_insert(v);
                }
            }
            enriched.push(val);
        }
        let json_str = serde_json::to_string(&enriched)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_select_device(
    device_id: *const c_char,
    backend_kind: c_int,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_select_device", || {
        let dev_id = if device_id.is_null() {
            None
        } else {
            let s = unsafe { CStr::from_ptr(device_id).to_str()? }.trim();
            if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            }
        };

        let backend = if backend_kind >= 0 {
            OutputBackendKind::ALL.get(backend_kind as usize).copied()
        } else {
            None
        };

        let engine = get_engine();
        if let Some(p) = engine.player_clone() {
            if let Err(e) = p.select_output_device(dev_id.as_deref(), backend) {
                let structured = e.to_lumina_error();
                engine.set_structured_error(structured.clone());
                set_last_structured_error(structured);
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
            if let Ok(mut lock) = engine.active_device_id.write() {
                *lock = dev_id.clone();
            }
            engine
                .dsp_bypassed
                .store(p.is_dsp_bypassed(), Ordering::SeqCst);
            engine
                .volume_bits
                .store(p.volume().to_bits() as u64, Ordering::Relaxed);
            engine.runtime.block_on(
                engine
                    .zone_manager
                    .sync_local_zone_selected_device(dev_id.as_deref(), Some(&p)),
            );
            engine.next_sequence();
            Ok(LUMINA_OK)
        } else {
            let err = LuminaError::new(
                LuminaErrorCode::NotInitialized,
                "Audio engine not initialized",
            );
            set_last_structured_error(err);
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}

/// Returns JSON of full Phase 10 `AudioEngineOutputInfo` (SOURCE, DECODER, OUTPUT, VERIFICATION).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_get_output_info() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_audio_get_output_info", || {
        let engine = get_engine();
        let info = if let Some(p) = engine.player_clone() {
            p.output_info()
        } else {
            AudioEngineOutputInfo::default()
        };
        let json_str = serde_json::to_string(&info)?;
        Ok(string_to_c_char(&json_str))
    })
}

/// Returns JSON array of real probed `AudioDeviceCapabilities` (WASAPI + ASIO)
/// enriched with OS-default, HDMI, and hardware buffer bounds metadata.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_list_device_capabilities() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_audio_list_device_capabilities",
        || {
            let engine = get_engine();
            let caps_with_meta = if let Some(p) = engine.player_clone() {
                p.list_device_capabilities_with_meta()
            } else {
                AudioDeviceManager::list_devices_with_meta()
            };
            let mut items = Vec::with_capacity(caps_with_meta.len());
            for (cap, meta) in caps_with_meta {
                let mut val = serde_json::to_value(&cap)?;
                if let Some(obj) = val.as_object_mut() {
                    obj.insert(
                        "is_os_default".into(),
                        serde_json::json!(meta.is_os_default),
                    );
                    obj.insert("is_hdmi".into(), serde_json::json!(meta.is_hdmi));
                    obj.insert(
                        "hardware_supports_exclusive".into(),
                        serde_json::json!(meta.hardware_supports_exclusive),
                    );
                    obj.insert(
                        "buffer_size_supported".into(),
                        serde_json::json!(meta.buffer_size_supported),
                    );
                    if let Some(v) = meta.min_buffer_frames {
                        obj.insert("min_buffer_frames".into(), serde_json::json!(v));
                    }
                    if let Some(v) = meta.max_buffer_frames {
                        obj.insert("max_buffer_frames".into(), serde_json::json!(v));
                    }
                    if let Some(v) = meta.default_buffer_frames {
                        obj.insert("default_buffer_frames".into(), serde_json::json!(v));
                    }
                    if let Some(v) = meta.buffer_granularity {
                        obj.insert("buffer_granularity".into(), serde_json::json!(v));
                    }
                }
                items.push(val);
            }
            let json_str = serde_json::to_string(&items)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Sets preferred hardware buffer size in frames when supported by the active backend.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_set_buffer_frames(frames: u32) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_set_buffer_frames", || {
        let engine = get_engine();
        if let Some(p) = engine.player_clone() {
            if let Err(e) = p.set_preferred_buffer_frames(frames) {
                set_last_error(e.to_string());
                return Ok(LUMINA_ERR_AUDIO_BACKEND);
            }
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}

/// Enables or disables Strict Bit-Perfect Mode (disables EQ/ReplayGain/Crossfeed/SW Volume/SRC).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_set_strict_mode(enabled: c_int) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_set_strict_mode", || {
        let engine = get_engine();
        let on = enabled != 0;
        if let Some(p) = engine.player_clone() {
            p.set_strict_bit_perfect(on)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            engine
                .dsp_bypassed
                .store(p.is_dsp_bypassed(), Ordering::SeqCst);
            engine
                .volume_bits
                .store(p.volume().to_bits() as u64, Ordering::Relaxed);
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}

/// Sets DSD output mode: 0 = Auto, 1 = NativeDsd, 2 = DoP, 3 = DsdToPcm.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_audio_set_dsd_mode(mode: c_int) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_audio_set_dsd_mode", || {
        let dsd_mode = match mode {
            1 => DsdOutputMode::NativeDsd,
            2 => DsdOutputMode::DoP,
            3 => DsdOutputMode::DsdToPcm,
            _ => DsdOutputMode::Auto,
        };
        let engine = get_engine();
        if let Some(p) = engine.player_clone() {
            p.set_dsd_output_mode(dsd_mode)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}
