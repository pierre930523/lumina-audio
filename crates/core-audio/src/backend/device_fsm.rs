use std::thread;
use std::time::{Duration, Instant};

use crate::error::BackendError;

/// Default post-release guard delay after dropping an exclusive hardware handle
/// (WASAPI Exclusive / ASIO / CoreAudio Hog Mode) so USB DAC firmware and OS drivers
/// finish releasing exclusive locks and resetting clocks before the next open.
pub const DEFAULT_POST_RELEASE_GUARD_DELAY: Duration = Duration::from_millis(25);

/// Explicit lifecycle state machine for an audio output device session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum OutputDeviceState {
    Idle,
    Opening,
    Running,
    Reconfiguring,
    Stopping,
    Faulted,
}

impl OutputDeviceState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Opening => "opening",
            Self::Running => "running",
            Self::Reconfiguring => "reconfiguring",
            Self::Stopping => "stopping",
            Self::Faulted => "faulted",
        }
    }
}

/// Deterministic lifecycle FSM enforcing safe exclusive-mode stop -> release -> guard delay ->
/// capability query -> reopen sequences without panics, deadlocks, or overlapping handle ownership.
#[derive(Debug, Clone)]
pub struct OutputDeviceFsm {
    state: OutputDeviceState,
    post_release_guard_delay: Duration,
    transition_history: Vec<OutputDeviceState>,
    transition_count: u64,
    handle_drop_count: u64,
    reconfigure_count: u64,
    guard_delay_sleeps: u64,
    last_guard_delay_elapsed: Option<Duration>,
}

impl Default for OutputDeviceFsm {
    fn default() -> Self {
        Self::new()
    }
}

impl OutputDeviceFsm {
    pub fn new() -> Self {
        Self::with_guard_delay(DEFAULT_POST_RELEASE_GUARD_DELAY)
    }

    pub fn with_guard_delay(post_release_guard_delay: Duration) -> Self {
        Self {
            state: OutputDeviceState::Idle,
            post_release_guard_delay,
            transition_history: vec![OutputDeviceState::Idle],
            transition_count: 0,
            handle_drop_count: 0,
            reconfigure_count: 0,
            guard_delay_sleeps: 0,
            last_guard_delay_elapsed: None,
        }
    }

    #[inline]
    pub const fn state(&self) -> OutputDeviceState {
        self.state
    }

    #[inline]
    pub const fn post_release_guard_delay(&self) -> Duration {
        self.post_release_guard_delay
    }

    pub fn set_post_release_guard_delay(&mut self, delay: Duration) {
        self.post_release_guard_delay = delay;
    }

    pub fn transition_history(&self) -> &[OutputDeviceState] {
        &self.transition_history
    }

    #[inline]
    pub const fn transition_count(&self) -> u64 {
        self.transition_count
    }

    #[inline]
    pub const fn handle_drop_count(&self) -> u64 {
        self.handle_drop_count
    }

    #[inline]
    pub const fn reconfigure_count(&self) -> u64 {
        self.reconfigure_count
    }

    #[inline]
    pub const fn guard_delay_sleeps(&self) -> u64 {
        self.guard_delay_sleeps
    }

    #[inline]
    pub const fn last_guard_delay_elapsed(&self) -> Option<Duration> {
        self.last_guard_delay_elapsed
    }

    /// Validates legal state transitions for the output device lifecycle.
    pub const fn can_transition(from: OutputDeviceState, to: OutputDeviceState) -> bool {
        use OutputDeviceState::*;
        matches!(
            (from, to),
            (Idle, Opening)
                | (Idle, Reconfiguring)
                | (Idle, Faulted)
                | (Opening, Running)
                | (Opening, Stopping)
                | (Opening, Idle)
                | (Opening, Faulted)
                | (Running, Reconfiguring)
                | (Running, Stopping)
                | (Running, Faulted)
                | (Reconfiguring, Stopping)
                | (Reconfiguring, Idle)
                | (Reconfiguring, Opening)
                | (Reconfiguring, Faulted)
                | (Stopping, Idle)
                | (Stopping, Faulted)
                | (Faulted, Stopping)
                | (Faulted, Idle)
                | (Faulted, Reconfiguring)
                | (Faulted, Opening)
        )
    }

    /// Transitions the FSM to `next` if valid, recording the transition in history.
    pub fn transition(&mut self, next: OutputDeviceState) -> Result<(), BackendError> {
        if self.state == next {
            return Ok(());
        }
        if !Self::can_transition(self.state, next) {
            return Err(BackendError::InvalidState(format!(
                "Invalid output device transition: {:?} -> {:?}",
                self.state, next
            )));
        }
        self.state = next;
        self.transition_count = self.transition_count.saturating_add(1);
        self.transition_history.push(next);
        Ok(())
    }

    /// Forces transition to `Faulted` (always allowed from any state).
    pub fn mark_faulted(&mut self) {
        if self.state != OutputDeviceState::Faulted {
            self.state = OutputDeviceState::Faulted;
            self.transition_count = self.transition_count.saturating_add(1);
            self.transition_history.push(OutputDeviceState::Faulted);
        }
    }

    /// Resets from `Faulted` back to `Idle` once hardware handles have been released.
    pub fn reset_from_fault(&mut self) -> Result<(), BackendError> {
        if self.state == OutputDeviceState::Faulted {
            self.transition(OutputDeviceState::Idle)
        } else {
            Ok(())
        }
    }

    fn apply_post_release_guard_delay(&mut self) {
        let delay = self.post_release_guard_delay;
        if !delay.is_zero() {
            let start = Instant::now();
            thread::sleep(delay);
            self.last_guard_delay_elapsed = Some(start.elapsed());
            self.guard_delay_sleeps = self.guard_delay_sleeps.saturating_add(1);
        } else {
            self.last_guard_delay_elapsed = Some(Duration::ZERO);
        }
    }

    /// Stops and drops an active hardware handle cleanly, sleeping `post_release_guard_delay`
    /// after drop before transitioning to `Idle`.
    pub fn stop_and_release_sequence<H, S>(
        &mut self,
        active_handle: &mut Option<H>,
        mut stop_and_drain: S,
    ) -> Result<(), BackendError>
    where
        S: FnMut(&mut H),
    {
        if let Some(mut handle) = active_handle.take() {
            if self.state != OutputDeviceState::Stopping {
                let _ = self.transition(OutputDeviceState::Stopping);
            }
            stop_and_drain(&mut handle);
            drop(handle);
            self.handle_drop_count = self.handle_drop_count.saturating_add(1);
            self.apply_post_release_guard_delay();
        } else if self.state == OutputDeviceState::Running
            || self.state == OutputDeviceState::Opening
            || self.state == OutputDeviceState::Reconfiguring
        {
            let _ = self.transition(OutputDeviceState::Stopping);
        }
        self.transition(OutputDeviceState::Idle)
    }

    /// Enforces the strict exclusive-mode reconfigure sequence:
    /// 1. Mute & stop/drain current stream (`Running -> Reconfiguring -> Stopping`),
    /// 2. Drop exclusive handle completely + sleep `post_release_guard_delay` (`Idle`),
    /// 3. Query device capabilities & reopen with new format (`Opening -> Running`),
    /// 4. On failure: if `!strict_bit_perfect`, attempt `fallback_open` (if provided);
    ///    otherwise transition cleanly to `Faulted` without panic or deadlock.
    pub fn reconfigure_sequence<H, S, O, F>(
        &mut self,
        active_handle: &mut Option<H>,
        strict_bit_perfect: bool,
        mut stop_and_drain: S,
        mut query_and_open: O,
        mut fallback_open: Option<F>,
    ) -> Result<H, BackendError>
    where
        S: FnMut(&mut H),
        O: FnMut() -> Result<H, BackendError>,
        F: FnMut(&BackendError) -> Result<H, BackendError>,
    {
        // Step 1: Running/Idle/Faulted -> Reconfiguring -> Stopping
        if self.state == OutputDeviceState::Running
            || self.state == OutputDeviceState::Idle
            || self.state == OutputDeviceState::Faulted
        {
            let _ = self.transition(OutputDeviceState::Reconfiguring);
        }

        if let Some(mut handle) = active_handle.take() {
            let _ = self.transition(OutputDeviceState::Stopping);
            stop_and_drain(&mut handle);
            // Step 2: Explicitly drop exclusive handle BEFORE guard delay and reopen.
            drop(handle);
            self.handle_drop_count = self.handle_drop_count.saturating_add(1);
            self.apply_post_release_guard_delay();
        } else if self.state == OutputDeviceState::Reconfiguring
            || self.state == OutputDeviceState::Opening
        {
            let _ = self.transition(OutputDeviceState::Stopping);
        }

        self.transition(OutputDeviceState::Idle)?;

        // Step 3: Idle -> Opening -> query & open
        self.transition(OutputDeviceState::Opening)?;
        match query_and_open() {
            Ok(new_handle) => {
                self.transition(OutputDeviceState::Running)?;
                self.reconfigure_count = self.reconfigure_count.saturating_add(1);
                Ok(new_handle)
            }
            Err(primary_err) => {
                // Step 4: Strict Bit-Perfect NEVER allows fallback.
                if !strict_bit_perfect
                    && let Some(ref mut fb) = fallback_open
                    && let Ok(fb_handle) = fb(&primary_err)
                {
                    self.transition(OutputDeviceState::Running)?;
                    self.reconfigure_count = self.reconfigure_count.saturating_add(1);
                    return Ok(fb_handle);
                }
                self.mark_faulted();
                Err(primary_err)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct TrackedHandle {
        dropped: Arc<AtomicBool>,
        stopped: bool,
    }

    impl Drop for TrackedHandle {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
        }
    }

    #[test]
    fn reconfigure_sequence_drops_handle_before_guard_delay_and_reopen() {
        let mut fsm = OutputDeviceFsm::with_guard_delay(Duration::from_millis(5));
        fsm.transition(OutputDeviceState::Opening).unwrap();
        fsm.transition(OutputDeviceState::Running).unwrap();

        let old_dropped = Arc::new(AtomicBool::new(false));
        let mut active = Some(TrackedHandle {
            dropped: Arc::clone(&old_dropped),
            stopped: false,
        });
        let new_dropped = Arc::new(AtomicBool::new(false));

        let reopened = fsm
            .reconfigure_sequence(
                &mut active,
                true,
                |h| {
                    h.stopped = true;
                },
                || {
                    assert!(
                        old_dropped.load(Ordering::SeqCst),
                        "old exclusive handle MUST be dropped before reopening"
                    );
                    Ok(TrackedHandle {
                        dropped: Arc::clone(&new_dropped),
                        stopped: false,
                    })
                },
                None::<fn(&BackendError) -> Result<TrackedHandle, BackendError>>,
            )
            .unwrap();

        assert_eq!(fsm.state(), OutputDeviceState::Running);
        assert_eq!(fsm.handle_drop_count(), 1);
        assert_eq!(fsm.reconfigure_count(), 1);
        assert_eq!(fsm.guard_delay_sleeps(), 1);
        assert!(fsm.last_guard_delay_elapsed().unwrap() >= Duration::from_millis(4));
        assert_eq!(
            fsm.transition_history(),
            &[
                OutputDeviceState::Idle,
                OutputDeviceState::Opening,
                OutputDeviceState::Running,
                OutputDeviceState::Reconfiguring,
                OutputDeviceState::Stopping,
                OutputDeviceState::Idle,
                OutputDeviceState::Opening,
                OutputDeviceState::Running,
            ]
        );
        drop(reopened);
    }

    #[test]
    fn strict_bit_perfect_blocks_fallback_and_transitions_to_faulted() {
        let mut fsm = OutputDeviceFsm::with_guard_delay(Duration::ZERO);
        let mut active: Option<()> = None;
        let mut fallback_called = false;

        let res = fsm.reconfigure_sequence(
            &mut active,
            true,
            |_| {},
            || Err(BackendError::DeviceInUse),
            Some(|_: &BackendError| {
                fallback_called = true;
                Ok(())
            }),
        );

        assert!(res.is_err());
        assert!(!fallback_called);
        assert_eq!(fsm.state(), OutputDeviceState::Faulted);
    }

    #[test]
    fn non_strict_mode_allows_fallback_on_open_failure() {
        let mut fsm = OutputDeviceFsm::with_guard_delay(Duration::ZERO);
        let mut active: Option<u32> = None;

        let handle = fsm
            .reconfigure_sequence(
                &mut active,
                false,
                |_| {},
                || Err(BackendError::DeviceInUse),
                Some(|_: &BackendError| Ok(42u32)),
            )
            .unwrap();

        assert_eq!(handle, 42);
        assert_eq!(fsm.state(), OutputDeviceState::Running);
    }
}
