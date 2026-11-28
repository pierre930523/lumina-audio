use core_types::{LuminaError, LuminaErrorCode};
use std::cell::RefCell;
use std::ffi::CString;
use std::os::raw::c_char;

pub const LUMINA_OK: i32 = 0;
pub const LUMINA_ERR_GENERAL: i32 = -1;
pub const LUMINA_ERR_NULL_POINTER: i32 = -2;
pub const LUMINA_ERR_INVALID_UTF8: i32 = -3;
pub const LUMINA_ERR_NOT_INITIALIZED: i32 = -4;
pub const LUMINA_ERR_AUDIO_BACKEND: i32 = -5;
pub const LUMINA_ERR_DATABASE: i32 = -6;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
    static LAST_STRUCTURED_ERROR: RefCell<Option<LuminaError>> = const { RefCell::new(None) };
}

pub fn set_last_error(msg: impl Into<String>) {
    let s = msg.into();
    let structured = LuminaError::new(LuminaErrorCode::Internal, s.clone());
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(s);
    });
    LAST_STRUCTURED_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(structured);
    });
}

pub fn set_last_structured_error(err: LuminaError) {
    let msg = err.message.clone();
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(msg);
    });
    LAST_STRUCTURED_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(err);
    });
}

pub fn take_last_error() -> Option<String> {
    let msg = LAST_ERROR.with(|cell| cell.borrow_mut().take());
    if msg.is_some() {
        LAST_STRUCTURED_ERROR.with(|cell| {
            let _ = cell.borrow_mut().take();
        });
    }
    msg
}

pub fn take_last_structured_error() -> Option<LuminaError> {
    let structured = LAST_STRUCTURED_ERROR.with(|cell| cell.borrow_mut().take());
    let raw = LAST_ERROR.with(|cell| cell.borrow_mut().take());
    structured.or_else(|| raw.map(|m| LuminaError::new(LuminaErrorCode::Internal, m)))
}

pub fn clear_last_errors() {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = None;
    });
    LAST_STRUCTURED_ERROR.with(|cell| {
        *cell.borrow_mut() = None;
    });
}

/// Synthesizes a structured [`LuminaError`] from legacy `(message, code, provider)` fields.
pub fn synthesize_lumina_error(
    message: String,
    code_str: Option<&str>,
    provider: Option<String>,
) -> LuminaError {
    let code = match code_str.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("auth_required" | "stream_auth_required") => LuminaErrorCode::StreamAuthRequired,
        Some("device_open_failed") => LuminaErrorCode::DeviceOpenFailed,
        Some("exclusive_mode_conflict" | "device_in_use") => LuminaErrorCode::ExclusiveModeConflict,
        Some("device_not_found") => LuminaErrorCode::DeviceNotFound,
        Some("device_lost") => LuminaErrorCode::DeviceLost,
        Some("stream_resolve_timeout" | "timeout") => LuminaErrorCode::StreamResolveTimeout,
        Some("network_disconnected") => LuminaErrorCode::NetworkDisconnected,
        Some("http_error") => LuminaErrorCode::HttpError,
        Some("decode_failed") => LuminaErrorCode::DecodeFailed,
        Some("unsupported_format") => LuminaErrorCode::UnsupportedFormat,
        Some("invalid_command") => LuminaErrorCode::InvalidCommand,
        Some("invalid_state") => LuminaErrorCode::InvalidState,
        Some("not_initialized") => LuminaErrorCode::NotInitialized,
        Some("database_error") => LuminaErrorCode::DatabaseError,
        _ => LuminaErrorCode::Internal,
    };
    let retryable = matches!(
        code,
        LuminaErrorCode::DeviceOpenFailed
            | LuminaErrorCode::ExclusiveModeConflict
            | LuminaErrorCode::DeviceLost
            | LuminaErrorCode::StreamResolveTimeout
            | LuminaErrorCode::NetworkDisconnected
    );
    let mut err = LuminaError::new(code, message).with_retryable(retryable);
    if let Some(p) = provider {
        err = err.with_provider(p);
    }
    err
}

/// Helper that catches Rust panics and maps errors to thread-local error string & structured error.
pub fn catch_unwind_ffi<F, R>(default_error_val: R, op_name: &'static str, f: F) -> R
where
    F: FnOnce() -> anyhow::Result<R>,
{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(val)) => val,
        Ok(Err(err)) => {
            set_last_structured_error(LuminaError::new(
                LuminaErrorCode::Internal,
                format!("{}: {}", op_name, err),
            ));
            default_error_val
        }
        Err(panic_payload) => {
            let msg = if let Some(s) = panic_payload.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic payload".to_string()
            };
            set_last_structured_error(
                LuminaError::new(
                    LuminaErrorCode::Internal,
                    format!("Panic in {}: {}", op_name, msg),
                )
                .with_details("rust_panic"),
            );
            default_error_val
        }
    }
}

/// Helper to convert a Rust string into a raw C pointer that must be freed with lumina_string_free.
pub fn string_to_c_char(s: &str) -> *mut c_char {
    match CString::new(s) {
        Ok(c_str) => c_str.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Retrieves and clears the last structured [`core_types::LuminaError`] as JSON.
/// Returns NULL when no error is pending. Returned non-null pointers MUST be freed with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_last_error_json() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_last_error_json", || {
        let engine = crate::engine::get_engine();
        if let Some(err) = take_last_structured_error() {
            if let Ok(mut guard) = engine.last_structured_error.write()
                && guard.as_ref().is_some_and(|e| e.message == err.message)
            {
                *guard = None;
            }
            if let Ok(mut err_lock) = engine.async_last_error.write()
                && err_lock.as_deref() == Some(err.message.as_str())
            {
                *err_lock = None;
            }
            let json = serde_json::to_string(&err)?;
            return Ok(string_to_c_char(&json));
        }
        if let Some(err) = engine.take_structured_error() {
            let json = serde_json::to_string(&err)?;
            return Ok(string_to_c_char(&json));
        }
        Ok(std::ptr::null_mut())
    })
}
