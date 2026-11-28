use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use bytes::Bytes;
use core_types::StreamKey;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::super::l2_cache::{DashL2Package, DashL2SegmentEntry, MAX_DASH_L2_SEGMENTS};
use super::super::{
    FormatMismatchReason, InFlightDownloadGuard, StreamError, StreamHttpConfig,
    StreamHttpTransport, StreamRefreshHandler, await_watch_result, streaming_runtime,
};
use super::manifest::{ParsedDashManifest, validate_dash_package_compatibility};
use super::proxy::SegmentedStreamProxy;
use super::recovery::{SegmentRefreshContext, fetch_segment_bytes};
use super::scheduler::{
    InFlightSegRx, InFlightSegment, SegFlightCleanup, SegmentLruCache, SegmentSlot,
};

impl SegmentedStreamProxy {
    /// Attaches stream identity, injectable 403/410 self-healing callback, and network-epoch
    /// reset capability metadata.
    pub fn with_refresh_context(
        mut self,
        key: StreamKey,
        handler: Arc<dyn StreamRefreshHandler>,
        needs_network_epoch_reset: bool,
    ) -> Self {
        self.key = Some(key);
        self.refresh_handler = Some(handler);
        self.needs_network_epoch_reset = needs_network_epoch_reset;
        self
    }

    /// Attaches a [`StreamKey`] without a refresh handler (preserves `provider_id` on HTTP 401).
    pub fn with_stream_key(mut self, key: StreamKey) -> Self {
        self.key = Some(key);
        self
    }

    /// Overrides the 2-attempt 403/410 retry backoff delays (defaults to `[300ms, 1000ms]`).
    pub fn with_refresh_backoffs(mut self, backoffs: [Duration; 2]) -> Self {
        self.refresh_backoffs = backoffs;
        self
    }

    /// Binds a custom network epoch receiver (useful for isolated deterministic tests).
    pub fn with_network_epoch_rx(mut self, rx: watch::Receiver<u64>) -> Self {
        self.epoch_rx = rx;
        self
    }

    /// Overrides the bounded background prefetch lookahead count (`PREFETCH_AHEAD`).
    pub fn with_prefetch_ahead(mut self, ahead: usize) -> Self {
        self.prefetch_ahead = ahead;
        self
    }

    /// Overrides the in-memory RAM LRU byte cap for cached DASH media segments (`init` stays pinned).
    pub fn with_max_cache_bytes(self, max_bytes: usize) -> Self {
        if let Ok(mut st) = self.state.lock() {
            let max_entries = st.segment_cache.max_entries;
            st.segment_cache = SegmentLruCache::new(max_bytes, max_entries);
        }
        self
    }

    /// Overrides the maximum number of DASH media segments held in the RAM LRU cache.
    pub fn with_max_cached_segments(self, max_segments: usize) -> Self {
        if let Ok(mut st) = self.state.lock() {
            let max_bytes = st.segment_cache.max_bytes;
            st.segment_cache = SegmentLruCache::new(max_bytes, max_segments);
        }
        self
    }

    /// Returns total cached media segment bytes currently held in the RAM LRU cache.
    pub fn cached_segment_bytes(&self) -> usize {
        self.state
            .lock()
            .map(|st| st.segment_cache.total_bytes)
            .unwrap_or(0)
    }

    /// Overrides HTTP timeouts and redirect limits.
    pub fn with_http_config(mut self, config: StreamHttpConfig) -> Self {
        self.config = config;
        self
    }

    /// Overrides the [`StreamHttpTransport`] used to fetch initialization and media segments.
    pub fn with_transport(mut self, transport: Arc<dyn StreamHttpTransport>) -> Self {
        self.transport = transport;
        self
    }

    /// Binds a parent [`CancellationToken`] for external cancellation.
    pub fn with_cancellation_token(mut self, token: CancellationToken) -> Self {
        self.cancel = token;
        if let Ok(mut st) = self.state.lock() {
            st.window_cancel.cancel();
            st.window_cancel = self.cancel.child_token();
        }
        self
    }

    /// Returns a snapshot of the parsed DASH manifest representation chosen for playback.
    pub fn manifest(&self) -> ParsedDashManifest {
        self.manifest
            .read()
            .map(|g| g.clone())
            .unwrap_or(ParsedDashManifest {
                init_url: None,
                segments: Vec::new(),
                bandwidth: 0,
                mime_type: None,
                codecs: None,
                duration_ms: None,
            })
    }

    /// Returns the number of currently active in-flight HTTP downloads for this proxy.
    pub fn active_downloads(&self) -> usize {
        self.active_downloads.load(Ordering::SeqCst)
    }

    /// Returns whether this proxy's provider requires network-epoch resets.
    pub fn needs_network_epoch_reset(&self) -> bool {
        self.needs_network_epoch_reset
    }

    pub(super) fn refresh_context(&self) -> SegmentRefreshContext {
        SegmentRefreshContext {
            key: self.key.clone(),
            manifest_slot: Arc::clone(&self.manifest),
            manifest_source_url: Arc::clone(&self.manifest_source_url),
            headers_slot: Arc::clone(&self.headers),
            mime_type: self.mime_type.clone(),
            refresh_handler: self.refresh_handler.clone(),
            refresh_lock: Arc::clone(&self.refresh_lock),
            backoffs: self.refresh_backoffs,
        }
    }

    pub(super) fn slot_url(&self, slot: SegmentSlot) -> Option<String> {
        let guard = self.manifest.read().ok()?;
        match slot {
            SegmentSlot::Init => guard.init_url.clone(),
            SegmentSlot::Media(idx) => guard.segments.get(idx).map(|s| s.url.clone()),
        }
    }

    pub(super) fn spawn_slot_fetch(
        &self,
        epoch: u64,
        slot: SegmentSlot,
        window_cancel: &CancellationToken,
        active_seg_hint: usize,
        allow_refresh: bool,
    ) -> Result<(bool, InFlightSegRx), StreamError> {
        let key = (epoch, slot);
        let mut st = self
            .state
            .lock()
            .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;

        if st.window_epoch != epoch || window_cancel.is_cancelled() || self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }

        if let Some(existing) = st.in_flight.get(&key) {
            return Ok((!existing.allow_refresh, existing.rx.clone()));
        }

        if self.slot_url(slot).is_none() {
            return Err(StreamError::InvalidManifest(
                "Requested segment slot out of range".to_string(),
            ));
        }

        let (tx, rx) = watch::channel(None);
        st.in_flight.insert(
            key,
            InFlightSegment {
                allow_refresh,
                rx: rx.clone(),
            },
        );
        drop(st);

        let rt = streaming_runtime()?;
        let transport = Arc::clone(&self.transport);
        let config = self.config;
        let task_cancel = window_cancel.clone();
        let state = Arc::clone(&self.state);
        let active_downloads = Arc::clone(&self.active_downloads);
        let prefetch_ahead = self.prefetch_ahead;
        let refresh_ctx = self.refresh_context();
        let mut epoch_rx = self.epoch_rx.clone();

        rt.spawn(async move {
            let dl_guard = InFlightDownloadGuard::new(Some(active_downloads));
            let mut cleanup = SegFlightCleanup {
                key,
                in_flight_active: Arc::clone(&state),
                tx,
                completed: false,
            };

            let res = fetch_segment_bytes(
                transport.as_ref(),
                &refresh_ctx,
                slot,
                allow_refresh,
                &config,
                &task_cancel,
                &mut epoch_rx,
            )
            .await;

            if let Ok(ref bytes) = res
                && let Ok(mut st) = state.lock()
            {
                match slot {
                    SegmentSlot::Init => {
                        if st.init_bytes.is_none() {
                            st.init_bytes = Some(bytes.clone());
                        }
                    }
                    SegmentSlot::Media(seg_idx) => {
                        if st.window_epoch == epoch {
                            let protected_end = active_seg_hint.saturating_add(prefetch_ahead);
                            st.segment_cache.insert(
                                seg_idx,
                                bytes.clone(),
                                active_seg_hint..=protected_end,
                            );
                        }
                    }
                }
            }

            drop(dl_guard);
            if let Ok(mut st) = cleanup.in_flight_active.lock() {
                st.in_flight.remove(&key);
            }
            let _ = cleanup.tx.send(Some(res));
            cleanup.completed = true;
        });

        Ok((false, rx))
    }

    pub(super) async fn get_or_fetch_slot(
        &self,
        epoch: u64,
        window_cancel: &CancellationToken,
        slot: SegmentSlot,
        active_seg_hint: usize,
    ) -> Result<Bytes, StreamError> {
        loop {
            {
                let mut st = self.state.lock().map_err(|_| {
                    StreamError::Io("segmented proxy state lock poisoned".to_string())
                })?;
                if st.window_epoch != epoch
                    || window_cancel.is_cancelled()
                    || self.cancel.is_cancelled()
                {
                    return Err(StreamError::Cancelled);
                }
                match slot {
                    SegmentSlot::Init => {
                        if let Some(ref b) = st.init_bytes {
                            return Ok(b.clone());
                        }
                    }
                    SegmentSlot::Media(idx) => {
                        if let Some(b) = st.segment_cache.get(idx) {
                            return Ok(b);
                        }
                    }
                }
            }

            let (joined_bg_prefetch, mut rx) =
                self.spawn_slot_fetch(epoch, slot, window_cancel, active_seg_hint, true)?;
            match await_watch_result(&mut rx, window_cancel).await {
                Ok(bytes) => return Ok(bytes),
                Err(StreamError::HttpStatus(403 | 410)) if joined_bg_prefetch => {
                    // Background prefetch aborted on 403/410 without consuming retries;
                    // escalate to a foreground fetch to perform in-place 403/410 self-healing.
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
    }

    pub(super) fn schedule_prefetch_ahead(
        &self,
        epoch: u64,
        window_cancel: &CancellationToken,
        current_seg_idx: usize,
    ) {
        self.schedule_prefetch_from(
            epoch,
            window_cancel,
            current_seg_idx.saturating_add(1),
            current_seg_idx,
        );
    }

    pub(super) fn schedule_prefetch_from(
        &self,
        epoch: u64,
        window_cancel: &CancellationToken,
        start: usize,
        active_seg_hint: usize,
    ) {
        let total = self.manifest.read().map(|m| m.segments.len()).unwrap_or(0);
        if self.prefetch_ahead == 0
            || window_cancel.is_cancelled()
            || self.cancel.is_cancelled()
            || total == 0
            || start >= total
        {
            return;
        }

        let end_excl = start.saturating_add(self.prefetch_ahead).min(total);
        for seg_idx in start..end_excl {
            let need_fetch = {
                let Ok(st) = self.state.lock() else {
                    return;
                };
                if st.window_epoch != epoch || st.window_cancel.is_cancelled() {
                    return;
                }
                !st.segment_cache.contains_key(seg_idx)
                    && !st
                        .in_flight
                        .contains_key(&(epoch, SegmentSlot::Media(seg_idx)))
            };
            if need_fetch {
                let _ = self.spawn_slot_fetch(
                    epoch,
                    SegmentSlot::Media(seg_idx),
                    window_cancel,
                    active_seg_hint,
                    false,
                );
            }
        }
    }

    /// Validates `pkg` against the live parsed manifest and injects `init_bytes` + `seg_0..`
    /// into `WindowState` so virtual byte offsets stay locked, then prefetches from `pkg.segments.len()`.
    pub fn prime_cached_package(&self, pkg: &DashL2Package) -> Result<(), FormatMismatchReason> {
        let manifest = self.manifest();
        validate_dash_package_compatibility(pkg, &manifest)?;

        let (epoch, window_cancel) = {
            let mut st = self
                .state
                .lock()
                .map_err(|_| FormatMismatchReason::DashSpecMismatch {
                    detail: "segmented proxy state lock poisoned".to_string(),
                })?;
            st.init_bytes = if pkg.init_bytes.is_empty() {
                None
            } else {
                Some(Bytes::from(pkg.init_bytes.clone()))
            };
            let protected_end = pkg.segments.len().saturating_add(self.prefetch_ahead);
            for (idx, seg) in pkg.segments.iter().enumerate() {
                st.segment_cache
                    .insert(idx, Bytes::from(seg.bytes.clone()), 0..=protected_end);
            }
            (st.window_epoch, st.window_cancel.clone())
        };

        let next_seg = pkg.segments.len();
        let hint = next_seg.saturating_sub(1);
        self.schedule_prefetch_from(epoch, &window_cancel, next_seg, hint);
        Ok(())
    }

    /// Exports `init_bytes` and up to the first 2 segments fitting inside `max_payload_bytes` as
    /// a [`DashL2Package`] (reading from RAM cache first, fetching only if uncached).
    pub async fn export_l2_package(
        &self,
        max_payload_bytes: usize,
    ) -> Result<DashL2Package, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        let manifest = self.manifest();
        let (epoch, window_cancel) = {
            let st = self
                .state
                .lock()
                .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;
            (st.window_epoch, st.window_cancel.clone())
        };

        let init_bytes = if manifest.init_url.is_some() {
            self.get_or_fetch_slot(epoch, &window_cancel, SegmentSlot::Init, 0)
                .await?
                .to_vec()
        } else {
            Vec::new()
        };

        let mut segments = Vec::new();
        let cap = max_payload_bytes.min(core_types::L2_MAX_TARGET_BYTES as usize);
        let mut used = init_bytes.len();
        if used <= cap {
            for (idx, seg_meta) in manifest
                .segments
                .iter()
                .take(MAX_DASH_L2_SEGMENTS)
                .enumerate()
            {
                let bytes = self
                    .get_or_fetch_slot(epoch, &window_cancel, SegmentSlot::Media(idx), idx)
                    .await?;
                if used.saturating_add(bytes.len()) > cap {
                    break;
                }
                used += bytes.len();
                segments.push(DashL2SegmentEntry {
                    number: seg_meta.number,
                    start_ms: seg_meta.start_ms,
                    duration_ms: seg_meta.duration_ms,
                    bytes: bytes.to_vec(),
                });
            }
        }

        Ok(DashL2Package {
            mime_type: self
                .mime_type
                .clone()
                .or(manifest.mime_type)
                .unwrap_or_else(|| "audio/mp4".to_string()),
            codecs: manifest.codecs,
            bandwidth: (manifest.bandwidth > 0).then_some(manifest.bandwidth),
            total_duration_ms: manifest.duration_ms,
            init_bytes,
            segments,
        })
    }
}
