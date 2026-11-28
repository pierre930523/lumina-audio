use crate::error::string_to_c_char;
use core_audio::streaming::{
    StreamError, StreamRefreshHandler, StreamRefreshOutcome, StreamRefreshRequest,
};
use core_types::StreamSourceSpec;
use serde::Deserialize;
use std::collections::HashMap;
use std::os::raw::c_char;
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

pub(super) struct PendingRefreshEntry {
    pub(super) provider_id: String,
    pub(super) tx: oneshot::Sender<Result<StreamRefreshOutcome, StreamError>>,
}

pub(super) static STREAM_REFRESH_CB: RwLock<Option<StreamRefreshCallback>> = RwLock::new(None);
pub(super) static NETWORK_EPOCH_CB: RwLock<Option<NetworkEpochCallback>> = RwLock::new(None);
pub(super) static PROVIDER_CANCEL_HOOK: RwLock<Option<ProviderCancelHook>> = RwLock::new(None);
static NEXT_REFRESH_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static PENDING_REFRESHES: OnceLock<Mutex<HashMap<u64, PendingRefreshEntry>>> = OnceLock::new();

pub(super) fn pending_refreshes() -> &'static Mutex<HashMap<u64, PendingRefreshEntry>> {
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
pub(super) fn fail_pending_refreshes_for_provider(provider_id: &str) {
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

/// Registers an internal Rust callback invoked by [`crate::streaming_bridge::lumina_streaming_cancel_provider`]
/// so the active `AudioPlayer` cancels playback if its current stream matches `provider_id`.
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
/// and [`crate::streaming_bridge::lumina_stream_complete_refresh`].
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
pub(super) enum RefreshCompletePayload {
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
