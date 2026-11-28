use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use core_types::{ManifestFormat, StreamKey, StreamSourceSpec};
use reqwest::header::HeaderMap;
use reqwest::{Client, Method};
use tokio::sync::{Mutex as AsyncMutex, watch};
use tokio_util::sync::CancellationToken;

use super::super::l2_cache::DashL2Package;
use super::super::{
    DEFAULT_REFRESH_403_BACKOFFS, HttpRequestSpec, InFlightDownloadGuard, ReqwestStreamTransport,
    StreamError, StreamHttpConfig, StreamHttpTransport, StreamRefreshHandler, StreamRefreshOutcome,
    StreamRefreshRequest, build_sanitized_headers, execute_with_epoch_watch,
    subscribe_network_epoch,
};
use super::manifest::{
    ParsedDashManifest, infer_dash_extension, validate_dash_package_compatibility,
};
use super::parser::parse_mpd_xml;
use super::scheduler::{SegmentLruCache, WindowState};
use super::{DEFAULT_MAX_CACHED_SEGMENTS, DEFAULT_MAX_SEGMENT_CACHE_BYTES, DEFAULT_PREFETCH_AHEAD};

/// Virtual byte-stream proxy for unencrypted MPEG-DASH `.mpd` manifests (`init` + `.m4s`
/// segments), supporting bounded ahead-of-play prefetching and timeline seeking.
pub struct SegmentedStreamProxy {
    pub(super) manifest: Arc<RwLock<ParsedDashManifest>>,
    pub(super) manifest_source_url: Arc<RwLock<Option<String>>>,
    pub(super) headers: Arc<RwLock<HeaderMap>>,
    pub(super) key: Option<StreamKey>,
    pub(super) refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    pub(super) refresh_lock: Arc<AsyncMutex<()>>,
    pub(super) refresh_backoffs: [Duration; 2],
    pub(super) epoch_rx: watch::Receiver<u64>,
    pub(super) needs_network_epoch_reset: bool,
    pub(super) hint_extension: Option<String>,
    pub(super) mime_type: Option<String>,
    pub(super) prefetch_ahead: usize,
    pub(super) cancel: CancellationToken,
    pub(super) transport: Arc<dyn StreamHttpTransport>,
    pub(super) config: StreamHttpConfig,
    pub(super) state: Arc<Mutex<WindowState>>,
    pub(super) active_downloads: Arc<AtomicUsize>,
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
                    Err(
                        err @ (StreamError::Cancelled
                        | StreamError::AuthRequired { .. }
                        | StreamError::FormatChanged(_)),
                    ) => {
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
    pub(super) fn from_parsed_parts(
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
}
