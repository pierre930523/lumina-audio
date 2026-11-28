use std::future::Future;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_types::{
    AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, StreamKey, StreamSourceSpec, TrackSource,
};
use serde::Deserialize;
use tokio_util::sync::CancellationToken;

use crate::deezer::DeezerProvider;
use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpResponse, endpoint_url};
use crate::media_provider::{MediaPlaylist, MediaProvider, ProviderHealth};
use crate::resilience::{
    RetryPolicy, SingleFlightRefreshGate, execute_with_retry, parse_retry_after,
    send_http_with_retry,
};
use crate::traits::{MusicProvider, StreamResolver};

/// Resilient [`MediaProvider`] adapter wrapping [`DeezerProvider`].
pub struct DeezerMediaProvider {
    inner: Arc<DeezerProvider>,
    retry_policy: RetryPolicy,
    refresh_gate: SingleFlightRefreshGate,
}

impl DeezerMediaProvider {
    pub fn new(inner: Arc<DeezerProvider>) -> Self {
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

    pub fn inner(&self) -> &Arc<DeezerProvider> {
        &self.inner
    }

    async fn refresh_once_inner(
        &self,
        observed_epoch: u64,
        cancel: &CancellationToken,
    ) -> Result<(), ProviderError> {
        self.refresh_gate
            .refresh_once(observed_epoch, cancel, || async {
                let arl = self
                    .inner
                    .active_arl_cookie()
                    .await
                    .map_err(normalize_auth_error)?;
                self.inner.clear_session().await;
                self.inner
                    .login_with_arl(&arl)
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
                        res = fut => res.map_err(normalize_deezer_error),
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
impl MediaProvider for DeezerMediaProvider {
    fn provider_id(&self) -> &'static str {
        "deezer"
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
            let url = endpoint_url(&cfg.api_base_url, &format!("playlist/{playlist_id}"));
            let mut req = HttpRequest::get(url);
            if let Ok(arl) = self.inner.active_arl_cookie().await {
                req = req.with_header("Cookie", format!("arl={arl}"));
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

            map_deezer_http_status(&resp, "playlist/get")?;
            break resp;
        };

        let dto: DeezerPlaylistDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Deezer playlist response: {e}"))
        })?;

        let raw_tracks = dto.tracks.map(|t| t.data).unwrap_or_default();
        let mut tracks = Vec::with_capacity(raw_tracks.len());
        let format = AudioFormat::pcm(AudioCodec::Flac, 44_100, 16, 2)?;
        for (idx, item) in raw_tracks.into_iter().enumerate() {
            let version_id = item
                .album
                .map(|a| a.id)
                .unwrap_or_else(|| format!("deezer-playlist-{playlist_id}"));
            let mut track = TrackSource::new(
                version_id,
                ProviderKind::Deezer,
                item.id,
                item.title,
                item.disk_number.unwrap_or(1).max(1),
                item.track_position.unwrap_or((idx + 1) as u16).max(1),
                item.duration.unwrap_or(1).saturating_mul(1000).max(1),
                format.clone(),
            )?;
            if let Some(isrc) = item.isrc.filter(|s| !s.trim().is_empty()) {
                if let Ok(with_isrc) = track.clone().with_isrc(isrc) {
                    track = with_isrc;
                }
            }
            if let Some(gain) = item.gain.filter(|g| g.is_finite()) {
                track = track.with_replay_gain(Some(gain), None, None, None);
            }
            tracks.push(track);
        }

        let artwork_url = dto
            .picture_xl
            .or(dto.picture_big)
            .or(dto.picture_medium)
            .filter(|s| !s.trim().is_empty());

        Ok(MediaPlaylist {
            id: dto.id,
            provider_id: self.provider_id().to_string(),
            title: dto.title,
            description: dto.description.filter(|s| !s.trim().is_empty()),
            owner: dto
                .creator
                .and_then(|c| c.name)
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
                Some("Deezer ARL session available".to_string())
            } else {
                Some("Deezer ARL authentication required".to_string())
            },
        })
    }

    async fn refresh_credentials(&self) -> Result<(), ProviderError> {
        let cancel = CancellationToken::new();
        let epoch = self.refresh_gate.current_epoch();
        self.refresh_once_inner(epoch, &cancel).await
    }
}

fn normalize_deezer_error(err: ProviderError) -> ProviderError {
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

fn map_deezer_http_status(resp: &HttpResponse, context: &str) -> Result<(), ProviderError> {
    let lower = resp.body.to_ascii_lowercase();
    let is_geo_blocked = lower.contains("region")
        || lower.contains("country")
        || lower.contains("territory")
        || lower.contains("geo-block")
        || lower.contains("geoblock");

    match resp.status {
        200..=299 => Ok(()),
        401 => Err(ProviderError::AuthExpired(format!(
            "Deezer {context} unauthorized (HTTP 401)"
        ))),
        429 => Err(ProviderError::rate_limited(
            format!("Deezer {context} rate limited (HTTP 429)"),
            resp.header("retry-after").and_then(parse_retry_after),
        )),
        451 => Err(ProviderError::RegionBlocked(format!(
            "Deezer {context} region blocked (HTTP 451): {}",
            resp.body
        ))),
        403 if is_geo_blocked => Err(ProviderError::RegionBlocked(format!(
            "Deezer {context} geo-blocked (HTTP 403): {}",
            resp.body
        ))),
        404 => Err(ProviderError::AlbumNotFound(format!(
            "Deezer {context} not found (HTTP 404)"
        ))),
        _ => Err(ProviderError::Network(format!(
            "Deezer {context} failed (HTTP {}): {}",
            resp.status, resp.body
        ))),
    }
}

fn de_id_str<'de, D>(deserializer: D) -> Result<String, D::Error>
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
struct DeezerPlaylistDto {
    #[serde(deserialize_with = "de_id_str")]
    id: String,
    title: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    creator: Option<DeezerPlaylistCreatorDto>,
    #[serde(default)]
    picture_xl: Option<String>,
    #[serde(default)]
    picture_big: Option<String>,
    #[serde(default)]
    picture_medium: Option<String>,
    #[serde(default)]
    tracks: Option<DeezerPlaylistTracksDto>,
}

#[derive(Debug, Deserialize)]
struct DeezerPlaylistCreatorDto {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DeezerPlaylistTracksDto {
    #[serde(default)]
    data: Vec<DeezerPlaylistTrackDto>,
}

#[derive(Debug, Deserialize)]
struct DeezerPlaylistTrackDto {
    #[serde(deserialize_with = "de_id_str")]
    id: String,
    title: String,
    #[serde(default)]
    isrc: Option<String>,
    #[serde(default)]
    duration: Option<u64>,
    #[serde(default)]
    track_position: Option<u16>,
    #[serde(default)]
    disk_number: Option<u16>,
    #[serde(default)]
    gain: Option<f64>,
    #[serde(default)]
    album: Option<DeezerPlaylistAlbumRef>,
}

#[derive(Debug, Deserialize)]
struct DeezerPlaylistAlbumRef {
    #[serde(deserialize_with = "de_id_str")]
    id: String,
}
