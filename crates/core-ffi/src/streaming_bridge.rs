use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, LUMINA_ERR_GENERAL,
    LUMINA_ERR_NULL_POINTER, LUMINA_OK,
};
use core_audio::streaming::{
    StreamError, StreamRefreshHandler, StreamRefreshOutcome, StreamRefreshRequest,
    current_network_epoch,
};
use core_types::StreamSourceSpec;
use serde::Deserialize;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

/// C-ABI callback invoked from Rust streaming workers (safe with Dart `NativeCallable.listener`).
///
/// Ownership: `request_json` is a heap-allocated NUL-terminated UTF-8 string created via
/// `CString::into_raw`. The Dart callback MUST free it with `lumina_string_free(request_json)`.
pub type StreamRefreshCallback = extern "C" fn(request_id: u64, request_json: *mut c_char);

/// C-ABI callback invoked when `NetworkMonitor` confirms a real network/route/VPN change and
/// increments the global `network_epoch`. Safe with Dart `NativeCallable.listener`.
pub type NetworkEpochCallback = extern "C" fn(new_epoch: u64);

/// Internal Rust hook registered by playback/player layer to cancel active streaming playback
/// belonging to a specific `provider_id` when `AuthRequired` circuit-breaker trips.
pub type ProviderCancelHook = Arc<dyn Fn(&str) + Send + Sync>;

struct PendingRefreshEntry {
    provider_id: String,
    tx: oneshot::Sender<Result<StreamRefreshOutcome, StreamError>>,
}

static STREAM_REFRESH_CB: RwLock<Option<StreamRefreshCallback>> = RwLock::new(None);
static NETWORK_EPOCH_CB: RwLock<Option<NetworkEpochCallback>> = RwLock::new(None);
static PROVIDER_CANCEL_HOOK: RwLock<Option<ProviderCancelHook>> = RwLock::new(None);
static NEXT_REFRESH_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static PENDING_REFRESHES: OnceLock<Mutex<HashMap<u64, PendingRefreshEntry>>> = OnceLock::new();

fn pending_refreshes() -> &'static Mutex<HashMap<u64, PendingRefreshEntry>> {
    PENDING_REFRESHES.get_or_init(|| Mutex::new(HashMap::new()))
}

struct PendingRefreshCleanup {
    request_id: u64,
}

impl Drop for PendingRefreshCleanup {
    fn drop(&mut self) {
        if let Ok(mut map) = pending_refreshes().lock() {
            map.remove(&self.request_id);
        }
    }
}

/// Cancels all in-flight FFI stream-refresh requests (called on shutdown or callback deregistration).
pub fn cancel_all_pending_refreshes() {
    if let Ok(mut map) = pending_refreshes().lock() {
        for (_, entry) in map.drain() {
            let _ = entry.tx.send(Err(StreamError::Cancelled));
        }
    }
}

/// Fails any pending FFI stream-refresh requests for `provider_id` with `StreamError::AuthRequired`.
fn fail_pending_refreshes_for_provider(provider_id: &str) {
    let Ok(mut map) = pending_refreshes().lock() else {
        return;
    };
    let matching_ids: Vec<u64> = map
        .iter()
        .filter(|(_, entry)| entry.provider_id.eq_ignore_ascii_case(provider_id))
        .map(|(&id, _)| id)
        .collect();
    for id in matching_ids {
        if let Some(entry) = map.remove(&id) {
            let _ = entry.tx.send(Err(StreamError::AuthRequired {
                provider_id: entry.provider_id,
                status: 401,
            }));
        }
    }
}

/// Registers an internal Rust callback invoked by [`lumina_streaming_cancel_provider`] so the
/// active `AudioPlayer` cancels playback if its current stream matches `provider_id`.
pub fn register_provider_cancel_hook(hook: Option<ProviderCancelHook>) {
    if let Ok(mut guard) = PROVIDER_CANCEL_HOOK.write() {
        *guard = hook;
    }
}

/// Notifies the registered Dart FFI epoch callback (if any) that `network_epoch` advanced.
/// Holds the read lock across the non-blocking `NativeCallable.listener` call so
/// `lumina_network_set_epoch_callback(None)` synchronizes before Dart closes the callable.
pub fn notify_network_epoch_changed(epoch: u64) {
    if let Ok(guard) = NETWORK_EPOCH_CB.read()
        && let Some(func) = *guard
    {
        func(epoch);
    }
}

/// [`StreamRefreshHandler`] backed by the registered Dart `NativeCallable.listener` FFI callback
/// and [`lumina_stream_complete_refresh`].
pub struct FfiStreamRefreshHandler {
    timeout: Duration,
}

impl FfiStreamRefreshHandler {
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);

    pub fn new() -> Self {
        Self {
            timeout: Self::DEFAULT_TIMEOUT,
        }
    }

    pub fn with_timeout(timeout: Duration) -> Self {
        Self { timeout }
    }
}

impl Default for FfiStreamRefreshHandler {
    fn default() -> Self {
        Self::new()
    }
}

/// Convenience constructor returning a shared `Arc<dyn StreamRefreshHandler>` for `AudioPlayer` wiring.
pub fn ffi_stream_refresh_handler() -> Arc<dyn StreamRefreshHandler> {
    Arc::new(FfiStreamRefreshHandler::new())
}

impl StreamRefreshHandler for FfiStreamRefreshHandler {
    fn refresh_after_403<'life0, 'life1, 'async_trait>(
        &'life0 self,
        req: StreamRefreshRequest,
        cancel: &'life1 CancellationToken,
    ) -> std::pin::Pin<
        Box<
            dyn std::future::Future<Output = Result<StreamRefreshOutcome, StreamError>>
                + Send
                + 'async_trait,
        >,
    >
    where
        'life0: 'async_trait,
        'life1: 'async_trait,
        Self: 'async_trait,
    {
        let timeout = self.timeout;
        let cancel = cancel.clone();
        Box::pin(async move {
            if cancel.is_cancelled() {
                return Err(StreamError::Cancelled);
            }
            let payload_json = serde_json::to_string(&req).map_err(|e| {
                StreamError::Io(format!("Failed to serialize refresh request: {e}"))
            })?;

            let request_id = NEXT_REFRESH_REQUEST_ID.fetch_add(1, Ordering::SeqCst);
            let (tx, rx) = oneshot::channel();
            let _cleanup = {
                // Hold the read lock across the non-blocking `NativeCallable.listener` call so
                // `lumina_stream_set_refresh_callback(None)` (`write()` lock) strictly waits for
                // any in-flight callback invocation to return before Dart closes the callable.
                let cb_guard = STREAM_REFRESH_CB
                    .read()
                    .map_err(|_| StreamError::HttpStatus(req.status_code))?;
                let cb = (*cb_guard).ok_or(StreamError::HttpStatus(req.status_code))?;

                let c_ptr = string_to_c_char(&payload_json);
                if c_ptr.is_null() {
                    return Err(StreamError::Io(
                        "Refresh request JSON contained interior NUL byte".to_string(),
                    ));
                }

                {
                    let Ok(mut map) = pending_refreshes().lock() else {
                        unsafe {
                            drop(std::ffi::CString::from_raw(c_ptr));
                        }
                        return Err(StreamError::Io("pending refresh lock poisoned".to_string()));
                    };
                    map.insert(
                        request_id,
                        PendingRefreshEntry {
                            provider_id: req.provider_id.clone(),
                            tx,
                        },
                    );
                }
                let cleanup = PendingRefreshCleanup { request_id };

                cb(request_id, c_ptr);
                cleanup
            };

            tokio::select! {
                biased;
                _ = cancel.cancelled() => Err(StreamError::Cancelled),
                _ = tokio::time::sleep(timeout) => Err(StreamError::Timeout),
                res = rx => match res {
                    Ok(outcome) => outcome,
                    Err(_) => Err(StreamError::Cancelled),
                }
            }
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum RefreshCompletePayload {
    Refreshed {
        spec: StreamSourceSpec,
    },
    FormatChanged {
        spec: StreamSourceSpec,
        #[serde(default)]
        reason: String,
    },
    AuthRequired {
        provider_id: String,
        #[serde(default)]
        message: String,
    },
    Cancelled,
    Error {
        #[serde(default)]
        message: String,
    },
}

/// Registers (or clears when null) the Dart `NativeCallable.listener` callback invoked when a
/// Rust streaming proxy hits HTTP 403/410 and needs `ResolverFacade.refresh_after_403`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_stream_set_refresh_callback(cb: Option<StreamRefreshCallback>) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_stream_set_refresh_callback",
        || {
            if let Ok(mut guard) = STREAM_REFRESH_CB.write() {
                *guard = cb;
            }
            if cb.is_none() {
                cancel_all_pending_refreshes();
            }
            Ok(LUMINA_OK)
        },
    )
}

/// Completes a pending Rust stream-refresh request initiated via [`StreamRefreshCallback`].
///
/// Expected `result_json` schema:
/// - `{"status":"refreshed","spec":{...}}`
/// - `{"status":"format_changed","spec":{...},"reason":"..."}`
/// - `{"status":"auth_required","provider_id":"...","message":"..."}`
/// - `{"status":"cancelled"}`
/// - `{"status":"error","message":"..."}`
#[unsafe(no_mangle)]
pub extern "C" fn lumina_stream_complete_refresh(
    request_id: u64,
    result_json: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_stream_complete_refresh",
        || {
            if request_id == 0 {
                set_last_error("request_id must be greater than 0");
                return Ok(LUMINA_ERR_GENERAL);
            }
            if result_json.is_null() {
                set_last_error("result_json is null");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let raw = unsafe { CStr::from_ptr(result_json) }
                .to_str()
                .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in result_json: {e}"))?;
            let parsed: RefreshCompletePayload = serde_json::from_str(raw)
                .map_err(|e| anyhow::anyhow!("Invalid refresh result JSON: {e}"))?;

            let outcome = match parsed {
                RefreshCompletePayload::Refreshed { spec } => {
                    Ok(StreamRefreshOutcome::Refreshed(spec))
                }
                RefreshCompletePayload::FormatChanged { spec, reason } => {
                    Ok(StreamRefreshOutcome::FormatChanged(spec, reason))
                }
                RefreshCompletePayload::AuthRequired {
                    provider_id,
                    message,
                } => Ok(StreamRefreshOutcome::AuthRequired {
                    provider_id,
                    message,
                }),
                RefreshCompletePayload::Cancelled => Err(StreamError::Cancelled),
                RefreshCompletePayload::Error { message } => Err(StreamError::Network(
                    if message.trim().is_empty() {
                        "Stream refresh failed".to_string()
                    } else {
                        message
                    },
                )),
            };

            let maybe_entry = pending_refreshes()
                .lock()
                .ok()
                .and_then(|mut map| map.remove(&request_id));
            if let Some(entry) = maybe_entry {
                let _ = entry.tx.send(outcome);
            }
            Ok(LUMINA_OK)
        },
    )
}

/// Returns the current global `network_epoch` (starts at `1`, incremented atomically on real
/// network/route/VPN changes).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_network_get_epoch() -> u64 {
    current_network_epoch()
}

/// Registers (or clears when null) the Dart `NativeCallable.listener` callback invoked whenever
/// `NetworkMonitor` advances `network_epoch`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_network_set_epoch_callback(cb: Option<NetworkEpochCallback>) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_network_set_epoch_callback",
        || {
            if let Ok(mut guard) = NETWORK_EPOCH_CB.write() {
                *guard = cb;
            }
            Ok(LUMINA_OK)
        },
    )
}

/// Cancels any active streaming playback and pending stream refreshes belonging to `provider_id`
/// (invoked by Dart's `AuthManager.tripAuthRequired` circuit breaker).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_streaming_cancel_provider(provider_id: *const c_char) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_streaming_cancel_provider",
        || {
            if provider_id.is_null() {
                set_last_error("provider_id is null");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let pid = unsafe { CStr::from_ptr(provider_id) }
                .to_str()
                .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in provider_id: {e}"))?
                .trim()
                .to_string();
            if pid.is_empty() {
                set_last_error("provider_id must be non-empty");
                return Ok(LUMINA_ERR_GENERAL);
            }

            fail_pending_refreshes_for_provider(&pid);
            let hook = PROVIDER_CANCEL_HOOK.read().ok().and_then(|g| g.clone());
            if let Some(func) = hook {
                func(&pid);
            }
            Ok(LUMINA_OK)
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lumina_string_free;
    use core_types::StreamKey;
    use std::collections::BTreeMap;
    use std::ffi::CString;
    use std::sync::atomic::AtomicU64;

    static LAST_TEST_EPOCH: AtomicU64 = AtomicU64::new(0);
    static TEST_BRIDGE_LOCK: Mutex<()> = Mutex::new(());

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
        assert_eq!(lumina_network_set_epoch_callback(Some(test_epoch_cb)), LUMINA_OK);
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
        assert_eq!(
            cancelled_provider.lock().unwrap().as_deref(),
            Some("tidal")
        );
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
        let outcome = rt.block_on(handler.refresh_after_403(req, &cancel)).unwrap();
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
    static SYNC_EPOCH_DONE: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);
    static SYNC_REFRESH_ENTERED: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);
    static SYNC_REFRESH_DONE: std::sync::atomic::AtomicBool =
        std::sync::atomic::AtomicBool::new(false);

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
}
