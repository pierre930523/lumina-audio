use std::sync::Arc;

use core_db::credential::{CredentialStore, DEFAULT_SERVICE_NAME};
use core_db::SqlitePool;
use core_types::{CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::RwLock;
use tokio::task::JoinSet;
use tracing::{error, info, warn};

use crate::deezer::{
    validate_arl_cookie, DeezerConfig, DeezerProvider, DeezerUser, DEEZER_CREDENTIAL_SERVICE,
    DEEZER_KEY_ARL,
};
use crate::error::ProviderError;
use crate::library::{LibrarySyncService, SyncPersistReport};
use crate::local::{LocalProvider, LocalProviderConfig};
use crate::qobuz::{
    QobuzConfig, QobuzProvider, QobuzUserSession, QOBUZ_CREDENTIAL_SERVICE,
    QOBUZ_FALLBACK_TOKEN_KEY, QOBUZ_KEYRING_TOKEN_KEY,
};
use crate::registry::{ProviderRegistry, ProviderSummary};
use crate::remote::{SmbConfig, SmbProvider, SmbTransport, WebDavConfig, WebDavProvider};
use crate::tidal::{
    is_token_expired, TidalConfig, TidalPkceSession, TidalProvider, TidalTokenResponse,
    TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH,
};
use crate::traits::{MusicProvider, ResolvedStream, SyncResult};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AggregatedSearchResult {
    pub query: String,
    pub albums: Vec<CanonicalAlbum>,
    pub provider_errors: Vec<(ProviderKind, String)>,
}

#[derive(Clone)]
pub struct ProviderManager {
    registry: ProviderRegistry,
    credential_store: Arc<dyn CredentialStore>,
    pending_tidal: Arc<RwLock<Option<Arc<TidalProvider>>>>,
}

impl ProviderManager {
    pub fn new(registry: ProviderRegistry, credential_store: Arc<dyn CredentialStore>) -> Self {
        Self {
            registry,
            credential_store,
            pending_tidal: Arc::new(RwLock::new(None)),
        }
    }

    pub fn with_credential_store(credential_store: Arc<dyn CredentialStore>) -> Self {
        Self::new(ProviderRegistry::new(), credential_store)
    }

    pub fn registry(&self) -> &ProviderRegistry {
        &self.registry
    }

    pub fn credential_store(&self) -> &Arc<dyn CredentialStore> {
        &self.credential_store
    }

    pub async fn register_provider(&self, provider: Arc<dyn MusicProvider>) {
        self.registry.register(provider).await;
    }

    pub async fn unregister_provider(
        &self,
        kind: ProviderKind,
    ) -> Option<Arc<dyn MusicProvider>> {
        self.registry.unregister(kind).await
    }

    pub async fn summaries(&self) -> Vec<ProviderSummary> {
        self.registry.summaries().await
    }

    pub async fn configure_local(&self, config: LocalProviderConfig) {
        let provider = Arc::new(LocalProvider::new(config));
        self.registry.register(provider).await;
    }

    pub async fn configure_qobuz(
        &self,
        config: QobuzConfig,
        authenticate: bool,
    ) -> Result<Option<QobuzUserSession>, ProviderError> {
        let provider = Arc::new(QobuzProvider::live(
            config,
            Some(self.credential_store.clone()),
        ));
        let session = if authenticate {
            Some(provider.authenticate().await?)
        } else {
            None
        };
        self.registry.register(provider).await;
        Ok(session)
    }

    pub async fn start_tidal_pkce(&self, config: TidalConfig) -> TidalPkceSession {
        let provider = Arc::new(TidalProvider::live(
            config,
            Some(self.credential_store.clone()),
        ));
        let session = provider.start_pkce_login().await;
        *self.pending_tidal.write().await = Some(provider.clone());
        self.registry.register(provider).await;
        session
    }

    pub async fn complete_tidal_pkce(
        &self,
        code: &str,
        code_verifier: &str,
    ) -> Result<TidalTokenResponse, ProviderError> {
        let provider = self
            .pending_tidal
            .read()
            .await
            .clone()
            .unwrap_or_else(|| {
                Arc::new(TidalProvider::new(Some(self.credential_store.clone())))
            });
        let tokens = provider.exchange_pkce_code(code, code_verifier).await?;
        self.registry.register(provider).await;
        *self.pending_tidal.write().await = None;
        Ok(tokens)
    }

    pub async fn configure_tidal_tokens(
        &self,
        config: TidalConfig,
        tokens: TidalTokenResponse,
    ) -> Result<(), ProviderError> {
        let provider = Arc::new(TidalProvider::live(
            config,
            Some(self.credential_store.clone()),
        ));
        provider.login_with_tokens(tokens).await?;
        self.registry.register(provider).await;
        Ok(())
    }

    pub async fn configure_deezer(
        &self,
        config: DeezerConfig,
        authenticate: bool,
    ) -> Result<Option<DeezerUser>, ProviderError> {
        let arl_opt = config.arl.clone();
        let provider = Arc::new(DeezerProvider::with_config(
            config,
            Some(self.credential_store.clone()),
        ));
        let user = if authenticate {
            let arl = arl_opt.ok_or_else(|| {
                ProviderError::AuthenticationFailed("Deezer ARL is required to authenticate".into())
            })?;
            Some(provider.login_with_arl(&arl).await?)
        } else {
            None
        };
        self.registry.register(provider).await;
        Ok(user)
    }

    pub async fn configure_webdav(&self, config: WebDavConfig) {
        let provider = Arc::new(WebDavProvider::new(
            config,
            Some(self.credential_store.clone()),
        ));
        self.registry.register(provider).await;
    }

    pub async fn configure_smb(
        &self,
        config: SmbConfig,
        transport: Option<Arc<dyn SmbTransport>>,
    ) {
        let provider = match transport {
            Some(t) => Arc::new(SmbProvider::with_transport(
                config,
                t,
                Some(self.credential_store.clone()),
            )),
            None => Arc::new(SmbProvider::new(
                config,
                Some(self.credential_store.clone()),
            )),
        };
        self.registry.register(provider).await;
    }

    /// Checks and hydrates stored credentials offline without failing startup.
    pub async fn initialize_credentials(&self) {
        for (svc, key) in [
            (DEFAULT_SERVICE_NAME, QOBUZ_KEYRING_TOKEN_KEY),
            (DEFAULT_SERVICE_NAME, QOBUZ_FALLBACK_TOKEN_KEY),
            (QOBUZ_CREDENTIAL_SERVICE, QOBUZ_KEYRING_TOKEN_KEY),
        ] {
            if let Ok(Some(token)) = self.credential_store.get_secret(svc, key).await {
                if !token.trim().is_empty() {
                    info!("Found saved Qobuz token in CredentialStore ({svc}/{key})");
                    if !self.registry.is_registered(ProviderKind::Qobuz).await {
                        if let Ok(cfg) = QobuzConfig::from_token(token) {
                            let prov = Arc::new(QobuzProvider::live(
                                cfg,
                                Some(self.credential_store.clone()),
                            ));
                            self.registry.register(prov).await;
                        }
                    }
                    break;
                }
            }
        }

        if let Ok(Some(secret)) = self
            .credential_store
            .get_secret(TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH)
            .await
        {
            if let Ok(tokens) = serde_json::from_str::<TidalTokenResponse>(&secret) {
                let expired = is_token_expired(tokens.issued_at, tokens.expires_in, 60);
                info!("Found saved Tidal OAuth tokens (expired={expired})");
                if !self.registry.is_registered(ProviderKind::Tidal).await {
                    let prov = Arc::new(TidalProvider::new(Some(self.credential_store.clone())));
                    let _ = prov.login_with_tokens(tokens).await;
                    self.registry.register(prov).await;
                }
            }
        }

        if let Ok(Some(arl)) = self
            .credential_store
            .get_secret(DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL)
            .await
        {
            if validate_arl_cookie(&arl) {
                info!("Found saved Deezer ARL in CredentialStore");
                if !self.registry.is_registered(ProviderKind::Deezer).await {
                    let cfg = DeezerConfig::from_arl(arl);
                    let prov = Arc::new(DeezerProvider::with_config(
                        cfg,
                        Some(self.credential_store.clone()),
                    ));
                    self.registry.register(prov).await;
                }
            }
        }
    }

    pub async fn resolve_stream(
        &self,
        track: &TrackSource,
    ) -> Result<ResolvedStream, ProviderError> {
        let provider = self.registry.require(track.provider).await?;
        if provider.kind().is_streaming() && !provider.is_authenticated().await {
            return Err(ProviderError::Unauthenticated(format!(
                "Provider '{}' is unauthenticated",
                provider.kind()
            )));
        }
        let stream = provider.resolve_stream(track).await?;
        Ok(stream.with_replay_gain_from_track(track))
    }

    pub async fn search(&self, query: &str, limit_per_provider: usize) -> AggregatedSearchResult {
        let providers = self.registry.list_all().await;
        let mut join_set = JoinSet::new();

        for provider in providers {
            let caps = provider.capabilities();
            if !caps.supports_catalog_search {
                continue;
            }
            let q = query.to_string();
            let p = provider.clone();
            join_set.spawn(async move {
                let kind = p.kind();
                let res = p.search(&q, limit_per_provider).await;
                (kind, res)
            });
        }

        let mut aggregated_albums = Vec::new();
        let mut provider_errors = Vec::new();

        while let Some(res) = join_set.join_next().await {
            match res {
                Ok((_kind, Ok(albums))) => {
                    aggregated_albums.extend(albums);
                }
                Ok((kind, Err(e))) => {
                    warn!("Search on provider {kind} failed: {e}");
                    provider_errors.push((kind, e.to_string()));
                }
                Err(panic_err) => {
                    error!("Provider search task panicked: {panic_err}");
                }
            }
        }

        AggregatedSearchResult {
            query: query.to_string(),
            albums: aggregated_albums,
            provider_errors,
        }
    }

    pub async fn sync_provider(&self, kind: ProviderKind) -> Result<SyncResult, ProviderError> {
        let provider = self.registry.require(kind).await?;
        provider.sync_library().await
    }

    pub async fn sync_all(&self) -> Vec<(ProviderKind, Result<SyncResult, ProviderError>)> {
        let providers = self.registry.list_all().await;
        let mut results = Vec::new();
        for p in providers {
            if p.capabilities().supports_filesystem_scan {
                let res = p.sync_library().await;
                results.push((p.kind(), res));
            }
        }
        results
    }

    pub async fn sync_and_persist(
        &self,
        pool: &SqlitePool,
    ) -> Result<(Vec<(ProviderKind, Result<SyncResult, ProviderError>)>, SyncPersistReport), ProviderError>
    {
        let sync_results = self.sync_all().await;
        let mut total_report = SyncPersistReport::default();

        for (kind, res) in &sync_results {
            if let Ok(sync) = res {
                let album_meta = if let Some(provider) = self.registry.get(*kind).await {
                    provider.last_sync_album_metadata().await
                } else {
                    std::collections::HashMap::new()
                };
                let rep =
                    LibrarySyncService::persist_sync_result_with_metadata(pool, sync, &album_meta)
                        .await?;
                total_report.albums_inserted += rep.albums_inserted;
                total_report.albums_matched += rep.albums_matched;
                total_report.albums_merged += rep.albums_merged;
                total_report.versions_upserted += rep.versions_upserted;
                total_report.tracks_upserted += rep.tracks_upserted;
                total_report.search_index_entries = rep.search_index_entries;
            }
        }

        Ok((sync_results, total_report))
    }
}
