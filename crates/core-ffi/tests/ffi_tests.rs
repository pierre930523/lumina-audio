use core_ffi::*;
use std::f64::consts::PI;
use std::ffi::{CStr, CString};
use std::sync::Mutex;

static FFI_TEST_GUARD: Mutex<()> = Mutex::new(());

fn write_test_wav(path: &std::path::Path, sample_rate: u32, channels: u16, num_frames: u32) {
    let mut buf = Vec::new();
    let block_align = channels * 2;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = num_frames * (block_align as u32);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    for n in 0..num_frames {
        let t = n as f64 / sample_rate as f64;
        let sample = ((2.0 * PI * 440.0 * t).sin() * 20000.0) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample.to_le_bytes());
        }
    }
    std::fs::write(path, buf).unwrap();
}

#[test]
fn test_core_version_export() {
    assert_eq!(core_version(), "0.1.0");

    let c_ver = lumina_version();
    assert!(!c_ver.is_null());
    let s = unsafe { CStr::from_ptr(c_ver).to_str().unwrap() };
    assert_eq!(s, "0.1.0");
}

#[test]
fn test_ffi_lifecycle_and_playback_control() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // Initial state is Stopped (1)
    assert_eq!(playback::lumina_playback_get_state(), 1);

    // Set volume
    assert_eq!(playback::lumina_playback_set_volume(0.85), 0);
    assert!((playback::lumina_playback_get_volume() - 0.85).abs() < 1e-4);

    // Play track (synthetic metadata)
    let track_json = CString::new(r#"{"id": "trk-001", "title": "Time"}"#).unwrap();
    assert_eq!(playback::lumina_playback_play(track_json.as_ptr()), 0);
    assert_eq!(playback::lumina_playback_get_state(), 2); // 2 = Playing

    // Seek
    assert_eq!(playback::lumina_playback_seek(45_000), 0);
    assert_eq!(playback::lumina_playback_get_position_ms(), 45_000);

    // Pause
    assert_eq!(playback::lumina_playback_pause(), 0);
    assert_eq!(playback::lumina_playback_get_state(), 3); // 3 = Paused

    // Stop
    assert_eq!(playback::lumina_playback_stop(), 0);
    assert_eq!(playback::lumina_playback_get_state(), 1); // 1 = Stopped
    assert_eq!(playback::lumina_playback_get_position_ms(), 0);

    // Shutdown
    assert_eq!(lumina_shutdown(), 0);
    assert_eq!(playback::lumina_playback_get_state(), 0); // 0 = Uninit
}

#[test]
fn test_ffi_signal_path_query_and_bypass_toggle() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    lumina_init_headless();

    // With DSP active: quality should be Enhanced (1)
    let q1 = signal_path::lumina_signal_path_get_quality();
    assert_eq!(q1, 1);

    let sp_ptr1 = signal_path::lumina_signal_path_get();
    assert!(!sp_ptr1.is_null());
    let sp_str1 = unsafe { CStr::from_ptr(sp_ptr1).to_str().unwrap() };
    assert!(sp_str1.contains("\"overall_quality\":\"enhanced\""));
    unsafe { lumina_string_free(sp_ptr1) };

    // Toggle DSP Bypass
    assert_eq!(signal_path::lumina_signal_path_toggle_dsp_bypass(), 0);

    // With DSP bypassed: quality should be Lossless (0)
    let q2 = signal_path::lumina_signal_path_get_quality();
    assert_eq!(q2, 0);

    let sp_ptr2 = signal_path::lumina_signal_path_get();
    assert!(!sp_ptr2.is_null());
    let sp_str2 = unsafe { CStr::from_ptr(sp_ptr2).to_str().unwrap() };
    assert!(sp_str2.contains("\"overall_quality\":\"lossless\""));
    assert!(sp_str2.contains("\"dsp_bypassed\":true"));
    unsafe { lumina_string_free(sp_ptr2) };

    // Toggle back
    signal_path::lumina_signal_path_toggle_dsp_bypass();
    lumina_shutdown();
}

#[test]
fn test_ffi_signal_path_inspect() {
    let source = CString::new("Tidal Hi-Fi").unwrap();
    let dev = CString::new("ASIO Driver").unwrap();

    let ptr = signal_path::lumina_signal_path_inspect(
        source.as_ptr(),
        std::ptr::null(),
        1, // bypass = 1 -> lossless
        0, // backend = ASIO
        dev.as_ptr(),
    );

    assert!(!ptr.is_null());
    let json_str = unsafe { CStr::from_ptr(ptr).to_str().unwrap() };
    assert!(json_str.contains("\"overall_quality\":\"lossless\""));
    unsafe { lumina_string_free(ptr) };
}

#[test]
fn test_ffi_library_search() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();

    let q = CString::new("Pink").unwrap();
    let res_ptr = library::lumina_library_search(q.as_ptr(), 10);
    assert!(!res_ptr.is_null());

    let res_str = unsafe { CStr::from_ptr(res_ptr).to_str().unwrap() };
    assert!(res_str.contains("Pink Floyd"));
    assert!(res_str.contains("Time"));
    unsafe { lumina_string_free(res_ptr) };

    // Empty query returns empty array
    let empty_q = CString::new("").unwrap();
    let empty_ptr = library::lumina_library_search(empty_q.as_ptr(), 10);
    let empty_str = unsafe { CStr::from_ptr(empty_ptr).to_str().unwrap() };
    assert_eq!(empty_str, "[]");
    unsafe { lumina_string_free(empty_ptr) };
}

#[test]
fn test_ffi_server_lifecycle() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(server::lumina_server_start(0, 1), 0);
    assert!(server::lumina_server_get_port() > 0);
    assert_eq!(server::lumina_server_stop(), 0);
    assert_eq!(server::lumina_server_get_port(), 0);
}

#[test]
fn test_ffi_error_message_and_panic_catch() {
    error::set_last_error("Test custom error");
    let err_ptr = lumina_last_error_message();
    assert!(!err_ptr.is_null());
    let err_str = unsafe { CStr::from_ptr(err_ptr).to_str().unwrap() };
    assert_eq!(err_str, "Test custom error");
    unsafe { lumina_string_free(err_ptr) };

    // Once taken, next call returns null
    let next_err_ptr = lumina_last_error_message();
    assert!(next_err_ptr.is_null());
}

#[test]
fn test_ffi_real_sqlite_scan_search_and_headless_playback() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root_dir = std::env::temp_dir().join(format!("lumina_ffi_e2e_{ts}"));
    let album_dir = root_dir.join("Miles Davis").join("Kind of Blue");
    std::fs::create_dir_all(&album_dir).unwrap();
    write_test_wav(&album_dir.join("01 - So What.wav"), 48_000, 2, 96_000);
    let db_path = root_dir.join("library.db");

    assert_eq!(lumina_init_headless(), 0);

    let db_cstr = CString::new(db_path.to_string_lossy().as_ref()).unwrap();
    assert_eq!(library::lumina_library_init(db_cstr.as_ptr()), 0);

    let dir_cstr = CString::new(root_dir.to_string_lossy().as_ref()).unwrap();
    let scan_ptr = library::lumina_library_scan_dir(dir_cstr.as_ptr());
    assert!(!scan_ptr.is_null());
    let scan_str = unsafe { CStr::from_ptr(scan_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(scan_ptr) };
    let scan_val: serde_json::Value = serde_json::from_str(&scan_str).unwrap();
    assert_eq!(scan_val["tracks_count"], 1);
    assert_eq!(scan_val["albums_count"], 1);

    let tracks_ptr = library::lumina_library_get_tracks(50);
    assert!(!tracks_ptr.is_null());
    let tracks_str = unsafe { CStr::from_ptr(tracks_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(tracks_ptr) };
    let tracks_val: serde_json::Value = serde_json::from_str(&tracks_str).unwrap();
    assert_eq!(tracks_val.as_array().unwrap().len(), 1);
    assert_eq!(tracks_val[0]["artist"], "Miles Davis");
    assert_eq!(tracks_val[0]["album"], "Kind of Blue");

    let q_cstr = CString::new("Miles").unwrap();
    let search_ptr = library::lumina_library_search(q_cstr.as_ptr(), 20);
    assert!(!search_ptr.is_null());
    let search_str = unsafe { CStr::from_ptr(search_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(search_ptr) };
    let search_val: serde_json::Value = serde_json::from_str(&search_str).unwrap();
    assert_eq!(search_val.as_array().unwrap().len(), 1);

    let play_payload = serde_json::json!({
        "id": tracks_val[0]["id"],
        "file_path": tracks_val[0]["file_path"],
        "source": "Local Library"
    })
    .to_string();
    let play_cstr = CString::new(play_payload).unwrap();
    assert_eq!(playback::lumina_playback_play(play_cstr.as_ptr()), 0);
    assert_eq!(playback::lumina_playback_get_state(), 2);
    assert!(playback::lumina_playback_get_duration_ms() >= 1900);

    std::thread::sleep(std::time::Duration::from_millis(80));
    assert!(playback::lumina_playback_get_position_ms() > 0);

    // Signal Path reflects real WAV stream: Enhanced -> Lossless on bypass toggle
    assert_eq!(signal_path::lumina_signal_path_get_quality(), 1);
    assert_eq!(signal_path::lumina_signal_path_toggle_dsp_bypass(), 0);
    assert_eq!(signal_path::lumina_signal_path_get_quality(), 0);

    let sp_ptr = signal_path::lumina_signal_path_get();
    let sp_str = unsafe { CStr::from_ptr(sp_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(sp_ptr) };
    assert!(sp_str.contains("Local Library"));
    assert!(sp_str.contains("\"overall_quality\":\"lossless\""));

    assert_eq!(playback::lumina_playback_stop(), 0);
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(root_dir);
}

#[test]
fn test_ffi_m7c_and_phase4_exports_roundtrip() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // 1. Profiles CRUD & switch
    let p_json = CString::new(r##"{"name":"Audiophile","avatar_color":"#8B5CF6"}"##).unwrap();
    let p_ptr = profiles::lumina_profile_create(p_json.as_ptr());
    assert!(!p_ptr.is_null());
    let p_str = unsafe { CStr::from_ptr(p_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(p_ptr) };
    let created: serde_json::Value = serde_json::from_str(&p_str).unwrap();
    let pid = created["id"].as_str().unwrap().to_string();

    let p2_json = CString::new(r##"{"name":"NightMode","avatar_color":"#10B981"}"##).unwrap();
    let p2_ptr = profiles::lumina_profile_create(p2_json.as_ptr());
    let p2_str = unsafe { CStr::from_ptr(p2_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(p2_ptr) };
    let p2_id = serde_json::from_str::<serde_json::Value>(&p2_str).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    let p2_c = CString::new(p2_id.clone()).unwrap();
    assert_eq!(profiles::lumina_profile_switch(p2_c.as_ptr()), 0);
    let act_ptr = profiles::lumina_profile_get_active();
    let act_str = unsafe { CStr::from_ptr(act_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(act_ptr) };
    assert!(act_str.contains(&p2_id));

    let upd_c = CString::new(r##"{"name":"NightModeV2","avatar_color":"#10B981","is_default":false}"##).unwrap();
    assert_eq!(profiles::lumina_profile_update(p2_c.as_ptr(), upd_c.as_ptr()), 0);
    assert_eq!(profiles::lumina_profile_delete(p2_c.as_ptr()), 0);

    let list_ptr = profiles::lumina_profile_list();
    let list_str = unsafe { CStr::from_ptr(list_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(list_ptr) };
    assert!(list_str.contains(&pid));

    // 2. Audio device listing & selection
    let devs_ptr = playback::lumina_audio_list_devices();
    assert!(!devs_ptr.is_null());
    let devs_str = unsafe { CStr::from_ptr(devs_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(devs_ptr) };
    let devs: Vec<serde_json::Value> = serde_json::from_str(&devs_str).unwrap();
    assert!(!devs.is_empty());
    let dev_id = CString::new(devs[0]["id"].as_str().unwrap()).unwrap();
    assert_eq!(playback::lumina_audio_select_device(dev_id.as_ptr(), 1), 0);

    // 3. DSP Config & AutoEQ import
    let autoeq_c = CString::new("Preamp: -4.2 dB\nFilter 1: ON PK Fc 250 Hz Gain 2.5 dB Q 1.2\n").unwrap();
    let bands_ptr = signal_path::lumina_dsp_import_autoeq(autoeq_c.as_ptr());
    assert!(!bands_ptr.is_null());
    let bands_str = unsafe { CStr::from_ptr(bands_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(bands_ptr) };
    assert!(bands_str.contains("250.0"));

    let dsp_ptr = signal_path::lumina_dsp_get_config();
    let dsp_str = unsafe { CStr::from_ptr(dsp_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(dsp_ptr) };
    assert!(dsp_str.contains("250.0"));

    // 4. Library dedup & albums
    let dedup_ptr = library::lumina_library_deduplicate();
    let dedup_str = unsafe { CStr::from_ptr(dedup_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(dedup_ptr) };
    assert!(dedup_str.contains("merged_albums"));

    let albums_ptr = library::lumina_library_get_albums(10);
    assert!(!albums_ptr.is_null());
    unsafe { lumina_string_free(albums_ptr) };

    // 5. Providers & Tidal PKCE
    let pkce_ptr = providers::lumina_provider_tidal_pkce_start();
    assert!(!pkce_ptr.is_null());
    let pkce_str = unsafe { CStr::from_ptr(pkce_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(pkce_ptr) };
    assert!(pkce_str.contains("auth_url"));
    assert!(pkce_str.contains("verifier"));

    // 6. Zones
    let z_ptr = zones::lumina_zone_discover();
    assert!(!z_ptr.is_null());
    let z_str = unsafe { CStr::from_ptr(z_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(z_ptr) };
    assert!(z_str.contains("zone-local"));

    let z_id = CString::new("zone-local").unwrap();
    assert_eq!(zones::lumina_zone_set_volume(z_id.as_ptr(), 0.75), 0);
    let grp_c = CString::new(r#"{"group_id":"grp-1","zone_ids":["zone-local"]}"#).unwrap();
    assert_eq!(zones::lumina_zone_group(grp_c.as_ptr()), 0);
    let sync_ptr = zones::lumina_zone_sync_status(z_id.as_ptr());
    let sync_str = unsafe { CStr::from_ptr(sync_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(sync_ptr) };
    assert!(sync_str.contains("zone-local"));

    assert_eq!(lumina_shutdown(), 0);
}

#[test]
fn test_ffi_demo_track_synth_playback_advances_position() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let track_json =
        CString::new(r#"{"id":"trk-001","title":"Time","source":"Qobuz Hi-Res"}"#).unwrap();
    assert_eq!(playback::lumina_playback_play(track_json.as_ptr()), 0);
    assert_eq!(playback::lumina_playback_get_state(), 2);
    assert_eq!(playback::lumina_playback_get_duration_ms(), 245_000);

    std::thread::sleep(std::time::Duration::from_millis(120));
    assert!(
        playback::lumina_playback_get_position_ms() > 0,
        "Expected demo track synth playback to advance position_ms"
    );

    let sp_ptr = signal_path::lumina_signal_path_get();
    assert!(!sp_ptr.is_null());
    let sp_str = unsafe { CStr::from_ptr(sp_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(sp_ptr) };
    assert!(sp_str.contains("Qobuz Hi-Res"));
    assert!(!sp_str.contains("FiiO K9 Pro USB ASIO"));

    assert_eq!(playback::lumina_playback_stop(), 0);
    assert_eq!(lumina_shutdown(), 0);
}

#[test]
fn test_ffi_non_headless_wasapi_playback_and_zone_default() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init(), 0);

    let devs_ptr = playback::lumina_audio_list_devices();
    assert!(!devs_ptr.is_null());
    let devs_str = unsafe { CStr::from_ptr(devs_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(devs_ptr) };
    let devs: Vec<serde_json::Value> = serde_json::from_str(&devs_str).unwrap();
    let has_real_hw = devs
        .iter()
        .any(|d| d["id"].as_str() != Some("virtual-exclusive-dac"));

    let z_ptr = zones::lumina_zone_list();
    assert!(!z_ptr.is_null());
    let z_str = unsafe { CStr::from_ptr(z_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(z_ptr) };
    let z_list: Vec<serde_json::Value> = serde_json::from_str(&z_str).unwrap();
    let local_zone = z_list
        .iter()
        .find(|z| z["id"].as_str() == Some("zone-local"))
        .expect("zone-local must exist");
    if has_real_hw {
        assert_ne!(
            local_zone["device_id"].as_str(),
            Some("virtual-exclusive-dac"),
            "zone-local must not default to virtual-exclusive-dac when real hardware exists"
        );
    }

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let wav_path = std::env::temp_dir().join(format!("lumina_ffi_wasapi_{ts}.wav"));
    write_test_wav(&wav_path, 48_000, 2, 96_000);

    let play_payload = serde_json::json!({
        "id": "wasapi-wav-1",
        "title": "WASAPI Test",
        "file_path": wav_path.to_string_lossy(),
        "source": "Local Library"
    })
    .to_string();
    let play_cstr = CString::new(play_payload).unwrap();
    assert_eq!(playback::lumina_playback_play(play_cstr.as_ptr()), 0);

    std::thread::sleep(std::time::Duration::from_millis(140));
    assert!(playback::lumina_playback_get_position_ms() > 0);

    let sp_ptr = signal_path::lumina_signal_path_get();
    let sp_str = unsafe { CStr::from_ptr(sp_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(sp_ptr) };
    if has_real_hw {
        assert!(
            !sp_str.contains("Virtual Exclusive DAC"),
            "Non-headless WASAPI playback must not report Virtual Exclusive DAC: {sp_str}"
        );
    }

    assert_eq!(playback::lumina_playback_stop(), 0);
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_file(wav_path);
}

#[test]
fn test_ffi_invalid_file_path_returns_error_and_last_error() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // Drain any prior error
    let prev = lumina_last_error_message();
    if !prev.is_null() {
        unsafe { lumina_string_free(prev) };
    }

    let bad_json =
        CString::new(r#"{"id":"bad-1","title":"Missing","file_path":"/definitely/missing/audio_12345.wav"}"#)
            .unwrap();
    let rc1 = playback::lumina_playback_play(bad_json.as_ptr());
    assert_eq!(rc1, error::LUMINA_ERR_AUDIO_BACKEND);
    let err1 = lumina_last_error_message();
    assert!(!err1.is_null());
    let err1_str = unsafe { CStr::from_ptr(err1).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(err1) };
    assert!(!err1_str.is_empty());

    let bad_raw = CString::new("/definitely/missing/raw_12345.wav").unwrap();
    let rc2 = playback::lumina_playback_play(bad_raw.as_ptr());
    assert_eq!(rc2, error::LUMINA_ERR_AUDIO_BACKEND);
    let err2 = lumina_last_error_message();
    assert!(!err2.is_null());
    unsafe { lumina_string_free(err2) };

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let corrupt_path = std::env::temp_dir().join(format!("lumina_ffi_corrupt_{ts}.wav"));
    std::fs::write(&corrupt_path, b"NOT_A_VALID_AUDIO_FILE_1234567890").unwrap();
    let corrupt_json = serde_json::json!({
        "id": "bad-corrupt",
        "title": "Corrupt",
        "file_path": corrupt_path.to_string_lossy(),
    })
    .to_string();
    let corrupt_cstr = CString::new(corrupt_json).unwrap();
    let rc3 = playback::lumina_playback_play(corrupt_cstr.as_ptr());
    assert_eq!(rc3, error::LUMINA_ERR_AUDIO_BACKEND);
    let err3 = lumina_last_error_message();
    assert!(!err3.is_null());
    unsafe { lumina_string_free(err3) };

    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_file(corrupt_path);
}

#[test]
fn test_ffi_phase10_strict_mode_output_info_and_device_caps() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // 1. Device capabilities JSON
    let caps_ptr = playback::lumina_audio_list_device_capabilities();
    assert!(!caps_ptr.is_null());
    let caps_str = unsafe { CStr::from_ptr(caps_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(caps_ptr) };
    let caps_val: serde_json::Value = serde_json::from_str(&caps_str).unwrap();
    assert!(caps_val.as_array().is_some_and(|a| !a.is_empty()));

    // 2. Write a 48kHz / 16-bit WAV file & enable Strict Bit-Perfect Mode
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let wav_path = std::env::temp_dir().join(format!("lumina_ffi_strict_{ts}.wav"));
    write_test_wav(&wav_path, 48_000, 2, 48_000);

    assert_eq!(playback::lumina_playback_set_volume(0.40), 0);
    assert!((playback::lumina_playback_get_volume() - 0.40).abs() < 1e-4);

    assert_eq!(playback::lumina_audio_set_strict_mode(1), 0);
    // Strict mode forces SW volume to 1.0 and rejects attenuation
    assert!((playback::lumina_playback_get_volume() - 1.0).abs() < 1e-4);
    assert_eq!(playback::lumina_playback_set_volume(0.25), 0);
    assert!((playback::lumina_playback_get_volume() - 1.0).abs() < 1e-4);

    assert_eq!(playback::lumina_audio_set_dsd_mode(2), 0); // DoP

    let payload = serde_json::json!({
        "id": "strict-wav",
        "title": "Strict 48k",
        "file_path": wav_path.to_string_lossy(),
    })
    .to_string();
    let c_payload = CString::new(payload).unwrap();
    assert_eq!(playback::lumina_playback_play(c_payload.as_ptr()), 0);

    std::thread::sleep(std::time::Duration::from_millis(120));
    let info_ptr = playback::lumina_audio_get_output_info();
    assert!(!info_ptr.is_null());
    let info_str = unsafe { CStr::from_ptr(info_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(info_ptr) };
    let info_val: serde_json::Value = serde_json::from_str(&info_str).unwrap();
    assert_eq!(info_val["output"]["strict_mode"], serde_json::json!(true));
    assert_eq!(info_val["verification"]["sample_hash_match"], serde_json::json!(true));
    assert_eq!(info_val["verification"]["status"], serde_json::json!("PCM UNMODIFIED"));

    // Exit Strict Mode -> restores previous SW volume (0.25)
    assert_eq!(playback::lumina_audio_set_strict_mode(0), 0);
    assert!((playback::lumina_playback_get_volume() - 0.25).abs() < 1e-4);

    assert_eq!(playback::lumina_playback_stop(), 0);
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_file(wav_path);
}

#[test]
fn test_ffi_contract1_playback_state_json_resume_and_reconnect() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // Initial state JSON
    let state_ptr = playback::lumina_playback_get_state_json();
    assert!(!state_ptr.is_null());
    let state_str = unsafe { CStr::from_ptr(state_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(state_ptr) };
    let st: serde_json::Value = serde_json::from_str(&state_str).unwrap();
    assert_eq!(st["state_code"], 1); // Stopped
    assert_eq!(st["state_name"], "Stopped");
    assert_eq!(st["clock_source"], "stream_frames");
    assert_eq!(st["volume"], 1.0);
    assert_eq!(st["is_seeking"], false);
    assert_eq!(st["device_lost"], false);

    // Play demo track
    let track_json = CString::new(r#"{"id": "trk-c1", "title": "Contract Track"}"#).unwrap();
    assert_eq!(playback::lumina_playback_play(track_json.as_ptr()), 0);

    let state_ptr2 = playback::lumina_playback_get_state_json();
    assert!(!state_ptr2.is_null());
    let state_str2 = unsafe { CStr::from_ptr(state_ptr2).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(state_ptr2) };
    let st2: serde_json::Value = serde_json::from_str(&state_str2).unwrap();
    assert_eq!(st2["state_code"], 2); // Playing
    assert_eq!(st2["current_track_id"], "trk-c1");

    // Pause and Resume via lumina_playback_resume()
    assert_eq!(playback::lumina_playback_pause(), 0);
    assert_eq!(playback::lumina_playback_get_state(), 3);
    assert_eq!(playback::lumina_playback_resume(), 0);
    assert_eq!(playback::lumina_playback_get_state(), 2);

    // Pause and Resume via lumina_playback_play(null)
    assert_eq!(playback::lumina_playback_pause(), 0);
    assert_eq!(playback::lumina_playback_get_state(), 3);
    assert_eq!(playback::lumina_playback_play(std::ptr::null()), 0);
    assert_eq!(playback::lumina_playback_get_state(), 2);

    // Seek
    assert_eq!(playback::lumina_playback_seek(10_000), 0);
    assert_eq!(playback::lumina_playback_get_position_ms(), 10_000);

    // Reconnect device
    assert_eq!(playback::lumina_playback_reconnect_device(), 0);

    assert_eq!(playback::lumina_playback_stop(), 0);
    assert_eq!(lumina_shutdown(), 0);
}

#[test]
fn test_ffi_contract2_artwork_and_rescan() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_c2_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let db_path = tmp_dir.join("library.db");
    let c_db = CString::new(db_path.to_string_lossy().to_string()).unwrap();
    assert_eq!(library::lumina_library_init(c_db.as_ptr()), 0);

    // Write a dummy wav and dummy cover.jpg
    let wav_file = tmp_dir.join("test_art.wav");
    write_test_wav(&wav_file, 44_100, 2, 44_100);
    let cover_file = tmp_dir.join("cover.jpg");
    // Minimal valid JPEG header bytes
    let dummy_jpg = [
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01,
        0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06,
        0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D,
        0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D,
        0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28,
        0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01,
        0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01,
        0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02,
        0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01,
        0x01, 0x00, 0x00, 0x3F, 0x00, 0xBF, 0x00, 0xFF, 0xD9,
    ];
    std::fs::write(&cover_file, &dummy_jpg).unwrap();

    // Scan dir
    let c_dir = CString::new(tmp_dir.to_string_lossy().to_string()).unwrap();
    let scan_ptr = library::lumina_library_scan_dir(c_dir.as_ptr());
    assert!(!scan_ptr.is_null());
    unsafe { lumina_string_free(scan_ptr) };

    // Query tracks
    let tracks_ptr = library::lumina_library_get_tracks(10);
    assert!(!tracks_ptr.is_null());
    let tracks_str = unsafe { CStr::from_ptr(tracks_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(tracks_ptr) };
    let tracks_val: serde_json::Value = serde_json::from_str(&tracks_str).unwrap();
    assert!(tracks_val.as_array().is_some_and(|arr| !arr.is_empty()));
    let trk0 = &tracks_val[0];
    assert!(trk0.get("bit_depth").is_some());
    assert!(trk0.get("sample_rate_hz").is_some());
    assert!(trk0.get("channels").is_some());
    assert!(trk0.get("codec").is_some());
    assert!(trk0.get("is_dsd").is_some());
    assert!(trk0.get("has_lyrics").is_some());

    // Artwork get
    let target = serde_json::json!({
        "file_path": wav_file.to_string_lossy(),
    })
    .to_string();
    let c_target = CString::new(target).unwrap();
    let art_ptr = library::lumina_artwork_get(c_target.as_ptr(), 256);
    assert!(!art_ptr.is_null());
    let art_str = unsafe { CStr::from_ptr(art_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(art_ptr) };
    let art_val: serde_json::Value = serde_json::from_str(&art_str).unwrap();
    assert!(art_val.get("found").is_some());
    assert!(art_val.get("source_kind").is_some());

    // User cover set and clear
    let manual_cover = tmp_dir.join("manual_cover.png");
    // Minimal 1x1 PNG bytes
    let dummy_png = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
        0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
        0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
        0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    std::fs::write(&manual_cover, &dummy_png).unwrap();
    let c_manual = CString::new(manual_cover.to_string_lossy().to_string()).unwrap();

    assert_eq!(
        library::lumina_artwork_set_user_cover(c_target.as_ptr(), c_manual.as_ptr()),
        0
    );
    assert_eq!(
        library::lumina_artwork_clear_user_cover(c_target.as_ptr()),
        0
    );

    // Rescan tags
    let rescan_ptr = library::lumina_library_rescan_tags(c_dir.as_ptr(), 0);
    assert!(!rescan_ptr.is_null());
    let rescan_str = unsafe { CStr::from_ptr(rescan_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(rescan_ptr) };
    let rescan_val: serde_json::Value = serde_json::from_str(&rescan_str).unwrap();
    assert!(rescan_val.get("scanned").is_some());

    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(tmp_dir);
}

#[test]
fn test_ffi_contract3_lyrics() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_c3_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let db_path = tmp_dir.join("library.db");
    let c_db = CString::new(db_path.to_string_lossy().to_string()).unwrap();
    assert_eq!(library::lumina_library_init(c_db.as_ptr()), 0);

    // Write a dummy audio file and sidecar LRC
    let wav_file = tmp_dir.join("track_lyr.wav");
    write_test_wav(&wav_file, 44_100, 2, 44_100);
    let lrc_file = tmp_dir.join("track_lyr.lrc");
    let lrc_content = "[00:01.00]First line of lyric\n[00:03.50]Second line of lyric\n";
    std::fs::write(&lrc_file, lrc_content).unwrap();

    let target = serde_json::json!({
        "file_path": wav_file.to_string_lossy(),
    })
    .to_string();
    let c_target = CString::new(target).unwrap();

    // Query lyrics -> sidecar_lrc
    let lyr_ptr = lyrics::lumina_lyrics_get(c_target.as_ptr());
    assert!(!lyr_ptr.is_null());
    let lyr_str = unsafe { CStr::from_ptr(lyr_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(lyr_ptr) };
    let lyr_val: serde_json::Value = serde_json::from_str(&lyr_str).unwrap();
    assert_eq!(lyr_val["found"], true);
    assert_eq!(lyr_val["source"], "sidecar_lrc");
    assert_eq!(lyr_val["kind"], "synced");
    assert!(lyr_val["lines"].as_array().is_some_and(|l| l.len() >= 2));

    // User lyrics override
    let user_lrc = tmp_dir.join("user_override.lrc");
    std::fs::write(&user_lrc, "[00:00.50]User lyric override\n").unwrap();
    let c_user_lrc = CString::new(user_lrc.to_string_lossy().to_string()).unwrap();

    assert_eq!(
        lyrics::lumina_lyrics_set_user_file(c_target.as_ptr(), c_user_lrc.as_ptr()),
        0
    );

    let lyr_ptr2 = lyrics::lumina_lyrics_get(c_target.as_ptr());
    assert!(!lyr_ptr2.is_null());
    let lyr_str2 = unsafe { CStr::from_ptr(lyr_ptr2).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(lyr_ptr2) };
    let lyr_val2: serde_json::Value = serde_json::from_str(&lyr_str2).unwrap();
    assert_eq!(lyr_val2["source"], "user_file");

    // Clear override
    assert_eq!(lyrics::lumina_lyrics_clear_user_file(c_target.as_ptr()), 0);

    let lyr_ptr3 = lyrics::lumina_lyrics_get(c_target.as_ptr());
    assert!(!lyr_ptr3.is_null());
    let lyr_str3 = unsafe { CStr::from_ptr(lyr_ptr3).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(lyr_ptr3) };
    let lyr_val3: serde_json::Value = serde_json::from_str(&lyr_str3).unwrap();
    assert_eq!(lyr_val3["source"], "sidecar_lrc");

    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(tmp_dir);
}
