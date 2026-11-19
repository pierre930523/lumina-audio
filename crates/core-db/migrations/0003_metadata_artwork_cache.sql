-- Migration 0003: Rich track/album metadata, incremental file scan cache, artwork cache & user overrides.

ALTER TABLE canonical_albums ADD COLUMN album_artist TEXT;

ALTER TABLE track_sources ADD COLUMN artist_name TEXT;
ALTER TABLE track_sources ADD COLUMN album_artist TEXT;
ALTER TABLE track_sources ADD COLUMN genre TEXT;
ALTER TABLE track_sources ADD COLUMN composer TEXT;
ALTER TABLE track_sources ADD COLUMN channels INTEGER NOT NULL DEFAULT 2;
ALTER TABLE track_sources ADD COLUMN is_dsd INTEGER NOT NULL DEFAULT 0;
ALTER TABLE track_sources ADD COLUMN embedded_lyrics TEXT;
ALTER TABLE track_sources ADD COLUMN file_mtime INTEGER;
ALTER TABLE track_sources ADD COLUMN file_size INTEGER;
ALTER TABLE track_sources ADD COLUMN metadata_hash TEXT;

-- Backfill existing rows from 0001/0002
UPDATE track_sources
SET is_dsd = 1
WHERE LOWER(codec) IN ('dsf', 'dsdiff') AND is_dsd = 0;

UPDATE track_sources
SET channels = COALESCE(
    (SELECT av.channels FROM album_versions av WHERE av.id = track_sources.version_id),
    2
)
WHERE channels = 2;

-- Indexes for incremental cache checks, pruning, and metadata queries
CREATE INDEX IF NOT EXISTS idx_track_sources_provider_ext
    ON track_sources(provider_id, external_track_id);
CREATE INDEX IF NOT EXISTS idx_track_sources_provider_mtime
    ON track_sources(provider_id, file_mtime, file_size);
CREATE INDEX IF NOT EXISTS idx_track_sources_artist_name
    ON track_sources(artist_name);
CREATE INDEX IF NOT EXISTS idx_track_sources_genre
    ON track_sources(genre);

-- Artwork disk cache metadata (nullable FKs cascade when linked rows are deleted)
CREATE TABLE IF NOT EXISTS artwork_cache (
    cache_key TEXT PRIMARY KEY,
    track_id TEXT REFERENCES track_sources(id) ON DELETE CASCADE,
    album_id TEXT REFERENCES canonical_albums(id) ON DELETE CASCADE,
    source_kind TEXT NOT NULL,
    mime_type TEXT,
    width INTEGER,
    height INTEGER,
    max_dim INTEGER NOT NULL DEFAULT 0,
    cache_path TEXT NOT NULL,
    source_mtime INTEGER,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_artwork_cache_track_id ON artwork_cache(track_id);
CREATE INDEX IF NOT EXISTS idx_artwork_cache_album_id ON artwork_cache(album_id);

-- User-specified external artwork overrides
CREATE TABLE IF NOT EXISTS artwork_overrides (
    target_kind TEXT NOT NULL CHECK (target_kind IN ('track', 'album')),
    target_id TEXT NOT NULL,
    image_path TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (target_kind, target_id)
);

CREATE INDEX IF NOT EXISTS idx_artwork_overrides_target_id
    ON artwork_overrides(target_id);
