-- Migration 0012: Library Step 5 — Playlist Improver Snapshots,
-- Album Assets (PDF booklets & gallery images, zero BLOBs), and Backup History / Preferences.
-- Additive only (migrations 0001..0011 remain immutable).

-- 1. Playlist Improver Undo Snapshots
CREATE TABLE IF NOT EXISTS playlist_snapshots (
    id TEXT PRIMARY KEY,
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    snapshot_json TEXT NOT NULL,
    reason TEXT NOT NULL DEFAULT 'improver',
    track_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_playlist_snapshots_playlist
    ON playlist_snapshots(playlist_id, created_at DESC);

-- 2. Album Version Assets (PDF booklets & gallery images; strict metadata-only, NO BLOB columns)
CREATE TABLE IF NOT EXISTS album_assets (
    id TEXT PRIMARY KEY,
    album_version_id TEXT NOT NULL REFERENCES album_versions(id) ON DELETE CASCADE,
    asset_kind TEXT NOT NULL CHECK (asset_kind IN ('pdf', 'image')),
    source_kind TEXT NOT NULL CHECK (source_kind IN ('file', 'embedded')),
    role TEXT NOT NULL CHECK (role IN ('front', 'back', 'media', 'booklet', 'other')),
    file_path TEXT,
    embedded_track_id TEXT REFERENCES track_sources(id) ON DELETE CASCADE,
    embedded_pic_index INTEGER,
    mime_type TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    file_size INTEGER,
    display_name TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_album_assets_file_unique
    ON album_assets(album_version_id, file_path)
    WHERE source_kind = 'file' AND file_path IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_album_assets_embedded_unique
    ON album_assets(album_version_id, embedded_track_id, embedded_pic_index)
    WHERE source_kind = 'embedded'
      AND embedded_track_id IS NOT NULL
      AND embedded_pic_index IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_album_assets_version_sort
    ON album_assets(album_version_id, asset_kind, sort_order, id);

-- 3. Database Backup History
CREATE TABLE IF NOT EXISTS backup_history (
    id TEXT PRIMARY KEY,
    trigger_mode TEXT NOT NULL CHECK (trigger_mode IN ('manual', 'scheduled', 'pre_restore')),
    backup_path TEXT NOT NULL,
    manifest_path TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    schema_version INTEGER NOT NULL DEFAULT 12,
    status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'failed', 'pruned')),
    error_message TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_backup_history_created
    ON backup_history(created_at DESC);

-- 4. Seed default backup preferences (idempotent)
INSERT OR IGNORE INTO app_preferences (key, value, updated_at)
VALUES
    ('backup_dir', '', datetime('now')),
    ('backup_schedule_mode', 'off', datetime('now')),
    ('backup_max_keep', '10', datetime('now'));
