use crate::engine::{EngineState, get_engine};
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};
use core_db::{SqlitePool, open_test_database};
use core_providers::{
    DeezerConfig, LibrarySyncService, LocalProviderConfig, ProviderRegistry, QobuzConfig,
    SmbConfig, TidalConfig, WebDavConfig, parse_remote_share_uri,
};
use core_types::{ProviderKind, QobuzAuthMode};
use serde::Deserialize;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::str::FromStr;

fn ensure_db_pool(engine: &EngineState) -> anyhow::Result<SqlitePool> {
    if let Ok(guard) = engine.db_pool.read()
        && let Some(ref pool) = *guard
    {
        return Ok(pool.clone());
    }
    let pool = engine.runtime.block_on(open_test_database())?;
    if let Ok(mut guard) = engine.db_pool.write() {
        *guard = Some(pool.clone());
    }
    Ok(pool)
}

#[derive(Debug, Deserialize)]
struct QobuzCfgJson {
    user_auth_token: Option<String>,
    username: Option<String>,
    password: Option<String>,
    app_id: Option<String>,
    app_secret: Option<String>,
    base_url: Option<String>,
    authenticate: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct DeezerCfgJson {
    arl: String,
    api_base_url: Option<String>,
    gw_base_url: Option<String>,
    media_base_url: Option<String>,
    authenticate: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct RemoteShareCfgJson {
    uri: String,
    domain: Option<String>,
}

#[derive(Debug, Deserialize)]
struct LocalCfgJson {
    root_paths: Vec<String>,
    follow_symlinks: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct TidalExchangeJson {
    code: String,
    code_verifier: String,
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_provider_configure(
    provider_kind: *const c_char,
    config_json: *const c_char,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_provider_configure", || {
        if provider_kind.is_null() || config_json.is_null() {
            set_last_error("provider_kind or config_json is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let kind_str = unsafe { CStr::from_ptr(provider_kind).to_str()? };
        let cfg_str = unsafe { CStr::from_ptr(config_json).to_str()? };
        let kind = ProviderKind::from_str(kind_str).map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let engine = get_engine();
        engine.runtime.block_on(async {
            match kind {
                ProviderKind::Local => {
                    let req: LocalCfgJson = serde_json::from_str(cfg_str)?;
                    engine
                        .provider_manager
                        .configure_local(LocalProviderConfig {
                            root_paths: req.root_paths.into_iter().map(PathBuf::from).collect(),
                            follow_symlinks: req.follow_symlinks.unwrap_or(false),
                        })
                        .await;
                }
                ProviderKind::Qobuz => {
                    let req: QobuzCfgJson = serde_json::from_str(cfg_str)?;
                    let auth =
                        if let Some(tok) = req.user_auth_token.filter(|s| !s.trim().is_empty()) {
                            QobuzAuthMode::token(tok, req.app_id, req.app_secret)
                                .map_err(|e| anyhow::anyhow!(e.to_string()))?
                        } else if let (Some(u), Some(p)) = (req.username, req.password) {
                            QobuzAuthMode::credentials(u, p, req.app_id, req.app_secret)
                                .map_err(|e| anyhow::anyhow!(e.to_string()))?
                        } else {
                            return Err(anyhow::anyhow!(
                                "Qobuz config requires user_auth_token or username+password"
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
                    engine
                        .provider_manager
                        .configure_qobuz(cfg, req.authenticate.unwrap_or(false))
                        .await
                        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                }
                ProviderKind::Tidal => {
                    let cfg: TidalConfig = serde_json::from_str(cfg_str)?;
                    let _ = engine.provider_manager.start_tidal_pkce(cfg).await;
                }
                ProviderKind::Deezer => {
                    let req: DeezerCfgJson = serde_json::from_str(cfg_str)?;
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
                    engine
                        .provider_manager
                        .configure_deezer(cfg, req.authenticate.unwrap_or(false))
                        .await
                        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                }
                ProviderKind::WebDav => {
                    let req: RemoteShareCfgJson = serde_json::from_str(cfg_str)?;
                    let uri = parse_remote_share_uri(&req.uri)
                        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                    engine
                        .provider_manager
                        .configure_webdav(WebDavConfig { uri })
                        .await;
                }
                ProviderKind::Smb => {
                    let req: RemoteShareCfgJson = serde_json::from_str(cfg_str)?;
                    let uri = parse_remote_share_uri(&req.uri)
                        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                    engine
                        .provider_manager
                        .configure_smb(
                            SmbConfig {
                                uri,
                                domain: req.domain,
                            },
                            None,
                        )
                        .await;
                }
                ProviderKind::AppleMusic | ProviderKind::YouTubeMusic => {
                    return Err(anyhow::anyhow!(
                        "Provider '{}' is configured via client streaming adapters",
                        kind
                    ));
                }
            }
            Ok::<_, anyhow::Error>(())
        })?;

        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_provider_sync(provider_kind: *const c_char) -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_provider_sync", || {
        if provider_kind.is_null() {
            set_last_error("provider_kind is null");
            return Ok(std::ptr::null_mut());
        }
        let kind_str = unsafe { CStr::from_ptr(provider_kind).to_str()? };
        let kind = ProviderKind::from_str(kind_str).map_err(|e| anyhow::anyhow!(e.to_string()))?;

        let engine = get_engine();
        let pool = ensure_db_pool(&engine)?;

        let json_val = engine.runtime.block_on(async {
            let sync = engine
                .provider_manager
                .sync_provider(kind)
                .await
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let meta = if let Some(prov) = engine.provider_manager.registry().get(kind).await {
                prov.last_sync_album_metadata().await
            } else {
                std::collections::HashMap::new()
            };
            let persist_report =
                LibrarySyncService::persist_sync_result_with_metadata(&pool, &sync, &meta)
                    .await
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok::<_, anyhow::Error>(serde_json::json!({
                "provider": kind.as_str(),
                "scanned_files": sync.scanned_files_count,
                "albums_count": sync.albums.len(),
                "tracks_count": sync.tracks.len(),
                "errors_count": sync.errors.len(),
                "persist_report": persist_report,
            }))
        })?;

        let json_str = serde_json::to_string(&json_val)?;
        Ok(string_to_c_char(&json_str))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_provider_tidal_pkce_start() -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_provider_tidal_pkce_start",
        || {
            let engine = get_engine();
            let session = engine.runtime.block_on(
                engine
                    .provider_manager
                    .start_tidal_pkce(TidalConfig::default()),
            );
            let json_str = serde_json::to_string(&session)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_provider_tidal_pkce_complete(exchange_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_provider_tidal_pkce_complete",
        || {
            if exchange_json.is_null() {
                set_last_error("exchange_json is null");
                return Ok(std::ptr::null_mut());
            }
            let raw = unsafe { CStr::from_ptr(exchange_json).to_str()? };
            let req: TidalExchangeJson = serde_json::from_str(raw)?;
            let engine = get_engine();
            let tokens = engine
                .runtime
                .block_on(
                    engine
                        .provider_manager
                        .complete_tidal_pkce(&req.code, &req.code_verifier),
                )
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&tokens)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_provider_list() -> *mut c_char {
    catch_unwind_ffi(std::ptr::null_mut(), "lumina_provider_list", || {
        let engine = get_engine();
        let items: Vec<serde_json::Value> = engine.runtime.block_on(async {
            let summaries = engine.provider_manager.summaries().await;
            if !summaries.is_empty() {
                return summaries
                    .into_iter()
                    .map(|s| {
                        serde_json::json!({
                            "provider_kind": s.kind.as_str(),
                            "is_configured": true,
                            "is_online": s.is_authenticated,
                        })
                    })
                    .collect();
            }
            let registry = ProviderRegistry::new();
            let providers = registry.list_all().await;
            let mut out = Vec::with_capacity(providers.len());
            for p in providers {
                let is_auth = p.is_authenticated().await;
                out.push(serde_json::json!({
                    "provider_kind": p.kind().as_str(),
                    "is_configured": true,
                    "is_online": is_auth,
                }));
            }
            out
        });
        let json_str = serde_json::to_string(&items)?;
        Ok(string_to_c_char(&json_str))
    })
}
