use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use core_types::{StreamKey, StreamSourceSpec};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use crate::error::ProviderError;

use super::lru::LruCacheState;
use super::{
    CachedStreamEntry, ClockFn, StreamCacheConfig, StreamCacheStore, clone_provider_error,
    extract_raw_expire_at, should_refresh_for_http_status, system_epoch_secs,
};

type SharedFlightResult = Result<StreamSourceSpec, Arc<ProviderError>>;

struct InFlightEntry {
    flight_id: u64,
    waiters: usize,
    flight_cancel: CancellationToken,
    result_rx: watch::Receiver<Option<SharedFlightResult>>,
}

struct StreamUrlCacheInner {
    config: StreamCacheConfig,
    clock: ClockFn,
    store: Option<Arc<dyn StreamCacheStore>>,
    lru: Mutex<LruCacheState>,
    in_flight: Mutex<HashMap<StreamKey, InFlightEntry>>,
    next_flight_id: AtomicU64,
}

impl StreamUrlCacheInner {
    fn now_epoch_secs(&self) -> u64 {
        (self.clock)()
    }

    fn build_entry(&self, key: &StreamKey, spec: StreamSourceSpec) -> CachedStreamEntry {
        let now = self.now_epoch_secs();
        let raw_expire_at = extract_raw_expire_at(&spec).unwrap_or_else(|| {
            now.saturating_add(self.config.default_ttl_for(&key.provider_id).as_secs())
        });
        let safety_margin_secs = self.config.default_safety_margin.as_secs();
        let effective_expire_at = raw_expire_at.saturating_sub(safety_margin_secs);

        CachedStreamEntry {
            key: key.clone(),
            spec,
            raw_expire_at,
            effective_expire_at,
            cached_at: now,
        }
    }

    async fn store_resolved(
        &self,
        key: &StreamKey,
        spec: &StreamSourceSpec,
    ) -> Option<CachedStreamEntry> {
        let entry = self.build_entry(key, spec.clone());
        let now = entry.cached_at;

        if !entry.is_valid_at(now) {
            {
                let mut lru = self.lru.lock().unwrap_or_else(|e| e.into_inner());
                lru.remove(key);
            }
            if let Some(store) = &self.store {
                store.delete(key).await;
            }
            return None;
        }

        {
            let mut lru = self.lru.lock().unwrap_or_else(|e| e.into_inner());
            lru.put(entry.clone(), now);
        }
        if let Some(store) = &self.store {
            store.put(&entry).await;
        }

        Some(entry)
    }

    fn remove_flight_if_matches(&self, key: &StreamKey, flight_id: u64) {
        let mut flights = self.in_flight.lock().unwrap_or_else(|e| e.into_inner());
        if flights.get(key).is_some_and(|e| e.flight_id == flight_id) {
            flights.remove(key);
        }
    }
}

struct WaiterGuard {
    inner: Arc<StreamUrlCacheInner>,
    key: StreamKey,
    flight_id: u64,
}

impl Drop for WaiterGuard {
    fn drop(&mut self) {
        let mut flights = self
            .inner
            .in_flight
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let should_cancel = if let Some(entry) = flights.get_mut(&self.key)
            && entry.flight_id == self.flight_id
        {
            entry.waiters = entry.waiters.saturating_sub(1);
            if entry.waiters == 0 {
                entry.flight_cancel.cancel();
                true
            } else {
                false
            }
        } else {
            false
        };

        if should_cancel {
            flights.remove(&self.key);
        }
    }
}

struct FlightCleanupGuard {
    inner: Arc<StreamUrlCacheInner>,
    key: StreamKey,
    flight_id: u64,
    cleaned: bool,
}

impl FlightCleanupGuard {
    fn finish(&mut self) {
        if !self.cleaned {
            self.inner
                .remove_flight_if_matches(&self.key, self.flight_id);
            self.cleaned = true;
        }
    }
}

impl Drop for FlightCleanupGuard {
    fn drop(&mut self) {
        self.finish();
    }
}

/// Thread-safe, TTL-aware, bounded-LRU stream URL cache with single-flight coalescing
/// and optional persistent backing storage.
#[derive(Clone)]
pub struct StreamUrlCache {
    inner: Arc<StreamUrlCacheInner>,
}

impl Default for StreamUrlCache {
    fn default() -> Self {
        Self::new(StreamCacheConfig::default())
    }
}

impl StreamUrlCache {
    /// Creates an in-memory [`StreamUrlCache`] using the system clock.
    pub fn new(config: StreamCacheConfig) -> Self {
        Self::with_clock(config, None, Arc::new(system_epoch_secs))
    }

    /// Creates a [`StreamUrlCache`] backed by a persistent [`StreamCacheStore`].
    pub fn with_store(config: StreamCacheConfig, store: Arc<dyn StreamCacheStore>) -> Self {
        Self::with_clock(config, Some(store), Arc::new(system_epoch_secs))
    }

    /// Creates a [`StreamUrlCache`] with an injectable clock and optional persistent store.
    pub fn with_clock(
        config: StreamCacheConfig,
        store: Option<Arc<dyn StreamCacheStore>>,
        clock: ClockFn,
    ) -> Self {
        let max_entries = config.max_entries;
        Self {
            inner: Arc::new(StreamUrlCacheInner {
                config,
                clock,
                store,
                lru: Mutex::new(LruCacheState::new(max_entries)),
                in_flight: Mutex::new(HashMap::new()),
                next_flight_id: AtomicU64::new(1),
            }),
        }
    }

    /// Returns the cache configuration.
    pub fn config(&self) -> &StreamCacheConfig {
        &self.inner.config
    }

    /// Returns the current clock timestamp in Unix epoch seconds.
    pub fn now_epoch_secs(&self) -> u64 {
        self.inner.now_epoch_secs()
    }

    /// Returns the number of entries currently held in memory.
    pub fn len(&self) -> usize {
        self.inner
            .lru
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .len()
    }

    /// Returns `true` if no entries are held in memory.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns `true` if an unexpired entry for `key` exists in memory.
    pub fn contains_valid(&self, key: &StreamKey) -> bool {
        let now = self.inner.now_epoch_secs();
        self.inner
            .lru
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains_valid(key, now)
    }

    /// Performs a fast memory-only lookup, evicting the entry if expired.
    pub fn get_memory(&self, key: &StreamKey) -> Option<CachedStreamEntry> {
        let now = self.inner.now_epoch_secs();
        self.inner
            .lru
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(key, now)
    }

    /// Looks up `key` in memory, falling back to the optional persistent store.
    ///
    /// Valid entries loaded from the persistent store warm the in-memory LRU.
    /// Expired entries are evicted from both layers.
    pub async fn get(&self, key: &StreamKey) -> Option<CachedStreamEntry> {
        if let Some(entry) = self.get_memory(key) {
            return Some(entry);
        }

        let store = self.inner.store.as_ref()?;
        let entry = store.get(key).await?;
        let now = self.inner.now_epoch_secs();
        if !entry.is_valid_at(now) {
            store.delete(key).await;
            return None;
        }

        {
            let mut lru = self.inner.lru.lock().unwrap_or_else(|e| e.into_inner());
            lru.put(entry.clone(), now);
        }
        Some(entry)
    }

    /// Explicitly inserts `spec` into the cache (computing expiry + safety margin).
    ///
    /// Returns `None` without caching if the entry is already expired after applying
    /// the safety margin.
    pub async fn put(&self, key: &StreamKey, spec: StreamSourceSpec) -> Option<CachedStreamEntry> {
        self.inner.store_resolved(key, &spec).await
    }

    /// Removes `key` from memory and the optional persistent store.
    pub async fn invalidate(&self, key: &StreamKey) {
        {
            let mut lru = self.inner.lru.lock().unwrap_or_else(|e| e.into_inner());
            lru.remove(key);
        }
        if let Some(store) = &self.inner.store {
            store.delete(key).await;
        }
    }

    /// Removes all cached entries for `provider_id` from memory and the optional store.
    pub async fn invalidate_provider(&self, provider_id: &str) {
        {
            let mut lru = self.inner.lru.lock().unwrap_or_else(|e| e.into_inner());
            lru.remove_provider(provider_id);
        }
        if let Some(store) = &self.inner.store {
            store.clear_provider(provider_id).await;
        }
    }

    /// Resolves `key` from cache if valid, otherwise coalesces concurrent misses
    /// via single-flight so the upstream resolver runs once.
    ///
    /// Cancelling a caller's `cancel_token` returns `Err(ProviderError::Cancelled)`
    /// for that caller without aborting the shared flight unless no waiters remain.
    pub async fn resolve_or_cached<F, Fut>(
        &self,
        key: &StreamKey,
        cancel_token: CancellationToken,
        resolver_fn: F,
    ) -> Result<StreamSourceSpec, ProviderError>
    where
        F: FnOnce(CancellationToken) -> Fut,
        Fut: Future<Output = Result<StreamSourceSpec, ProviderError>> + Send + 'static,
    {
        if cancel_token.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        if let Some(entry) = self.get(key).await {
            return Ok(entry.spec);
        }

        self.resolve_singleflight(key, cancel_token, resolver_fn)
            .await
    }

    /// Handles upstream HTTP errors by invalidating stale cached URLs on `403` / `410`
    /// and running a single coalesced fresh resolution.
    pub async fn refresh_on_http_error<F, Fut>(
        &self,
        key: &StreamKey,
        status_code: u16,
        cancel_token: CancellationToken,
        resolver_fn: F,
    ) -> Result<StreamSourceSpec, ProviderError>
    where
        F: FnOnce(CancellationToken) -> Fut,
        Fut: Future<Output = Result<StreamSourceSpec, ProviderError>> + Send + 'static,
    {
        if cancel_token.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        if !should_refresh_for_http_status(status_code) {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "HTTP {status_code} does not trigger stream URL refresh for '{key}'"
            )));
        }

        self.invalidate(key).await;
        self.resolve_singleflight(key, cancel_token, resolver_fn)
            .await
    }

    async fn resolve_singleflight<F, Fut>(
        &self,
        key: &StreamKey,
        cancel_token: CancellationToken,
        resolver_fn: F,
    ) -> Result<StreamSourceSpec, ProviderError>
    where
        F: FnOnce(CancellationToken) -> Fut,
        Fut: Future<Output = Result<StreamSourceSpec, ProviderError>> + Send + 'static,
    {
        if cancel_token.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        enum FlightAction {
            Joined {
                flight_id: u64,
                rx: watch::Receiver<Option<SharedFlightResult>>,
            },
            Started {
                flight_id: u64,
                flight_cancel: CancellationToken,
                tx: watch::Sender<Option<SharedFlightResult>>,
                rx: watch::Receiver<Option<SharedFlightResult>>,
            },
        }

        let action = {
            let mut flights = self
                .inner
                .in_flight
                .lock()
                .unwrap_or_else(|e| e.into_inner());

            if let Some(existing) = flights.get_mut(key)
                && !existing.flight_cancel.is_cancelled()
            {
                existing.waiters += 1;
                FlightAction::Joined {
                    flight_id: existing.flight_id,
                    rx: existing.result_rx.clone(),
                }
            } else {
                let flight_id = self.inner.next_flight_id.fetch_add(1, Ordering::Relaxed);
                let flight_cancel = CancellationToken::new();
                let (tx, rx) = watch::channel(None);
                flights.insert(
                    key.clone(),
                    InFlightEntry {
                        flight_id,
                        waiters: 1,
                        flight_cancel: flight_cancel.clone(),
                        result_rx: rx.clone(),
                    },
                );
                FlightAction::Started {
                    flight_id,
                    flight_cancel,
                    tx,
                    rx,
                }
            }
        };

        let (flight_id, mut rx) = match action {
            FlightAction::Joined { flight_id, rx } => (flight_id, rx),
            FlightAction::Started {
                flight_id,
                flight_cancel,
                tx,
                rx,
            } => {
                let fut = resolver_fn(flight_cancel.clone());
                let inner = Arc::clone(&self.inner);
                let key_owned = key.clone();

                tokio::spawn(async move {
                    let mut cleanup = FlightCleanupGuard {
                        inner: Arc::clone(&inner),
                        key: key_owned.clone(),
                        flight_id,
                        cleaned: false,
                    };

                    // Drive the resolver future to completion so it can observe
                    // `flight_cancel` and run clean async cancellation (e.g. killing
                    // child processes) rather than being dropped mid-poll.
                    let res = fut.await;

                    let shared_res = match res {
                        Ok(spec) => {
                            if !flight_cancel.is_cancelled() {
                                inner.store_resolved(&key_owned, &spec).await;
                            }
                            Ok(spec)
                        }
                        Err(err) => Err(Arc::new(err)),
                    };

                    cleanup.finish();
                    let _ = tx.send(Some(shared_res));
                });

                (flight_id, rx)
            }
        };

        let _waiter_guard = WaiterGuard {
            inner: Arc::clone(&self.inner),
            key: key.clone(),
            flight_id,
        };

        loop {
            if let Some(result) = rx.borrow().as_ref() {
                return match result {
                    Ok(spec) => Ok(spec.clone()),
                    Err(err) => Err(clone_provider_error(err)),
                };
            }

            tokio::select! {
                biased;
                _ = cancel_token.cancelled() => return Err(ProviderError::Cancelled),
                changed = rx.changed() => {
                    if changed.is_err() {
                        return Err(ProviderError::StreamResolutionFailed(format!(
                            "Stream resolution task for '{key}' ended without a result"
                        )));
                    }
                }
            }
        }
    }
}
