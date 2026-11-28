use async_trait::async_trait;
use core_types::{CanonicalAlbum, StreamSourceSpec, TrackSource};
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

use crate::error::ProviderError;

/// Standardized playlist DTO returned by [`MediaProvider::get_playlist`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaPlaylist {
    pub id: String,
    pub provider_id: String,
    pub title: String,
    pub description: Option<String>,
    pub owner: Option<String>,
    pub artwork_url: Option<String>,
    pub tracks: Vec<TrackSource>,
}

/// Standardized health status DTO returned by [`MediaProvider::health_check`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderHealth {
    pub provider_id: String,
    pub healthy: bool,
    pub authenticated: bool,
    pub latency_ms: u64,
    pub detail: Option<String>,
}

/// Unified, cancellation-aware async media provider contract.
#[async_trait]
pub trait MediaProvider: Send + Sync {
    fn provider_id(&self) -> &'static str;

    async fn search(&self, query: &str, limit: usize)
    -> Result<Vec<CanonicalAlbum>, ProviderError>;

    async fn get_track(&self, track_id: &str) -> Result<TrackSource, ProviderError>;

    async fn get_playlist(&self, playlist_id: &str) -> Result<MediaPlaylist, ProviderError>;

    async fn resolve_stream(
        &self,
        track_id: &str,
        quality: &str,
        cancel_token: CancellationToken,
    ) -> Result<StreamSourceSpec, ProviderError>;

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError>;

    async fn refresh_credentials(&self) -> Result<(), ProviderError>;
}
