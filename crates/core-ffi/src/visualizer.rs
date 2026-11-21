use crate::error::{catch_unwind_ffi, LUMINA_ERR_GENERAL, LUMINA_OK};
use core_audio::visualizer::{global_tap, NUM_BANDS};
use std::os::raw::c_int;

/// Enables or disables the real-time audio visualizer sidechain tap and analysis thread.
/// Takes effect immediately without interrupting audio playback or affecting Bit-Perfect output.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_visualizer_set_enabled(enabled: c_int) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_visualizer_set_enabled", || {
        global_tap().set_enabled(enabled != 0);
        Ok(LUMINA_OK)
    })
}

/// Returns whether the real-time audio visualizer tap is currently enabled (1 = enabled, 0 = disabled).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_visualizer_is_enabled() -> c_int {
    catch_unwind_ffi(0, "lumina_visualizer_is_enabled", || {
        Ok(if global_tap().is_enabled() { 1 } else { 0 })
    })
}

/// Copies up to `max_count` (typically 64) normalized [0.0, 1.0] spectrum band magnitudes into `out_ptr`.
/// Returns the number of bands actually copied (64 on success, 0 on failure / null pointer / insufficient buffer).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_visualizer_get_bands(out_ptr: *mut f32, max_count: u32) -> c_int {
    if out_ptr.is_null() || max_count < NUM_BANDS as u32 {
        return 0;
    }
    catch_unwind_ffi(0, "lumina_visualizer_get_bands", || {
        let mut bands = [0.0f32; NUM_BANDS];
        if global_tap().get_latest_bands(&mut bands) {
            unsafe {
                std::ptr::copy_nonoverlapping(bands.as_ptr(), out_ptr, NUM_BANDS);
            }
            Ok(NUM_BANDS as c_int)
        } else {
            Ok(0)
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_visualizer_lifecycle() {
        assert_eq!(lumina_visualizer_set_enabled(1), LUMINA_OK);
        assert_eq!(lumina_visualizer_is_enabled(), 1);

        let mut bands = [0.0f32; 64];
        let copied = lumina_visualizer_get_bands(bands.as_mut_ptr(), 64);
        assert_eq!(copied, 64);

        // Null pointer check
        assert_eq!(lumina_visualizer_get_bands(std::ptr::null_mut(), 64), 0);

        // Insufficient buffer check (< 64)
        assert_eq!(lumina_visualizer_get_bands(bands.as_mut_ptr(), 32), 0);

        assert_eq!(lumina_visualizer_set_enabled(0), LUMINA_OK);
        assert_eq!(lumina_visualizer_is_enabled(), 0);
    }
}
