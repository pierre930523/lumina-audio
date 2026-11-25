use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ops::RangeInclusive;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use core_types::{ManifestFormat, StreamKey, StreamSourceSpec};
use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};
use reqwest::header::HeaderMap;
use reqwest::{Client, Method};
use tokio::sync::{Mutex as AsyncMutex, watch};
use tokio_util::sync::CancellationToken;

use super::l2_cache::{DashL2Package, DashL2SegmentEntry, MAX_DASH_L2_SEGMENTS};
use super::{
    ByteStreamSource, DEFAULT_REFRESH_403_BACKOFFS, FormatMismatchReason, HttpRequestSpec,
    InFlightDownloadGuard, ReqwestStreamTransport, SegmentedSeekTarget, StreamError,
    StreamHttpConfig, StreamHttpTransport, StreamRefreshHandler, StreamRefreshOutcome,
    StreamRefreshRequest, await_watch_result, build_sanitized_headers, execute_with_epoch_watch,
    normalize_mime_base, streaming_runtime, subscribe_network_epoch,
};

/// Default number of future DASH media segments prefetched ahead of the active read position.
pub const DEFAULT_PREFETCH_AHEAD: usize = 3;

/// Default in-memory RAM LRU byte cap for cached DASH media segments: 16 MiB.
pub const DEFAULT_MAX_SEGMENT_CACHE_BYTES: usize = 16 * 1024 * 1024;

/// Default maximum number of DASH media segments retained in the RAM LRU cache.
pub const DEFAULT_MAX_CACHED_SEGMENTS: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashSegment {
    pub index: usize,
    pub number: u64,
    pub time: u64,
    pub start_ms: u64,
    pub duration_ms: u64,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedDashManifest {
    pub init_url: Option<String>,
    pub segments: Vec<DashSegment>,
    pub bandwidth: u64,
    pub mime_type: Option<String>,
    pub codecs: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Default)]
struct SegmentTemplateRaw {
    initialization: Option<String>,
    media: Option<String>,
    timescale: Option<u64>,
    start_number: Option<u64>,
    duration: Option<u64>,
    presentation_time_offset: Option<u64>,
    timeline: Vec<TimelineEntryRaw>,
}

impl SegmentTemplateRaw {
    fn merged_with(&self, child: &Self) -> Self {
        Self {
            initialization: child
                .initialization
                .clone()
                .or_else(|| self.initialization.clone()),
            media: child.media.clone().or_else(|| self.media.clone()),
            timescale: child.timescale.or(self.timescale),
            start_number: child.start_number.or(self.start_number),
            duration: child.duration.or(self.duration),
            presentation_time_offset: child
                .presentation_time_offset
                .or(self.presentation_time_offset),
            timeline: if !child.timeline.is_empty() {
                child.timeline.clone()
            } else {
                self.timeline.clone()
            },
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct TimelineEntryRaw {
    t: Option<u64>,
    d: u64,
    r: i64,
}

#[derive(Debug, Clone, Default)]
struct SegmentListRaw {
    initialization_url: Option<String>,
    timescale: Option<u64>,
    duration: Option<u64>,
    segment_urls: Vec<String>,
}

impl SegmentListRaw {
    fn merged_with(&self, child: &Self) -> Self {
        Self {
            initialization_url: child
                .initialization_url
                .clone()
                .or_else(|| self.initialization_url.clone()),
            timescale: child.timescale.or(self.timescale),
            duration: child.duration.or(self.duration),
            segment_urls: if !child.segment_urls.is_empty() {
                child.segment_urls.clone()
            } else {
                self.segment_urls.clone()
            },
        }
    }
}

#[derive(Debug, Clone, Default)]
struct RepresentationRaw {
    id: String,
    bandwidth: u64,
    mime_type: Option<String>,
    codecs: Option<String>,
    base_url: Option<String>,
    segment_template: Option<SegmentTemplateRaw>,
    segment_list: Option<SegmentListRaw>,
    is_audio: Option<bool>,
}

#[derive(Debug, Clone, Default)]
struct AdaptationSetRaw {
    content_type: Option<String>,
    mime_type: Option<String>,
    codecs: Option<String>,
    base_url: Option<String>,
    segment_template: Option<SegmentTemplateRaw>,
    segment_list: Option<SegmentListRaw>,
    has_audio_channel_config: bool,
    representations: Vec<RepresentationRaw>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ActiveContainer {
    Mpd,
    Period,
    AdaptationSet,
    Representation,
    SegmentTemplate,
    SegmentTimeline,
    SegmentList,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum SegmentSlot {
    Init,
    Media(usize),
}

type InFlightSegRx = watch::Receiver<Option<Result<Bytes, StreamError>>>;

#[derive(Debug)]
struct SegmentLruCache {
    max_bytes: usize,
    max_entries: usize,
    total_bytes: usize,
    entries: HashMap<usize, Bytes>,
    lru: VecDeque<usize>,
}

impl SegmentLruCache {
    fn new(max_bytes: usize, max_entries: usize) -> Self {
        Self {
            max_bytes: max_bytes.max(1),
            max_entries: max_entries.max(1),
            total_bytes: 0,
            entries: HashMap::new(),
            lru: VecDeque::new(),
        }
    }

    fn touch(&mut self, seg_idx: usize) {
        if let Some(pos) = self.lru.iter().position(|&k| k == seg_idx) {
            self.lru.remove(pos);
            self.lru.push_back(seg_idx);
        }
    }

    fn get(&mut self, seg_idx: usize) -> Option<Bytes> {
        let bytes = self.entries.get(&seg_idx)?.clone();
        self.touch(seg_idx);
        Some(bytes)
    }

    fn peek(&self, seg_idx: usize) -> Option<&Bytes> {
        self.entries.get(&seg_idx)
    }

    fn contains_key(&self, seg_idx: usize) -> bool {
        self.entries.contains_key(&seg_idx)
    }

    fn insert(
        &mut self,
        seg_idx: usize,
        bytes: Bytes,
        protected: RangeInclusive<usize>,
    ) {
        if let Some(old) = self.entries.insert(seg_idx, bytes.clone()) {
            self.total_bytes = self.total_bytes.saturating_sub(old.len());
            self.total_bytes = self.total_bytes.saturating_add(bytes.len());
            self.touch(seg_idx);
        } else {
            self.total_bytes = self.total_bytes.saturating_add(bytes.len());
            self.lru.push_back(seg_idx);
        }

        while (self.total_bytes > self.max_bytes || self.entries.len() > self.max_entries)
            && self.entries.len() > 1
        {
            let Some(pos) = self
                .lru
                .iter()
                .position(|&k| k != seg_idx && !protected.contains(&k))
            else {
                break;
            };
            if let Some(evicted_key) = self.lru.remove(pos)
                && let Some(evicted_bytes) = self.entries.remove(&evicted_key)
            {
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes.len());
            }
        }
    }

    fn retain_only(&mut self, keep_seg: usize) -> usize {
        let before = self.total_bytes;
        if let Some(bytes) = self.entries.remove(&keep_seg) {
            self.entries.clear();
            self.lru.clear();
            self.total_bytes = bytes.len();
            self.entries.insert(keep_seg, bytes);
            self.lru.push_back(keep_seg);
        } else {
            self.entries.clear();
            self.lru.clear();
            self.total_bytes = 0;
        }
        before.saturating_sub(self.total_bytes)
    }
}

struct InFlightSegment {
    allow_refresh: bool,
    rx: InFlightSegRx,
}

struct WindowState {
    window_epoch: u64,
    window_start_seg: usize,
    window_cancel: CancellationToken,
    init_bytes: Option<Bytes>,
    segment_cache: SegmentLruCache,
    in_flight: HashMap<(u64, SegmentSlot), InFlightSegment>,
}

#[derive(Clone)]
struct SegmentRefreshContext {
    key: Option<StreamKey>,
    manifest_slot: Arc<RwLock<ParsedDashManifest>>,
    manifest_source_url: Arc<RwLock<Option<String>>>,
    headers_slot: Arc<RwLock<HeaderMap>>,
    mime_type: Option<String>,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    refresh_lock: Arc<AsyncMutex<()>>,
    backoffs: [Duration; 2],
}

impl SegmentRefreshContext {
    fn provider_id(&self) -> String {
        self.key
            .as_ref()
            .map(|k| k.provider_id.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }

    fn current_headers(&self) -> HeaderMap {
        self.headers_slot
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    fn slot_url(&self, slot: SegmentSlot) -> Option<String> {
        let guard = self.manifest_slot.read().ok()?;
        match slot {
            SegmentSlot::Init => guard.init_url.clone(),
            SegmentSlot::Media(idx) => guard.segments.get(idx).map(|s| s.url.clone()),
        }
    }
}

fn manifests_compatible(old: &ParsedDashManifest, new: &ParsedDashManifest) -> bool {
    if old.init_url.is_some() != new.init_url.is_some() {
        return false;
    }
    if let (Some(a), Some(b)) = (&old.mime_type, &new.mime_type)
        && normalize_mime_base(a) != normalize_mime_base(b)
    {
        return false;
    }
    if let (Some(a), Some(b)) = (&old.codecs, &new.codecs)
        && !a.trim().eq_ignore_ascii_case(b.trim())
    {
        return false;
    }
    if old.segments.len() != new.segments.len() {
        return false;
    }
    old.segments
        .iter()
        .zip(new.segments.iter())
        .all(|(a, b)| a.start_ms == b.start_ms && a.duration_ms == b.duration_ms)
}

#[allow(clippy::too_many_arguments)]
async fn resolve_mpd_xml_for_spec(
    manifest_url_or_xml: &str,
    headers: &HeaderMap,
    provider_id: &str,
    transport: &dyn StreamHttpTransport,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<(String, Option<String>), StreamError> {
    let trimmed = manifest_url_or_xml.trim_start_matches('\u{feff}').trim_start();
    if trimmed.starts_with('<') {
        return Ok((trimmed.to_string(), None));
    }
    if cancel.is_cancelled() {
        return Err(StreamError::Cancelled);
    }
    let req = HttpRequestSpec {
        method: Method::GET,
        url: trimmed.to_string(),
        headers: headers.clone(),
        range: None,
    };
    let resp = execute_with_epoch_watch(transport, req, true, config, cancel, epoch_rx).await?;
    if resp.status == 401 {
        return Err(StreamError::AuthRequired {
            provider_id: provider_id.to_string(),
            status: 401,
        });
    }
    if !(200..300).contains(&resp.status) {
        return Err(StreamError::HttpStatus(resp.status));
    }
    let xml = String::from_utf8(resp.body.to_vec()).map_err(|e| {
        StreamError::InvalidManifest(format!("MPD manifest is not valid UTF-8: {e}"))
    })?;
    Ok((xml, Some(resp.final_url)))
}

#[allow(clippy::too_many_arguments)]
async fn attempt_segment_refresh_after_403(
    ctx: &SegmentRefreshContext,
    slot: SegmentSlot,
    failed_url: &str,
    status_code: u16,
    refresh_attempts: &mut u8,
    transport: &dyn StreamHttpTransport,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<bool, StreamError> {
    let (Some(handler), Some(key)) = (&ctx.refresh_handler, &ctx.key) else {
        return Err(StreamError::HttpStatus(status_code));
    };

    // Fast CAS before lock acquisition
    if ctx.slot_url(slot).as_deref() != Some(failed_url) {
        return Ok(false);
    }

    let _guard = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Err(StreamError::Cancelled),
        g = ctx.refresh_lock.lock() => g,
    };

    // Serialized CAS after acquiring refresh_lock
    if ctx.slot_url(slot).as_deref() != Some(failed_url) {
        return Ok(false);
    }

    if *refresh_attempts >= 2 {
        return Err(StreamError::HttpStatus(status_code));
    }
    let delay = ctx.backoffs[*refresh_attempts as usize];
    *refresh_attempts += 1;
    let attempt = *refresh_attempts;

    if !delay.is_zero() {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(StreamError::Cancelled),
            _ = tokio::time::sleep(delay) => {}
        }
    }

    if ctx.slot_url(slot).as_deref() != Some(failed_url) {
        return Ok(false);
    }

    let req = StreamRefreshRequest {
        provider_id: key.provider_id.clone(),
        track_id: key.track_id.clone(),
        quality_key: key.quality_key.clone(),
        failed_url: failed_url.to_string(),
        status_code,
        attempt,
        expected_content_length: None,
        expected_mime_type: ctx.mime_type.clone(),
        expected_kind: Some("segmented_manifest".to_string()),
        is_initial_probe: false,
    };

    match handler.refresh_after_403(req, cancel).await {
        Ok(StreamRefreshOutcome::Refreshed(new_spec)) => {
            let (new_manifest_src, new_headers_map) = match &new_spec {
                StreamSourceSpec::SegmentedManifest {
                    manifest_url_or_xml,
                    format: ManifestFormat::Dash,
                    headers,
                    ..
                } => (manifest_url_or_xml.clone(), headers.clone()),
                _ => return Err(StreamError::FormatChanged(Box::new(new_spec))),
            };

            let sanitized_headers = build_sanitized_headers(&new_headers_map)?;
            let (xml_text, base_url) = resolve_mpd_xml_for_spec(
                &new_manifest_src,
                &sanitized_headers,
                &key.provider_id,
                transport,
                config,
                cancel,
                epoch_rx,
            )
            .await?;
            let new_manifest = parse_mpd_xml(&xml_text, base_url.as_deref())?;

            let compatible = ctx
                .manifest_slot
                .read()
                .map(|old| manifests_compatible(&old, &new_manifest))
                .unwrap_or(false);
            if !compatible {
                return Err(StreamError::FormatChanged(Box::new(new_spec)));
            }

            if let Ok(mut m_guard) = ctx.manifest_slot.write() {
                *m_guard = new_manifest;
            }
            if let Ok(mut h_guard) = ctx.headers_slot.write() {
                *h_guard = sanitized_headers;
            }
            if let Ok(mut src_guard) = ctx.manifest_source_url.write() {
                *src_guard = base_url;
            }
            Ok(true)
        }
        Ok(StreamRefreshOutcome::FormatChanged(new_spec, _reason)) => {
            Err(StreamError::FormatChanged(Box::new(new_spec)))
        }
        Ok(StreamRefreshOutcome::AuthRequired { provider_id, .. }) => {
            Err(StreamError::AuthRequired {
                provider_id,
                status: 401,
            })
        }
        Err(err @ (StreamError::Cancelled | StreamError::AuthRequired { .. } | StreamError::FormatChanged(_))) => {
            Err(err)
        }
        Err(err) => {
            if *refresh_attempts >= 2 {
                Err(err)
            } else {
                Ok(false)
            }
        }
    }
}

struct SegFlightCleanup {
    key: (u64, SegmentSlot),
    in_flight_active: Arc<Mutex<WindowState>>,
    tx: watch::Sender<Option<Result<Bytes, StreamError>>>,
    completed: bool,
}

impl Drop for SegFlightCleanup {
    fn drop(&mut self) {
        if let Ok(mut st) = self.in_flight_active.lock() {
            st.in_flight.remove(&self.key);
        }
        if !self.completed {
            let _ = self.tx.send(Some(Err(StreamError::Cancelled)));
        }
    }
}

/// Virtual byte-stream proxy for unencrypted MPEG-DASH `.mpd` manifests (`init` + `.m4s`
/// segments), supporting bounded ahead-of-play prefetching and timeline seeking.
pub struct SegmentedStreamProxy {
    manifest: Arc<RwLock<ParsedDashManifest>>,
    manifest_source_url: Arc<RwLock<Option<String>>>,
    headers: Arc<RwLock<HeaderMap>>,
    key: Option<StreamKey>,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    refresh_lock: Arc<AsyncMutex<()>>,
    refresh_backoffs: [Duration; 2],
    epoch_rx: watch::Receiver<u64>,
    needs_network_epoch_reset: bool,
    hint_extension: Option<String>,
    mime_type: Option<String>,
    prefetch_ahead: usize,
    cancel: CancellationToken,
    transport: Arc<dyn StreamHttpTransport>,
    config: StreamHttpConfig,
    state: Arc<Mutex<WindowState>>,
    active_downloads: Arc<AtomicUsize>,
}

impl SegmentedStreamProxy {
    /// Opens a `SegmentedStreamProxy` from either inline MPD XML or an HTTP(S) `.mpd` manifest URL.
    pub async fn open(
        manifest_url_or_xml: impl Into<String>,
        headers: &BTreeMap<String, String>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
    ) -> Result<Self, StreamError> {
        let transport = Arc::new(ReqwestStreamTransport::shared()?);
        Self::open_with_transport(
            manifest_url_or_xml,
            headers,
            hint_extension,
            mime_type,
            transport,
            StreamHttpConfig::default(),
            CancellationToken::new(),
        )
        .await
    }

    /// Opens a `SegmentedStreamProxy` with an explicit `reqwest::Client`.
    pub async fn open_with_client(
        manifest_url_or_xml: impl Into<String>,
        headers: &BTreeMap<String, String>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        client: Client,
    ) -> Result<Self, StreamError> {
        Self::open_with_transport(
            manifest_url_or_xml,
            headers,
            hint_extension,
            mime_type,
            Arc::new(ReqwestStreamTransport::from_client(client)),
            StreamHttpConfig::default(),
            CancellationToken::new(),
        )
        .await
    }

    /// Opens a `SegmentedStreamProxy` using a custom [`StreamHttpTransport`], [`StreamHttpConfig`],
    /// and [`CancellationToken`].
    pub async fn open_with_transport(
        manifest_url_or_xml: impl Into<String>,
        headers: &BTreeMap<String, String>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        transport: Arc<dyn StreamHttpTransport>,
        config: StreamHttpConfig,
        cancel: CancellationToken,
    ) -> Result<Self, StreamError> {
        Self::open_with_refresh(
            manifest_url_or_xml,
            headers,
            hint_extension,
            mime_type,
            transport,
            config,
            cancel,
            None,
            None,
            false,
            DEFAULT_REFRESH_403_BACKOFFS,
            subscribe_network_epoch(),
        )
        .await
    }

    /// Opens a `SegmentedStreamProxy` with optional stream key, 403/410 self-healing handler,
    /// custom retry backoffs, and network-epoch receiver (healing initial `.mpd` 403/410 as well).
    #[allow(clippy::too_many_arguments)]
    pub async fn open_with_refresh(
        manifest_url_or_xml: impl Into<String>,
        headers: &BTreeMap<String, String>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        transport: Arc<dyn StreamHttpTransport>,
        config: StreamHttpConfig,
        cancel: CancellationToken,
        key: Option<StreamKey>,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
        needs_network_epoch_reset: bool,
        refresh_backoffs: [Duration; 2],
        mut epoch_rx: watch::Receiver<u64>,
    ) -> Result<Self, StreamError> {
        let mut current_src = manifest_url_or_xml.into();
        let mut header_map = build_sanitized_headers(headers)?;
        let provider_id = key
            .as_ref()
            .map(|k| k.provider_id.clone())
            .unwrap_or_else(|| "unknown".to_string());

        let mut refresh_attempts: u8 = 0;
        let (xml_text, base_url) = loop {
            let trimmed = current_src.trim_start_matches('\u{feff}').trim_start();
            if trimmed.starts_with('<') {
                break (trimmed.to_string(), None);
            }
            if cancel.is_cancelled() {
                return Err(StreamError::Cancelled);
            }
            let _dl_guard = InFlightDownloadGuard::new(None);
            let req_url = trimmed.to_string();
            let req = HttpRequestSpec {
                method: Method::GET,
                url: req_url.clone(),
                headers: header_map.clone(),
                range: None,
            };
            let resp = execute_with_epoch_watch(
                transport.as_ref(),
                req,
                true,
                &config,
                &cancel,
                &mut epoch_rx,
            )
            .await?;
            drop(_dl_guard);

            if resp.status == 401 {
                return Err(StreamError::AuthRequired {
                    provider_id,
                    status: 401,
                });
            }
            if (resp.status == 403 || resp.status == 410)
                && let (Some(handler), Some(stream_key)) = (&refresh_handler, &key)
            {
                if refresh_attempts >= 2 {
                    return Err(StreamError::HttpStatus(resp.status));
                }
                let delay = refresh_backoffs[refresh_attempts as usize];
                refresh_attempts += 1;
                if !delay.is_zero() {
                    tokio::select! {
                        biased;
                        _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                        _ = tokio::time::sleep(delay) => {}
                    }
                }
                let refresh_req = StreamRefreshRequest {
                    provider_id: stream_key.provider_id.clone(),
                    track_id: stream_key.track_id.clone(),
                    quality_key: stream_key.quality_key.clone(),
                    failed_url: req_url,
                    status_code: resp.status,
                    attempt: refresh_attempts,
                    expected_content_length: None,
                    expected_mime_type: mime_type.clone(),
                    expected_kind: Some("segmented_manifest".to_string()),
                    is_initial_probe: true,
                };
                match handler.refresh_after_403(refresh_req, &cancel).await {
                    Ok(StreamRefreshOutcome::Refreshed(new_spec)) => match new_spec {
                        StreamSourceSpec::SegmentedManifest {
                            manifest_url_or_xml,
                            format: ManifestFormat::Dash,
                            headers: new_hdrs,
                            ..
                        } => {
                            current_src = manifest_url_or_xml;
                            header_map = build_sanitized_headers(&new_hdrs)?;
                            continue;
                        }
                        other => return Err(StreamError::FormatChanged(Box::new(other))),
                    },
                    Ok(StreamRefreshOutcome::FormatChanged(new_spec, _)) => {
                        return Err(StreamError::FormatChanged(Box::new(new_spec)));
                    }
                    Ok(StreamRefreshOutcome::AuthRequired { provider_id, .. }) => {
                        return Err(StreamError::AuthRequired {
                            provider_id,
                            status: 401,
                        });
                    }
                    Err(err @ (StreamError::Cancelled | StreamError::AuthRequired { .. } | StreamError::FormatChanged(_))) => {
                        return Err(err);
                    }
                    Err(err) => {
                        if refresh_attempts >= 2 {
                            return Err(err);
                        }
                        continue;
                    }
                }
            }
            if !(200..300).contains(&resp.status) {
                return Err(StreamError::HttpStatus(resp.status));
            }
            let xml = String::from_utf8(resp.body.to_vec()).map_err(|e| {
                StreamError::InvalidManifest(format!("MPD manifest is not valid UTF-8: {e}"))
            })?;
            break (xml, Some(resp.final_url));
        };

        let mut proxy = Self::from_parsed_parts(
            &xml_text,
            base_url.as_deref(),
            header_map,
            hint_extension,
            mime_type,
            transport,
            config,
            cancel,
        )?;
        proxy.key = key;
        proxy.refresh_handler = refresh_handler;
        proxy.needs_network_epoch_reset = needs_network_epoch_reset;
        proxy.refresh_backoffs = refresh_backoffs;
        proxy.epoch_rx = epoch_rx;
        Ok(proxy)
    }

    /// Constructs a `SegmentedStreamProxy` synchronously from inline MPD XML.
    pub fn from_mpd_xml(
        mpd_xml: &str,
        base_url: Option<&str>,
        headers: &BTreeMap<String, String>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
    ) -> Result<Self, StreamError> {
        let transport = Arc::new(ReqwestStreamTransport::shared()?);
        let header_map = build_sanitized_headers(headers)?;
        Self::from_parsed_parts(
            mpd_xml,
            base_url,
            header_map,
            hint_extension,
            mime_type,
            transport,
            StreamHttpConfig::default(),
            CancellationToken::new(),
        )
    }

    /// Constructs a `SegmentedStreamProxy` directly from a parsed manifest and injects cached
    /// `DashL2Package` initialization + opening segments into `WindowState` (locking virtual offsets
    /// and starting prefetch from the next uncached segment).
    #[allow(clippy::too_many_arguments)]
    pub fn from_cached_package(
        pkg: &DashL2Package,
        manifest: ParsedDashManifest,
        headers: &BTreeMap<String, String>,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        transport: Arc<dyn StreamHttpTransport>,
        config: StreamHttpConfig,
        cancel: CancellationToken,
    ) -> Result<Self, StreamError> {
        validate_dash_package_compatibility(pkg, &manifest)
            .map_err(|reason| StreamError::InvalidManifest(reason.to_string()))?;

        let header_map = build_sanitized_headers(headers)?;
        let derived_mime = mime_type.or_else(|| manifest.mime_type.clone());
        let derived_ext = hint_extension
            .map(|s| s.trim().trim_start_matches('.').to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .or_else(|| infer_dash_extension(derived_mime.as_deref(), manifest.codecs.as_deref()));

        let window_cancel = cancel.child_token();
        let proxy = Self {
            manifest: Arc::new(RwLock::new(manifest)),
            manifest_source_url: Arc::new(RwLock::new(None)),
            headers: Arc::new(RwLock::new(header_map)),
            key: None,
            refresh_handler: None,
            refresh_lock: Arc::new(AsyncMutex::new(())),
            refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
            epoch_rx: subscribe_network_epoch(),
            needs_network_epoch_reset: false,
            hint_extension: derived_ext,
            mime_type: derived_mime,
            prefetch_ahead: DEFAULT_PREFETCH_AHEAD,
            cancel,
            transport,
            config,
            state: Arc::new(Mutex::new(WindowState {
                window_epoch: 0,
                window_start_seg: 0,
                window_cancel,
                init_bytes: None,
                segment_cache: SegmentLruCache::new(
                    DEFAULT_MAX_SEGMENT_CACHE_BYTES,
                    DEFAULT_MAX_CACHED_SEGMENTS,
                ),
                in_flight: HashMap::new(),
            })),
            active_downloads: Arc::new(AtomicUsize::new(0)),
        };

        proxy
            .prime_cached_package(pkg)
            .map_err(|reason| StreamError::InvalidManifest(reason.to_string()))?;
        Ok(proxy)
    }

    #[allow(clippy::too_many_arguments)]
    fn from_parsed_parts(
        mpd_xml: &str,
        base_url: Option<&str>,
        headers: HeaderMap,
        hint_extension: Option<String>,
        mime_type: Option<String>,
        transport: Arc<dyn StreamHttpTransport>,
        config: StreamHttpConfig,
        cancel: CancellationToken,
    ) -> Result<Self, StreamError> {
        let manifest = parse_mpd_xml(mpd_xml, base_url)?;
        let derived_mime = mime_type.or_else(|| manifest.mime_type.clone());
        let derived_ext = hint_extension
            .map(|s| s.trim().trim_start_matches('.').to_ascii_lowercase())
            .filter(|s| !s.is_empty())
            .or_else(|| infer_dash_extension(derived_mime.as_deref(), manifest.codecs.as_deref()));

        let window_cancel = cancel.child_token();
        Ok(Self {
            manifest: Arc::new(RwLock::new(manifest)),
            manifest_source_url: Arc::new(RwLock::new(base_url.map(str::to_string))),
            headers: Arc::new(RwLock::new(headers)),
            key: None,
            refresh_handler: None,
            refresh_lock: Arc::new(AsyncMutex::new(())),
            refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
            epoch_rx: subscribe_network_epoch(),
            needs_network_epoch_reset: false,
            hint_extension: derived_ext,
            mime_type: derived_mime,
            prefetch_ahead: DEFAULT_PREFETCH_AHEAD,
            cancel,
            transport,
            config,
            state: Arc::new(Mutex::new(WindowState {
                window_epoch: 0,
                window_start_seg: 0,
                window_cancel,
                init_bytes: None,
                segment_cache: SegmentLruCache::new(
                    DEFAULT_MAX_SEGMENT_CACHE_BYTES,
                    DEFAULT_MAX_CACHED_SEGMENTS,
                ),
                in_flight: HashMap::new(),
            })),
            active_downloads: Arc::new(AtomicUsize::new(0)),
        })
    }

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

    fn refresh_context(&self) -> SegmentRefreshContext {
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

    fn slot_url(&self, slot: SegmentSlot) -> Option<String> {
        let guard = self.manifest.read().ok()?;
        match slot {
            SegmentSlot::Init => guard.init_url.clone(),
            SegmentSlot::Media(idx) => guard.segments.get(idx).map(|s| s.url.clone()),
        }
    }

    fn spawn_slot_fetch(
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

    async fn get_or_fetch_slot(
        &self,
        epoch: u64,
        window_cancel: &CancellationToken,
        slot: SegmentSlot,
        active_seg_hint: usize,
    ) -> Result<Bytes, StreamError> {
        loop {
            {
                let mut st = self
                    .state
                    .lock()
                    .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;
                if st.window_epoch != epoch || window_cancel.is_cancelled() || self.cancel.is_cancelled()
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

    fn schedule_prefetch_ahead(
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

    fn schedule_prefetch_from(
        &self,
        epoch: u64,
        window_cancel: &CancellationToken,
        start: usize,
        active_seg_hint: usize,
    ) {
        let total = self
            .manifest
            .read()
            .map(|m| m.segments.len())
            .unwrap_or(0);
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
                    && !st.in_flight.contains_key(&(epoch, SegmentSlot::Media(seg_idx)))
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
            let mut st = self.state.lock().map_err(|_| FormatMismatchReason::DashSpecMismatch {
                detail: "segmented proxy state lock poisoned".to_string(),
            })?;
            st.init_bytes = if pkg.init_bytes.is_empty() {
                None
            } else {
                Some(Bytes::from(pkg.init_bytes.clone()))
            };
            let protected_end = pkg.segments.len().saturating_add(self.prefetch_ahead);
            for (idx, seg) in pkg.segments.iter().enumerate() {
                st.segment_cache.insert(
                    idx,
                    Bytes::from(seg.bytes.clone()),
                    0..=protected_end,
                );
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
            for (idx, seg_meta) in manifest.segments.iter().take(MAX_DASH_L2_SEGMENTS).enumerate() {
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

/// Validates compatibility between a cached [`DashL2Package`] and a freshly parsed [`ParsedDashManifest`].
pub fn validate_dash_package_compatibility(
    pkg: &DashL2Package,
    manifest: &ParsedDashManifest,
) -> Result<(), FormatMismatchReason> {
    let pkg_has_init = !pkg.init_bytes.is_empty();
    let man_has_init = manifest.init_url.is_some();
    if pkg_has_init != man_has_init {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!(
                "init presence mismatch (cached={pkg_has_init}, manifest={man_has_init})"
            ),
        });
    }

    if !pkg.mime_type.trim().is_empty()
        && let Some(ref man_mime) = manifest.mime_type
        && normalize_mime_base(&pkg.mime_type) != normalize_mime_base(man_mime)
    {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!(
                "mime_type changed (cached={}, manifest={man_mime})",
                pkg.mime_type
            ),
        });
    }

    let pkg_codecs = pkg
        .codecs
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase);
    let man_codecs = manifest
        .codecs
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase);
    if pkg_codecs != man_codecs {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!("codecs changed (cached={pkg_codecs:?}, manifest={man_codecs:?})"),
        });
    }

    if let (Some(cached_dur), Some(fresh_dur)) = (pkg.total_duration_ms, manifest.duration_ms)
        && cached_dur != fresh_dur
    {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!("duration changed (cached={cached_dur}ms, manifest={fresh_dur}ms)"),
        });
    }

    if manifest.segments.len() < pkg.segments.len() {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!(
                "segment count shrunk (cached={}, manifest={})",
                pkg.segments.len(),
                manifest.segments.len()
            ),
        });
    }

    for (idx, cached_seg) in pkg.segments.iter().enumerate() {
        let fresh = &manifest.segments[idx];
        if fresh.number != cached_seg.number
            || fresh.start_ms != cached_seg.start_ms
            || fresh.duration_ms != cached_seg.duration_ms
        {
            return Err(FormatMismatchReason::DashSpecMismatch {
                detail: format!(
                    "segment[{idx}] metadata changed (cached=#{}@{}ms+{}ms, manifest=#{}@{}ms+{}ms)",
                    cached_seg.number,
                    cached_seg.start_ms,
                    cached_seg.duration_ms,
                    fresh.number,
                    fresh.start_ms,
                    fresh.duration_ms
                ),
            });
        }
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn fetch_segment_bytes(
    transport: &dyn StreamHttpTransport,
    ctx: &SegmentRefreshContext,
    slot: SegmentSlot,
    allow_refresh: bool,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<Bytes, StreamError> {
    if cancel.is_cancelled() {
        return Err(StreamError::Cancelled);
    }

    let mut refresh_attempts: u8 = 0;
    let mut cas_retries: u8 = 0;

    loop {
        let Some(req_url) = ctx.slot_url(slot) else {
            return Err(StreamError::InvalidManifest(
                "Requested segment slot out of range".to_string(),
            ));
        };
        let req_headers = ctx.current_headers();
        let req = HttpRequestSpec {
            method: Method::GET,
            url: req_url.clone(),
            headers: req_headers,
            range: None,
        };
        let resp =
            execute_with_epoch_watch(transport, req, true, config, cancel, epoch_rx).await?;

        if resp.status == 401 {
            return Err(StreamError::AuthRequired {
                provider_id: ctx.provider_id(),
                status: 401,
            });
        }

        if resp.status == 403 || resp.status == 410 {
            if !allow_refresh {
                return Err(StreamError::HttpStatus(resp.status));
            }
            let refreshed = attempt_segment_refresh_after_403(
                ctx,
                slot,
                &req_url,
                resp.status,
                &mut refresh_attempts,
                transport,
                config,
                cancel,
                epoch_rx,
            )
            .await?;
            if !refreshed {
                cas_retries += 1;
                if cas_retries > 4 {
                    return Err(StreamError::HttpStatus(resp.status));
                }
            }
            continue;
        }

        if !(200..300).contains(&resp.status) {
            return Err(StreamError::HttpStatus(resp.status));
        }
        return Ok(resp.body);
    }
}

#[async_trait]
impl ByteStreamSource for SegmentedStreamProxy {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if buf.is_empty() {
            return Ok(0);
        }

        let (epoch, window_start_seg, window_cancel) = {
            let st = self
                .state
                .lock()
                .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;
            (st.window_epoch, st.window_start_seg, st.window_cancel.clone())
        };

        let (has_init, total_segs) = self
            .manifest
            .read()
            .map(|m| (m.init_url.is_some(), m.segments.len()))
            .unwrap_or((false, 0));
        let mut cum_offset = 0u64;
        let mut cursor = offset;
        let mut written = 0usize;
        let mut slot_pos = 0usize;

        while written < buf.len() {
            let (slot, active_seg_hint) = if has_init {
                if slot_pos == 0 {
                    (SegmentSlot::Init, window_start_seg)
                } else {
                    let seg_idx = window_start_seg + (slot_pos - 1);
                    if seg_idx >= total_segs {
                        break;
                    }
                    (SegmentSlot::Media(seg_idx), seg_idx)
                }
            } else {
                let seg_idx = window_start_seg + slot_pos;
                if seg_idx >= total_segs {
                    break;
                }
                (SegmentSlot::Media(seg_idx), seg_idx)
            };

            let bytes = self
                .get_or_fetch_slot(epoch, &window_cancel, slot, active_seg_hint)
                .await?;
            let slot_end = cum_offset + bytes.len() as u64;

            if cursor < slot_end {
                let prefetch_anchor = match slot {
                    SegmentSlot::Init => window_start_seg.saturating_sub(1),
                    SegmentSlot::Media(idx) => idx,
                };
                if matches!(slot, SegmentSlot::Media(_)) {
                    self.schedule_prefetch_ahead(epoch, &window_cancel, prefetch_anchor);
                } else if total_segs > window_start_seg && self.prefetch_ahead > 0 {
                    // When reading init, prefetch starting from window_start_seg within the bound.
                    self.schedule_prefetch_ahead(
                        epoch,
                        &window_cancel,
                        window_start_seg.saturating_sub(1),
                    );
                }

                let inner_offset = (cursor - cum_offset) as usize;
                let available = &bytes[inner_offset..];
                let to_copy = available.len().min(buf.len() - written);
                buf[written..written + to_copy].copy_from_slice(&available[..to_copy]);
                written += to_copy;
                cursor += to_copy as u64;
            }

            cum_offset = slot_end;
            slot_pos += 1;
        }

        Ok(written)
    }

    fn len(&self) -> Option<u64> {
        let st = self.state.lock().ok()?;
        let manifest = self.manifest.read().ok()?;
        let mut total = 0u64;
        if manifest.init_url.is_some() {
            total += st.init_bytes.as_ref()?.len() as u64;
        }
        for seg_idx in st.window_start_seg..manifest.segments.len() {
            total += st.segment_cache.peek(seg_idx)?.len() as u64;
        }
        Some(total)
    }

    fn cancel(&self) {
        self.cancel.cancel();
        if let Ok(st) = self.state.lock() {
            st.window_cancel.cancel();
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
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        let (idx, segment_start_ms) = {
            let manifest = self
                .manifest
                .read()
                .map_err(|_| StreamError::Io("segmented proxy manifest lock poisoned".to_string()))?;
            if manifest.segments.is_empty() {
                return Ok(None);
            }
            let idx = manifest
                .segments
                .partition_point(|s| s.start_ms <= target_ms)
                .saturating_sub(1)
                .min(manifest.segments.len() - 1);
            (idx, manifest.segments[idx].start_ms)
        };

        {
            let mut st = self
                .state
                .lock()
                .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;
            st.window_cancel.cancel();
            st.window_epoch = st.window_epoch.wrapping_add(1);
            st.window_start_seg = idx;
            st.window_cancel = self.cancel.child_token();
            // Retain previously cached segments in the LRU cache so backward seeks hit RAM.
        }

        Ok(Some(SegmentedSeekTarget {
            virtual_offset: 0,
            segment_index: idx,
            segment_start_ms,
        }))
    }

    fn reclaim_idle_memory(&self) -> usize {
        self.state
            .lock()
            .map(|mut st| {
                st.window_cancel.cancel();
                st.window_epoch = st.window_epoch.wrapping_add(1);
                st.window_cancel = self.cancel.child_token();
                st.in_flight.clear();
                let keep_seg = st.window_start_seg;
                st.segment_cache.retain_only(keep_seg)
            })
            .unwrap_or(0)
    }
}

pub(crate) fn infer_dash_extension(mime: Option<&str>, codecs: Option<&str>) -> Option<String> {
    if let Some(m) = mime {
        let lower = m.to_ascii_lowercase();
        if lower.contains("webm") {
            return Some("webm".to_string());
        }
        if lower.contains("mp4") {
            return Some("m4a".to_string());
        }
    }
    if let Some(c) = codecs {
        let lower = c.to_ascii_lowercase();
        if lower.contains("opus") || lower.contains("vorbis") {
            return Some("webm".to_string());
        }
    }
    Some("m4a".to_string())
}

/// Parses an ISO 8601 duration string (e.g. `PT3M45.5S`, `PT1H2M3S`, `P0DT4M12S`) to milliseconds.
pub fn parse_iso8601_duration_ms(input: &str) -> Option<u64> {
    let s = input.trim();
    if !s.starts_with('P') {
        return None;
    }
    let rest = &s[1..];
    let (date_part, time_part) = match rest.split_once('T') {
        Some((d, t)) => (d, Some(t)),
        None => (rest, None),
    };

    let mut total_secs = 0.0f64;
    let mut num_buf = String::new();
    for ch in date_part.chars() {
        if ch.is_ascii_digit() || ch == '.' {
            num_buf.push(ch);
        } else {
            let val: f64 = num_buf.parse().ok()?;
            num_buf.clear();
            match ch {
                'D' => total_secs += val * 86_400.0,
                'W' => total_secs += val * 7.0 * 86_400.0,
                'M' => total_secs += val * 30.0 * 86_400.0,
                'Y' => total_secs += val * 365.0 * 86_400.0,
                _ => return None,
            }
        }
    }
    if !num_buf.is_empty() {
        return None;
    }

    if let Some(tp) = time_part {
        for ch in tp.chars() {
            if ch.is_ascii_digit() || ch == '.' {
                num_buf.push(ch);
            } else {
                let val: f64 = num_buf.parse().ok()?;
                num_buf.clear();
                match ch {
                    'H' => total_secs += val * 3600.0,
                    'M' => total_secs += val * 60.0,
                    'S' => total_secs += val,
                    _ => return None,
                }
            }
        }
        if !num_buf.is_empty() {
            return None;
        }
    }

    if !total_secs.is_finite() || total_secs < 0.0 {
        return None;
    }
    Some((total_secs * 1000.0).round() as u64)
}

fn local_tag_name(raw: &[u8]) -> &[u8] {
    match raw.iter().rposition(|&b| b == b':') {
        Some(idx) => &raw[idx + 1..],
        None => raw,
    }
}

fn attr_value(e: &BytesStart<'_>, target: &str) -> Option<String> {
    for attr in e.attributes().flatten() {
        let key = attr.key.as_ref();
        let local = local_tag_name(key);
        if local == target.as_bytes()
            && let Ok(val) = attr.unescape_value()
        {
            return Some(val.into_owned());
        }
    }
    None
}

fn parse_u64_attr(e: &BytesStart<'_>, target: &str) -> Option<u64> {
    attr_value(e, target)?.trim().parse::<u64>().ok()
}

fn parse_i64_attr(e: &BytesStart<'_>, target: &str) -> Option<i64> {
    attr_value(e, target)?.trim().parse::<i64>().ok()
}

fn join_base_url(parent: Option<&str>, child: &str) -> Result<String, StreamError> {
    let trimmed = child.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Ok(trimmed.to_string());
    }
    let Some(base) = parent else {
        return Err(StreamError::InvalidManifest(format!(
            "Relative DASH URL '{trimmed}' requires a BaseURL"
        )));
    };
    let parsed_base = reqwest::Url::parse(base).map_err(|e| {
        StreamError::InvalidManifest(format!("Invalid DASH BaseURL '{base}': {e}"))
    })?;
    let joined = parsed_base.join(trimmed).map_err(|e| {
        StreamError::InvalidManifest(format!(
            "Failed to join DASH URL '{trimmed}' against '{base}': {e}"
        ))
    })?;
    Ok(joined.to_string())
}

fn expand_dash_template(
    template: &str,
    rep_id: &str,
    bandwidth: u64,
    number: u64,
    time: u64,
) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let chars: Vec<char> = template.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] != '$' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        if let Some(rel_end) = chars[i + 1..].iter().position(|&c| c == '$') {
            let token: String = chars[i + 1..i + 1 + rel_end].iter().collect();
            if token.is_empty() {
                out.push('$');
            } else if token == "RepresentationID" {
                out.push_str(rep_id);
            } else if let Some(rest) = token.strip_prefix("Bandwidth") {
                out.push_str(&format_dash_number(bandwidth, rest));
            } else if let Some(rest) = token.strip_prefix("Number") {
                out.push_str(&format_dash_number(number, rest));
            } else if let Some(rest) = token.strip_prefix("Time") {
                out.push_str(&format_dash_number(time, rest));
            } else {
                out.push('$');
                out.push_str(&token);
                out.push('$');
            }
            i += rel_end + 2;
        } else {
            out.push('$');
            i += 1;
        }
    }
    out
}

fn format_dash_number(val: u64, format_suffix: &str) -> String {
    if let Some(spec) = format_suffix.strip_prefix('%')
        && let Some(width_str) = spec.strip_suffix('d')
        && let Ok(width) = width_str.trim_start_matches('0').parse::<usize>()
    {
        return format!("{val:0width$}");
    }
    val.to_string()
}

/// Parses an unencrypted MPEG-DASH MPD XML document into a resolved segment list for the
/// highest-bandwidth audio representation.
pub fn parse_mpd_xml(xml: &str, base_url: Option<&str>) -> Result<ParsedDashManifest, StreamError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut stack: Vec<ActiveContainer> = Vec::new();
    let mut mpd_duration_ms: Option<u64> = None;
    let mut period_duration_ms: Option<u64> = None;
    let mut mpd_base_url: Option<String> = base_url.map(str::to_string);
    let mut period_base_url: Option<String> = None;
    let mut in_first_period = false;
    let mut parsed_first_period = false;
    let mut reading_base_url = false;

    let mut adaptation_sets: Vec<AdaptationSetRaw> = Vec::new();
    let mut current_as: Option<AdaptationSetRaw> = None;
    let mut current_rep: Option<RepresentationRaw> = None;
    let mut current_tmpl: Option<SegmentTemplateRaw> = None;
    let mut current_list: Option<SegmentListRaw> = None;

    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let local = local_tag_name(e.name().as_ref()).to_vec();
                if local.eq_ignore_ascii_case(b"ContentProtection") {
                    return Err(StreamError::DrmRestricted(
                        "DASH MPD contains ContentProtection DRM".to_string(),
                    ));
                }
                handle_start_element(
                    &e,
                    &local,
                    false,
                    &mut stack,
                    &mut mpd_duration_ms,
                    &mut period_duration_ms,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                )?;
            }
            Ok(Event::Empty(e)) => {
                let local = local_tag_name(e.name().as_ref()).to_vec();
                if local.eq_ignore_ascii_case(b"ContentProtection") {
                    return Err(StreamError::DrmRestricted(
                        "DASH MPD contains ContentProtection DRM".to_string(),
                    ));
                }
                handle_start_element(
                    &e,
                    &local,
                    true,
                    &mut stack,
                    &mut mpd_duration_ms,
                    &mut period_duration_ms,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                )?;
                handle_end_element(
                    &local,
                    &mut stack,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut adaptation_sets,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                );
            }
            Ok(Event::Text(e)) => {
                if reading_base_url {
                    let text = e.unescape().map_err(|err| {
                        StreamError::InvalidManifest(format!("Invalid BaseURL text: {err}"))
                    })?;
                    let trimmed = text.trim();
                    if !trimmed.is_empty() {
                        let parent_container = stack.last().copied();
                        match parent_container {
                            Some(ActiveContainer::Mpd) => {
                                mpd_base_url = Some(join_base_url(mpd_base_url.as_deref(), trimmed)?);
                            }
                            Some(ActiveContainer::Period) if in_first_period => {
                                let parent = period_base_url
                                    .as_deref()
                                    .or(mpd_base_url.as_deref());
                                period_base_url = Some(join_base_url(parent, trimmed)?);
                            }
                            Some(ActiveContainer::AdaptationSet) if in_first_period => {
                                if let Some(ref mut aset) = current_as {
                                    let parent = aset
                                        .base_url
                                        .as_deref()
                                        .or(period_base_url.as_deref())
                                        .or(mpd_base_url.as_deref());
                                    aset.base_url = Some(join_base_url(parent, trimmed)?);
                                }
                            }
                            Some(ActiveContainer::Representation) if in_first_period => {
                                if let Some(ref mut rep) = current_rep {
                                    let parent = rep
                                        .base_url
                                        .as_deref()
                                        .or(current_as.as_ref().and_then(|a| a.base_url.as_deref()))
                                        .or(period_base_url.as_deref())
                                        .or(mpd_base_url.as_deref());
                                    rep.base_url = Some(join_base_url(parent, trimmed)?);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Ok(Event::End(e)) => {
                let local = local_tag_name(e.name().as_ref()).to_vec();
                handle_end_element(
                    &local,
                    &mut stack,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut adaptation_sets,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                );
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(StreamError::InvalidManifest(format!(
                    "Failed to parse DASH MPD XML: {e}"
                )));
            }
            _ => {}
        }
        buf.clear();
    }

    if adaptation_sets.is_empty() {
        return Err(StreamError::InvalidManifest(
            "DASH MPD contained no AdaptationSet elements".to_string(),
        ));
    }

    let duration_ms = period_duration_ms.or(mpd_duration_ms);
    let effective_period_base = period_base_url.or(mpd_base_url);

    let mut audio_candidates: Vec<(
        &AdaptationSetRaw,
        &RepresentationRaw,
        Option<String>,
        Option<String>,
    )> = Vec::new();
    let mut untyped_candidates: Vec<(
        &AdaptationSetRaw,
        &RepresentationRaw,
        Option<String>,
        Option<String>,
    )> = Vec::new();

    for aset in &adaptation_sets {
        let as_is_audio = aset
            .content_type
            .as_deref()
            .is_some_and(|ct| ct.eq_ignore_ascii_case("audio"))
            || aset
                .mime_type
                .as_deref()
                .is_some_and(|m| m.to_ascii_lowercase().starts_with("audio/"))
            || aset.has_audio_channel_config;
        let as_is_non_audio = aset
            .content_type
            .as_deref()
            .is_some_and(|ct| !ct.eq_ignore_ascii_case("audio"))
            || aset.mime_type.as_deref().is_some_and(|m| {
                let low = m.to_ascii_lowercase();
                !low.starts_with("audio/") && !low.is_empty()
            });

        for rep in &aset.representations {
            let eff_mime = rep.mime_type.clone().or_else(|| aset.mime_type.clone());
            let eff_codecs = rep.codecs.clone().or_else(|| aset.codecs.clone());
            let rep_is_audio = as_is_audio
                || rep.is_audio == Some(true)
                || eff_mime
                    .as_deref()
                    .is_some_and(|m| m.to_ascii_lowercase().starts_with("audio/"));
            let rep_is_non_audio = as_is_non_audio
                || rep.is_audio == Some(false)
                || eff_mime.as_deref().is_some_and(|m| {
                    let low = m.to_ascii_lowercase();
                    !low.starts_with("audio/") && !low.is_empty()
                });

            if rep_is_audio {
                audio_candidates.push((aset, rep, eff_mime, eff_codecs));
            } else if !rep_is_non_audio {
                untyped_candidates.push((aset, rep, eff_mime, eff_codecs));
            }
        }
    }

    let pool = if !audio_candidates.is_empty() {
        audio_candidates
    } else {
        untyped_candidates
    };

    let (chosen_as, chosen_rep, chosen_mime, chosen_codecs) = pool
        .into_iter()
        .max_by_key(|(_, rep, _, _)| rep.bandwidth)
        .ok_or_else(|| {
            StreamError::InvalidManifest(
                "DASH MPD contained no playable audio Representation".to_string(),
            )
        })?;

    let rep_base_url = chosen_rep
        .base_url
        .clone()
        .or_else(|| chosen_as.base_url.clone())
        .or(effective_period_base);

    let merged_tmpl = match (&chosen_as.segment_template, &chosen_rep.segment_template) {
        (Some(parent), Some(child)) => Some(parent.merged_with(child)),
        (None, Some(child)) => Some(child.clone()),
        (Some(parent), None) => Some(parent.clone()),
        (None, None) => None,
    };
    let merged_list = match (&chosen_as.segment_list, &chosen_rep.segment_list) {
        (Some(parent), Some(child)) => Some(parent.merged_with(child)),
        (None, Some(child)) => Some(child.clone()),
        (Some(parent), None) => Some(parent.clone()),
        (None, None) => None,
    };

    if let Some(tmpl) = merged_tmpl {
        build_segments_from_template(
            &tmpl,
            chosen_rep,
            rep_base_url.as_deref(),
            chosen_mime,
            chosen_codecs,
            duration_ms,
        )
    } else if let Some(list) = merged_list {
        build_segments_from_list(
            &list,
            chosen_rep,
            rep_base_url.as_deref(),
            chosen_mime,
            chosen_codecs,
            duration_ms,
        )
    } else if let Some(url) = rep_base_url {
        Ok(ParsedDashManifest {
            init_url: None,
            segments: vec![DashSegment {
                index: 0,
                number: 1,
                time: 0,
                start_ms: 0,
                duration_ms: duration_ms.unwrap_or(0),
                url,
            }],
            bandwidth: chosen_rep.bandwidth,
            mime_type: chosen_mime,
            codecs: chosen_codecs,
            duration_ms,
        })
    } else {
        Err(StreamError::InvalidManifest(
            "Selected DASH audio Representation has neither SegmentTemplate, SegmentList, nor BaseURL"
                .to_string(),
        ))
    }
}

#[allow(clippy::too_many_arguments)]
fn handle_start_element(
    e: &BytesStart<'_>,
    local: &[u8],
    is_empty: bool,
    stack: &mut Vec<ActiveContainer>,
    mpd_duration_ms: &mut Option<u64>,
    period_duration_ms: &mut Option<u64>,
    in_first_period: &mut bool,
    parsed_first_period: &mut bool,
    reading_base_url: &mut bool,
    current_as: &mut Option<AdaptationSetRaw>,
    current_rep: &mut Option<RepresentationRaw>,
    current_tmpl: &mut Option<SegmentTemplateRaw>,
    current_list: &mut Option<SegmentListRaw>,
) -> Result<(), StreamError> {
    match local {
        b"MPD" => {
            if let Some(dur) = attr_value(e, "mediaPresentationDuration") {
                *mpd_duration_ms = parse_iso8601_duration_ms(&dur);
            }
            if !is_empty {
                stack.push(ActiveContainer::Mpd);
            }
        }
        b"Period" => {
            if !*parsed_first_period {
                *in_first_period = true;
                if let Some(dur) = attr_value(e, "duration") {
                    *period_duration_ms = parse_iso8601_duration_ms(&dur);
                }
            }
            if !is_empty {
                stack.push(ActiveContainer::Period);
            }
        }
        b"BaseURL" if *in_first_period || stack.last() == Some(&ActiveContainer::Mpd) => {
            if !is_empty {
                *reading_base_url = true;
            }
        }
        b"AdaptationSet" if *in_first_period => {
            *current_as = Some(AdaptationSetRaw {
                content_type: attr_value(e, "contentType"),
                mime_type: attr_value(e, "mimeType"),
                codecs: attr_value(e, "codecs"),
                ..Default::default()
            });
            if !is_empty {
                stack.push(ActiveContainer::AdaptationSet);
            }
        }
        b"AudioChannelConfiguration" if *in_first_period => {
            if let Some(aset) = current_as.as_mut() {
                aset.has_audio_channel_config = true;
            }
            if let Some(rep) = current_rep.as_mut() {
                rep.is_audio = Some(true);
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        b"Representation" if *in_first_period => {
            *current_rep = Some(RepresentationRaw {
                id: attr_value(e, "id").unwrap_or_else(|| "0".to_string()),
                bandwidth: parse_u64_attr(e, "bandwidth").unwrap_or(0),
                mime_type: attr_value(e, "mimeType"),
                codecs: attr_value(e, "codecs"),
                ..Default::default()
            });
            if !is_empty {
                stack.push(ActiveContainer::Representation);
            }
        }
        b"SegmentTemplate" if *in_first_period => {
            *current_tmpl = Some(SegmentTemplateRaw {
                initialization: attr_value(e, "initialization"),
                media: attr_value(e, "media"),
                timescale: parse_u64_attr(e, "timescale"),
                start_number: parse_u64_attr(e, "startNumber"),
                duration: parse_u64_attr(e, "duration"),
                presentation_time_offset: parse_u64_attr(e, "presentationTimeOffset"),
                timeline: Vec::new(),
            });
            if !is_empty {
                stack.push(ActiveContainer::SegmentTemplate);
            }
        }
        b"SegmentTimeline" if *in_first_period => {
            if !is_empty {
                stack.push(ActiveContainer::SegmentTimeline);
            }
        }
        b"S" if *in_first_period && stack.last() == Some(&ActiveContainer::SegmentTimeline) => {
            let d = parse_u64_attr(e, "d").ok_or_else(|| {
                StreamError::InvalidManifest("DASH SegmentTimeline <S> missing 'd' attribute".to_string())
            })?;
            let t = parse_u64_attr(e, "t");
            let r = parse_i64_attr(e, "r").unwrap_or(0);
            if let Some(tmpl) = current_tmpl.as_mut() {
                tmpl.timeline.push(TimelineEntryRaw { t, d, r });
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        b"SegmentList" if *in_first_period => {
            *current_list = Some(SegmentListRaw {
                initialization_url: None,
                timescale: parse_u64_attr(e, "timescale"),
                duration: parse_u64_attr(e, "duration"),
                segment_urls: Vec::new(),
            });
            if !is_empty {
                stack.push(ActiveContainer::SegmentList);
            }
        }
        b"Initialization" if *in_first_period && stack.last() == Some(&ActiveContainer::SegmentList) => {
            if let Some(src) = attr_value(e, "sourceURL")
                && let Some(list) = current_list.as_mut()
            {
                list.initialization_url = Some(src);
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        b"SegmentURL" if *in_first_period && stack.last() == Some(&ActiveContainer::SegmentList) => {
            if let Some(media) = attr_value(e, "media")
                && let Some(list) = current_list.as_mut()
            {
                list.segment_urls.push(media);
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        _ => {
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn handle_end_element(
    local: &[u8],
    stack: &mut Vec<ActiveContainer>,
    in_first_period: &mut bool,
    parsed_first_period: &mut bool,
    reading_base_url: &mut bool,
    adaptation_sets: &mut Vec<AdaptationSetRaw>,
    current_as: &mut Option<AdaptationSetRaw>,
    current_rep: &mut Option<RepresentationRaw>,
    current_tmpl: &mut Option<SegmentTemplateRaw>,
    current_list: &mut Option<SegmentListRaw>,
) {
    match local {
        b"BaseURL" => {
            *reading_base_url = false;
        }
        b"SegmentTemplate" => {
            if let Some(tmpl) = current_tmpl.take() {
                if let Some(rep) = current_rep.as_mut() {
                    rep.segment_template = Some(tmpl);
                } else if let Some(aset) = current_as.as_mut() {
                    aset.segment_template = Some(tmpl);
                }
            }
            if stack.last() == Some(&ActiveContainer::SegmentTemplate) {
                stack.pop();
            }
        }
        b"SegmentList" => {
            if let Some(list) = current_list.take() {
                if let Some(rep) = current_rep.as_mut() {
                    rep.segment_list = Some(list);
                } else if let Some(aset) = current_as.as_mut() {
                    aset.segment_list = Some(list);
                }
            }
            if stack.last() == Some(&ActiveContainer::SegmentList) {
                stack.pop();
            }
        }
        b"SegmentTimeline" => {
            if stack.last() == Some(&ActiveContainer::SegmentTimeline) {
                stack.pop();
            }
        }
        b"Representation" => {
            if let Some(rep) = current_rep.take()
                && let Some(aset) = current_as.as_mut()
            {
                aset.representations.push(rep);
            }
            if stack.last() == Some(&ActiveContainer::Representation) {
                stack.pop();
            }
        }
        b"AdaptationSet" => {
            if let Some(aset) = current_as.take() {
                adaptation_sets.push(aset);
            }
            if stack.last() == Some(&ActiveContainer::AdaptationSet) {
                stack.pop();
            }
        }
        b"Period" => {
            if *in_first_period {
                *in_first_period = false;
                *parsed_first_period = true;
            }
            if stack.last() == Some(&ActiveContainer::Period) {
                stack.pop();
            }
        }
        b"MPD" => {
            if stack.last() == Some(&ActiveContainer::Mpd) {
                stack.pop();
            }
        }
        b"SegmentURL" | b"Initialization" | b"S" | b"AudioChannelConfiguration" => {
            if stack.last() == Some(&ActiveContainer::Other) {
                stack.pop();
            }
        }
        _ => {
            if stack.last() == Some(&ActiveContainer::Other) {
                stack.pop();
            }
        }
    }
}

fn build_segments_from_template(
    tmpl: &SegmentTemplateRaw,
    rep: &RepresentationRaw,
    base_url: Option<&str>,
    mime_type: Option<String>,
    codecs: Option<String>,
    duration_ms: Option<u64>,
) -> Result<ParsedDashManifest, StreamError> {
    let timescale = tmpl.timescale.unwrap_or(1).max(1);
    let start_number = tmpl.start_number.unwrap_or(1);
    let pto = tmpl.presentation_time_offset.unwrap_or(0);

    let init_url = tmpl
        .initialization
        .as_deref()
        .map(|raw| {
            let expanded = expand_dash_template(raw, &rep.id, rep.bandwidth, start_number, 0);
            join_base_url(base_url, &expanded)
        })
        .transpose()?;

    let media_tmpl = tmpl.media.as_deref().ok_or_else(|| {
        StreamError::InvalidManifest("DASH SegmentTemplate missing 'media' attribute".to_string())
    })?;

    let mut segments = Vec::new();
    if !tmpl.timeline.is_empty() {
        let mut cursor_ticks = 0u64;
        for entry in &tmpl.timeline {
            if let Some(t) = entry.t {
                cursor_ticks = t;
            }
            if entry.d == 0 {
                return Err(StreamError::InvalidManifest(
                    "DASH SegmentTimeline <S> has d=0".to_string(),
                ));
            }
            let repeat_count = if entry.r < 0 { 1 } else { (entry.r as usize) + 1 };
            for _ in 0..repeat_count {
                let index = segments.len();
                let number = start_number + index as u64;
                let rel_ticks = cursor_ticks.saturating_sub(pto);
                let start_ms = ((rel_ticks as u128 * 1000) / timescale as u128) as u64;
                let seg_dur_ms = ((entry.d as u128 * 1000) / timescale as u128) as u64;
                let expanded = expand_dash_template(
                    media_tmpl,
                    &rep.id,
                    rep.bandwidth,
                    number,
                    cursor_ticks,
                );
                let url = join_base_url(base_url, &expanded)?;
                segments.push(DashSegment {
                    index,
                    number,
                    time: cursor_ticks,
                    start_ms,
                    duration_ms: seg_dur_ms,
                    url,
                });
                cursor_ticks = cursor_ticks.saturating_add(entry.d);
            }
        }
    } else if let Some(fixed_dur) = tmpl.duration.filter(|&d| d > 0) {
        let pres_ms = duration_ms.ok_or_else(|| {
            StreamError::InvalidManifest(
                "DASH fixed-duration SegmentTemplate requires mediaPresentationDuration or Period duration"
                    .to_string(),
            )
        })?;
        let total_ticks = ((pres_ms as u128) * (timescale as u128)).div_ceil(1000);
        let seg_count = total_ticks.div_ceil(fixed_dur as u128).max(1) as usize;
        for index in 0..seg_count {
            let number = start_number + index as u64;
            let time = (index as u64).saturating_mul(fixed_dur);
            let start_ms = ((time as u128 * 1000) / timescale as u128) as u64;
            let seg_dur_ms = ((fixed_dur as u128 * 1000) / timescale as u128) as u64;
            let expanded =
                expand_dash_template(media_tmpl, &rep.id, rep.bandwidth, number, time);
            let url = join_base_url(base_url, &expanded)?;
            segments.push(DashSegment {
                index,
                number,
                time,
                start_ms,
                duration_ms: seg_dur_ms,
                url,
            });
        }
    } else {
        return Err(StreamError::InvalidManifest(
            "DASH SegmentTemplate requires either SegmentTimeline or fixed duration".to_string(),
        ));
    }

    if segments.is_empty() {
        return Err(StreamError::InvalidManifest(
            "DASH SegmentTemplate produced 0 segments".to_string(),
        ));
    }

    let computed_duration_ms = duration_ms.or_else(|| {
        segments
            .last()
            .map(|last| last.start_ms.saturating_add(last.duration_ms))
    });

    Ok(ParsedDashManifest {
        init_url,
        segments,
        bandwidth: rep.bandwidth,
        mime_type,
        codecs,
        duration_ms: computed_duration_ms,
    })
}

fn build_segments_from_list(
    list: &SegmentListRaw,
    rep: &RepresentationRaw,
    base_url: Option<&str>,
    mime_type: Option<String>,
    codecs: Option<String>,
    duration_ms: Option<u64>,
) -> Result<ParsedDashManifest, StreamError> {
    if list.segment_urls.is_empty() {
        return Err(StreamError::InvalidManifest(
            "DASH SegmentList contained no SegmentURL elements".to_string(),
        ));
    }

    let init_url = list
        .initialization_url
        .as_deref()
        .map(|u| join_base_url(base_url, u))
        .transpose()?;

    let timescale = list.timescale.unwrap_or(1).max(1);
    let per_seg_ms = list
        .duration
        .map(|d| ((d as u128 * 1000) / timescale as u128) as u64)
        .or_else(|| duration_ms.map(|total| total / list.segment_urls.len() as u64))
        .unwrap_or(0);

    let mut segments = Vec::with_capacity(list.segment_urls.len());
    for (index, raw_url) in list.segment_urls.iter().enumerate() {
        let url = join_base_url(base_url, raw_url)?;
        let start_ms = (index as u64).saturating_mul(per_seg_ms);
        segments.push(DashSegment {
            index,
            number: (index + 1) as u64,
            time: 0,
            start_ms,
            duration_ms: per_seg_ms,
            url,
        });
    }

    Ok(ParsedDashManifest {
        init_url,
        segments,
        bandwidth: rep.bandwidth,
        mime_type,
        codecs,
        duration_ms,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn spawn_dash_server(
        routes: HashMap<String, Vec<u8>>,
        delay: Duration,
    ) -> (std::net::SocketAddr, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hits = Arc::new(Mutex::new(Vec::new()));
        let routes = Arc::new(routes);
        let hits_clone = Arc::clone(&hits);

        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let routes = Arc::clone(&routes);
                let hits = Arc::clone(&hits_clone);
                tokio::spawn(async move {
                    let mut req_buf = Vec::with_capacity(2048);
                    let mut tmp = [0u8; 512];
                    loop {
                        req_buf.clear();
                        let header_end = loop {
                            if let Some(pos) = req_buf.windows(4).position(|w| w == b"\r\n\r\n") {
                                break pos + 4;
                            }
                            match socket.read(&mut tmp).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => req_buf.extend_from_slice(&tmp[..n]),
                            }
                        };
                        let req_str = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                        let path = req_str
                            .lines()
                            .next()
                            .and_then(|l| l.split_whitespace().nth(1))
                            .unwrap_or("/")
                            .to_string();

                        hits.lock().unwrap().push(path.clone());
                        if !delay.is_zero() {
                            tokio::time::sleep(delay).await;
                        }

                        if let Some(body) = routes.get(&path) {
                            let hdr = format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                                body.len()
                            );
                            if socket.write_all(hdr.as_bytes()).await.is_err()
                                || socket.write_all(body).await.is_err()
                                || socket.flush().await.is_err()
                            {
                                return;
                            }
                        } else {
                            let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                            if socket.write_all(resp.as_bytes()).await.is_err()
                                || socket.flush().await.is_err()
                            {
                                return;
                            }
                        }
                    }
                });
            }
        });

        (addr, hits)
    }

    #[test]
    fn test_parse_iso8601_duration_ms() {
        assert_eq!(parse_iso8601_duration_ms("PT3M45.5S"), Some(225_500));
        assert_eq!(parse_iso8601_duration_ms("PT1H2M3S"), Some(3_723_000));
        assert_eq!(parse_iso8601_duration_ms("P0DT0H0M30.25S"), Some(30_250));
        assert_eq!(parse_iso8601_duration_ms("invalid"), None);
    }

    #[test]
    fn test_mpd_rejects_content_protection_drm() {
        let drm_mpd = r#"<MPD><Period><AdaptationSet contentType="audio"><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation id="1" bandwidth="128000"><BaseURL>https://cdn.example.com/a.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"#;
        let err = parse_mpd_xml(drm_mpd, None).unwrap_err();
        assert!(matches!(err, StreamError::DrmRestricted(_)));

        let namespaced = r#"<MPD><Period><AdaptationSet><cenc:ContentProtection value="cenc"/></AdaptationSet></Period></MPD>"#;
        let err2 = parse_mpd_xml(namespaced, None).unwrap_err();
        assert!(matches!(err2, StreamError::DrmRestricted(_)));
    }

    #[test]
    fn test_mpd_parses_segment_timeline_and_picks_highest_bandwidth_audio() {
        let mpd = r#"<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT12S">
  <BaseURL>https://cdn.example.com/tracks/42/</BaseURL>
  <Period>
    <AdaptationSet contentType="video" mimeType="video/mp4">
      <Representation id="vid" bandwidth="5000000">
        <BaseURL>video.mp4</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <SegmentTemplate initialization="init-$RepresentationID$.mp4" media="chunk-$RepresentationID$-$Number%03d$-$Time$.m4s" timescale="1000" startNumber="1">
        <SegmentTimeline>
          <S t="0" d="2000" r="1"/>
          <S d="3000"/>
        </SegmentTimeline>
      </SegmentTemplate>
      <Representation id="low" bandwidth="320000" codecs="mp4a.40.2"/>
      <Representation id="hires" bandwidth="3200000" codecs="flac"/>
    </AdaptationSet>
  </Period>
</MPD>"#;

        let parsed = parse_mpd_xml(mpd, None).unwrap();
        assert_eq!(parsed.bandwidth, 3_200_000);
        assert_eq!(parsed.codecs.as_deref(), Some("flac"));
        assert_eq!(
            parsed.init_url.as_deref(),
            Some("https://cdn.example.com/tracks/42/init-hires.mp4")
        );
        assert_eq!(parsed.segments.len(), 3);
        assert_eq!(
            parsed.segments[0].url,
            "https://cdn.example.com/tracks/42/chunk-hires-001-0.m4s"
        );
        assert_eq!(parsed.segments[0].start_ms, 0);
        assert_eq!(
            parsed.segments[1].url,
            "https://cdn.example.com/tracks/42/chunk-hires-002-2000.m4s"
        );
        assert_eq!(parsed.segments[1].start_ms, 2000);
        assert_eq!(
            parsed.segments[2].url,
            "https://cdn.example.com/tracks/42/chunk-hires-003-4000.m4s"
        );
        assert_eq!(parsed.segments[2].start_ms, 4000);
        assert_eq!(parsed.segments[2].duration_ms, 3000);
    }

    #[test]
    fn test_mpd_parses_fixed_duration_and_segment_list() {
        let fixed_mpd = r#"<MPD mediaPresentationDuration="PT6.5S">
  <Period>
    <AdaptationSet mimeType="audio/mp4">
      <Representation id="1" bandwidth="1411200">
        <SegmentTemplate initialization="https://cdn.example.com/init.mp4" media="https://cdn.example.com/s-$Number$.m4s" timescale="44100" duration="88200" startNumber="10"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
        let parsed = parse_mpd_xml(fixed_mpd, None).unwrap();
        assert_eq!(parsed.segments.len(), 4);
        assert_eq!(parsed.segments[0].number, 10);
        assert_eq!(parsed.segments[0].start_ms, 0);
        assert_eq!(parsed.segments[1].start_ms, 2000);
        assert_eq!(parsed.segments[3].url, "https://cdn.example.com/s-13.m4s");

        let list_mpd = r#"<MPD>
  <Period>
    <AdaptationSet contentType="audio">
      <Representation id="a" bandwidth="960000">
        <SegmentList timescale="1000" duration="1500">
          <Initialization sourceURL="init.mp4"/>
          <SegmentURL media="seg0.m4s"/>
          <SegmentURL media="seg1.m4s"/>
        </SegmentList>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
        let parsed_list =
            parse_mpd_xml(list_mpd, Some("https://cdn.example.com/dash/manifest.mpd")).unwrap();
        assert_eq!(
            parsed_list.init_url.as_deref(),
            Some("https://cdn.example.com/dash/init.mp4")
        );
        assert_eq!(parsed_list.segments.len(), 2);
        assert_eq!(
            parsed_list.segments[1].url,
            "https://cdn.example.com/dash/seg1.m4s"
        );
        assert_eq!(parsed_list.segments[1].start_ms, 1500);
    }

    #[tokio::test]
    async fn test_segmented_proxy_virtual_stream_bounded_prefetch_and_timeline_seek() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let mut routes = HashMap::new();
        routes.insert("/init.mp4".to_string(), b"INIT".to_vec());
        for idx in 0..8 {
            routes.insert(
                format!("/seg-{idx}.m4s"),
                format!("SEG{idx:02}").into_bytes(),
            );
        }

        let mpd_xml = r#"<MPD mediaPresentationDuration="PT16S">
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="flac" bandwidth="2000000">
        <SegmentTemplate initialization="/init.mp4" media="/seg-$Number$.m4s" timescale="1000" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="2000" r="7"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
        routes.insert("/manifest.mpd".to_string(), mpd_xml.as_bytes().to_vec());

        let (addr, hits) = spawn_dash_server(routes, Duration::from_millis(5)).await;
        let manifest_url = format!("http://{addr}/manifest.mpd");
        let proxy = SegmentedStreamProxy::open(manifest_url, &BTreeMap::new(), None, None)
            .await
            .unwrap()
            .with_prefetch_ahead(3);

        // Read init + seg 0 + seg 1 sequentially from offset 0.
        let mut buf = [0u8; 14];
        let mut read_total = 0;
        while read_total < buf.len() {
            let n = proxy
                .read_at(read_total as u64, &mut buf[read_total..])
                .await
                .unwrap();
            assert!(n > 0);
            read_total += n;
        }
        assert_eq!(&buf, b"INITSEG00SEG01");

        // Allow bounded prefetch ahead (SEG02, SEG03, SEG04) to finish without fetching SEG05..07.
        tokio::time::sleep(Duration::from_millis(60)).await;
        {
            let recorded = hits.lock().unwrap();
            assert!(recorded.contains(&"/seg-2.m4s".to_string()));
            assert!(recorded.contains(&"/seg-4.m4s".to_string()));
            assert!(
                !recorded.contains(&"/seg-5.m4s".to_string()),
                "prefetch must remain bounded to PREFETCH_AHEAD=3, saw {recorded:?}"
            );
        }

        // Seek by timeline to 10_500ms -> segment 5 (start_ms = 10_000ms), virtual_offset = 0.
        let target = proxy.seek_to_time_ms(10_500).await.unwrap().unwrap();
        assert_eq!(
            target,
            SegmentedSeekTarget {
                virtual_offset: 0,
                segment_index: 5,
                segment_start_ms: 10_000,
            }
        );

        let mut after_seek = [0u8; 9];
        let n = proxy.read_at(0, &mut after_seek).await.unwrap();
        assert_eq!(n, 9);
        assert_eq!(&after_seek, b"INITSEG05");

        // Read until EOF of the remaining window [init, seg5, seg6, seg7].
        let mut rest = [0u8; 16];
        let n_rest = proxy.read_at(9, &mut rest).await.unwrap();
        assert_eq!(n_rest, 10);
        assert_eq!(&rest[..n_rest], b"SEG06SEG07");
        assert_eq!(proxy.read_at(19, &mut rest).await.unwrap(), 0);
    }

    #[tokio::test]
    async fn test_segmented_proxy_seek_cancels_previous_prefetch_and_cancel_clears_downloads() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let mut routes = HashMap::new();
        routes.insert("/init.mp4".to_string(), b"INIT".to_vec());
        for idx in 0..6 {
            routes.insert(
                format!("/seg-{idx}.m4s"),
                format!("SEG{idx:02}").into_bytes(),
            );
        }
        let mpd_xml = r#"<MPD>
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="1" bandwidth="1000000">
        <SegmentTemplate initialization="/init.mp4" media="/seg-$Number$.m4s" timescale="1000" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="2000" r="5"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
        let (addr, _hits) = spawn_dash_server(routes, Duration::from_secs(2)).await;
        let base_url = format!("http://{addr}/manifest.mpd");
        let proxy = Arc::new(
            SegmentedStreamProxy::from_mpd_xml(
                mpd_xml,
                Some(&base_url),
                &BTreeMap::new(),
                None,
                None,
            )
            .unwrap(),
        );

        let p2 = Arc::clone(&proxy);
        let slow_read = tokio::spawn(async move {
            let mut buf = [0u8; 4];
            p2.read_at(0, &mut buf).await
        });

        tokio::time::sleep(Duration::from_millis(40)).await;
        assert_eq!(proxy.active_downloads(), 1);

        // Seeking cancels the active window's child token immediately.
        let target = proxy.seek_to_time_ms(6_000).await.unwrap().unwrap();
        assert_eq!(target.segment_index, 3);
        assert_eq!(slow_read.await.unwrap().unwrap_err(), StreamError::Cancelled);
        assert_eq!(proxy.active_downloads(), 0);

        proxy.cancel();
        assert_eq!(proxy.active_downloads(), 0);
    }

    #[tokio::test]
    async fn test_segmented_proxy_backward_seek_hits_ram_lru_and_byte_cap_evicts_oldest() {
        let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
        let mut routes = HashMap::new();
        routes.insert("/init.mp4".to_string(), b"INIT".to_vec());
        // Each segment is 100 bytes so we can test exact byte-capped LRU eviction cleanly.
        for idx in 0..6 {
            let mut seg = vec![b'0' + (idx as u8); 100];
            seg[0] = b'S';
            seg[1] = b'0' + (idx as u8);
            routes.insert(format!("/seg-{idx}.m4s"), seg);
        }

        let mpd_xml = r#"<MPD mediaPresentationDuration="PT12S">
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="flac" bandwidth="2000000">
        <SegmentTemplate initialization="/init.mp4" media="/seg-$Number$.m4s" timescale="1000" startNumber="0">
          <SegmentTimeline>
            <S t="0" d="2000" r="5"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
        routes.insert("/manifest.mpd".to_string(), mpd_xml.as_bytes().to_vec());

        let (addr, hits) = spawn_dash_server(routes, Duration::ZERO).await;
        let manifest_url = format!("http://{addr}/manifest.mpd");
        let proxy = SegmentedStreamProxy::open(manifest_url, &BTreeMap::new(), None, None)
            .await
            .unwrap()
            .with_prefetch_ahead(0)
            .with_max_cache_bytes(300); // holds at most 3 * 100B segments (+ pinned init)

        // Read init + seg 0 + seg 1
        let mut buf = vec![0u8; 204];
        let mut got = 0;
        while got < buf.len() {
            let n = proxy.read_at(got as u64, &mut buf[got..]).await.unwrap();
            assert!(n > 0);
            got += n;
        }
        assert_eq!(&buf[0..4], b"INIT");
        assert_eq!(&buf[4..6], b"S0");
        assert_eq!(&buf[104..106], b"S1");

        // Forward seek to seg 4 (8_000 ms) and read init + seg 4
        let target = proxy.seek_to_time_ms(8_000).await.unwrap().unwrap();
        assert_eq!(target.segment_index, 4);
        let mut fwd = vec![0u8; 104];
        assert_eq!(proxy.read_at(0, &mut fwd).await.unwrap(), 104);
        assert_eq!(&fwd[0..4], b"INIT");
        assert_eq!(&fwd[4..6], b"S4");

        let hits_before_back = hits.lock().unwrap().len();
        assert_eq!(proxy.cached_segment_bytes(), 300); // seg 0, 1, 4 all resident!

        // Backward seek to seg 0 -> must serve init + seg 0 + seg 1 with ZERO new HTTP downloads!
        let back_target = proxy.seek_to_time_ms(500).await.unwrap().unwrap();
        assert_eq!(back_target.segment_index, 0);
        let mut back_buf = vec![0u8; 204];
        let mut got_back = 0;
        while got_back < back_buf.len() {
            let n = proxy
                .read_at(got_back as u64, &mut back_buf[got_back..])
                .await
                .unwrap();
            assert!(n > 0);
            got_back += n;
        }
        assert_eq!(&back_buf[..], &buf[..]);
        assert_eq!(
            hits.lock().unwrap().len(),
            hits_before_back,
            "backward seek inside DASH LRU cache must issue zero HTTP requests"
        );

        // Now seg 4 is LRU (seg 0 and seg 1 were just touched). Seeking to seg 5 evicts seg 4,
        // keeping cached bytes <= 300 while init_bytes stays pinned (never re-fetched).
        proxy.seek_to_time_ms(10_000).await.unwrap().unwrap();
        let mut s5 = vec![0u8; 104];
        assert_eq!(proxy.read_at(0, &mut s5).await.unwrap(), 104);
        assert_eq!(&s5[0..4], b"INIT");
        assert_eq!(&s5[4..6], b"S5");
        assert!(proxy.cached_segment_bytes() <= 300);
        let init_fetches = hits
            .lock()
            .unwrap()
            .iter()
            .filter(|p| p.as_str() == "/init.mp4")
            .count();
        assert_eq!(init_fetches, 1, "init segment must remain pinned across LRU evictions");
    }
}
