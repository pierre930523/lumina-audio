pub mod library;
pub mod lyrics;
pub mod pair;
pub mod playback;
pub mod profiles;
pub mod providers;
pub mod zones;

use crate::middleware::{auth_middleware, build_body_limit_layer, build_cors_layer};
use crate::state::AppState;
use crate::ws::ws_handler;
use axum::middleware;
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use std::sync::Arc;

async fn get_health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

async fn get_info() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "name": "Lumina Audio Server",
        "version": env!("CARGO_PKG_VERSION"),
        "api_version": 1,
        "capabilities": ["rest", "ws", "mdns", "dsp", "providers", "enrichment", "profiles", "zones"],
    }))
}

pub fn build_router(state: Arc<AppState>) -> Router {
    // Protected routes requiring Bearer authentication
    let protected_routes = Router::new()
        .route("/api/v1/playback/state", get(playback::get_playback_state))
        .route("/api/v1/playback/play", post(playback::post_play))
        .route("/api/v1/playback/pause", post(playback::post_pause))
        .route("/api/v1/playback/resume", post(playback::post_resume))
        .route("/api/v1/playback/reconnect", post(playback::post_reconnect))
        .route("/api/v1/playback/stop", post(playback::post_stop))
        .route("/api/v1/playback/seek", post(playback::post_seek))
        .route("/api/v1/playback/next", post(playback::post_next))
        .route("/api/v1/playback/previous", post(playback::post_previous))
        .route("/api/v1/playback/volume", post(playback::post_volume))
        .route("/api/v1/dsp/config", get(playback::get_dsp_config).put(playback::put_dsp_config))
        .route("/api/v1/dsp/autoeq", post(playback::post_dsp_autoeq))
        .route("/api/v1/signal-path", get(playback::get_signal_path))
        .route("/api/v1/audio/devices", get(playback::list_audio_devices))
        .route("/api/v1/audio/devices/select", post(playback::select_audio_device))
        .route("/api/v1/library/albums", get(library::get_albums))
        .route("/api/v1/library/albums/{id}", get(library::get_album_detail))
        .route("/api/v1/library/albums/{id}/credits", get(library::get_album_credits))
        .route("/api/v1/library/artists/{id}", get(library::get_artist_detail))
        .route("/api/v1/library/tracks", get(library::get_tracks))
        .route("/api/v1/library/artwork/{track_id}", get(library::get_artwork))
        .route(
            "/api/v1/library/artwork/{track_id}/override",
            post(library::post_artwork_override).delete(library::delete_artwork_override),
        )
        .route("/api/v1/library/scan", post(library::post_scan_library))
        .route("/api/v1/library/rescan", post(library::post_rescan_library))
        .route("/api/v1/library/search", get(library::search_library))
        .route("/api/v1/library/deduplicate", post(library::post_deduplicate))
        .route("/api/v1/library/enrich", post(library::post_enrich))
        .route("/api/v1/lyrics/{track_id}", get(lyrics::get_lyrics))
        .route(
            "/api/v1/lyrics/{track_id}/override",
            post(lyrics::post_lyrics_override).delete(lyrics::delete_lyrics_override),
        )
        .route("/api/v1/profiles", get(profiles::list_profiles).post(profiles::create_profile))
        .route(
            "/api/v1/profiles/{id}",
            put(profiles::update_profile).delete(profiles::delete_profile),
        )
        .route("/api/v1/profiles/{id}/activate", post(profiles::activate_profile))
        .route(
            "/api/v1/profiles/{id}/favorites",
            get(profiles::list_favorites).post(profiles::add_favorite),
        )
        .route(
            "/api/v1/profiles/{id}/favorites/{target_id}",
            delete(profiles::remove_favorite),
        )
        .route(
            "/api/v1/profiles/{id}/history",
            get(profiles::list_history).post(profiles::record_history),
        )
        .route("/api/v1/providers", get(providers::list_providers))
        .route("/api/v1/providers/list", get(providers::list_providers))
        .route("/api/v1/providers/qobuz", post(providers::configure_qobuz))
        .route("/api/v1/providers/tidal/pkce/start", post(providers::start_tidal_pkce))
        .route("/api/v1/providers/tidal/pkce/exchange", post(providers::exchange_tidal_pkce))
        .route("/api/v1/providers/deezer", post(providers::configure_deezer))
        .route("/api/v1/providers/webdav", post(providers::configure_webdav))
        .route("/api/v1/providers/smb", post(providers::configure_smb))
        .route("/api/v1/providers/local", post(providers::configure_local))
        .route("/api/v1/providers/{kind}/sync", post(providers::sync_provider))
        .route("/api/v1/zones", get(zones::list_zones).post(zones::upsert_zone))
        .route("/api/v1/zones/discover", post(zones::discover_zones))
        .route("/api/v1/zones/group", post(zones::group_zones))
        .route("/api/v1/zones/{id}/sync", post(zones::sync_zone_clock))
        .route("/api/v1/zones/{id}/volume", post(zones::set_zone_volume))
        .route("/api/v1/zones/{id}/cast", post(zones::cast_to_zone))
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            auth_middleware,
        ));

    // Public routes (health, info, pairing & websocket with token validation inside handler)
    let public_routes = Router::new()
        .route("/api/v1/health", get(get_health))
        .route("/api/v1/info", get(get_info))
        .route("/api/v1/pair", post(pair::unified_pair))
        .route("/api/v1/pair/initiate", post(pair::initiate_pairing))
        .route("/api/v1/pair/verify", post(pair::verify_pairing))
        .route("/api/v1/ws", get(ws_handler));

    // Combine routers and apply global layers
    Router::new()
        .merge(public_routes)
        .merge(protected_routes)
        .with_state(state)
        .layer(build_cors_layer())
        .layer(build_body_limit_layer())
}
