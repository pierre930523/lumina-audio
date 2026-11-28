use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, State};
use core_providers::{
    DeezerConfig, LocalProviderConfig, ProviderRegistry, QobuzConfig, SmbConfig, TidalConfig,
    WebDavConfig, parse_remote_share_uri,
};
use core_types::{ProviderKind, QobuzAuthMode};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;

#[derive(Debug, Serialize)]
pub struct ProviderStatusDto {
    pub provider_kind: String,
    pub is_configured: bool,
    pub is_online: bool,
}

#[derive(Debug, Deserialize)]
pub struct ConfigureQobuzRequest {
    pub user_auth_token: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub app_id: Option<String>,
    pub app_secret: Option<String>,
    pub base_url: Option<String>,
    pub authenticate: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct TidalPkceStartRequest {
    pub client_id: Option<String>,
    pub redirect_uri: Option<String>,
    pub auth_base_url: Option<String>,
    pub api_base_url: Option<String>,
    pub scopes: Option<String>,
    pub country_code: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TidalPkceExchangeRequest {
    pub code: String,
    pub code_verifier: String,
}

#[derive(Debug, Deserialize)]
pub struct ConfigureDeezerRequest {
    pub arl: String,
    pub api_base_url: Option<String>,
    pub gw_base_url: Option<String>,
    pub media_base_url: Option<String>,
    pub authenticate: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct ConfigureRemoteShareRequest {
    pub uri: String,
    pub domain: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ConfigureLocalRequest {
    pub root_paths: Vec<String>,
    pub follow_symlinks: Option<bool>,
}

pub async fn list_providers(State(state): State<Arc<AppState>>) -> Json<Vec<ProviderStatusDto>> {
    let summaries = state.provider_manager.summaries().await;
    if !summaries.is_empty() {
        return Json(
            summaries
                .into_iter()
                .map(|s| ProviderStatusDto {
                    provider_kind: s.kind.as_str().to_string(),
                    is_configured: true,
                    is_online: s.is_authenticated,
                })
                .collect(),
        );
    }

    let registry = ProviderRegistry::new();
    let providers = registry.list_all().await;
    let mut dtos = Vec::with_capacity(providers.len());
    for p in providers {
        let is_auth = p.is_authenticated().await;
        dtos.push(ProviderStatusDto {
            provider_kind: p.kind().as_str().to_string(),
            is_configured: true,
            is_online: is_auth,
        });
    }
    Json(dtos)
}

pub async fn configure_qobuz(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ConfigureQobuzRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let auth = if let Some(tok) = req.user_auth_token.filter(|s| !s.trim().is_empty()) {
        QobuzAuthMode::token(tok, req.app_id, req.app_secret)
            .map_err(|e| ServerError::BadRequest(e.to_string()))?
    } else if let (Some(u), Some(p)) = (req.username, req.password) {
        QobuzAuthMode::credentials(u, p, req.app_id, req.app_secret)
            .map_err(|e| ServerError::BadRequest(e.to_string()))?
    } else {
        return Err(ServerError::BadRequest(
            "Qobuz requires user_auth_token or username+password".to_string(),
        ));
    };

    let mut cfg = QobuzConfig {
        auth,
        base_url: core_providers::qobuz::config::DEFAULT_QOBUZ_BASE_URL.to_string(),
        default_format_id: None,
    };
    if let Some(base) = req.base_url.filter(|s| !s.trim().is_empty()) {
        cfg.base_url = base;
    }

    let authenticate = req.authenticate.unwrap_or(true);
    let session = state
        .provider_manager
        .configure_qobuz(cfg, authenticate)
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;

    Ok(Json(serde_json::json!({
        "status": "configured",
        "provider": "qobuz",
        "authenticated": session.is_some(),
    })))
}

pub async fn start_tidal_pkce(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<TidalPkceStartRequest>>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let req = payload.map(|Json(v)| v).unwrap_or(TidalPkceStartRequest {
        client_id: None,
        redirect_uri: None,
        auth_base_url: None,
        api_base_url: None,
        scopes: None,
        country_code: None,
    });
    let mut cfg = TidalConfig::default();
    if let Some(cid) = req.client_id.filter(|s| !s.trim().is_empty()) {
        cfg.client_id = cid;
    }
    if let Some(uri) = req.redirect_uri.filter(|s| !s.trim().is_empty()) {
        cfg.redirect_uri = uri;
    }
    if let Some(ab) = req.auth_base_url.filter(|s| !s.trim().is_empty()) {
        cfg.auth_base_url = ab;
    }
    if let Some(api) = req.api_base_url.filter(|s| !s.trim().is_empty()) {
        cfg.api_base_url = api;
    }
    if let Some(sc) = req.scopes.filter(|s| !s.trim().is_empty()) {
        cfg.scopes = sc;
    }
    if let Some(cc) = req.country_code.filter(|s| !s.trim().is_empty()) {
        cfg.country_code = cc;
    }

    let session = state.provider_manager.start_tidal_pkce(cfg).await;
    Ok(Json(serde_json::to_value(session).unwrap_or_default()))
}

pub async fn exchange_tidal_pkce(
    State(state): State<Arc<AppState>>,
    Json(req): Json<TidalPkceExchangeRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let tokens = state
        .provider_manager
        .complete_tidal_pkce(&req.code, &req.code_verifier)
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    Ok(Json(serde_json::to_value(tokens).unwrap_or_default()))
}

pub async fn configure_deezer(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ConfigureDeezerRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    if !core_providers::validate_arl_cookie(&req.arl) {
        return Err(ServerError::BadRequest(
            "Deezer ARL must be hex/underscore string >= 32 characters".to_string(),
        ));
    }
    let mut cfg = DeezerConfig::from_arl(req.arl);
    if let Some(api) = req.api_base_url.filter(|s| !s.trim().is_empty()) {
        cfg.api_base_url = api;
    }
    if let Some(gw) = req.gw_base_url.filter(|s| !s.trim().is_empty()) {
        cfg.gw_base_url = gw;
    }
    if let Some(media) = req.media_base_url.filter(|s| !s.trim().is_empty()) {
        cfg.media_base_url = media;
    }
    let authenticate = req.authenticate.unwrap_or(true);
    let user = state
        .provider_manager
        .configure_deezer(cfg, authenticate)
        .await
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;

    Ok(Json(serde_json::json!({
        "status": "configured",
        "provider": "deezer",
        "authenticated": user.is_some(),
        "user": user,
    })))
}

pub async fn configure_webdav(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ConfigureRemoteShareRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let uri =
        parse_remote_share_uri(&req.uri).map_err(|e| ServerError::BadRequest(e.to_string()))?;
    state
        .provider_manager
        .configure_webdav(WebDavConfig { uri })
        .await;
    Ok(Json(serde_json::json!({
        "status": "configured",
        "provider": "web_dav",
    })))
}

pub async fn configure_smb(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ConfigureRemoteShareRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let uri =
        parse_remote_share_uri(&req.uri).map_err(|e| ServerError::BadRequest(e.to_string()))?;
    state
        .provider_manager
        .configure_smb(
            SmbConfig {
                uri,
                domain: req.domain,
            },
            None,
        )
        .await;
    Ok(Json(serde_json::json!({
        "status": "configured",
        "provider": "smb",
    })))
}

pub async fn configure_local(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ConfigureLocalRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let cfg = LocalProviderConfig {
        root_paths: req.root_paths.into_iter().map(PathBuf::from).collect(),
        follow_symlinks: req.follow_symlinks.unwrap_or(false),
    };
    state.provider_manager.configure_local(cfg).await;
    Ok(Json(serde_json::json!({
        "status": "configured",
        "provider": "local",
    })))
}

pub async fn sync_provider(
    State(state): State<Arc<AppState>>,
    Path(kind_str): Path<String>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let kind =
        ProviderKind::from_str(&kind_str).map_err(|e| ServerError::BadRequest(e.to_string()))?;
    let sync = state
        .provider_manager
        .sync_provider(kind)
        .await
        .map_err(|e| ServerError::Internal(e.to_string()))?;

    let mut report_json = serde_json::json!({
        "provider": kind.as_str(),
        "scanned_files": sync.scanned_files_count,
        "albums_count": sync.albums.len(),
        "tracks_count": sync.tracks.len(),
        "errors_count": sync.errors.len(),
    });

    if let Some(ref pool) = state.db_pool {
        let meta = if let Some(prov) = state.provider_manager.registry().get(kind).await {
            prov.last_sync_album_metadata().await
        } else {
            std::collections::HashMap::new()
        };
        let rep = core_providers::LibrarySyncService::persist_sync_result_with_metadata(
            pool, &sync, &meta,
        )
        .await
        .map_err(|e| ServerError::Database(e.to_string()))?;
        report_json["persist_report"] = serde_json::to_value(rep).unwrap_or_default();
    }

    Ok(Json(report_json))
}
