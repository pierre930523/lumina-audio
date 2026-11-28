pub mod album_assets;
pub mod album_groups;
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
pub mod overrides;
pub mod playlist_improver;
pub mod preferences;
pub mod smart_playlists;
pub mod tags;
pub mod track_actions;

pub use album_assets::*;
pub use album_groups::*;
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
pub use overrides::*;
pub use playlist_improver::*;
pub use preferences::*;
pub use smart_playlists::*;
pub use tags::*;
pub use track_actions::*;

use crate::engine::EngineState;
use core_db::{SqlitePool, open_test_database};
use std::path::{Path, PathBuf};

pub(crate) fn ensure_db_pool(engine: &EngineState) -> anyhow::Result<SqlitePool> {
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

/// Resolves the shared local artwork cache directory for both FFI and embedded HTTP server.
pub(crate) fn resolve_artwork_cache_dir(engine: &EngineState) -> PathBuf {
    let dir = if let Ok(guard) = engine.db_path.read()
        && let Some(ref db_path) = *guard
        && let Some(parent) = Path::new(db_path).parent()
    {
        parent.join("artwork_cache")
    } else {
        std::env::temp_dir().join("lumina_artwork_cache")
    };
    let _ = std::fs::create_dir_all(&dir);
    dir
}
