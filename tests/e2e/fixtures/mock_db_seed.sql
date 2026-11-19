-- Lumina Audio Test Seed Data
INSERT OR IGNORE INTO profiles (id, name, avatar_color, is_default, created_at)
VALUES ('prof-default', 'Lumina Master', '#5856D6', 1, '2026-11-16T00:00:00Z');

INSERT OR IGNORE INTO artists (id, name, sort_name, musicbrainz_id, biography, image_path)
VALUES ('art-01', 'Miles Davis', 'Davis, Miles', '561d854a-6a28-4aa7-8c99-323e6ce46c2a', 'Iconic jazz trumpeter and bandleader', '/art/miles.jpg');

INSERT OR IGNORE INTO canonical_albums (id, title, sort_title, primary_artist_id, release_year, upc, musicbrainz_release_group_id, editorial_bio, merged_cover_path, created_at)
VALUES ('alb-01', 'Kind of Blue', 'Kind of Blue', 'art-01', 1959, '074646493526', 'c6799052-a5d6-3e05-9004-94646543b59a', 'Bestselling jazz record of all time', '/covers/kob.jpg', '2026-11-16T00:00:00Z');

INSERT OR IGNORE INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth, channels, is_dsd, edition_label)
VALUES ('ver-01', 'alb-01', 'local', 'local-kob-dsf', 'dsf', 2822400, 1, 2, 1, 'Mobile Fidelity SACD DSD64');

INSERT OR IGNORE INTO track_sources (id, version_id, provider_id, external_track_id, title, disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec, isrc)
VALUES ('trk-01', 'ver-01', 'local', 'local-kob-t01', 'So What', 1, 1, 562000, 2822400, 1, 'dsf', 'USSM15900010');

INSERT OR IGNORE INTO search_fts (entity_type, entity_id, title, subtitle)
VALUES ('album', 'alb-01', 'Kind of Blue', 'Miles Davis (1959)');
