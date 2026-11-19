use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::rate_limiter::{execute_with_backoff, RateLimiter};
use crate::error::ProviderError;
use crate::http::endpoint_url;

pub const DEFAULT_MUSICBRAINZ_BASE_URL: &str = "https://musicbrainz.org/ws/2";
pub const DEFAULT_MUSICBRAINZ_USER_AGENT: &str = "LuminaAudio/0.1.0 (https://lumina.audio)";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MusicBrainzConfig {
    pub base_url: String,
    pub user_agent: String,
    pub min_interval_ms: u64,
    pub max_retries: u8,
    pub timeout_secs: u64,
}

impl Default for MusicBrainzConfig {
    fn default() -> Self {
        Self {
            base_url: DEFAULT_MUSICBRAINZ_BASE_URL.to_string(),
            user_agent: DEFAULT_MUSICBRAINZ_USER_AGENT.to_string(),
            min_interval_ms: 1100,
            max_retries: 2,
            timeout_secs: 15,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbArtistRef {
    pub id: String,
    pub name: String,
    pub sort_name: Option<String>,
    pub disambiguation: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbArtistCredit {
    pub name: Option<String>,
    pub artist: Option<MbArtistRef>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbReleaseGroup {
    pub id: String,
    pub title: String,
    pub primary_type: Option<String>,
    pub first_release_date: Option<String>,
    pub artist_credit: Vec<MbArtistCredit>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
struct MbReleaseGroupSearchResponse {
    pub release_groups: Vec<MbReleaseGroup>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbReleaseGroupDetail {
    pub id: String,
    pub title: String,
    pub releases: Vec<MbRelease>,
    pub artist_credit: Vec<MbArtistCredit>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbRelease {
    pub id: String,
    pub title: String,
    pub date: Option<String>,
    pub barcode: Option<String>,
    pub release_group: Option<MbReleaseGroup>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
struct MbReleaseSearchResponse {
    pub releases: Vec<MbRelease>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbRelation {
    #[serde(rename = "type")]
    pub rel_type: String,
    pub target_type: Option<String>,
    pub attributes: Vec<String>,
    pub artist: Option<MbArtistRef>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbRecording {
    pub id: String,
    pub title: String,
    pub relations: Vec<MbRelation>,
    pub releases: Vec<MbRelease>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbTrack {
    pub id: String,
    pub title: String,
    pub recording: Option<MbRecording>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbMedium {
    pub tracks: Vec<MbTrack>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbReleaseDetail {
    pub id: String,
    pub title: String,
    pub date: Option<String>,
    pub barcode: Option<String>,
    pub release_group: Option<MbReleaseGroup>,
    pub artist_credit: Vec<MbArtistCredit>,
    pub relations: Vec<MbRelation>,
    pub media: Vec<MbMedium>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbIsrcLookup {
    pub isrc: Option<String>,
    pub recordings: Vec<MbRecording>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "kebab-case", default)]
pub struct MbArtistDetail {
    pub id: String,
    pub name: String,
    pub sort_name: Option<String>,
    pub disambiguation: Option<String>,
    #[serde(rename = "type")]
    pub artist_type: Option<String>,
    pub country: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MbCreditCandidate {
    pub artist_mbid: Option<String>,
    pub artist_name: String,
    pub role: String,
}

pub struct MusicBrainzClient {
    client: reqwest::Client,
    config: MusicBrainzConfig,
    limiter: Arc<RateLimiter>,
}

impl MusicBrainzClient {
    pub fn new(config: MusicBrainzConfig) -> Result<Self, ProviderError> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(config.timeout_secs.max(1)))
            .build()
            .map_err(|e| ProviderError::InvalidConfig(format!("MusicBrainz HTTP client init failed: {e}")))?;
        let limiter = Arc::new(RateLimiter::new(Duration::from_millis(config.min_interval_ms)));
        Ok(Self {
            client,
            config,
            limiter,
        })
    }

    pub fn config(&self) -> &MusicBrainzConfig {
        &self.config
    }

    async fn get_json<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<T, ProviderError> {
        let url = endpoint_url(&self.config.base_url, path);
        let mut all_query: Vec<(String, String)> = query
            .iter()
            .map(|(k, v)| ((*k).to_string(), v.clone()))
            .collect();
        all_query.push(("fmt".to_string(), "json".to_string()));

        let ua = self.config.user_agent.clone();
        let client = self.client.clone();

        let (status, body) = execute_with_backoff(&self.limiter, self.config.max_retries, || {
            client
                .get(&url)
                .header(reqwest::header::USER_AGENT, &ua)
                .header(reqwest::header::ACCEPT, "application/json")
                .query(&all_query)
                .send()
        })
        .await?;

        if status == 404 {
            return Err(ProviderError::AlbumNotFound(format!(
                "MusicBrainz resource not found: {path}"
            )));
        }
        if status >= 400 {
            return Err(ProviderError::Network(format!(
                "MusicBrainz API error on '{path}' (HTTP {status}): {body}"
            )));
        }

        serde_json::from_str::<T>(&body).map_err(|e| {
            ProviderError::Network(format!("Failed to decode MusicBrainz JSON for '{path}': {e}"))
        })
    }

    pub async fn search_release_groups(
        &self,
        title: &str,
        artist: &str,
        limit: usize,
    ) -> Result<Vec<MbReleaseGroup>, ProviderError> {
        let query_str = format!(
            "releasegroup:\"{}\" AND artist:\"{}\"",
            escape_lucene(title),
            escape_lucene(artist)
        );
        let resp: MbReleaseGroupSearchResponse = self
            .get_json(
                "release-group",
                &[
                    ("query", query_str),
                    ("limit", limit.max(1).to_string()),
                ],
            )
            .await?;
        Ok(resp.release_groups)
    }

    pub async fn search_releases_by_barcode(
        &self,
        upc: &str,
    ) -> Result<Vec<MbRelease>, ProviderError> {
        let clean = upc.trim();
        let resp: MbReleaseSearchResponse = self
            .get_json("release", &[("query", format!("barcode:{clean}"))])
            .await?;
        Ok(resp.releases)
    }

    pub async fn lookup_release_group(
        &self,
        rg_id: &str,
    ) -> Result<MbReleaseGroupDetail, ProviderError> {
        self.get_json(
            &format!("release-group/{}", rg_id.trim()),
            &[("inc", "releases+artist-credits".to_string())],
        )
        .await
    }

    pub async fn lookup_release_with_credits(
        &self,
        release_id: &str,
    ) -> Result<MbReleaseDetail, ProviderError> {
        self.get_json(
            &format!("release/{}", release_id.trim()),
            &[(
                "inc",
                "artists+artist-credits+recordings+recording-level-rels+artist-rels+work-rels"
                    .to_string(),
            )],
        )
        .await
    }

    pub async fn lookup_by_isrc(&self, isrc: &str) -> Result<MbIsrcLookup, ProviderError> {
        self.get_json(
            &format!("isrc/{}", isrc.trim()),
            &[("inc", "artists+artist-credits+releases".to_string())],
        )
        .await
    }

    pub async fn lookup_artist(&self, artist_mbid: &str) -> Result<MbArtistDetail, ProviderError> {
        self.get_json(&format!("artist/{}", artist_mbid.trim()), &[])
            .await
    }
}

pub fn extract_mb_credits(release: &MbReleaseDetail) -> Vec<MbCreditCandidate> {
    let mut credits = Vec::new();
    let mut seen: HashSet<(String, String)> = HashSet::new();

    let mut push_rel = |rel: &MbRelation| {
        let is_artist_target = rel
            .target_type
            .as_deref()
            .is_none_or(|t| t.eq_ignore_ascii_case("artist"));
        if !is_artist_target {
            return;
        }
        let Some(ref artist) = rel.artist else {
            return;
        };
        let name = artist.name.trim();
        if name.is_empty() {
            return;
        }
        let role = format_mb_role(&rel.rel_type, &rel.attributes);
        if role.is_empty() {
            return;
        }
        let artist_key = if artist.id.trim().is_empty() {
            name.to_ascii_lowercase()
        } else {
            artist.id.trim().to_ascii_lowercase()
        };
        if seen.insert((artist_key, role.to_ascii_lowercase())) {
            credits.push(MbCreditCandidate {
                artist_mbid: (!artist.id.trim().is_empty()).then(|| artist.id.trim().to_string()),
                artist_name: name.to_string(),
                role,
            });
        }
    };

    for rel in &release.relations {
        push_rel(rel);
    }
    for medium in &release.media {
        for track in &medium.tracks {
            if let Some(ref rec) = track.recording {
                for rel in &rec.relations {
                    push_rel(rel);
                }
            }
        }
    }

    credits
}

fn format_mb_role(rel_type: &str, attributes: &[String]) -> String {
    let base = title_case_words(rel_type.trim());
    if base.is_empty() {
        return String::new();
    }
    let clean_attrs: Vec<String> = attributes
        .iter()
        .map(|a| title_case_words(a.trim()))
        .filter(|a| !a.is_empty())
        .collect();
    if clean_attrs.is_empty() {
        base
    } else {
        format!("{base}: {}", clean_attrs.join(", "))
    }
}

fn title_case_words(input: &str) -> String {
    input
        .split([' ', '_', '-'])
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut chars = w.chars();
            match chars.next() {
                Some(first) => {
                    let mut s = first.to_uppercase().to_string();
                    s.push_str(&chars.as_str().to_ascii_lowercase());
                    s
                }
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn escape_lucene(input: &str) -> String {
    input.replace('"', "\\\"")
}
