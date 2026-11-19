-- Migration 0002: ReplayGain metadata, canonical album dedup/enrichment indexes, zones & non-secret configs.
-- Note: Sensitive credentials remain strictly isolated in the OS Keyring.

ALTER TABLE track_sources ADD COLUMN replay_gain_track_db REAL;
ALTER TABLE track_sources ADD COLUMN replay_gain_album_db REAL;
ALTER TABLE track_sources ADD COLUMN replay_gain_track_peak REAL;
ALTER TABLE track_sources ADD COLUMN replay_gain_album_peak REAL;

ALTER TABLE canonical_albums ADD COLUMN normalized_title TEXT;
ALTER TABLE canonical_albums ADD COLUMN normalized_artist TEXT;
ALTER TABLE canonical_albums ADD COLUMN enriched_at TEXT;

ALTER TABLE artists ADD COLUMN enriched_at TEXT;

CREATE INDEX IF NOT EXISTS idx_canonical_albums_norm
    ON canonical_albums(normalized_title, normalized_artist);
CREATE INDEX IF NOT EXISTS idx_canonical_albums_upc
    ON canonical_albums(upc);
CREATE INDEX IF NOT EXISTS idx_canonical_albums_mb_rg
    ON canonical_albums(musicbrainz_release_group_id);
CREATE INDEX IF NOT EXISTS idx_track_sources_isrc
    ON track_sources(isrc);
CREATE INDEX IF NOT EXISTS idx_album_versions_canonical_id
    ON album_versions(canonical_album_id);
CREATE INDEX IF NOT EXISTS idx_track_sources_version_id
    ON track_sources(version_id);
CREATE INDEX IF NOT EXISTS idx_album_credits_album_id
    ON album_credits(canonical_album_id);
CREATE INDEX IF NOT EXISTS idx_album_credits_artist_id
    ON album_credits(artist_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_album_credits_unique
    ON album_credits(canonical_album_id, artist_id, role);
CREATE INDEX IF NOT EXISTS idx_artists_name_lower
    ON artists(LOWER(name));

CREATE TABLE IF NOT EXISTS zones (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    backend TEXT NOT NULL,
    device_id TEXT,
    exclusive_mode INTEGER NOT NULL DEFAULT 0,
    dsp_bypass INTEGER NOT NULL DEFAULT 1,
    dsp_config_json TEXT,
    group_id TEXT,
    volume REAL NOT NULL DEFAULT 1.0,
    is_active INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS provider_configs (
    provider_id TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL DEFAULT 0,
    display_name TEXT,
    endpoint_url TEXT,
    username TEXT,
    app_id TEXT,
    share_path TEXT,
    last_sync_at TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_preferences (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
