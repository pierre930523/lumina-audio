use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, StreamKey,
    StreamSourceSpec, TrackSource,
};
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;

use super::models::{
    AppleDataListResponse, AppleMusicConfig, AppleMusicCredentialRefresher, ApplePlaylistResource,
    AppleSearchResponse, AppleSongResource, DEFAULT_APPLE_MUSIC_STOREFRONT,
};
use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpResponse, HttpTransport, ReqwestHttpTransport, endpoint_url};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::media_provider::{MediaPlaylist, MediaProvider, ProviderHealth};
use crate::resilience::{
    RetryPolicy, SingleFlightRefreshGate, parse_retry_after, send_http_with_retry,
};

/// Isolated Apple Music Catalog API [`MediaProvider`].
pub struct AppleMusicProvider {
    config: RwLock<AppleMusicConfig>,
    transport: Arc<dyn HttpTransport>,
    retry_policy: RetryPolicy,
    refresh_gate: SingleFlightRefreshGate,
    refresher: Option<AppleMusicCredentialRefresher>,
}

impl AppleMusicProvider {
    pub fn new(config: AppleMusicConfig, transport: Arc<dyn HttpTransport>) -> Self {
        Self {
            config: RwLock::new(config),
            transport,
            retry_policy: RetryPolicy::default(),
            refresh_gate: SingleFlightRefreshGate::new(),
            refresher: None,
        }
    }

    pub fn live(config: AppleMusicConfig) -> Self {
        Self::new(config, Arc::new(ReqwestHttpTransport::new()))
    }

    pub fn with_retry_policy(mut self, policy: RetryPolicy) -> Self {
        self.retry_policy = policy;
        self
    }

    pub fn with_credential_refresher(mut self, refresher: AppleMusicCredentialRefresher) -> Self {
        self.refresher = Some(refresher);
        self
    }

    async fn refresh_once_inner(
        &self,
        observed_epoch: u64,
        cancel: &CancellationToken,
    ) -> Result<(), ProviderError> {
        let Some(refresher) = self.refresher.clone() else {
            return Err(ProviderError::AuthExpired(
                "Apple Music credential refresher is not configured".to_string(),
            ));
        };

        self.refresh_gate
            .refresh_once(observed_epoch, cancel, || async {
                let updated = (refresher)().await?;
                let mut cfg = self.config.write().await;
                if let Some(dev) = updated.developer_token.filter(|s| !s.trim().is_empty()) {
                    cfg.developer_token = Some(dev);
                }
                if let Some(mut_tok) = updated.music_user_token.filter(|s| !s.trim().is_empty()) {
                    cfg.music_user_token = Some(mut_tok);
                }
                Ok(())
            })
            .await
            .map(|_| ())
    }

    async fn send_catalog_get(
        &self,
        path_suffix: &str,
        query: &[(&str, String)],
        context: &str,
        not_found_as_track: Option<&str>,
        cancel: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        let mut retried_after_refresh = false;
        loop {
            if cancel.is_cancelled() {
                return Err(ProviderError::Cancelled);
            }
            let observed_epoch = self.refresh_gate.current_epoch();
            let cfg = self.config.read().await.clone();
            let dev_token = cfg
                .developer_token
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| ProviderError::not_authenticated("apple_music"))?;

            let storefront = if cfg.storefront.trim().is_empty() {
                DEFAULT_APPLE_MUSIC_STOREFRONT
            } else {
                cfg.storefront.trim()
            };
            let full_path = format!(
                "catalog/{storefront}/{}",
                path_suffix.trim_start_matches('/')
            );
            let url = endpoint_url(&cfg.base_url, &full_path);

            let mut req =
                HttpRequest::get(url).with_header("Authorization", format!("Bearer {dev_token}"));
            if let Some(user_tok) = cfg
                .music_user_token
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                req = req.with_header("Music-User-Token", user_tok);
            }
            for (k, v) in query {
                req = req.with_query(*k, v.clone());
            }

            let resp =
                send_http_with_retry(self.transport.as_ref(), &req, &self.retry_policy, cancel)
                    .await?;

            if resp.status == 401 && !retried_after_refresh && self.refresher.is_some() {
                retried_after_refresh = true;
                self.refresh_once_inner(observed_epoch, cancel).await?;
                continue;
            }

            if resp.status == 404 {
                if let Some(track_id) = not_found_as_track {
                    return Err(ProviderError::track_not_found("apple_music", track_id));
                }
                return Err(ProviderError::AlbumNotFound(format!(
                    "Apple Music {context} not found (HTTP 404)"
                )));
            }

            map_apple_http_status(&resp, context)?;
            return Ok(resp);
        }
    }

    async fn fetch_song_dto(
        &self,
        track_id: &str,
        cancel: &CancellationToken,
    ) -> Result<AppleSongResource, ProviderError> {
        let resp = self
            .send_catalog_get(
                &format!("songs/{track_id}"),
                &[],
                "songs/get",
                Some(track_id),
                cancel,
            )
            .await?;

        let parsed: AppleDataListResponse<AppleSongResource> = serde_json::from_str(&resp.body)
            .map_err(|e| {
                ProviderError::Network(format!("Failed to parse Apple Music song response: {e}"))
            })?;

        parsed
            .data
            .into_iter()
            .next()
            .ok_or_else(|| ProviderError::track_not_found("apple_music", track_id))
    }
}

#[async_trait]
impl MediaProvider for AppleMusicProvider {
    fn provider_id(&self) -> &'static str {
        "apple_music"
    }

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let cancel = CancellationToken::new();
        let clamped_limit = limit.clamp(1, 25);
        let resp = self
            .send_catalog_get(
                "search",
                &[
                    ("term", query.to_string()),
                    ("types", "albums".to_string()),
                    ("limit", clamped_limit.to_string()),
                ],
                "catalog/search",
                None,
                &cancel,
            )
            .await?;

        let parsed: AppleSearchResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Apple Music search response: {e}"))
        })?;

        let items = parsed
            .results
            .and_then(|r| r.albums)
            .map(|a| a.data)
            .unwrap_or_default();

        let format = AudioFormat::pcm(AudioCodec::Alac, 44_100, 16, 2)?;
        let mut albums = Vec::with_capacity(items.len());
        for item in items {
            let attrs = item.attributes.unwrap_or_default();
            let raw_title = attrs.name.unwrap_or_else(|| "Unknown Album".to_string());
            let artist = attrs
                .artist_name
                .unwrap_or_else(|| "Unknown Artist".to_string());
            let (base_title, edition) = extract_edition_label(&raw_title);
            let mut album = CanonicalAlbum::new(&base_title, &artist)?;

            if let Some(year) = attrs.release_date.as_deref().and_then(parse_year) {
                if let Ok(alb) = album.clone().with_release_year(year) {
                    album = alb;
                }
            }
            if let Some(cover) = attrs.artwork.and_then(|a| a.formatted_url(600)) {
                album = album.with_cover_url(cover);
            }

            let mut version = AlbumVersion::new(
                &album.id,
                ProviderKind::AppleMusic,
                &item.id,
                format.clone(),
            )?;
            if let Some(ed) = edition {
                version = version.with_edition_label(ed);
            }
            album.add_version(version);
            albums.push(album);
        }

        Ok(albums)
    }

    async fn get_track(&self, track_id: &str) -> Result<TrackSource, ProviderError> {
        let cancel = CancellationToken::new();
        let song = self.fetch_song_dto(track_id, &cancel).await?;
        map_apple_song_to_track(song, 1, "apple-music-track")
    }

    async fn get_playlist(&self, playlist_id: &str) -> Result<MediaPlaylist, ProviderError> {
        let cancel = CancellationToken::new();
        let resp = self
            .send_catalog_get(
                &format!("playlists/{playlist_id}"),
                &[("include", "tracks".to_string())],
                "playlists/get",
                None,
                &cancel,
            )
            .await?;

        let parsed: AppleDataListResponse<ApplePlaylistResource> = serde_json::from_str(&resp.body)
            .map_err(|e| {
                ProviderError::Network(format!(
                    "Failed to parse Apple Music playlist response: {e}"
                ))
            })?;

        let playlist = parsed.data.into_iter().next().ok_or_else(|| {
            ProviderError::AlbumNotFound(format!("Apple Music playlist '{playlist_id}' not found"))
        })?;

        let attrs = playlist.attributes.unwrap_or_default();
        let raw_tracks = playlist
            .relationships
            .and_then(|r| r.tracks)
            .map(|t| t.data)
            .unwrap_or_default();

        let fallback_ver = format!("apple-playlist-{playlist_id}");
        let mut tracks = Vec::with_capacity(raw_tracks.len());
        for (idx, song) in raw_tracks.into_iter().enumerate() {
            tracks.push(map_apple_song_to_track(
                song,
                (idx + 1) as u16,
                &fallback_ver,
            )?);
        }

        Ok(MediaPlaylist {
            id: playlist.id,
            provider_id: self.provider_id().to_string(),
            title: attrs
                .name
                .unwrap_or_else(|| "Untitled Playlist".to_string()),
            description: attrs
                .description
                .and_then(|d| d.standard.or(d.short))
                .filter(|s| !s.trim().is_empty()),
            owner: attrs.curator_name.filter(|s| !s.trim().is_empty()),
            artwork_url: attrs.artwork.and_then(|a| a.formatted_url(600)),
            tracks,
        })
    }

    async fn resolve_stream(
        &self,
        track_id: &str,
        quality: &str,
        cancel_token: CancellationToken,
    ) -> Result<StreamSourceSpec, ProviderError> {
        if cancel_token.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }
        if track_id.trim().is_empty() {
            return Err(ProviderError::track_not_found("apple_music", track_id));
        }

        let song = self.fetch_song_dto(track_id, &cancel_token).await?;
        let attrs = song.attributes.unwrap_or_default();
        let preview_url = attrs
            .previews
            .into_iter()
            .find_map(|p| p.url.filter(|s| !s.trim().is_empty()));
        let external_web_url = attrs.url.filter(|s| !s.trim().is_empty());

        Ok(StreamSourceSpec::ExternalBackend {
            key: StreamKey::new(self.provider_id(), track_id, quality),
            provider_id: self.provider_id().to_string(),
            track_uri: format!("apple:{track_id}"),
            external_web_url,
            preview_url,
            notice: Some(
                "Apple Music streams are FairPlay DRM protected; use MusicKit external backend or preview URL."
                    .to_string(),
            ),
        })
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        let start = Instant::now();
        let cfg = self.config.read().await;
        let has_dev = cfg
            .developer_token
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty());
        let has_user = cfg
            .music_user_token
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty());
        let detail = if has_dev && has_user {
            "Apple Music developer & user tokens configured".to_string()
        } else if has_dev {
            "Apple Music developer token configured (catalog-only)".to_string()
        } else {
            "Apple Music developer token missing".to_string()
        };

        Ok(ProviderHealth {
            provider_id: self.provider_id().to_string(),
            healthy: has_dev,
            authenticated: has_dev,
            latency_ms: start.elapsed().as_millis() as u64,
            detail: Some(detail),
        })
    }

    async fn refresh_credentials(&self) -> Result<(), ProviderError> {
        let cancel = CancellationToken::new();
        let epoch = self.refresh_gate.current_epoch();
        self.refresh_once_inner(epoch, &cancel).await
    }
}

fn map_apple_song_to_track(
    song: AppleSongResource,
    fallback_track_num: u16,
    fallback_version_id: &str,
) -> Result<TrackSource, ProviderError> {
    let attrs = song.attributes.unwrap_or_default();
    let format = AudioFormat::pcm(AudioCodec::Alac, 44_100, 16, 2)?;
    let version_id = attrs
        .album_name
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| fallback_version_id.to_string());
    let mut track = TrackSource::new(
        version_id,
        ProviderKind::AppleMusic,
        song.id,
        attrs.name.unwrap_or_else(|| "Unknown Track".to_string()),
        attrs.disc_number.unwrap_or(1).max(1),
        attrs.track_number.unwrap_or(fallback_track_num).max(1),
        attrs.duration_in_millis.unwrap_or(1).max(1),
        format,
    )?;
    if let Some(isrc) = attrs.isrc.filter(|s| !s.trim().is_empty()) {
        if let Ok(with_isrc) = track.clone().with_isrc(isrc) {
            track = with_isrc;
        }
    }
    Ok(track)
}

fn map_apple_http_status(resp: &HttpResponse, context: &str) -> Result<(), ProviderError> {
    let lower = resp.body.to_ascii_lowercase();
    let is_geo_blocked = lower.contains("storefront")
        || lower.contains("region")
        || lower.contains("country")
        || lower.contains("territory")
        || lower.contains("geo-block")
        || lower.contains("geoblock");

    match resp.status {
        200..=299 => Ok(()),
        401 => Err(ProviderError::AuthExpired(format!(
            "Apple Music {context} unauthorized (HTTP 401)"
        ))),
        429 => Err(ProviderError::rate_limited(
            format!("Apple Music {context} rate limited (HTTP 429)"),
            resp.header("retry-after").and_then(parse_retry_after),
        )),
        451 => Err(ProviderError::RegionBlocked(format!(
            "Apple Music {context} region blocked (HTTP 451): {}",
            resp.body
        ))),
        403 if is_geo_blocked => Err(ProviderError::RegionBlocked(format!(
            "Apple Music {context} geo-blocked (HTTP 403): {}",
            resp.body
        ))),
        403 => Err(ProviderError::DrmRestricted(format!(
            "Apple Music {context} forbidden (HTTP 403): {}",
            resp.body
        ))),
        _ => Err(ProviderError::Network(format!(
            "Apple Music {context} failed (HTTP {}): {}",
            resp.status, resp.body
        ))),
    }
}
