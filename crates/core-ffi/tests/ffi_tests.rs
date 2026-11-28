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
    assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));

    let c_ver = lumina_version();
    assert!(!c_ver.is_null());
    let s = unsafe { CStr::from_ptr(c_ver).to_str().unwrap() };
    assert_eq!(s, env!("CARGO_PKG_VERSION"));
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

    let upd_c =
        CString::new(r##"{"name":"NightModeV2","avatar_color":"#10B981","is_default":false}"##)
            .unwrap();
    assert_eq!(
        profiles::lumina_profile_update(p2_c.as_ptr(), upd_c.as_ptr()),
        0
    );
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
    let autoeq_c =
        CString::new("Preamp: -4.2 dB\nFilter 1: ON PK Fc 250 Hz Gain 2.5 dB Q 1.2\n").unwrap();
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

    let start = std::time::Instant::now();
    let mut pos = 0;
    while start.elapsed() < std::time::Duration::from_millis(1500) {
        pos = playback::lumina_playback_get_position_ms();
        if pos > 0 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
    }
    assert!(pos > 0, "Playback position should advance within 1.5s");

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

    let bad_json = CString::new(
        r#"{"id":"bad-1","title":"Missing","file_path":"/definitely/missing/audio_12345.wav"}"#,
    )
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
    assert_eq!(
        info_val["verification"]["sample_hash_match"],
        serde_json::json!(true)
    );
    assert_eq!(
        info_val["verification"]["status"],
        serde_json::json!("PCM UNMODIFIED")
    );

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
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00,
        0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06,
        0x05, 0x08, 0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B,
        0x0C, 0x19, 0x12, 0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31,
        0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF,
        0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00,
        0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
        0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xBF, 0x00, 0xFF, 0xD9,
    ];
    std::fs::write(&cover_file, dummy_jpg).unwrap();

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
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
        0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00,
        0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    std::fs::write(&manual_cover, dummy_png).unwrap();
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

#[test]
fn test_ffi_play_async_non_blocking_and_superseding_cancellation() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // Local stalled TCP listener that accepts connections and never sends HTTP bytes.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let stalled_port = listener.local_addr().unwrap().port();
    let server_stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let server_stop_bg = server_stop.clone();
    listener.set_nonblocking(true).unwrap();
    let server_handle = std::thread::spawn(move || {
        let mut held_sockets = Vec::new();
        while !server_stop_bg.load(std::sync::atomic::Ordering::SeqCst) {
            if let Ok((sock, _)) = listener.accept() {
                held_sockets.push(sock);
            }
            std::thread::sleep(std::time::Duration::from_millis(15));
        }
    });

    let slow_payload = serde_json::json!({
        "id": "trk-slow-101",
        "title": "Slow Hung Stream",
        "stream_url": format!("http://127.0.0.1:{stalled_port}/hung.flac"),
        "duration_ms": 120_000,
    })
    .to_string();
    let c_slow = CString::new(slow_payload).unwrap();

    let t0 = std::time::Instant::now();
    assert_eq!(lumina_playback_play_async(c_slow.as_ptr(), 101), 0);
    let elapsed_ms = t0.elapsed().as_millis();
    assert!(
        elapsed_ms < 50,
        "lumina_playback_play_async blocked for {elapsed_ms}ms (expected < 50ms)"
    );
    assert_eq!(lumina_playback_get_active_request_id(), 101);
    assert_eq!(lumina_playback_get_state(), 5);

    let state_ptr1 = lumina_playback_get_state_json();
    let state_str1 = unsafe { CStr::from_ptr(state_ptr1).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(state_ptr1) };
    let v1: serde_json::Value = serde_json::from_str(&state_str1).unwrap();
    assert_eq!(v1["state_code"], 5);
    assert_eq!(v1["state_name"], "Loading");
    assert_eq!(v1["play_request_id"], 101);
    assert_eq!(v1["loaded_request_id"], 0);

    // Supersede request 101 immediately with a fast local WAV track (request 102).
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_async_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav_file = tmp_dir.join("fast_track.wav");
    write_test_wav(&wav_file, 44_100, 2, 44_100);

    let fast_payload = serde_json::json!({
        "id": "trk-fast-102",
        "title": "Fast Local Track",
        "file_path": wav_file.to_string_lossy(),
    })
    .to_string();
    let c_fast = CString::new(fast_payload).unwrap();

    let t1 = std::time::Instant::now();
    assert_eq!(lumina_playback_play_async(c_fast.as_ptr(), 102), 0);
    assert!(t1.elapsed().as_millis() < 50);
    assert_eq!(lumina_playback_get_active_request_id(), 102);

    let mut settled = None;
    for _ in 0..80 {
        let p = lumina_playback_get_state_json();
        let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(p) };
        let val: serde_json::Value = serde_json::from_str(&s).unwrap();
        if val["loaded_request_id"] == 102 && val["state_code"] == 2 {
            settled = Some(val);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    let settled = settled.expect("request 102 should settle into Playing state");
    assert_eq!(settled["current_track_id"], "trk-fast-102");
    assert_eq!(settled["play_request_id"], 102);

    // Verify explicit cancel_pending exits Loading cleanly.
    assert_eq!(lumina_playback_play_async(c_slow.as_ptr(), 103), 0);
    assert_eq!(lumina_playback_get_state(), 5);
    assert_eq!(lumina_playback_cancel_pending(103), 0);
    assert_eq!(lumina_playback_get_state(), 1);
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert_eq!(lumina_playback_get_state(), 1);

    server_stop.store(true, std::sync::atomic::Ordering::SeqCst);
    let _ = server_handle.join();
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(tmp_dir);
}

#[test]
fn test_ffi_sync_play_followed_by_async_request_id_one_and_zero_rejection() {
    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_sync_then_async_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav1 = tmp_dir.join("sync_1.wav");
    let wav2 = tmp_dir.join("sync_2.wav");
    write_test_wav(&wav1, 44_100, 2, 44_100);
    write_test_wav(&wav2, 44_100, 2, 44_100);

    for (id, path) in [("trk-sync-1", &wav1), ("trk-sync-2", &wav2)] {
        let sync_json = serde_json::json!({
            "id": id,
            "title": id,
            "file_path": path.to_string_lossy(),
        })
        .to_string();
        let c_sync = CString::new(sync_json).unwrap();
        assert_eq!(lumina_playback_play(c_sync.as_ptr()), 0);
    }

    // request_id == 0 must be rejected cleanly.
    let bad_json = CString::new(r#"{"id":"bad","title":"Bad"}"#).unwrap();
    assert_ne!(lumina_playback_play_async(bad_json.as_ptr(), 0), 0);

    // Local stalled TCP listener to keep request_id = 1 in Loading while checking state.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let stalled_port = listener.local_addr().unwrap().port();
    let server_stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let server_stop_bg = server_stop.clone();
    listener.set_nonblocking(true).unwrap();
    let server_handle = std::thread::spawn(move || {
        let mut held = Vec::new();
        while !server_stop_bg.load(std::sync::atomic::Ordering::SeqCst) {
            if let Ok((sock, _)) = listener.accept() {
                held.push(sock);
            }
            std::thread::sleep(std::time::Duration::from_millis(15));
        }
    });

    // After sync play calls, coordinator's first async request_id = 1 MUST still report Loading (5).
    let async_json = serde_json::json!({
        "id": "trk-async-1",
        "title": "Async After Sync",
        "stream_url": format!("http://127.0.0.1:{stalled_port}/stalled.flac"),
        "duration_ms": 90_000,
    })
    .to_string();
    let c_async = CString::new(async_json).unwrap();
    assert_eq!(lumina_playback_play_async(c_async.as_ptr(), 1), 0);
    assert_eq!(lumina_playback_get_active_request_id(), 1);
    assert_eq!(lumina_playback_get_state(), 5);

    let p = lumina_playback_get_state_json();
    let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(p) };
    let val: serde_json::Value = serde_json::from_str(&s).unwrap();
    assert_eq!(val["state_code"], 5);
    assert_eq!(val["state_name"], "Loading");
    assert_eq!(val["play_request_id"], 1);
    assert_eq!(val["loaded_request_id"], 0);

    assert_eq!(lumina_playback_cancel_pending(1), 0);
    assert_eq!(lumina_playback_get_state(), 1);

    server_stop.store(true, std::sync::atomic::Ordering::SeqCst);
    let _ = server_handle.join();
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(tmp_dir);
}

#[test]
fn test_ffi_http_headers_and_403_surfacing_sync_and_async() {
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    };

    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // Build a 384 KiB WAV (> 2 chunks of 128 KiB) for multi-Range verification.
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_http_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav_path = tmp_dir.join("fixture.wav");
    write_test_wav(&wav_path, 48_000, 2, 96_000);
    let wav_bytes = Arc::new(std::fs::read(&wav_path).unwrap());

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let server_stop = Arc::new(AtomicBool::new(false));
    let server_stop_bg = Arc::clone(&server_stop);
    let valid_range_hits = Arc::new(AtomicUsize::new(0));
    let valid_range_hits_srv = Arc::clone(&valid_range_hits);

    let server_handle = std::thread::spawn(move || {
        while !server_stop_bg.load(Ordering::SeqCst) {
            let Ok((mut stream, _)) = listener.accept() else {
                std::thread::sleep(std::time::Duration::from_millis(10));
                continue;
            };
            let _ = stream.set_nonblocking(false);
            let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
            let wav_bytes = Arc::clone(&wav_bytes);
            let range_hits = Arc::clone(&valid_range_hits_srv);
            std::thread::spawn(move || {
                let mut buf = [0u8; 16384];
                loop {
                    let mut total_read = 0;
                    loop {
                        let Ok(n) = stream.read(&mut buf[total_read..]) else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        total_read += n;
                        if let Some(end_pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            total_read = end_pos + 4;
                            break;
                        }
                        if total_read == buf.len() {
                            break;
                        }
                    }
                    let req_str = String::from_utf8_lossy(&buf[..total_read]);
                    let first_line = req_str.lines().next().unwrap_or("");
                    let mut parts = first_line.split_whitespace();
                    let method = parts.next().unwrap_or("GET");
                    let path = parts.next().unwrap_or("/");
                    let mut hdrs = std::collections::HashMap::new();
                    for line in req_str.lines().skip(1) {
                        if let Some((k, v)) = line.split_once(':') {
                            hdrs.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                        }
                    }

                    let headers_ok = hdrs.get("user-agent").map(String::as_str)
                        == Some("YtmTestAgent/1.0")
                        && hdrs.get("accept").map(String::as_str)
                            == Some("text/html,application/xhtml+xml,*/*;q=0.8")
                        && hdrs.get("accept-language").map(String::as_str)
                            == Some("en-US,en;q=0.9");

                    let total_len = wav_bytes.len();
                    if path == "/open-403.wav" || !headers_ok {
                        let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                        if stream.write_all(resp.as_bytes()).is_err() {
                            return;
                        }
                    } else if path == "/ok.wav" || path == "/mid-403.wav" {
                        if method == "HEAD" {
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                            );
                            if stream.write_all(resp.as_bytes()).is_err() {
                                return;
                            }
                        } else if let Some(range_val) = hdrs.get("range")
                            && let Some(spec) = range_val.strip_prefix("bytes=")
                            && let Some((s_str, e_str)) = spec.split_once('-')
                        {
                            let start = s_str.parse::<usize>().unwrap_or(0);
                            if path == "/mid-403.wav" && start >= 131_072 {
                                let resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                                if stream.write_all(resp.as_bytes()).is_err() {
                                    return;
                                }
                            } else {
                                let start = start.min(total_len - 1);
                                let end = e_str
                                    .parse::<usize>()
                                    .unwrap_or(total_len - 1)
                                    .min(total_len - 1);
                                range_hits.fetch_add(1, Ordering::Relaxed);
                                let slice = &wav_bytes[start..=end];
                                let resp = format!(
                                    "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                                    slice.len()
                                );
                                if stream.write_all(resp.as_bytes()).is_err()
                                    || stream.write_all(slice).is_err()
                                {
                                    return;
                                }
                            }
                        }
                    }
                    let _ = stream.flush();
                }
            });
        }
    });

    let valid_headers = serde_json::json!({
        "User-Agent": "YtmTestAgent/1.0",
        "Accept": "text/html,application/xhtml+xml,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    });

    let read_state_json = || -> serde_json::Value {
        let p = lumina_playback_get_state_json();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(p) };
        serde_json::from_str(&s).unwrap()
    };

    // 1. Async play with valid headers succeeds (server rejects missing headers with 403).
    let ok_payload = serde_json::json!({
        "id": "ytm:ok-1",
        "title": "Valid Header Stream",
        "stream_url": format!("http://{addr}/ok.wav"),
        "headers": valid_headers,
        "hint_extension": "wav",
        "source": "YouTube Music",
    })
    .to_string();
    let c_ok = CString::new(ok_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_ok.as_ptr(), 1), 0);

    let mut settled_ok = None;
    for _ in 0..80 {
        let st = read_state_json();
        if st["loaded_request_id"] == 1 && st["state_code"] == 2 {
            settled_ok = Some(st);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    assert!(
        settled_ok.is_some(),
        "Expected async stream with valid headers to reach Playing state"
    );
    assert!(valid_range_hits.load(Ordering::Relaxed) >= 1);
    assert_eq!(playback::lumina_playback_stop(), 0);

    // 2. Async play with open-time 403 surfaces state_code == 4 and "HTTP 403" in last_error.
    let open_403_payload = serde_json::json!({
        "id": "ytm:open-403",
        "title": "Open 403",
        "stream_url": format!("http://{addr}/open-403.wav"),
        "headers": valid_headers,
        "hint_extension": "wav",
        "source": "YouTube Music",
    })
    .to_string();
    let c_open_403 = CString::new(open_403_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_open_403.as_ptr(), 2), 0);

    let mut settled_open_err = None;
    for _ in 0..80 {
        let st = read_state_json();
        if st["loaded_request_id"] == 2 && st["state_code"] == 4 {
            settled_open_err = Some(st);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    let open_err_state = settled_open_err.expect("open 403 must reach Error state (4)");
    assert_eq!(open_err_state["state_name"], "Error");
    let open_err_str = open_err_state["last_error"].as_str().unwrap_or("");
    assert!(
        open_err_str.contains("HTTP 403"),
        "Expected 'HTTP 403' in async open last_error, got: {open_err_str}"
    );
    let err_msg_ptr = lumina_last_error_message();
    assert!(!err_msg_ptr.is_null());
    let err_msg = unsafe { CStr::from_ptr(err_msg_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(err_msg_ptr) };
    assert!(err_msg.contains("HTTP 403"));
    assert!(lumina_last_error_message().is_null());

    // 3. Async play that opens OK on chunk 0 then hits HTTP 403 on mid-stream Range chunk 1.
    let mid_403_payload = serde_json::json!({
        "id": "ytm:mid-403",
        "title": "Mid 403",
        "stream_url": format!("http://{addr}/mid-403.wav"),
        "headers": valid_headers,
        "hint_extension": "wav",
        "source": "YouTube Music",
    })
    .to_string();
    let c_mid_403 = CString::new(mid_403_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_mid_403.as_ptr(), 3), 0);

    let mut settled_mid_err = None;
    for _ in 0..100 {
        let st = read_state_json();
        if st["loaded_request_id"] == 3 && st["state_code"] == 4 {
            settled_mid_err = Some(st);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    let mid_err_state = settled_mid_err.expect("mid-stream Range 403 must reach Error state (4)");
    assert_eq!(mid_err_state["state_name"], "Error");
    let mid_err_str = mid_err_state["last_error"].as_str().unwrap_or("");
    assert!(
        mid_err_str.contains("HTTP 403"),
        "Expected 'HTTP 403' in mid-stream last_error, got: {mid_err_str}"
    );

    // 4. Sync play with open-time 403 returns non-zero and preserves "HTTP 403" in last error & state JSON.
    let rc_sync = playback::lumina_playback_play(c_open_403.as_ptr());
    assert_eq!(rc_sync, error::LUMINA_ERR_AUDIO_BACKEND);
    let sync_state = read_state_json();
    assert_eq!(sync_state["state_code"], 4);
    assert!(
        sync_state["last_error"]
            .as_str()
            .unwrap_or("")
            .contains("HTTP 403")
    );
    let sync_err_ptr = lumina_last_error_message();
    assert!(!sync_err_ptr.is_null());
    let sync_err = unsafe { CStr::from_ptr(sync_err_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(sync_err_ptr) };
    assert!(sync_err.contains("HTTP 403"));
    assert!(lumina_last_error_message().is_null());

    server_stop.store(true, Ordering::SeqCst);
    let _ = server_handle.join();
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(tmp_dir);
}

#[test]
fn test_ffi_source_spec_epoch_and_external_backend_rejection() {
    use core_types::{StreamKey, StreamSourceSpec};
    use std::collections::BTreeMap;
    use std::io::{Read, Write};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    // Build an in-memory WAV (~1.5s stereo 44.1 kHz) served over HTTP Range
    let sample_rate = 44_100u32;
    let channels = 2u16;
    let num_frames = 66_150u32;
    let mut wav_bytes = Vec::new();
    let block_align = channels * 2;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = num_frames * (block_align as u32);
    wav_bytes.extend_from_slice(b"RIFF");
    wav_bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav_bytes.extend_from_slice(b"WAVEfmt ");
    wav_bytes.extend_from_slice(&16u32.to_le_bytes());
    wav_bytes.extend_from_slice(&1u16.to_le_bytes());
    wav_bytes.extend_from_slice(&channels.to_le_bytes());
    wav_bytes.extend_from_slice(&sample_rate.to_le_bytes());
    wav_bytes.extend_from_slice(&byte_rate.to_le_bytes());
    wav_bytes.extend_from_slice(&block_align.to_le_bytes());
    wav_bytes.extend_from_slice(&16u16.to_le_bytes());
    wav_bytes.extend_from_slice(b"data");
    wav_bytes.extend_from_slice(&data_len.to_le_bytes());
    for n in 0..num_frames {
        let t = n as f64 / sample_rate as f64;
        let sample = ((2.0 * PI * 440.0 * t).sin() * 20000.0) as i16;
        for _ in 0..channels {
            wav_bytes.extend_from_slice(&sample.to_le_bytes());
        }
    }
    let wav_bytes = Arc::new(wav_bytes);

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let server_stop = Arc::new(AtomicBool::new(false));
    let stop_bg = Arc::clone(&server_stop);
    let server_handle = std::thread::spawn(move || {
        while !stop_bg.load(Ordering::Relaxed) {
            let Ok((mut stream, _)) = listener.accept() else {
                std::thread::sleep(std::time::Duration::from_millis(10));
                continue;
            };
            let _ = stream.set_nonblocking(false);
            let wav = Arc::clone(&wav_bytes);
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                loop {
                    let mut total_read = 0;
                    loop {
                        let Ok(n) = stream.read(&mut buf[total_read..]) else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        total_read += n;
                        if let Some(pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            total_read = pos + 4;
                            break;
                        }
                    }
                    let req = String::from_utf8_lossy(&buf[..total_read]);
                    let first = req.lines().next().unwrap_or("");
                    let mut parts = first.split_whitespace();
                    let method = parts.next().unwrap_or("GET");
                    let path = parts.next().unwrap_or("/");
                    if path == "/stalled.wav" && method == "GET" {
                        std::thread::sleep(std::time::Duration::from_secs(2));
                        return;
                    }
                    let total_len = wav.len();
                    if method == "HEAD" {
                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                        );
                        let _ = stream.write_all(hdr.as_bytes());
                    } else if let Some(range_line) = req
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        && let Some(spec) = range_line.split_once(':').map(|(_, v)| v.trim())
                        && let Some((s, e)) =
                            spec.strip_prefix("bytes=").and_then(|r| r.split_once('-'))
                    {
                        let start = s.parse::<usize>().unwrap_or(0).min(total_len - 1);
                        let end = e
                            .parse::<usize>()
                            .unwrap_or(total_len - 1)
                            .min(total_len - 1);
                        let slice = &wav[start..=end];
                        let hdr = format!(
                            "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                            slice.len()
                        );
                        if stream.write_all(hdr.as_bytes()).is_err()
                            || stream.write_all(slice).is_err()
                        {
                            return;
                        }
                    } else {
                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                        );
                        if stream.write_all(hdr.as_bytes()).is_err()
                            || stream.write_all(&wav).is_err()
                        {
                            return;
                        }
                    }
                    let _ = stream.flush();
                }
            });
        }
    });

    let read_state_json = || -> serde_json::Value {
        let p = lumina_playback_get_state_json();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(p) };
        serde_json::from_str(&s).unwrap()
    };

    // 1. ExternalBackend must be explicitly rejected by both play_async and sync play.
    let ext_spec = StreamSourceSpec::ExternalBackend {
        key: StreamKey::new("spotify", "sp-track-ffi", "very_high"),
        provider_id: "spotify".to_string(),
        track_uri: "spotify:track:sp-track-ffi".to_string(),
        external_web_url: None,
        notice: None,
        preview_url: None,
    };
    let ext_payload = serde_json::json!({
        "id": "sp-track-ffi",
        "epoch": 1,
        "source_spec": ext_spec,
    })
    .to_string();
    let c_ext = CString::new(ext_payload).unwrap();
    assert_ne!(lumina_playback_play_async(c_ext.as_ptr(), 1), 0);
    let err_ptr = lumina_last_error_message();
    assert!(!err_ptr.is_null());
    let err_str = unsafe { CStr::from_ptr(err_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(err_ptr) };
    assert!(err_str.contains("ExternalBackend"));

    assert_ne!(playback::lumina_playback_play(c_ext.as_ptr()), 0);
    let err_ptr2 = lumina_last_error_message();
    assert!(!err_ptr2.is_null());
    unsafe { lumina_string_free(err_ptr2) };

    // 2. Async play with DirectRange StreamSourceSpec + explicit epoch superseded by higher epoch.
    let stalled_spec = StreamSourceSpec::DirectRange {
        key: StreamKey::new("qobuz", "qb-stalled-ffi", "27"),
        url: format!("http://{addr}/stalled.wav"),
        headers: BTreeMap::new(),
        bitrate_bps: None,
        mime_type: Some("audio/wav".to_string()),
        hint_extension: Some("wav".to_string()),
        content_length: None,
        expire_at: None,
        init_range_end: None,
        index_range_start: None,
        index_range_end: None,
        loudness: None,
        album_loudness: None,
    };
    let stalled_payload = serde_json::json!({
        "id": "qb-stalled-ffi",
        "epoch": 10,
        "source": "Qobuz",
        "duration_ms": 1500,
        "source_spec": stalled_spec,
    })
    .to_string();
    let c_stalled = CString::new(stalled_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_stalled.as_ptr(), 10), 0);
    let loading_state = read_state_json();
    assert_eq!(loading_state["state_code"], 5);
    assert_eq!(loading_state["epoch"], 10);

    let ok_spec = StreamSourceSpec::DirectRange {
        key: StreamKey::new("qobuz", "qb-ok-ffi", "27"),
        url: format!("http://{addr}/ok.wav"),
        headers: BTreeMap::new(),
        bitrate_bps: Some(1_411_200),
        mime_type: Some("audio/wav".to_string()),
        hint_extension: Some("wav".to_string()),
        content_length: None,
        expire_at: None,
        init_range_end: None,
        index_range_start: None,
        index_range_end: None,
        loudness: None,
        album_loudness: None,
    };
    let ok_payload = serde_json::json!({
        "id": "qb-ok-ffi",
        "epoch": 25,
        "source": "Qobuz",
        "duration_ms": 1500,
        "source_spec": ok_spec,
    })
    .to_string();
    let c_ok = CString::new(ok_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_ok.as_ptr(), 25), 0);

    let mut settled = None;
    for _ in 0..100 {
        let st = read_state_json();
        if st["loaded_request_id"] == 25 && st["state_code"] == 2 {
            settled = Some(st);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    let settled = settled.unwrap_or_else(|| {
        panic!(
            "DirectRange source_spec play_async should settle into Playing, got: {}",
            read_state_json()
        )
    });
    assert_eq!(settled["current_track_id"], "qb-ok-ffi");
    assert!(settled["epoch"].as_u64().unwrap_or(0) >= 25);

    // Seeking must advance epoch monotonically and surface in get_state_json
    let epoch_before_seek = settled["epoch"].as_u64().unwrap();
    assert_eq!(playback::lumina_playback_seek(500), 0);
    let after_seek = read_state_json();
    assert!(
        after_seek["epoch"].as_u64().unwrap() > epoch_before_seek,
        "Seek must increment exposed state JSON epoch"
    );

    // Sync play with DirectRange StreamSourceSpec + higher epoch also succeeds cleanly
    let sync_spec = StreamSourceSpec::DirectRange {
        key: StreamKey::new("qobuz", "qb-sync-ffi", "27"),
        url: format!("http://{addr}/sync.wav"),
        headers: BTreeMap::new(),
        bitrate_bps: Some(1_411_200),
        mime_type: Some("audio/wav".to_string()),
        hint_extension: Some("wav".to_string()),
        content_length: None,
        expire_at: None,
        init_range_end: None,
        index_range_start: None,
        index_range_end: None,
        loudness: None,
        album_loudness: None,
    };
    let sync_payload = serde_json::json!({
        "id": "qb-sync-ffi",
        "epoch": 40,
        "source": "Qobuz",
        "source_spec": sync_spec,
    })
    .to_string();
    let c_sync = CString::new(sync_payload).unwrap();
    assert_eq!(playback::lumina_playback_play(c_sync.as_ptr()), 0);
    let after_sync = read_state_json();
    assert_eq!(after_sync["state_code"], 2);
    assert_eq!(after_sync["current_track_id"], "qb-sync-ffi");
    assert!(after_sync["epoch"].as_u64().unwrap() >= 40);

    // Out-of-order stale explicit epoch (5 < 40) must be silently dropped without disturbing qb-sync-ffi.
    let stale_payload = serde_json::json!({
        "id": "qb-stale-ffi",
        "epoch": 5,
        "source": "Qobuz",
        "source_spec": sync_spec,
    })
    .to_string();
    let c_stale = CString::new(stale_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_stale.as_ptr(), 5), 0);
    let after_stale = read_state_json();
    assert_eq!(after_stale["state_code"], 2);
    assert_eq!(after_stale["current_track_id"], "qb-sync-ffi");
    assert!(after_stale["epoch"].as_u64().unwrap() >= 40);

    assert_eq!(playback::lumina_playback_stop(), 0);
    let after_stop = read_state_json();
    assert!(after_stop["epoch"].as_u64().unwrap() > 40);

    server_stop.store(true, Ordering::SeqCst);
    let _ = server_handle.join();
    assert_eq!(lumina_shutdown(), 0);
}

#[test]
fn test_phase2_l1_cache_and_sidecar_ffi() {
    let _guard = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let _ = lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_l1_test_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let db_path = tmp_dir.join("l1_ffi.db");
    let c_db_path = CString::new(db_path.to_str().unwrap()).unwrap();
    assert_eq!(lumina_library_init(c_db_path.as_ptr()), 0);

    let rec_fresh = serde_json::json!({
        "provider_id": "youtube_music",
        "track_id": "dQw4w9WgXcQ",
        "quality_key": "default",
        "stream_type": "direct_range",
        "url_or_manifest": "https://rr1.googlevideo.com/videoplayback?itag=251",
        "headers_json": r#"{"User-Agent":"Lumina/2.0"}"#,
        "mime_type": r#"audio/webm; codecs="opus""#,
        "bitrate_bps": 160000,
        "content_length": 5200000,
        "init_range_end": 740,
        "index_range_start": 741,
        "index_range_end": 1105,
        "expire_at": 2_000_000_000i64,
        "network_epoch": 1,
        "updated_at": 1_700_000_000i64,
        "extra_json": r#"{"hint_extension":"webm"}"#,
    })
    .to_string();
    let c_fresh = CString::new(rec_fresh).unwrap();
    assert_eq!(lumina_l1_cache_upsert(c_fresh.as_ptr()), 0);

    let rec_expired = serde_json::json!({
        "provider_id": "qobuz",
        "track_id": "999",
        "quality_key": "27",
        "stream_type": "direct_range",
        "url_or_manifest": "https://cdn.qobuz.com/expired.flac",
        "headers_json": "{}",
        "expire_at": 1_600_000_000i64,
        "network_epoch": 1,
        "updated_at": 1_599_000_000i64,
    })
    .to_string();
    let c_expired = CString::new(rec_expired).unwrap();
    assert_eq!(lumina_l1_cache_upsert(c_expired.as_ptr()), 0);

    // Load unexpired flushes FIFO writes and filters expired rows
    let ptr = lumina_l1_cache_load_unexpired(1_900_000_000);
    assert!(!ptr.is_null());
    let json_str = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(ptr) };
    let rows: Vec<serde_json::Value> = serde_json::from_str(&json_str).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["provider_id"], "youtube_music");
    assert_eq!(rows[0]["track_id"], "dQw4w9WgXcQ");
    assert_eq!(rows[0]["init_range_end"], 740);
    assert_eq!(rows[0]["index_range_start"], 741);
    assert_eq!(rows[0]["index_range_end"], 1105);

    // Delete removes the entry
    let c_pid = CString::new("youtube_music").unwrap();
    let c_tid = CString::new("dQw4w9WgXcQ").unwrap();
    let c_qk = CString::new("default").unwrap();
    assert_eq!(
        lumina_l1_cache_delete(c_pid.as_ptr(), c_tid.as_ptr(), c_qk.as_ptr()),
        0
    );

    let ptr_after = lumina_l1_cache_load_unexpired(1_900_000_000);
    assert!(!ptr_after.is_null());
    let after_str = unsafe { CStr::from_ptr(ptr_after).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(ptr_after) };
    let rows_after: Vec<serde_json::Value> = serde_json::from_str(&after_str).unwrap();
    assert!(rows_after.is_empty());

    // Sidecar job validation & H2 warmup smoke check
    assert_ne!(lumina_sidecar_assign_job(0), 0);
    assert_eq!(lumina_streaming_warmup_h2(), 0);

    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_phase3_ffi_error_codes_provider_cancel_and_clean_shutdown() {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;
    use std::time::Duration;

    let _guard = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let _ = lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let read_state_json = || -> serde_json::Value {
        let ptr = playback::lumina_playback_get_state_json();
        assert!(!ptr.is_null());
        let s = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(ptr) };
        serde_json::from_str(&s).unwrap()
    };

    // Build a valid 48 kHz WAV in memory and serve both 200/206 and 401 endpoints
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_phase3_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav_tmp = tmp_dir.join("stream.wav");
    write_test_wav(&wav_tmp, 48_000, 2, 48_000 * 3);
    let wav_bytes = std::fs::read(&wav_tmp).unwrap();
    let wav_len = wav_bytes.len() as u64;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    let stop_srv = Arc::new(AtomicBool::new(false));
    let stop_bg = Arc::clone(&stop_srv);
    let srv_bytes = Arc::new(wav_bytes);
    let srv_handle = thread::spawn(move || {
        while !stop_bg.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((mut s, _)) => {
                    let _ = s.set_nonblocking(false);
                    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
                    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
                    let body = Arc::clone(&srv_bytes);
                    thread::spawn(move || {
                        let mut buf = [0u8; 8192];
                        loop {
                            let mut total_read = 0;
                            loop {
                                let Ok(n) = s.read(&mut buf[total_read..]) else {
                                    return;
                                };
                                if n == 0 {
                                    return;
                                }
                                total_read += n;
                                if let Some(pos) =
                                    buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                                {
                                    total_read = pos + 4;
                                    break;
                                }
                                if total_read >= buf.len() {
                                    return;
                                }
                            }
                            let req = String::from_utf8_lossy(&buf[..total_read]);
                            let first = req.lines().next().unwrap_or("");
                            let mut parts = first.split_whitespace();
                            let method = parts.next().unwrap_or("GET");
                            let path = parts.next().unwrap_or("/");
                            if path == "/401.wav" {
                                if s.write_all(
                                    b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n",
                                )
                                .is_err()
                                {
                                    return;
                                }
                                let _ = s.flush();
                                continue;
                            }
                            let total = body.len();
                            let range_hdr = req.lines().find_map(|l| {
                                l.to_ascii_lowercase()
                                    .starts_with("range:")
                                    .then(|| l.split_once(':').map(|(_, v)| v.trim().to_string()))
                                    .flatten()
                            });
                            let (start, end, partial) = if let Some(rh) = range_hdr
                                && let Some(spec) = rh.strip_prefix("bytes=")
                            {
                                let (a, b) = spec.split_once('-').unwrap_or(("0", ""));
                                let st = a.parse::<usize>().unwrap_or(0);
                                let en = if b.is_empty() {
                                    total - 1
                                } else {
                                    b.parse::<usize>().unwrap_or(total - 1).min(total - 1)
                                };
                                (st, en, true)
                            } else {
                                (0, total - 1, false)
                            };
                            let slice = &body[start..=end];
                            let hdr = if partial {
                                format!(
                                    "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {start}-{end}/{total}\r\nContent-Length: {}\r\n\r\n",
                                    slice.len()
                                )
                            } else {
                                format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\n\r\n",
                                    slice.len()
                                )
                            };
                            if s.write_all(hdr.as_bytes()).is_err() {
                                return;
                            }
                            if method != "HEAD" && s.write_all(slice).is_err() {
                                return;
                            }
                            let _ = s.flush();
                        }
                    });
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(_) => break,
            }
        }
    });

    // 1. Play youtube_music DirectRange spec via lumina_playback_play_async
    let ytm_payload = serde_json::json!({
        "id": "ytm-p3-1",
        "source": "YouTube Music",
        "source_spec": {
            "kind": "direct_range",
            "key": {
                "provider_id": "youtube_music",
                "track_id": "ytm-p3-1",
                "quality_key": "251"
            },
            "url": format!("http://127.0.0.1:{port}/ok.wav"),
            "headers": {},
            "content_length": wav_len,
            "mime_type": "audio/wav",
            "hint_extension": "wav",
            "loudness": { "gain_db": -4.0, "peak": 0.9 }
        }
    })
    .to_string();
    let c_ytm = CString::new(ytm_payload).unwrap();
    assert_eq!(playback::lumina_playback_play_async(c_ytm.as_ptr(), 101), 0);

    for _ in 0..80 {
        let st = read_state_json();
        if st["loaded_request_id"] == 101 && st["state_code"] == 2 {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    let playing_st = read_state_json();
    assert_eq!(
        playing_st["state_code"], 2,
        "Expected Playing: {playing_st}"
    );
    assert!(playing_st.get("last_error_code").is_some());
    assert!(playing_st.get("last_error_provider").is_some());
    assert!(playing_st["last_error_code"].is_null());
    assert!(playing_st["last_error_provider"].is_null());

    // 2. Cancel provider via FFI circuit breaker -> surfaces AUTH_REQUIRED + youtube_music
    let c_ytm_pid = CString::new("youtube_music").unwrap();
    assert_eq!(lumina_streaming_cancel_provider(c_ytm_pid.as_ptr()), 0);
    let cancelled_st = read_state_json();
    assert_eq!(
        cancelled_st["state_code"], 4,
        "Expected Error: {cancelled_st}"
    );
    assert_eq!(cancelled_st["last_error_code"], "AUTH_REQUIRED");
    assert_eq!(cancelled_st["last_error_provider"], "youtube_music");

    // 3. HTTP 401 during lumina_playback_play_async surfaces AUTH_REQUIRED + qobuz
    let qb_401_payload = serde_json::json!({
        "id": "qb-401-1",
        "source": "Qobuz",
        "source_spec": {
            "kind": "direct_range",
            "key": {
                "provider_id": "qobuz",
                "track_id": "qb-401-1",
                "quality_key": "27"
            },
            "url": format!("http://127.0.0.1:{port}/401.wav"),
            "headers": {},
            "mime_type": "audio/wav",
            "hint_extension": "wav"
        }
    })
    .to_string();
    let c_qb = CString::new(qb_401_payload).unwrap();
    assert_eq!(playback::lumina_playback_play_async(c_qb.as_ptr(), 102), 0);

    for _ in 0..80 {
        let st = read_state_json();
        if st["loaded_request_id"] == 102 {
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    let err_401_st = read_state_json();
    assert_eq!(err_401_st["state_code"], 4, "Expected Error: {err_401_st}");
    assert_eq!(err_401_st["last_error_code"], "AUTH_REQUIRED");
    assert_eq!(err_401_st["last_error_provider"], "qobuz");

    // 4. Clean shutdown flushes pending L1 SQLite writes & runs WAL TRUNCATE checkpoint
    let db_path = tmp_dir.join("shutdown_wal.db");
    let c_db_path = CString::new(db_path.to_str().unwrap()).unwrap();
    assert_eq!(lumina_library_init(c_db_path.as_ptr()), 0);
    let rec_json = serde_json::json!({
        "provider_id": "qobuz",
        "track_id": "persist-shutdown-1",
        "quality_key": "27",
        "stream_type": "direct_range",
        "url_or_manifest": "https://cdn.qobuz.com/persist.flac",
        "headers_json": "{}",
        "expire_at": 2_500_000_000i64,
        "network_epoch": 1,
        "updated_at": 1_800_000_000i64,
    })
    .to_string();
    let c_rec = CString::new(rec_json).unwrap();
    assert_eq!(lumina_l1_cache_upsert(c_rec.as_ptr()), 0);

    // Immediately shut down WITHOUT calling lumina_l1_cache_load_unexpired first!
    assert_eq!(lumina_shutdown(), 0);

    // Reopen DB in a fresh engine lifecycle -> record must be durably persisted!
    assert_eq!(lumina_init_headless(), 0);
    assert_eq!(lumina_library_init(c_db_path.as_ptr()), 0);
    let ptr = lumina_l1_cache_load_unexpired(2_000_000_000);
    assert!(!ptr.is_null());
    let loaded_str = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(ptr) };
    let rows: Vec<serde_json::Value> = serde_json::from_str(&loaded_str).unwrap();
    assert_eq!(
        rows.len(),
        1,
        "Pending L1 write must be flushed on shutdown: {rows:?}"
    );
    assert_eq!(rows[0]["track_id"], "persist-shutdown-1");

    assert_eq!(lumina_shutdown(), 0);
    stop_srv.store(true, Ordering::SeqCst);
    let _ = srv_handle.join();
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_phase4_ffi_l2_cache_and_dual_deck_standby_skip() {
    use core_types::{StreamKey, StreamSourceSpec};
    use std::thread;
    use std::time::Duration;

    let _guard = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let _ = lumina_shutdown();

    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_phase4_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let l2_root = tmp_dir.join("l2_custom");
    let c_l2_root = CString::new(l2_root.to_str().unwrap()).unwrap();

    // 1. Before library DB init, L2 cache FFI functions must return LUMINA_ERR_NOT_INITIALIZED.
    let mut total_bytes: u64 = 999;
    assert_eq!(
        lumina_l2_cache_init(c_l2_root.as_ptr(), 0, 0),
        error::LUMINA_ERR_NOT_INITIALIZED
    );
    assert_eq!(
        lumina_l2_cache_total_bytes(&mut total_bytes),
        error::LUMINA_ERR_NOT_INITIALIZED
    );
    assert_eq!(
        lumina_l2_cache_init(std::ptr::null(), 0, 0),
        error::LUMINA_ERR_NULL_POINTER
    );
    assert_eq!(
        lumina_l2_cache_total_bytes(std::ptr::null_mut()),
        error::LUMINA_ERR_NULL_POINTER
    );

    assert_eq!(lumina_init_headless(), 0);
    let db_path = tmp_dir.join("phase4.db");
    let c_db_path = CString::new(db_path.to_str().unwrap()).unwrap();
    assert_eq!(lumina_library_init(c_db_path.as_ptr()), 0);

    // 2. Auto-initialized default L2CacheManager works immediately after lumina_library_init.
    assert_eq!(lumina_l2_cache_total_bytes(&mut total_bytes), 0);
    assert_eq!(total_bytes, 0);

    // 3. Explicit lumina_l2_cache_init reconfigures root_dir & watermarks cleanly.
    assert_eq!(lumina_l2_cache_init(c_l2_root.as_ptr(), 2000, 1000), 0);
    let eng = engine::get_engine();
    let mgr = eng
        .l2_cache_manager
        .read()
        .unwrap()
        .clone()
        .expect("l2_cache_manager must be initialized");
    let key1 = StreamKey::new("qobuz", "ffi_t1", "27");
    let key2 = StreamKey::new("qobuz", "ffi_t2", "27");
    eng.runtime
        .block_on(mgr.store_direct_head(&key1, &vec![1u8; 900], Some(9000), 0))
        .unwrap();
    assert_eq!(lumina_l2_cache_total_bytes(&mut total_bytes), 0);
    assert_eq!(total_bytes, 900);

    // Lookup queues pending access; lumina_l2_cache_flush_access flushes in one transaction.
    let hit = eng
        .runtime
        .block_on(mgr.lookup_direct_head(&key1))
        .unwrap()
        .unwrap();
    drop(hit);
    assert_eq!(lumina_l2_cache_flush_access(), 0);
    assert_eq!(lumina_l2_cache_run_orphan_sweep(), 0);
    assert_eq!(lumina_l2_cache_evict_now(), 0);

    // Push above high watermark (2000) and verify eviction reduces total_bytes <= 1000.
    eng.runtime
        .block_on(mgr.store_direct_head(&key2, &vec![2u8; 1400], Some(9000), 0))
        .unwrap();
    assert_eq!(lumina_l2_cache_evict_now(), 0);
    assert_eq!(lumina_l2_cache_total_bytes(&mut total_bytes), 0);
    assert!(
        total_bytes <= 1000,
        "Expected total_bytes <= 1000, got {total_bytes}"
    );

    // 4. Dual-Deck FFI: play Active track, prepare Standby track, and skip_to_standby().
    let wav1 = tmp_dir.join("active_deck.wav");
    let wav2 = tmp_dir.join("standby_deck.wav");
    write_test_wav(&wav1, 48_000, 2, 48_000 * 4);
    write_test_wav(&wav2, 48_000, 2, 48_000 * 4);

    let read_state_json = || -> serde_json::Value {
        let ptr = lumina_playback_get_state_json();
        assert!(!ptr.is_null());
        let s = unsafe { CStr::from_ptr(ptr).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(ptr) };
        serde_json::from_str(&s).unwrap()
    };

    // Apple Music ExternalBackend must be rejected by lumina_playback_prepare_standby_async!
    let apple_spec = StreamSourceSpec::ExternalBackend {
        key: StreamKey::new("apple_music", "am-999", "lossless"),
        provider_id: "apple_music".to_string(),
        track_uri: "apple:am-999".to_string(),
        external_web_url: None,
        preview_url: None,
        notice: None,
    };
    let apple_payload = serde_json::json!({
        "id": "am-999",
        "epoch": 1,
        "source_spec": apple_spec,
    })
    .to_string();
    let c_apple = CString::new(apple_payload).unwrap();
    assert_eq!(
        lumina_playback_prepare_standby_async(c_apple.as_ptr(), 1),
        error::LUMINA_ERR_AUDIO_BACKEND
    );

    // Before standby is prepared, skip_to_standby returns 0.
    assert_eq!(lumina_playback_skip_to_standby(), 0);

    // Start playing wav1 on Active deck.
    let play1_json = serde_json::json!({
        "id": "trk-deck-1",
        "title": "Deck 1",
        "epoch": 10,
        "source_spec": StreamSourceSpec::LocalFile {
            key: StreamKey::new("local", "trk-deck-1", "native"),
            path: wav1.to_string_lossy().to_string(),
            loudness: None,
            album_loudness: None,
        }
    })
    .to_string();
    let c_play1 = CString::new(play1_json).unwrap();
    assert_eq!(lumina_playback_play(c_play1.as_ptr()), 0);

    let st_playing = read_state_json();
    assert_eq!(st_playing["state_code"], 2);
    assert_eq!(st_playing["active_deck"], "deck_a");
    assert_eq!(st_playing["activeDeck"], "deck_a");
    assert_eq!(st_playing["deck_a_state"], "PLAYING");
    assert_eq!(st_playing["deck_b_state"], "IDLE");

    // Prepare wav2 on Standby deck (Deck B).
    let standby2_json = serde_json::json!({
        "id": "trk-deck-2",
        "title": "Deck 2",
        "epoch": 10,
        "source_spec": StreamSourceSpec::LocalFile {
            key: StreamKey::new("local", "trk-deck-2", "native"),
            path: wav2.to_string_lossy().to_string(),
            loudness: None,
            album_loudness: None,
        }
    })
    .to_string();
    let c_standby2 = CString::new(standby2_json).unwrap();
    assert_eq!(
        lumina_playback_prepare_standby_async(c_standby2.as_ptr(), 10),
        0
    );

    let mut standby_ready = false;
    for _ in 0..80 {
        let st = read_state_json();
        if st["deck_b_state"] == "STANDBY_READY" {
            assert!(st["standby_buffered_ms"].as_u64().unwrap_or(0) >= 1500);
            standby_ready = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        standby_ready,
        "Expected Deck B to reach STANDBY_READY: {}",
        read_state_json()
    );

    // Zero-latency manual skip to standby flips active_deck to deck_b and returns 1.
    assert_eq!(lumina_playback_skip_to_standby(), 1);
    let st_after_skip = read_state_json();
    assert_eq!(st_after_skip["active_deck"], "deck_b");
    assert_eq!(st_after_skip["deck_b_state"], "PLAYING");
    assert!(
        st_after_skip["manual_zero_latency_switches"]
            .as_u64()
            .unwrap_or(0)
            >= 1
    );

    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_ffi_play_async_uses_l2_head_cache_and_commits_adopted_refresh_spec() {
    use core_types::{StreamKey, StreamSourceSpec};
    use std::collections::BTreeMap;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

    static ADOPTED_TEST_URL: Mutex<Option<(String, u64)>> = Mutex::new(None);

    extern "C" fn refresh_to_v2_cb(req_id: u64, req_json_ptr: *mut std::os::raw::c_char) {
        let raw = unsafe { CStr::from_ptr(req_json_ptr).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(req_json_ptr) };
        let req: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let (target_url, target_len) = ADOPTED_TEST_URL
            .lock()
            .unwrap()
            .clone()
            .expect("ADOPTED_TEST_URL must be set");
        let spec = StreamSourceSpec::DirectRange {
            key: StreamKey::new(
                req["provider_id"].as_str().unwrap_or("youtube_music"),
                req["track_id"].as_str().unwrap_or("adopted"),
                req["quality_key"].as_str().unwrap_or("default"),
            ),
            url: target_url,
            headers: BTreeMap::new(),
            content_length: Some(target_len),
            bitrate_bps: Some(1_411_200),
            mime_type: Some("audio/wav".to_string()),
            hint_extension: Some("wav".to_string()),
            expire_at: None,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness: None,
            album_loudness: None,
        };
        let reply = serde_json::json!({
            "status": "refreshed",
            "spec": spec,
        })
        .to_string();
        let c_reply = CString::new(reply).unwrap();
        assert_eq!(lumina_stream_complete_refresh(req_id, c_reply.as_ptr()), 0);
    }

    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let _ = lumina_shutdown();

    let tmp_dir =
        std::env::temp_dir().join(format!("lumina_ffi_async_l2_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav1_path = tmp_dir.join("l2_source.wav");
    let wav2_path = tmp_dir.join("v2_refreshed.wav");
    write_test_wav(&wav1_path, 44_100, 2, 44_100 * 2); // ~352 KiB
    write_test_wav(&wav2_path, 44_100, 2, 44_100 * 3); // ~529 KiB (different content_length)
    let wav1_bytes = Arc::new(std::fs::read(&wav1_path).unwrap());
    let wav2_bytes = Arc::new(std::fs::read(&wav2_path).unwrap());

    let l2_ranges_seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let l2_ranges_srv = Arc::clone(&l2_ranges_seen);
    let w1_srv = Arc::clone(&wav1_bytes);
    let w2_srv = Arc::clone(&wav2_bytes);

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let stop_flag = Arc::new(AtomicBool::new(false));
    let stop_bg = Arc::clone(&stop_flag);
    let srv_handle = std::thread::spawn(move || {
        while !stop_bg.load(Ordering::Relaxed) {
            let Ok((mut stream, _)) = listener.accept() else {
                std::thread::sleep(std::time::Duration::from_millis(10));
                continue;
            };
            let _ = stream.set_nonblocking(false);
            let w1 = Arc::clone(&w1_srv);
            let w2 = Arc::clone(&w2_srv);
            let ranges = Arc::clone(&l2_ranges_srv);
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                loop {
                    let mut total_read = 0;
                    loop {
                        let Ok(n) = stream.read(&mut buf[total_read..]) else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        total_read += n;
                        if let Some(pos) =
                            buf[..total_read].windows(4).position(|w| w == b"\r\n\r\n")
                        {
                            total_read = pos + 4;
                            break;
                        }
                    }
                    let req = String::from_utf8_lossy(&buf[..total_read]);
                    let first = req.lines().next().unwrap_or("");
                    let mut parts = first.split_whitespace();
                    let _method = parts.next().unwrap_or("GET");
                    let path = parts.next().unwrap_or("/");
                    if path == "/expired-403.wav" {
                        let _ = stream
                            .write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
                        let _ = stream.flush();
                        continue;
                    }
                    let payload = if path == "/refreshed-v2.wav" {
                        &w2
                    } else {
                        &w1
                    };
                    let total_len = payload.len();
                    let range_hdr = req
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        .and_then(|l| l.split_once(':'))
                        .map(|(_, v)| v.trim().to_string());
                    if path == "/l2-track.wav"
                        && let Some(ref rh) = range_hdr
                    {
                        ranges.lock().unwrap().push(rh.clone());
                    }
                    if let Some(spec) = range_hdr
                        && let Some((s, e)) =
                            spec.strip_prefix("bytes=").and_then(|r| r.split_once('-'))
                    {
                        let start = s.parse::<usize>().unwrap_or(0).min(total_len - 1);
                        let end = e
                            .parse::<usize>()
                            .unwrap_or(total_len - 1)
                            .min(total_len - 1);
                        let slice = &payload[start..=end];
                        let hdr = format!(
                            "HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Range: bytes {start}-{end}/{total_len}\r\nContent-Length: {}\r\n\r\n",
                            slice.len()
                        );
                        if stream.write_all(hdr.as_bytes()).is_err()
                            || stream.write_all(slice).is_err()
                        {
                            return;
                        }
                    } else {
                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: audio/wav\r\nContent-Length: {total_len}\r\n\r\n"
                        );
                        if stream.write_all(hdr.as_bytes()).is_err()
                            || stream.write_all(payload).is_err()
                        {
                            return;
                        }
                    }
                    let _ = stream.flush();
                }
            });
        }
    });

    assert_eq!(lumina_init_headless(), 0);
    let db_path = tmp_dir.join("async_l2.db");
    let c_db_path = CString::new(db_path.to_str().unwrap()).unwrap();
    assert_eq!(lumina_library_init(c_db_path.as_ptr()), 0);
    let l2_root = tmp_dir.join("l2_dir");
    let c_l2_root = CString::new(l2_root.to_str().unwrap()).unwrap();
    assert_eq!(lumina_l2_cache_init(c_l2_root.as_ptr(), 0, 0), 0);

    let eng = engine::get_engine();
    let mgr = eng
        .l2_cache_manager
        .read()
        .unwrap()
        .clone()
        .expect("l2_cache_manager must be initialized");

    // Pre-populate L2 head cache with first 131_072 bytes of wav1.
    let cached_prefix_len = 131_072usize;
    let l2_key = StreamKey::new("qobuz", "ffi-async-l2", "27");
    eng.runtime
        .block_on(mgr.store_direct_head(
            &l2_key,
            &wav1_bytes[..cached_prefix_len],
            Some(wav1_bytes.len() as u64),
            0,
        ))
        .unwrap();

    let read_state_json = || -> serde_json::Value {
        let p = lumina_playback_get_state_json();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(p) };
        serde_json::from_str(&s).unwrap()
    };

    // 1. lumina_playback_play_async must hit HybridByteStream L2 head cache (overlap starts at 131072 - 64).
    let l2_spec = StreamSourceSpec::DirectRange {
        key: l2_key.clone(),
        url: format!("http://{addr}/l2-track.wav"),
        headers: BTreeMap::new(),
        content_length: Some(wav1_bytes.len() as u64),
        bitrate_bps: Some(1_411_200),
        mime_type: Some("audio/wav".to_string()),
        hint_extension: Some("wav".to_string()),
        expire_at: None,
        init_range_end: None,
        index_range_start: None,
        index_range_end: None,
        loudness: None,
        album_loudness: None,
    };
    let l2_payload = serde_json::json!({
        "id": "ffi-async-l2",
        "epoch": 50,
        "source": "Qobuz",
        "source_spec": l2_spec,
    })
    .to_string();
    let c_l2_payload = CString::new(l2_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_l2_payload.as_ptr(), 1), 0);

    let mut settled_l2 = false;
    for _ in 0..100 {
        let st = read_state_json();
        if st["loaded_request_id"] == 1 && st["state_code"] == 2 {
            settled_l2 = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(
        settled_l2,
        "L2 async play should settle into Playing: {}",
        read_state_json()
    );

    // Wait briefly for HybridByteStream background overlap verification request.
    let expected_overlap_prefix = format!("bytes={}-", cached_prefix_len - 64);
    let mut saw_overlap = false;
    for _ in 0..50 {
        let seen = l2_ranges_seen.lock().unwrap().clone();
        if seen.iter().any(|r| r.starts_with(&expected_overlap_prefix)) {
            saw_overlap = true;
            assert!(
                !seen.iter().any(|r| r.starts_with("bytes=0-")),
                "L2 hit must serve [0, cached_prefix) locally instead of fetching bytes=0-*: {seen:?}"
            );
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(15));
    }
    assert!(
        saw_overlap,
        "Expected HybridByteStream overlap Range starting at {expected_overlap_prefix}, got {:?}",
        l2_ranges_seen.lock().unwrap()
    );

    // 2. lumina_playback_play_async must commit the adopted StreamSourceSpec after initial 403 StreamFormatChanged.
    let v2_url = format!("http://{addr}/refreshed-v2.wav");
    *ADOPTED_TEST_URL.lock().unwrap() = Some((v2_url.clone(), wav2_bytes.len() as u64));
    assert_eq!(
        lumina_stream_set_refresh_callback(Some(refresh_to_v2_cb)),
        0
    );

    let expired_spec = StreamSourceSpec::DirectRange {
        key: StreamKey::new("youtube_music", "ffi-adopted-v2", "default"),
        url: format!("http://{addr}/expired-403.wav"),
        headers: BTreeMap::new(),
        content_length: Some(wav1_bytes.len() as u64), // differs from wav2_bytes.len() -> StreamFormatChanged!
        bitrate_bps: Some(1_411_200),
        mime_type: Some("audio/wav".to_string()),
        hint_extension: Some("wav".to_string()),
        expire_at: None,
        init_range_end: None,
        index_range_start: None,
        index_range_end: None,
        loudness: None,
        album_loudness: None,
    };
    let expired_payload = serde_json::json!({
        "id": "ffi-adopted-v2",
        "epoch": 60,
        "source": "YouTube Music",
        "source_spec": expired_spec,
    })
    .to_string();
    let c_exp = CString::new(expired_payload).unwrap();
    assert_eq!(lumina_playback_play_async(c_exp.as_ptr(), 2), 0);

    let mut settled_v2 = false;
    for _ in 0..150 {
        let st = read_state_json();
        if st["loaded_request_id"] == 2 && st["state_code"] == 2 {
            settled_v2 = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    assert!(
        settled_v2,
        "Refreshed StreamFormatChanged async play must settle into Playing: {}",
        read_state_json()
    );

    let committed_spec = eng
        .player
        .read()
        .unwrap()
        .as_ref()
        .unwrap()
        .active_source_spec()
        .expect("active_source_spec must be committed");
    match committed_spec {
        StreamSourceSpec::DirectRange {
            url,
            content_length,
            ..
        } => {
            assert_eq!(
                url, v2_url,
                "must commit adopted refreshed URL, not stale pre-refresh URL"
            );
            assert_eq!(content_length, Some(wav2_bytes.len() as u64));
        }
        other => panic!("Expected DirectRange adopted spec, got {other:?}"),
    }

    assert_eq!(lumina_stream_set_refresh_callback(None), 0);
    stop_flag.store(true, Ordering::SeqCst);
    let _ = srv_handle.join();
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_ffi_dual_deck_metadata_and_get_state_json_after_skip_and_eof() {
    use core_types::{StreamKey, StreamSourceSpec};

    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let _ = lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let tmp_dir =
        std::env::temp_dir().join(format!("lumina_ffi_deck_meta_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav1 = tmp_dir.join("meta_1.wav");
    let wav2 = tmp_dir.join("meta_2.wav");
    let wav3 = tmp_dir.join("meta_3.wav");
    write_test_wav(&wav1, 48_000, 2, 48_000 * 3); // 3s
    write_test_wav(&wav2, 48_000, 2, 48_000 / 2); // 0.5s (for fast EOF swap -> wav3)
    write_test_wav(&wav3, 48_000, 2, 48_000 * 3); // 3s

    let read_state_json = || -> serde_json::Value {
        let p = lumina_playback_get_state_json();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(p) };
        serde_json::from_str(&s).unwrap()
    };

    // 1. Play Track 1 with full metadata
    let play1 = serde_json::json!({
        "id": "qb-trk-1",
        "provider_id": "qobuz",
        "title": "Track One",
        "artist": "Artist One",
        "album": "Album One",
        "cover_url": "https://cdn.example.com/1.jpg",
        "epoch": 100,
        "source_spec": StreamSourceSpec::LocalFile {
            key: StreamKey::new("qobuz", "qb-trk-1", "27"),
            path: wav1.to_string_lossy().to_string(),
            loudness: None,
            album_loudness: None,
        }
    })
    .to_string();
    let c_play1 = CString::new(play1).unwrap();
    assert_eq!(lumina_playback_play(c_play1.as_ptr()), 0);

    let st1 = read_state_json();
    assert_eq!(st1["swap_generation"], 0);
    assert_eq!(st1["swapGeneration"], 0);
    assert_eq!(st1["current_track_id"], "qb-trk-1");
    assert_eq!(st1["current_track"]["track_id"], "qb-trk-1");
    assert_eq!(st1["current_track"]["provider_id"], "qobuz");
    assert_eq!(st1["current_track"]["title"], "Track One");
    assert_eq!(
        st1["current_track"]["cover_url"],
        "https://cdn.example.com/1.jpg"
    );
    assert!(st1["current_track"]["duration_ms"].as_u64().unwrap_or(0) >= 2_500);

    // 2. Prepare Standby Track 2 (using album_art_url alias) and skip_to_standby()
    let standby2 = serde_json::json!({
        "track_id": "td-trk-2",
        "provider_id": "tidal",
        "title": "Track Two",
        "artist": "Artist Two",
        "album": "Album Two",
        "album_art_url": "https://cdn.example.com/2.jpg",
        "epoch": 100,
        "source_spec": StreamSourceSpec::LocalFile {
            key: StreamKey::new("tidal", "td-trk-2", "HI_RES"),
            path: wav2.to_string_lossy().to_string(),
            loudness: None,
            album_loudness: None,
        }
    })
    .to_string();
    let c_sb2 = CString::new(standby2).unwrap();
    assert_eq!(
        lumina_playback_prepare_standby_async(c_sb2.as_ptr(), 100),
        0
    );

    let mut sb2_ready = false;
    for _ in 0..80 {
        if read_state_json()["deck_b_state"] == "STANDBY_READY" {
            sb2_ready = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(sb2_ready, "Standby Deck B did not become STANDBY_READY");

    assert_eq!(lumina_playback_skip_to_standby(), 1);
    let st2 = read_state_json();
    assert_eq!(st2["active_deck"], "deck_b");
    assert_eq!(st2["swap_generation"], 1);
    assert_eq!(st2["swapGeneration"], 1);
    assert_eq!(st2["current_track_id"], "td-trk-2");
    assert_eq!(st2["current_track"]["track_id"], "td-trk-2");
    assert_eq!(st2["current_track"]["provider_id"], "tidal");
    assert_eq!(st2["current_track"]["title"], "Track Two");
    assert_eq!(
        st2["current_track"]["cover_url"],
        "https://cdn.example.com/2.jpg"
    );

    // 3. Prepare Standby Track 3 on Deck A and let Track 2 reach EOF automatically
    let standby3 = serde_json::json!({
        "id": "ytm-trk-3",
        "title": "Track Three",
        "artist": "Artist Three",
        "album": "Album Three",
        "artwork_url": "https://cdn.example.com/3.jpg",
        "epoch": 100,
        "source_spec": StreamSourceSpec::LocalFile {
            key: StreamKey::new("youtube_music", "ytm-trk-3", "251"),
            path: wav3.to_string_lossy().to_string(),
            loudness: None,
            album_loudness: None,
        }
    })
    .to_string();
    let c_sb3 = CString::new(standby3).unwrap();
    assert_eq!(
        lumina_playback_prepare_standby_async(c_sb3.as_ptr(), 100),
        0
    );

    let mut swapped_eof = false;
    for _ in 0..150 {
        let st = read_state_json();
        if st["swap_generation"].as_u64().unwrap_or(0) >= 2 && st["active_deck"] == "deck_a" {
            swapped_eof = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(
        swapped_eof,
        "Expected automatic EOF gapless swap back to deck_a: {}",
        read_state_json()
    );

    // Give relay_loop a brief moment if needed and verify get_state_json() reports Track 3 cleanly
    let st3 = read_state_json();
    assert_eq!(st3["swap_generation"], 2);
    assert_eq!(st3["swapGeneration"], 2);
    assert_eq!(st3["current_track_id"], "ytm-trk-3");
    assert_eq!(st3["current_track"]["track_id"], "ytm-trk-3");
    assert_eq!(st3["current_track"]["provider_id"], "youtube_music");
    assert_eq!(st3["current_track"]["title"], "Track Three");
    assert_eq!(
        st3["current_track"]["cover_url"],
        "https://cdn.example.com/3.jpg"
    );
    assert!(st3["current_track"]["duration_ms"].as_u64().unwrap_or(0) >= 2_500);

    assert_eq!(lumina_playback_stop(), 0);
    let st_stopped = read_state_json();
    assert!(st_stopped["current_track"].is_null());

    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_ffi_rapid_30_skips_latest_wins_non_blocking_and_epoch_monotonic() {
    use core_types::{StreamKey, StreamSourceSpec};
    use std::collections::BTreeMap;
    use std::io::{Read as _, Write as _};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    let _guard = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let _ = lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_rapid30_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav_44 = tmp_dir.join("local_44k.wav");
    let wav_48 = tmp_dir.join("local_48k.wav");
    let wav_96 = tmp_dir.join("local_96k.wav");
    write_test_wav(&wav_44, 44_100, 2, 44_100 * 2);
    write_test_wav(&wav_48, 48_000, 2, 48_000 * 2);
    write_test_wav(&wav_96, 96_000, 2, 96_000 * 2);
    let wav_96_bytes = Arc::new(std::fs::read(&wav_96).unwrap());

    // Local mock HTTP server: /stalled hangs open sockets; /ok.wav serves 96kHz WAV with range support.
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let stop_srv = Arc::new(AtomicBool::new(false));
    let stop_bg = Arc::clone(&stop_srv);
    let http_hits = Arc::new(AtomicUsize::new(0));
    let http_hits_bg = Arc::clone(&http_hits);
    let wav_bg = Arc::clone(&wav_96_bytes);
    let srv_handle = std::thread::spawn(move || {
        let mut workers = Vec::new();
        while !stop_bg.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let stop_conn = Arc::clone(&stop_bg);
                    let hits_conn = Arc::clone(&http_hits_bg);
                    let wav_conn = Arc::clone(&wav_bg);
                    workers.push(std::thread::spawn(move || {
                        let _ = stream.set_nonblocking(false);
                        let _ = stream.set_read_timeout(Some(Duration::from_millis(50)));
                        let mut req_buf = Vec::with_capacity(2048);
                        let mut chunk = [0u8; 1024];
                        'conn: while !stop_conn.load(Ordering::Relaxed) {
                            let mut header_end = None;
                            while !stop_conn.load(Ordering::Relaxed) {
                                if let Some(pos) = req_buf.windows(4).position(|w| w == b"\r\n\r\n")
                                {
                                    header_end = Some(pos + 4);
                                    break;
                                }
                                match stream.read(&mut chunk) {
                                    Ok(0) => break 'conn,
                                    Ok(n) => req_buf.extend_from_slice(&chunk[..n]),
                                    Err(ref e)
                                        if matches!(
                                            e.kind(),
                                            std::io::ErrorKind::WouldBlock
                                                | std::io::ErrorKind::TimedOut
                                        ) =>
                                    {
                                        continue;
                                    }
                                    Err(_) => break 'conn,
                                }
                            }
                            let Some(end_idx) = header_end else {
                                break 'conn;
                            };
                            let req_bytes: Vec<u8> = req_buf.drain(..end_idx).collect();
                            let req_str = String::from_utf8_lossy(&req_bytes);
                            hits_conn.fetch_add(1, Ordering::SeqCst);
                            if req_str.contains("/stalled") {
                                while !stop_conn.load(Ordering::Relaxed) {
                                    std::thread::sleep(Duration::from_millis(10));
                                }
                                break 'conn;
                            } else if req_str.contains("/ok.wav") {
                                let is_head = req_str.starts_with("HEAD ");
                                let wants_close = req_str
                                    .to_ascii_lowercase()
                                    .contains("connection: close");
                                let body = &wav_conn[..];
                                let total = body.len();
                                let (status, slice, range_hdr) = if let Some(line) = req_str
                                    .lines()
                                    .find(|l| l.to_ascii_lowercase().starts_with("range: bytes="))
                                {
                                    let spec = line
                                        .split_once('=')
                                        .map(|(_, r)| r.trim())
                                        .unwrap_or("0-");
                                    let (s_str, e_str) = spec.split_once('-').unwrap_or(("0", ""));
                                    let start: usize = s_str.parse().unwrap_or(0).min(total - 1);
                                    let end: usize = if e_str.is_empty() {
                                        total - 1
                                    } else {
                                        e_str.parse().unwrap_or(total - 1).min(total - 1)
                                    };
                                    (
                                        "206 Partial Content",
                                        &body[start..=end],
                                        format!("Content-Range: bytes {start}-{end}/{total}\r\n"),
                                    )
                                } else {
                                    ("200 OK", body, String::new())
                                };
                                let conn_hdr = if wants_close { "close" } else { "keep-alive" };
                                let hdr = format!(
                                    "HTTP/1.1 {status}\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\n{range_hdr}Content-Length: {}\r\nConnection: {conn_hdr}\r\n\r\n",
                                    slice.len()
                                );
                                if stream.write_all(hdr.as_bytes()).is_err()
                                    || (!is_head && stream.write_all(slice).is_err())
                                    || stream.flush().is_err()
                                {
                                    break 'conn;
                                }
                            } else {
                                let _ = stream.write_all(
                                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                                );
                                let _ = stream.flush();
                                break 'conn;
                            }
                        }
                    }));
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => break,
            }
        }
        for worker in workers {
            let _ = worker.join();
        }
    });

    let read_state_json = || -> serde_json::Value {
        let p = lumina_playback_get_state_json();
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p).to_str().unwrap().to_string() };
        unsafe { lumina_string_free(p) };
        serde_json::from_str(&s).unwrap()
    };

    let mut max_call_ms: u128 = 0;
    let mut last_pb_epoch: u64 = 0;

    // Fire 30 rapid skips across stalled HTTP, local 44.1/48/96kHz, and Tidal/YTM DirectRange specs,
    // interleaved with cancel_pending, prepare_standby_async, and get_state_json polls.
    for i in 1u64..=30 {
        let track_id = format!("rapid-track-{i}");
        let payload = if i == 30 {
            serde_json::json!({
                "id": track_id,
                "title": "Settled Final Track 30",
                "provider_id": "tidal",
                "playback_epoch": i,
                "duration_ms": 2000,
                "source_spec": StreamSourceSpec::DirectRange {
                    key: StreamKey::new("tidal", "rapid-track-30", "HI_RES"),
                    url: format!("http://{addr}/ok.wav"),
                    headers: BTreeMap::new(),
                    bitrate_bps: Some(4_608_000),
                    mime_type: Some("audio/wav".to_string()),
                    hint_extension: Some("wav".to_string()),
                    content_length: Some(wav_96_bytes.len() as u64),
                    expire_at: None,
                    init_range_end: None,
                    index_range_start: None,
                    index_range_end: None,
                    loudness: None,
                    album_loudness: None,
                }
            })
        } else if i % 3 == 1 {
            // Stalled YTM-like stream
            serde_json::json!({
                "id": track_id,
                "title": format!("YTM Stalled {i}"),
                "provider_id": "youtube_music",
                "playback_epoch": i,
                "stream_url": format!("http://{addr}/stalled/{i}"),
                "duration_ms": 180_000,
            })
        } else if i % 3 == 2 {
            // Local lossless 44.1kHz or 48kHz
            let p = if i % 2 == 0 { &wav_44 } else { &wav_48 };
            serde_json::json!({
                "id": track_id,
                "title": format!("Local Lossless {i}"),
                "provider_id": "local",
                "playback_epoch": i,
                "source_spec": StreamSourceSpec::LocalFile {
                    key: StreamKey::new("local", format!("rapid-track-{i}"), "native"),
                    path: p.to_string_lossy().to_string(),
                    loudness: None,
                    album_loudness: None,
                }
            })
        } else {
            // Stalled Tidal-like DirectRange
            serde_json::json!({
                "id": track_id,
                "title": format!("Tidal Stalled {i}"),
                "provider_id": "tidal",
                "playback_epoch": i,
                "source_spec": StreamSourceSpec::DirectRange {
                    key: StreamKey::new("tidal", format!("rapid-track-{i}"), "HI_RES"),
                    url: format!("http://{addr}/stalled/{i}"),
                    headers: BTreeMap::new(),
                    bitrate_bps: Some(4_608_000),
                    mime_type: Some("audio/wav".to_string()),
                    hint_extension: Some("wav".to_string()),
                    content_length: None,
                    expire_at: None,
                    init_range_end: None,
                    index_range_start: None,
                    index_range_end: None,
                    loudness: None,
                    album_loudness: None,
                }
            })
        }
        .to_string();

        let c_payload = CString::new(payload).unwrap();
        let t0 = Instant::now();
        assert_eq!(lumina_playback_play_async(c_payload.as_ptr(), i), 0);
        let elapsed_ms = t0.elapsed().as_millis();
        max_call_ms = max_call_ms.max(elapsed_ms);

        // Interleave non-blocking standby prep & cancel mid-burst
        if i == 10 {
            let sb_payload = CString::new(
                serde_json::json!({
                    "id": "sb-mid",
                    "epoch": i,
                    "source_spec": StreamSourceSpec::LocalFile {
                        key: StreamKey::new("local", "sb-mid", "native"),
                        path: wav_48.to_string_lossy().to_string(),
                        loudness: None,
                        album_loudness: None,
                    }
                })
                .to_string(),
            )
            .unwrap();
            let t_sb = Instant::now();
            assert_eq!(
                lumina_playback_prepare_standby_async(sb_payload.as_ptr(), i),
                0
            );
            assert!(
                t_sb.elapsed().as_millis() < 25,
                "prepare_standby_async must be non-blocking"
            );
        }
        if i == 15 {
            let t_cancel = Instant::now();
            assert_eq!(lumina_playback_cancel_pending(i), 0);
            assert!(
                t_cancel.elapsed().as_millis() < 25,
                "cancel_pending must be non-blocking"
            );
        }

        let st = read_state_json();
        let pb_ep = st["playback_epoch"].as_u64().unwrap_or(0);
        assert_eq!(pb_ep, st["playbackEpoch"].as_u64().unwrap_or(0));
        assert!(
            pb_ep >= last_pb_epoch,
            "playback_epoch must be monotonic: prev={last_pb_epoch} cur={pb_ep}"
        );
        last_pb_epoch = pb_ep;
        std::thread::sleep(Duration::from_millis(5));
    }

    assert!(
        max_call_ms < 25,
        "lumina_playback_play_async took {max_call_ms}ms during 30 rapid skips (expected non-blocking)"
    );

    // Wait for track #30 to settle via Latest-Wins
    let mut settled = None;
    for _ in 0..120 {
        let st = read_state_json();
        if st["loaded_request_id"] == 30 && st["state_code"] == 2 {
            settled = Some(st);
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let settled = settled.unwrap_or_else(|| {
        panic!(
            "Final track 30 should settle into Playing after 30 rapid skips, got: {}",
            read_state_json()
        )
    });
    assert_eq!(settled["current_track_id"], "rapid-track-30");
    assert!(settled["playback_epoch"].as_u64().unwrap_or(0) >= 30);
    assert!(settled["epoch"].as_u64().unwrap_or(0) >= 30);

    // Stale epoch (12 < 30) must be ignored without disturbing track 30
    let stale_payload = CString::new(
        serde_json::json!({
            "id": "stale-12",
            "playback_epoch": 12,
            "file_path": wav_44.to_string_lossy(),
        })
        .to_string(),
    )
    .unwrap();
    assert_eq!(lumina_playback_play_async(stale_payload.as_ptr(), 12), 0);
    let after_stale = read_state_json();
    assert_eq!(after_stale["current_track_id"], "rapid-track-30");
    assert_eq!(after_stale["state_code"], 2);

    // Epoch-less stalled play right after epoched track 30 must:
    // 1. Report Loading (5) with NEW track 31 metadata (never flashing back to Old Track 30!)
    // 2. Advance playback_epoch monotonically (> 30)
    let ep30 = after_stale["playback_epoch"].as_u64().unwrap();
    let epochless_stalled = CString::new(
        serde_json::json!({
            "id": "rapid-track-31",
            "title": "Loading Track 31",
            "artist": "Artist 31",
            "provider_id": "youtube_music",
            "stream_url": format!("http://{addr}/stalled/31"),
            "duration_ms": 180_000,
        })
        .to_string(),
    )
    .unwrap();
    assert_eq!(
        lumina_playback_play_async(epochless_stalled.as_ptr(), 31),
        0
    );
    let loading_31 = read_state_json();
    assert_eq!(loading_31["state_code"], 5);
    assert_eq!(loading_31["current_track_id"], "rapid-track-31");
    assert_eq!(loading_31["current_track"]["track_id"], "rapid-track-31");
    assert_eq!(loading_31["current_track"]["title"], "Loading Track 31");
    assert!(
        loading_31["playback_epoch"].as_u64().unwrap_or(0) > ep30,
        "epoch-less play after epoched play must advance playback_epoch past {ep30}"
    );

    // Epoch-less fast play right after epoched play must NOT be silently dropped (must settle to Playing)
    let epochless_fast = CString::new(
        serde_json::json!({
            "id": "rapid-track-32",
            "title": "Epochless Settled 32",
            "file_path": wav_48.to_string_lossy(),
        })
        .to_string(),
    )
    .unwrap();
    assert_eq!(lumina_playback_play_async(epochless_fast.as_ptr(), 32), 0);
    let mut settled_32 = None;
    for _ in 0..100 {
        let st = read_state_json();
        if st["loaded_request_id"] == 32 && st["state_code"] == 2 {
            settled_32 = Some(st);
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let settled_32 = settled_32.unwrap_or_else(|| {
        panic!(
            "Epoch-less play 32 after epoched play 30 must settle into Playing, got: {}",
            read_state_json()
        )
    });
    assert_eq!(settled_32["current_track_id"], "rapid-track-32");
    assert!(settled_32["playback_epoch"].as_u64().unwrap_or(0) > ep30);

    // Non-blocking stop must return rapidly and bump playback_epoch
    let ep_before_stop = settled_32["playback_epoch"].as_u64().unwrap();
    let t_stop = Instant::now();
    assert_eq!(lumina_playback_stop(), 0);
    assert!(
        t_stop.elapsed().as_millis() < 25,
        "lumina_playback_stop must be non-blocking"
    );
    let after_stop = read_state_json();
    assert_eq!(after_stop["state_code"], 1);
    assert!(after_stop["current_track"].is_null());
    assert!(after_stop["playback_epoch"].as_u64().unwrap() > ep_before_stop);

    stop_srv.store(true, Ordering::SeqCst);
    let _ = srv_handle.join();
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn test_ffi_ingestion_layer_watch_scan_skipped_overrides_ingest_and_providers() {
    use std::os::raw::c_char;
    use std::sync::{Mutex as StdMutex, OnceLock};
    use std::time::{Duration, Instant};

    static CAPTURED_EVENTS: OnceLock<StdMutex<Vec<serde_json::Value>>> = OnceLock::new();

    extern "C" fn on_scan_progress(json_ptr: *const c_char) {
        if json_ptr.is_null() {
            return;
        }
        let s = unsafe { CStr::from_ptr(json_ptr).to_string_lossy().into_owned() };
        unsafe { lumina_string_free(json_ptr as *mut c_char) };
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&s) {
            let store = CAPTURED_EVENTS.get_or_init(|| StdMutex::new(Vec::new()));
            if let Ok(mut guard) = store.lock() {
                guard.push(val);
            }
        }
    }

    let _g = FFI_TEST_GUARD.lock().unwrap_or_else(|e| e.into_inner());
    let store = CAPTURED_EVENTS.get_or_init(|| StdMutex::new(Vec::new()));
    store.lock().unwrap().clear();

    lumina_shutdown();
    assert_eq!(lumina_init_headless(), 0);

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_ffi_ingest_{ts}"));
    let music_dir = tmp_dir.join("Music").join("ArtistA").join("AlbumA");
    std::fs::create_dir_all(&music_dir).unwrap();
    let db_path = tmp_dir.join("library.db");

    let wav_ok = music_dir.join("01 - Good.wav");
    write_test_wav(&wav_ok, 44_100, 2, 44_100);
    let corrupt_wav = music_dir.join("02 - Broken.wav");
    std::fs::write(&corrupt_wav, b"NOT_A_VALID_WAV_HEADER_0000").unwrap();
    let dismiss_cue = music_dir.join("03 - Unsplit.cue");
    std::fs::write(&dismiss_cue, b"FILE \"disc.flac\" WAVE\nTRACK 01 AUDIO\n").unwrap();

    let c_db = CString::new(db_path.to_string_lossy().as_ref()).unwrap();
    assert_eq!(lumina_library_init(c_db.as_ptr()), 0);

    // 1. Register scan progress callback
    assert_eq!(
        lumina_library_set_scan_progress_callback(Some(on_scan_progress)),
        0
    );

    // 2. Watch root CRUD
    let c_root = CString::new(tmp_dir.join("Music").to_string_lossy().as_ref()).unwrap();
    let c_mode = CString::new("manual").unwrap();
    let added_ptr = lumina_library_watch_add(c_root.as_ptr(), c_mode.as_ptr(), 120);
    assert!(!added_ptr.is_null());
    let added_str = unsafe { CStr::from_ptr(added_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(added_ptr) };
    let added_val: serde_json::Value = serde_json::from_str(&added_str).unwrap();
    assert_eq!(added_val["watch_mode"], "manual");
    assert_eq!(added_val["poll_interval_sec"], 120);

    let list_ptr = lumina_library_watch_list();
    assert!(!list_ptr.is_null());
    let list_str = unsafe { CStr::from_ptr(list_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(list_ptr) };
    let list_val: serde_json::Value = serde_json::from_str(&list_str).unwrap();
    assert_eq!(list_val.as_array().unwrap().len(), 1);

    // 3. Async scan start -> emits ScanProgressEvent through FFI callback with matching scan_id
    let start_ptr = lumina_library_scan_start(c_root.as_ptr(), 0);
    assert!(!start_ptr.is_null());
    let start_str = unsafe { CStr::from_ptr(start_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(start_ptr) };
    let start_val: serde_json::Value = serde_json::from_str(&start_str).unwrap();
    let expected_scan_id = start_val["scan_id"].as_str().unwrap().to_string();
    assert!(!expected_scan_id.is_empty());

    // Wait until Completed arrives for the exact correlated scan_id
    let corr_deadline = Instant::now() + Duration::from_secs(10);
    let mut scan_completed_with_id = false;
    while Instant::now() < corr_deadline {
        if let Some(m) = CAPTURED_EVENTS.get()
            && let Ok(evs) = m.lock()
            && evs.iter().any(|e| {
                e["scan_id"].as_str() == Some(expected_scan_id.as_str())
                    && e["state"].as_str() == Some("completed")
            })
        {
            scan_completed_with_id = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        scan_completed_with_id,
        "lumina_library_scan_start scan_id must correlate with ScanProgressEvent.scan_id"
    );

    // 3b. Async tag rescan start -> non-blocking return with correlated Completed event
    let rescan_start_ptr = lumina_library_rescan_start(c_root.as_ptr(), 1);
    assert!(!rescan_start_ptr.is_null());
    let rescan_start_str = unsafe {
        CStr::from_ptr(rescan_start_ptr)
            .to_str()
            .unwrap()
            .to_string()
    };
    unsafe { lumina_string_free(rescan_start_ptr) };
    let rescan_start_val: serde_json::Value = serde_json::from_str(&rescan_start_str).unwrap();
    let expected_rescan_id = rescan_start_val["scan_id"].as_str().unwrap().to_string();
    assert!(!expected_rescan_id.is_empty());

    let rescan_deadline = Instant::now() + Duration::from_secs(10);
    let mut rescan_completed_with_id = false;
    while Instant::now() < rescan_deadline {
        if let Some(m) = CAPTURED_EVENTS.get()
            && let Ok(evs) = m.lock()
            && evs.iter().any(|e| {
                e["scan_id"].as_str() == Some(expected_rescan_id.as_str())
                    && e["state"].as_str() == Some("completed")
            })
        {
            rescan_completed_with_id = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        rescan_completed_with_id,
        "lumina_library_rescan_start must emit correlated Completed ScanProgressEvent"
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut saw_completed = false;
    while Instant::now() < deadline {
        {
            let evs = store.lock().unwrap();
            if evs.iter().any(|e| e["state"] == "completed") {
                saw_completed = true;
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        saw_completed,
        "Expected scan progress callback to receive a 'completed' event"
    );

    // 4. Skipped files: list, retry (still_skipped -> fix -> imported), dismiss
    let skip_ptr = lumina_library_get_skipped_files(0);
    assert!(!skip_ptr.is_null());
    let skip_str = unsafe { CStr::from_ptr(skip_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(skip_ptr) };
    let skipped: Vec<serde_json::Value> = serde_json::from_str(&skip_str).unwrap();
    assert!(
        skipped.len() >= 2,
        "Expected corrupt wav and unsplit cue in skipped_files, got: {skipped:?}"
    );

    let broken_rec = skipped
        .iter()
        .find(|s| {
            s["file_path"]
                .as_str()
                .unwrap_or("")
                .to_ascii_lowercase()
                .ends_with("02 - broken.wav")
        })
        .expect("broken wav skipped record");
    let broken_id = CString::new(broken_rec["id"].as_str().unwrap()).unwrap();

    // Retry while still broken -> still_skipped
    let r1_ptr = lumina_library_retry_skipped_file(broken_id.as_ptr());
    assert!(!r1_ptr.is_null());
    let r1_val: serde_json::Value =
        serde_json::from_str(unsafe { CStr::from_ptr(r1_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(r1_ptr) };
    assert_eq!(r1_val["status"], "still_skipped");

    // Replace broken file with valid WAV and retry -> imported
    write_test_wav(&corrupt_wav, 44_100, 2, 44_100);
    let r2_ptr = lumina_library_retry_skipped_file(broken_id.as_ptr());
    assert!(!r2_ptr.is_null());
    let r2_val: serde_json::Value =
        serde_json::from_str(unsafe { CStr::from_ptr(r2_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(r2_ptr) };
    assert_eq!(r2_val["status"], "imported");

    // Dismiss the unsplit cue
    let cue_rec = skipped
        .iter()
        .find(|s| {
            s["file_path"]
                .as_str()
                .unwrap_or("")
                .to_ascii_lowercase()
                .ends_with("03 - unsplit.cue")
        })
        .expect("cue skipped record");
    let cue_id = CString::new(cue_rec["id"].as_str().unwrap()).unwrap();
    assert_eq!(lumina_library_dismiss_skipped_file(cue_id.as_ptr()), 0);

    let skip_after_ptr = lumina_library_get_skipped_files(0);
    let skip_after: Vec<serde_json::Value> =
        serde_json::from_str(unsafe { CStr::from_ptr(skip_after_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(skip_after_ptr) };
    assert!(skip_after.is_empty());

    // 5. Metadata overrides: set, get, clear
    let c_et = CString::new("album").unwrap();
    let c_eid = CString::new("alb-test-1").unwrap();
    let c_field = CString::new("title").unwrap();
    let c_val = CString::new("\"User Custom Title\"").unwrap();
    assert_eq!(
        lumina_library_set_metadata_override(
            c_et.as_ptr(),
            c_eid.as_ptr(),
            c_field.as_ptr(),
            c_val.as_ptr()
        ),
        0
    );
    let ov_ptr = lumina_library_get_metadata_overrides(c_et.as_ptr(), c_eid.as_ptr());
    assert!(!ov_ptr.is_null());
    let ovs: Vec<serde_json::Value> =
        serde_json::from_str(unsafe { CStr::from_ptr(ov_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(ov_ptr) };
    assert_eq!(ovs.len(), 1);
    assert_eq!(ovs[0]["field_name"], "title");
    assert_eq!(ovs[0]["source_layer"], "user_edit");

    assert_eq!(
        lumina_library_clear_metadata_override(c_et.as_ptr(), c_eid.as_ptr(), c_field.as_ptr()),
        0
    );
    let ov2_ptr = lumina_library_get_metadata_overrides(c_et.as_ptr(), c_eid.as_ptr());
    let ovs2: Vec<serde_json::Value> =
        serde_json::from_str(unsafe { CStr::from_ptr(ov2_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(ov2_ptr) };
    assert!(ovs2.is_empty());

    // 6. External catalog ingest (Apple Music / YouTube Music lightweight metadata)
    let batch = serde_json::json!({
        "provider": "apple_music",
        "albums": [{
            "external_album_id": "am-alb-1",
            "title": "Cloud Symphony",
            "artist_name": "Orbital",
            "release_year": 2024,
            "tracks": [{
                "external_track_id": "am-trk-1",
                "title": "Overture",
                "artist_name": "Orbital",
                "album_title": "Cloud Symphony",
                "disc_number": 1,
                "track_number": 1,
                "duration_ms": 210000,
                "codec": "alac",
                "sample_rate_hz": 96000,
                "bit_depth": 24,
                "channels": 2,
                "is_dsd": false
            }]
        }]
    })
    .to_string();
    let c_batch = CString::new(batch).unwrap();
    let ing_ptr = lumina_library_ingest_external_catalog(c_batch.as_ptr());
    assert!(!ing_ptr.is_null());
    let ing_val: serde_json::Value =
        serde_json::from_str(unsafe { CStr::from_ptr(ing_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(ing_ptr) };
    assert_eq!(ing_val["albums_ingested"], 1);
    assert_eq!(ing_val["tracks_ingested"], 1);

    // 7. Provider list & watch root removal
    let prov_ptr = lumina_provider_list();
    assert!(!prov_ptr.is_null());
    let prov_val: serde_json::Value =
        serde_json::from_str(unsafe { CStr::from_ptr(prov_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(prov_ptr) };
    assert!(prov_val.is_array());

    assert_eq!(lumina_library_watch_remove(c_root.as_ptr()), 0);
    let list2_ptr = lumina_library_watch_list();
    let list2_val: serde_json::Value =
        serde_json::from_str(unsafe { CStr::from_ptr(list2_ptr).to_str().unwrap() }).unwrap();
    unsafe { lumina_string_free(list2_ptr) };
    assert!(list2_val.as_array().unwrap().is_empty());

    assert_eq!(lumina_library_set_scan_progress_callback(None), 0);
    assert_eq!(lumina_shutdown(), 0);
    let _ = std::fs::remove_dir_all(&tmp_dir);
}
