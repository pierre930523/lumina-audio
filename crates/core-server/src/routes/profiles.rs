use crate::error::ServerError;
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use core_db::{
    DbError, LibraryRepository, PlayHistoryEntry, ProfileError, ProfileFavorite, ProfileRepository,
};
use core_types::Profile;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

#[derive(Debug, Serialize)]
pub struct ProfilesListResponse {
    pub active_profile_id: Option<String>,
    pub profiles: Vec<Profile>,
}

#[derive(Debug, Deserialize)]
pub struct CreateProfileRequest {
    pub name: String,
    pub avatar_color: Option<String>,
    pub is_default: Option<bool>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateProfileRequest {
    pub name: Option<String>,
    pub avatar_color: Option<String>,
    pub is_default: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ProfileActionResponse {
    pub status: String,
    pub active_profile_id: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
pub struct FavoritesQuery {
    pub item_type: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct FavoriteRequest {
    pub item_type: String,
    pub item_id: String,
}

#[derive(Debug, Deserialize, Default)]
pub struct HistoryQuery {
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct RecordHistoryRequest {
    pub track_source_id: String,
    pub duration_listened_ms: u64,
}

fn map_db_err(err: DbError) -> ServerError {
    match err {
        DbError::Profile(ProfileError::NotFound(m)) | DbError::NotFound(m) => {
            ServerError::NotFound(m)
        }
        DbError::Profile(pe) => ServerError::BadRequest(pe.to_string()),
        other => ServerError::Database(other.to_string()),
    }
}

pub async fn list_profiles(
    State(state): State<Arc<AppState>>,
) -> Result<Json<ProfilesListResponse>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Ok(Json(ProfilesListResponse {
            active_profile_id: Some("default".to_string()),
            profiles: vec![Profile::default_profile()],
        }));
    };

    let profiles = ProfileRepository::list_profiles(pool)
        .await
        .map_err(map_db_err)?;
    let mut active = state.active_profile_id.read().await.clone();
    if active.is_none() {
        active = profiles
            .iter()
            .find(|p| p.is_default)
            .or_else(|| profiles.first())
            .map(|p| p.id.clone());
        *state.active_profile_id.write().await = active.clone();
    }

    Ok(Json(ProfilesListResponse {
        active_profile_id: active,
        profiles,
    }))
}

pub async fn create_profile(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateProfileRequest>,
) -> Result<Json<Profile>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };

    let color = req.avatar_color.unwrap_or_else(|| "#007AFF".to_string());
    let prof = Profile::new(req.name, color, req.is_default.unwrap_or(false))
        .map_err(|e| ServerError::BadRequest(e.to_string()))?;
    let created = ProfileRepository::create_profile(pool, &prof)
        .await
        .map_err(map_db_err)?;

    if state.active_profile_id.read().await.is_none() || created.is_default {
        *state.active_profile_id.write().await = Some(created.id.clone());
    }

    Ok(Json(created))
}

pub async fn update_profile(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<UpdateProfileRequest>,
) -> Result<Json<Profile>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };

    let existing = ProfileRepository::get_profile(pool, &id)
        .await
        .map_err(map_db_err)?
        .ok_or_else(|| ServerError::NotFound(format!("Profile {id} not found")))?;

    let mut updated = existing.clone();
    if let Some(name) = req.name {
        updated.name = name;
    }
    if let Some(color) = req.avatar_color {
        updated.avatar_color = color;
    }
    if let Some(is_def) = req.is_default {
        updated.is_default = is_def;
    }

    let saved = ProfileRepository::update_profile(pool, &updated)
        .await
        .map_err(map_db_err)?;
    Ok(Json(saved))
}

pub async fn delete_profile(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<ProfileActionResponse>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };

    ProfileRepository::delete_profile(pool, &id)
        .await
        .map_err(map_db_err)?;

    let mut active = state.active_profile_id.write().await;
    if active.as_deref() == Some(id.as_str()) {
        *active = ProfileRepository::get_default_profile(pool)
            .await
            .ok()
            .map(|p| p.id);
    }

    Ok(Json(ProfileActionResponse {
        status: "deleted".to_string(),
        active_profile_id: active.clone(),
    }))
}

pub async fn activate_profile(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<ProfileActionResponse>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };

    let existing = ProfileRepository::get_profile(pool, &id)
        .await
        .map_err(map_db_err)?
        .ok_or_else(|| ServerError::NotFound(format!("Profile {id} not found")))?;

    *state.active_profile_id.write().await = Some(existing.id.clone());
    Ok(Json(ProfileActionResponse {
        status: "activated".to_string(),
        active_profile_id: Some(existing.id),
    }))
}

pub async fn list_favorites(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<FavoritesQuery>,
) -> Result<Json<Vec<ProfileFavorite>>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let favs = LibraryRepository::list_favorites_for_profile(pool, &id, query.item_type.as_deref())
        .await
        .map_err(map_db_err)?;
    Ok(Json(favs))
}

pub async fn add_favorite(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<FavoriteRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };
    LibraryRepository::add_favorite(pool, &id, &req.item_type, &req.item_id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(serde_json::json!({ "status": "added" })))
}

pub async fn remove_favorite(
    State(state): State<Arc<AppState>>,
    Path((id, target_id)): Path<(String, String)>,
    Query(query): Query<FavoritesQuery>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };
    let item_type = query.item_type.unwrap_or_else(|| "track".to_string());
    let removed = LibraryRepository::remove_favorite(pool, &id, &item_type, &target_id)
        .await
        .map_err(map_db_err)?;
    Ok(Json(serde_json::json!({ "removed": removed })))
}

pub async fn list_history(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<Vec<PlayHistoryEntry>>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Ok(Json(Vec::new()));
    };
    let hist = LibraryRepository::get_recent_history(pool, &id, query.limit.unwrap_or(50))
        .await
        .map_err(map_db_err)?;
    Ok(Json(hist))
}

pub async fn record_history(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<RecordHistoryRequest>,
) -> Result<Json<serde_json::Value>, ServerError> {
    let Some(ref pool) = state.db_pool else {
        return Err(ServerError::Database(
            "Database not initialized".to_string(),
        ));
    };
    let row_id =
        LibraryRepository::record_play(pool, &id, &req.track_source_id, req.duration_listened_ms)
            .await
            .map_err(map_db_err)?;
    Ok(Json(serde_json::json!({ "id": row_id })))
}
