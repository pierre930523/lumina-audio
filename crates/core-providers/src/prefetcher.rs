//! Background look-ahead stream prefetcher for gapless / instant-play transitions.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use core_types::StreamKey;
use tokio::sync::Semaphore;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use crate::error::ProviderError;
use crate::media_provider::MediaProvider;
use crate::stream_cache::StreamUrlCache;

/// Default remaining playback threshold (seconds) at which look-ahead prefetch begins.
pub const DEFAULT_TRIGGER_REMAINING_SECS: u64 = 15;
/// Lower bound of the supported look-ahead prefetch trigger window (seconds).
pub const MIN_TRIGGER_REMAINING_SECS: u64 = 15;
/// Upper bound of the supported look-ahead prefetch trigger window (seconds).
pub const MAX_TRIGGER_REMAINING_SECS: u64 = 20;
/// Default maximum concurrent background prefetch tasks.
pub const DEFAULT_MAX_CONCURRENT_PREFETCHES: usize = 2;

/// Callback resolving a provider identifier to its [`MediaProvider`] implementation.
pub type ProviderLookup = Arc<dyn Fn(&str) -> Option<Arc<dyn MediaProvider>> + Send + Sync>;

/// Configuration for [`StreamPrefetcher`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrefetchConfig {
    /// Remaining seconds on the active track at or below which next-track prefetch triggers.
    /// Clamped to the 15–20s look-ahead window via [`Self::clamped_trigger_secs`].
    pub trigger_remaining_secs: u64,
    /// Upper bound on concurrent background prefetch resolutions.
    pub max_concurrent_prefetches: usize,
}

impl Default for PrefetchConfig {
    fn default() -> Self {
        Self {
            trigger_remaining_secs: DEFAULT_TRIGGER_REMAINING_SECS,
            max_concurrent_prefetches: DEFAULT_MAX_CONCURRENT_PREFETCHES,
        }
    }
}

impl PrefetchConfig {
    /// Returns `trigger_remaining_secs` clamped to the `[15, 20]` second look-ahead window.
    #[inline]
    pub fn clamped_trigger_secs(&self) -> u64 {
        self.trigger_remaining_secs
            .clamp(MIN_TRIGGER_REMAINING_SECS, MAX_TRIGGER_REMAINING_SECS)
    }
}

/// Target track and quality to pre-resolve in the background.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct PrefetchTarget {
    pub key: StreamKey,
}

impl PrefetchTarget {
    pub fn new(key: StreamKey) -> Self {
        Self { key }
    }
}

impl From<StreamKey> for PrefetchTarget {
    fn from(key: StreamKey) -> Self {
        Self { key }
    }
}

/// Event emitted whenever the active or upcoming queue item changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueUpdateEvent {
    pub current: Option<StreamKey>,
    pub next: Option<StreamKey>,
}

/// Event emitted periodically during playback with remaining track duration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackProgressEvent {
    pub track_key: StreamKey,
    pub remaining_secs: u64,
}

struct ActivePrefetch {
    id: u64,
    target: StreamKey,
    cancel: CancellationToken,
    handle: JoinHandle<()>,
}

#[derive(Default)]
struct PrefetchState {
    current_track: Option<StreamKey>,
    next_track: Option<StreamKey>,
    active: Option<ActivePrefetch>,
    next_job_id: u64,
}

struct ActiveClearGuard {
    state: Arc<Mutex<PrefetchState>>,
    job_id: u64,
}

impl Drop for ActiveClearGuard {
    fn drop(&mut self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.active.as_ref().is_some_and(|a| a.id == self.job_id) {
            state.active = None;
        }
    }
}

/// Automatic look-ahead prefetcher that warms [`StreamUrlCache`] for the next queued track
/// once the current track enters the remaining-time threshold, and immediately cancels
/// stale prefetches on manual skips or queue changes.
pub struct StreamPrefetcher {
    config: PrefetchConfig,
    cache: Arc<StreamUrlCache>,
    provider_lookup: ProviderLookup,
    semaphore: Arc<Semaphore>,
    state: Arc<Mutex<PrefetchState>>,
}

impl StreamPrefetcher {
    /// Creates a [`StreamPrefetcher`] with a dynamic provider lookup callback.
    pub fn new(
        cache: Arc<StreamUrlCache>,
        provider_lookup: ProviderLookup,
        config: PrefetchConfig,
    ) -> Self {
        let permits = config.max_concurrent_prefetches.max(1);
        Self {
            config,
            cache,
            provider_lookup,
            semaphore: Arc::new(Semaphore::new(permits)),
            state: Arc::new(Mutex::new(PrefetchState::default())),
        }
    }

    /// Convenience constructor backed by a static map of `provider_id -> MediaProvider`.
    pub fn from_providers(
        cache: Arc<StreamUrlCache>,
        providers: HashMap<String, Arc<dyn MediaProvider>>,
        config: PrefetchConfig,
    ) -> Self {
        let normalized: HashMap<String, Arc<dyn MediaProvider>> = providers
            .into_iter()
            .map(|(k, v)| (k.trim().to_ascii_lowercase(), v))
            .collect();
        let lookup: ProviderLookup = Arc::new(move |provider_id: &str| {
            normalized
                .get(&provider_id.trim().to_ascii_lowercase())
                .cloned()
        });
        Self::new(cache, lookup, config)
    }

    /// Returns the active configuration.
    pub fn config(&self) -> PrefetchConfig {
        self.config
    }

    /// Updates tracked `current` and `next` queue items, immediately cancelling any
    /// in-flight prefetch that no longer matches the new `next` target.
    pub fn on_queue_update(&self, event: QueueUpdateEvent) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.current_track = event.current;
        state.next_track = event.next;

        let stale = state
            .active
            .as_ref()
            .is_some_and(|active| state.next_track.as_ref() != Some(&active.target));

        if stale && let Some(active) = state.active.take() {
            active.cancel.cancel();
        }
    }

    /// Processes a playback progress tick.
    ///
    /// - If `event.track_key` differs from the tracked `current` track, treats it as a
    ///   skip, immediately cancelling any stale prefetch and updating `current`.
    /// - When `event.remaining_secs <= config.clamped_trigger_secs()`, schedules a
    ///   background prefetch of `next` if it is not already cached or in-flight.
    pub fn on_playback_progress(&self, event: PlaybackProgressEvent) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());

        // Clear any completed handle before evaluating active state.
        if state
            .active
            .as_ref()
            .is_some_and(|active| active.handle.is_finished())
        {
            state.active = None;
        }

        if let Some(current) = &state.current_track
            && current != &event.track_key
        {
            // Track skip detected before queue update arrived: abort stale prefetch immediately.
            state.current_track = Some(event.track_key.clone());
            if let Some(active) = state.active.take() {
                active.cancel.cancel();
            }
        } else if state.current_track.is_none() {
            state.current_track = Some(event.track_key.clone());
        }

        if event.remaining_secs > self.config.clamped_trigger_secs() {
            return;
        }

        let Some(next_key) = state.next_track.clone() else {
            return;
        };

        if self.cache.contains_valid(&next_key) {
            return;
        }

        if state
            .active
            .as_ref()
            .is_some_and(|active| active.target == next_key && !active.cancel.is_cancelled())
        {
            return;
        }

        let Some(provider) = (self.provider_lookup)(&next_key.provider_id) else {
            tracing::debug!(
                provider_id = %next_key.provider_id,
                track_id = %next_key.track_id,
                "Skipping prefetch: no MediaProvider registered for provider"
            );
            return;
        };

        // Cancel any superseded active prefetch before launching the new target.
        if let Some(old) = state.active.take() {
            old.cancel.cancel();
        }

        state.next_job_id = state.next_job_id.wrapping_add(1);
        let job_id = state.next_job_id;
        let cancel = CancellationToken::new();
        let cancel_task = cancel.clone();
        let cache = Arc::clone(&self.cache);
        let semaphore = Arc::clone(&self.semaphore);
        let state_ref = Arc::clone(&self.state);
        let target = PrefetchTarget::new(next_key.clone());

        let handle = tokio::spawn(async move {
            let _clear_guard = ActiveClearGuard {
                state: state_ref,
                job_id,
            };

            let _permit = tokio::select! {
                biased;
                _ = cancel_task.cancelled() => return,
                permit = semaphore.acquire_owned() => match permit {
                    Ok(p) => p,
                    Err(_) => return,
                },
            };

            if cancel_task.is_cancelled() {
                return;
            }

            let track_id = target.key.track_id.clone();
            let quality_key = target.key.quality_key.clone();
            let result = cache
                .resolve_or_cached(
                    &target.key,
                    cancel_task.clone(),
                    move |flight_cancel| async move {
                        provider
                            .resolve_stream(&track_id, &quality_key, flight_cancel)
                            .await
                    },
                )
                .await;

            match result {
                Ok(_) => {
                    tracing::debug!(key = %target.key, "Prefetched upcoming stream into URL cache");
                }
                Err(ProviderError::Cancelled) => {
                    tracing::debug!(key = %target.key, "Prefetch cancelled");
                }
                Err(err) => {
                    tracing::warn!(key = %target.key, error = %err, "Prefetch stream resolution failed");
                }
            }
        });

        state.active = Some(ActivePrefetch {
            id: job_id,
            target: next_key,
            cancel,
            handle,
        });
    }

    /// Immediately cancels any currently running prefetch task.
    pub fn cancel_active(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(active) = state.active.take() {
            active.cancel.cancel();
        }
    }

    /// Returns the [`StreamKey`] currently being prefetched, if any.
    pub fn active_prefetch_key(&self) -> Option<StreamKey> {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.active.as_ref().and_then(|active| {
            if active.handle.is_finished() || active.cancel.is_cancelled() {
                None
            } else {
                Some(active.target.clone())
            }
        })
    }

    /// Returns `true` if `key` currently has a valid, unexpired entry in the cache.
    pub fn is_prefetched(&self, key: &StreamKey) -> bool {
        self.cache.contains_valid(key)
    }

    /// Returns the currently tracked playing track key, if any.
    pub fn current_track(&self) -> Option<StreamKey> {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .current_track
            .clone()
    }

    /// Returns the currently tracked upcoming track key, if any.
    pub fn next_track(&self) -> Option<StreamKey> {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .next_track
            .clone()
    }
}

impl Drop for StreamPrefetcher {
    fn drop(&mut self) {
        self.cancel_active();
    }
}
