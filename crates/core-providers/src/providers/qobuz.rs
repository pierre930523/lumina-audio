use std::future::Future;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_types::{
    AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, StreamKey, StreamSourceSpec, TrackSource,
};
use serde::Deserialize;
use tokio_util::sync::CancellationToken;

use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpResponse, endpoint_url};
use crate::media_provider::{MediaPlaylist, MediaProvider, ProviderHealth};
use crate::qobuz::{QobuzProvider, QobuzTrackItem, normalize_sample_rate};
use crate::resilience::{
    RetryPolicy, SingleFlightRefreshGate, execute_with_retry, parse_retry_after,
    send_http_with_retry,
};
use crate::traits::{MusicProvider, StreamResolver};

/// Resilient [`MediaProvider`] adapter wrapping [`QobuzProvider`].
pub struct QobuzMediaProvider {
    inner: Arc<QobuzProvider>,
    retry_policy: RetryPolicy,
    refresh_gate: SingleFlightRefreshGate,
}

impl QobuzMediaProvider {
    pub fn new(inner: Arc<QobuzProvider>) -> Self {
        Self {
            inner,
            retry_policy: RetryPolicy::default(),
            refresh_gate: SingleFlightRefreshGate::new(),
        }
    }

    pub fn with_retry_policy(mut self, policy: RetryPolicy) -> Self {
        self.retry_policy = policy;
        self
    }

    pub fn inner(&self) -> &Arc<QobuzProvider> {
        &self.inner
    }

    async fn refresh_once_inner(
        &self,
        observed_epoch: u64,
        cancel: &CancellationToken,
    ) -> Result<(), ProviderError> {
        self.refresh_gate
            .refresh_once(observed_epoch, cancel, || async {
                self.inner.clear_session().await;
                self.inner
                    .authenticate()
                    .await
                    .map(|_| ())
                    .map_err(normalize_auth_error)
            })
            .await
            .map(|_| ())
    }

    async fn execute_resilient<T, F, Fut>(
        &self,
        cancel: &CancellationToken,
        mut op: F,
    ) -> Result<T, ProviderError>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T, ProviderError>>,
    {
        let mut retried_after_refresh = false;
        loop {
            if cancel.is_cancelled() {
                return Err(ProviderError::Cancelled);
            }
            let observed_epoch = self.refresh_gate.current_epoch();
            let attempt_res = execute_with_retry(&self.retry_policy, cancel, |_| {
                let fut = op();
                async move {
                    tokio::select! {
                        biased;
                        _ = cancel.cancelled() => Err(ProviderError::Cancelled),
                        res = fut => res.map_err(normalize_qobuz_error),
                    }
                }
            })
            .await;

            match attempt_res {
                Ok(v) => return Ok(v),
                Err(err) if err.is_auth_expired() && !retried_after_refresh => {
                    retried_after_refresh = true;
                    self.refresh_once_inner(observed_epoch, cancel).await?;
                }
                Err(err) => return Err(err),
            }
        }
    }
}

#[async_trait]
impl MediaProvider for QobuzMediaProvider {
    fn provider_id(&self) -> &'static str {
        "qobuz"
    }

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let cancel = CancellationToken::new();
        self.execute_resilient(&cancel, || self.inner.search(query, limit))
            .await
    }

    async fn get_track(&self, track_id: &str) -> Result<TrackSource, ProviderError> {
        let cancel = CancellationToken::new();
        self.execute_resilient(&cancel, || self.inner.get_track(track_id))
            .await
    }

    async fn get_playlist(&self, playlist_id: &str) -> Result<MediaPlaylist, ProviderError> {
        let cancel = CancellationToken::new();
        let mut retried_after_refresh = false;

        let resp = loop {
            let observed_epoch = self.refresh_gate.current_epoch();
            let cfg = self.inner.config_snapshot().await;
            let token = self.inner.session_token().await;
            let url = endpoint_url(&cfg.base_url, "playlist/get");

            let mut req = HttpRequest::get(url)
                .with_header("X-App-Id", cfg.app_id())
                .with_query("playlist_id", playlist_id)
                .with_query("extra", "tracks");
            if let Some(tok) = token {
                req = req.with_header("X-User-Auth-Token", tok);
            }

            let resp = send_http_with_retry(
                self.inner.transport().as_ref(),
                &req,
                &self.retry_policy,
                &cancel,
            )
            .await?;

            if resp.status == 401 && !retried_after_refresh {
                retried_after_refresh = true;
                self.refresh_once_inner(observed_epoch, &cancel).await?;
                continue;
            }

            map_qobuz_http_status(&resp, "playlist/get")?;
            break resp;
        };

        let dto: QobuzPlaylistDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Qobuz playlist/get: {e}"))
        })?;

        let raw_tracks = dto.tracks.and_then(|t| t.items).unwrap_or_default();
        let mut tracks = Vec::with_capacity(raw_tracks.len());
        for (idx, item) in raw_tracks.into_iter().enumerate() {
            let sr = item
                .maximum_sampling_rate
                .as_ref()
                .map(normalize_sample_rate)
                .unwrap_or(44_100);
            let bd = item.maximum_bit_depth.unwrap_or(16);
            let format = AudioFormat::pcm(AudioCodec::Flac, sr, bd, 2)?;
            let version_id = item
                .album
                .as_ref()
                .map(|a| a.id.clone())
                .unwrap_or_else(|| format!("qobuz-playlist-{playlist_id}"));
            let mut track = TrackSource::new(
                version_id,
                ProviderKind::Qobuz,
                item.id,
                item.title,
                item.media_number.unwrap_or(1).max(1),
                item.track_number.unwrap_or((idx + 1) as u16).max(1),
                item.duration.unwrap_or(1).saturating_mul(1000).max(1),
                format,
            )?;
            if let Some(isrc) = item.isrc.filter(|s| !s.trim().is_empty()) {
                if let Ok(with_isrc) = track.clone().with_isrc(isrc) {
                    track = with_isrc;
                }
            }
            tracks.push(track);
        }

        let artwork_url = dto
            .images300
            .into_iter()
            .chain(dto.image_rectangle)
            .find(|u| !u.trim().is_empty());

        Ok(MediaPlaylist {
            id: dto.id,
            provider_id: self.provider_id().to_string(),
            title: dto.name,
            description: dto.description.filter(|s| !s.trim().is_empty()),
            owner: dto
                .owner
                .and_then(|o| o.name)
                .filter(|s| !s.trim().is_empty()),
            artwork_url,
            tracks,
        })
    }

    async fn resolve_stream(
        &self,
        track_id: &str,
        quality: &str,
        cancel_token: CancellationToken,
    ) -> Result<StreamSourceSpec, ProviderError> {
        let key = StreamKey::new(self.provider_id(), track_id, quality);
        self.execute_resilient(&cancel_token, || self.inner.resolve_source(&key))
            .await
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        let start = Instant::now();
        let authenticated = self.inner.is_authenticated().await;
        Ok(ProviderHealth {
            provider_id: self.provider_id().to_string(),
            healthy: authenticated,
            authenticated,
            latency_ms: start.elapsed().as_millis() as u64,
            detail: if authenticated {
                Some("Qobuz session/token available".to_string())
            } else {
                Some("Qobuz authentication required".to_string())
            },
        })
    }

    async fn refresh_credentials(&self) -> Result<(), ProviderError> {
        let cancel = CancellationToken::new();
        let epoch = self.refresh_gate.current_epoch();
        self.refresh_once_inner(epoch, &cancel).await
    }
}

fn normalize_qobuz_error(err: ProviderError) -> ProviderError {
    match err {
        ProviderError::AuthenticationFailed(msg) => ProviderError::AuthExpired(msg),
        ProviderError::RegionRestricted(msg) => ProviderError::RegionBlocked(msg),
        other => other,
    }
}

fn normalize_auth_error(err: ProviderError) -> ProviderError {
    match err {
        ProviderError::AuthenticationFailed(msg) | ProviderError::Unauthenticated(msg) => {
            ProviderError::AuthExpired(msg)
        }
        other => other,
    }
}

fn map_qobuz_http_status(resp: &HttpResponse, context: &str) -> Result<(), ProviderError> {
    let lower = resp.body.to_ascii_lowercase();
    let is_geo_blocked = lower.contains("region")
        || lower.contains("country")
        || lower.contains("territory")
        || lower.contains("geo-block")
        || lower.contains("geoblock");

    match resp.status {
        200..=299 => Ok(()),
        401 => Err(ProviderError::AuthExpired(format!(
            "Qobuz {context} unauthorized (HTTP 401)"
        ))),
        429 => Err(ProviderError::rate_limited(
            format!("Qobuz {context} rate limited (HTTP 429)"),
            resp.header("retry-after").and_then(parse_retry_after),
        )),
        451 => Err(ProviderError::RegionBlocked(format!(
            "Qobuz {context} region blocked (HTTP 451): {}",
            resp.body
        ))),
        403 if is_geo_blocked => Err(ProviderError::RegionBlocked(format!(
            "Qobuz {context} geo-blocked (HTTP 403): {}",
            resp.body
        ))),
        404 => Err(ProviderError::AlbumNotFound(format!(
            "Qobuz {context} not found (HTTP 404)"
        ))),
        _ => Err(ProviderError::Network(format!(
            "Qobuz {context} failed (HTTP {}): {}",
            resp.status, resp.body
        ))),
    }
}

fn de_id_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let val = serde_json::Value::deserialize(deserializer)?;
    match val {
        serde_json::Value::String(s) => Ok(s),
        serde_json::Value::Number(n) => Ok(n.to_string()),
        other => Ok(other.to_string()),
    }
}

#[derive(Debug, Deserialize)]
struct QobuzPlaylistDto {
    #[serde(deserialize_with = "de_id_string")]
    id: String,
    name: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    owner: Option<QobuzPlaylistOwnerDto>,
    #[serde(default)]
    images300: Vec<String>,
    #[serde(default)]
    image_rectangle: Vec<String>,
    #[serde(default)]
    tracks: Option<QobuzPlaylistTracksDto>,
}

#[derive(Debug, Deserialize)]
struct QobuzPlaylistOwnerDto {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct QobuzPlaylistTracksDto {
    #[serde(default)]
    items: Option<Vec<QobuzTrackItem>>,
}
