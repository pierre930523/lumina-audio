"""
SQLite database fixture helper for Lumina Audio.
Executes and validates crates/core-db/migrations/0001_init.sql.
Provides in-memory testing, FTS5 full-text search indexing, query sanitization,
repository CRUD helpers, bulk track ingestion, and album version sorting/scoring.
"""
import hashlib
import os
import re
import sqlite3
import uuid
from typing import Dict, Any, List, Optional, Tuple


def get_migration_0001_path() -> str:
    """Resolves absolute path to crates/core-db/migrations/0001_init.sql."""
    current_dir = os.path.dirname(os.path.abspath(__file__))
    workspace_root = os.path.abspath(os.path.join(current_dir, "..", "..", ".."))
    migration_path = os.path.join(workspace_root, "crates", "core-db", "migrations", "0001_init.sql")
    if not os.path.isfile(migration_path):
        raise FileNotFoundError(f"Migration file not found at {migration_path}")
    return migration_path


def run_migration_0001(conn: sqlite3.Connection) -> None:
    """Executes the DDL statements from 0001_init.sql on the given SQLite connection."""
    sql_path = get_migration_0001_path()
    with open(sql_path, "r", encoding="utf-8") as f:
        ddl = f.read()
    conn.executescript(ddl)
    conn.commit()


def init_in_memory_db() -> sqlite3.Connection:
    """Creates an in-memory SQLite database and applies 0001_init.sql with foreign keys enabled."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    run_migration_0001(conn)
    return conn


def verify_schema_tables(conn: sqlite3.Connection) -> List[str]:
    """Returns list of all created tables in the database schema."""
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type in ('table', 'view') AND name NOT LIKE 'sqlite_%';")
    tables = [row[0] for row in cursor.fetchall()]
    return tables


def sanitize_fts5_query(query: str) -> str:
    """
    Sanitizes raw user input string for safe SQLite FTS5 query matching.
    Escapes quotes, removes control characters, cleans syntax operators,
    and formats tokens for safe prefix search.
    """
    if not query or not query.strip():
        return ""
    cleaned = re.sub(r'[\"\*\(\)\:\^\+\-\~]', " ", query)
    reserved = {"AND", "OR", "NOT", "NEAR"}
    tokens = [t.strip() for t in cleaned.split() if t.strip() and t.upper() not in reserved]
    if not tokens:
        return ""
    sanitized_parts = [f'"{token}"*' for token in tokens]
    return " ".join(sanitized_parts)


def execute_fts5_search(conn: sqlite3.Connection, query: str) -> List[Dict[str, Any]]:
    """Performs full-text search against search_fts with input sanitization."""
    sanitized = sanitize_fts5_query(query)
    if not sanitized:
        return []
    cursor = conn.cursor()
    cursor.execute(
        "SELECT entity_type, entity_id, title, subtitle, rank FROM search_fts WHERE search_fts MATCH ? ORDER BY rank",
        (sanitized,)
    )
    results = []
    for row in cursor.fetchall():
        results.append({
            "entity_type": row[0],
            "entity_id": row[1],
            "title": row[2],
            "subtitle": row[3],
            "rank": row[4],
        })
    return results


def make_sort_title(title: str) -> str:
    """Generates standardized sort title by stripping leading English articles ('The ', 'A ', 'An ')."""
    for prefix in ("The ", "A ", "An "):
        if title.startswith(prefix):
            return f"{title[len(prefix):]}, {prefix.strip()}"
    return title


def generate_sort_title(title: str) -> str:
    """Alias for make_sort_title."""
    return make_sort_title(title)


def quality_score(v: Dict[str, Any]) -> int:
    """Calculates fidelity ranking score (DSD prioritized, followed by sample_rate * bit_depth)."""
    if v.get("is_dsd"):
        return 10000000 + int(v.get("sample_rate_hz", 0))
    return int(v.get("sample_rate_hz", 0)) * int(v.get("bit_depth", 0))


def calculate_version_quality_score(v: Dict[str, Any]) -> int:
    """Alias for quality_score."""
    return quality_score(v)


def compute_version_score(ver: Dict[str, Any]) -> int:
    """Calculates audiophile version score: DSD + rate/1000*10 + bit_depth*50 + provider priority."""
    score = 0
    if ver.get("is_dsd"):
        score += 10000
    score += ver.get("sample_rate_hz", 0) // 1000 * 10
    score += ver.get("bit_depth", 16) * 50
    p = ver.get("provider", "")
    if p == "local":
        score += 100
    elif p == "qobuz":
        score += 50
    elif p == "tidal":
        score += 20
    return score


def compute_album_version_score(ver: Dict[str, Any]) -> int:
    """Alias for compute_version_score."""
    return compute_version_score(ver)


def select_best_album_version(versions: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Selects the highest fidelity album version from a list of versions."""
    if not versions:
        raise ValueError("Cannot select from empty versions list")
    return max(versions, key=quality_score)


def validate_album(title: str, artist: str) -> None:
    """Validates that album title and artist are non-empty and non-blank."""
    if not title or not title.strip():
        raise ValueError("Album title cannot be blank")
    if not artist or not artist.strip():
        raise ValueError("Album artist cannot be blank")


def validate_year(year: Optional[int]) -> Optional[int]:
    """Validates release year within historical recorded music sanity range (1860-2100)."""
    if year is None:
        return None
    if year < 1860 or year > 2100:
        raise ValueError(f"Release year outside historical sanity range: {year}")
    return year


def merge_versions(existing_ids: List[str], new_id: str) -> List[str]:
    """Appends new_id to existing_ids, rejecting duplicates."""
    if new_id in existing_ids:
        raise ValueError(f"Duplicate AlbumVersion ID: {new_id}")
    return existing_ids + [new_id]


def validate_mbid(mbid: str) -> bool:
    """Validates RFC 4122 UUID format for MusicBrainz IDs."""
    uuid_regex = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
    return bool(uuid_regex.match(mbid.strip()))


def validate_musicbrainz_uuid(mbid: str) -> bool:
    """Alias for validate_mbid."""
    return validate_mbid(mbid)


def validate_duration(ms: int) -> None:
    """Validates track duration in milliseconds (1 <= ms <= 86,400,000)."""
    if not isinstance(ms, int) or ms <= 0:
        raise ValueError("Track duration must be greater than 0 ms")
    if ms > 86400000:
        raise ValueError("Track duration exceeds 24 hours")


def validate_track_numbers(disc: int, trk: int) -> None:
    """Validates disc number >= 1 and track number >= 1."""
    if disc < 1:
        raise ValueError("Disc number must be >= 1")
    if trk < 1:
        raise ValueError("Track number must be >= 1")


def check_track_version_compatibility(track_rate: int, version_rate: int) -> None:
    """Verifies track sample rate matches parent version sample rate."""
    if track_rate != version_rate:
        raise ValueError(f"Track sample rate ({track_rate}) does not match Version ({version_rate})")


def insert_artist(conn: sqlite3.Connection, artist_id: str, name: str, sort_name: Optional[str] = None) -> str:
    """Inserts artist record into artists table."""
    sort = sort_name if sort_name is not None else make_sort_title(name)
    conn.execute(
        "INSERT OR IGNORE INTO artists (id, name, sort_name) VALUES (?, ?, ?)",
        (artist_id, name, sort)
    )
    conn.commit()
    return artist_id


def upsert_canonical_album(
    conn: sqlite3.Connection,
    album_id: str,
    title: str,
    artist_id: Optional[str] = None,
    release_year: Optional[int] = None,
    cover_url: Optional[str] = None,
) -> str:
    """Inserts or ignores canonical album record into canonical_albums table."""
    sort_title = make_sort_title(title)
    conn.execute(
        "INSERT OR IGNORE INTO canonical_albums (id, title, sort_title, primary_artist_id, release_year, merged_cover_path, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (album_id, title, sort_title, artist_id, release_year, cover_url, "2026-11-16T00:00:00Z")
    )
    conn.commit()
    return album_id


def insert_album_version(
    conn: sqlite3.Connection,
    version_id: str,
    album_id: str,
    provider_id: str,
    external_id: str,
    codec: str,
    sample_rate_hz: int,
    bit_depth: int,
) -> str:
    """Inserts album version record into album_versions table."""
    conn.execute(
        "INSERT OR IGNORE INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (version_id, album_id, provider_id, external_id, codec, sample_rate_hz, bit_depth)
    )
    conn.commit()
    return version_id


def insert_track_source(
    conn: sqlite3.Connection,
    track_id: str,
    version_id: str,
    provider_id: str,
    external_id: str,
    title: str,
    track_no: int,
    duration_ms: int,
    sample_rate_hz: int,
    bit_depth: int,
    codec: str,
) -> str:
    """Inserts track source record into track_sources table."""
    conn.execute(
        "INSERT OR IGNORE INTO track_sources (id, version_id, provider_id, external_track_id, title, track_number, duration_ms, sample_rate_hz, bit_depth, codec) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (track_id, version_id, provider_id, external_id, title, track_no, duration_ms, sample_rate_hz, bit_depth, codec)
    )
    conn.commit()
    return track_id


def register_paired_client(
    conn: sqlite3.Connection,
    client_id: str,
    device_name: str,
    platform: str,
    token_hash: str,
) -> None:
    """Registers a paired remote client in paired_clients table."""
    conn.execute(
        "INSERT OR REPLACE INTO paired_clients (id, device_name, platform, token_hash, created_at, last_seen_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (client_id, device_name, platform, token_hash, "2026-11-16T00:00:00Z", "2026-11-16T00:00:00Z")
    )
    conn.commit()


def bulk_ingest_scanned_tracks(
    conn: sqlite3.Connection,
    scanned_files: List[Dict[str, Any]],
) -> Dict[str, int]:
    """
    Atomically ingests scanned files, upserting artists, canonical albums, versions, tracks,
    and synchronizing search_fts index entries.
    """
    cur = conn.cursor()
    artist_cache: Dict[str, str] = {}
    album_cache: Dict[Tuple[str, str], Tuple[str, str]] = {}
    track_count = 0

    for item in scanned_files:
        artist_name = item.get("artist", "Unknown Artist")
        if artist_name not in artist_cache:
            art_id = f"art-{hashlib.md5(artist_name.encode('utf-8')).hexdigest()[:8]}"
            cur.execute(
                "INSERT OR IGNORE INTO artists (id, name, sort_name) VALUES (?, ?, ?)",
                (art_id, artist_name, make_sort_title(artist_name))
            )
            artist_cache[artist_name] = art_id

        album_title = item.get("album", "Unknown Album")
        album_key = (artist_name, album_title)
        if album_key not in album_cache:
            alb_hash = hashlib.md5((artist_name + ":" + album_title).encode("utf-8")).hexdigest()[:8]
            alb_id = f"alb-{alb_hash}"
            cur.execute(
                "INSERT OR IGNORE INTO canonical_albums (id, title, sort_title, primary_artist_id, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (alb_id, album_title, make_sort_title(album_title), artist_cache[artist_name], "2026-11-16T00:00:00Z")
            )
            ver_id = f"ver-{alb_id}-local"
            cur.execute(
                "INSERT OR IGNORE INTO album_versions (id, canonical_album_id, provider_id, external_album_id, codec, sample_rate_hz, bit_depth) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (ver_id, alb_id, "local", f"ext-{alb_id}", item.get("codec", "flac"), item.get("sample_rate_hz", 44100), item.get("bit_depth", 16))
            )
            album_cache[album_key] = (alb_id, ver_id)
            cur.execute(
                "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('album', ?, ?, ?)",
                (alb_id, album_title, artist_name)
            )

        alb_id, ver_id = album_cache[album_key]
        file_path = item.get("file_path", item.get("title", f"track-{track_count}"))
        trk_id = f"trk-{hashlib.md5(file_path.encode('utf-8')).hexdigest()[:8]}"
        title = item.get("title", "Unknown Title")
        track_no = item.get("track_no", 1)
        duration_ms = item.get("duration_ms", 180000)
        sample_rate_hz = item.get("sample_rate_hz", 44100)
        bit_depth = item.get("bit_depth", 16)
        codec = item.get("codec", "flac")
        cur.execute(
            "INSERT OR IGNORE INTO track_sources (id, version_id, provider_id, external_track_id, title, track_number, duration_ms, sample_rate_hz, bit_depth, codec) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (trk_id, ver_id, "local", trk_id, title, track_no, duration_ms, sample_rate_hz, bit_depth, codec)
        )
        cur.execute(
            "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
            (trk_id, title, f"{artist_name} - {album_title}")
        )
        track_count += 1

    conn.commit()
    return {
        "artists": len(artist_cache),
        "albums": len(album_cache),
        "tracks": track_count,
    }


def update_track_metadata(conn: sqlite3.Connection, track_id: str, new_title: str, artist_name: str) -> None:
    """Updates track title in track_sources and live synchronizes search_fts index."""
    cur = conn.cursor()
    cur.execute("UPDATE track_sources SET title = ? WHERE id = ?", (new_title, track_id))
    cur.execute("DELETE FROM search_fts WHERE entity_id = ?", (track_id,))
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
        (track_id, new_title, artist_name)
    )
    conn.commit()


def seed_mock_library(conn: sqlite3.Connection) -> Dict[str, Any]:
    """
    Seeds canonical mock music library into SQLite database matching core-db schema.
    Returns dictionary with generated IDs for verification.
    """
    cur = conn.cursor()
    profile_id = "prof-001"
    cur.execute(
        "INSERT INTO profiles (id, name, avatar_color, is_default, created_at) VALUES (?, ?, ?, ?, ?)",
        (profile_id, "Default Profile", "#007AFF", 1, "2026-11-16T00:00:00Z")
    )

    art_miles = "art-miles-001"
    art_pink = "art-pink-001"
    art_daft = "art-daft-001"
    insert_artist(conn, art_miles, "Miles Davis", "Davis, Miles")
    insert_artist(conn, art_pink, "Pink Floyd", "Pink Floyd, The")
    insert_artist(conn, art_daft, "Daft Punk", "Daft Punk")

    alb_kob = "alb-kob-001"
    alb_dsotm = "alb-dsotm-001"
    upsert_canonical_album(conn, alb_kob, "Kind of Blue", art_miles, 1959)
    upsert_canonical_album(conn, alb_dsotm, "The Dark Side of the Moon", art_pink, 1973)

    ver_kob_flac = "ver-kob-001-local-flac"
    ver_dsotm_flac = "ver-dsotm-001-local-flac"
    ver_dsotm_qobuz = "ver-dsotm-002-qobuz-hires"
    ver_dsotm_dsd = "ver-dsotm-003-local-dsd"

    insert_album_version(conn, ver_kob_flac, alb_kob, "local", "path/to/kob", "flac", 96000, 24)
    insert_album_version(conn, ver_dsotm_flac, alb_dsotm, "local", "path/to/dsotm", "flac", 44100, 16)
    insert_album_version(conn, ver_dsotm_qobuz, alb_dsotm, "qobuz", "qobuz-album-19482", "flac", 192000, 24)
    insert_album_version(conn, ver_dsotm_dsd, alb_dsotm, "local", "path/to/dsotm_dsd", "dsf", 2822400, 1)

    trk_kob_01 = "trk-kob-001"
    trk_dsotm_01 = "trk-dsotm-001"
    trk_dsotm_02 = "trk-dsotm-002"
    insert_track_source(conn, trk_kob_01, ver_kob_flac, "local", "path/to/so_what.flac", "So What", 1, 562000, 96000, 24, "flac")
    insert_track_source(conn, trk_dsotm_01, ver_dsotm_flac, "local", "path/to/speak_to_me.flac", "Speak to Me", 1, 67000, 44100, 16, "flac")
    insert_track_source(conn, trk_dsotm_02, ver_dsotm_flac, "local", "path/to/breathe.flac", "Breathe", 2, 163000, 44100, 16, "flac")

    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('artist', ?, ?, ?)",
        (art_pink, "Pink Floyd", "Rock Band")
    )
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('artist', ?, ?, ?)",
        (art_daft, "Daft Punk", "Electronic Duo")
    )
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('album', ?, ?, ?)",
        (alb_kob, "Kind of Blue", "Miles Davis")
    )
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('album', ?, ?, ?)",
        (alb_dsotm, "The Dark Side of the Moon", "Pink Floyd")
    )
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
        (trk_kob_01, "So What", "Miles Davis - Kind of Blue")
    )
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
        (trk_dsotm_01, "Speak to Me", "Pink Floyd - The Dark Side of the Moon")
    )
    cur.execute(
        "INSERT INTO search_fts (entity_type, entity_id, title, subtitle) VALUES ('track', ?, ?, ?)",
        (trk_dsotm_02, "Breathe", "Pink Floyd - The Dark Side of the Moon")
    )

    conn.commit()

    return {
        "profile_id": profile_id,
        "artist_miles_id": art_miles,
        "artist_pink_id": art_pink,
        "album_kob_id": alb_kob,
        "album_dsotm_id": alb_dsotm,
        "ver_kob_flac_id": ver_kob_flac,
        "ver_dsotm_flac_id": ver_dsotm_flac,
        "ver_dsotm_qobuz_id": ver_dsotm_qobuz,
        "ver_dsotm_dsd_id": ver_dsotm_dsd,
        "version_ids": [ver_kob_flac, ver_dsotm_flac, ver_dsotm_qobuz, ver_dsotm_dsd],
        "trk_kob_01_id": trk_kob_01,
        "trk_dsotm_01_id": trk_dsotm_01,
    }
