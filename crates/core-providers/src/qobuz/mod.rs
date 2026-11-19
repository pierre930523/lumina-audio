pub mod config;
pub mod models;
pub mod transport;

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use chrono::{DateTime, Datelike};
use core_db::credential::{CredentialStore, DEFAULT_SERVICE_NAME};
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, QobuzAuthMode, TrackSource,
};
use tokio::sync::RwLock;

use crate::error::ProviderError;
use crate::http::endpoint_url;
use crate::local::extract_edition_label;
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, SyncProgress, SyncResult,
};
pub use self::config::{format_ids, QobuzConfig, QobuzUserSession};
pub use self::models::*;
pub use self::transport::{
    HttpRequest, HttpResponse, HttpTransport, MockHttpTransport, ReqwestHttpTransport,
};

pub const QOBUZ_CREDENTIAL_SERVICE: &str = "com.lumina.audio.qobuz";
pub const QOBUZ_KEYRING_TOKEN_KEY: &str = "qobuz:user_auth_token";
pub const QOBUZ_KEYRING_APP_ID_KEY: &str = "qobuz:app_id";
pub const QOBUZ_KEYRING_APP_SECRET_KEY: &str = "qobuz:app_secret";
pub const QOBUZ_FALLBACK_TOKEN_KEY: &str = "lumina_qobuz:auth_token";

pub struct QobuzProvider {
    config: RwLock<QobuzConfig>,
    session: RwLock<Option<QobuzUserSession>>,
    transport: Arc<dyn HttpTransport>,
    credential_store: Option<Arc<dyn CredentialStore>>,
}

impl QobuzProvider {
    pub fn new(
        config: QobuzConfig,
        transport: Arc<dyn HttpTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self {
            config: RwLock::new(config),
            session: RwLock::new(None),
            transport,
            credential_store,
        }
    }

    pub fn live(
        config: QobuzConfig,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self::new(config, Arc::new(ReqwestHttpTransport::new()), credential_store)
    }

    pub async fn authenticate(&self) -> Result<QobuzUserSession, ProviderError> {
        let (auth_mode, base_url, app_id) = {
            let cfg = self.config.read().await;
            (
                cfg.auth.clone(),
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
            )
        };

        match auth_mode {
            QobuzAuthMode::Token {
                user_auth_token, ..
            } => {
                let session = self
                    .verify_token(&base_url, &app_id, &user_auth_token)
                    .await?;
                *self.session.write().await = Some(session.clone());
                self.persist_token(&user_auth_token).await;
                Ok(session)
            }
            QobuzAuthMode::Credentials {
                username, password, ..
            } => {
                let session = self
                    .login_with_credentials(&base_url, &app_id, &username, &password)
                    .await?;
                *self.session.write().await = Some(session.clone());
                self.persist_token(&session.user_auth_token).await;
                Ok(session)
            }
        }
    }

    async fn persist_token(&self, token: &str) {
        if let Some(ref store) = self.credential_store {
            let _ = store
                .set_secret(DEFAULT_SERVICE_NAME, QOBUZ_KEYRING_TOKEN_KEY, token)
                .await;
            let _ = store
                .set_secret(DEFAULT_SERVICE_NAME, QOBUZ_FALLBACK_TOKEN_KEY, token)
                .await;
            let _ = store
                .set_secret(QOBUZ_CREDENTIAL_SERVICE, QOBUZ_KEYRING_TOKEN_KEY, token)
                .await;
        }
    }

    async fn load_stored_token(&self) -> Option<String> {
        let store = self.credential_store.as_ref()?;
        for (svc, key) in [
            (DEFAULT_SERVICE_NAME, QOBUZ_KEYRING_TOKEN_KEY),
            (DEFAULT_SERVICE_NAME, QOBUZ_FALLBACK_TOKEN_KEY),
            (QOBUZ_CREDENTIAL_SERVICE, QOBUZ_KEYRING_TOKEN_KEY),
        ] {
            if let Ok(Some(tok)) = store.get_secret(svc, key).await {
                if !tok.trim().is_empty() {
                    return Some(tok);
                }
            }
        }
        None
    }

    async fn ensure_session(&self) -> Result<QobuzUserSession, ProviderError> {
        if let Some(sess) = self.session.read().await.clone() {
            return Ok(sess);
        }

        let token_candidate = {
            let cfg = self.config.read().await;
            match &cfg.auth {
                QobuzAuthMode::Token {
                    user_auth_token, ..
                } if !user_auth_token.trim().is_empty() => Some(user_auth_token.clone()),
                _ => None,
            }
        };

        let token = if let Some(t) = token_candidate {
            Some(t)
        } else {
            self.load_stored_token().await
        };

        let Some(tok) = token else {
            return Err(ProviderError::not_authenticated("qobuz"));
        };

        let default_q = self
            .config
            .read()
            .await
            .default_format_id
            .unwrap_or(format_ids::FLAC_24_192);
        let session = QobuzUserSession {
            user_id: 0,
            login: "Qobuz Subscriber".to_string(),
            user_auth_token: tok,
            label: None,
            hires: default_q >= format_ids::FLAC_24_96,
            lossless: true,
            max_streaming_quality: default_q,
        };
        *self.session.write().await = Some(session.clone());
        Ok(session)
    }

    fn map_http_status(&self, status: u16, context: &str, body: &str) -> Result<(), ProviderError> {
        match status {
            200..=299 => Ok(()),
            401 | 403 => Err(ProviderError::AuthenticationFailed(format!(
                "Qobuz {context} unauthorized (HTTP {status})"
            ))),
            404 => Err(ProviderError::AlbumNotFound(format!(
                "Qobuz {context} not found (HTTP 404)"
            ))),
            429 => Err(ProviderError::RateLimited(format!(
                "Qobuz {context} rate limited (HTTP 429)"
            ))),
            _ => Err(ProviderError::Network(format!(
                "Qobuz {context} failed with HTTP {status}: {body}"
            ))),
        }
    }

    async fn verify_token(
        &self,
        base_url: &str,
        app_id: &str,
        token: &str,
    ) -> Result<QobuzUserSession, ProviderError> {
        let url = endpoint_url(base_url, "user/get");
        let req = HttpRequest {
            method: "GET".to_string(),
            url,
            headers: vec![
                ("X-App-Id".to_string(), app_id.to_string()),
                ("X-User-Auth-Token".to_string(), token.to_string()),
            ],
            query_params: Vec::new(),
            body: None,
        };

        let resp = self.transport.execute(req).await?;
        self.map_http_status(resp.status, "user/get", &resp.body)?;

        let parsed: QobuzLoginResponse = serde_json::from_str(&resp.body)
            .map_err(|e| ProviderError::Network(format!("Failed to parse Qobuz user/get: {e}")))?;

        if parsed.status.as_deref() == Some("error") {
            return Err(ProviderError::AuthenticationFailed(
                parsed
                    .message
                    .unwrap_or_else(|| "Qobuz authentication error".to_string()),
            ));
        }

        let user = parsed.user.ok_or_else(|| {
            ProviderError::AuthenticationFailed("Missing user object in response".to_string())
        })?;
        let user_id = match user.id {
            Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0),
            Some(serde_json::Value::String(s)) => s.parse::<u64>().unwrap_or(0),
            _ => 0,
        };

        let params = user.credential.and_then(|c| c.parameters);
        Ok(QobuzUserSession {
            user_id,
            login: "Qobuz Subscriber".to_string(),
            user_auth_token: token.to_string(),
            label: None,
            hires: params.as_ref().and_then(|p| p.hires).unwrap_or(false),
            lossless: true,
            max_streaming_quality: params
                .as_ref()
                .and_then(|p| p.max_streaming_quality)
                .unwrap_or(format_ids::FLAC_16_44),
        })
    }

    async fn login_with_credentials(
        &self,
        base_url: &str,
        app_id: &str,
        username: &str,
        password: &str,
    ) -> Result<QobuzUserSession, ProviderError> {
        let url = endpoint_url(base_url, "user/login");
        let req = HttpRequest {
            method: "GET".to_string(),
            url,
            headers: vec![("X-App-Id".to_string(), app_id.to_string())],
            query_params: vec![
                ("username".to_string(), username.to_string()),
                ("password".to_string(), password.to_string()),
            ],
            body: None,
        };

        let resp = self.transport.execute(req).await?;
        self.map_http_status(resp.status, "user/login", &resp.body)?;

        let parsed: QobuzLoginResponse = serde_json::from_str(&resp.body)
            .map_err(|e| ProviderError::Network(format!("Failed to parse Qobuz user/login: {e}")))?;

        if parsed.status.as_deref() == Some("error") {
            return Err(ProviderError::AuthenticationFailed(
                parsed
                    .message
                    .unwrap_or_else(|| "Invalid username or password".to_string()),
            ));
        }

        let user = parsed.user.ok_or_else(|| {
            ProviderError::AuthenticationFailed("Missing user object".to_string())
        })?;
        let token = user.user_auth_token.ok_or_else(|| {
            ProviderError::AuthenticationFailed(
                "Missing user_auth_token in login response".to_string(),
            )
        })?;

        let user_id = match user.id {
            Some(serde_json::Value::Number(n)) => n.as_u64().unwrap_or(0),
            Some(serde_json::Value::String(s)) => s.parse::<u64>().unwrap_or(0),
            _ => 0,
        };

        let params = user.credential.and_then(|c| c.parameters);
        Ok(QobuzUserSession {
            user_id,
            login: username.to_string(),
            user_auth_token: token,
            label: None,
            hires: params.as_ref().and_then(|p| p.hires).unwrap_or(false),
            lossless: true,
            max_streaming_quality: params
                .as_ref()
                .and_then(|p| p.max_streaming_quality)
                .unwrap_or(format_ids::FLAC_16_44),
        })
    }

    fn map_album_item(&self, item: QobuzAlbumItem) -> Result<CanonicalAlbum, ProviderError> {
        let artist_name = item
            .artist
            .map(|a| a.name)
            .unwrap_or_else(|| "Unknown Artist".to_string());
        let (base_title, extracted_edition) = extract_edition_label(&item.title);
        let mut album = CanonicalAlbum::new(&base_title, &artist_name)?;

        if let Some(year) = parse_qobuz_release_year(
            item.release_date_original.as_deref(),
            item.released_at,
        ) {
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

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError> {
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

        self.map_http_status(resp.status, "catalog/search", &resp.body)?;

        let parsed: QobuzSearchResponse = serde_json::from_str(&resp.body)
            .map_err(|e| ProviderError::Network(format!("Failed to parse catalog search response: {e}")))?;

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
        self.map_http_status(resp.status, "track/get", &resp.body)?;

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
        if track.provider != ProviderKind::Qobuz {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Cannot resolve non-Qobuz track on QobuzProvider: {}",
                track.provider
            )));
        }

        let session = self.ensure_session().await?;
        let (base_url, app_id, app_secret, default_format_id) = {
            let cfg = self.config.read().await;
            (
                cfg.base_url.clone(),
                cfg.app_id().to_string(),
                cfg.app_secret().map(str::to_string),
                cfg.default_format_id,
            )
        };

        let max_quality = session.max_streaming_quality;
        let requested_format_id = if let Some(explicit_fmt) = default_format_id {
            explicit_fmt
        } else if track.format.sample_rate_hz >= 176400 && max_quality >= format_ids::FLAC_24_192 {
            format_ids::FLAC_24_192
        } else if track.format.sample_rate_hz >= 88200 && max_quality >= format_ids::FLAC_24_96 {
            format_ids::FLAC_24_96
        } else if max_quality >= format_ids::FLAC_16_44 {
            format_ids::FLAC_16_44
        } else {
            format_ids::MP3_320
        };

        let url = endpoint_url(&base_url, "track/getFileUrl");
        let mut query_params = vec![
            ("track_id".to_string(), track.external_track_id.clone()),
            ("format_id".to_string(), requested_format_id.to_string()),
            ("intent".to_string(), "stream".to_string()),
        ];

        if let Some(secret) = app_secret {
            let ts = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
                .to_string();
            let sig_payload = format!(
                "trackgetFileUrlformat_id{requested_format_id}intentstreamtrack_id{}{ts}{secret}",
                track.external_track_id
            );
            let sig = md5_hex(sig_payload.as_bytes());
            query_params.push(("request_ts".to_string(), ts));
            query_params.push(("request_sig".to_string(), sig));
        }

        let req = HttpRequest {
            method: "GET".to_string(),
            url,
            headers: vec![
                ("X-App-Id".to_string(), app_id.clone()),
                ("X-User-Auth-Token".to_string(), session.user_auth_token.clone()),
            ],
            query_params,
            body: None,
        };

        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found(
                "qobuz",
                &track.external_track_id,
            ));
        }
        self.map_http_status(resp.status, "track/getFileUrl", &resp.body)?;

        let parsed: QobuzStreamResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!("Failed to parse stream response: {e}"))
        })?;

        if parsed.status.as_deref() == Some("error") {
            return Err(ProviderError::StreamResolutionFailed(
                parsed
                    .message
                    .unwrap_or_else(|| "Stream resolution error".to_string()),
            ));
        }

        if let Some(restrictions) = parsed.restrictions {
            if !restrictions.is_empty() {
                return Err(ProviderError::DrmRestricted(format!(
                    "Track restricted: {:?}",
                    restrictions
                )));
            }
        }

        let stream_url = parsed
            .url
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| {
                ProviderError::StreamResolutionFailed("Missing stream URL".to_string())
            })?;

        let (default_sr, default_bd) =
            resolve_qobuz_format_id(parsed.format_id.unwrap_or(requested_format_id));
        let sample_rate = parsed
            .sampling_rate
            .as_ref()
            .map(normalize_sample_rate)
            .unwrap_or(default_sr);
        let bit_depth = parsed.bit_depth.unwrap_or(default_bd);

        let codec = if parsed.mime_type.as_deref() == Some("audio/mpeg") {
            AudioCodec::Mp3
        } else {
            AudioCodec::Flac
        };

        let resolved_format = AudioFormat::pcm(codec, sample_rate, bit_depth, 2)?;
        let hint_ext = if codec == AudioCodec::Mp3 {
            "mp3"
        } else {
            "flac"
        };

        Ok(ResolvedStream::http_stream(
            stream_url,
            resolved_format,
            vec![
                ("X-App-Id".to_string(), app_id),
                ("X-User-Auth-Token".to_string(), session.user_auth_token),
                ("User-Agent".to_string(), "LuminaAudio/0.1.0".to_string()),
            ],
            Some(hint_ext.to_string()),
        )
        .with_replay_gain_from_track(track))
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

/// Pure-Rust RFC 1321 MD5 digest (hex lowercase) for Qobuz request signing.
pub fn md5_hex(input: &[u8]) -> String {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20,
        5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6,
        10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];

    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut msg = input.to_vec();
    msg.push(0x80);
    while (msg.len() % 64) != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bit_len.to_le_bytes());

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    for chunk in msg.chunks_exact(64) {
        let mut m = [0u32; 16];
        for (i, word) in m.iter_mut().enumerate() {
            let off = i * 4;
            *word = u32::from_le_bytes([chunk[off], chunk[off + 1], chunk[off + 2], chunk[off + 3]]);
        }

        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i {
                0..=15 => ((b & c) | ((!b) & d), i),
                16..=31 => ((d & b) | ((!d) & c), (5 * i + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | (!d)), (7 * i) % 16),
            };
            let temp = d;
            d = c;
            c = b;
            let sum = a.wrapping_add(f).wrapping_add(K[i]).wrapping_add(m[g]);
            b = b.wrapping_add(sum.rotate_left(S[i]));
            a = temp;
        }

        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut digest = [0u8; 16];
    digest[0..4].copy_from_slice(&a0.to_le_bytes());
    digest[4..8].copy_from_slice(&b0.to_le_bytes());
    digest[8..12].copy_from_slice(&c0.to_le_bytes());
    digest[12..16].copy_from_slice(&d0.to_le_bytes());

    digest.iter().map(|b| format!("{b:02x}")).collect()
}
