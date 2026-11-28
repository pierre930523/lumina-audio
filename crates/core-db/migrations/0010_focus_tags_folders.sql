-- Migration 0010: Library Step 3 — Focus Engine Indexes, Custom Nested Tags & Physical Folder Browsing
-- Additive only (migrations 0001..0009 remain immutable).

-- 1. Custom Nested Tags (DAG with multi-parent / multi-child support)
CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL UNIQUE,
    color TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tag_links (
    parent_tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    child_tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    PRIMARY KEY (parent_tag_id, child_tag_id),
    CHECK (parent_tag_id != child_tag_id)
);

CREATE INDEX IF NOT EXISTS idx_tag_links_child
    ON tag_links(child_tag_id);

CREATE TABLE IF NOT EXISTS tag_items (
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL CHECK (entity_type IN ('album_group', 'track', 'artist')),
    entity_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (tag_id, entity_type, entity_id)
);

CREATE INDEX IF NOT EXISTS idx_tag_items_entity
    ON tag_items(entity_type, entity_id);

-- 2. Materialized Physical Folder Tree
CREATE TABLE IF NOT EXISTS library_folders (
    id TEXT PRIMARY KEY,
    root_id TEXT REFERENCES watched_roots(id) ON DELETE SET NULL,
    parent_id TEXT REFERENCES library_folders(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    norm_path TEXT NOT NULL UNIQUE,
    display_path TEXT NOT NULL,
    depth INTEGER NOT NULL DEFAULT 0,
    direct_track_count INTEGER NOT NULL DEFAULT 0,
    recursive_track_count INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_library_folders_parent
    ON library_folders(parent_id, name);

CREATE INDEX IF NOT EXISTS idx_library_folders_root
    ON library_folders(root_id);

CREATE INDEX IF NOT EXISTS idx_library_folders_recursive_count
    ON library_folders(recursive_track_count);

-- 3. Additive columns on track_sources for Folder linkage, Date Added, and Record Label
ALTER TABLE track_sources ADD COLUMN folder_id TEXT REFERENCES library_folders(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_track_sources_folder
    ON track_sources(folder_id, file_status);

ALTER TABLE track_sources ADD COLUMN added_at TEXT;

UPDATE track_sources
SET added_at = COALESCE(
    (
        SELECT ca.created_at
        FROM album_versions av
        JOIN canonical_albums ca ON ca.id = av.canonical_album_id
        WHERE av.id = track_sources.version_id
    ),
    CASE WHEN file_mtime IS NOT NULL THEN datetime(file_mtime, 'unixepoch') END,
    datetime('now')
)
WHERE added_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_track_sources_added_at
    ON track_sources(added_at);

ALTER TABLE track_sources ADD COLUMN record_label TEXT;

CREATE INDEX IF NOT EXISTS idx_track_sources_record_label
    ON track_sources(record_label);

-- 4. Additive record_label column on canonical_albums
ALTER TABLE canonical_albums ADD COLUMN record_label TEXT;

CREATE INDEX IF NOT EXISTS idx_canonical_albums_record_label
    ON canonical_albums(record_label);
