use crate::engine::get_engine;
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NOT_INITIALIZED, LUMINA_ERR_NULL_POINTER, LUMINA_OK,
    catch_unwind_ffi, set_last_error, string_to_c_char,
};
use core_audio::{DspPipelineConfig, PeqBand, build_signal_path, parse_autoeq_txt};
use core_types::{
    AudioCodec, AudioFormat, DspPipelineConfig as SharedDspConfig, OutputBackendKind, SignalPath,
    SignalQuality,
};
use serde_json::json;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::Ordering;

fn serialize_signal_path(path: &SignalPath, bypassed: Option<bool>) -> serde_json::Value {
    let overall_str = path.overall.as_str();
    let nodes_val: Vec<serde_json::Value> = path
        .nodes
        .iter()
        .map(|n| {
            json!({
                "stage": n.stage,
                "detail": n.detail,
                "quality": n.quality.as_str(),
            })
        })
        .collect();

    if let Some(b) = bypassed {
        json!({
            "overall_quality": overall_str,
            "nodes": nodes_val,
            "dsp_bypassed": b,
        })
    } else {
        json!({
            "overall_quality": overall_str,
            "nodes": nodes_val,
        })
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_signal_path_get() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_signal_path_get", || {
        let engine = get_engine();
        let bypassed = engine.dsp_bypassed.load(Ordering::Relaxed);

        if let Some(player) = engine.player_clone() {
            let path = player.current_signal_path();
            let effective_bypass = player.is_dsp_bypassed();
            engine
                .dsp_bypassed
                .store(effective_bypass, Ordering::Relaxed);
            let root = serialize_signal_path(&path, Some(effective_bypass));
            let json_str = serde_json::to_string(&root)?;
            return Ok(string_to_c_char(&json_str));
        }

        let format = AudioFormat {
            codec: AudioCodec::Flac,
            sample_rate_hz: 96_000,
            bit_depth: 24,
            channels: 2,
            is_dsd: false,
        };

        let mut dsp = DspPipelineConfig::default();
        if bypassed {
            dsp.bypass = true;
        } else {
            dsp.bypass = false;
            dsp.peq_bands = vec![PeqBand {
                frequency_hz: 1000.0,
                gain_db: 2.5,
                q_factor: 1.414,
                enabled: true,
            }];
        }

        let path = build_signal_path(
            "Qobuz Hi-Res 24/96",
            &format,
            &dsp,
            None,
            OutputBackendKind::WindowsAsio,
            "FiiO K9 Pro USB ASIO",
        );

        let root = serialize_signal_path(&path, Some(bypassed));
        let json_str = serde_json::to_string(&root)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_signal_path_get_quality() -> c_int {
    catch_unwind_ffi(-1, "lumina_signal_path_get_quality", || {
        let engine = get_engine();
        if let Some(player) = engine.player_clone() {
            let q = match player.current_signal_path().overall {
                SignalQuality::Lossless => 0,
                SignalQuality::Enhanced => 1,
                SignalQuality::HighQuality => 2,
            };
            return Ok(q);
        }

        let bypassed = engine.dsp_bypassed.load(Ordering::Relaxed);
        if bypassed {
            Ok(0) // 0 = Lossless
        } else {
            Ok(1) // 1 = Enhanced
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_signal_path_toggle_dsp_bypass() -> c_int {
    catch_unwind_ffi(
        crate::error::LUMINA_ERR_GENERAL,
        "lumina_signal_path_toggle_dsp_bypass",
        || {
            let engine = get_engine();
            if let Some(player) = engine.player_clone() {
                let effective = player.toggle_dsp_bypass();
                engine.dsp_bypassed.store(effective, Ordering::SeqCst);
                return Ok(LUMINA_OK);
            }
            let _ = engine.dsp_bypassed.fetch_xor(true, Ordering::SeqCst);
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_signal_path_inspect(
    source_label: *const c_char,
    format_json: *const c_char,
    dsp_bypass: c_int,
    backend_kind: c_int,
    device_name: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_signal_path_inspect", || {
        let s_label = if !source_label.is_null() {
            unsafe { CStr::from_ptr(source_label).to_str().unwrap_or("Source") }
        } else {
            "Source"
        };

        let dev_name = if !device_name.is_null() {
            unsafe {
                CStr::from_ptr(device_name)
                    .to_str()
                    .unwrap_or("Default DAC")
            }
        } else {
            "Default DAC"
        };

        let default_format = AudioFormat {
            codec: AudioCodec::Flac,
            sample_rate_hz: 96_000,
            bit_depth: 24,
            channels: 2,
            is_dsd: false,
        };

        let format = if !format_json.is_null() {
            let f_str = unsafe { CStr::from_ptr(format_json).to_str().unwrap_or("") };
            serde_json::from_str::<AudioFormat>(f_str).unwrap_or(default_format)
        } else {
            default_format
        };

        let mut dsp = DspPipelineConfig::default();
        if dsp_bypass == 0 {
            dsp.bypass = false;
            dsp.peq_bands = vec![PeqBand {
                frequency_hz: 1000.0,
                gain_db: 2.5,
                q_factor: 1.414,
                enabled: true,
            }];
        } else {
            dsp.bypass = true;
        }

        let backend = match backend_kind {
            0 => OutputBackendKind::WindowsAsio,
            1 => OutputBackendKind::WindowsWasapiExclusive,
            _ => OutputBackendKind::WindowsWasapiShared,
        };

        let path = build_signal_path(s_label, &format, &dsp, None, backend, dev_name);
        let root = serialize_signal_path(&path, None);
        let json_str = serde_json::to_string(&root)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_dsp_get_config() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_dsp_get_config", || {
        let engine = get_engine();
        let cfg = if let Some(p) = engine.player_clone() {
            p.get_dsp_config()
        } else {
            SharedDspConfig {
                bypass: engine.dsp_bypassed.load(Ordering::Relaxed),
                ..SharedDspConfig::default()
            }
        };
        let json_str = serde_json::to_string(&cfg)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_dsp_set_config(config_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_dsp_set_config", || {
        if config_json.is_null() {
            set_last_error("config_json is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let raw = unsafe { CStr::from_ptr(config_json).to_str()? };
        let cfg: SharedDspConfig = serde_json::from_str(raw)?;
        let engine = get_engine();
        engine.dsp_bypassed.store(cfg.bypass, Ordering::SeqCst);

        if let Some(p) = engine.player_clone() {
            p.set_dsp_config(cfg)
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            engine
                .dsp_bypassed
                .store(p.is_dsp_bypassed(), Ordering::SeqCst);
            Ok(LUMINA_OK)
        } else {
            Ok(LUMINA_ERR_NOT_INITIALIZED)
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_dsp_import_autoeq(autoeq_txt: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_dsp_import_autoeq", || {
        if autoeq_txt.is_null() {
            set_last_error("autoeq_txt is null");
            return Ok(std::ptr::null_mut());
        }
        let raw = unsafe { CStr::from_ptr(autoeq_txt).to_str()? };
        let bands = parse_autoeq_txt(raw).map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let engine = get_engine();
        if let Some(p) = engine.player_clone() {
            let mut cfg = p.get_dsp_config();
            cfg.peq_bands = bands.clone();
            cfg.bypass = false;
            engine.dsp_bypassed.store(false, Ordering::SeqCst);
            let _ = p.set_dsp_config(cfg);
        }

        let json_str = serde_json::to_string(&bands)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{lumina_init_headless, lumina_shutdown, lumina_string_free};
    use std::ffi::CStr;

    #[test]
    fn test_idle_signal_path_queries_real_player_not_hardcoded_asio_dummy() {
        let _guard = crate::streaming_bridge::TEST_BRIDGE_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        lumina_shutdown();
        assert_eq!(lumina_init_headless(), 0);

        let ptr = lumina_signal_path_get();
        assert!(!ptr.is_null());
        let json_str = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(ptr) };

        assert!(
            !json_str.contains("FiiO K9 Pro USB ASIO"),
            "Idle signal path must come from live player, not hardcoded dummy: {json_str}"
        );
        assert!(json_str.contains("Virtual Exclusive DAC"));
        assert_eq!(lumina_signal_path_get_quality(), 1); // Enhanced (PEQ active by default)

        lumina_shutdown();
    }
}
