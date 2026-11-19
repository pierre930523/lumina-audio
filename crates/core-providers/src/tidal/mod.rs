use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use core_db::credential::CredentialStore;
use core_types::{AudioCodec, AudioFormat, CanonicalAlbum, AlbumVersion, ProviderKind, TrackSource};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::RwLock;

use crate::error::ProviderError;
use crate::http::{endpoint_url, HttpRequest, HttpTransport, ReqwestHttpTransport};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::traits::{MusicProvider, ProviderCapabilities, ResolvedStream, SyncResult};

pub const TIDAL_CREDENTIAL_SERVICE: &str = "com.lumina.audio.tidal";
pub const TIDAL_KEY_OAUTH: &str = "oauth_tokens";

pub const DEFAULT_TIDAL_CLIENT_ID: &str = "lumina_desktop_client";
pub const DEFAULT_TIDAL_REDIRECT_URI: &str = "http://localhost:9888/callback";
pub const DEFAULT_TIDAL_AUTH_BASE_URL: &str = "https://login.tidal.com";
pub const DEFAULT_TIDAL_API_BASE_URL: &str = "https://api.tidal.com/v1";

pub fn generate_pkce_challenge() -> (String, String, String) {
    let session = start_pkce_with_params(
        DEFAULT_TIDAL_AUTH_BASE_URL,
        DEFAULT_TIDAL_CLIENT_ID,
        DEFAULT_TIDAL_REDIRECT_URI,
        "r_usr w_usr",
    );
    (session.verifier, session.challenge, session.auth_url)
}

fn start_pkce_with_params(
    auth_base_url: &str,
    client_id: &str,
    redirect_uri: &str,
    scopes: &str,
) -> TidalPkceSession {
    let mut random_bytes = [0u8; 48];
    rand::thread_rng().fill_bytes(&mut random_bytes);
    let verifier = URL_SAFE_NO_PAD.encode(random_bytes);

    let mut hasher = Sha256::new();
    hasher.update(verifier.as_bytes());
    let challenge = URL_SAFE_NO_PAD.encode(hasher.finalize());

    let enc_client = url::form_urlencoded::byte_serialize(client_id.as_bytes()).collect::<String>();
    let enc_redirect =
        url::form_urlencoded::byte_serialize(redirect_uri.as_bytes()).collect::<String>();
    let enc_scope = url::form_urlencoded::byte_serialize(scopes.as_bytes()).collect::<String>();

    let base_auth = endpoint_url(auth_base_url, "authorize");
    let auth_url = format!(
        "{base_auth}?response_type=code\
        &client_id={enc_client}\
        &redirect_uri={enc_redirect}\
        &code_challenge={challenge}\
        &code_challenge_method=S256\
        &scope={enc_scope}"
    );

    TidalPkceSession {
        verifier,
        challenge,
        auth_url,
    }
}

pub fn validate_pkce_verifier(verifier: &str) -> bool {
    let len = verifier.len();
    if !(43..=128).contains(&len) {
        return false;
    }
    verifier
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

pub fn is_token_expired(issued_at: u64, expires_in: u64, skew_sec: u64) -> bool {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    now >= (issued_at + expires_in).saturating_sub(skew_sec)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TidalPkceSession {
    pub verifier: String,
    pub challenge: String,
    pub auth_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TidalTokenResponse {
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: String,
    #[serde(default = "default_token_type")]
    pub token_type: String,
    #[serde(default = "default_expires_in")]
    pub expires_in: u64,
    #[serde(default)]
    pub user_id: u64,
    #[serde(default)]
    pub issued_at: u64,
}

fn default_token_type() -> String {
    "Bearer".to_string()
}

fn default_expires_in() -> u64 {
    3600
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TidalConfig {
    pub client_id: String,
    #[serde(default)]
    pub client_secret: Option<String>,
    pub redirect_uri: String,
    pub auth_base_url: String,
    pub api_base_url: String,
    pub scopes: String,
    pub country_code: String,
    pub audio_quality: String,
}

impl Default for TidalConfig {
    fn default() -> Self {
        Self {
            client_id: DEFAULT_TIDAL_CLIENT_ID.to_string(),
            client_secret: None,
            redirect_uri: DEFAULT_TIDAL_REDIRECT_URI.to_string(),
            auth_base_url: DEFAULT_TIDAL_AUTH_BASE_URL.to_string(),
            api_base_url: DEFAULT_TIDAL_API_BASE_URL.to_string(),
            scopes: "r_usr w_usr".to_string(),
            country_code: "US".to_string(),
            audio_quality: "HI_RES_LOSSLESS".to_string(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct TidalOAuthRawResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    token_type: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    user_id: Option<u64>,
    #[serde(default)]
    user: Option<TidalOAuthUser>,
}

#[derive(Debug, Deserialize)]
struct TidalOAuthUser {
    #[serde(rename = "userId", default)]
    user_id: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct TidalSearchAlbumsResponse {
    #[serde(default)]
    items: Vec<TidalAlbumItem>,
}

#[derive(Debug, Deserialize)]
struct TidalAlbumItem {
    #[serde(deserialize_with = "de_val_string")]
    id: String,
    title: String,
    #[serde(default)]
    artist: Option<TidalArtistRef>,
    #[serde(default)]
    artists: Vec<TidalArtistRef>,
    #[serde(rename = "releaseDate", default)]
    release_date: Option<String>,
    #[serde(default)]
    cover: Option<String>,
    #[serde(rename = "audioQuality", default)]
    audio_quality: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    upc: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TidalArtistRef {
    name: String,
}

#[derive(Debug, Deserialize)]
struct TidalTrackItem {
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
    album: Option<TidalAlbumIdRef>,
}

#[derive(Debug, Deserialize)]
struct TidalAlbumIdRef {
    #[serde(deserialize_with = "de_val_string")]
    id: String,
}

#[derive(Debug, Deserialize)]
struct TidalPlaybackInfo {
    #[serde(rename = "audioQuality", default)]
    audio_quality: Option<String>,
    #[serde(rename = "bitDepth", default)]
    bit_depth: Option<u8>,
    #[serde(rename = "sampleRate", default)]
    sample_rate: Option<u32>,
    #[serde(rename = "manifestMimeType", default)]
    manifest_mime_type: Option<String>,
    #[serde(default)]
    manifest: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    urls: Vec<String>,
    #[serde(rename = "encryptionType", default)]
    encryption_type: Option<String>,
    #[serde(rename = "trackReplayGain", default)]
    track_replay_gain: Option<f64>,
    #[serde(rename = "albumReplayGain", default)]
    album_replay_gain: Option<f64>,
    #[serde(rename = "trackPeakAmplitude", default)]
    track_peak_amplitude: Option<f64>,
    #[serde(rename = "albumPeakAmplitude", default)]
    album_peak_amplitude: Option<f64>,
}

#[derive(Debug, Deserialize)]
struct TidalBtsManifest {
    #[serde(rename = "mimeType", default)]
    mime_type: Option<String>,
    #[serde(default)]
    codecs: Option<String>,
    #[serde(default)]
    urls: Vec<String>,
    #[serde(rename = "encryptionType", default)]
    encryption_type: Option<String>,
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

pub struct TidalProvider {
    config: RwLock<TidalConfig>,
    transport: Arc<dyn HttpTransport>,
    credential_store: Option<Arc<dyn CredentialStore>>,
    active_tokens: RwLock<Option<TidalTokenResponse>>,
    pending_verifier: RwLock<Option<String>>,
}

impl TidalProvider {
    pub fn new(credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::live(TidalConfig::default(), credential_store)
    }

    pub fn live(
        config: TidalConfig,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self::with_config(config, Arc::new(ReqwestHttpTransport::new()), credential_store)
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
        }
    }

    pub async fn start_pkce_login(&self) -> TidalPkceSession {
        let cfg = self.config.read().await.clone();
        let session = start_pkce_with_params(
            &cfg.auth_base_url,
            &cfg.client_id,
            &cfg.redirect_uri,
            &cfg.scopes,
        );
        *self.pending_verifier.write().await = Some(session.verifier.clone());
        session
    }

    pub async fn pending_pkce_verifier(&self) -> Option<String> {
        self.pending_verifier.read().await.clone()
    }

    pub async fn exchange_pkce_code(
        &self,
        code: &str,
        code_verifier: &str,
    ) -> Result<TidalTokenResponse, ProviderError> {
        if code.trim().is_empty() {
            return Err(ProviderError::AuthenticationFailed(
                "Tidal authorization code cannot be empty".to_string(),
            ));
        }
        if !validate_pkce_verifier(code_verifier) {
            return Err(ProviderError::AuthenticationFailed(
                "Invalid Tidal PKCE code_verifier".to_string(),
            ));
        }

        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.auth_base_url, "token");
        let mut pairs: Vec<(&str, &str)> = vec![
            ("grant_type", "authorization_code"),
            ("client_id", &cfg.client_id),
            ("code", code.trim()),
            ("redirect_uri", &cfg.redirect_uri),
            ("code_verifier", code_verifier),
        ];
        if let Some(ref sec) = cfg.client_secret {
            pairs.push(("client_secret", sec));
        }

        let req = HttpRequest::post_form(url, &pairs);
        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 || resp.status == 400 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Tidal token exchange failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Tidal token endpoint error (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let raw: TidalOAuthRawResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::AuthenticationFailed(format!("Invalid Tidal token response: {e}"))
        })?;

        let tokens = TidalTokenResponse {
            access_token: raw.access_token,
            refresh_token: raw.refresh_token.unwrap_or_default(),
            token_type: raw.token_type.unwrap_or_else(|| "Bearer".to_string()),
            expires_in: raw.expires_in.unwrap_or(3600),
            user_id: raw
                .user_id
                .or_else(|| raw.user.and_then(|u| u.user_id))
                .unwrap_or(0),
            issued_at: now_secs(),
        };

        self.login_with_tokens(tokens.clone()).await?;
        *self.pending_verifier.write().await = None;
        Ok(tokens)
    }

    pub async fn refresh_tokens(&self) -> Result<TidalTokenResponse, ProviderError> {
        let current = self.load_any_tokens().await?;
        if current.refresh_token.trim().is_empty() {
            return Err(ProviderError::Unauthenticated(
                "Tidal refresh token missing".to_string(),
            ));
        }

        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.auth_base_url, "token");
        let mut pairs: Vec<(&str, &str)> = vec![
            ("grant_type", "refresh_token"),
            ("client_id", &cfg.client_id),
            ("refresh_token", &current.refresh_token),
        ];
        if let Some(ref sec) = cfg.client_secret {
            pairs.push(("client_secret", sec));
        }

        let req = HttpRequest::post_form(url, &pairs);
        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 || resp.status == 400 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Tidal token refresh failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Tidal token refresh error (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let raw: TidalOAuthRawResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::AuthenticationFailed(format!("Invalid Tidal refresh response: {e}"))
        })?;

        let tokens = TidalTokenResponse {
            access_token: raw.access_token,
            refresh_token: raw
                .refresh_token
                .filter(|s| !s.trim().is_empty())
                .unwrap_or(current.refresh_token),
            token_type: raw.token_type.unwrap_or(current.token_type),
            expires_in: raw.expires_in.unwrap_or(3600),
            user_id: raw
                .user_id
                .or_else(|| raw.user.and_then(|u| u.user_id))
                .unwrap_or(current.user_id),
            issued_at: now_secs(),
        };

        self.login_with_tokens(tokens.clone()).await?;
        Ok(tokens)
    }

    pub async fn login_with_tokens(
        &self,
        mut tokens: TidalTokenResponse,
    ) -> Result<(), ProviderError> {
        if tokens.issued_at == 0 {
            tokens.issued_at = now_secs();
        }
        if let Some(ref store) = self.credential_store {
            let secret = serde_json::to_string(&tokens).map_err(|e| {
                ProviderError::Credential(core_db::credential::CredentialError::System(
                    e.to_string(),
                ))
            })?;
            store
                .set_secret(TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH, &secret)
                .await?;
        }

        let mut w = self.active_tokens.write().await;
        *w = Some(tokens);
        Ok(())
    }

    async fn load_any_tokens(&self) -> Result<TidalTokenResponse, ProviderError> {
        if let Some(tok) = self.active_tokens.read().await.clone() {
            return Ok(tok);
        }

        if let Some(ref store) = self.credential_store {
            if let Some(secret) = store
                .get_secret(TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH)
                .await?
            {
                let tokens: TidalTokenResponse = serde_json::from_str(&secret).map_err(|e| {
                    ProviderError::Credential(core_db::credential::CredentialError::System(
                        e.to_string(),
                    ))
                })?;
                *self.active_tokens.write().await = Some(tokens.clone());
                return Ok(tokens);
            }
        }

        Err(ProviderError::not_authenticated("tidal"))
    }

    async fn get_valid_access_token(&self) -> Result<String, ProviderError> {
        let tok = self.load_any_tokens().await?;
        if !is_token_expired(tok.issued_at, tok.expires_in, 60) {
            return Ok(tok.access_token);
        }
        if !tok.refresh_token.trim().is_empty() {
            let refreshed = self.refresh_tokens().await?;
            return Ok(refreshed.access_token);
        }
        Err(ProviderError::Unauthenticated(
            "Tidal access token expired: refresh required".to_string(),
        ))
    }

    fn map_http_error(&self, status: u16, context: &str, body: &str) -> Result<(), ProviderError> {
        match status {
            200..=299 => Ok(()),
            401 | 403 => Err(ProviderError::AuthenticationFailed(format!(
                "Tidal {context} unauthorized (HTTP {status})"
            ))),
            404 => Err(ProviderError::AlbumNotFound(format!(
                "Tidal {context} not found (HTTP 404)"
            ))),
            429 => Err(ProviderError::RateLimited(format!(
                "Tidal {context} rate limited (HTTP 429)"
            ))),
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

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let token = self.get_valid_access_token().await?;
        let cfg = self.config.read().await.clone();
        let url = endpoint_url(&cfg.api_base_url, "search/albums");

        let req = HttpRequest::get(url)
            .with_header("Authorization", format!("Bearer {token}"))
            .with_query("query", query)
            .with_query("limit", limit.to_string())
            .with_query("countryCode", &cfg.country_code);

        let resp = self.transport.execute(req).await?;
        self.map_http_error(resp.status, "search/albums", &resp.body)?;

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
        self.map_http_error(resp.status, "tracks/get", &resp.body)?;

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
        if track.provider != ProviderKind::Tidal {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Cannot resolve non-Tidal track on TidalProvider: {}",
                track.provider
            )));
        }

        let access_token = self.get_valid_access_token().await?;
        let cfg = self.config.read().await.clone();
        let auth_header = format!("Bearer {access_token}");

        let url = endpoint_url(
            &cfg.api_base_url,
            &format!("tracks/{}/playbackinfo", track.external_track_id),
        );
        let req = HttpRequest::get(url)
            .with_header("Authorization", auth_header.clone())
            .with_query("audioquality", &cfg.audio_quality)
            .with_query("playbackmode", "STREAM")
            .with_query("assetpresentation", "FULL")
            .with_query("countryCode", &cfg.country_code);

        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found(
                "tidal",
                &track.external_track_id,
            ));
        }
        self.map_http_error(resp.status, "tracks/playbackinfo", &resp.body)?;

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

        let mut codec_override: Option<AudioCodec> = None;
        let mut hint_ext: Option<String> = None;
        let stream_url = if let Some(u) = info.url.filter(|s| !s.trim().is_empty()) {
            u
        } else if let Some(u) = info.urls.into_iter().find(|s| !s.trim().is_empty()) {
            u
        } else if let Some(manifest_b64) = info.manifest.filter(|s| !s.trim().is_empty()) {
            let mime = info.manifest_mime_type.as_deref().unwrap_or("");
            if mime.eq_ignore_ascii_case("application/dash+xml") {
                return Err(ProviderError::DrmRestricted(
                    "Encrypted/segmented Tidal DASH manifest is not directly streamable".to_string(),
                ));
            }
            let decoded = STANDARD.decode(manifest_b64.trim()).map_err(|e| {
                ProviderError::StreamResolutionFailed(format!(
                    "Failed to decode Tidal BTS manifest base64: {e}"
                ))
            })?;
            let bts: TidalBtsManifest = serde_json::from_slice(&decoded).map_err(|e| {
                ProviderError::StreamResolutionFailed(format!(
                    "Failed to parse Tidal BTS manifest JSON: {e}"
                ))
            })?;
            if let Some(ref enc) = bts.encryption_type {
                if !enc.trim().is_empty() && !enc.eq_ignore_ascii_case("NONE") {
                    return Err(ProviderError::DrmRestricted(format!(
                        "Tidal BTS manifest encrypted ({enc})"
                    )));
                }
            }
            if let Some(ref mt) = bts.mime_type {
                if mt.contains("mp4") || bts.codecs.as_deref() == Some("mp4a.40.2") {
                    codec_override = Some(AudioCodec::Aac);
                    hint_ext = Some("m4a".to_string());
                } else if mt.contains("flac") {
                    codec_override = Some(AudioCodec::Flac);
                    hint_ext = Some("flac".to_string());
                }
            }
            bts.urls
                .into_iter()
                .find(|s| !s.trim().is_empty())
                .ok_or_else(|| {
                    ProviderError::StreamResolutionFailed(
                        "Tidal BTS manifest contains no stream URLs".to_string(),
                    )
                })?
        } else {
            return Err(ProviderError::StreamResolutionFailed(
                "Tidal playbackinfo missing both stream URL and manifest".to_string(),
            ));
        };

        let mut format = audio_format_for_tidal_quality(
            info.audio_quality.as_deref(),
            info.sample_rate,
            info.bit_depth,
        )?;
        if let Some(c) = codec_override {
            let bd = if c == AudioCodec::Aac { 16 } else { format.bit_depth };
            format = AudioFormat::pcm(c, format.sample_rate_hz, bd, format.channels)?;
        }
        if hint_ext.is_none() {
            hint_ext = Some(format.codec.default_file_extension().to_string());
        }

        let mut resolved = ResolvedStream::http_stream(
            stream_url,
            format,
            vec![("Authorization".to_string(), auth_header)],
            hint_ext,
        );
        resolved = resolved
            .with_replay_gain(
                info.track_replay_gain,
                info.album_replay_gain,
                info.track_peak_amplitude,
                info.album_peak_amplitude,
            )
            .with_replay_gain_from_track(track);

        Ok(resolved)
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        Ok(SyncResult::default())
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn audio_format_for_tidal_quality(
    quality: Option<&str>,
    sample_rate_override: Option<u32>,
    bit_depth_override: Option<u8>,
) -> Result<AudioFormat, ProviderError> {
    let (default_codec, default_sr, default_bd) = match quality.unwrap_or("LOSSLESS") {
        "HI_RES_LOSSLESS" | "HI_RES" => (AudioCodec::Flac, 96000, 24),
        "LOSSLESS" => (AudioCodec::Flac, 44100, 16),
        "HIGH" | "LOW" => (AudioCodec::Aac, 44100, 16),
        _ => (AudioCodec::Flac, 44100, 16),
    };
    let sr = sample_rate_override.unwrap_or(default_sr);
    let bd = bit_depth_override.unwrap_or(default_bd);
    Ok(AudioFormat::pcm(default_codec, sr, bd, 2)?)
}
