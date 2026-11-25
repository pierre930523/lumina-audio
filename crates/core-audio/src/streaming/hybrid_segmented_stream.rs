use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use core_types::StreamKey;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::l2_cache::{DashL2Package, L2CacheManager, L2DashHit, L2FileLease};
use super::segmented_proxy::{DEFAULT_PREFETCH_AHEAD, SegmentedStreamProxy, infer_dash_extension};
use super::{
    ByteStreamSource, DEFAULT_REFRESH_403_BACKOFFS, FormatMismatchCallback, FormatMismatchReason,
    ReqwestStreamTransport, SegmentedSeekTarget, StreamError, StreamHttpConfig,
    StreamHttpTransport, StreamRefreshHandler, streaming_runtime, subscribe_network_epoch,
};

#[derive(Clone)]
enum HybridDashFailure {
    Mismatch(FormatMismatchReason),
    Stream(StreamError),
}

/// Optional configuration parameters for [`HybridSegmentedStream`].
#[derive(Clone)]
pub struct HybridSegmentedConfig {
    pub headers: BTreeMap<String, String>,
    pub hint_extension: Option<String>,
    pub mime_type: Option<String>,
    pub http_config: StreamHttpConfig,
    pub refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    pub needs_network_epoch_reset: bool,
    pub refresh_backoffs: [Duration; 2],
    pub prefetch_ahead: usize,
    pub epoch_rx: Option<watch::Receiver<u64>>,
    pub on_mismatch: Option<FormatMismatchCallback>,
}

impl Default for HybridSegmentedConfig {
    fn default() -> Self {
        Self {
            headers: BTreeMap::new(),
            hint_extension: None,
            mime_type: None,
            http_config: StreamHttpConfig::default(),
            refresh_handler: None,
            needs_network_epoch_reset: false,
            refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
            prefetch_ahead: DEFAULT_PREFETCH_AHEAD,
            epoch_rx: None,
            on_mismatch: None,
        }
    }
}

/// [`ByteStreamSource`] serving cached DASH `init` + opening segments (`seg_0`, `seg_1`) from
/// L2 in `< 1 ms` while concurrently fetching and validating the fresh `.mpd` manifest and priming
/// [`SegmentedStreamProxy`] to splice seamlessly from segment index `2` onward.
pub struct HybridSegmentedStream {
    key: StreamKey,
    local_chunks: Vec<Bytes>,
    local_end: u64,
    _lease: L2FileLease,
    cancel: CancellationToken,
    hint_extension: Option<String>,
    mime_type: Option<String>,
    total_duration_ms: Arc<Mutex<Option<u64>>>,
    proxy_rx: watch::Receiver<Option<Result<Arc<SegmentedStreamProxy>, HybridDashFailure>>>,
    mismatch_reason: Arc<Mutex<Option<FormatMismatchReason>>>,
    delegated_after_seek: Arc<AtomicBool>,
}

impl HybridSegmentedStream {
    /// Opens a [`HybridSegmentedStream`] using the shared process-wide HTTP/2 transport.
    pub fn open_shared(
        key: StreamKey,
        hit: L2DashHit,
        manifest_url_or_xml: impl Into<String>,
        l2_manager: Arc<L2CacheManager>,
        cancel: CancellationToken,
        config: HybridSegmentedConfig,
    ) -> Result<Self, StreamError> {
        let transport = Arc::new(ReqwestStreamTransport::shared()?);
        Self::new(
            key,
            hit,
            manifest_url_or_xml,
            transport,
            l2_manager,
            cancel,
            config,
        )
    }

    /// Constructs a [`HybridSegmentedStream`] from an [`L2DashHit`] with an injectable
    /// [`StreamHttpTransport`] and spawns background `.mpd` manifest verification & priming.
    pub fn new(
        key: StreamKey,
        hit: L2DashHit,
        manifest_url_or_xml: impl Into<String>,
        transport: Arc<dyn StreamHttpTransport>,
        l2_manager: Arc<L2CacheManager>,
        cancel: CancellationToken,
        config: HybridSegmentedConfig,
    ) -> Result<Self, StreamError> {
        let pkg = hit.package;
        let mut local_chunks = Vec::with_capacity(1 + pkg.segments.len());
        if !pkg.init_bytes.is_empty() {
            local_chunks.push(Bytes::from(pkg.init_bytes.clone()));
        }
        for seg in &pkg.segments {
            local_chunks.push(Bytes::from(seg.bytes.clone()));
        }
        let local_end: u64 = local_chunks.iter().map(|c| c.len() as u64).sum();

        let derived_mime = config
            .mime_type
            .clone()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("application/dash+xml"))
            .or_else(|| {
                let m = pkg.mime_type.trim();
                (!m.is_empty()).then(|| m.to_string())
            });
        let derived_ext = config
            .hint_extension
            .clone()
            .map(|s| s.trim().trim_start_matches('.').to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .or_else(|| infer_dash_extension(derived_mime.as_deref(), pkg.codecs.as_deref()));

        let total_duration_ms = Arc::new(Mutex::new(pkg.total_duration_ms));
        let mismatch_reason = Arc::new(Mutex::new(None));
        let notified = Arc::new(AtomicBool::new(false));
        let (proxy_tx, proxy_rx) = watch::channel(None);

        let rt_handle = streaming_runtime()
            .ok()
            .map(|rt| rt.handle().clone())
            .or_else(|| tokio::runtime::Handle::try_current().ok())
            .ok_or_else(|| {
                StreamError::Io("No Tokio runtime for HybridSegmentedStream".to_string())
            })?;

        let manifest_src = manifest_url_or_xml.into();
        let bg_key = key.clone();
        let bg_cancel = cancel.clone();
        let bg_mime = derived_mime.clone();
        let bg_ext = derived_ext.clone();
        let bg_dur = Arc::clone(&total_duration_ms);
        let bg_mismatch = Arc::clone(&mismatch_reason);
        let bg_notified = Arc::clone(&notified);
        let bg_l2 = Arc::clone(&l2_manager);
        let epoch_rx = config.epoch_rx.unwrap_or_else(subscribe_network_epoch);

        rt_handle.spawn(async move {
            spawn_manifest_validate_and_prime(
                bg_key,
                pkg,
                manifest_src,
                config.headers,
                bg_ext,
                bg_mime,
                transport,
                config.http_config,
                bg_cancel,
                config.refresh_handler,
                config.needs_network_epoch_reset,
                config.refresh_backoffs,
                config.prefetch_ahead,
                epoch_rx,
                bg_dur,
                bg_mismatch,
                bg_notified,
                bg_l2,
                config.on_mismatch,
                proxy_tx,
            )
            .await;
        });

        Ok(Self {
            key,
            local_chunks,
            local_end,
            _lease: hit.lease,
            cancel,
            hint_extension: derived_ext,
            mime_type: derived_mime,
            total_duration_ms,
            proxy_rx,
            mismatch_reason,
            delegated_after_seek: Arc::new(AtomicBool::new(false)),
        })
    }

    /// Returns the [`StreamKey`] associated with this hybrid DASH stream.
    pub fn key(&self) -> &StreamKey {
        &self.key
    }

    /// Returns the local virtual byte boundary `[0, local_end)` backed immediately by L2 (`init + seg_0 + seg_1`).
    pub fn local_end(&self) -> u64 {
        self.local_end
    }

    /// Returns the presentation duration in milliseconds (from L2 package initially, refined by `.mpd`).
    pub fn total_duration_ms(&self) -> Option<u64> {
        self.total_duration_ms.lock().ok().and_then(|g| *g)
    }

    /// Returns the detected [`FormatMismatchReason`], if `.mpd` compatibility validation failed.
    pub fn mismatch_reason(&self) -> Option<FormatMismatchReason> {
        self.mismatch_reason.lock().ok().and_then(|g| g.clone())
    }

    /// Waits for background `.mpd` fetch, compatibility validation, and priming to finish.
    pub async fn wait_ready(&self) -> Result<(), StreamError> {
        self.await_proxy().await.map(|_| ()).map_err(|failure| match failure {
            HybridDashFailure::Mismatch(reason) => {
                StreamError::InvalidManifest(format!("L2 DASH mismatch: {reason}"))
            }
            HybridDashFailure::Stream(err) => err,
        })
    }

    fn copy_from_local(&self, offset: u64, buf: &mut [u8]) -> usize {
        if offset >= self.local_end || buf.is_empty() {
            return 0;
        }
        let mut cum = 0u64;
        let mut cursor = offset;
        let mut copied = 0usize;

        for chunk in &self.local_chunks {
            let chunk_end = cum + chunk.len() as u64;
            if cursor < chunk_end && copied < buf.len() {
                let inner_start = (cursor - cum) as usize;
                let avail = &chunk[inner_start..];
                let to_copy = avail.len().min(buf.len() - copied);
                buf[copied..copied + to_copy].copy_from_slice(&avail[..to_copy]);
                copied += to_copy;
                cursor += to_copy as u64;
            }
            cum = chunk_end;
            if copied >= buf.len() {
                break;
            }
        }
        copied
    }

    async fn await_proxy(&self) -> Result<Arc<SegmentedStreamProxy>, HybridDashFailure> {
        let mut rx = self.proxy_rx.clone();
        loop {
            if self.cancel.is_cancelled() {
                return Err(HybridDashFailure::Stream(StreamError::Cancelled));
            }
            if let Some(res) = rx.borrow().clone() {
                return res;
            }
            tokio::select! {
                biased;
                _ = self.cancel.cancelled() => {
                    return Err(HybridDashFailure::Stream(StreamError::Cancelled));
                }
                changed = rx.changed() => {
                    if changed.is_err() {
                        return Err(HybridDashFailure::Stream(StreamError::Cancelled));
                    }
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn spawn_manifest_validate_and_prime(
    key: StreamKey,
    pkg: DashL2Package,
    manifest_src: String,
    headers: BTreeMap<String, String>,
    hint_extension: Option<String>,
    mime_type: Option<String>,
    transport: Arc<dyn StreamHttpTransport>,
    http_config: StreamHttpConfig,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    needs_network_epoch_reset: bool,
    refresh_backoffs: [Duration; 2],
    prefetch_ahead: usize,
    epoch_rx: watch::Receiver<u64>,
    duration_slot: Arc<Mutex<Option<u64>>>,
    mismatch_slot: Arc<Mutex<Option<FormatMismatchReason>>>,
    notified: Arc<AtomicBool>,
    l2_manager: Arc<L2CacheManager>,
    on_mismatch: Option<FormatMismatchCallback>,
    proxy_tx: watch::Sender<Option<Result<Arc<SegmentedStreamProxy>, HybridDashFailure>>>,
) {
    let proxy_cancel = cancel.child_token();
    let proxy_res = SegmentedStreamProxy::open_with_refresh(
        manifest_src,
        &headers,
        hint_extension,
        mime_type,
        transport,
        http_config,
        proxy_cancel,
        Some(key.clone()),
        refresh_handler,
        needs_network_epoch_reset,
        refresh_backoffs,
        epoch_rx,
    )
    .await;

    let proxy = match proxy_res {
        Ok(p) => p.with_prefetch_ahead(prefetch_ahead),
        Err(err) => {
            let _ = proxy_tx.send(Some(Err(HybridDashFailure::Stream(err))));
            return;
        }
    };

    if let Err(reason) = proxy.prime_cached_package(&pkg) {
        proxy.cancel();
        if let Ok(mut guard) = mismatch_slot.lock() {
            *guard = Some(reason.clone());
        }
        // Delete stale L2 entry before invoking callback so Standby recovery sees a clean cache.
        let _ = l2_manager.delete_entry(&key).await;
        if !notified.swap(true, Ordering::SeqCst)
            && let Some(cb) = on_mismatch
        {
            cb(key, reason.clone());
        }
        let _ = proxy_tx.send(Some(Err(HybridDashFailure::Mismatch(reason))));
        return;
    }

    if let Some(dur_ms) = proxy.manifest().duration_ms
        && let Ok(mut guard) = duration_slot.lock()
    {
        *guard = Some(dur_ms);
    }

    let _ = proxy_tx.send(Some(Ok(Arc::new(proxy))));
}

#[async_trait]
impl ByteStreamSource for HybridSegmentedStream {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if buf.is_empty() {
            return Ok(0);
        }

        if self.delegated_after_seek.load(Ordering::SeqCst) {
            return match self.await_proxy().await {
                Ok(proxy) => proxy.read_at(offset, buf).await,
                Err(HybridDashFailure::Mismatch(reason)) => Err(StreamError::InvalidManifest(
                    format!("L2 DASH mismatch: {reason}"),
                )),
                Err(HybridDashFailure::Stream(err)) => Err(err),
            };
        }

        if offset < self.local_end {
            let local_copied = self.copy_from_local(offset, buf);
            if local_copied == buf.len() {
                return Ok(local_copied);
            }

            // Straddling `local_end` (end of `seg_1` into `seg_2`): await primed remote proxy.
            return match self.await_proxy().await {
                Ok(proxy) => {
                    if self.cancel.is_cancelled() {
                        return Err(StreamError::Cancelled);
                    }
                    if self.delegated_after_seek.load(Ordering::SeqCst) {
                        return Ok(local_copied);
                    }
                    match proxy.read_at(self.local_end, &mut buf[local_copied..]).await {
                        Ok(remote_n) => Ok(local_copied + remote_n),
                        Err(StreamError::Cancelled) => Err(StreamError::Cancelled),
                        Err(_) if self.cancel.is_cancelled() => Err(StreamError::Cancelled),
                        Err(_) => Ok(local_copied),
                    }
                }
                Err(HybridDashFailure::Stream(StreamError::Cancelled)) => {
                    Err(StreamError::Cancelled)
                }
                Err(_) if self.cancel.is_cancelled() => Err(StreamError::Cancelled),
                Err(_) => Ok(local_copied),
            };
        }

        match self.await_proxy().await {
            Ok(proxy) => proxy.read_at(offset, buf).await,
            // Signal clean EOF at `local_end` on DASH format mismatch so the Active Deck's decoder
            // finishes the local segments cleanly while its ring buffer drains through the Standby
            // Deck's `+800ms` micro-crossfade takeover.
            Err(HybridDashFailure::Mismatch(_)) => Ok(0),
            Err(HybridDashFailure::Stream(err)) => Err(err),
        }
    }

    fn len(&self) -> Option<u64> {
        if let Some(Ok(ref proxy)) = *self.proxy_rx.borrow() {
            proxy.len()
        } else {
            None
        }
    }

    fn cancel(&self) {
        self.cancel.cancel();
        if let Some(Ok(ref proxy)) = *self.proxy_rx.borrow() {
            proxy.cancel();
        }
    }

    fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    fn hint_extension(&self) -> Option<&str> {
        self.hint_extension.as_deref()
    }

    fn mime_type(&self) -> Option<&str> {
        self.mime_type.as_deref()
    }

    async fn seek_to_time_ms(
        &self,
        target_ms: u64,
    ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
        let proxy = self.await_proxy().await.map_err(|failure| match failure {
            HybridDashFailure::Mismatch(reason) => {
                StreamError::InvalidManifest(format!("L2 DASH mismatch: {reason}"))
            }
            HybridDashFailure::Stream(err) => err,
        })?;
        let target = proxy.seek_to_time_ms(target_ms).await?;
        if target.is_some() {
            self.delegated_after_seek.store(true, Ordering::SeqCst);
        }
        Ok(target)
    }

    fn reclaim_idle_memory(&self) -> usize {
        if let Some(Ok(ref proxy)) = *self.proxy_rx.borrow() {
            proxy.reclaim_idle_memory()
        } else {
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::streaming::{
        DashL2SegmentEntry, HttpRequestSpec, HttpResponseData, L2CacheConfig, read_all_at,
    };
    use core_db::{L2HeadCacheRepository, open_test_database};
    use reqwest::header::HeaderMap;
    use std::collections::HashMap;
    use std::time::Instant;
    use tempfile::TempDir;

    struct MockDashTransport {
        mpd_xml: String,
        blobs: HashMap<String, Vec<u8>>,
        urls_requested: Arc<Mutex<Vec<String>>>,
        mpd_delay: Duration,
    }

    #[async_trait]
    impl StreamHttpTransport for MockDashTransport {
        async fn execute(
            &self,
            req: HttpRequestSpec,
            _read_body: bool,
            _config: &StreamHttpConfig,
            cancel: &CancellationToken,
        ) -> Result<HttpResponseData, StreamError> {
            self.urls_requested.lock().unwrap().push(req.url.clone());
            if req.url.ends_with(".mpd") && !self.mpd_delay.is_zero() {
                tokio::select! {
                    _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                    _ = tokio::time::sleep(self.mpd_delay) => {}
                }
            }
            if req.url.ends_with(".mpd") {
                let bytes = Bytes::from(self.mpd_xml.clone().into_bytes());
                return Ok(HttpResponseData {
                    status: 200,
                    final_url: req.url,
                    headers: HeaderMap::new(),
                    content_length: Some(bytes.len() as u64),
                    content_range_total: None,
                    body: bytes,
                });
            }
            if let Some(data) = self.blobs.get(&req.url) {
                let bytes = Bytes::copy_from_slice(data);
                return Ok(HttpResponseData {
                    status: 200,
                    final_url: req.url,
                    headers: HeaderMap::new(),
                    content_length: Some(bytes.len() as u64),
                    content_range_total: None,
                    body: bytes,
                });
            }
            Ok(HttpResponseData {
                status: 404,
                final_url: req.url,
                headers: HeaderMap::new(),
                content_length: Some(0),
                content_range_total: None,
                body: Bytes::new(),
            })
        }
    }

    fn build_sample_mpd(codecs: &str, seg_dur_ms: u64, seg_count: usize) -> String {
        let total_secs = (seg_dur_ms as f64 * seg_count as f64) / 1000.0;
        let d_ticks = seg_dur_ms;
        let r = seg_count.saturating_sub(1);
        format!(
            r#"<MPD mediaPresentationDuration="PT{total_secs}S">
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4" codecs="{codecs}">
      <Representation id="flac_1" bandwidth="3200000">
        <SegmentTemplate timescale="1000" startNumber="1" initialization="https://cdn.fresh.example/init.mp4" media="https://cdn.fresh.example/seg_$Number$.m4s">
          <SegmentTimeline>
            <S t="0" d="{d_ticks}" r="{r}"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#
        )
    }

    fn test_l2_cfg(dir: &TempDir) -> L2CacheConfig {
        L2CacheConfig::new(dir.path())
            .with_access_flush_interval(Duration::from_secs(3600))
            .with_orphan_sweep_delay(Duration::from_secs(3600))
    }

    #[tokio::test]
    async fn test_hybrid_segmented_serves_init_seg0_seg1_then_splices_seg2() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();
        let l2 = Arc::new(L2CacheManager::new(pool, test_l2_cfg(&tmp)).unwrap());

        let init = b"INIT_BOX_BYTES".to_vec();
        let seg1 = b"SEG_ONE_AUDIO".to_vec();
        let seg2 = b"SEG_TWO_AUDIO".to_vec();
        let seg3 = b"SEG_THREE_FROM_FRESH_CDN".to_vec();
        let seg4 = b"SEG_FOUR_FROM_FRESH_CDN".to_vec();

        let pkg = DashL2Package {
            mime_type: "audio/mp4".to_string(),
            codecs: Some("flac".to_string()),
            bandwidth: Some(3_200_000),
            total_duration_ms: Some(16_000),
            init_bytes: init.clone(),
            segments: vec![
                DashL2SegmentEntry {
                    number: 1,
                    start_ms: 0,
                    duration_ms: 4_000,
                    bytes: seg1.clone(),
                },
                DashL2SegmentEntry {
                    number: 2,
                    start_ms: 4_000,
                    duration_ms: 4_000,
                    bytes: seg2.clone(),
                },
            ],
        };

        let key = StreamKey::new("tidal", "dash_ok", "HI_RES_LOSSLESS");
        l2.store_dash_head(&key, &pkg, 0).await.unwrap();
        let hit = l2.lookup_dash_head(&key).await.unwrap().unwrap();

        let mut blobs = HashMap::new();
        blobs.insert("https://cdn.fresh.example/seg_3.m4s".to_string(), seg3.clone());
        blobs.insert("https://cdn.fresh.example/seg_4.m4s".to_string(), seg4.clone());
        let transport = Arc::new(MockDashTransport {
            mpd_xml: build_sample_mpd("flac", 4_000, 4),
            blobs,
            urls_requested: Arc::new(Mutex::new(Vec::new())),
            mpd_delay: Duration::from_millis(120),
        });

        let stream = HybridSegmentedStream::new(
            key,
            hit,
            "https://api.tidal.example/track.mpd",
            transport.clone(),
            Arc::clone(&l2),
            CancellationToken::new(),
            HybridSegmentedConfig::default(),
        )
        .unwrap();

        // Local [init + seg_0 + seg_1] MUST be readable in < 40ms despite 120ms MPD fetch!
        let local_expected: Vec<u8> = [init.as_slice(), seg1.as_slice(), seg2.as_slice()].concat();
        let started = Instant::now();
        let mut local_buf = vec![0u8; local_expected.len()];
        let n_local = read_all_at(&stream, 0, &mut local_buf).await.unwrap();
        assert_eq!(n_local, local_expected.len());
        assert_eq!(local_buf, local_expected);
        assert!(started.elapsed() < Duration::from_millis(40));

        // Reading across boundary into segment index 2 (seg_3.m4s) & 3 (seg_4.m4s) splices seamlessly!
        let full_expected: Vec<u8> = [
            init.as_slice(),
            seg1.as_slice(),
            seg2.as_slice(),
            seg3.as_slice(),
            seg4.as_slice(),
        ]
        .concat();
        let mut tail_buf = vec![0u8; seg3.len() + seg4.len()];
        let n_tail = read_all_at(&stream, local_expected.len() as u64, &mut tail_buf)
            .await
            .unwrap();
        assert_eq!(n_tail, tail_buf.len());
        assert_eq!(
            &[local_buf, tail_buf].concat()[..],
            &full_expected[..]
        );

        // Fresh manifest must NEVER re-fetch init.mp4, seg_1.m4s, or seg_2.m4s!
        let urls = transport.urls_requested.lock().unwrap().clone();
        assert!(!urls.iter().any(|u| u.ends_with("init.mp4")));
        assert!(!urls.iter().any(|u| u.ends_with("seg_1.m4s")));
        assert!(!urls.iter().any(|u| u.ends_with("seg_2.m4s")));
        assert!(urls.iter().any(|u| u.ends_with("seg_3.m4s")));

        // Seek to segment 3 (start_ms = 8000) delegates to primed proxy and yields init + seg3 + seg4.
        let seek_target = stream.seek_to_time_ms(8_500).await.unwrap().unwrap();
        assert_eq!(seek_target.segment_index, 2);
        let mut seek_buf = vec![0u8; init.len() + seg3.len() + seg4.len()];
        let n_seek = read_all_at(&stream, 0, &mut seek_buf).await.unwrap();
        assert_eq!(n_seek, seek_buf.len());
        assert_eq!(
            seek_buf,
            [init.as_slice(), seg3.as_slice(), seg4.as_slice()].concat()
        );

        drop(stream);
        l2.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn test_hybrid_segmented_mismatch_deletes_l2_and_preserves_local_head() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let pool = open_test_database().await.unwrap();
        let tmp = TempDir::new().unwrap();
        let l2 = Arc::new(L2CacheManager::new(pool.clone(), test_l2_cfg(&tmp)).unwrap());

        let init = b"OLD_INIT".to_vec();
        let seg1 = b"OLD_SEG1".to_vec();
        let seg2 = b"OLD_SEG2".to_vec();
        let pkg = DashL2Package {
            mime_type: "audio/mp4".to_string(),
            codecs: Some("flac".to_string()),
            bandwidth: Some(3_200_000),
            total_duration_ms: Some(16_000),
            init_bytes: init.clone(),
            segments: vec![
                DashL2SegmentEntry {
                    number: 1,
                    start_ms: 0,
                    duration_ms: 4_000,
                    bytes: seg1.clone(),
                },
                DashL2SegmentEntry {
                    number: 2,
                    start_ms: 4_000,
                    duration_ms: 4_000,
                    bytes: seg2.clone(),
                },
            ],
        };

        let key = StreamKey::new("tidal", "dash_mismatch", "HI_RES");
        l2.store_dash_head(&key, &pkg, 0).await.unwrap();
        let hit = l2.lookup_dash_head(&key).await.unwrap().unwrap();

        let mismatch_events = Arc::new(Mutex::new(Vec::new()));
        let events_clone = Arc::clone(&mismatch_events);
        let cb: FormatMismatchCallback = Arc::new(move |k, reason| {
            events_clone.lock().unwrap().push((k, reason));
        });

        // Fresh MPD switched codec from flac to mp4a.40.2!
        let transport = Arc::new(MockDashTransport {
            mpd_xml: build_sample_mpd("mp4a.40.2", 4_000, 4),
            blobs: HashMap::new(),
            urls_requested: Arc::new(Mutex::new(Vec::new())),
            mpd_delay: Duration::ZERO,
        });

        let stream = HybridSegmentedStream::new(
            key.clone(),
            hit,
            "https://api.tidal.example/mismatch.mpd",
            transport,
            Arc::clone(&l2),
            CancellationToken::new(),
            HybridSegmentedConfig {
                on_mismatch: Some(cb),
                ..Default::default()
            },
        )
        .unwrap();

        assert!(stream.wait_ready().await.is_err());
        assert!(matches!(
            stream.mismatch_reason(),
            Some(FormatMismatchReason::DashSpecMismatch { .. })
        ));
        assert_eq!(mismatch_events.lock().unwrap().len(), 1);
        assert!(L2HeadCacheRepository::get(&pool, &key).await.unwrap().is_none());

        // Local [0, local_end) remains readable cleanly!
        let local_expected: Vec<u8> = [init.as_slice(), seg1.as_slice(), seg2.as_slice()].concat();
        let mut local_buf = vec![0u8; local_expected.len()];
        let n = read_all_at(&stream, 0, &mut local_buf).await.unwrap();
        assert_eq!(n, local_expected.len());
        assert_eq!(local_buf, local_expected);

        // Reading beyond local_end returns clean EOF (0) so Active Deck's decoder never dies
        // before the Standby Deck's +800ms takeover.
        let mut remote_buf = [0u8; 32];
        assert_eq!(
            stream
                .read_at(local_expected.len() as u64, &mut remote_buf)
                .await
                .unwrap(),
            0
        );

        drop(stream);
        l2.shutdown().await.unwrap();
    }
}
