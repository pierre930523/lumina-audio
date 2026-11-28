//! Lock-free atomic state coordinating RT callback micro-fades.

use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};

/// Lock-free fade target signaled from control/decode threads to the RT audio callback.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FadeTarget {
    Playing = 0,
    PauseFadeOut = 1,
    StopFadeOut = 2,
    SeekFadeOut = 3,
    SkipSilence = 4,
}

impl FadeTarget {
    #[inline]
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::PauseFadeOut,
            2 => Self::StopFadeOut,
            3 => Self::SeekFadeOut,
            4 => Self::SkipSilence,
            _ => Self::Playing,
        }
    }
}

/// Lock-free atomic state coordinating 5–15 ms RT callback micro-fades without mutexes or allocations.
#[derive(Debug)]
pub struct AudioFadeControl {
    target: AtomicU8,
    fade_out_done: AtomicBool,
    seek_fade_epoch: AtomicU64,
    seek_ready_epoch: AtomicU64,
    fade_in_enabled: AtomicBool,
    fade_out_enabled: AtomicBool,
    has_audible_output: AtomicBool,
}

impl AudioFadeControl {
    pub fn new(fade_in_enabled: bool, fade_out_enabled: bool, start_paused: bool) -> Self {
        Self {
            target: AtomicU8::new(if start_paused {
                FadeTarget::PauseFadeOut as u8
            } else {
                FadeTarget::Playing as u8
            }),
            fade_out_done: AtomicBool::new(start_paused || !fade_out_enabled),
            seek_fade_epoch: AtomicU64::new(0),
            seek_ready_epoch: AtomicU64::new(0),
            fade_in_enabled: AtomicBool::new(fade_in_enabled),
            fade_out_enabled: AtomicBool::new(fade_out_enabled),
            has_audible_output: AtomicBool::new(false),
        }
    }

    /// Constructs an [`AudioFadeControl`] honoring Strict Bit-Perfect and DSD/DoP invariants:
    /// both fade-in and fade-out are disabled when `is_dsd_or_dop || strict_bit_perfect`.
    pub fn new_for_mode(is_dsd_or_dop: bool, strict_bit_perfect: bool, start_paused: bool) -> Self {
        let allow_fade = !is_dsd_or_dop && !strict_bit_perfect;
        Self::new(allow_fade, allow_fade, start_paused)
    }

    /// Updates fade permissions when Strict Bit-Perfect mode is toggled at runtime.
    pub fn set_strict_bit_perfect(&self, strict_bit_perfect: bool, is_dsd_or_dop: bool) {
        let allow_fade = !strict_bit_perfect && !is_dsd_or_dop;
        self.fade_in_enabled.store(allow_fade, Ordering::Release);
        self.fade_out_enabled.store(allow_fade, Ordering::Release);
        if !allow_fade {
            self.fade_out_done.store(true, Ordering::Release);
        }
    }

    #[inline]
    pub fn target(&self) -> FadeTarget {
        FadeTarget::from_u8(self.target.load(Ordering::Acquire))
    }

    #[inline]
    pub fn is_fade_out_done(&self) -> bool {
        self.fade_out_done.load(Ordering::Acquire)
    }

    #[inline]
    pub fn fade_in_enabled(&self) -> bool {
        self.fade_in_enabled.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn fade_out_enabled(&self) -> bool {
        self.fade_out_enabled.load(Ordering::Relaxed)
    }

    #[inline]
    pub fn mark_fade_out_done(&self) {
        self.fade_out_done.store(true, Ordering::Release);
    }

    #[inline]
    pub fn mark_audible(&self) {
        if !self.has_audible_output.load(Ordering::Relaxed) {
            self.has_audible_output.store(true, Ordering::Release);
        }
    }

    #[inline]
    pub fn mark_silent(&self) {
        self.has_audible_output.store(false, Ordering::Release);
        self.fade_out_done.store(true, Ordering::Release);
    }

    pub fn request_pause_fade_out(&self) {
        if self.target() == FadeTarget::PauseFadeOut {
            return;
        }
        let immediate =
            !self.fade_out_enabled() || !self.has_audible_output.load(Ordering::Acquire);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::PauseFadeOut as u8, Ordering::Release);
    }

    pub fn request_play_fade_in(&self) {
        self.target
            .store(FadeTarget::Playing as u8, Ordering::Release);
    }

    pub fn request_stop_fade_out(&self) {
        if self.target() == FadeTarget::StopFadeOut {
            return;
        }
        let already_silent = (self.target() == FadeTarget::PauseFadeOut
            || self.target() == FadeTarget::SkipSilence)
            && self.is_fade_out_done();
        let immediate = already_silent
            || !self.fade_out_enabled()
            || !self.has_audible_output.load(Ordering::Acquire);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::StopFadeOut as u8, Ordering::Release);
    }

    pub fn request_skip_fade_out(&self) {
        if self.target() == FadeTarget::SkipSilence {
            return;
        }
        let already_silent = (self.target() == FadeTarget::PauseFadeOut
            || self.target() == FadeTarget::StopFadeOut)
            && self.is_fade_out_done();
        let immediate = already_silent
            || !self.fade_out_enabled()
            || !self.has_audible_output.load(Ordering::Acquire);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::SkipSilence as u8, Ordering::Release);
    }

    pub fn request_seek_fade_out(&self, seek_epoch: u64) {
        let already_silent = (self.target() == FadeTarget::PauseFadeOut
            || self.target() == FadeTarget::SeekFadeOut)
            && self.is_fade_out_done();
        let immediate = already_silent
            || !self.fade_out_enabled()
            || !self.has_audible_output.load(Ordering::Acquire);
        self.seek_fade_epoch.store(seek_epoch, Ordering::Release);
        self.fade_out_done.store(immediate, Ordering::Release);
        self.target
            .store(FadeTarget::SeekFadeOut as u8, Ordering::Release);
    }

    pub fn notify_seek_ready(&self, seek_epoch: u64, still_paused: bool) {
        self.seek_ready_epoch.store(seek_epoch, Ordering::Release);
        if still_paused {
            self.fade_out_done.store(true, Ordering::Release);
            let _ = self.target.compare_exchange(
                FadeTarget::SeekFadeOut as u8,
                FadeTarget::PauseFadeOut as u8,
                Ordering::SeqCst,
                Ordering::Relaxed,
            );
        } else {
            let _ = self.target.compare_exchange(
                FadeTarget::SeekFadeOut as u8,
                FadeTarget::Playing as u8,
                Ordering::SeqCst,
                Ordering::Relaxed,
            );
        }
    }
}
