-- Migration 0013: Per-track visibility (is_hidden), track-level release_year & bitrate_kbps,
-- lyrics layer backfill, and offline corruption / loudness / waveform analysis columns.

ALTER TABLE track_sources ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0
    CHECK(is_hidden IN (0, 1));
ALTER TABLE track_sources ADD COLUMN release_year INTEGER;
ALTER TABLE track_sources ADD COLUMN bitrate_kbps INTEGER;
ALTER TABLE track_sources ADD COLUMN corruption_status TEXT NOT NULL DEFAULT 'unchecked'
    CHECK(corruption_status IN ('unchecked', 'ok', 'corrupt', 'unreadable'));
ALTER TABLE track_sources ADD COLUMN analysis_error TEXT;
ALTER TABLE track_sources ADD COLUMN integrated_lufs REAL;
ALTER TABLE track_sources ADD COLUMN true_peak_db REAL;
ALTER TABLE track_sources ADD COLUMN waveform_peaks_json TEXT;
ALTER TABLE track_sources ADD COLUMN analyzed_at TEXT;

CREATE INDEX IF NOT EXISTS idx_track_sources_is_hidden
    ON track_sources(is_hidden);

-- Backfill non-empty embedded_lyrics into existing track_sources.file_meta_json so
-- reverting user edits or toggling metadata policy restores the original embedded lyrics.
UPDATE track_sources
SET file_meta_json = json_set(file_meta_json, '$.lyrics', embedded_lyrics)
WHERE file_meta_json IS NOT NULL
  AND json_valid(file_meta_json)
  AND json_extract(file_meta_json, '$.lyrics') IS NULL
  AND embedded_lyrics IS NOT NULL
  AND TRIM(embedded_lyrics, char(9, 10, 13, 32)) != '';
