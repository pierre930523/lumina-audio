pub mod album_assets;
pub mod album_groups;
pub mod artwork;
pub mod backup_export;
pub mod bookmarks;
pub mod bulk_edit;
pub mod catalog;
pub mod cleanup;
pub mod focus;
pub mod folders;
pub mod ingestion;
pub mod listen_later;
pub mod metadata;
pub mod models;
pub mod playlist_improver;
pub mod preferences;
pub mod scan;
pub mod search;
pub mod smart_playlists;
pub mod tags;
pub mod track_actions;

pub use album_assets::*;
pub use album_groups::*;
pub use artwork::*;
pub use backup_export::*;
pub use bookmarks::*;
pub use bulk_edit::*;
pub use catalog::*;
pub use cleanup::*;
pub use focus::*;
pub use folders::*;
pub use ingestion::*;
pub use listen_later::*;
pub use metadata::*;
pub use models::*;
pub use playlist_improver::*;
pub use preferences::*;
pub use scan::*;
pub use search::*;
pub use smart_playlists::*;
pub use tags::*;
pub use track_actions::*;

use crate::state::AppState;
use axum::Router;
use axum::routing::{delete, get, post, put};
use std::sync::Arc;

/// Registers all 22 Library Step 5 protected routes (Static Playlists & Improver,
/// Bulk Editor, Album Assets, WAL Backup/Restore, and Catalog/Audio Export).
pub fn step5_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/api/v1/library/playlists",
            get(get_static_playlists).post(post_create_static_playlist),
        )
        .route(
            "/api/v1/library/playlists/{id}",
            get(get_static_playlist_detail).delete(delete_static_playlist),
        )
        .route(
            "/api/v1/library/playlists/{id}/tracks",
            post(post_add_tracks_to_static_playlist),
        )
        .route(
            "/api/v1/library/playlists/{id}/improvements",
            get(get_playlist_improvements),
        )
        .route(
            "/api/v1/library/playlists/{id}/improvements/apply",
            post(post_apply_playlist_improvements),
        )
        .route(
            "/api/v1/library/playlists/{id}/snapshots",
            get(get_playlist_snapshots),
        )
        .route(
            "/api/v1/library/playlists/snapshots/{snapshot_id}/revert",
            post(post_revert_playlist_snapshot),
        )
        .route(
            "/api/v1/library/bulk-edit/summary",
            post(post_bulk_edit_summary),
        )
        .route(
            "/api/v1/library/bulk-edit/apply",
            post(post_bulk_edit_apply),
        )
        .route("/api/v1/library/albums/{id}/assets", get(get_album_assets))
        .route(
            "/api/v1/library/assets/{asset_id}/content",
            get(get_album_asset_content),
        )
        .route(
            "/api/v1/library/backups/settings",
            get(get_backup_settings).put(put_backup_settings),
        )
        .route(
            "/api/v1/library/backups",
            get(get_backup_history).post(post_create_backup),
        )
        .route("/api/v1/library/backups/restore", post(post_restore_backup))
        .route("/api/v1/library/export/catalog", post(post_export_catalog))
        .route(
            "/api/v1/library/export/audio",
            post(post_start_audio_export),
        )
        .route(
            "/api/v1/library/export/audio/{job_id}",
            get(get_audio_export_progress),
        )
        .route(
            "/api/v1/library/export/audio/{job_id}/cancel",
            post(post_cancel_audio_export),
        )
        .route(
            "/api/v1/library/tracks/{track_id}/file-info",
            get(get_track_file_info),
        )
        .route(
            "/api/v1/library/tracks/{track_id}/hidden",
            put(put_track_hidden),
        )
        .route(
            "/api/v1/library/tracks/{track_id}/rescan",
            post(post_rescan_track),
        )
        .route(
            "/api/v1/library/tracks/{track_id}/reidentify",
            post(post_reidentify_track),
        )
        .route(
            "/api/v1/library/tracks/{track_id}/reanalyze",
            post(post_reanalyze_track),
        )
        .route(
            "/api/v1/library/tracks/{track_id}/delete",
            post(post_delete_track),
        )
        .route(
            "/api/v1/library/tracks/{track_id}",
            delete(delete_track_endpoint),
        )
}
