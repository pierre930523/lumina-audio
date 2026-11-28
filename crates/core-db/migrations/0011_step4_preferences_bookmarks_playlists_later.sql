-- Migration 0011: Library Step 4 — Tri-State Preferences, Dynamic Bookmarks,
-- Unified Smart Playlists (FocusQuery-backed), and Listen Later (library + external snapshots).
-- Additive only (migrations 0001..0010 remain immutable).

-- 1. Tri-state preference (-1 = Banned, 0 = Neutral, 1 = Favorite)
ALTER TABLE track_sources ADD COLUMN preference INTEGER NOT NULL DEFAULT 0
    CHECK (preference IN (-1, 0, 1));
CREATE INDEX IF NOT EXISTS idx_track_sources_preference
    ON track_sources(preference);

ALTER TABLE canonical_albums ADD COLUMN preference INTEGER NOT NULL DEFAULT 0
    CHECK (preference IN (-1, 0, 1));
CREATE INDEX IF NOT EXISTS idx_canonical_albums_preference
    ON canonical_albums(preference);

ALTER TABLE artists ADD COLUMN preference INTEGER NOT NULL DEFAULT 0
    CHECK (preference IN (-1, 0, 1));
CREATE INDEX IF NOT EXISTS idx_artists_preference
    ON artists(preference);

-- Backfill preference = 1 from existing profile_favorites
UPDATE track_sources
SET preference = 1
WHERE preference = 0
  AND EXISTS (
      SELECT 1
      FROM profile_favorites pf
      WHERE pf.item_type = 'track'
        AND pf.item_id = track_sources.id
  );

UPDATE canonical_albums
SET preference = 1
WHERE preference = 0
  AND EXISTS (
      SELECT 1
      FROM profile_favorites pf
      WHERE pf.item_type = 'album'
        AND pf.item_id = canonical_albums.id
  );

UPDATE artists
SET preference = 1
WHERE preference = 0
  AND EXISTS (
      SELECT 1
      FROM profile_favorites pf
      WHERE pf.item_type = 'artist'
        AND pf.item_id = artists.id
  );

-- 2. Dynamic Bookmarks
CREATE TABLE IF NOT EXISTS bookmarks (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    target_route TEXT NOT NULL,
    focus_query_json TEXT,
    view_state_json TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_bookmarks_sort
    ON bookmarks(sort_order, created_at);

-- 3. Unified Smart Playlists backed by FocusQuery
CREATE TABLE IF NOT EXISTS smart_playlists (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    focus_query_json TEXT NOT NULL,
    exclude_banned INTEGER NOT NULL DEFAULT 1,
    limit_count INTEGER,
    is_pinned INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_system_seed INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_smart_playlists_sort
    ON smart_playlists(is_pinned DESC, sort_order ASC, created_at ASC);

-- Seed 4 built-in presets (idempotent)
INSERT OR IGNORE INTO smart_playlists
    (id, name, description, focus_query_json, exclude_banned, limit_count, is_pinned, sort_order, is_system_seed, created_at, updated_at)
VALUES
    (
        'sp-hires',
        'Hi-Res 高解析精選',
        'Lossless tracks with sample rate >= 96 kHz',
        '{"entity":"tracks","predicates":[{"facet":"format","value":{"kind":"string","value":"lossless"},"mode":"include"},{"facet":"sample_rate","value":{"kind":"int_range","min":96000},"mode":"include"}]}',
        1,
        NULL,
        1,
        0,
        1,
        datetime('now'),
        datetime('now')
    ),
    (
        'sp-lossless',
        '無損母帶純享',
        'All lossless tracks in library',
        '{"entity":"tracks","predicates":[{"facet":"format","value":{"kind":"string","value":"lossless"},"mode":"include"}]}',
        1,
        NULL,
        1,
        1,
        1,
        datetime('now'),
        datetime('now')
    ),
    (
        'sp-dsd',
        'DSD 原生軌典藏',
        'Native DSD tracks (DSF/DSDIFF)',
        '{"entity":"tracks","predicates":[{"facet":"format","value":{"kind":"string","value":"dsd"},"mode":"include"}]}',
        1,
        NULL,
        1,
        2,
        1,
        datetime('now'),
        datetime('now')
    ),
    (
        'sp-all',
        '工作室全曲庫',
        'All library tracks',
        '{"entity":"tracks","predicates":[]}',
        1,
        NULL,
        1,
        3,
        1,
        datetime('now'),
        datetime('now')
    );

-- 4. Listen Later (library references + external streaming metadata snapshots)
CREATE TABLE IF NOT EXISTS listen_later_items (
    id TEXT PRIMARY KEY,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('library', 'external')),
    entity_type TEXT NOT NULL CHECK (entity_type IN ('album', 'track')),
    entity_id TEXT,
    provider_id TEXT,
    external_id TEXT,
    title TEXT NOT NULL,
    artist_name TEXT NOT NULL DEFAULT '',
    album_title TEXT NOT NULL DEFAULT '',
    cover_url TEXT,
    track_count INTEGER,
    metadata_json TEXT,
    note TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'listened')),
    added_at TEXT NOT NULL,
    listened_at TEXT,
    promoted_entity_id TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_listen_later_lib_unique
    ON listen_later_items(entity_type, entity_id)
    WHERE source_kind = 'library' AND entity_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_listen_later_ext_unique
    ON listen_later_items(provider_id, entity_type, external_id)
    WHERE source_kind = 'external' AND provider_id IS NOT NULL AND external_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_listen_later_status
    ON listen_later_items(status, added_at DESC);
