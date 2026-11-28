use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use core_types::{NormalizedLoudness, StreamKey, StreamSourceSpec};
use reqwest::header::HeaderMap;
use tokio::sync::Mutex as AsyncMutex;
use tokio_util::sync::CancellationToken;

use super::super::{
    StreamError, StreamRefreshHandler, StreamRefreshOutcome, StreamRefreshRequest,
    build_sanitized_headers, header_map_to_btree, normalize_mime_base, same_trusted_redirect_scope,
    strip_sensitive_cross_origin_headers,
};

#[derive(Clone)]
pub(super) struct ChunkRefreshContext {
    pub(super) key: Option<StreamKey>,
    pub(super) expected_kind: String,
    pub(super) bitrate_bps: Option<u64>,
    pub(super) hint_extension: Option<String>,
    pub(super) mime_type: Option<String>,
    pub(super) loudness: Option<NormalizedLoudness>,
    pub(super) album_loudness: Option<NormalizedLoudness>,
    pub(super) content_length: Arc<Mutex<Option<u64>>>,
    pub(super) url_slot: Arc<RwLock<String>>,
    pub(super) headers_slot: Arc<RwLock<HeaderMap>>,
    pub(super) refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    pub(super) refresh_lock: Arc<AsyncMutex<()>>,
    pub(super) backoffs: [Duration; 2],
    pub(super) has_delivered_bytes: Arc<AtomicBool>,
}

impl ChunkRefreshContext {
    pub(super) fn provider_id(&self) -> String {
        self.key
            .as_ref()
            .map(|k| k.provider_id.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }

    pub(super) fn track_id(&self) -> String {
        self.key
            .as_ref()
            .map(|k| k.track_id.clone())
            .unwrap_or_else(|| "unknown".to_string())
    }

    pub(super) fn current_url(&self) -> String {
        self.url_slot.read().map(|g| g.clone()).unwrap_or_default()
    }

    pub(super) fn current_headers(&self) -> HeaderMap {
        self.headers_slot
            .read()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    pub(super) fn known_content_length(&self) -> Option<u64> {
        self.content_length.lock().ok().and_then(|g| *g)
    }

    pub(super) fn update_redirected_url(&self, from_url: &str, final_url: String) {
        if final_url == from_url {
            return;
        }
        let strip_auth = match (
            reqwest::Url::parse(from_url),
            reqwest::Url::parse(&final_url),
        ) {
            (Ok(a), Ok(b)) => !same_trusted_redirect_scope(&a, &b),
            _ => false,
        };
        if let Ok(mut g) = self.url_slot.write()
            && *g == from_url
        {
            *g = final_url;
            if strip_auth && let Ok(mut hdrs) = self.headers_slot.write() {
                strip_sensitive_cross_origin_headers(&mut hdrs);
            }
        }
    }

    pub(super) fn synthesize_format_changed_spec(&self, actual_len: u64) -> StreamSourceSpec {
        let key = self
            .key
            .clone()
            .unwrap_or_else(|| StreamKey::new("unknown", "unknown", "default"));
        StreamSourceSpec::DirectRange {
            key,
            url: self.current_url(),
            headers: header_map_to_btree(&self.current_headers()),
            content_length: Some(actual_len),
            bitrate_bps: self.bitrate_bps,
            mime_type: self.mime_type.clone(),
            hint_extension: self.hint_extension.clone(),
            expire_at: None,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness: self.loudness,
            album_loudness: self.album_loudness,
        }
    }

    pub(super) fn check_and_apply_refreshed_spec(
        &self,
        new_spec: StreamSourceSpec,
    ) -> Result<StreamSourceSpec, StreamError> {
        let (new_kind, new_url, new_headers, new_len, new_mime, new_ext) = match &new_spec {
            StreamSourceSpec::DirectRange {
                url,
                headers,
                content_length,
                mime_type,
                hint_extension,
                ..
            } => (
                "direct_range",
                url.clone(),
                headers.clone(),
                *content_length,
                mime_type.clone(),
                hint_extension.clone(),
            ),
            StreamSourceSpec::EncryptedRange {
                url,
                headers,
                content_length,
                mime_type,
                hint_extension,
                ..
            } => (
                "encrypted_range",
                url.clone(),
                headers.clone(),
                *content_length,
                mime_type.clone(),
                hint_extension.clone(),
            ),
            _ => return Err(StreamError::FormatChanged(Box::new(new_spec))),
        };

        if !self.expected_kind.is_empty() && new_kind != self.expected_kind {
            return Err(StreamError::FormatChanged(Box::new(new_spec)));
        }
        if let (Some(cur_mime), Some(next_mime)) = (&self.mime_type, &new_mime)
            && normalize_mime_base(cur_mime) != normalize_mime_base(next_mime)
        {
            return Err(StreamError::FormatChanged(Box::new(new_spec)));
        }
        if let (Some(cur_ext), Some(next_ext)) = (&self.hint_extension, &new_ext) {
            let norm_next = next_ext.trim().trim_start_matches('.').to_ascii_lowercase();
            if !norm_next.is_empty() && cur_ext != &norm_next {
                return Err(StreamError::FormatChanged(Box::new(new_spec)));
            }
        }
        if let (Some(expected_len), Some(actual_len)) = (self.known_content_length(), new_len)
            && expected_len != actual_len
        {
            return Err(StreamError::FormatChanged(Box::new(new_spec)));
        }

        let sanitized_headers = build_sanitized_headers(&new_headers)?;
        if let Ok(mut url_guard) = self.url_slot.write() {
            *url_guard = new_url;
        }
        if let Ok(mut hdr_guard) = self.headers_slot.write() {
            *hdr_guard = sanitized_headers;
        }
        Ok(new_spec)
    }
}

pub(super) fn spec_with_content_length(
    mut spec: StreamSourceSpec,
    actual_len: u64,
) -> StreamSourceSpec {
    match &mut spec {
        StreamSourceSpec::DirectRange { content_length, .. }
        | StreamSourceSpec::EncryptedRange { content_length, .. } => {
            *content_length = Some(actual_len);
        }
        _ => {}
    }
    spec
}

pub(super) async fn attempt_chunk_refresh_after_403(
    ctx: &ChunkRefreshContext,
    failed_url: &str,
    status_code: u16,
    is_initial_probe: bool,
    refresh_attempts: &mut u8,
    cancel: &CancellationToken,
) -> Result<Option<StreamSourceSpec>, StreamError> {
    let (Some(handler), Some(key)) = (&ctx.refresh_handler, &ctx.key) else {
        tracing::warn!(
            provider = %ctx.provider_id(),
            track = %ctx.track_id(),
            status = status_code,
            initial_probe = is_initial_probe,
            "ChunkedStreamProxy received HTTP {status_code} with no refresh handler"
        );
        eprintln!(
            "[LuminaStream] http_{status_code} no_refresh_handler provider={} track={} initial_probe={is_initial_probe}",
            ctx.provider_id(),
            ctx.track_id()
        );
        return Err(StreamError::HttpStatus(status_code));
    };

    // Fast CAS before lock acquisition
    if ctx.current_url() != failed_url {
        return Ok(None);
    }

    let _guard = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Err(StreamError::Cancelled),
        g = ctx.refresh_lock.lock() => g,
    };

    // Serialized CAS after acquiring refresh_lock
    if ctx.current_url() != failed_url {
        return Ok(None);
    }

    if *refresh_attempts >= 2 {
        tracing::warn!(
            provider = %key.provider_id,
            track = %key.track_id,
            status = status_code,
            initial_probe = is_initial_probe,
            "ChunkedStreamProxy exhausted HTTP {status_code} refresh retries"
        );
        eprintln!(
            "[LuminaStream] http_{status_code} refresh_exhausted provider={} track={} initial_probe={is_initial_probe}",
            key.provider_id, key.track_id
        );
        return Err(StreamError::HttpStatus(status_code));
    }
    let delay = ctx.backoffs[*refresh_attempts as usize];
    *refresh_attempts += 1;
    let attempt = *refresh_attempts;

    tracing::warn!(
        provider = %key.provider_id,
        track = %key.track_id,
        status = status_code,
        attempt,
        initial_probe = is_initial_probe,
        "ChunkedStreamProxy triggering HTTP {status_code} refresh"
    );
    eprintln!(
        "[LuminaStream] http_{status_code} refresh attempt={attempt} provider={} track={} initial_probe={is_initial_probe}",
        key.provider_id, key.track_id
    );

    if !delay.is_zero() {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return Err(StreamError::Cancelled),
            _ = tokio::time::sleep(delay) => {}
        }
    }

    // Re-check CAS after backoff sleep in case URL changed out-of-band
    if ctx.current_url() != failed_url {
        return Ok(None);
    }

    let req = StreamRefreshRequest {
        provider_id: key.provider_id.clone(),
        track_id: key.track_id.clone(),
        quality_key: key.quality_key.clone(),
        failed_url: failed_url.to_string(),
        status_code,
        attempt,
        expected_content_length: ctx.known_content_length(),
        expected_mime_type: ctx.mime_type.clone(),
        expected_kind: Some(ctx.expected_kind.clone()),
        is_initial_probe,
    };

    match handler.refresh_after_403(req, cancel).await {
        Ok(StreamRefreshOutcome::Refreshed(new_spec)) => {
            let applied = ctx.check_and_apply_refreshed_spec(new_spec)?;
            Ok(Some(applied))
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
                Ok(None)
            }
        }
    }
}
