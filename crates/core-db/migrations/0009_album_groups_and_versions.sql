-- Migration 0009: Album Groups vs Album Versions, Primary Version Locking,
-- Hidden Versions, Manual Grouping/Splitting Locks, and Quality Scoring.
-- Additive only (migrations 0001..0008 remain immutable).

-- 1. Album Group (canonical_albums) primary version & lock columns
ALTER TABLE canonical_albums ADD COLUMN primary_version_id TEXT REFERENCES album_versions(id) ON DELETE SET NULL;
ALTER TABLE canonical_albums ADD COLUMN is_primary_locked INTEGER NOT NULL DEFAULT 0
    CHECK(is_primary_locked IN (0, 1));

-- 2. Album Version (album_versions) scoring, visibility & manual group lock columns
ALTER TABLE album_versions ADD COLUMN quality_score REAL NOT NULL DEFAULT 0.0;
ALTER TABLE album_versions ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0
    CHECK(is_hidden IN (0, 1));
ALTER TABLE album_versions ADD COLUMN manual_group_id TEXT REFERENCES canonical_albums(id) ON DELETE SET NULL;

-- 3. Track Source (track_sources) manual version & manual disc number locks
ALTER TABLE track_sources ADD COLUMN manual_version_id TEXT REFERENCES album_versions(id) ON DELETE SET NULL;
ALTER TABLE track_sources ADD COLUMN manual_disc_number INTEGER;

-- 4. Indexes
CREATE INDEX IF NOT EXISTS idx_canonical_albums_primary_version
    ON canonical_albums(primary_version_id);

CREATE INDEX IF NOT EXISTS idx_album_versions_group_hidden_score
    ON album_versions(canonical_album_id, is_hidden, quality_score DESC);

CREATE INDEX IF NOT EXISTS idx_album_versions_manual_group
    ON album_versions(manual_group_id)
    WHERE manual_group_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_track_sources_manual_version
    ON track_sources(manual_version_id)
    WHERE manual_version_id IS NOT NULL;

-- 5. Backfill track_count & disc_count from present tracks
UPDATE album_versions
SET track_count = (
        SELECT COUNT(*)
        FROM track_sources ts
        WHERE ts.version_id = album_versions.id
          AND ts.file_status = 'present'
    ),
    disc_count = MAX(
        1,
        COALESCE(
            (
                SELECT COUNT(DISTINCT COALESCE(ts.manual_disc_number, ts.disc_number))
                FROM track_sources ts
                WHERE ts.version_id = album_versions.id
                  AND ts.file_status = 'present'
            ),
            1
        )
    );

-- 6. Backfill album_versions.quality_score (0.0 if no present tracks)
UPDATE album_versions
SET quality_score = CASE
    WHEN COALESCE(track_count, 0) <= 0 THEN 0.0
    ELSE
        -- Completeness component
        (
            200.0 * MIN(
                1.0,
                CAST(track_count AS REAL) / MAX(
                    1.0,
                    CAST(
                        COALESCE(
                            (
                                SELECT MAX(COALESCE(av2.track_count, 0))
                                FROM album_versions av2
                                WHERE av2.canonical_album_id = album_versions.canonical_album_id
                            ),
                            track_count
                        ) AS REAL
                    )
                )
            )
            + MIN(60.0, CAST(track_count AS REAL) * 2.0)
        )
        -- Lossless / codec priority
        + CASE
            WHEN is_dsd = 1 OR LOWER(codec) IN ('flac', 'alac', 'wav', 'aiff', 'aif', 'ape', 'wv', 'wavpack', 'pcm', 'dsf', 'dsdiff', 'dsd') THEN 400.0
            WHEN LOWER(codec) IN ('opus', 'aac', 'm4a', 'ogg', 'vorbis') THEN 120.0
            ELSE 100.0
          END
        -- Resolution / DSD bonus
        + CASE
            WHEN is_dsd = 1 OR LOWER(codec) IN ('dsf', 'dsdiff', 'dsd') THEN
                CASE
                    WHEN sample_rate_hz >= 22579200 THEN 220.0
                    WHEN sample_rate_hz >= 11289600 THEN 205.0
                    WHEN sample_rate_hz >= 5644800 THEN 185.0
                    ELSE 160.0
                END
            WHEN LOWER(codec) IN ('flac', 'alac', 'wav', 'aiff', 'aif', 'ape', 'wv', 'wavpack', 'pcm') THEN
                (
                    CASE
                        WHEN bit_depth >= 32 THEN 60.0
                        WHEN bit_depth >= 24 THEN 50.0
                        WHEN bit_depth >= 16 THEN 20.0
                        ELSE 0.0
                    END
                ) + (
                    CASE
                        WHEN sample_rate_hz >= 352800 THEN 150.0
                        WHEN sample_rate_hz >= 176400 THEN 130.0
                        WHEN sample_rate_hz >= 88200 THEN 100.0
                        WHEN sample_rate_hz >= 44100 THEN 40.0
                        ELSE 0.0
                    END
                )
            ELSE 0.0
          END
        -- Provider preference
        + CASE
            WHEN LOWER(provider_id) = 'local' THEN 50.0
            WHEN LOWER(provider_id) IN ('smb', 'web_dav', 'webdav') THEN 40.0
            WHEN LOWER(provider_id) IN ('qobuz', 'tidal', 'deezer', 'apple_music', 'applemusic') THEN 20.0
            ELSE 0.0
          END
    END;

-- 7. Backfill canonical_albums.primary_version_id to highest-scoring present version per group
UPDATE canonical_albums
SET primary_version_id = (
    SELECT av.id
    FROM album_versions av
    WHERE av.canonical_album_id = canonical_albums.id
      AND EXISTS (
          SELECT 1
          FROM track_sources ts
          WHERE ts.version_id = av.id
            AND ts.file_status = 'present'
      )
    ORDER BY av.is_hidden ASC,
             av.quality_score DESC,
             COALESCE(av.track_count, 0) DESC,
             CASE WHEN LOWER(av.provider_id) = 'local' THEN 1 ELSE 0 END DESC,
             av.sample_rate_hz DESC,
             av.bit_depth DESC,
             av.id ASC
    LIMIT 1
)
WHERE primary_version_id IS NULL;
