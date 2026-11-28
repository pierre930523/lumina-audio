use std::sync::Arc;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{AlbumVersion, CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::{Mutex, RwLock};

use super::models::{
    TidalAlbumItem, TidalConfig, TidalPlaybackInfo, TidalSearchAlbumsResponse, TidalTokenResponse,
    TidalTrackItem,
};
use super::stream::audio_format_for_tidal_quality;
use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpResponse, HttpTransport, ReqwestHttpTransport, endpoint_url};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::traits::{MusicProvider, ProviderCapabilities, ResolvedStream, SyncResult};

pub struct TidalProvider {
    pub(super) config: RwLock<TidalConfig>,
    pub(super) transport: Arc<dyn HttpTransport>,
    pub(super) credential_store: Option<Arc<dyn CredentialStore>>,
    pub(super) active_tokens: RwLock<Option<TidalTokenResponse>>,
    pub(super) pending_verifier: RwLock<Option<String>>,
    pub(super) refresh_lock: Mutex<()>,
}

impl TidalProvider {
    pub fn new(credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::live(TidalConfig::default(), credential_store)
    }

    pub fn live(config: TidalConfig, credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::with_config(
            config,
            Arc::new(ReqwestHttpTransport::new()),
            credential_store,
        )
    }

    pub fn with_config(
        config: TidalConfig,
        transport: Arc<dyn HttpTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self {
            config: RwLock::new(config),
            transport,
            credential_store,
            active_tokens: RwLock::new(None),
            pending_verifier: RwLock::new(None),
            refresh_lock: Mutex::new(()),
        }
    }

    pub(crate) fn transport(&self) -> &Arc<dyn HttpTransport> {
        &self.transport
    }

    pub(crate) async fn config_snapshot(&self) -> TidalConfig {
        self.config.read().await.clone()
    }

    pub(super) fn map_http_response(
        &self,
        resp: &HttpResponse,
        context: &str,
    ) -> Result<(), ProviderError> {
        if resp.status == 429 {
            let retry_after = resp
                .header("retry-after")
                .and_then(crate::resilience::parse_retry_after);
            return Err(ProviderError::rate_limited(
                format!("Tidal {context} rate limited (HTTP 429)"),
                retry_after,
            ));
        }
        self.map_http_error(resp.status, context, &resp.body)
    }

    pub(super) fn map_http_error(
        &self,
        status: u16,
        context: &str,
        body: &str,
    ) -> Result<(), ProviderError> {
        let lower = body.to_ascii_lowercase();
        let is_geo_blocked = lower.contains("not available in your")
            || lower.contains("region")
            || lower.contains("territory")
            || lower.contains("country")
            || lower.contains("geo-block")
            || lower.contains("geoblock");
        let is_takedown = lower.contains("no longer available")
            || lower.contains("takedown")
            || lower.contains("asset is not ready")
            || lower.contains("track unavailable")
            || lower.contains("unavailable for streaming");

        match status {
            200..=299 => Ok(()),
            401 => Err(ProviderError::AuthenticationFailed(format!(
                "Tidal {context} unauthorized (HTTP 401)"
            ))),
            451 => Err(ProviderError::RegionRestricted(format!(
                "Tidal {context} region restricted (HTTP 451): {body}"
            ))),
            410 => Err(ProviderError::TrackUnavailable(format!(
                "Tidal {context} track removed/unavailable (HTTP 410): {body}"
            ))),
            403 if is_geo_blocked => Err(ProviderError::RegionRestricted(format!(
                "Tidal {context} geo-restricted (HTTP 403): {body}"
            ))),
            403 if is_takedown => Err(ProviderError::TrackUnavailable(format!(
                "Tidal {context} track unavailable (HTTP 403): {body}"
            ))),
            403 => Err(ProviderError::StreamResolutionFailed(format!(
                "Tidal {context} forbidden (HTTP 403): {body}"
            ))),
            404 => Err(ProviderError::AlbumNotFound(format!(
                "Tidal {context} not found (HTTP 404)"
            ))),
            429 => Err(ProviderError::rate_limited(
                format!("Tidal {context} rate limited (HTTP 429)"),
                None,
            )),
            _ => Err(ProviderError::Network(format!(
                "Tidal {context} failed (HTTP {status}): {body}"
            ))),
        }
    }

    fn map_album_item(&self, item: TidalAlbumItem) -> Result<CanonicalAlbum, ProviderError> {
        let artist_name = item
            .artist
            .map(|a| a.name)
            .or_else(|| item.artists.into_iter().next().map(|a| a.name))
            .unwrap_or_else(|| "Unknown Artist".to_string());
        let (base_title, extracted_edition) = extract_edition_label(&item.title);
        let mut album = CanonicalAlbum::new(&base_title, &artist_name)?;

        if let Some(year) = item.release_date.as_deref().and_then(parse_year) {
            if let Ok(alb) = album.clone().with_release_year(year) {
                album = alb;
            }
        }
        if let Some(cover) = item.cover.filter(|s| !s.trim().is_empty()) {
            let cover_url = if cover.starts_with("http://") || cover.starts_with("https://") {
                cover
            } else {
                format!(
                    "https://resources.tidal.com/images/{}/640x640.jpg",
                    cover.replace('-', "/")
                )
            };
            album = album.with_cover_url(cover_url);
        }

        let format = audio_format_for_tidal_quality(item.audio_quality.as_deref(), None, None)?;
        let mut version = AlbumVersion::new(&album.id, ProviderKind::Tidal, &item.id, format)?;
        if let Some(ed) = item
            .version
            .filter(|s| !s.trim().is_empty())
            .or(extracted_edition)
        {
            version = version.with_edition_label(ed);
        }
        album.add_version(version);
        Ok(album)
    }

    pub(super) async fn fetch_playback_info(
        &self,
        track_id: &str,
        audio_quality: &str,
    ) -> Result<(TidalPlaybackInfo, String), ProviderError> {
        let mut access_token = self.get_valid_access_token().await?;
        let cfg = self.config.read().await.clone();
        let url = endpoint_url(
            &cfg.api_base_url,
            &format!("tracks/{track_id}/playbackinfo"),
        );

        let mut retried_auth = false;
        let (resp, auth_header) = loop {
            let auth_header = format!("Bearer {access_token}");
            let req = HttpRequest::get(url.clone())
                .with_header("Authorization", auth_header.clone())
                .with_query("audioquality", audio_quality)
                .with_query("playbackmode", "STREAM")
                .with_query("assetpresentation", "FULL")
                .with_query("countryCode", &cfg.country_code);

            let resp = self.transport.execute(req).await?;
            if resp.status == 401 && !retried_auth {
                if let Ok(refreshed) = self
                    .refresh_tokens_single_flight(Some(&access_token), true)
                    .await
                {
                    access_token = refreshed.access_token;
                    retried_auth = true;
                    continue;
                }
            }
            break (resp, auth_header);
        };

        if resp.status == 404 {
            return Err(ProviderError::track_not_found("tidal", track_id));
        }
        self.map_http_response(&resp, "tracks/playbackinfo")?;

        let info: TidalPlaybackInfo = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!(
                "Failed to parse Tidal playbackinfo: {e}"
            ))
        })?;

        if let Some(ref enc) = info.encryption_type {
            if !enc.trim().is_empty() && !enc.eq_ignore_ascii_case("NONE") {
                return Err(ProviderError::DrmRestricted(format!(
                    "Tidal stream is encrypted ({enc})"
                )));
            }
        }

        Ok((info, auth_header))
    }
}

#[async_trait]
impl MusicProvider for TidalProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Tidal
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::tidal()
    }

    async fn is_authenticated(&self) -> bool {
        self.get_valid_access_token().await.is_ok()
    }

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let token = self.get_valid_access_token().await?;
        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.api_base_url, "search/albums");

        let req = HttpRequest::get(url)
            .with_header("Authorization", format!("Bearer {token}"))
            .with_query("query", query)
            .with_query("limit", limit.to_string())
            .with_query("countryCode", &cfg.country_code);

        let resp = self.transport.execute(req).await?;
        self.map_http_response(&resp, "search/albums")?;

        let parsed: TidalSearchAlbumsResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Tidal search response: {e}"))
        })?;

        let mut albums = Vec::with_capacity(parsed.items.len());
        for item in parsed.items {
            albums.push(self.map_album_item(item)?);
        }
        Ok(albums)
    }

    async fn get_album(&self, external_album_id: &str) -> Result<CanonicalAlbum, ProviderError> {
        let token = self.get_valid_access_token().await?;
        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.api_base_url, &format!("albums/{external_album_id}"));

        let req = HttpRequest::get(url)
            .with_header("Authorization", format!("Bearer {token}"))
            .with_query("countryCode", &cfg.country_code);

        let resp = self.transport.execute(req).await?;
        self.map_http_error(resp.status, "albums/get", &resp.body)?;

        let item: TidalAlbumItem = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Tidal album response: {e}"))
        })?;
        self.map_album_item(item)
    }

    async fn get_track(&self, external_track_id: &str) -> Result<TrackSource, ProviderError> {
        let token = self.get_valid_access_token().await?;
        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.api_base_url, &format!("tracks/{external_track_id}"));

        let req = HttpRequest::get(url)
            .with_header("Authorization", format!("Bearer {token}"))
            .with_query("countryCode", &cfg.country_code);

        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found("tidal", external_track_id));
        }
        self.map_http_response(&resp, "tracks/get")?;

        let item: TidalTrackItem = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Tidal track response: {e}"))
        })?;

        let format = audio_format_for_tidal_quality(item.audio_quality.as_deref(), None, None)?;
        let version_id = item
            .album
            .map(|a| a.id)
            .unwrap_or_else(|| "tidal-track".to_string());

        let mut track = TrackSource::new(
            version_id,
            ProviderKind::Tidal,
            item.id,
            item.title,
            item.volume_number.unwrap_or(1).max(1),
            item.track_number.unwrap_or(1).max(1),
            item.duration.unwrap_or(1).saturating_mul(1000).max(1),
            format,
        )?;
        if let Some(isrc) = item.isrc.filter(|s| !s.trim().is_empty()) {
            if let Ok(t) = track.clone().with_isrc(isrc) {
                track = t;
            }
        }
        Ok(track)
    }

    async fn resolve_stream(&self, track: &TrackSource) -> Result<ResolvedStream, ProviderError> {
        self.resolve_legacy_stream(track).await
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        Ok(SyncResult::default())
    }
}
