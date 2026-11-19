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
}

pub fn set_last_error(msg: impl Into<String>) {
    LAST_ERROR.with(|cell| {
        *cell.borrow_mut() = Some(msg.into());
    });
}

pub fn take_last_error() -> Option<String> {
    LAST_ERROR.with(|cell| cell.borrow_mut().take())
}

/// Helper that catches Rust panics and maps errors to thread-local error string.
pub fn catch_unwind_ffi<F, R>(default_error_val: R, op_name: &'static str, f: F) -> R
where
    F: FnOnce() -> anyhow::Result<R>,
{
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(val)) => val,
        Ok(Err(err)) => {
            set_last_error(format!("{}: {}", op_name, err));
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
            set_last_error(format!("Panic in {}: {}", op_name, msg));
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
