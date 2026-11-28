use std::sync::{Arc, RwLock};
use std::time::Duration;

use bytes::Bytes;
use core_types::{ManifestFormat, StreamKey, StreamSourceSpec};
use reqwest::Method;
use reqwest::header::HeaderMap;
use tokio::sync::{Mutex as AsyncMutex, watch};
use tokio_util::sync::CancellationToken;

use super::super::{
    HttpRequestSpec, StreamError, StreamHttpConfig, StreamHttpTransport, StreamRefreshHandler,
    StreamRefreshOutcome, StreamRefreshRequest, build_sanitized_headers, execute_with_epoch_watch,
};
use super::manifest::{ParsedDashManifest, manifests_compatible};
use super::parser::parse_mpd_xml;
use super::scheduler::SegmentSlot;

#[derive(Clone)]
pub(super) struct SegmentRefreshContext {
    pub(super) key: Option<StreamKey>,
    pub(super) manifest_slot: Arc<RwLock<ParsedDashManifest>>,
    pub(super) manifest_source_url: Arc<RwLock<Option<String>>>,
    pub(super) headers_slot: Arc<RwLock<HeaderMap>>,
    pub(super) mime_type: Option<String>,
    pub(super) refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    pub(super) refresh_lock: Arc<AsyncMutex<()>>,
    pub(super) backoffs: [Duration; 2],
}

impl SegmentRefreshContext {
    pub(super) fn provider_id(&self) -> String {
        self.key
            .as_ref()
            .map(|k| k.provider_id.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }

    pub(super) fn current_headers(&self) -> HeaderMap {
        self.headers_slot
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    pub(super) fn slot_url(&self, slot: SegmentSlot) -> Option<String> {
        let guard = self.manifest_slot.read().ok()?;
        match slot {
            SegmentSlot::Init => guard.init_url.clone(),
            SegmentSlot::Media(idx) => guard.segments.get(idx).map(|s| s.url.clone()),
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn resolve_mpd_xml_for_spec(
    manifest_url_or_xml: &str,
    headers: &HeaderMap,
    provider_id: &str,
    transport: &dyn StreamHttpTransport,
    config: &StreamHttpConfig,
    cancel: &CancellationToken,
    epoch_rx: &mut watch::Receiver<u64>,
) -> Result<(String, Option<String>), StreamError> {
    let trimmed = manifest_url_or_xml
        .trim_start_matches('\u{feff}')
        .trim_start();
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
pub(super) async fn attempt_segment_refresh_after_403(
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
        Err(
            err @ (StreamError::Cancelled
            | StreamError::AuthRequired { .. }
            | StreamError::FormatChanged(_)),
        ) => Err(err),
        Err(err) => {
            if *refresh_attempts >= 2 {
                Err(err)
            } else {
                Ok(false)
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn fetch_segment_bytes(
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
        let resp = execute_with_epoch_watch(transport, req, true, config, cancel, epoch_rx).await?;

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
