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
use crate::resilience::{
    RetryPolicy, SingleFlightRefreshGate, execute_with_retry, parse_retry_after,
    send_http_with_retry,
};
use crate::tidal::TidalProvider;
use crate::traits::{MusicProvider, StreamResolver};

/// Resilient [`MediaProvider`] adapter wrapping [`TidalProvider`].
pub struct TidalMediaProvider {
    inner: Arc<TidalProvider>,
    retry_policy: RetryPolicy,
    refresh_gate: SingleFlightRefreshGate,
}

impl TidalMediaProvider {
    pub fn new(inner: Arc<TidalProvider>) -> Self {
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

    pub fn inner(&self) -> &Arc<TidalProvider> {
        &self.inner
    }

    async fn refresh_once_inner(
        &self,
        observed_epoch: u64,
        cancel: &CancellationToken,
    ) -> Result<(), ProviderError> {
        self.refresh_gate
            .refresh_once(observed_epoch, cancel, || async {
                self.inner
                    .refresh_tokens()
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
                        res = fut => res.map_err(normalize_tidal_error),
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

    async fn fetch_json_with_auth(
        &self,
        path: &str,
        extra_query: &[(&str, String)],
        context: &str,
        cancel: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        let mut retried_after_refresh = false;
        loop {
            let observed_epoch = self.refresh_gate.current_epoch();
            let token = self
                .inner
                .valid_access_token()
                .await
                .map_err(normalize_tidal_error)?;
            let cfg = self.inner.config_snapshot().await;
            let url = endpoint_url(&cfg.api_base_url, path);

            let mut req = HttpRequest::get(url)
                .with_header("Authorization", format!("Bearer {token}"))
                .with_query("countryCode", &cfg.country_code);
            for (k, v) in extra_query {
                req = req.with_query(*k, v.clone());
            }

            let resp = send_http_with_retry(
                self.inner.transport().as_ref(),
                &req,
                &self.retry_policy,
                cancel,
            )
            .await?;

            if resp.status == 401 && !retried_after_refresh {
                retried_after_refresh = true;
                self.refresh_once_inner(observed_epoch, cancel).await?;
                continue;
            }

            map_tidal_http_status(&resp, context)?;
            return Ok(resp);
        }
    }
}

#[async_trait]
impl MediaProvider for TidalMediaProvider {
    fn provider_id(&self) -> &'static str {
        "tidal"
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
        let resp = self
            .fetch_json_with_auth(
                &format!("playlists/{playlist_id}"),
                &[],
                "playlists/get",
                &cancel,
            )
            .await?;

        let meta: TidalPlaylistDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Tidal playlist response: {e}"))
        })?;

        let mut track_items = meta.tracks.map(|t| t.items).unwrap_or_default();
        if track_items.is_empty() {
            if let Ok(tracks_resp) = self
                .fetch_json_with_auth(
                    &format!("playlists/{playlist_id}/tracks"),
                    &[("limit", "100".to_string())],
                    "playlists/tracks",
                    &cancel,
                )
                .await
            {
                if let Ok(parsed) =
                    serde_json::from_str::<TidalPlaylistTracksDto>(&tracks_resp.body)
                {
                    track_items = parsed.items;
                }
            }
        }

        let mut tracks = Vec::with_capacity(track_items.len());
        for (idx, item) in track_items.into_iter().enumerate() {
            let format = format_for_tidal_quality(item.audio_quality.as_deref())?;
            let version_id = item
                .album
                .map(|a| a.id)
                .unwrap_or_else(|| format!("tidal-playlist-{playlist_id}"));
            let mut track = TrackSource::new(
                version_id,
                ProviderKind::Tidal,
                item.id,
                item.title,
                item.volume_number.unwrap_or(1).max(1),
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

        let artwork_url = meta
            .square_image
            .or(meta.image)
            .filter(|s| !s.trim().is_empty())
            .map(|img| {
                if img.starts_with("http://") || img.starts_with("https://") {
                    img
                } else {
                    format!(
                        "https://resources.tidal.com/images/{}/640x640.jpg",
                        img.replace('-', "/")
                    )
                }
            });

        Ok(MediaPlaylist {
            id: meta
                .uuid
                .or(meta.id)
                .unwrap_or_else(|| playlist_id.to_string()),
            provider_id: self.provider_id().to_string(),
            title: meta.title,
            description: meta.description.filter(|s| !s.trim().is_empty()),
            owner: meta
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
                Some("Tidal OAuth session active".to_string())
            } else {
                Some("Tidal authentication required".to_string())
            },
        })
    }

    async fn refresh_credentials(&self) -> Result<(), ProviderError> {
        let cancel = CancellationToken::new();
        let epoch = self.refresh_gate.current_epoch();
        self.refresh_once_inner(epoch, &cancel).await
    }
}

fn normalize_tidal_error(err: ProviderError) -> ProviderError {
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

fn map_tidal_http_status(resp: &HttpResponse, context: &str) -> Result<(), ProviderError> {
    let lower = resp.body.to_ascii_lowercase();
    let is_geo_blocked = lower.contains("not available in your")
        || lower.contains("region")
        || lower.contains("territory")
        || lower.contains("country")
        || lower.contains("geo-block")
        || lower.contains("geoblock");

    match resp.status {
        200..=299 => Ok(()),
        401 => Err(ProviderError::AuthExpired(format!(
            "Tidal {context} unauthorized (HTTP 401)"
        ))),
        429 => Err(ProviderError::rate_limited(
            format!("Tidal {context} rate limited (HTTP 429)"),
            resp.header("retry-after").and_then(parse_retry_after),
        )),
        451 => Err(ProviderError::RegionBlocked(format!(
            "Tidal {context} region blocked (HTTP 451): {}",
            resp.body
        ))),
        403 if is_geo_blocked => Err(ProviderError::RegionBlocked(format!(
            "Tidal {context} geo-blocked (HTTP 403): {}",
            resp.body
        ))),
        404 => Err(ProviderError::AlbumNotFound(format!(
            "Tidal {context} not found (HTTP 404)"
        ))),
        _ => Err(ProviderError::Network(format!(
            "Tidal {context} failed (HTTP {}): {}",
            resp.status, resp.body
        ))),
    }
}

fn format_for_tidal_quality(quality: Option<&str>) -> Result<AudioFormat, ProviderError> {
    let (codec, sr, bd) = match quality.unwrap_or("LOSSLESS") {
        "HI_RES_LOSSLESS" | "HI_RES" => (AudioCodec::Flac, 96_000, 24),
        "HIGH" | "LOW" => (AudioCodec::Aac, 44_100, 16),
        _ => (AudioCodec::Flac, 44_100, 16),
    };
    Ok(AudioFormat::pcm(codec, sr, bd, 2)?)
}

fn de_opt_val_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let val = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(val.map(|v| match v {
        serde_json::Value::String(s) => s,
        serde_json::Value::Number(n) => n.to_string(),
        other => other.to_string(),
    }))
}

fn de_val_string<'de, D>(deserializer: D) -> Result<String, D::Error>
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
struct TidalPlaylistDto {
    #[serde(default, deserialize_with = "de_opt_val_string")]
    uuid: Option<String>,
    #[serde(default, deserialize_with = "de_opt_val_string")]
    id: Option<String>,
    title: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    creator: Option<TidalCreatorDto>,
    #[serde(rename = "squareImage", default)]
    square_image: Option<String>,
    #[serde(default)]
    image: Option<String>,
    #[serde(default)]
    tracks: Option<TidalPlaylistTracksDto>,
}

#[derive(Debug, Deserialize)]
struct TidalCreatorDto {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TidalPlaylistTracksDto {
    #[serde(default)]
    items: Vec<TidalPlaylistTrackItemDto>,
}

#[derive(Debug, Deserialize)]
struct TidalPlaylistTrackItemDto {
    #[serde(deserialize_with = "de_val_string")]
    id: String,
    title: String,
    #[serde(rename = "trackNumber", default)]
    track_number: Option<u16>,
    #[serde(rename = "volumeNumber", default)]
    volume_number: Option<u16>,
    #[serde(default)]
    duration: Option<u64>,
    #[serde(default)]
    isrc: Option<String>,
    #[serde(rename = "audioQuality", default)]
    audio_quality: Option<String>,
    #[serde(default)]
    album: Option<TidalPlaylistAlbumRef>,
}

#[derive(Debug, Deserialize)]
struct TidalPlaylistAlbumRef {
    #[serde(deserialize_with = "de_val_string")]
    id: String,
}
