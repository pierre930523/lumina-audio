use async_trait::async_trait;
use chrono::{DateTime, Datelike};
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, QobuzAuthMode, TrackSource,
};

use super::client::QobuzProvider;
use super::models::{QobuzAlbumItem, QobuzSearchResponse, QobuzTrackItem, normalize_sample_rate};
use super::transport::HttpRequest;
use crate::error::ProviderError;
use crate::http::endpoint_url;
use crate::local::extract_edition_label;
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, SyncProgress, SyncResult,
};

impl QobuzProvider {
    fn map_album_item(&self, item: QobuzAlbumItem) -> Result<CanonicalAlbum, ProviderError> {
        let artist_name = item
            .artist
            .map(|a| a.name)
            .unwrap_or_else(|| "Unknown Artist".to_string());
        let (base_title, extracted_edition) = extract_edition_label(&item.title);
        let mut album = CanonicalAlbum::new(&base_title, &artist_name)?;

        if let Some(year) =
            parse_qobuz_release_year(item.release_date_original.as_deref(), item.released_at)
        {
            if let Ok(alb) = album.clone().with_release_year(year) {
                album = alb;
            }
        }
        if let Some(cover) = item.image.as_ref().and_then(|img| img.best_url()) {
            album = album.with_cover_url(cover);
        }

        let sample_rate = item
            .maximum_sampling_rate
            .as_ref()
            .map(normalize_sample_rate)
            .unwrap_or(44100);
        let bit_depth = item.maximum_bit_depth.unwrap_or(16);

        let format = AudioFormat::pcm(AudioCodec::Flac, sample_rate, bit_depth, 2)?;
        let mut version = AlbumVersion::new(&album.id, ProviderKind::Qobuz, &item.id, format)?;
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
}

#[async_trait]
impl MusicProvider for QobuzProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Qobuz
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::qobuz()
    }

    async fn is_authenticated(&self) -> bool {
        if self.session.read().await.is_some() {
            return true;
        }
        {
            let cfg = self.config.read().await;
            if let QobuzAuthMode::Token {
                user_auth_token, ..
            } = &cfg.auth
            {
                if !user_auth_token.trim().is_empty() {
                    return true;
                }
            }
        }
        self.load_stored_token().await.is_some()
    }

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let (base_url, app_id, token) = {
            let cfg = self.config.read().await;
            let sess = self.session.read().await;
            (
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
                sess.as_ref().map(|s| s.user_auth_token.clone()),
            )
        };

        let url = endpoint_url(&base_url, "catalog/search");
        let mut headers = vec![("X-App-Id".to_string(), app_id)];
        if let Some(t) = token {
            headers.push(("X-User-Auth-Token".to_string(), t));
        }

        let resp = self
            .transport
            .execute(HttpRequest {
                method: "GET".to_string(),
                url,
                headers,
                query_params: vec![
                    ("query".to_string(), query.to_string()),
                    ("type".to_string(), "albums".to_string()),
                    ("limit".to_string(), limit.to_string()),
                ],
                body: None,
            })
            .await?;

        self.map_http_response(&resp, "catalog/search")?;

        let parsed: QobuzSearchResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse catalog search response: {e}"))
        })?;

        let mut albums = Vec::new();
        let items = parsed.albums.and_then(|a| a.items).unwrap_or_default();

        for item in items {
            albums.push(self.map_album_item(item)?);
        }

        Ok(albums)
    }

    async fn get_album(&self, external_album_id: &str) -> Result<CanonicalAlbum, ProviderError> {
        let (base_url, app_id, token) = {
            let cfg = self.config.read().await;
            let sess = self.session.read().await;
            (
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
                sess.as_ref().map(|s| s.user_auth_token.clone()),
            )
        };

        let url = endpoint_url(&base_url, "album/get");
        let mut headers = vec![("X-App-Id".to_string(), app_id)];
        if let Some(t) = token {
            headers.push(("X-User-Auth-Token".to_string(), t));
        }

        let resp = self
            .transport
            .execute(HttpRequest {
                method: "GET".to_string(),
                url,
                headers,
                query_params: vec![("album_id".to_string(), external_album_id.to_string())],
                body: None,
            })
            .await?;

        self.map_http_status(resp.status, "album/get", &resp.body)?;
        let item: QobuzAlbumItem = serde_json::from_str(&resp.body)
            .map_err(|e| ProviderError::Network(format!("Failed to parse Qobuz album/get: {e}")))?;
        self.map_album_item(item)
    }

    async fn get_track(&self, external_track_id: &str) -> Result<TrackSource, ProviderError> {
        let (base_url, app_id, token) = {
            let cfg = self.config.read().await;
            let sess = self.session.read().await;
            (
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
                sess.as_ref().map(|s| s.user_auth_token.clone()),
            )
        };

        let url = endpoint_url(&base_url, "track/get");
        let mut headers = vec![("X-App-Id".to_string(), app_id)];
        if let Some(t) = token {
            headers.push(("X-User-Auth-Token".to_string(), t));
        }

        let resp = self
            .transport
            .execute(HttpRequest {
                method: "GET".to_string(),
                url,
                headers,
                query_params: vec![("track_id".to_string(), external_track_id.to_string())],
                body: None,
            })
            .await?;

        if resp.status == 404 {
            return Err(ProviderError::track_not_found("qobuz", external_track_id));
        }
        self.map_http_response(&resp, "track/get")?;

        let item: QobuzTrackItem = serde_json::from_str(&resp.body)
            .map_err(|e| ProviderError::Network(format!("Failed to parse Qobuz track/get: {e}")))?;

        let sr = item
            .maximum_sampling_rate
            .as_ref()
            .map(normalize_sample_rate)
            .unwrap_or(44100);
        let bd = item.maximum_bit_depth.unwrap_or(16);
        let format = AudioFormat::pcm(AudioCodec::Flac, sr, bd, 2)?;
        let version_id = item
            .album
            .as_ref()
            .map(|a| a.id.clone())
            .unwrap_or_else(|| "qobuz-track".to_string());

        let mut track = TrackSource::new(
            version_id,
            ProviderKind::Qobuz,
            item.id,
            item.title,
            item.media_number.unwrap_or(1).max(1),
            item.track_number.unwrap_or(1).max(1),
            item.duration.unwrap_or(1).saturating_mul(1000).max(1),
            format,
        )?;
        if let Some(isrc) = item.isrc.filter(|s| !s.trim().is_empty()) {
            if let Ok(with_i) = track.clone().with_isrc(isrc) {
                track = with_i;
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

    async fn sync_library_with_progress(
        &self,
        progress_tx: Option<tokio::sync::mpsc::Sender<SyncProgress>>,
    ) -> Result<SyncResult, ProviderError> {
        let _ = progress_tx;
        self.sync_library().await
    }
}

fn parse_qobuz_release_year(original: Option<&str>, released_at: Option<i64>) -> Option<i32> {
    if let Some(orig) = original {
        if let Some(year) = crate::local::dsd_meta::parse_year(orig) {
            return Some(year);
        }
    }
    if let Some(ts) = released_at {
        if let Some(dt) = DateTime::from_timestamp(ts, 0) {
            let y = dt.year();
            if (1000..=3000).contains(&y) {
                return Some(y);
            }
        }
    }
    None
}
