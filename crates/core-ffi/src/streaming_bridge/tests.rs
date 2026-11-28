use super::*;
use crate::lumina_string_free;
use core_audio::streaming::{
    StreamError, StreamRefreshHandler, StreamRefreshOutcome, StreamRefreshRequest,
};
use core_types::{StreamKey, StreamSourceSpec};
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio_util::sync::CancellationToken;

static LAST_TEST_EPOCH: AtomicU64 = AtomicU64::new(0);

extern "C" fn test_epoch_cb(epoch: u64) {
    LAST_TEST_EPOCH.store(epoch, Ordering::SeqCst);
}

extern "C" fn test_refresh_cb(req_id: u64, req_json_ptr: *mut c_char) {
    let raw = unsafe { CStr::from_ptr(req_json_ptr).to_str().unwrap().to_string() };
    unsafe { lumina_string_free(req_json_ptr) };
    let req: StreamRefreshRequest = serde_json::from_str(&raw).unwrap();
    let spec = StreamSourceSpec::DirectRange {
        key: StreamKey::new(&req.provider_id, &req.track_id, &req.quality_key),
        url: "https://cdn.example.com/refreshed.flac".to_string(),
        headers: BTreeMap::new(),
        content_length: req.expected_content_length,
        bitrate_bps: None,
        mime_type: req.expected_mime_type,
        hint_extension: Some("flac".to_string()),
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
    let rc = lumina_stream_complete_refresh(req_id, c_reply.as_ptr());
    assert_eq!(rc, LUMINA_OK);
}

#[test]
fn test_ffi_stream_refresh_roundtrip_and_epoch_and_provider_cancel() {
    let _guard = TEST_BRIDGE_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    assert!(lumina_network_get_epoch() >= 1);
    assert_eq!(
        lumina_network_set_epoch_callback(Some(test_epoch_cb)),
        LUMINA_OK
    );
    notify_network_epoch_changed(42);
    assert_eq!(LAST_TEST_EPOCH.load(Ordering::SeqCst), 42);
    assert_eq!(lumina_network_set_epoch_callback(None), LUMINA_OK);

    let cancelled_provider = Arc::new(Mutex::new(None::<String>));
    let cp_clone = Arc::clone(&cancelled_provider);
    register_provider_cancel_hook(Some(Arc::new(move |pid| {
        *cp_clone.lock().unwrap() = Some(pid.to_string());
    })));
    let c_pid = CString::new("tidal").unwrap();
    assert_eq!(lumina_streaming_cancel_provider(c_pid.as_ptr()), LUMINA_OK);
    assert_eq!(cancelled_provider.lock().unwrap().as_deref(), Some("tidal"));
    register_provider_cancel_hook(None);

    assert_eq!(
        lumina_stream_set_refresh_callback(Some(test_refresh_cb)),
        LUMINA_OK
    );
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let handler = FfiStreamRefreshHandler::with_timeout(Duration::from_secs(2));
    let req = StreamRefreshRequest {
        provider_id: "qobuz".to_string(),
        track_id: "123".to_string(),
        quality_key: "27".to_string(),
        failed_url: "https://cdn.example.com/old.flac".to_string(),
        status_code: 403,
        attempt: 1,
        expected_content_length: Some(1024),
        expected_mime_type: Some("audio/flac".to_string()),
        expected_kind: Some("direct_range".to_string()),
        is_initial_probe: false,
    };
    let cancel = CancellationToken::new();
    let outcome = rt
        .block_on(handler.refresh_after_403(req, &cancel))
        .unwrap();
    match outcome {
        StreamRefreshOutcome::Refreshed(StreamSourceSpec::DirectRange { url, .. }) => {
            assert_eq!(url, "https://cdn.example.com/refreshed.flac");
        }
        other => panic!("expected Refreshed DirectRange, got {other:?}"),
    }
    assert_eq!(lumina_stream_set_refresh_callback(None), LUMINA_OK);
}

static SYNC_EPOCH_ENTERED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
static SYNC_EPOCH_DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static SYNC_REFRESH_ENTERED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
static SYNC_REFRESH_DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn slow_epoch_cb(_epoch: u64) {
    SYNC_EPOCH_ENTERED.store(true, Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(50));
    SYNC_EPOCH_DONE.store(true, Ordering::SeqCst);
}

extern "C" fn slow_refresh_cb(_req_id: u64, req_json_ptr: *mut c_char) {
    unsafe { lumina_string_free(req_json_ptr) };
    SYNC_REFRESH_ENTERED.store(true, Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(50));
    SYNC_REFRESH_DONE.store(true, Ordering::SeqCst);
}

#[test]
fn test_callback_deregistration_waits_for_inflight_invocation() {
    let _guard = TEST_BRIDGE_LOCK.lock().unwrap_or_else(|e| e.into_inner());

    // 1. Network epoch callback teardown synchronization
    SYNC_EPOCH_ENTERED.store(false, Ordering::SeqCst);
    SYNC_EPOCH_DONE.store(false, Ordering::SeqCst);
    assert_eq!(
        lumina_network_set_epoch_callback(Some(slow_epoch_cb)),
        LUMINA_OK
    );
    let t_epoch = std::thread::spawn(|| notify_network_epoch_changed(99));
    while !SYNC_EPOCH_ENTERED.load(Ordering::SeqCst) {
        std::thread::yield_now();
    }
    assert_eq!(lumina_network_set_epoch_callback(None), LUMINA_OK);
    assert!(
        SYNC_EPOCH_DONE.load(Ordering::SeqCst),
        "set_epoch_callback(None) must not return before in-flight callback exits"
    );
    t_epoch.join().unwrap();

    // 2. Stream refresh callback teardown synchronization + pending cancellation
    SYNC_REFRESH_ENTERED.store(false, Ordering::SeqCst);
    SYNC_REFRESH_DONE.store(false, Ordering::SeqCst);
    assert_eq!(
        lumina_stream_set_refresh_callback(Some(slow_refresh_cb)),
        LUMINA_OK
    );
    let t_refresh = std::thread::spawn(|| {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let handler = FfiStreamRefreshHandler::with_timeout(Duration::from_secs(2));
        let req = StreamRefreshRequest {
            provider_id: "qobuz".to_string(),
            track_id: "sync-1".to_string(),
            quality_key: "27".to_string(),
            failed_url: "https://cdn.example.com/old.flac".to_string(),
            status_code: 403,
            attempt: 1,
            expected_content_length: None,
            expected_mime_type: None,
            expected_kind: None,
            is_initial_probe: false,
        };
        let cancel = CancellationToken::new();
        rt.block_on(handler.refresh_after_403(req, &cancel))
    });
    while !SYNC_REFRESH_ENTERED.load(Ordering::SeqCst) {
        std::thread::yield_now();
    }
    assert_eq!(lumina_stream_set_refresh_callback(None), LUMINA_OK);
    assert!(
        SYNC_REFRESH_DONE.load(Ordering::SeqCst),
        "set_refresh_callback(None) must not return before in-flight callback exits"
    );
    let res = t_refresh.join().unwrap();
    assert_eq!(res, Err(StreamError::Cancelled));
}
