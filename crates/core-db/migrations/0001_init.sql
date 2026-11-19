-- Lumina Audio Initial Schema (SQLite WAL + FTS5)
-- Note: Sensitive streaming secrets (Qobuz tokens, Tidal OAuth, Deezer ARL, SMB passwords)
-- are stored in the OS Keyring, NOT in SQLite.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    avatar_color TEXT NOT NULL DEFAULT '#007AFF',
    is_default INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS artists (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sort_name TEXT NOT NULL,
    musicbrainz_id TEXT UNIQUE,
    biography TEXT,
    image_path TEXT
);

CREATE TABLE IF NOT EXISTS canonical_albums (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    sort_title TEXT NOT NULL,
    primary_artist_id TEXT REFERENCES artists(id) ON DELETE SET NULL,
    release_year INTEGER,
    upc TEXT,
    musicbrainz_release_group_id TEXT UNIQUE,
    editorial_bio TEXT,
    cover_url TEXT,
    merged_cover_path TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS album_versions (
    id TEXT PRIMARY KEY,
    canonical_album_id TEXT NOT NULL REFERENCES canonical_albums(id) ON DELETE CASCADE,
    provider_id TEXT NOT NULL,
    external_album_id TEXT NOT NULL,
    codec TEXT NOT NULL,
    sample_rate_hz INTEGER NOT NULL,
    bit_depth INTEGER NOT NULL,
    channels INTEGER NOT NULL DEFAULT 2,
    is_dsd INTEGER NOT NULL DEFAULT 0,
    edition_label TEXT,
    UNIQUE(provider_id, external_album_id)
);

CREATE TABLE IF NOT EXISTS track_sources (
    id TEXT PRIMARY KEY,
    version_id TEXT NOT NULL REFERENCES album_versions(id) ON DELETE CASCADE,
    provider_id TEXT NOT NULL,
    external_track_id TEXT NOT NULL,
    title TEXT NOT NULL,
    disc_number INTEGER NOT NULL DEFAULT 1,
    track_number INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    sample_rate_hz INTEGER NOT NULL,
    bit_depth INTEGER NOT NULL,
    codec TEXT NOT NULL,
    isrc TEXT,
    UNIQUE(provider_id, external_track_id)
);

CREATE TABLE IF NOT EXISTS album_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    canonical_album_id TEXT NOT NULL REFERENCES canonical_albums(id) ON DELETE CASCADE,
    artist_id TEXT NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
    role TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS profile_favorites (
    profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    item_type TEXT NOT NULL,
    item_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (profile_id, item_type, item_id)
);

CREATE TABLE IF NOT EXISTS play_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    track_source_id TEXT NOT NULL REFERENCES track_sources(id) ON DELETE CASCADE,
    played_at TEXT NOT NULL,
    duration_listened_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS paired_clients (
    id TEXT PRIMARY KEY,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
    entity_type,
    entity_id UNINDEXED,
    title,
    subtitle,
    tokenize = 'unicode61'
);
