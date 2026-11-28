pub mod handler;

#[cfg(test)]
pub(crate) static TEST_BRIDGE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests;

pub use handler::{
    FfiStreamRefreshHandler, NetworkEpochCallback, ProviderCancelHook, StreamRefreshCallback,
    cancel_all_pending_refreshes, ffi_stream_refresh_handler, notify_network_epoch_changed,
    register_provider_cancel_hook,
};

use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
};
use core_audio::streaming::{StreamError, StreamRefreshOutcome, current_network_epoch};
use handler::{
    NETWORK_EPOCH_CB, PROVIDER_CANCEL_HOOK, RefreshCompletePayload, STREAM_REFRESH_CB,
    fail_pending_refreshes_for_provider, pending_refreshes,
};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

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
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_stream_complete_refresh", || {
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
            RefreshCompletePayload::Refreshed { spec } => Ok(StreamRefreshOutcome::Refreshed(spec)),
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
            RefreshCompletePayload::Error { message } => {
                Err(StreamError::Network(if message.trim().is_empty() {
                    "Stream refresh failed".to_string()
                } else {
                    message
                }))
            }
        };

        let maybe_entry = pending_refreshes()
            .lock()
            .ok()
            .and_then(|mut map| map.remove(&request_id));
        if let Some(entry) = maybe_entry {
            let _ = entry.tx.send(outcome);
        }
        Ok(LUMINA_OK)
    })
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
