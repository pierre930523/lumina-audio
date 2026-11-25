use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use core_db::credential::CredentialStore;
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ManifestFormat, NormalizedLoudness,
    ProviderKind, StreamKey, StreamProviderCapabilities, StreamSourceSpec, TrackSource,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::{Mutex, RwLock};

use crate::error::ProviderError;
use crate::http::{endpoint_url, HttpRequest, HttpTransport, ReqwestHttpTransport};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::traits::{
    extract_expire_at_from_url, validate_stream_key, MusicProvider, ProviderCapabilities,
    ResolvedStream, StreamResolver, SyncResult,
};

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
    refresh_lock: Mutex<()>,
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
            refresh_lock: Mutex::new(()),
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
        self.refresh_tokens_single_flight(None, true).await
    }

    async fn refresh_tokens_single_flight(
        &self,
        stale_access_token: Option<&str>,
        force: bool,
    ) -> Result<TidalTokenResponse, ProviderError> {
        let _guard = self.refresh_lock.lock().await;
        let current = self.load_any_tokens().await?;

        // Double-checked Single-Flight: if another caller already refreshed
        // while we waited on the mutex, reuse the fresh token directly.
        if !is_token_expired(current.issued_at, current.expires_in, 60) {
            if !force || stale_access_token.is_some_and(|stale| stale != current.access_token) {
                return Ok(current);
            }
        }

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
            let refreshed = self.refresh_tokens_single_flight(None, false).await?;
            return Ok(refreshed.access_token);
        }
        Err(ProviderError::Unauthenticated(
            "Tidal access token expired: refresh required".to_string(),
        ))
    }

    fn map_http_error(&self, status: u16, context: &str, body: &str) -> Result<(), ProviderError> {
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

    async fn fetch_playback_info(
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

        Ok((info, auth_header))
    }
}

struct TidalBtsDecoded {
    stream_url: String,
    codec_override: Option<AudioCodec>,
    hint_ext: Option<String>,
    mime_type: Option<String>,
}

fn decode_base64_padded(raw: &str) -> Result<Vec<u8>, base64::DecodeError> {
    let mut cleaned: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
    let rem = cleaned.len() % 4;
    if rem != 0 {
        cleaned.extend(std::iter::repeat_n('=', 4 - rem));
    }
    STANDARD.decode(cleaned)
}

fn parse_tidal_bts_manifest(manifest_b64: &str) -> Result<TidalBtsDecoded, ProviderError> {
    let decoded = decode_base64_padded(manifest_b64).map_err(|e| {
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
    let mut codec_override = None;
    let mut hint_ext = None;
    if let Some(ref mt) = bts.mime_type {
        if mt.contains("mp4")
            || mt.contains("aac")
            || bts.codecs.as_deref().is_some_and(|c| c.starts_with("mp4a"))
        {
            codec_override = Some(AudioCodec::Aac);
            hint_ext = Some("m4a".to_string());
        } else if mt.contains("flac") {
            codec_override = Some(AudioCodec::Flac);
            hint_ext = Some("flac".to_string());
        }
    }
    let stream_url = bts
        .urls
        .into_iter()
        .find(|s| !s.trim().is_empty())
        .ok_or_else(|| {
            ProviderError::StreamResolutionFailed(
                "Tidal BTS manifest contains no stream URLs".to_string(),
            )
        })?;
    Ok(TidalBtsDecoded {
        stream_url,
        codec_override,
        hint_ext,
        mime_type: bts.mime_type,
    })
}

fn has_dash_content_protection(mpd_xml: &str) -> bool {
    let lower = mpd_xml.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    let needle = "contentprotection";
    let mut idx = 0;
    while let Some(pos) = lower[idx..].find(needle) {
        let abs = idx + pos;
        let before_is_tag = abs > 0 && (bytes[abs - 1] == b'<' || bytes[abs - 1] == b':');
        let after = abs + needle.len();
        let after_ok = after >= bytes.len()
            || bytes[after].is_ascii_whitespace()
            || bytes[after] == b'>'
            || bytes[after] == b'/';
        if before_is_tag && after_ok {
            return true;
        }
        idx = after;
    }
    false
}

fn tidal_audio_quality(quality_key: &str, default_quality: &str) -> Result<String, ProviderError> {
    let normalized = quality_key.trim().to_ascii_lowercase();
    let mapped = match normalized.as_str() {
        "" | "default" | "auto" => default_quality.to_string(),
        "hi_res_lossless" | "hi_res" | "hires" | "hi_res_192" | "hi_res_96" | "max" | "best" => {
            "HI_RES_LOSSLESS".to_string()
        }
        "lossless" | "flac" | "cd" => "LOSSLESS".to_string(),
        "high" | "aac_320" | "320" => "HIGH".to_string(),
        "low" | "aac_96" => "LOW".to_string(),
        _ => {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Unsupported Tidal quality key: '{quality_key}'"
            )));
        }
    };
    Ok(mapped)
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

        let audio_quality = self.config.read().await.audio_quality.clone();
        let (info, auth_header) = self
            .fetch_playback_info(&track.external_track_id, &audio_quality)
            .await?;

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
            let bts = parse_tidal_bts_manifest(&manifest_b64)?;
            codec_override = bts.codec_override;
            hint_ext = bts.hint_ext;
            bts.stream_url
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

#[async_trait]
impl StreamResolver for TidalProvider {
    fn provider_id(&self) -> &'static str {
        "tidal"
    }

    fn capabilities(&self) -> StreamProviderCapabilities {
        StreamProviderCapabilities::tidal()
    }

    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError> {
        validate_stream_key("tidal", key)?;
        let default_quality = self.config.read().await.audio_quality.clone();
        let requested_quality = tidal_audio_quality(&key.quality_key, &default_quality)?;
        let fallback_tiers = tidal_quality_fallback_chain(&requested_quality);

        let mut last_err: Option<ProviderError> = None;
        for tier in fallback_tiers {
            match self.resolve_source_for_quality(key, tier).await {
                Ok(spec) => return Ok(spec),
                Err(err) => {
                    let can_downgrade = matches!(
                        err,
                        ProviderError::StreamResolutionFailed(_)
                            | ProviderError::UnsupportedFormat(_)
                    );
                    if !can_downgrade {
                        return Err(err);
                    }
                    last_err = Some(err);
                }
            }
        }

        Err(last_err.unwrap_or_else(|| {
            ProviderError::StreamResolutionFailed(format!(
                "Tidal failed to resolve track '{}' at any quality tier",
                key.track_id
            ))
        }))
    }
}

fn tidal_quality_fallback_chain(requested: &str) -> Vec<&'static str> {
    match requested {
        "HI_RES_LOSSLESS" | "HI_RES" => vec!["HI_RES_LOSSLESS", "LOSSLESS", "HIGH", "LOW"],
        "LOSSLESS" => vec!["LOSSLESS", "HIGH", "LOW"],
        "HIGH" => vec!["HIGH", "LOW"],
        "LOW" => vec!["LOW"],
        _ => vec!["LOSSLESS", "HIGH", "LOW"],
    }
}

impl TidalProvider {
    async fn resolve_source_for_quality(
        &self,
        key: &StreamKey,
        requested_quality: &str,
    ) -> Result<StreamSourceSpec, ProviderError> {
        let (info, auth_header) = self
            .fetch_playback_info(&key.track_id, requested_quality)
            .await?;

        let headers = BTreeMap::from([("Authorization".to_string(), auth_header)]);
        let loudness = info.track_replay_gain.filter(|g| g.is_finite()).map(|g| {
            NormalizedLoudness::from_replay_gain(
                g as f32,
                info.track_peak_amplitude.filter(|p| p.is_finite()).map(|p| p as f32),
            )
        });
        let album_loudness = info.album_replay_gain.filter(|g| g.is_finite()).map(|g| {
            NormalizedLoudness::from_replay_gain(
                g as f32,
                info.album_peak_amplitude.filter(|p| p.is_finite()).map(|p| p as f32),
            )
        });

        if let Some(u) = info
            .url
            .filter(|s| !s.trim().is_empty())
            .or_else(|| info.urls.into_iter().find(|s| !s.trim().is_empty()))
        {
            let format = audio_format_for_tidal_quality(
                info.audio_quality.as_deref().or(Some(requested_quality)),
                info.sample_rate,
                info.bit_depth,
            )?;
            let hint_ext = format.codec.default_file_extension().to_string();
            let mime_type = if format.codec == AudioCodec::Aac {
                "audio/mp4"
            } else {
                "audio/flac"
            };
            let expire_at = extract_expire_at_from_url(&u);
            return Ok(StreamSourceSpec::DirectRange {
                key: key.clone(),
                url: u,
                headers,
                content_length: None,
                bitrate_bps: None,
                mime_type: Some(mime_type.to_string()),
                hint_extension: Some(hint_ext),
                expire_at,
                init_range_end: None,
                index_range_start: None,
                index_range_end: None,
                loudness,
                album_loudness,
            });
        }

        let manifest_b64 = info
            .manifest
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| {
                ProviderError::StreamResolutionFailed(
                    "Tidal playbackinfo missing both stream URL and manifest".to_string(),
                )
            })?;

        let manifest_mime = info.manifest_mime_type.as_deref().unwrap_or("").trim();
        if manifest_mime.eq_ignore_ascii_case("application/dash+xml") {
            let decoded = decode_base64_padded(&manifest_b64).map_err(|e| {
                ProviderError::StreamResolutionFailed(format!(
                    "Failed to decode Tidal DASH manifest base64: {e}"
                ))
            })?;
            let decoded_mpd_xml = String::from_utf8(decoded).map_err(|e| {
                ProviderError::StreamResolutionFailed(format!(
                    "Tidal DASH manifest is not valid UTF-8 XML: {e}"
                ))
            })?;

            if has_dash_content_protection(&decoded_mpd_xml) {
                return Err(ProviderError::DrmRestricted(
                    "Tidal DASH manifest contains ContentProtection DRM".to_string(),
                ));
            }

            return Ok(StreamSourceSpec::SegmentedManifest {
                key: key.clone(),
                manifest_url_or_xml: decoded_mpd_xml,
                format: ManifestFormat::Dash,
                headers,
                bitrate_bps: None,
                mime_type: Some("application/dash+xml".to_string()),
                expire_at: None,
                loudness,
                album_loudness,
            });
        }

        let bts = parse_tidal_bts_manifest(&manifest_b64)?;
        let format = audio_format_for_tidal_quality(
            info.audio_quality.as_deref().or(Some(requested_quality)),
            info.sample_rate,
            info.bit_depth,
        )?;
        let effective_codec = bts.codec_override.unwrap_or(format.codec);
        let hint_ext = bts
            .hint_ext
            .unwrap_or_else(|| effective_codec.default_file_extension().to_string());
        let mime_type = bts.mime_type.or_else(|| {
            Some(
                if effective_codec == AudioCodec::Aac {
                    "audio/mp4"
                } else {
                    "audio/flac"
                }
                .to_string(),
            )
        });
        let expire_at = extract_expire_at_from_url(&bts.stream_url);

        Ok(StreamSourceSpec::DirectRange {
            key: key.clone(),
            url: bts.stream_url,
            headers,
            content_length: None,
            bitrate_bps: None,
            mime_type,
            hint_extension: Some(hint_ext),
            expire_at,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness,
            album_loudness,
        })
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::{HttpResponse, MockHttpTransport};

    async fn make_logged_in_tidal(transport: Arc<MockHttpTransport>) -> TidalProvider {
        let provider = TidalProvider::with_config(TidalConfig::default(), transport, None);
        provider
            .login_with_tokens(TidalTokenResponse {
                access_token: "tidal_tok_abc".to_string(),
                refresh_token: "tidal_ref_abc".to_string(),
                token_type: "Bearer".to_string(),
                expires_in: 3600,
                user_id: 42,
                issued_at: now_secs(),
            })
            .await
            .unwrap();
        provider
    }

    #[tokio::test]
    async fn test_tidal_stream_resolver_bts_manifest_direct_range() {
        let transport = Arc::new(MockHttpTransport::new());
        transport
            .register_fn("tracks/777/playbackinfo", |req| {
                let quality = req
                    .query_params
                    .iter()
                    .find(|(k, _)| k == "audioquality")
                    .map(|(_, v)| v.as_str())
                    .unwrap_or("");
                let manifest_json = if quality == "HIGH" {
                    serde_json::json!({
                        "mimeType": "audio/mp4",
                        "codecs": "mp4a.40.2",
                        "encryptionType": "NONE",
                        "urls": ["https://sp-cf.tidal.com/777-high.m4a"]
                    })
                } else {
                    serde_json::json!({
                        "mimeType": "audio/flac",
                        "codecs": "flac",
                        "encryptionType": "NONE",
                        "urls": ["https://sp-cf.tidal.com/777-lossless.flac"]
                    })
                };
                let b64 = STANDARD.encode(manifest_json.to_string().as_bytes());
                Ok(HttpResponse::ok_json(
                    serde_json::json!({
                        "audioQuality": quality,
                        "sampleRate": 44100,
                        "bitDepth": 16,
                        "manifestMimeType": "application/vnd.tidal.bts",
                        "manifest": b64
                    })
                    .to_string(),
                ))
            })
            .await;

        let provider = make_logged_in_tidal(transport).await;
        assert_eq!(StreamResolver::provider_id(&provider), "tidal");
        assert_eq!(
            StreamResolver::capabilities(&provider),
            StreamProviderCapabilities::tidal()
        );

        let flac_spec = provider
            .resolve_source(&StreamKey::new("tidal", "777", "LOSSLESS"))
            .await
            .unwrap();
        match flac_spec {
            StreamSourceSpec::DirectRange {
                url,
                headers,
                mime_type,
                hint_extension,
                ..
            } => {
                assert_eq!(url, "https://sp-cf.tidal.com/777-lossless.flac");
                assert_eq!(
                    headers.get("Authorization").map(String::as_str),
                    Some("Bearer tidal_tok_abc")
                );
                assert_eq!(mime_type.as_deref(), Some("audio/flac"));
                assert_eq!(hint_extension.as_deref(), Some("flac"));
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }

        let high_spec = provider
            .resolve_source(&StreamKey::new("tidal", "777", "HIGH"))
            .await
            .unwrap();
        match high_spec {
            StreamSourceSpec::DirectRange {
                url,
                mime_type,
                hint_extension,
                ..
            } => {
                assert_eq!(url, "https://sp-cf.tidal.com/777-high.m4a");
                assert_eq!(mime_type.as_deref(), Some("audio/mp4"));
                assert_eq!(hint_extension.as_deref(), Some("m4a"));
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn test_tidal_stream_resolver_unencrypted_dash_segmented_manifest() {
        let mpd_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="0" codecs="flac" audioSamplingRate="192000">
        <SegmentTemplate initialization="https://cdn.tidal.com/init.mp4" media="https://cdn.tidal.com/seg-$Number$.m4s" startNumber="1"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
        let mpd_b64 = STANDARD.encode(mpd_xml.as_bytes());

        let transport = Arc::new(MockHttpTransport::new());
        transport
            .register_exact(
                "tracks/888/playbackinfo",
                HttpResponse::ok_json(
                    serde_json::json!({
                        "audioQuality": "HI_RES_LOSSLESS",
                        "sampleRate": 192000,
                        "bitDepth": 24,
                        "manifestMimeType": "application/dash+xml",
                        "manifest": mpd_b64
                    })
                    .to_string(),
                ),
            )
            .await;

        let provider = make_logged_in_tidal(transport).await;
        let key = StreamKey::new("tidal", "888", "HI_RES_LOSSLESS");
        let spec = provider.resolve_source(&key).await.unwrap();
        match spec {
            StreamSourceSpec::SegmentedManifest {
                key: k,
                manifest_url_or_xml,
                format,
                headers,
                mime_type,
                ..
            } => {
                assert_eq!(k, key);
                assert_eq!(format, ManifestFormat::Dash);
                assert_eq!(manifest_url_or_xml, mpd_xml);
                assert_eq!(
                    headers.get("Authorization").map(String::as_str),
                    Some("Bearer tidal_tok_abc")
                );
                assert_eq!(mime_type.as_deref(), Some("application/dash+xml"));
            }
            other => panic!("expected SegmentedManifest, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn test_tidal_stream_resolver_drm_dash_rejected() {
        let drm_mpd = r#"<MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation/></AdaptationSet></Period></MPD>"#;
        let drm_b64 = STANDARD.encode(drm_mpd.as_bytes());

        let namespaced_drm_mpd = r#"<MPD><Period><AdaptationSet><cenc:ContentProtection value="cenc"/></AdaptationSet></Period></MPD>"#;
        let namespaced_b64 = STANDARD.encode(namespaced_drm_mpd.as_bytes());

        let transport = Arc::new(MockHttpTransport::new());
        transport
            .register_exact(
                "tracks/666/playbackinfo",
                HttpResponse::ok_json(
                    serde_json::json!({
                        "audioQuality": "HI_RES_LOSSLESS",
                        "manifestMimeType": "application/dash+xml",
                        "manifest": drm_b64
                    })
                    .to_string(),
                ),
            )
            .await;
        transport
            .register_exact(
                "tracks/667/playbackinfo",
                HttpResponse::ok_json(
                    serde_json::json!({
                        "audioQuality": "HI_RES_LOSSLESS",
                        "manifestMimeType": "application/dash+xml",
                        "manifest": namespaced_b64
                    })
                    .to_string(),
                ),
            )
            .await;

        let provider = make_logged_in_tidal(transport).await;
        let err1 = provider
            .resolve_source(&StreamKey::new("tidal", "666", "HI_RES_LOSSLESS"))
            .await
            .unwrap_err();
        assert!(matches!(err1, ProviderError::DrmRestricted(_)));

        let err2 = provider
            .resolve_source(&StreamKey::new("tidal", "667", "HI_RES_LOSSLESS"))
            .await
            .unwrap_err();
        assert!(matches!(err2, ProviderError::DrmRestricted(_)));
    }

    #[tokio::test]
    async fn test_tidal_phase3_401_single_flight_refresh_403_split_and_loudness() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let transport = Arc::new(MockHttpTransport::new());
        let token_refresh_calls = Arc::new(AtomicUsize::new(0));
        let refresh_counter = token_refresh_calls.clone();

        transport
            .register_fn("token", move |_req| {
                refresh_counter.fetch_add(1, Ordering::SeqCst);
                Ok(HttpResponse::ok_json(
                    serde_json::json!({
                        "access_token": "tidal_fresh_tok_2",
                        "refresh_token": "tidal_ref_2",
                        "token_type": "Bearer",
                        "expires_in": 3600,
                        "user_id": 42
                    })
                    .to_string(),
                ))
            })
            .await;

        transport
            .register_fn("tracks/501/playbackinfo", |req| {
                let auth = req
                    .headers
                    .iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
                    .map(|(_, v)| v.as_str())
                    .unwrap_or("");
                if auth == "Bearer tidal_tok_abc" {
                    return Ok(HttpResponse {
                        status: 401,
                        headers: vec![],
                        body: r#"{"userMessage":"Expired access token"}"#.to_string(),
                    });
                }
                let manifest_json = serde_json::json!({
                    "mimeType": "audio/flac",
                    "codecs": "flac",
                    "encryptionType": "NONE",
                    "urls": ["https://sp-cf.tidal.com/501-refreshed.flac"]
                });
                let b64 = STANDARD.encode(manifest_json.to_string().as_bytes());
                Ok(HttpResponse::ok_json(
                    serde_json::json!({
                        "audioQuality": "LOSSLESS",
                        "sampleRate": 44100,
                        "bitDepth": 16,
                        "trackReplayGain": -6.5,
                        "trackPeakAmplitude": 0.92,
                        "albumReplayGain": -5.0,
                        "albumPeakAmplitude": 0.98,
                        "manifestMimeType": "application/vnd.tidal.bts",
                        "manifest": b64
                    })
                    .to_string(),
                ))
            })
            .await;

        transport
            .register_exact(
                "tracks/503/playbackinfo",
                HttpResponse {
                    status: 403,
                    headers: vec![],
                    body: r#"{"userMessage":"Forbidden stream"}"#.to_string(),
                },
            )
            .await;

        let provider = Arc::new(make_logged_in_tidal(transport).await);

        // Concurrent 401s must deduplicate token refresh to exactly 1 /token call.
        let p1 = provider.clone();
        let p2 = provider.clone();
        let key1 = StreamKey::new("tidal", "501", "LOSSLESS");
        let key2 = key1.clone();
        let (r1, r2) = tokio::join!(
            p1.resolve_source(&key1),
            p2.resolve_source(&key2),
        );
        assert_eq!(token_refresh_calls.load(Ordering::SeqCst), 1);

        let spec = r1.unwrap();
        assert!(r2.is_ok());
        match spec {
            StreamSourceSpec::DirectRange {
                url,
                loudness,
                album_loudness,
                ..
            } => {
                assert_eq!(url, "https://sp-cf.tidal.com/501-refreshed.flac");
                let track_l = loudness.expect("track loudness should be populated");
                assert!((track_l.gain_db - (-2.5)).abs() < 1e-4);
                assert!((track_l.peak - 0.92).abs() < 1e-4);
                let album_l = album_loudness.expect("album loudness should be populated");
                assert!((album_l.gain_db - (-1.0)).abs() < 1e-4);
                assert!((album_l.peak - 0.98).abs() < 1e-4);
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }

        // HTTP 403 must NOT map to AuthenticationFailed.
        let err_403 = provider
            .resolve_source(&StreamKey::new("tidal", "503", "LOSSLESS"))
            .await
            .unwrap_err();
        assert!(matches!(err_403, ProviderError::StreamResolutionFailed(_)));
    }

    #[tokio::test]
    async fn test_tidal_quality_downgrade_and_region_restricted_451() {
        let transport = Arc::new(MockHttpTransport::new());
        transport
            .register_fn("tracks/777/playbackinfo", |req| {
                let quality = req
                    .query_params
                    .iter()
                    .find(|(k, _)| k == "audioquality")
                    .map(|(_, v)| v.as_str())
                    .unwrap_or("");
                if quality == "HI_RES_LOSSLESS" {
                    return Ok(HttpResponse {
                        status: 403,
                        headers: vec![],
                        body: r#"{"userMessage":"Tier not entitled"}"#.to_string(),
                    });
                }
                let manifest_json = serde_json::json!({
                    "mimeType": "audio/flac",
                    "codecs": "flac",
                    "encryptionType": "NONE",
                    "urls": ["https://sp-cf.tidal.com/777-lossless.flac"]
                });
                let b64 = STANDARD.encode(manifest_json.to_string().as_bytes());
                Ok(HttpResponse::ok_json(
                    serde_json::json!({
                        "audioQuality": "LOSSLESS",
                        "sampleRate": 44100,
                        "bitDepth": 16,
                        "manifestMimeType": "application/vnd.tidal.bts",
                        "manifest": b64
                    })
                    .to_string(),
                ))
            })
            .await;

        transport
            .register_exact(
                "tracks/451/playbackinfo",
                HttpResponse {
                    status: 451,
                    headers: vec![],
                    body: r#"{"userMessage":"Not available in your country"}"#.to_string(),
                },
            )
            .await;

        let provider = make_logged_in_tidal(transport).await;

        // HI_RES_LOSSLESS downgrades cleanly to LOSSLESS
        let spec = provider
            .resolve_source(&StreamKey::new("tidal", "777", "HI_RES_LOSSLESS"))
            .await
            .unwrap();
        match spec {
            StreamSourceSpec::DirectRange { url, .. } => {
                assert_eq!(url, "https://sp-cf.tidal.com/777-lossless.flac");
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }

        // HTTP 451 maps directly to RegionRestricted without downgrading
        let err_451 = provider
            .resolve_source(&StreamKey::new("tidal", "451", "LOSSLESS"))
            .await
            .unwrap_err();
        assert!(matches!(err_451, ProviderError::RegionRestricted(_)));
    }
}
