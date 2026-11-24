-- Migration 0004: Multi-platform L1 direct-URL / manifest stream cache.

CREATE TABLE IF NOT EXISTS l1_stream_urls (
    provider_id TEXT NOT NULL,
    track_id TEXT NOT NULL,
    quality_key TEXT NOT NULL,
    stream_type TEXT NOT NULL,
    url_or_manifest TEXT NOT NULL,
    headers_json TEXT NOT NULL DEFAULT '{}',
    mime_type TEXT,
    bitrate_bps INTEGER,
    content_length INTEGER,
    init_range_end INTEGER,
    index_range_start INTEGER,
    index_range_end INTEGER,
    expire_at INTEGER NOT NULL,
    network_epoch INTEGER NOT NULL DEFAULT 1,
    updated_at INTEGER NOT NULL,
    extra_json TEXT,
    PRIMARY KEY (provider_id, track_id, quality_key)
);

CREATE INDEX IF NOT EXISTS idx_l1_stream_urls_expire_at
    ON l1_stream_urls(expire_at);
