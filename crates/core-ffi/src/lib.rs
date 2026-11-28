#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod engine;
pub mod error;
pub mod l1_cache;
pub mod l2_cache;
pub mod library;
pub mod lyrics;
pub mod playback;
pub mod profiles;
pub mod providers;
pub mod server;
pub mod sidecar;
pub mod signal_path;
pub mod streaming_bridge;
pub mod visualizer;
pub mod zones;

pub use error::lumina_last_error_json;
pub use l1_cache::*;
pub use l2_cache::*;
pub use library::*;
pub use lyrics::*;
pub use playback::*;
pub use providers::lumina_provider_list;
pub use sidecar::*;
pub use streaming_bridge::*;
pub use visualizer::*;

use engine::get_engine;
use error::{LUMINA_OK, catch_unwind_ffi, string_to_c_char, take_last_error};
use std::ffi::CString;
use std::os::raw::{c_char, c_int};

/// Entrypoint bridge surface to be bound via `flutter_rust_bridge` in Phase 2.
pub fn core_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_version() -> *const c_char {
    // Static constant string: valid for duration of process
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_init() -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_init", || {
        let engine = get_engine();
        engine.init_player(false);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_init_headless() -> c_int {
    catch_unwind_ffi(
        crate::error::LUMINA_ERR_GENERAL,
        "lumina_init_headless",
        || {
            let engine = get_engine();
            engine.init_player(true);
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_shutdown() -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_shutdown", || {
        let engine = get_engine();
        engine.reset();
        Ok(LUMINA_OK)
    })
}

/// Allocates a zeroed buffer of `len + 1` bytes on the Rust heap for Dart/FFI UTF-8 string passing.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_bytes_alloc(len: usize) -> *mut u8 {
    let mut buf = vec![0u8; len.saturating_add(1)];
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

/// Frees a buffer allocated via `lumina_bytes_alloc(len)`.
///
/// # Safety
/// `ptr` must either be null or the exact pointer previously returned by `lumina_bytes_alloc(len)`,
/// paired with the same `len`, and must not be freed more than once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumina_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        let total = len.saturating_add(1);
        unsafe {
            drop(Vec::from_raw_parts(ptr, total, total));
        }
    }
}

/// Safely deallocates a CString allocated on the Rust heap.
/// MUST be called by Dart/FFI clients for any `*mut c_char` returned by Lumina FFI.
///
/// # Safety
/// `ptr` must either be null or a valid pointer previously returned by a Lumina FFI
/// function via `CString::into_raw()`, and must not be freed more than once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lumina_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

/// Retrieves and clears the last error recorded on this thread.
/// The returned pointer must be freed with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_last_error_message() -> *mut c_char {
    let engine = get_engine();
    if let Some(err) = take_last_error() {
        if let Ok(mut err_lock) = engine.async_last_error.write()
            && err_lock.as_deref() == Some(err.as_str())
        {
            *err_lock = None;
        }
        if let Ok(mut s_lock) = engine.last_structured_error.write()
            && s_lock.as_ref().is_some_and(|e| e.message == err)
        {
            *s_lock = None;
        }
        return string_to_c_char(&err);
    }
    if let Some(player) = engine.player_clone()
        && let Some(err) = player.take_last_error()
    {
        if let Ok(mut s_lock) = engine.last_structured_error.write()
            && s_lock.as_ref().is_some_and(|e| e.message == err)
        {
            *s_lock = None;
        }
        return string_to_c_char(&err);
    }
    if let Ok(mut err_lock) = engine.async_last_error.write()
        && let Some(err) = err_lock.take()
    {
        if let Ok(mut s_lock) = engine.last_structured_error.write() {
            *s_lock = None;
        }
        return string_to_c_char(&err);
    }
    if let Ok(mut s_lock) = engine.last_structured_error.write()
        && let Some(err) = s_lock.take()
    {
        return string_to_c_char(&err.message);
    }
    std::ptr::null_mut()
}
