use std::sync::Arc;

use windows::Win32::Media::Audio::{IAudioClient, IAudioClock, IAudioRenderClient};
use windows::core::HRESULT;

use super::com::Win32Event;

/// Trait abstracting COM WASAPI stream operations so `run_wasapi_render_loop` can be tested
/// deterministically with real Win32 events and fake COM ops.
#[doc(hidden)]
pub trait WasapiStreamOps {
    fn start(&mut self) -> Result<(), HRESULT>;
    fn stop(&mut self) -> Result<(), HRESULT>;
    fn reset(&mut self) -> Result<(), HRESULT>;
    fn reset_buf_event(&mut self);
    fn current_padding(&mut self) -> Result<u32, HRESULT>;
    fn get_buffer(&mut self, num_frames: u32) -> Result<*mut u8, HRESULT>;
    fn release_buffer(&mut self, num_frames_written: u32, flags: u32) -> Result<(), HRESULT>;
    fn clock_frequency(&mut self) -> Option<u64>;
    fn clock_position(&mut self) -> Result<(u64, u64), HRESULT>;
}

pub(super) struct RealWasapiStreamOps {
    pub(super) client: IAudioClient,
    pub(super) render: IAudioRenderClient,
    pub(super) clock: Option<IAudioClock>,
    pub(super) buf_event: Arc<Win32Event>,
}

impl WasapiStreamOps for RealWasapiStreamOps {
    fn start(&mut self) -> Result<(), HRESULT> {
        unsafe { self.client.Start() }.map_err(|e| e.code())
    }

    fn stop(&mut self) -> Result<(), HRESULT> {
        unsafe { self.client.Stop() }.map_err(|e| e.code())
    }

    fn reset(&mut self) -> Result<(), HRESULT> {
        unsafe { self.client.Reset() }.map_err(|e| e.code())
    }

    fn reset_buf_event(&mut self) {
        self.buf_event.reset();
    }

    fn current_padding(&mut self) -> Result<u32, HRESULT> {
        unsafe { self.client.GetCurrentPadding() }.map_err(|e| e.code())
    }

    fn get_buffer(&mut self, num_frames: u32) -> Result<*mut u8, HRESULT> {
        unsafe { self.render.GetBuffer(num_frames) }.map_err(|e| e.code())
    }

    fn release_buffer(&mut self, num_frames_written: u32, flags: u32) -> Result<(), HRESULT> {
        unsafe { self.render.ReleaseBuffer(num_frames_written, flags) }.map_err(|e| e.code())
    }

    fn clock_frequency(&mut self) -> Option<u64> {
        self.clock
            .as_ref()
            .and_then(|c| unsafe { c.GetFrequency().ok() })
            .filter(|&f| f > 0)
    }

    fn clock_position(&mut self) -> Result<(u64, u64), HRESULT> {
        if let Some(c) = &self.clock {
            let mut pos = 0u64;
            let mut qpc = 0u64;
            unsafe { c.GetPosition(&mut pos, Some(&mut qpc)) }.map_err(|e| e.code())?;
            Ok((pos, qpc))
        } else {
            Err(HRESULT(-1))
        }
    }
}
