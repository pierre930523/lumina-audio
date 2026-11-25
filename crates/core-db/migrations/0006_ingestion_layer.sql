-- Migration 0006: Layer 1 Ingestion Foundation
-- Adds watched roots, skipped files quarantine, layered non-destructive metadata overrides,
-- canonical tracks & multi-artist links, move/rename content fingerprints, version TOC signatures,
-- and sidecar playlist persistence.

CREATE TABLE IF NOT EXISTS watched_roots (
    id TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL,
    root_path TEXT NOT NULL UNIQUE,
    watch_mode TEXT NOT NULL DEFAULT 'native_os',
    poll_interval_sec INTEGER NOT NULL DEFAULT 300,
    is_online INTEGER NOT NULL DEFAULT 1,
    last_scan_at TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS skipped_files (
    id TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL,
    file_path TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    detail TEXT NOT NULL,
    file_size INTEGER,
    file_mtime INTEGER,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    dismissed INTEGER NOT NULL DEFAULT 0,
    UNIQUE(provider_id, file_path)
);

CREATE TABLE IF NOT EXISTS metadata_overrides (
    entity_type TEXT NOT NULL CHECK(entity_type IN ('track', 'album', 'artist')),
    entity_id TEXT NOT NULL,
    field_name TEXT NOT NULL,
    value_json TEXT NOT NULL,
    source_layer TEXT NOT NULL DEFAULT 'user_edit',
    updated_at TEXT NOT NULL,
    PRIMARY KEY (entity_type, entity_id, field_name)
);

CREATE TABLE IF NOT EXISTS canonical_tracks (
    id TEXT PRIMARY KEY,
    canonical_album_id TEXT NOT NULL REFERENCES canonical_albums(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    sort_title TEXT NOT NULL,
    artist_name TEXT NOT NULL,
    album_artist TEXT,
    disc_number INTEGER NOT NULL DEFAULT 1,
    track_number INTEGER NOT NULL DEFAULT 1,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    isrc TEXT,
    musicbrainz_recording_id TEXT,
    genre TEXT,
    composer TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS track_artists (
    canonical_track_id TEXT NOT NULL REFERENCES canonical_tracks(id) ON DELETE CASCADE,
    artist_id TEXT NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'performer',
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (canonical_track_id, artist_id, role)
);

CREATE TABLE IF NOT EXISTS playlists (
    id TEXT PRIMARY KEY,
    provider_id TEXT NOT NULL,
    source_path TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    track_count INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlist_items (
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    raw_entry TEXT NOT NULL,
    resolved_track_source_id TEXT REFERENCES track_sources(id) ON DELETE SET NULL,
    PRIMARY KEY (playlist_id, position)
);

-- Additive columns on track_sources for canonical track grouping, move/rename fingerprinting, and soft-missing state
ALTER TABLE track_sources ADD COLUMN canonical_track_id TEXT REFERENCES canonical_tracks(id) ON DELETE SET NULL;
ALTER TABLE track_sources ADD COLUMN content_fingerprint TEXT;
ALTER TABLE track_sources ADD COLUMN audio_byte_len INTEGER;
ALTER TABLE track_sources ADD COLUMN file_status TEXT NOT NULL DEFAULT 'present';
ALTER TABLE track_sources ADD COLUMN missing_since TEXT;

-- Additive columns on album_versions for multi-disc counts and TOC signatures
ALTER TABLE album_versions ADD COLUMN toc_signature TEXT;
ALTER TABLE album_versions ADD COLUMN disc_count INTEGER NOT NULL DEFAULT 1;
ALTER TABLE album_versions ADD COLUMN track_count INTEGER;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_track_sources_fingerprint
    ON track_sources(provider_id, content_fingerprint, audio_byte_len);
CREATE INDEX IF NOT EXISTS idx_track_sources_canonical_track
    ON track_sources(canonical_track_id);
CREATE INDEX IF NOT EXISTS idx_album_versions_toc
    ON album_versions(toc_signature);
CREATE INDEX IF NOT EXISTS idx_skipped_files_provider_dismissed
    ON skipped_files(provider_id, dismissed);
CREATE INDEX IF NOT EXISTS idx_metadata_overrides_entity
    ON metadata_overrides(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_canonical_tracks_album
    ON canonical_tracks(canonical_album_id);
CREATE INDEX IF NOT EXISTS idx_canonical_tracks_isrc
    ON canonical_tracks(isrc);
