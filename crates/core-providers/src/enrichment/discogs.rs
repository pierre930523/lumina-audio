use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::rate_limiter::{execute_with_backoff, RateLimiter};
use crate::error::ProviderError;
use crate::http::endpoint_url;

pub const DEFAULT_DISCOGS_BASE_URL: &str = "https://api.discogs.com";
pub const DEFAULT_DISCOGS_USER_AGENT: &str = "LuminaAudio/0.1.0";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscogsConfig {
    pub base_url: String,
    pub user_agent: String,
    #[serde(default)]
    pub token: Option<String>,
    pub min_interval_ms: u64,
    pub max_retries: u8,
    pub timeout_secs: u64,
}

impl Default for DiscogsConfig {
    fn default() -> Self {
        Self {
            base_url: DEFAULT_DISCOGS_BASE_URL.to_string(),
            user_agent: DEFAULT_DISCOGS_USER_AGENT.to_string(),
            token: None,
            min_interval_ms: 1000,
            max_retries: 2,
            timeout_secs: 15,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsSearchResult {
    pub id: u64,
    pub title: String,
    pub year: Option<String>,
    pub master_id: Option<u64>,
    pub cover_image: Option<String>,
    pub thumb: Option<String>,
    #[serde(rename = "type")]
    pub result_type: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
struct DiscogsSearchResponse {
    pub results: Vec<DiscogsSearchResult>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsImage {
    pub uri: String,
    #[serde(rename = "type")]
    pub image_type: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsExtraArtist {
    pub id: Option<u64>,
    pub name: String,
    pub role: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsIdentifier {
    #[serde(rename = "type")]
    pub id_type: String,
    pub value: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsTrack {
    pub title: String,
    pub extraartists: Vec<DiscogsExtraArtist>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsMaster {
    pub id: u64,
    pub title: String,
    pub year: Option<i32>,
    pub main_release: Option<u64>,
    pub notes: Option<String>,
    pub images: Vec<DiscogsImage>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsRelease {
    pub id: u64,
    pub title: String,
    pub year: Option<i32>,
    pub master_id: Option<u64>,
    pub notes: Option<String>,
    pub images: Vec<DiscogsImage>,
    pub artists: Vec<DiscogsExtraArtist>,
    pub extraartists: Vec<DiscogsExtraArtist>,
    pub tracklist: Vec<DiscogsTrack>,
    pub identifiers: Vec<DiscogsIdentifier>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct DiscogsArtist {
    pub id: u64,
    pub name: String,
    pub profile: Option<String>,
    pub images: Vec<DiscogsImage>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscogsCreditCandidate {
    pub discogs_artist_id: Option<u64>,
    pub artist_name: String,
    pub role: String,
}

#[derive(Debug, Clone, Default)]
pub struct DiscogsExtractedAlbum {
    pub editorial_bio: Option<String>,
    pub cover_url: Option<String>,
    pub upc: Option<String>,
    pub year: Option<i32>,
    pub credits: Vec<DiscogsCreditCandidate>,
}

pub struct DiscogsClient {
    client: reqwest::Client,
    config: DiscogsConfig,
    limiter: Arc<RateLimiter>,
}

impl DiscogsClient {
    pub fn new(config: DiscogsConfig) -> Result<Self, ProviderError> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(config.timeout_secs.max(1)))
            .build()
            .map_err(|e| {
                ProviderError::InvalidConfig(format!("Discogs HTTP client init failed: {e}"))
            })?;
        let limiter = Arc::new(RateLimiter::new(Duration::from_millis(config.min_interval_ms)));
        Ok(Self {
            client,
            config,
            limiter,
        })
    }

    pub fn config(&self) -> &DiscogsConfig {
        &self.config
    }

    async fn get_json<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, ProviderError> {
        let url = endpoint_url(&self.config.base_url, path);
        let ua = self.config.user_agent.clone();
        let auth_header = self
            .config
            .token
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|t| format!("Discogs token={t}"));
        let client = self.client.clone();
        let query_vec: Vec<(String, String)> = query
            .iter()
            .map(|(k, v)| ((*k).to_string(), v.clone()))
            .collect();

        let (status, body) = execute_with_backoff(&self.limiter, self.config.max_retries, || {
            let mut req = client
                .get(&url)
                .header(reqwest::header::USER_AGENT, &ua)
                .header(reqwest::header::ACCEPT, "application/json");
            if let Some(ref auth) = auth_header {
                req = req.header(reqwest::header::AUTHORIZATION, auth);
            }
            if !query_vec.is_empty() {
                req = req.query(&query_vec);
            }
            req.send()
        })
        .await?;

        if status == 401 || status == 403 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Discogs API unauthorized on '{path}' (HTTP {status})"
            )));
        }
        if status == 404 {
            return Err(ProviderError::AlbumNotFound(format!(
                "Discogs resource not found: {path}"
            )));
        }
        if status >= 400 {
            return Err(ProviderError::Network(format!(
                "Discogs API error on '{path}' (HTTP {status}): {body}"
            )));
        }

        serde_json::from_str::<T>(&body).map_err(|e| {
            ProviderError::Network(format!("Failed to decode Discogs JSON for '{path}': {e}"))
        })
    }

    pub async fn search_releases(
        &self,
        title: &str,
        artist: &str,
        upc: Option<&str>,
        per_page: usize,
    ) -> Result<Vec<DiscogsSearchResult>, ProviderError> {
        let mut query = vec![
            ("type", "release".to_string()),
            ("per_page", per_page.max(1).to_string()),
        ];
        if let Some(barcode) = upc.map(str::trim).filter(|s| !s.is_empty()) {
            query.push(("barcode", barcode.to_string()));
        } else {
            query.push(("release_title", title.trim().to_string()));
            query.push(("artist", artist.trim().to_string()));
        }

        let resp: DiscogsSearchResponse = self.get_json("database/search", &query).await?;
        Ok(resp.results)
    }

    pub async fn get_master(&self, master_id: u64) -> Result<DiscogsMaster, ProviderError> {
        self.get_json(&format!("masters/{master_id}"), &[]).await
    }

    pub async fn get_release(&self, release_id: u64) -> Result<DiscogsRelease, ProviderError> {
        self.get_json(&format!("releases/{release_id}"), &[]).await
    }

    pub async fn get_artist(&self, artist_id: u64) -> Result<DiscogsArtist, ProviderError> {
        self.get_json(&format!("artists/{artist_id}"), &[]).await
    }
}

/// Strips Discogs disambiguation suffixes like `"Alan Parsons (2)" -> "Alan Parsons"`.
pub fn clean_discogs_artist_name(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.ends_with(')') {
        if let Some(open_idx) = trimmed.rfind(" (") {
            let inside = &trimmed[open_idx + 2..trimmed.len() - 1];
            if !inside.is_empty() && inside.chars().all(|c| c.is_ascii_digit()) {
                return trimmed[..open_idx].trim().to_string();
            }
        }
    }
    trimmed.to_string()
}

pub fn extract_discogs_credits(release: &DiscogsRelease) -> DiscogsExtractedAlbum {
    let mut credits = Vec::new();
    let mut seen: HashSet<(String, String)> = HashSet::new();

    let mut push_extra = |ea: &DiscogsExtraArtist| {
        let clean_name = clean_discogs_artist_name(&ea.name);
        if clean_name.is_empty() {
            return;
        }
        for role_part in split_discogs_roles(&ea.role) {
            let role = role_part.trim();
            if role.is_empty() {
                continue;
            }
            if seen.insert((clean_name.to_ascii_lowercase(), role.to_ascii_lowercase())) {
                credits.push(DiscogsCreditCandidate {
                    discogs_artist_id: ea.id,
                    artist_name: clean_name.clone(),
                    role: role.to_string(),
                });
            }
        }
    };

    for ea in &release.extraartists {
        push_extra(ea);
    }
    for trk in &release.tracklist {
        for ea in &trk.extraartists {
            push_extra(ea);
        }
    }

    let upc = release
        .identifiers
        .iter()
        .find(|id| id.id_type.eq_ignore_ascii_case("Barcode"))
        .map(|id| id.value.trim().to_string())
        .filter(|s| !s.is_empty());

    let cover_url = release
        .images
        .iter()
        .find(|img| img.image_type.as_deref() == Some("primary"))
        .or_else(|| release.images.first())
        .map(|img| img.uri.trim().to_string())
        .filter(|s| !s.is_empty());

    let editorial_bio = release
        .notes
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    DiscogsExtractedAlbum {
        editorial_bio,
        cover_url,
        upc,
        year: release.year.filter(|y| (1000..=3000).contains(y)),
        credits,
    }
}

fn split_discogs_roles(raw: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut bracket_depth: usize = 0;
    let mut paren_depth: usize = 0;
    let mut start = 0usize;

    for (idx, ch) in raw.char_indices() {
        match ch {
            '[' => bracket_depth += 1,
            ']' => bracket_depth = bracket_depth.saturating_sub(1),
            '(' => paren_depth += 1,
            ')' => paren_depth = paren_depth.saturating_sub(1),
            ',' if bracket_depth == 0 && paren_depth == 0 => {
                let part = raw[start..idx].trim();
                if !part.is_empty() {
                    parts.push(part);
                }
                start = idx + 1;
            }
            _ => {}
        }
    }
    let tail = raw[start..].trim();
    if !tail.is_empty() {
        parts.push(tail);
    }
    parts
}
