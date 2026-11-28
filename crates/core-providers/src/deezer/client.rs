use std::sync::Arc;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, TrackSource,
};
use tokio::sync::RwLock;

use super::models::{
    DeezerAlbumDto, DeezerConfig, DeezerSearchAlbumsResponse, DeezerSession, DeezerTrackDto,
};
use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpTransport, ReqwestHttpTransport, endpoint_url};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::traits::{MusicProvider, ProviderCapabilities, ResolvedStream, SyncResult};

pub struct DeezerProvider {
    pub(super) config: RwLock<DeezerConfig>,
    pub(super) transport: Arc<dyn HttpTransport>,
    pub(super) credential_store: Option<Arc<dyn CredentialStore>>,
    pub(super) active_arl: RwLock<Option<String>>,
    pub(super) session: RwLock<Option<DeezerSession>>,
}

impl DeezerProvider {
    pub fn new(credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::with_config(DeezerConfig::default(), credential_store)
    }

    pub fn with_config(
        config: DeezerConfig,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self::with_transport(
            config,
            Arc::new(ReqwestHttpTransport::new()),
            credential_store,
        )
    }

    pub fn with_transport(
        config: DeezerConfig,
        transport: Arc<dyn HttpTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        let arl = config.arl.clone();
        Self {
            config: RwLock::new(config),
            transport,
            credential_store,
            active_arl: RwLock::new(arl),
            session: RwLock::new(None),
        }
    }

    pub(crate) fn transport(&self) -> &Arc<dyn HttpTransport> {
        &self.transport
    }

    pub(crate) async fn config_snapshot(&self) -> DeezerConfig {
        self.config.read().await.clone()
    }

    fn map_album_dto(&self, dto: DeezerAlbumDto) -> Result<CanonicalAlbum, ProviderError> {
        let artist_name = dto
            .artist
            .map(|a| a.name)
            .unwrap_or_else(|| "Unknown Artist".to_string());
        let (base_title, edition) = extract_edition_label(&dto.title);
        let mut album = CanonicalAlbum::new(&base_title, &artist_name)?;

        if let Some(year) = dto.release_date.as_deref().and_then(parse_year) {
            if let Ok(alb) = album.clone().with_release_year(year) {
                album = alb;
            }
        }
        if let Some(cover) = dto
            .cover_xl
            .or(dto.cover_big)
            .or(dto.cover_medium)
            .filter(|s| !s.trim().is_empty())
        {
            album = album.with_cover_url(cover);
        }

        let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2)?;
        let mut version = AlbumVersion::new(&album.id, ProviderKind::Deezer, &dto.id, format)?;
        if let Some(ed) = edition {
            version = version.with_edition_label(ed);
        }
        album.add_version(version);
        Ok(album)
    }

    pub(super) fn build_cookie_header(&self, sess: &DeezerSession) -> String {
        if let Some(ref sid) = sess.sid {
            format!("arl={}; sid={}", sess.arl, sid)
        } else {
            format!("arl={}", sess.arl)
        }
    }
}

#[async_trait]
impl MusicProvider for DeezerProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::Deezer
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::deezer()
    }

    async fn is_authenticated(&self) -> bool {
        if self.session.read().await.is_some() {
            return true;
        }
        self.get_valid_arl().await.is_ok()
    }

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let arl = self.get_valid_arl().await?;
        let api_base = self.config.read().await.api_base_url.clone();
        let url = endpoint_url(&api_base, "search/album");

        let req = HttpRequest::get(url)
            .with_header("Cookie", format!("arl={arl}"))
            .with_query("q", query)
            .with_query("limit", limit.to_string());

        let resp = self.transport.execute(req).await?;
        if resp.status == 429 {
            let retry_after = resp
                .header("retry-after")
                .and_then(crate::resilience::parse_retry_after);
            return Err(ProviderError::rate_limited(
                "Deezer search rate limited",
                retry_after,
            ));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer search failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let parsed: DeezerSearchAlbumsResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Deezer search response: {e}"))
        })?;

        let mut albums = Vec::with_capacity(parsed.data.len());
        for dto in parsed.data {
            albums.push(self.map_album_dto(dto)?);
        }
        Ok(albums)
    }

    async fn get_album(&self, external_album_id: &str) -> Result<CanonicalAlbum, ProviderError> {
        let arl = self.get_valid_arl().await?;
        let api_base = self.config.read().await.api_base_url.clone();
        let url = endpoint_url(&api_base, &format!("album/{external_album_id}"));

        let req = HttpRequest::get(url).with_header("Cookie", format!("arl={arl}"));
        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::album_not_found("deezer", external_album_id));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer album fetch failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let dto: DeezerAlbumDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Deezer album response: {e}"))
        })?;
        self.map_album_dto(dto)
    }

    async fn get_track(&self, external_track_id: &str) -> Result<TrackSource, ProviderError> {
        let arl = self.get_valid_arl().await?;
        let api_base = self.config.read().await.api_base_url.clone();
        let url = endpoint_url(&api_base, &format!("track/{external_track_id}"));

        let req = HttpRequest::get(url).with_header("Cookie", format!("arl={arl}"));
        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found("deezer", external_track_id));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer track fetch failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let dto: DeezerTrackDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::Network(format!("Failed to parse Deezer track response: {e}"))
        })?;

        let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2)?;
        let version_id = dto
            .album
            .map(|a| a.id)
            .unwrap_or_else(|| "deezer-track".to_string());

        let mut track = TrackSource::new(
            version_id,
            ProviderKind::Deezer,
            dto.id,
            dto.title,
            dto.disk_number.unwrap_or(1).max(1),
            dto.track_position.unwrap_or(1).max(1),
            dto.duration.unwrap_or(1).saturating_mul(1000).max(1),
            format,
        )?;
        if let Some(isrc) = dto.isrc.filter(|s| !s.trim().is_empty()) {
            if let Ok(t) = track.clone().with_isrc(isrc) {
                track = t;
            }
        }
        if let Some(gain) = dto.gain.filter(|g| g.is_finite()) {
            track = track.with_replay_gain(Some(gain), None, None, None);
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
