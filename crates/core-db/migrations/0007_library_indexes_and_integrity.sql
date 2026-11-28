-- Migration 0007: Library Integrity, Present-Track Query & Orphan Cleanup Indexes
-- Additive only (migrations 0001..0006 remain immutable).

CREATE INDEX IF NOT EXISTS idx_track_sources_version_status
    ON track_sources(version_id, file_status);

CREATE INDEX IF NOT EXISTS idx_track_sources_provider_status
    ON track_sources(provider_id, file_status);

CREATE INDEX IF NOT EXISTS idx_canonical_albums_primary_artist
    ON canonical_albums(primary_artist_id);

CREATE INDEX IF NOT EXISTS idx_track_artists_artist_id
    ON track_artists(artist_id);

CREATE INDEX IF NOT EXISTS idx_play_history_track_source
    ON play_history(track_source_id);

CREATE INDEX IF NOT EXISTS idx_play_history_profile_played
    ON play_history(profile_id, played_at DESC);

CREATE INDEX IF NOT EXISTS idx_playlist_items_resolved_track
    ON playlist_items(resolved_track_source_id);
