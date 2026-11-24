use std::collections::BTreeMap;
use std::sync::Arc;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, NormalizedLoudness, ProviderKind,
    StreamCipher, StreamKey, StreamProviderCapabilities, StreamSourceSpec, TrackSource,
    DEFAULT_DEEZER_BLOCK_SIZE, DEFAULT_DEEZER_STRIDE,
};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::error::ProviderError;
use crate::http::{endpoint_url, HttpRequest, HttpTransport, ReqwestHttpTransport};
use crate::local::dsd_meta::parse_year;
use crate::local::extract_edition_label;
use crate::traits::{
    extract_expire_at_from_url, validate_stream_key, MusicProvider, ProviderCapabilities,
    ResolvedStream, StreamResolver, SyncResult,
};

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
    exp: Option<u64>,
    #[serde(default)]
    cipher: Option<serde_json::Value>,
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
    preview: Option<String>,
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

    async fn fetch_encrypted_media(
        &self,
        sess: &DeezerSession,
        track_id: &str,
        preferred_formats: Vec<serde_json::Value>,
    ) -> Result<DeezerMediaResolved, ProviderError> {
        let cookie_header = self.build_cookie_header(sess);
        let cfg = self.config.read().await.clone();

        // Optionally query song.getData to obtain TRACK_TOKEN and ReplayGain when api_token is available.
        let mut track_token = track_id.to_string();
        let mut gw_gain_db: Option<f64> = None;

        if let Some(ref api_token) = sess.api_token {
            let song_body = serde_json::json!({ "sng_id": track_id }).to_string();
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
        if resp.status == 401 {
            return Err(ProviderError::AuthenticationFailed(
                "Deezer media endpoint unauthorized (HTTP 401)".to_string(),
            ));
        }
        if resp.status == 403 {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "Deezer media endpoint forbidden (HTTP 403): {}",
                resp.body
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
        let mut media_exp: Option<u64> = None;
        let mut is_unencrypted = false;
        let stream_url = if let Some(u) = parsed.url.filter(|s| !s.trim().is_empty()) {
            u
        } else if let Some(first) = parsed.data.into_iter().next() {
            let media_was_empty = first.media.is_empty();
            let mut found_media: Option<(Option<String>, Option<u64>, bool, String)> = None;
            for media in first.media {
                if let Some(src) = media.sources.into_iter().find(|s| !s.url.trim().is_empty()) {
                    let unenc = is_deezer_cipher_none(media.cipher.as_ref());
                    found_media = Some((media.format, media.exp, unenc, src.url));
                    break;
                }
            }

            if let Some((fmt_name, exp, unenc, url)) = found_media {
                chosen_format_name = fmt_name;
                media_exp = exp;
                is_unencrypted = unenc;
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

        let upper_fmt = chosen_format_name
            .as_deref()
            .map(|f| f.to_ascii_uppercase());
        let (codec, hint_ext, mime_type, bitrate_bps) = match upper_fmt.as_deref() {
            Some("MP3_128") => (AudioCodec::Mp3, "mp3", "audio/mpeg", Some(128_000)),
            Some(f) if f.starts_with("MP3") => (AudioCodec::Mp3, "mp3", "audio/mpeg", Some(320_000)),
            Some(_) => (AudioCodec::Flac, "flac", "audio/flac", None),
            None if !sess.user.can_stream_lossless => {
                (AudioCodec::Mp3, "mp3", "audio/mpeg", Some(320_000))
            }
            None => (AudioCodec::Flac, "flac", "audio/flac", None),
        };
        let expire_at = media_exp.or_else(|| extract_expire_at_from_url(&stream_url));

        Ok(DeezerMediaResolved {
            url: stream_url,
            codec,
            hint_ext,
            mime_type: mime_type.to_string(),
            bitrate_bps,
            gw_gain_db,
            expire_at,
            is_unencrypted,
        })
    }

    async fn fetch_preview_info(
        &self,
        track_id: &str,
    ) -> Result<(String, Option<NormalizedLoudness>), ProviderError> {
        let api_base = self.config.read().await.api_base_url.clone();
        let url = endpoint_url(&api_base, &format!("track/{track_id}"));
        let mut req = HttpRequest::get(url);
        if let Ok(arl) = self.get_valid_arl().await {
            req = req.with_header("Cookie", format!("arl={arl}"));
        }
        let resp = self.transport.execute(req).await?;
        if resp.status == 404 {
            return Err(ProviderError::track_not_found("deezer", track_id));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer track preview fetch failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }
        let dto: DeezerTrackDto = serde_json::from_str(&resp.body).map_err(|e| {
            ProviderError::StreamResolutionFailed(format!(
                "Failed to parse Deezer track response: {e}"
            ))
        })?;
        let loudness = dto
            .gain
            .filter(|g| g.is_finite())
            .map(|g| NormalizedLoudness::from_deezer_gain(g as f32));
        let preview_url = dto
            .preview
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                ProviderError::StreamResolutionFailed(format!(
                    "Deezer track '{track_id}' has no preview stream URL"
                ))
            })?;
        Ok((preview_url, loudness))
    }
}

struct DeezerMediaResolved {
    url: String,
    codec: AudioCodec,
    hint_ext: &'static str,
    mime_type: String,
    bitrate_bps: Option<u64>,
    gw_gain_db: Option<f64>,
    expire_at: Option<u64>,
    is_unencrypted: bool,
}

fn is_deezer_cipher_none(cipher: Option<&serde_json::Value>) -> bool {
    match cipher {
        Some(serde_json::Value::String(s)) => s.trim().eq_ignore_ascii_case("NONE"),
        Some(serde_json::Value::Object(map)) => map
            .get("type")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s.trim().eq_ignore_ascii_case("NONE")),
        _ => false,
    }
}

enum DeezerQualityPlan {
    Full(Vec<serde_json::Value>),
    PreviewOnly,
}

fn deezer_quality_plan(
    quality_key: &str,
    can_stream_lossless: bool,
    can_stream_hq: bool,
) -> Result<DeezerQualityPlan, ProviderError> {
    let normalized = quality_key.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "preview" => Ok(DeezerQualityPlan::PreviewOnly),
        "" | "default" | "auto" | "flac" | "lossless" | "hi_res" | "hires" | "max" | "best" => {
            if can_stream_lossless {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "FLAC" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else if can_stream_hq {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else {
                Ok(DeezerQualityPlan::PreviewOnly)
            }
        }
        "mp3_320" | "mp3" | "high" | "320" => {
            if can_stream_hq || can_stream_lossless {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_320" }),
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else {
                Ok(DeezerQualityPlan::PreviewOnly)
            }
        }
        "mp3_128" | "low" | "128" => {
            if can_stream_hq || can_stream_lossless {
                Ok(DeezerQualityPlan::Full(vec![
                    serde_json::json!({ "cipher": "BF_CBC_STRIPE", "format": "MP3_128" }),
                ]))
            } else {
                Ok(DeezerQualityPlan::PreviewOnly)
            }
        }
        _ => Err(ProviderError::UnsupportedFormat(format!(
            "Unsupported Deezer quality key: '{quality_key}'"
        ))),
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

        let resolved = self
            .fetch_encrypted_media(&sess, &track.external_track_id, preferred_formats)
            .await?;
        let format = AudioFormat::pcm(resolved.codec, 44100, 16, 2)?;

        Ok(ResolvedStream::http_stream(
            resolved.url,
            format,
            vec![("Cookie".to_string(), format!("arl={}", sess.arl))],
            Some(resolved.hint_ext.to_string()),
        )
        .with_replay_gain(resolved.gw_gain_db, None, None, None)
        .with_replay_gain_from_track(track))
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        Ok(SyncResult::default())
    }
}

#[async_trait]
impl StreamResolver for DeezerProvider {
    fn provider_id(&self) -> &'static str {
        "deezer"
    }

    fn capabilities(&self) -> StreamProviderCapabilities {
        StreamProviderCapabilities::deezer()
    }

    async fn resolve_source(&self, key: &StreamKey) -> Result<StreamSourceSpec, ProviderError> {
        validate_stream_key("deezer", key)?;

        if key.quality_key.trim().eq_ignore_ascii_case("preview") {
            let (preview_url, loudness) = self.fetch_preview_info(&key.track_id).await?;
            let expire_at = extract_expire_at_from_url(&preview_url);
            return Ok(StreamSourceSpec::DirectRange {
                key: key.clone(),
                url: preview_url,
                headers: BTreeMap::new(),
                content_length: None,
                bitrate_bps: Some(128_000),
                mime_type: Some("audio/mpeg".to_string()),
                hint_extension: Some("mp3".to_string()),
                expire_at,
                init_range_end: None,
                index_range_start: None,
                index_range_end: None,
                loudness,
                album_loudness: None,
            });
        }

        // Validate quality_key syntax up front before any session/network fallback.
        let _ = deezer_quality_plan(&key.quality_key, true, true)?;

        let sess = match self.ensure_session().await {
            Ok(s) => s,
            Err(ProviderError::Unauthenticated(unauth_msg)) => {
                if let Ok((preview_url, loudness)) = self.fetch_preview_info(&key.track_id).await {
                    let expire_at = extract_expire_at_from_url(&preview_url);
                    return Ok(StreamSourceSpec::DirectRange {
                        key: key.clone(),
                        url: preview_url,
                        headers: BTreeMap::new(),
                        content_length: None,
                        bitrate_bps: Some(128_000),
                        mime_type: Some("audio/mpeg".to_string()),
                        hint_extension: Some("mp3".to_string()),
                        expire_at,
                        init_range_end: None,
                        index_range_start: None,
                        index_range_end: None,
                        loudness,
                        album_loudness: None,
                    });
                }
                return Err(ProviderError::Unauthenticated(unauth_msg));
            }
            Err(e) => return Err(e),
        };

        let plan = deezer_quality_plan(
            &key.quality_key,
            sess.user.can_stream_lossless,
            sess.user.can_stream_hq,
        )?;

        match plan {
            DeezerQualityPlan::PreviewOnly => {
                let (preview_url, loudness) = self.fetch_preview_info(&key.track_id).await?;
                let expire_at = extract_expire_at_from_url(&preview_url);
                Ok(StreamSourceSpec::DirectRange {
                    key: key.clone(),
                    url: preview_url,
                    headers: BTreeMap::new(),
                    content_length: None,
                    bitrate_bps: Some(128_000),
                    mime_type: Some("audio/mpeg".to_string()),
                    hint_extension: Some("mp3".to_string()),
                    expire_at,
                    init_range_end: None,
                    index_range_start: None,
                    index_range_end: None,
                    loudness,
                    album_loudness: None,
                })
            }
            DeezerQualityPlan::Full(preferred_formats) => {
                match self
                    .fetch_encrypted_media(&sess, &key.track_id, preferred_formats)
                    .await
                {
                    Ok(media) => {
                        let headers = BTreeMap::from([(
                            "Cookie".to_string(),
                            format!("arl={}", sess.arl),
                        )]);
                        let loudness = media
                            .gw_gain_db
                            .filter(|g| g.is_finite())
                            .map(|g| NormalizedLoudness::from_deezer_gain(g as f32));
                        if media.is_unencrypted {
                            Ok(StreamSourceSpec::DirectRange {
                                key: key.clone(),
                                url: media.url,
                                headers,
                                content_length: None,
                                bitrate_bps: media.bitrate_bps,
                                mime_type: Some(media.mime_type),
                                hint_extension: Some(media.hint_ext.to_string()),
                                expire_at: media.expire_at,
                                init_range_end: None,
                                index_range_start: None,
                                index_range_end: None,
                                loudness,
                                album_loudness: None,
                            })
                        } else {
                            Ok(StreamSourceSpec::EncryptedRange {
                                key: key.clone(),
                                url: media.url,
                                headers,
                                content_length: None,
                                bitrate_bps: media.bitrate_bps,
                                mime_type: Some(media.mime_type),
                                hint_extension: Some(media.hint_ext.to_string()),
                                cipher: StreamCipher::DeezerBlowfish {
                                    track_id: key.track_id.clone(),
                                    block_size: DEFAULT_DEEZER_BLOCK_SIZE,
                                    stride: DEFAULT_DEEZER_STRIDE,
                                },
                                expire_at: media.expire_at,
                                loudness,
                                album_loudness: None,
                            })
                        }
                    }
                    Err(e @ (ProviderError::AuthenticationFailed(_) | ProviderError::RateLimited(_))) => {
                        Err(e)
                    }
                    Err(orig_err) => {
                        if let Ok((preview_url, loudness)) =
                            self.fetch_preview_info(&key.track_id).await
                        {
                            let expire_at = extract_expire_at_from_url(&preview_url);
                            Ok(StreamSourceSpec::DirectRange {
                                key: key.clone(),
                                url: preview_url,
                                headers: BTreeMap::new(),
                                content_length: None,
                                bitrate_bps: Some(128_000),
                                mime_type: Some("audio/mpeg".to_string()),
                                hint_extension: Some("mp3".to_string()),
                                expire_at,
                                init_range_end: None,
                                index_range_start: None,
                                index_range_end: None,
                                loudness,
                                album_loudness: None,
                            })
                        } else {
                            Err(orig_err)
                        }
                    }
                }
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::{HttpResponse, MockHttpTransport};

    #[tokio::test]
    async fn test_deezer_stream_resolver_bf_cbc_stripe_encrypted_range() {
        let valid_arl = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
        let transport = Arc::new(MockHttpTransport::new());
        transport
            .register_fn("gw-light.php", |req| {
                let is_song = req
                    .query_params
                    .iter()
                    .any(|(k, v)| k == "method" && v == "song.getData");
                if is_song {
                    return Ok(HttpResponse::ok_json(
                        r#"{"error":[],"results":{"TRACK_TOKEN":"trk_tok_554433","GAIN":-4.2}}"#,
                    ));
                }
                Ok(HttpResponse::ok_json(
                    r#"{
                        "error": [],
                        "results": {
                            "checkForm": "dz_csrf_1",
                            "OFFER_NAME": "Deezer HiFi",
                            "USER": {
                                "USER_ID": 482910,
                                "BLOG_NAME": "HiFi Subscriber",
                                "OPTIONS": {
                                    "web_hq": true,
                                    "web_lossless": true,
                                    "license_token": "lic_tok_1"
                                }
                            }
                        }
                    }"#,
                ))
            })
            .await;
        transport
            .register_fn("get_url", |req| {
                let body = String::from_utf8_lossy(req.body.as_deref().unwrap_or(&[]));
                if body.contains(r#""format":"FLAC""#) {
                    Ok(HttpResponse::ok_json(
                        r#"{
                            "data": [{
                                "media": [{
                                    "format": "FLAC",
                                    "exp": 1766000000,
                                    "sources": [{ "url": "https://e-cdns-proxy.dzcdn.net/stream/554433.flac" }]
                                }]
                            }]
                        }"#,
                    ))
                } else {
                    Ok(HttpResponse::ok_json(
                        r#"{
                            "data": [{
                                "media": [{
                                    "format": "MP3_320",
                                    "sources": [{ "url": "https://e-cdns-proxy.dzcdn.net/stream/554433.mp3" }]
                                }]
                            }]
                        }"#,
                    ))
                }
            })
            .await;

        let provider = DeezerProvider::with_transport(DeezerConfig::default(), transport, None);
        provider.login_with_arl(valid_arl).await.unwrap();

        assert_eq!(StreamResolver::provider_id(&provider), "deezer");
        assert_eq!(
            StreamResolver::capabilities(&provider),
            StreamProviderCapabilities::deezer()
        );

        let flac_key = StreamKey::new("deezer", "554433", "FLAC");
        let flac_spec = provider.resolve_source(&flac_key).await.unwrap();
        match flac_spec {
            StreamSourceSpec::EncryptedRange {
                key,
                url,
                headers,
                mime_type,
                hint_extension,
                cipher,
                expire_at,
                loudness,
                ..
            } => {
                assert_eq!(key, flac_key);
                assert_eq!(url, "https://e-cdns-proxy.dzcdn.net/stream/554433.flac");
                assert_eq!(
                    headers.get("Cookie").map(String::as_str),
                    Some(format!("arl={valid_arl}").as_str())
                );
                assert_eq!(mime_type.as_deref(), Some("audio/flac"));
                assert_eq!(hint_extension.as_deref(), Some("flac"));
                assert_eq!(expire_at, Some(1_766_000_000));
                let l = loudness.expect("Deezer GAIN should map to NormalizedLoudness");
                assert!((l.gain_db - (-3.2)).abs() < 1e-4);
                assert!((l.peak - 1.0).abs() < 1e-4);
                assert_eq!(
                    cipher,
                    StreamCipher::DeezerBlowfish {
                        track_id: "554433".to_string(),
                        block_size: 2048,
                        stride: 3,
                    }
                );
            }
            other => panic!("expected EncryptedRange, got {other:?}"),
        }

        let mp3_key = StreamKey::new("deezer", "554433", "MP3_320");
        let mp3_spec = provider.resolve_source(&mp3_key).await.unwrap();
        match mp3_spec {
            StreamSourceSpec::EncryptedRange {
                url,
                bitrate_bps,
                mime_type,
                hint_extension,
                cipher,
                ..
            } => {
                assert_eq!(url, "https://e-cdns-proxy.dzcdn.net/stream/554433.mp3");
                assert_eq!(bitrate_bps, Some(320_000));
                assert_eq!(mime_type.as_deref(), Some("audio/mpeg"));
                assert_eq!(hint_extension.as_deref(), Some("mp3"));
                assert_eq!(
                    cipher,
                    StreamCipher::DeezerBlowfish {
                        track_id: "554433".to_string(),
                        block_size: 2048,
                        stride: 3,
                    }
                );
            }
            other => panic!("expected EncryptedRange, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn test_deezer_stream_resolver_preview_mp3_returns_direct_range() {
        let transport = Arc::new(MockHttpTransport::new());
        transport
            .register_exact(
                "track/554433",
                HttpResponse::ok_json(
                    r#"{
                        "id": 554433,
                        "title": "Preview Track",
                        "preview": "https://cdns-preview-5.dzcdn.net/stream/c-554433.mp3"
                    }"#,
                ),
            )
            .await;

        let provider = DeezerProvider::with_transport(DeezerConfig::default(), transport, None);
        let spec = provider
            .resolve_source(&StreamKey::new("deezer", "554433", "preview"))
            .await
            .unwrap();
        match spec {
            StreamSourceSpec::DirectRange {
                url,
                headers,
                bitrate_bps,
                mime_type,
                hint_extension,
                ..
            } => {
                assert_eq!(url, "https://cdns-preview-5.dzcdn.net/stream/c-554433.mp3");
                assert!(headers.is_empty());
                assert_eq!(bitrate_bps, Some(128_000));
                assert_eq!(mime_type.as_deref(), Some("audio/mpeg"));
                assert_eq!(hint_extension.as_deref(), Some("mp3"));
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }

        // Unauthenticated quality fallback also resolves official 30s preview DirectRange
        let fallback_spec = provider
            .resolve_source(&StreamKey::new("deezer", "554433", "FLAC"))
            .await
            .unwrap();
        assert!(matches!(fallback_spec, StreamSourceSpec::DirectRange { .. }));
    }
}
