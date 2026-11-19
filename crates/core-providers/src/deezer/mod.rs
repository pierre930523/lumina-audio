use std::sync::Arc;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::error::ProviderError;
use crate::http::{endpoint_url, HttpRequest, HttpTransport, ReqwestHttpTransport};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::traits::{MusicProvider, ProviderCapabilities, ResolvedStream, SyncResult};

pub const DEEZER_CREDENTIAL_SERVICE: &str = "com.lumina.audio.deezer";
pub const DEEZER_KEY_ARL: &str = "arl_token";

pub const DEFAULT_DEEZER_API_BASE_URL: &str = "https://api.deezer.com";
pub const DEFAULT_DEEZER_GW_BASE_URL: &str = "https://www.deezer.com/ajax/gw-light.php";
pub const DEFAULT_DEEZER_MEDIA_BASE_URL: &str = "https://media.deezer.com/v1/get_url";

pub fn validate_arl_cookie(arl: &str) -> bool {
    let trimmed = arl.trim();
    if trimmed.len() < 32 {
        return false;
    }
    trimmed.chars().all(|c| c.is_ascii_hexdigit() || c == '_')
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeezerUser {
    pub id: u64,
    pub name: String,
    pub offer: String,
    pub can_stream_hq: bool,
    pub can_stream_lossless: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeezerConfig {
    pub arl: Option<String>,
    pub api_base_url: String,
    pub gw_base_url: String,
    pub media_base_url: String,
}

impl Default for DeezerConfig {
    fn default() -> Self {
        Self {
            arl: None,
            api_base_url: DEFAULT_DEEZER_API_BASE_URL.to_string(),
            gw_base_url: DEFAULT_DEEZER_GW_BASE_URL.to_string(),
            media_base_url: DEFAULT_DEEZER_MEDIA_BASE_URL.to_string(),
        }
    }
}

impl DeezerConfig {
    pub fn from_arl(arl: impl Into<String>) -> Self {
        Self {
            arl: Some(arl.into()),
            ..Default::default()
        }
    }
}

#[derive(Debug, Clone)]
struct DeezerSession {
    arl: String,
    sid: Option<String>,
    api_token: Option<String>,
    license_token: Option<String>,
    user: DeezerUser,
}

#[derive(Debug, Deserialize)]
struct DeezerGwResponse<T> {
    #[serde(default)]
    error: Option<serde_json::Value>,
    #[serde(default)]
    results: Option<T>,
}

#[derive(Debug, Default, Deserialize)]
struct DeezerUserDataResult {
    #[serde(rename = "USER", default)]
    user: Option<DeezerGwUser>,
    #[serde(rename = "checkForm", default)]
    check_form: Option<String>,
    #[serde(rename = "OFFER_NAME", default)]
    offer_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DeezerGwUser {
    #[serde(rename = "USER_ID", default)]
    user_id: u64,
    #[serde(rename = "BLOG_NAME", default)]
    blog_name: Option<String>,
    #[serde(rename = "OPTIONS", default)]
    options: Option<DeezerGwOptions>,
}

#[derive(Debug, Deserialize)]
struct DeezerGwOptions {
    #[serde(default)]
    web_hq: Option<bool>,
    #[serde(default)]
    web_lossless: Option<bool>,
    #[serde(default)]
    license_token: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct DeezerSongDataResult {
    #[serde(rename = "TRACK_TOKEN", default)]
    track_token: Option<String>,
    #[serde(rename = "GAIN", default)]
    gain: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct DeezerMediaResponse {
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    data: Vec<DeezerMediaDataItem>,
}

#[derive(Debug, Deserialize)]
struct DeezerMediaDataItem {
    #[serde(default)]
    media: Vec<DeezerMediaItem>,
    #[serde(default)]
    errors: Vec<DeezerMediaError>,
}

#[derive(Debug, Deserialize)]
struct DeezerMediaItem {
    #[serde(default)]
    format: Option<String>,
    #[serde(default)]
    sources: Vec<DeezerMediaSource>,
}

#[derive(Debug, Deserialize)]
struct DeezerMediaSource {
    url: String,
}

#[derive(Debug, Deserialize)]
struct DeezerMediaError {
    #[serde(default)]
    code: Option<i64>,
    #[serde(default)]
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DeezerSearchAlbumsResponse {
    #[serde(default)]
    data: Vec<DeezerAlbumDto>,
}

#[derive(Debug, Deserialize)]
struct DeezerAlbumDto {
    #[serde(deserialize_with = "de_id_str")]
    id: String,
    title: String,
    #[serde(default)]
    artist: Option<DeezerArtistDto>,
    #[serde(default)]
    cover_xl: Option<String>,
    #[serde(default)]
    cover_big: Option<String>,
    #[serde(default)]
    cover_medium: Option<String>,
    #[serde(default)]
    release_date: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    upc: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DeezerArtistDto {
    name: String,
}

#[derive(Debug, Deserialize)]
struct DeezerTrackDto {
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
    album: Option<DeezerTrackAlbumDto>,
}

#[derive(Debug, Deserialize)]
struct DeezerTrackAlbumDto {
    #[serde(deserialize_with = "de_id_str")]
    id: String,
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

pub struct DeezerProvider {
    config: RwLock<DeezerConfig>,
    transport: Arc<dyn HttpTransport>,
    credential_store: Option<Arc<dyn CredentialStore>>,
    active_arl: RwLock<Option<String>>,
    session: RwLock<Option<DeezerSession>>,
}

impl DeezerProvider {
    pub fn new(credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::with_config(DeezerConfig::default(), credential_store)
    }

    pub fn with_config(
        config: DeezerConfig,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self::with_transport(config, Arc::new(ReqwestHttpTransport::new()), credential_store)
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

    pub async fn login_with_arl(&self, arl: &str) -> Result<DeezerUser, ProviderError> {
        let trimmed = arl.trim();
        if !validate_arl_cookie(trimmed) {
            return Err(ProviderError::AuthenticationFailed(
                "Deezer ARL must be hex/underscore string >= 32 characters".to_string(),
            ));
        }

        let gw_url = self.config.read().await.gw_base_url.clone();
        let req = HttpRequest::post_json(&gw_url, "{}")
            .with_header("Cookie", format!("arl={trimmed}"))
            .with_query("method", "deezer.getUserData")
            .with_query("input", "3")
            .with_query("api_version", "1.0")
            .with_query("api_token", "null");

        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Deezer ARL rejected (HTTP {})",
                resp.status
            )));
        }
        if resp.status == 429 {
            return Err(ProviderError::RateLimited(
                "Deezer getUserData rate limited (HTTP 429)".to_string(),
            ));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer getUserData failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let parsed: DeezerGwResponse<DeezerUserDataResult> = serde_json::from_str(&resp.body)
            .map_err(|e| {
                ProviderError::AuthenticationFailed(format!(
                    "Failed to parse Deezer getUserData response: {e}"
                ))
            })?;

        if let Some(err_val) = parsed.error {
            if is_non_empty_gw_error(&err_val) {
                return Err(ProviderError::AuthenticationFailed(format!(
                    "Deezer gw-light error: {err_val}"
                )));
            }
        }

        let results = parsed.results.ok_or_else(|| {
            ProviderError::AuthenticationFailed(
                "Missing results in Deezer getUserData response".to_string(),
            )
        })?;
        let gw_user = results.user.ok_or_else(|| {
            ProviderError::AuthenticationFailed(
                "Missing USER in Deezer getUserData response".to_string(),
            )
        })?;

        if gw_user.user_id == 0 {
            return Err(ProviderError::AuthenticationFailed(
                "Deezer ARL is invalid or expired (USER_ID == 0)".to_string(),
            ));
        }

        let opts = gw_user.options;
        let can_hq = opts.as_ref().and_then(|o| o.web_hq).unwrap_or(true);
        let can_lossless = opts.as_ref().and_then(|o| o.web_lossless).unwrap_or(false);
        let license_token = opts.and_then(|o| o.license_token);

        let user = DeezerUser {
            id: gw_user.user_id,
            name: gw_user
                .blog_name
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| format!("Deezer User {}", gw_user.user_id)),
            offer: results.offer_name.unwrap_or_else(|| {
                if can_lossless {
                    "Deezer HiFi".to_string()
                } else {
                    "Deezer Standard".to_string()
                }
            }),
            can_stream_hq: can_hq,
            can_stream_lossless: can_lossless,
        };

        let sid = extract_sid_cookie(&resp.headers);
        let sess = DeezerSession {
            arl: trimmed.to_string(),
            sid,
            api_token: results.check_form.filter(|s| !s.trim().is_empty()),
            license_token: license_token.filter(|s| !s.trim().is_empty()),
            user: user.clone(),
        };

        if let Some(ref store) = self.credential_store {
            store
                .set_secret(DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL, trimmed)
                .await?;
        }

        *self.active_arl.write().await = Some(trimmed.to_string());
        *self.session.write().await = Some(sess);

        Ok(user)
    }

    async fn get_valid_arl(&self) -> Result<String, ProviderError> {
        {
            let r = self.active_arl.read().await;
            if let Some(arl) = &*r {
                if validate_arl_cookie(arl) {
                    return Ok(arl.clone());
                }
            }
        }

        if let Some(ref store) = self.credential_store {
            if let Some(arl) = store
                .get_secret(DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL)
                .await?
            {
                if validate_arl_cookie(&arl) {
                    *self.active_arl.write().await = Some(arl.clone());
                    return Ok(arl);
                }
            }
        }

        Err(ProviderError::not_authenticated("deezer"))
    }

    async fn ensure_session(&self) -> Result<DeezerSession, ProviderError> {
        if let Some(sess) = self.session.read().await.clone() {
            return Ok(sess);
        }
        let arl = self.get_valid_arl().await?;
        self.login_with_arl(&arl).await?;
        self.session
            .read()
            .await
            .clone()
            .ok_or_else(|| ProviderError::not_authenticated("deezer"))
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

    fn build_cookie_header(&self, sess: &DeezerSession) -> String {
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

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let arl = self.get_valid_arl().await?;
        let api_base = self.config.read().await.api_base_url.clone();
        let url = endpoint_url(&api_base, "search/album");

        let req = HttpRequest::get(url)
            .with_header("Cookie", format!("arl={arl}"))
            .with_query("q", query)
            .with_query("limit", limit.to_string());

        let resp = self.transport.execute(req).await?;
        if resp.status == 429 {
            return Err(ProviderError::RateLimited(
                "Deezer search rate limited".to_string(),
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
        if track.provider != ProviderKind::Deezer {
            return Err(ProviderError::UnsupportedFormat(format!(
                "Cannot resolve non-Deezer track on DeezerProvider: {}",
                track.provider
            )));
        }

        let sess = self.ensure_session().await?;
        let cookie_header = self.build_cookie_header(&sess);
        let cfg = self.config.read().await.clone();

        // Optionally query song.getData to obtain TRACK_TOKEN and ReplayGain when api_token is available.
        let mut track_token = track.external_track_id.clone();
        let mut gw_gain_db: Option<f64> = None;

        if let Some(ref api_token) = sess.api_token {
            let song_body = serde_json::json!({ "sng_id": track.external_track_id }).to_string();
            let song_req = HttpRequest::post_json(&cfg.gw_base_url, song_body)
                .with_header("Cookie", &cookie_header)
                .with_query("method", "song.getData")
                .with_query("input", "3")
                .with_query("api_version", "1.0")
                .with_query("api_token", api_token);

            if let Ok(song_resp) = self.transport.execute(song_req).await {
                if song_resp.status == 200 {
                    if let Ok(parsed) =
                        serde_json::from_str::<DeezerGwResponse<DeezerSongDataResult>>(
                            &song_resp.body,
                        )
                    {
                        if let Some(res) = parsed.results {
                            if let Some(tt) = res.track_token.filter(|s| !s.trim().is_empty()) {
                                track_token = tt;
                            }
                            if let Some(g) = res.gain {
                                gw_gain_db = match g {
                                    serde_json::Value::Number(n) => n.as_f64(),
                                    serde_json::Value::String(s) => s.parse::<f64>().ok(),
                                    _ => None,
                                }
                                .filter(|v| v.is_finite());
                            }
                        }
                    }
                }
            }
        }

        let preferred_formats = if sess.user.can_stream_lossless {
            vec![
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "FLAC" }),
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
            ]
        } else {
            vec![
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
            ]
        };

        let media_payload = serde_json::json!({
            "license_token": sess.license_token.as_deref().unwrap_or(""),
            "media": [{
                "type": "FULL",
                "formats": preferred_formats,
            }],
            "track_tokens": [track_token],
        })
        .to_string();

        let media_req = HttpRequest::post_json(&cfg.media_base_url, media_payload)
            .with_header("Cookie", &cookie_header);

        let resp = self.transport.execute(media_req).await?;
        if resp.status == 401 || resp.status == 403 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Deezer media endpoint unauthorized (HTTP {})",
                resp.status
            )));
        }
        if resp.status == 429 {
            return Err(ProviderError::RateLimited(
                "Deezer media endpoint rate limited (HTTP 429)".to_string(),
            ));
        }
        if resp.status >= 400 {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "Deezer media endpoint failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let parsed: DeezerMediaResponse = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!(
                "Failed to parse Deezer media response: {e}"
            ))
        })?;

        let mut chosen_format_name: Option<String> = None;
        let stream_url = if let Some(u) = parsed.url.filter(|s| !s.trim().is_empty()) {
            u
        } else if let Some(first) = parsed.data.into_iter().next() {
            let media_was_empty = first.media.is_empty();
            let mut found_media: Option<(Option<String>, String)> = None;
            for media in first.media {
                if let Some(src) = media.sources.into_iter().find(|s| !s.url.trim().is_empty()) {
                    found_media = Some((media.format, src.url));
                    break;
                }
            }

            if let Some((fmt_name, url)) = found_media {
                chosen_format_name = fmt_name;
                url
            } else if let Some(err) = first.errors.into_iter().next() {
                let code = err.code.unwrap_or(0);
                let msg = err.message.unwrap_or_else(|| "Unavailable".to_string());
                if code == 2002 || msg.to_ascii_lowercase().contains("license") {
                    return Err(ProviderError::DrmRestricted(format!(
                        "Deezer track restricted ({code}): {msg}"
                    )));
                }
                return Err(ProviderError::StreamResolutionFailed(format!(
                    "Deezer media error ({code}): {msg}"
                )));
            } else if media_was_empty {
                return Err(ProviderError::StreamResolutionFailed(
                    "Deezer media response contained empty data item".to_string(),
                ));
            } else {
                return Err(ProviderError::StreamResolutionFailed(
                    "Deezer media item contained no source URLs".to_string(),
                ));
            }
        } else {
            return Err(ProviderError::StreamResolutionFailed(
                "Deezer media response missing stream URL".to_string(),
            ));
        };

        let (codec, hint_ext) = match chosen_format_name
            .as_deref()
            .map(|f| f.to_ascii_uppercase())
        {
            Some(ref f) if f.starts_with("MP3") => (AudioCodec::Mp3, "mp3"),
            Some(_) => (AudioCodec::Flac, "flac"),
            None if !sess.user.can_stream_lossless => (AudioCodec::Mp3, "mp3"),
            None => (AudioCodec::Flac, "flac"),
        };
        let format = AudioFormat::pcm(codec, 44100, 16, 2)?;

        Ok(ResolvedStream::http_stream(
            stream_url,
            format,
            vec![("Cookie".to_string(), format!("arl={}", sess.arl))],
            Some(hint_ext.to_string()),
        )
        .with_replay_gain(gw_gain_db, None, None, None)
        .with_replay_gain_from_track(track))
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        Ok(SyncResult::default())
    }
}

fn is_non_empty_gw_error(err: &serde_json::Value) -> bool {
    match err {
        serde_json::Value::Null => false,
        serde_json::Value::Array(arr) => !arr.is_empty(),
        serde_json::Value::Object(map) => !map.is_empty(),
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::String(s) => !s.trim().is_empty(),
        _ => true,
    }
}

fn extract_sid_cookie(headers: &[(String, String)]) -> Option<String> {
    for (k, v) in headers {
        if k.eq_ignore_ascii_case("set-cookie") {
            for part in v.split(';') {
                let trimmed = part.trim();
                if let Some(val) = trimmed.strip_prefix("sid=") {
                    if !val.trim().is_empty() {
                        return Some(val.trim().to_string());
                    }
                }
            }
        }
    }
    None
}
