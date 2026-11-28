-- Migration 0008: Three-Layer Non-Destructive Metadata
-- Adds file_meta_json, cloud_meta_json, user_edits_json, and meta_policy to
-- canonical_albums and track_sources, seeds global default_metadata_policy = 'file',
-- backfills file_meta_json from existing columns, and folds legacy metadata_overrides.

ALTER TABLE canonical_albums ADD COLUMN file_meta_json TEXT;
ALTER TABLE canonical_albums ADD COLUMN cloud_meta_json TEXT;
ALTER TABLE canonical_albums ADD COLUMN user_edits_json TEXT;
ALTER TABLE canonical_albums ADD COLUMN meta_policy TEXT NOT NULL DEFAULT 'inherit'
    CHECK(meta_policy IN ('inherit', 'file', 'cloud'));

ALTER TABLE track_sources ADD COLUMN file_meta_json TEXT;
ALTER TABLE track_sources ADD COLUMN cloud_meta_json TEXT;
ALTER TABLE track_sources ADD COLUMN user_edits_json TEXT;
ALTER TABLE track_sources ADD COLUMN meta_policy TEXT NOT NULL DEFAULT 'inherit'
    CHECK(meta_policy IN ('inherit', 'file', 'cloud'));

CREATE INDEX IF NOT EXISTS idx_canonical_albums_meta_policy
    ON canonical_albums(meta_policy);
CREATE INDEX IF NOT EXISTS idx_track_sources_meta_policy
    ON track_sources(meta_policy);

INSERT OR IGNORE INTO app_preferences (key, value, updated_at)
VALUES ('default_metadata_policy', 'file', datetime('now'));

-- Backfill canonical_albums.file_meta_json from existing columns
UPDATE canonical_albums
SET file_meta_json = json_object(
    'title', title,
    'sort_title', sort_title,
    'album_artist', COALESCE(
        NULLIF(TRIM(album_artist), ''),
        (SELECT a.name FROM artists a WHERE a.id = canonical_albums.primary_artist_id)
    ),
    'release_year', release_year,
    'upc', upc,
    'musicbrainz_release_group_id', musicbrainz_release_group_id,
    'editorial_bio', editorial_bio,
    'cover_url', cover_url,
    'merged_cover_path', merged_cover_path
)
WHERE file_meta_json IS NULL;

-- Backfill track_sources.file_meta_json from existing columns
UPDATE track_sources
SET file_meta_json = json_object(
    'title', title,
    'artist_name', artist_name,
    'album_artist', album_artist,
    'album_title', (
        SELECT ca.title
        FROM album_versions av
        JOIN canonical_albums ca ON ca.id = av.canonical_album_id
        WHERE av.id = track_sources.version_id
    ),
    'disc_number', disc_number,
    'track_number', track_number,
    'genre', genre,
    'composer', composer,
    'isrc', isrc
)
WHERE file_meta_json IS NULL;

-- Fold legacy album metadata_overrides -> user_edits_json / cloud_meta_json / file_meta_json
UPDATE canonical_albums
SET user_edits_json = (
    SELECT json_group_object(
        CASE WHEN mo.field_name = 'artist_name' THEN 'album_artist' ELSE mo.field_name END,
        CASE WHEN json_valid(mo.value_json) THEN json(mo.value_json) ELSE mo.value_json END
    )
    FROM metadata_overrides mo
    WHERE mo.entity_type = 'album'
      AND mo.entity_id = canonical_albums.id
      AND mo.source_layer = 'user_edit'
      AND NOT (
          mo.field_name = 'artist_name'
          AND EXISTS (
              SELECT 1 FROM metadata_overrides mo2
              WHERE mo2.entity_type = 'album'
                AND mo2.entity_id = mo.entity_id
                AND mo2.source_layer = 'user_edit'
                AND mo2.field_name = 'album_artist'
          )
      )
)
WHERE EXISTS (
    SELECT 1 FROM metadata_overrides mo
    WHERE mo.entity_type = 'album'
      AND mo.entity_id = canonical_albums.id
      AND mo.source_layer = 'user_edit'
);

UPDATE canonical_albums
SET cloud_meta_json = (
    SELECT json_group_object(
        CASE WHEN mo.field_name = 'artist_name' THEN 'album_artist' ELSE mo.field_name END,
        CASE WHEN json_valid(mo.value_json) THEN json(mo.value_json) ELSE mo.value_json END
    )
    FROM metadata_overrides mo
    WHERE mo.entity_type = 'album'
      AND mo.entity_id = canonical_albums.id
      AND mo.source_layer = 'cloud_enrichment'
      AND NOT (
          mo.field_name = 'artist_name'
          AND EXISTS (
              SELECT 1 FROM metadata_overrides mo2
              WHERE mo2.entity_type = 'album'
                AND mo2.entity_id = mo.entity_id
                AND mo2.source_layer = 'cloud_enrichment'
                AND mo2.field_name = 'album_artist'
          )
      )
)
WHERE EXISTS (
    SELECT 1 FROM metadata_overrides mo
    WHERE mo.entity_type = 'album'
      AND mo.entity_id = canonical_albums.id
      AND mo.source_layer = 'cloud_enrichment'
);

UPDATE canonical_albums
SET file_meta_json = json_patch(
    COALESCE(file_meta_json, '{}'),
    (
        SELECT json_group_object(
            CASE WHEN mo.field_name = 'artist_name' THEN 'album_artist' ELSE mo.field_name END,
            CASE WHEN json_valid(mo.value_json) THEN json(mo.value_json) ELSE mo.value_json END
        )
        FROM metadata_overrides mo
        WHERE mo.entity_type = 'album'
          AND mo.entity_id = canonical_albums.id
          AND mo.source_layer = 'file_tag'
          AND NOT (
              mo.field_name = 'artist_name'
              AND EXISTS (
                  SELECT 1 FROM metadata_overrides mo2
                  WHERE mo2.entity_type = 'album'
                    AND mo2.entity_id = mo.entity_id
                    AND mo2.source_layer = 'file_tag'
                    AND mo2.field_name = 'album_artist'
              )
          )
    )
)
WHERE EXISTS (
    SELECT 1 FROM metadata_overrides mo
    WHERE mo.entity_type = 'album'
      AND mo.entity_id = canonical_albums.id
      AND mo.source_layer = 'file_tag'
);

-- Fold legacy track metadata_overrides -> user_edits_json / cloud_meta_json / file_meta_json
UPDATE track_sources
SET user_edits_json = (
    SELECT json_group_object(
        mo.field_name,
        CASE WHEN json_valid(mo.value_json) THEN json(mo.value_json) ELSE mo.value_json END
    )
    FROM metadata_overrides mo
    WHERE mo.entity_type = 'track'
      AND mo.entity_id = track_sources.id
      AND mo.source_layer = 'user_edit'
)
WHERE EXISTS (
    SELECT 1 FROM metadata_overrides mo
    WHERE mo.entity_type = 'track'
      AND mo.entity_id = track_sources.id
      AND mo.source_layer = 'user_edit'
);

UPDATE track_sources
SET cloud_meta_json = (
    SELECT json_group_object(
        mo.field_name,
        CASE WHEN json_valid(mo.value_json) THEN json(mo.value_json) ELSE mo.value_json END
    )
    FROM metadata_overrides mo
    WHERE mo.entity_type = 'track'
      AND mo.entity_id = track_sources.id
      AND mo.source_layer = 'cloud_enrichment'
)
WHERE EXISTS (
    SELECT 1 FROM metadata_overrides mo
    WHERE mo.entity_type = 'track'
      AND mo.entity_id = track_sources.id
      AND mo.source_layer = 'cloud_enrichment'
);

UPDATE track_sources
SET file_meta_json = json_patch(
    COALESCE(file_meta_json, '{}'),
    (
        SELECT json_group_object(
            mo.field_name,
            CASE WHEN json_valid(mo.value_json) THEN json(mo.value_json) ELSE mo.value_json END
        )
        FROM metadata_overrides mo
        WHERE mo.entity_type = 'track'
          AND mo.entity_id = track_sources.id
          AND mo.source_layer = 'file_tag'
    )
)
WHERE EXISTS (
    SELECT 1 FROM metadata_overrides mo
    WHERE mo.entity_type = 'track'
      AND mo.entity_id = track_sources.id
      AND mo.source_layer = 'file_tag'
);
