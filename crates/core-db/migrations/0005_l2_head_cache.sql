-- Migration 0005: Multi-platform L2 head chunk persistent cache metadata.

CREATE TABLE IF NOT EXISTS l2_head_chunks (
    provider_id TEXT NOT NULL,
    track_id TEXT NOT NULL,
    quality_key TEXT NOT NULL,
    cache_kind TEXT NOT NULL,
    file_rel_path TEXT NOT NULL,
    cached_bytes INTEGER NOT NULL,
    total_content_length INTEGER,
    tail_fingerprint BLOB NOT NULL,
    pin_level INTEGER NOT NULL DEFAULT 0,
    last_accessed_at INTEGER NOT NULL,
    access_count INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (provider_id, track_id, quality_key)
);

CREATE INDEX IF NOT EXISTS idx_l2_head_chunks_eviction
    ON l2_head_chunks(pin_level ASC, last_accessed_at ASC);
