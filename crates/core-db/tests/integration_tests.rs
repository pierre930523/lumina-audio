use core_db::credential::{CredentialStore, FallbackCredentialStore, MemoryCredentialStore};
use core_db::error::{DbError, ProfileError};
use core_db::repository::library::{
    deterministic_artist_id, normalize_match_key, Artist, ArtworkCacheEntry, LibraryRepository,
    PairedClient,
};
use core_db::repository::profile::ProfileRepository;
use core_db::search::{rebuild_search_index, search_library, sync_album_fts, sync_artist_fts};
use core_db::{open_database, open_test_database};
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, Profile, ProviderKind, TrackSource,
};
use std::collections::HashSet;
use std::sync::Arc;
use tempfile::tempdir;

#[tokio::test]
async fn test_wal_pool_and_migration_idempotency() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("wal_test.db");

    // 1. First open: runs migrations, sets WAL mode
    let pool = open_database(&db_path).await.unwrap();

    let journal_mode: (String,) = sqlx::query_as("PRAGMA journal_mode")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(journal_mode.0.to_lowercase(), "wal");

    let busy_timeout: (i64,) = sqlx::query_as("PRAGMA busy_timeout")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(busy_timeout.0, 5000);

    let foreign_keys: (i64,) = sqlx::query_as("PRAGMA foreign_keys")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(foreign_keys.0, 1);

    // 2. Migration idempotency: close and re-open on the same path
    drop(pool);
    let pool2 = open_database(&db_path).await.unwrap();

    let tables: Vec<(String,)> = sqlx::query_as(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    )
    .fetch_all(&pool2)
    .await
    .unwrap();

    let table_names: Vec<String> = tables.into_iter().map(|(t,)| t).collect();
    assert!(table_names.contains(&"profiles".to_string()));
    assert!(table_names.contains(&"artists".to_string()));
    assert!(table_names.contains(&"canonical_albums".to_string()));
    assert!(table_names.contains(&"album_versions".to_string()));
    assert!(table_names.contains(&"track_sources".to_string()));
    assert!(table_names.contains(&"album_credits".to_string()));
    assert!(table_names.contains(&"profile_favorites".to_string()));
    assert!(table_names.contains(&"play_history".to_string()));
    assert!(table_names.contains(&"paired_clients".to_string()));
    assert!(table_names.contains(&"search_fts".to_string()));
}

#[tokio::test]
async fn test_wal_concurrency_stress_16_tasks_8_conns() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("concurrency_stress.db");
    let pool = Arc::new(open_database(&db_path).await.unwrap());

    // Initialize one default profile
    ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "initial_profile".into(),
            name: "Initial".into(),
            avatar_color: "#007AFF".into(),
            is_default: true,
        },
    )
    .await
    .unwrap();

    let mut handles = Vec::new();

    // Spawn 16 concurrent tasks contending on the 8 pooled connections
    for i in 0..16 {
        let pool = Arc::clone(&pool);
        let handle = tokio::spawn(async move {
            let artist = Artist {
                id: format!("art-concurrent-{}", i),
                name: format!("Artist {}", i),
                sort_name: format!("Artist {}", i),
                musicbrainz_id: Some(format!("mb-id-{}", i)),
                biography: Some("Concurrent artist test bio".into()),
                image_path: None,
            };

            // Concurrent insert
            LibraryRepository::insert_artist(&pool, &artist)
                .await
                .unwrap();

            // Concurrent read
            let retrieved = LibraryRepository::find_artist_by_id(&pool, &artist.id)
                .await
                .unwrap()
                .expect("artist should be retrieved");
            assert_eq!(retrieved.name, artist.name);

            // Concurrent profile list
            let profiles = ProfileRepository::list_profiles(&pool).await.unwrap();
            assert!(!profiles.is_empty());
        });
        handles.push(handle);
    }

    for handle in handles {
        handle.await.expect("task should not panic or deadlock");
    }

    // Verify all 16 artists were persisted
    for i in 0..16 {
        let art_id = format!("art-concurrent-{}", i);
        let art = LibraryRepository::find_artist_by_id(&pool, &art_id)
            .await
            .unwrap();
        assert!(art.is_some());
    }
}

#[tokio::test]
async fn test_profile_protection_invariants() {
    let pool = open_test_database().await.unwrap();

    // 1. First profile created automatically becomes default even if passed is_default: false
    let p1 = ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "p1".into(),
            name: "Alice".into(),
            avatar_color: "#FF0000".into(),
            is_default: false,
        },
    )
    .await
    .unwrap();
    assert!(p1.is_default);

    // 2. Second profile created as non-default
    let p2 = ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "p2".into(),
            name: "Bob".into(),
            avatar_color: "#00FF00".into(),
            is_default: false,
        },
    )
    .await
    .unwrap();
    assert!(!p2.is_default);

    // 3. Attempting to unset is_default on p1 fails with CannotUnsetDefaultProfile
    let p1_unset = Profile {
        id: "p1".into(),
        name: "Alice Updated".into(),
        avatar_color: "#FF0000".into(),
        is_default: false,
    };
    match ProfileRepository::update_profile(&pool, &p1_unset).await {
        Err(DbError::Profile(ProfileError::CannotUnsetDefaultProfile)) => {}
        other => panic!("expected CannotUnsetDefaultProfile, got {:?}", other),
    }

    // 4. Attempting to delete default profile p1 fails
    match ProfileRepository::delete_profile(&pool, "p1").await {
        Err(DbError::Profile(ProfileError::CannotDeleteDefault(id))) => assert_eq!(id, "p1"),
        other => panic!("expected CannotDeleteDefault, got {:?}", other),
    }

    // 5. Switching default to p2 atomically unsets p1
    let p2_make_default = Profile {
        id: "p2".into(),
        name: "Bob Default".into(),
        avatar_color: "#00FF00".into(),
        is_default: true,
    };
    ProfileRepository::update_profile(&pool, &p2_make_default)
        .await
        .unwrap();

    let p1_refreshed = ProfileRepository::get_profile(&pool, "p1")
        .await
        .unwrap()
        .unwrap();
    assert!(!p1_refreshed.is_default);

    let p2_refreshed = ProfileRepository::get_profile(&pool, "p2")
        .await
        .unwrap()
        .unwrap();
    assert!(p2_refreshed.is_default);

    // 6. Now p1 is not default, deleting p1 succeeds
    ProfileRepository::delete_profile(&pool, "p1").await.unwrap();
    assert!(ProfileRepository::get_profile(&pool, "p1")
        .await
        .unwrap()
        .is_none());

    // 7. Deleting p2 (now the last remaining profile) fails with CannotDeleteLastProfile
    match ProfileRepository::delete_profile(&pool, "p2").await {
        Err(DbError::Profile(ProfileError::CannotDeleteLastProfile)) => {}
        other => panic!("expected CannotDeleteLastProfile, got {:?}", other),
    }
}

#[tokio::test]
async fn test_library_repository_crud_cascade_and_batch() {
    let pool = open_test_database().await.unwrap();

    // 1. Artist CRUD
    let artist = Artist {
        id: "art-miles".into(),
        name: "Miles Davis".into(),
        sort_name: "Davis, Miles".into(),
        musicbrainz_id: Some("mb-miles-123".into()),
        biography: Some("Jazz trumpeter and composer".into()),
        image_path: None,
    };
    LibraryRepository::insert_artist(&pool, &artist)
        .await
        .unwrap();

    let search_res = LibraryRepository::search_artists_by_name(&pool, "Miles")
        .await
        .unwrap();
    assert_eq!(search_res.len(), 1);
    assert_eq!(search_res[0].id, "art-miles");

    // 2. Canonical Album & Version
    let format = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let mut album = CanonicalAlbum::new("Kind of Blue", "Miles Davis")
        .unwrap()
        .with_release_year(1959)
        .unwrap();
    album.id = "alb-kob".into();

    let version = AlbumVersion::new(&album.id, ProviderKind::Qobuz, "qobuz-kob-hi-res", format.clone())
        .unwrap()
        .with_edition_label("Remastered 2013");
    album.add_version(version);

    LibraryRepository::insert_canonical_album(&pool, &album, Some("art-miles"))
        .await
        .unwrap();

    let fetched_album = LibraryRepository::find_canonical_album_by_id(&pool, "alb-kob")
        .await
        .unwrap()
        .expect("album should exist");
    assert_eq!(fetched_album.title, "Kind of Blue");
    assert_eq!(fetched_album.artist_name, "Miles Davis");
    assert_eq!(fetched_album.versions.len(), 1);
    assert_eq!(fetched_album.versions[0].edition_label.as_deref(), Some("Remastered 2013"));

    // 3. Batch insert 500 tracks into this version
    let version_id = &fetched_album.versions[0].id;
    let mut batch_tracks = Vec::with_capacity(500);
    for i in 1..=500 {
        batch_tracks.push(
            TrackSource::new(
                version_id,
                ProviderKind::Qobuz,
                format!("ext-track-{}", i),
                format!("Track Title {}", i),
                1,
                i,
                180_000,
                format.clone(),
            )
            .unwrap(),
        );
    }

    LibraryRepository::insert_track_sources_batch(&pool, &batch_tracks)
        .await
        .unwrap();

    let count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM track_sources WHERE version_id = ?")
        .bind(version_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count.0, 500);

    // 4. Album Credits
    LibraryRepository::insert_album_credit(&pool, "alb-kob", "art-miles", "Trumpet, Bandleader")
        .await
        .unwrap();
    let credits = LibraryRepository::list_credits_for_album(&pool, "alb-kob")
        .await
        .unwrap();
    assert_eq!(credits.len(), 1);
    assert_eq!(credits[0].role, "Trumpet, Bandleader");
    assert_eq!(credits[0].artist_name.as_deref(), Some("Miles Davis"));

    // 5. Foreign Key Cascade: Deleting canonical album deletes versions and tracks
    LibraryRepository::delete_canonical_album(&pool, "alb-kob")
        .await
        .unwrap();

    let v_count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM album_versions WHERE canonical_album_id = 'alb-kob'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(v_count.0, 0);

    let t_count: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM track_sources WHERE version_id = ?")
        .bind(version_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(t_count.0, 0);
}

#[tokio::test]
async fn test_profile_favorites_and_play_history() {
    let pool = open_test_database().await.unwrap();

    let p = ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "user_prof".into(),
            name: "Listener".into(),
            avatar_color: "#123456".into(),
            is_default: true,
        },
    )
    .await
    .unwrap();

    // Favorites
    assert!(!LibraryRepository::is_favorite(&pool, &p.id, "album", "alb-123").await.unwrap());
    LibraryRepository::add_favorite(&pool, &p.id, "album", "alb-123")
        .await
        .unwrap();
    assert!(LibraryRepository::is_favorite(&pool, &p.id, "album", "alb-123").await.unwrap());

    let favs = LibraryRepository::list_favorites_for_profile(&pool, &p.id, Some("album"))
        .await
        .unwrap();
    assert_eq!(favs.len(), 1);
    assert_eq!(favs[0].item_id, "alb-123");

    let removed = LibraryRepository::remove_favorite(&pool, &p.id, "album", "alb-123")
        .await
        .unwrap();
    assert!(removed);
    assert!(!LibraryRepository::is_favorite(&pool, &p.id, "album", "alb-123").await.unwrap());

    // Play History
    // First set up artist, album, version, track for relational foreign key
    let artist = Artist {
        id: "art-hist".into(),
        name: "Historical Artist".into(),
        sort_name: "Historical Artist".into(),
        musicbrainz_id: None,
        biography: None,
        image_path: None,
    };
    LibraryRepository::insert_artist(&pool, &artist).await.unwrap();

    let album = CanonicalAlbum::new("Historical Album", "Historical Artist").unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, Some("art-hist")).await.unwrap();

    let version = AlbumVersion::new(&album.id, ProviderKind::Local, "loc-v1", AudioFormat::cd_quality()).unwrap();
    LibraryRepository::insert_album_version(&pool, &version).await.unwrap();

    let track = TrackSource::new(&version.id, ProviderKind::Local, "loc-t1", "Track 1", 1, 1, 200_000, AudioFormat::cd_quality()).unwrap();
    LibraryRepository::insert_track_source(&pool, &track).await.unwrap();

    LibraryRepository::record_play(&pool, &p.id, &track.id, 180_000).await.unwrap();
    LibraryRepository::record_play(&pool, &p.id, &track.id, 200_000).await.unwrap();

    let history = LibraryRepository::get_recent_history(&pool, &p.id, 10).await.unwrap();
    assert_eq!(history.len(), 2);
    assert_eq!(history[0].track_source_id, track.id);
}

#[tokio::test]
async fn test_fts5_search_ranking_and_sanitization() {
    let pool = open_test_database().await.unwrap();

    // 1. Insert directly into search_fts using sync helpers
    let mut tx = pool.begin().await.unwrap();
    sync_artist_fts(&mut tx, "art-floyd", "Pink Floyd", Some("Progressive rock band")).await.unwrap();
    sync_artist_fts(&mut tx, "art-daft", "Daft Punk", Some("Electronic music duo")).await.unwrap();
    sync_artist_fts(&mut tx, "art-sakamoto", "坂本龍一", Some("Japanese composer")).await.unwrap();
    tx.commit().await.unwrap();

    // 2. Search exact and prefix
    let res1 = search_library(&pool, "Pink Floyd").await.unwrap();
    assert!(!res1.is_empty());
    assert_eq!(res1[0].entity_id, "art-floyd");

    let res2 = search_library(&pool, "Daft").await.unwrap();
    assert!(!res2.is_empty());
    assert_eq!(res2[0].entity_id, "art-daft");

    let res3 = search_library(&pool, "坂本").await.unwrap();
    assert!(!res3.is_empty());
    assert_eq!(res3[0].entity_id, "art-sakamoto");

    // 3. Toxic query sanitization resilience:
    // User query with punctuation and reserved keywords executes safely without SQL errors
    let toxic = "Pink (Floyd) \"Dark*Side: AND OR NOT ^test";
    let toxic_res = search_library(&pool, toxic).await.unwrap();
    // Query execution is valid and does not error
    let _ = toxic_res;

    // Toxic query matching Pink Floyd executes safely and matches
    let toxic_match = "Pink (Floyd)* AND OR NOT";
    let match_res = search_library(&pool, toxic_match).await.unwrap();
    assert!(!match_res.is_empty());
    assert_eq!(match_res[0].entity_id, "art-floyd");

    // 4. Empty and whitespace queries return empty Vec
    assert!(search_library(&pool, "").await.unwrap().is_empty());
    assert!(search_library(&pool, "   ").await.unwrap().is_empty());
    assert!(search_library(&pool, "::: +++ --- ***").await.unwrap().is_empty());

    // 5. Rebuild search index test
    let count = rebuild_search_index(&pool).await.unwrap();
    assert_eq!(count, 0); // No relational data inserted yet
}

#[tokio::test]
async fn test_credential_isolation_and_fallback() {
    let memory_store = MemoryCredentialStore::new();

    // Test URL-safe and high-entropy 256-bit binary tokens
    let high_entropy_secret = "4f8a9b2c1d3e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a";
    memory_store
        .set_secret("com.lumina.audio", "qobuz_auth_token", high_entropy_secret)
        .await
        .unwrap();

    let fetched = memory_store
        .get_secret("com.lumina.audio", "qobuz_auth_token")
        .await
        .unwrap();
    assert_eq!(fetched.as_deref(), Some(high_entropy_secret));

    // Fallback store test
    let fallback_store = FallbackCredentialStore::new(Arc::new(memory_store.clone()));
    let fallback_fetched = fallback_store
        .get_secret("com.lumina.audio", "qobuz_auth_token")
        .await
        .unwrap();
    assert_eq!(fallback_fetched.as_deref(), Some(high_entropy_secret));

    // Secret Isolation verification: ensure no sensitive keys exist in SQLite schema
    let pool = open_test_database().await.unwrap();
    let schemas: Vec<(String,)> = sqlx::query_as(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND sql IS NOT NULL",
    )
    .fetch_all(&pool)
    .await
    .unwrap();

    let forbidden_keys = [
        "user_auth_token",
        "oauth_access_token",
        "deezer_arl",
        "smb_password",
        "password_hash",
        "client_secret",
        "refresh_token",
    ];

    for (schema_sql,) in schemas {
        for forbidden in &forbidden_keys {
            assert!(
                !schema_sql.to_lowercase().contains(forbidden),
                "Secret isolation violated: found '{}' in schema:\n{}",
                forbidden,
                schema_sql
            );
        }
    }
}

#[cfg(feature = "os-keyring")]
#[tokio::test]
async fn test_keyring_store_direct_and_persistence() {
    use core_db::credential::{CredentialError, KeyringStore};

    let service = "com.lumina.audio.test";
    let key = format!("test_key_{}", uuid::Uuid::new_v4());
    let secret = "secret_auth_token_wal_verified_9999";

    let keyring = KeyringStore::new();

    // Verify set_secret and cross-thread persistence with spawn_blocking
    match keyring.set_secret(service, &key, secret).await {
        Ok(()) => {
            // Retrieve secret from another task / thread
            let get_handle = tokio::spawn({
                let keyring = keyring.clone();
                let key = key.clone();
                async move { keyring.get_secret(service, &key).await }
            });
            let retrieved = get_handle
                .await
                .unwrap()
                .expect("get_secret should succeed");
            assert_eq!(retrieved.as_deref(), Some(secret));

            // Test deletion
            keyring
                .delete_secret(service, &key)
                .await
                .expect("delete_secret should succeed");
            let after_delete = keyring
                .get_secret(service, &key)
                .await
                .expect("get_secret after delete should succeed");
            assert_eq!(after_delete, None);

            // Test FallbackCredentialStore wrapping functional KeyringStore
            let fallback = FallbackCredentialStore::new(Arc::new(keyring.clone()));
            let fb_key = format!("test_fb_key_{}", uuid::Uuid::new_v4());
            let fb_secret = "fallback_wrapped_secret_token";
            fallback
                .set_secret(service, &fb_key, fb_secret)
                .await
                .unwrap();
            let fb_fetched = fallback.get_secret(service, &fb_key).await.unwrap();
            assert_eq!(fb_fetched.as_deref(), Some(fb_secret));
            fallback.delete_secret(service, &fb_key).await.unwrap();
            assert_eq!(fallback.get_secret(service, &fb_key).await.unwrap(), None);
        }
        Err(CredentialError::System(err)) | Err(CredentialError::Unavailable(err)) => {
            // Graceful degradation when running in headless / container environments without an OS keyring daemon (e.g. headless Linux CI)
            eprintln!("Keyring daemon unavailable in this environment: {err}");
            let fallback_store = FallbackCredentialStore::new(Arc::new(keyring));
            fallback_store
                .set_secret(service, &key, secret)
                .await
                .unwrap();
            let retrieved = fallback_store.get_secret(service, &key).await.unwrap();
            assert_eq!(retrieved.as_deref(), Some(secret));
            fallback_store.delete_secret(service, &key).await.unwrap();
            let after_delete = fallback_store.get_secret(service, &key).await.unwrap();
            assert_eq!(after_delete, None);
        }
        Err(other) => panic!("Unexpected error from KeyringStore: {:?}", other),
    }
}

#[tokio::test]
async fn test_wal_concurrency_stress_64_tasks_8_conns() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("concurrency_stress_64.db");
    let pool = Arc::new(open_database(&db_path).await.unwrap());

    // Initialize two profiles
    ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "prof_stress_1".into(),
            name: "Initial Stress 1".into(),
            avatar_color: "#007AFF".into(),
            is_default: true,
        },
    )
    .await
    .unwrap();

    ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "prof_stress_2".into(),
            name: "Initial Stress 2".into(),
            avatar_color: "#34C759".into(),
            is_default: false,
        },
    )
    .await
    .unwrap();

    let mut handles = Vec::with_capacity(64);

    // Spawn 64 concurrent tasks executing update_profile and insert_artist
    // simultaneously across the 8 pooled connections.
    // Under BEGIN IMMEDIATE, all transactions acquire immediate writer locks,
    // guaranteeing ZERO SQLITE_BUSY_SNAPSHOT (code: 517) errors.
    for i in 0..64 {
        let pool = Arc::clone(&pool);
        let handle = tokio::spawn(async move {
            // Task executes insert_artist
            let artist = Artist {
                id: format!("art-concurrent-64-{}", i),
                name: format!("Artist 64-{}", i),
                sort_name: format!("Artist 64-{}", i),
                musicbrainz_id: Some(format!("mb-64-{}", i)),
                biography: Some("Concurrent 64-task WAL stress artist".into()),
                image_path: None,
            };
            LibraryRepository::insert_artist(&pool, &artist)
                .await
                .expect("insert_artist must succeed without SQLITE_BUSY_SNAPSHOT");

            // Task concurrently executes update_profile (multi-statement transaction)
            let target_id = if i % 2 == 0 {
                "prof_stress_1"
            } else {
                "prof_stress_2"
            };
            let update = Profile {
                id: target_id.to_string(),
                name: format!("Updated Profile Task {}", i),
                avatar_color: format!("#{:06X}", (i * 31337) % 0xFFFFFF),
                is_default: true,
            };

            ProfileRepository::update_profile(&pool, &update)
                .await
                .expect("update_profile must succeed without SQLITE_BUSY_SNAPSHOT");

            // Verify read consistency
            let fetched = LibraryRepository::find_artist_by_id(&pool, &artist.id)
                .await
                .expect("find_artist must succeed");
            assert!(fetched.is_some());
        });
        handles.push(handle);
    }

    // Await all 64 tasks; ensure 0 panics, 0 deadlocks, 0 SQLITE_BUSY_SNAPSHOT errors
    for handle in handles {
        handle.await.expect("task must not panic or abort");
    }

    // Verify all 64 artists exist in the database
    for i in 0..64 {
        let art_id = format!("art-concurrent-64-{}", i);
        let art = LibraryRepository::find_artist_by_id(&pool, &art_id)
            .await
            .unwrap();
        assert!(art.is_some(), "Artist {} must exist", art_id);
    }

    // Verify profiles table is consistent and has exactly one default profile
    let default_prof = ProfileRepository::get_default_profile(&pool)
        .await
        .expect("must have exactly one default profile");
    assert!(default_prof.is_default);
}

#[tokio::test]
async fn test_migration_0002_replaygain_and_preferences() {
    let pool = open_test_database().await.unwrap();

    // Verify migration 0002 tables exist
    let tables: Vec<(String,)> = sqlx::query_as(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let table_names: Vec<String> = tables.into_iter().map(|(t,)| t).collect();
    assert!(table_names.contains(&"zones".to_string()));
    assert!(table_names.contains(&"provider_configs".to_string()));
    assert!(table_names.contains(&"app_preferences".to_string()));

    // Setup album, version, track with ReplayGain tags
    let artist = Artist {
        id: "art-rg".into(),
        name: "Radiohead".into(),
        sort_name: "Radiohead".into(),
        musicbrainz_id: None,
        biography: None,
        image_path: None,
    };
    LibraryRepository::insert_artist(&pool, &artist).await.unwrap();

    let album = CanonicalAlbum::new("OK Computer", "Radiohead").unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, Some(&artist.id))
        .await
        .unwrap();

    let version = AlbumVersion::new(&album.id, ProviderKind::Local, "loc-okc", AudioFormat::cd_quality()).unwrap();
    LibraryRepository::insert_album_version(&pool, &version).await.unwrap();

    let track1 = TrackSource::new(
        &version.id,
        ProviderKind::Local,
        "loc-trk-1",
        "Airbag",
        1,
        1,
        284_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_replay_gain(Some(-7.2), Some(-8.1), Some(0.95), Some(0.99));

    let track2 = TrackSource::new(
        &version.id,
        ProviderKind::Local,
        "loc-trk-2",
        "Paranoid Android",
        1,
        2,
        383_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_replay_gain(Some(-6.5), Some(-8.1), Some(0.97), Some(0.99));

    LibraryRepository::insert_track_source(&pool, &track1).await.unwrap();
    LibraryRepository::insert_track_sources_batch(&pool, std::slice::from_ref(&track2))
        .await
        .unwrap();

    let fetched1 = LibraryRepository::find_track_source_by_id(&pool, &track1.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(fetched1.replay_gain_track_db, Some(-7.2));
    assert_eq!(fetched1.replay_gain_album_db, Some(-8.1));
    assert_eq!(fetched1.replay_gain_track_peak, Some(0.95));
    assert_eq!(fetched1.replay_gain_album_peak, Some(0.99));

    let updated = LibraryRepository::update_track_source_replay_gain(
        &pool,
        &track2.id,
        Some(-5.0),
        Some(-6.0),
        Some(0.88),
        Some(0.92),
    )
    .await
    .unwrap();
    assert!(updated);

    let fetched2 = LibraryRepository::find_track_source_by_id(&pool, &track2.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(fetched2.replay_gain_track_db, Some(-5.0));
    assert_eq!(fetched2.replay_gain_album_db, Some(-6.0));
    assert_eq!(fetched2.replay_gain_track_peak, Some(0.88));
    assert_eq!(fetched2.replay_gain_album_peak, Some(0.92));

    // App preferences roundtrip
    assert_eq!(LibraryRepository::get_preference(&pool, "active_zone").await.unwrap(), None);
    LibraryRepository::set_preference(&pool, "active_zone", "zone-main")
        .await
        .unwrap();
    assert_eq!(
        LibraryRepository::get_preference(&pool, "active_zone")
            .await
            .unwrap()
            .as_deref(),
        Some("zone-main")
    );
    LibraryRepository::set_preference(&pool, "active_zone", "zone-desk")
        .await
        .unwrap();
    assert_eq!(
        LibraryRepository::get_preference(&pool, "active_zone")
            .await
            .unwrap()
            .as_deref(),
        Some("zone-desk")
    );
}

#[tokio::test]
async fn test_canonical_album_cross_source_match_merge_dedup_and_details() {
    let pool = open_test_database().await.unwrap();

    assert_eq!(normalize_match_key("  The Dark Side of the Moon! "), "the dark side of the moon");

    let prof = ProfileRepository::create_profile(
        &pool,
        &Profile {
            id: "prof-dedup".into(),
            name: "Dedup User".into(),
            avatar_color: "#FF9500".into(),
            is_default: true,
        },
    )
    .await
    .unwrap();

    let primary_artist = LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "Pink Floyd",
        Some("mb-art-pf"),
        Some("British rock band"),
        None,
    )
    .await
    .unwrap();

    let producer = LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "Alan Parsons",
        None,
        None,
        None,
    )
    .await
    .unwrap();

    // Source 1: Local FLAC album
    let mut alb1 = CanonicalAlbum::new("Dark Side of the Moon", "Pink Floyd")
        .unwrap()
        .with_release_year(1973)
        .unwrap();
    alb1.id = "alb-local".into();
    let ver1 = AlbumVersion::new(
        &alb1.id,
        ProviderKind::Local,
        "loc-dsotm",
        AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap(),
    )
    .unwrap()
    .with_edition_label("2011 Remaster");
    alb1.add_version(ver1.clone());
    LibraryRepository::insert_canonical_album(&pool, &alb1, Some(&primary_artist.id))
        .await
        .unwrap();

    let trk1 = TrackSource::new(
        &ver1.id,
        ProviderKind::Local,
        "loc-time",
        "Time",
        1,
        4,
        413_000,
        AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap(),
    )
    .unwrap()
    .with_isrc("GBAYE7300004")
    .unwrap();
    LibraryRepository::insert_track_source(&pool, &trk1).await.unwrap();

    // Source 2: Qobuz album with punctuation difference, UPC + MBID
    let mut alb2 = CanonicalAlbum::new("Dark Side of the Moon!", "Pink Floyd")
        .unwrap()
        .with_musicbrainz_id("mb-rg-dsotm");
    alb2.id = "alb-qobuz".into();
    let ver2 = AlbumVersion::new(
        &alb2.id,
        ProviderKind::Qobuz,
        "qobuz-dsotm",
        AudioFormat::pcm(AudioCodec::Flac, 192000, 24, 2).unwrap(),
    )
    .unwrap()
    .with_edition_label("Hi-Res 24/192");
    alb2.add_version(ver2.clone());
    LibraryRepository::insert_canonical_album(&pool, &alb2, Some(&primary_artist.id))
        .await
        .unwrap();
    LibraryRepository::update_canonical_album_metadata(
        &pool,
        &alb2.id,
        Some("5099902987620"),
        None,
        Some("Iconic 1973 concept album"),
        Some("https://example.com/dsotm.jpg"),
    )
    .await
    .unwrap();

    let trk2 = TrackSource::new(
        &ver2.id,
        ProviderKind::Qobuz,
        "q-time",
        "Time",
        1,
        4,
        413_000,
        AudioFormat::pcm(AudioCodec::Flac, 192000, 24, 2).unwrap(),
    )
    .unwrap()
    .with_isrc("GBAYE7300004")
    .unwrap();
    LibraryRepository::insert_track_source(&pool, &trk2).await.unwrap();

    // Credits & favorites on both before merge (including overlapping credit & favorite)
    let c1 = LibraryRepository::upsert_album_credit(&pool, &alb1.id, &producer.id, "Engineer")
        .await
        .unwrap();
    let c1_dup = LibraryRepository::upsert_album_credit(&pool, &alb1.id, &producer.id, "Engineer")
        .await
        .unwrap();
    assert_eq!(c1, c1_dup);
    LibraryRepository::upsert_album_credit(&pool, &alb2.id, &producer.id, "Engineer")
        .await
        .unwrap();
    LibraryRepository::upsert_album_credit(&pool, &alb2.id, &producer.id, "Producer")
        .await
        .unwrap();

    LibraryRepository::add_favorite(&pool, &prof.id, "album", &alb1.id)
        .await
        .unwrap();
    LibraryRepository::add_favorite(&pool, &prof.id, "album", &alb2.id)
        .await
        .unwrap();

    let mut tx = pool.begin().await.unwrap();
    sync_album_fts(&mut tx, &alb2.id, &alb2.title, Some("Pink Floyd"), Some(1973))
        .await
        .unwrap();
    tx.commit().await.unwrap();

    // Cross-source match checks (MBID, UPC, ISRC, Normalized key)
    assert_eq!(
        LibraryRepository::find_canonical_album_match(
            &pool,
            "Unrelated",
            "Nobody",
            None,
            Some("mb-rg-dsotm"),
            &[]
        )
        .await
        .unwrap()
        .unwrap()
        .id,
        "alb-qobuz"
    );
    assert_eq!(
        LibraryRepository::find_canonical_album_match(
            &pool,
            "Unrelated",
            "Nobody",
            Some("5099902987620"),
            None,
            &[]
        )
        .await
        .unwrap()
        .unwrap()
        .id,
        "alb-qobuz"
    );
    assert!(!LibraryRepository::find_canonical_album_ids_by_isrcs(&pool, &["GB-AYE-73-00004".to_string()])
        .await
        .unwrap()
        .is_empty());

    // Deduplicate canonical albums -> merges alb-local into richer alb-qobuz
    let merged = LibraryRepository::deduplicate_canonical_albums(&pool)
        .await
        .unwrap();
    assert_eq!(merged, 1);

    // Confirm surviving album has both versions, both tracks, deduplicated credits, favorite, and cover/year backfill
    let listed = LibraryRepository::list_canonical_albums(&pool, 20, 0)
        .await
        .unwrap();
    assert_eq!(listed.len(), 1);
    let survivor_id = listed[0].id.clone();

    let detail = LibraryRepository::get_album_detail(&pool, &survivor_id)
        .await
        .unwrap()
        .expect("album detail should exist");
    assert_eq!(detail.album.release_year, Some(1973));
    assert_eq!(detail.album.musicbrainz_release_group_id.as_deref(), Some("mb-rg-dsotm"));
    assert_eq!(detail.album.cover_url.as_deref(), Some("https://example.com/dsotm.jpg"));
    assert_eq!(detail.versions.len(), 2);
    assert_eq!(detail.versions.iter().map(|v| v.tracks.len()).sum::<usize>(), 2);
    assert_eq!(detail.credits.len(), 2); // Engineer (deduped) + Producer

    assert!(LibraryRepository::is_favorite(&pool, &prof.id, "album", &survivor_id)
        .await
        .unwrap());

    // Artist detail includes credited album even when not primary_artist_id
    LibraryRepository::mark_album_enriched(&pool, &survivor_id)
        .await
        .unwrap();
    let producer_detail = LibraryRepository::get_artist_detail(&pool, &producer.id)
        .await
        .unwrap()
        .expect("producer detail should exist");
    assert_eq!(producer_detail.albums.len(), 1);
    assert_eq!(producer_detail.albums[0].id, survivor_id);
    assert_eq!(producer_detail.credits.len(), 2);
}

#[tokio::test]
async fn test_paired_clients_persistence_and_token_hashes() {
    let pool = open_test_database().await.unwrap();

    let c1 = PairedClient {
        id: "client-1".into(),
        device_name: "iPhone 16 Pro".into(),
        platform: "ios".into(),
        token_hash: "hash_alpha_111".into(),
        created_at: "2026-11-17T10:00:00Z".into(),
        last_seen_at: "2026-11-17T10:00:00Z".into(),
    };
    let c2 = PairedClient {
        id: "client-2".into(),
        device_name: "Pixel 9".into(),
        platform: "android".into(),
        token_hash: "hash_beta_222".into(),
        created_at: "2026-11-17T11:00:00Z".into(),
        last_seen_at: "2026-11-17T11:00:00Z".into(),
    };

    LibraryRepository::insert_paired_client(&pool, &c1).await.unwrap();
    LibraryRepository::insert_paired_client(&pool, &c2).await.unwrap();

    let hashes = LibraryRepository::list_paired_token_hashes(&pool).await.unwrap();
    assert_eq!(hashes.len(), 2);
    assert!(hashes.contains(&"hash_alpha_111".to_string()));
    assert!(hashes.contains(&"hash_beta_222".to_string()));

    LibraryRepository::touch_paired_client_by_hash(&pool, "hash_alpha_111")
        .await
        .unwrap();
    let clients = LibraryRepository::list_paired_clients(&pool).await.unwrap();
    assert_eq!(clients.len(), 2);

    assert!(LibraryRepository::delete_paired_client(&pool, "client-1").await.unwrap());
    assert!(!LibraryRepository::delete_paired_client(&pool, "client-1").await.unwrap());
    assert_eq!(LibraryRepository::list_paired_token_hashes(&pool).await.unwrap().len(), 1);
}

#[tokio::test]
async fn test_migration_0003_schema_and_pre0003_backfill() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("backfill_0003.db");

    // Simulate a pre-0003 database by running only migrations 0001 and 0002 first
    {
        let options = sqlx::sqlite::SqliteConnectOptions::new()
            .filename(&db_path)
            .create_if_missing(true)
            .foreign_keys(true);
        let pre_pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .unwrap();

        let m1 = include_str!("../migrations/0001_init.sql");
        let m2 = include_str!("../migrations/0002_replaygain_and_zones.sql");
        sqlx::raw_sql(m1).execute(&pre_pool).await.unwrap();
        sqlx::raw_sql(m2).execute(&pre_pool).await.unwrap();

        // Seed _sqlx_migrations for 1 & 2? Actually let's test applying 0003 raw SQL directly
        // on the pre-0003 seeded rows, AND verify open_test_database creates all 0003 tables/columns.
        sqlx::query("INSERT INTO artists (id, name, sort_name) VALUES ('a1', 'Artist', 'Artist')")
            .execute(&pre_pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO canonical_albums (id, title, sort_title, primary_artist_id, created_at) \
             VALUES ('alb1', 'Surround DSD', 'Surround DSD', 'a1', '2026-01-01T00:00:00Z')",
        )
        .execute(&pre_pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO album_versions (id, canonical_album_id, provider_id, external_album_id, \
             codec, sample_rate_hz, bit_depth, channels, is_dsd) \
             VALUES ('v1', 'alb1', 'local', 'ext-v1', 'dsf', 2822400, 1, 6, 1)",
        )
        .execute(&pre_pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO track_sources (id, version_id, provider_id, external_track_id, title, \
             disc_number, track_number, duration_ms, sample_rate_hz, bit_depth, codec) \
             VALUES ('t1', 'v1', 'local', 'D:/dsd.dsf', 'DSD Track', 1, 1, 100000, 2822400, 1, 'dsf')",
        )
        .execute(&pre_pool)
        .await
        .unwrap();

        let m3 = include_str!("../migrations/0003_metadata_artwork_cache.sql");
        sqlx::raw_sql(m3).execute(&pre_pool).await.unwrap();

        let row: (i64, i32) =
            sqlx::query_as("SELECT channels, is_dsd FROM track_sources WHERE id = 't1'")
                .fetch_one(&pre_pool)
                .await
                .unwrap();
        assert_eq!(row.0, 6);
        assert_eq!(row.1, 1);
    }

    // Also verify normal open_test_database creates 0003 tables cleanly
    let pool = open_test_database().await.unwrap();
    let tables: Vec<(String,)> = sqlx::query_as(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let names: Vec<String> = tables.into_iter().map(|(n,)| n).collect();
    assert!(names.contains(&"artwork_cache".to_string()));
    assert!(names.contains(&"artwork_overrides".to_string()));
}

#[tokio::test]
async fn test_metadata_hydration_channels_dsd_and_fts_subtitle() {
    let pool = open_test_database().await.unwrap();

    let artist = LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "Various Artists",
        None,
        None,
        None,
    )
    .await
    .unwrap();

    let mut album = CanonicalAlbum::new("SACD Multi-Ch Compilation", "Various Artists")
        .unwrap()
        .with_album_artist("Various Artists (Album Artist)");
    album.id = "alb-sacd".into();

    let ver_mono = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "ext-mono",
        AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 1).unwrap(),
    )
    .unwrap();
    let ver_dsd_6ch = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "ext-dsd6",
        AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 6).unwrap(),
    )
    .unwrap();
    album.add_version(ver_mono.clone());
    album.add_version(ver_dsd_6ch.clone());

    LibraryRepository::insert_canonical_album(&pool, &album, Some(&artist.id))
        .await
        .unwrap();

    let fetched_album = LibraryRepository::find_canonical_album_by_id(&pool, &album.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        fetched_album.album_artist.as_deref(),
        Some("Various Artists (Album Artist)")
    );

    let trk_mono = TrackSource::new(
        &ver_mono.id,
        ProviderKind::Local,
        "D:/Music/mono.flac",
        "Mono Lead",
        1,
        1,
        120_000,
        AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 1).unwrap(),
    )
    .unwrap()
    .with_artist_name("坂本龍一")
    .with_album_artist("Various Artists (Album Artist)")
    .with_genre("Ambient")
    .with_composer("Ryuichi Sakamoto");

    let trk_dsd = TrackSource::new(
        &ver_dsd_6ch.id,
        ProviderKind::Local,
        "D:/Music/surround.dsf",
        "Surround Finale",
        1,
        2,
        240_000,
        AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 6).unwrap(),
    )
    .unwrap()
    .with_artist_name("陳奕迅")
    .with_genre("Classical");

    LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &trk_mono,
        Some("[00:10.00]Instrumental"),
        Some(1_700_000_000),
        Some(12_345_678),
        Some("hash-mono-1"),
    )
    .await
    .unwrap();
    LibraryRepository::insert_track_sources_batch(&pool, std::slice::from_ref(&trk_dsd))
        .await
        .unwrap();

    let hydrated_mono = LibraryRepository::find_track_source_by_id(&pool, &trk_mono.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(hydrated_mono.format.channels, 1);
    assert!(!hydrated_mono.format.is_dsd);
    assert_eq!(hydrated_mono.artist_name.as_deref(), Some("坂本龍一"));
    assert_eq!(
        hydrated_mono.album_artist.as_deref(),
        Some("Various Artists (Album Artist)")
    );
    assert_eq!(hydrated_mono.genre.as_deref(), Some("Ambient"));
    assert_eq!(hydrated_mono.composer.as_deref(), Some("Ryuichi Sakamoto"));
    assert!(hydrated_mono.has_lyrics);
    assert_eq!(
        LibraryRepository::get_track_embedded_lyrics(&pool, &trk_mono.id)
            .await
            .unwrap()
            .as_deref(),
        Some("[00:10.00]Instrumental")
    );

    let hydrated_dsd = LibraryRepository::find_track_sources_by_version(&pool, &ver_dsd_6ch.id)
        .await
        .unwrap();
    assert_eq!(hydrated_dsd.len(), 1);
    assert_eq!(hydrated_dsd[0].format.channels, 6);
    assert!(hydrated_dsd[0].format.is_dsd);
    assert_eq!(hydrated_dsd[0].artist_name.as_deref(), Some("陳奕迅"));
    assert_eq!(hydrated_dsd[0].genre.as_deref(), Some("Classical"));
    assert!(!hydrated_dsd[0].has_lyrics);

    // FTS5 rebuild indexes track-level artist_name rather than only album artist
    rebuild_search_index(&pool).await.unwrap();
    let fts_hits = search_library(&pool, "坂本龍一").await.unwrap();
    assert!(
        fts_hits
            .iter()
            .any(|h| h.entity_type == "track" && h.entity_id == trk_mono.id),
        "expected track FTS hit for track-level artist_name, got {fts_hits:?}"
    );
}

#[tokio::test]
async fn test_rescan_clears_removed_tags_and_preserves_id_and_play_history() {
    let pool = open_test_database().await.unwrap();
    let prof = ProfileRepository::create_profile(
        &pool,
        &Profile::new("Rescan Tester", "#112233", true).unwrap(),
    )
    .await
    .unwrap();

    let artist =
        LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "Test Artist", None, None, None)
            .await
            .unwrap();
    let album = CanonicalAlbum::new("Rescan Album", "Test Artist").unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, Some(&artist.id))
        .await
        .unwrap();
    let ver = AlbumVersion::new(&album.id, ProviderKind::Local, "v-rescan", AudioFormat::cd_quality())
        .unwrap();
    LibraryRepository::insert_album_version(&pool, &ver).await.unwrap();

    let initial = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/rescan.flac",
        "Original Title",
        1,
        1,
        200_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_isrc("USRC17607839")
    .unwrap()
    .with_replay_gain(Some(-5.5), Some(-6.0), Some(0.95), Some(0.98))
    .with_artist_name("Track Artist")
    .with_album_artist("Album Artist")
    .with_genre("Jazz")
    .with_composer("Composer X");

    let persisted_1 = LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &initial,
        Some("Old Lyrics"),
        Some(1000),
        Some(2000),
        Some("h1"),
    )
    .await
    .unwrap();
    assert!(persisted_1.has_lyrics);

    // Record play history against initial.id
    LibraryRepository::record_play(&pool, &prof.id, &persisted_1.id, 90_000)
        .await
        .unwrap();

    // Rescan with a brand new TrackSource struct (different in-memory UUID) and cleared tags
    let rescanned = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/rescan.flac",
        "Updated Title",
        1,
        1,
        200_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();

    let persisted_2 = LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &rescanned,
        None,
        Some(1001),
        Some(2001),
        Some("h2"),
    )
    .await
    .unwrap();

    // Must preserve original DB row ID so play_history FK remains intact
    assert_eq!(persisted_2.id, persisted_1.id);
    assert!(!persisted_2.has_lyrics);

    let reloaded = LibraryRepository::find_track_source_by_id(&pool, &persisted_1.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reloaded.title, "Updated Title");
    assert_eq!(reloaded.isrc, None);
    assert_eq!(reloaded.replay_gain_track_db, None);
    assert_eq!(reloaded.replay_gain_album_db, None);
    assert_eq!(reloaded.replay_gain_track_peak, None);
    assert_eq!(reloaded.replay_gain_album_peak, None);
    assert_eq!(reloaded.artist_name, None);
    assert_eq!(reloaded.album_artist, None);
    assert_eq!(reloaded.genre, None);
    assert_eq!(reloaded.composer, None);
    assert!(!reloaded.has_lyrics);
    assert_eq!(
        LibraryRepository::get_track_embedded_lyrics(&pool, &persisted_1.id)
            .await
            .unwrap(),
        None
    );

    // Also verify insert_track_source clears nullable tags without COALESCE
    let with_isrc = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/rescan.flac",
        "Updated Title 2",
        1,
        1,
        200_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_isrc("GBAYE7300001")
    .unwrap()
    .with_genre("Rock");
    LibraryRepository::insert_track_source(&pool, &with_isrc)
        .await
        .unwrap();
    let after_set = LibraryRepository::find_track_source_by_id(&pool, &persisted_1.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after_set.isrc.as_deref(), Some("GBAYE7300001"));
    assert_eq!(after_set.genre.as_deref(), Some("Rock"));

    let cleared = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/rescan.flac",
        "Updated Title 3",
        1,
        1,
        200_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let cleared_ret = LibraryRepository::insert_track_source(&pool, &cleared)
        .await
        .unwrap();
    assert_eq!(cleared_ret.id, persisted_1.id);
    let after_clear = LibraryRepository::find_track_source_by_id(&pool, &persisted_1.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after_clear.isrc, None);
    assert_eq!(after_clear.genre, None);

    // Play history survived every rescan upsert
    let hist = LibraryRepository::get_recent_history(&pool, &prof.id, 10)
        .await
        .unwrap();
    assert_eq!(hist.len(), 1);
    assert_eq!(hist[0].track_source_id, persisted_1.id);

    // Whitespace-only (\n, \t, \r, space) embedded_lyrics must report has_lyrics == false
    // both on upsert return and across all DB SELECT paths.
    let ws_track = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/rescan.flac",
        "Whitespace Lyrics Track",
        1,
        1,
        200_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_isrc("USRC17607840")
    .unwrap();
    let persisted_ws = LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &ws_track,
        Some("  \n\t\r  "),
        Some(1002),
        Some(2002),
        Some("h3"),
    )
    .await
    .unwrap();
    assert!(!persisted_ws.has_lyrics);
    let by_id_ws = LibraryRepository::find_track_source_by_id(&pool, &persisted_1.id)
        .await
        .unwrap()
        .unwrap();
    assert!(!by_id_ws.has_lyrics);
    let by_ver_ws = LibraryRepository::find_track_sources_by_version(&pool, &ver.id)
        .await
        .unwrap();
    assert!(!by_ver_ws[0].has_lyrics);
    let by_isrc_ws = LibraryRepository::find_track_sources_by_isrc(&pool, "USRC17607840")
        .await
        .unwrap();
    assert!(!by_isrc_ws[0].has_lyrics);

    // insert_track_source preserves DB embedded_lyrics and reflects true DB has_lyrics on return
    let with_real_lyrics = LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &ws_track,
        Some("[00:01.00] Real lyrics line"),
        Some(1003),
        Some(2003),
        Some("h4"),
    )
    .await
    .unwrap();
    assert!(with_real_lyrics.has_lyrics);

    let update_without_lyrics_flag = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/rescan.flac",
        "Updated Title Keeping Lyrics",
        1,
        1,
        200_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    assert!(!update_without_lyrics_flag.has_lyrics);
    let persisted_kept_lyrics =
        LibraryRepository::insert_track_source(&pool, &update_without_lyrics_flag)
            .await
            .unwrap();
    assert!(persisted_kept_lyrics.has_lyrics);
}

#[tokio::test]
async fn test_unicode_deterministic_artist_ids_and_file_cache_info() {
    let pool = open_test_database().await.unwrap();

    let id_sakamoto = deterministic_artist_id("坂本龍");
    let id_eason = deterministic_artist_id("陳奕迅");
    assert_ne!(id_sakamoto, id_eason);
    assert!(id_sakamoto.starts_with("art:"));
    assert_eq!(id_sakamoto.len(), 36);
    assert_eq!(
        LibraryRepository::deterministic_artist_id("  Pink   Floyd "),
        deterministic_artist_id("PINK FLOYD")
    );
    assert_eq!(
        deterministic_artist_id("  Café  "),
        deterministic_artist_id("CAFÉ")
    );

    let a1 = LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "坂本龍", None, None, None)
        .await
        .unwrap();
    let a2 = LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "陳奕迅", None, None, None)
        .await
        .unwrap();
    assert_ne!(a1.id, a2.id);

    // Non-ASCII case variants collapse to the same row without PK collision
    let c1 = LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "  Café  ", None, None, None)
        .await
        .unwrap();
    let c2 = LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "CAFÉ",
        None,
        Some("French band"),
        None,
    )
    .await
    .unwrap();
    assert_eq!(c1.id, c2.id);
    assert_eq!(c2.biography.as_deref(), Some("French band"));

    // File cache info lookup/list/update
    let album = CanonicalAlbum::new("Cache Album", "坂本龍").unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, Some(&a1.id))
        .await
        .unwrap();
    let ver = AlbumVersion::new(&album.id, ProviderKind::Local, "v-cache", AudioFormat::cd_quality())
        .unwrap();
    LibraryRepository::insert_album_version(&pool, &ver).await.unwrap();
    let trk = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/c1.flac",
        "Cache Track",
        1,
        1,
        100_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &trk,
        None,
        Some(1_700_000_001),
        Some(4096),
        Some("sha-1"),
    )
    .await
    .unwrap();

    let info = LibraryRepository::get_track_file_cache_info(&pool, "local", "D:/Music/c1.flac")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(info.track_id, trk.id);
    assert_eq!(info.file_mtime, Some(1_700_000_001));
    assert_eq!(info.file_size, Some(4096));
    assert_eq!(info.metadata_hash.as_deref(), Some("sha-1"));

    assert!(
        LibraryRepository::update_track_file_cache_info(
            &pool,
            &trk.id,
            Some(1_700_000_999),
            Some(8192),
            Some("sha-2")
        )
        .await
        .unwrap()
    );
    let list = LibraryRepository::list_track_file_cache_info(&pool, "local")
        .await
        .unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].file_mtime, Some(1_700_000_999));
    assert_eq!(list[0].file_size, Some(8192));
    assert_eq!(list[0].metadata_hash.as_deref(), Some("sha-2"));
}

#[tokio::test]
async fn test_prune_missing_local_tracks_scoped_boundary_and_cascade() {
    let pool = open_test_database().await.unwrap();
    let prof = ProfileRepository::create_profile(
        &pool,
        &Profile::new("Prune User", "#445566", true).unwrap(),
    )
    .await
    .unwrap();
    let artist =
        LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "Prune Artist", None, None, None)
            .await
            .unwrap();

    // Album A under D:/Music/A (missing from disk)
    let mut alb_a = CanonicalAlbum::new("Album A", "Prune Artist").unwrap();
    alb_a.id = "alb-a".into();
    let ver_a = AlbumVersion::new(&alb_a.id, ProviderKind::Local, "D:/Music/A", AudioFormat::cd_quality())
        .unwrap();
    alb_a.add_version(ver_a.clone());
    LibraryRepository::insert_canonical_album(&pool, &alb_a, Some(&artist.id))
        .await
        .unwrap();
    let trk_a = TrackSource::new(
        &ver_a.id,
        ProviderKind::Local,
        "D:/Music/A/01.flac",
        "Song A",
        1,
        1,
        150_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_track_source(&pool, &trk_a).await.unwrap();

    // Album A2 under D:/Music/A2 (prefix trap! must NOT be touched when scoping to D:/Music/A)
    let mut alb_a2 = CanonicalAlbum::new("Album A2", "Prune Artist").unwrap();
    alb_a2.id = "alb-a2".into();
    let ver_a2 = AlbumVersion::new(
        &alb_a2.id,
        ProviderKind::Local,
        "D:/Music/A2",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    alb_a2.add_version(ver_a2.clone());
    LibraryRepository::insert_canonical_album(&pool, &alb_a2, Some(&artist.id))
        .await
        .unwrap();
    let trk_a2 = TrackSource::new(
        &ver_a2.id,
        ProviderKind::Local,
        "D:/Music/A2/01.flac",
        "Song A2",
        1,
        1,
        160_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_track_source(&pool, &trk_a2).await.unwrap();

    // Unrelated pre-existing trackless version on Album A2 (must NOT be deleted)
    let trackless_ver = AlbumVersion::new(
        &alb_a2.id,
        ProviderKind::Qobuz,
        "q-trackless",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_album_version(&pool, &trackless_ver)
        .await
        .unwrap();

    // Album B under D:/Music/B (kept)
    let mut alb_b = CanonicalAlbum::new("Album B", "Prune Artist").unwrap();
    alb_b.id = "alb-b".into();
    let ver_b = AlbumVersion::new(&alb_b.id, ProviderKind::Local, "D:/Music/B", AudioFormat::cd_quality())
        .unwrap();
    alb_b.add_version(ver_b.clone());
    LibraryRepository::insert_canonical_album(&pool, &alb_b, Some(&artist.id))
        .await
        .unwrap();
    let trk_b = TrackSource::new(
        &ver_b.id,
        ProviderKind::Local,
        "D:/Music/B/02.flac",
        "Song B",
        1,
        1,
        170_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_track_source(&pool, &trk_b).await.unwrap();

    // Attach play_history, credits, favorites, artwork_cache, artwork_overrides, search_fts to Album A
    LibraryRepository::record_play(&pool, &prof.id, &trk_a.id, 60_000)
        .await
        .unwrap();
    LibraryRepository::insert_album_credit(&pool, &alb_a.id, &artist.id, "Performer")
        .await
        .unwrap();
    LibraryRepository::add_favorite(&pool, &prof.id, "track", &trk_a.id)
        .await
        .unwrap();
    LibraryRepository::add_favorite(&pool, &prof.id, "album", &alb_a.id)
        .await
        .unwrap();
    LibraryRepository::set_artwork_override(&pool, "track", &trk_a.id, "D:/cover_t.jpg")
        .await
        .unwrap();
    LibraryRepository::set_artwork_override(&pool, "album", &alb_a.id, "D:/cover_a.jpg")
        .await
        .unwrap();
    LibraryRepository::upsert_artwork_cache(
        &pool,
        &ArtworkCacheEntry {
            cache_key: "trk:a:512".into(),
            track_id: Some(trk_a.id.clone()),
            album_id: None,
            source_kind: "embedded".into(),
            mime_type: Some("image/jpeg".into()),
            width: Some(512),
            height: Some(512),
            max_dim: 512,
            cache_path: "C:/cache/trk_a_512.jpg".into(),
            source_mtime: Some(100),
            updated_at: String::new(),
        },
    )
    .await
    .unwrap();
    LibraryRepository::upsert_artwork_cache(
        &pool,
        &ArtworkCacheEntry {
            cache_key: "alb:a:512".into(),
            track_id: None,
            album_id: Some(alb_a.id.clone()),
            source_kind: "cover".into(),
            mime_type: Some("image/png".into()),
            width: Some(512),
            height: Some(512),
            max_dim: 512,
            cache_path: "C:/cache/alb_a_512.png".into(),
            source_mtime: Some(100),
            updated_at: String::new(),
        },
    )
    .await
    .unwrap();
    rebuild_search_index(&pool).await.unwrap();

    // Scoped prune on D:\Music\A (mixed slashes & case) with empty existing_paths
    let report = LibraryRepository::prune_missing_local_tracks(
        &pool,
        Some(r"d:\music\a\"),
        &HashSet::new(),
    )
    .await
    .unwrap();
    assert_eq!(report.tracks_pruned, 1);
    assert_eq!(report.versions_pruned, 1);
    assert_eq!(report.albums_pruned, 1);
    assert_eq!(report.invalidated_artwork_paths.len(), 2);
    assert!(report
        .invalidated_artwork_paths
        .contains(&"C:/cache/trk_a_512.jpg".to_string()));
    assert!(report
        .invalidated_artwork_paths
        .contains(&"C:/cache/alb_a_512.png".to_string()));

    assert!(LibraryRepository::find_track_source_by_id(&pool, &trk_a.id)
        .await
        .unwrap()
        .is_none());
    assert!(LibraryRepository::find_canonical_album_by_id(&pool, &alb_a.id)
        .await
        .unwrap()
        .is_none());
    assert!(LibraryRepository::get_artwork_override(&pool, "track", &trk_a.id)
        .await
        .unwrap()
        .is_none());
    assert!(LibraryRepository::get_artwork_override(&pool, "album", &alb_a.id)
        .await
        .unwrap()
        .is_none());
    assert!(!LibraryRepository::is_favorite(&pool, &prof.id, "album", &alb_a.id)
        .await
        .unwrap());
    assert!(LibraryRepository::get_recent_history(&pool, &prof.id, 10)
        .await
        .unwrap()
        .is_empty());

    // Album A2 (prefix boundary) + trackless Qobuz version + Album B remain intact
    assert!(LibraryRepository::find_track_source_by_id(&pool, &trk_a2.id)
        .await
        .unwrap()
        .is_some());
    assert_eq!(
        LibraryRepository::list_versions_for_album(&pool, &alb_a2.id)
            .await
            .unwrap()
            .len(),
        2
    );
    assert!(LibraryRepository::find_track_source_by_id(&pool, &trk_b.id)
        .await
        .unwrap()
        .is_some());

    // Unscoped prune keeping only d:/music/b/02.flac (case-insensitive) prunes trk_a2, keeps trk_b and trackless_ver
    let mut keep = HashSet::new();
    keep.insert("d:\\music\\b\\02.flac".to_string());
    let report_2 = LibraryRepository::prune_missing_local_tracks(&pool, None, &keep)
        .await
        .unwrap();
    assert_eq!(report_2.tracks_pruned, 1);
    assert_eq!(report_2.versions_pruned, 1); // ver_a2 pruned; trackless_ver preserved!
    assert_eq!(report_2.albums_pruned, 0); // alb_a2 still has trackless_ver
    assert_eq!(
        LibraryRepository::list_versions_for_album(&pool, &alb_a2.id)
            .await
            .unwrap()
            .len(),
        1
    );
    assert!(LibraryRepository::find_track_source_by_id(&pool, &trk_b.id)
        .await
        .unwrap()
        .is_some());
}

#[tokio::test]
async fn test_artwork_cache_overrides_merge_and_delete_cascade() {
    let pool = open_test_database().await.unwrap();
    let artist =
        LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "Art Artist", None, None, None)
            .await
            .unwrap();

    let mut alb1 = CanonicalAlbum::new("Art Album 1", "Art Artist").unwrap();
    alb1.id = "alb-art-1".into();
    let ver1 = AlbumVersion::new(&alb1.id, ProviderKind::Local, "v-art-1", AudioFormat::cd_quality())
        .unwrap();
    alb1.add_version(ver1.clone());
    LibraryRepository::insert_canonical_album(&pool, &alb1, Some(&artist.id))
        .await
        .unwrap();
    let trk1 = TrackSource::new(
        &ver1.id,
        ProviderKind::Local,
        "D:/Art/01.flac",
        "Art Track 1",
        1,
        1,
        120_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_track_source(&pool, &trk1).await.unwrap();

    let mut alb2 = CanonicalAlbum::new("Art Album 2", "Art Artist")
        .unwrap()
        .with_album_artist("Art Album Artist");
    alb2.id = "alb-art-2".into();
    let ver2 = AlbumVersion::new(&alb2.id, ProviderKind::Qobuz, "q-art-2", AudioFormat::cd_quality())
        .unwrap();
    alb2.add_version(ver2);
    LibraryRepository::insert_canonical_album(&pool, &alb2, Some(&artist.id))
        .await
        .unwrap();

    // Artwork cache CRUD & invalidation
    let entry_trk = ArtworkCacheEntry {
        cache_key: "trk:1:256".into(),
        track_id: Some(trk1.id.clone()),
        album_id: None,
        source_kind: "embedded".into(),
        mime_type: Some("image/webp".into()),
        width: Some(256),
        height: Some(256),
        max_dim: 256,
        cache_path: "C:/cache/t1_256.webp".into(),
        source_mtime: Some(500),
        updated_at: String::new(),
    };
    LibraryRepository::upsert_artwork_cache(&pool, &entry_trk)
        .await
        .unwrap();
    let got_trk = LibraryRepository::get_artwork_cache(&pool, "trk:1:256")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(got_trk.cache_path, "C:/cache/t1_256.webp");

    let invalidated = LibraryRepository::invalidate_artwork_cache_for_track(&pool, &trk1.id)
        .await
        .unwrap();
    assert_eq!(invalidated, vec!["C:/cache/t1_256.webp".to_string()]);
    assert!(LibraryRepository::get_artwork_cache(&pool, "trk:1:256")
        .await
        .unwrap()
        .is_none());

    // Album cache + delete_artwork_cache + clear_artwork_cache
    LibraryRepository::upsert_artwork_cache(
        &pool,
        &ArtworkCacheEntry {
            cache_key: "alb:1:512".into(),
            track_id: None,
            album_id: Some(alb1.id.clone()),
            source_kind: "cover".into(),
            mime_type: Some("image/jpeg".into()),
            width: Some(512),
            height: Some(512),
            max_dim: 512,
            cache_path: "C:/cache/a1_512.jpg".into(),
            source_mtime: None,
            updated_at: String::new(),
        },
    )
    .await
    .unwrap();
    LibraryRepository::upsert_artwork_cache(
        &pool,
        &ArtworkCacheEntry {
            cache_key: "standalone:ph".into(),
            track_id: None,
            album_id: None,
            source_kind: "placeholder".into(),
            mime_type: None,
            width: None,
            height: None,
            max_dim: 0,
            cache_path: "C:/cache/ph.png".into(),
            source_mtime: None,
            updated_at: String::new(),
        },
    )
    .await
    .unwrap();
    assert!(LibraryRepository::delete_artwork_cache(&pool, "standalone:ph")
        .await
        .unwrap());
    assert!(!LibraryRepository::delete_artwork_cache(&pool, "standalone:ph")
        .await
        .unwrap());

    // Overrides validation & CRUD
    assert!(
        LibraryRepository::set_artwork_override(&pool, "invalid", "x", "y")
            .await
            .is_err()
    );
    LibraryRepository::set_artwork_override(&pool, "album", &alb2.id, "D:/Covers/custom2.jpg")
        .await
        .unwrap();
    assert_eq!(
        LibraryRepository::get_artwork_override(&pool, "album", &alb2.id)
            .await
            .unwrap()
            .unwrap()
            .image_path,
        "D:/Covers/custom2.jpg"
    );

    // merge_canonical_albums migrates album_artist and album artwork_override from alb2 -> alb1
    assert!(
        LibraryRepository::merge_canonical_albums(&pool, &alb1.id, &alb2.id)
            .await
            .unwrap()
    );
    let merged_alb = LibraryRepository::find_canonical_album_by_id(&pool, &alb1.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(merged_alb.album_artist.as_deref(), Some("Art Album Artist"));
    assert_eq!(
        LibraryRepository::get_artwork_override(&pool, "album", &alb1.id)
            .await
            .unwrap()
            .unwrap()
            .image_path,
        "D:/Covers/custom2.jpg"
    );
    assert!(LibraryRepository::get_artwork_override(&pool, "album", &alb2.id)
        .await
        .unwrap()
        .is_none());
    // Stale target album artwork_cache was invalidated when alb2's override was adopted
    assert!(LibraryRepository::get_artwork_cache(&pool, "alb:1:512")
        .await
        .unwrap()
        .is_none());

    // Insert fresh post-merge cache entry for alb1, then verify delete_canonical_album cascades it
    LibraryRepository::upsert_artwork_cache(
        &pool,
        &ArtworkCacheEntry {
            cache_key: "alb:1:user:512".into(),
            track_id: None,
            album_id: Some(alb1.id.clone()),
            source_kind: "user".into(),
            mime_type: Some("image/jpeg".into()),
            width: Some(512),
            height: Some(512),
            max_dim: 512,
            cache_path: "C:/cache/a1_user_512.jpg".into(),
            source_mtime: None,
            updated_at: String::new(),
        },
    )
    .await
    .unwrap();

    // delete_canonical_album cascades artwork_cache & cleans artwork_overrides
    LibraryRepository::delete_canonical_album(&pool, &alb1.id)
        .await
        .unwrap();
    assert!(LibraryRepository::get_artwork_cache(&pool, "alb:1:user:512")
        .await
        .unwrap()
        .is_none());
    assert!(LibraryRepository::get_artwork_override(&pool, "album", &alb1.id)
        .await
        .unwrap()
        .is_none());

    // clear_artwork_cache returns any remaining paths and empties table
    LibraryRepository::upsert_artwork_cache(
        &pool,
        &ArtworkCacheEntry {
            cache_key: "temp:1".into(),
            track_id: None,
            album_id: None,
            source_kind: "user".into(),
            mime_type: Some("image/png".into()),
            width: Some(128),
            height: Some(128),
            max_dim: 128,
            cache_path: "C:/cache/temp1.png".into(),
            source_mtime: None,
            updated_at: String::new(),
        },
    )
    .await
    .unwrap();
    let cleared = LibraryRepository::clear_artwork_cache(&pool).await.unwrap();
    assert_eq!(cleared, vec!["C:/cache/temp1.png".to_string()]);
    assert!(LibraryRepository::clear_artwork_cache(&pool)
        .await
        .unwrap()
        .is_empty());
}

#[tokio::test]
async fn test_concurrent_upsert_artist_by_mbid_or_name_no_toctou_race() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("concurrent_artists.db");
    let pool = open_database(&db_path).await.unwrap();

    // 16 concurrent tasks racing on the exact same unseen Unicode artist
    let barrier_name = Arc::new(tokio::sync::Barrier::new(16));
    let mut handles = Vec::with_capacity(16);
    for _ in 0..16 {
        let pool_cloned = pool.clone();
        let barrier = Arc::clone(&barrier_name);
        handles.push(tokio::spawn(async move {
            barrier.wait().await;
            LibraryRepository::upsert_artist_by_mbid_or_name(
                &pool_cloned,
                "Concurrent 坂本龍一",
                None,
                None,
                None,
            )
            .await
        }));
    }

    let expected_id = deterministic_artist_id("Concurrent 坂本龍一");
    for handle in handles {
        let artist = handle.await.unwrap().expect("concurrent upsert should succeed");
        assert_eq!(artist.id, expected_id);
    }

    let count_name: (i64,) = sqlx::query_as("SELECT COUNT(*) FROM artists WHERE id = ?")
        .bind(&expected_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count_name.0, 1);

    // 16 concurrent tasks racing on the same unseen MusicBrainz ID across varying name spellings
    let barrier_mbid = Arc::new(tokio::sync::Barrier::new(16));
    let mut mbid_handles = Vec::with_capacity(16);
    for idx in 0..16 {
        let pool_cloned = pool.clone();
        let barrier = Arc::clone(&barrier_mbid);
        let artist_name = if idx % 2 == 0 {
            "Concurrent MBID 坂本龍一"
        } else {
            "Ryuichi Sakamoto"
        };
        mbid_handles.push(tokio::spawn(async move {
            barrier.wait().await;
            LibraryRepository::upsert_artist_by_mbid_or_name(
                &pool_cloned,
                artist_name,
                Some("mb-concurrent-sakamoto"),
                None,
                None,
            )
            .await
        }));
    }

    let mut mbid_ids = HashSet::new();
    for handle in mbid_handles {
        let artist = handle
            .await
            .unwrap()
            .expect("concurrent MBID upsert should succeed");
        mbid_ids.insert(artist.id);
    }
    assert_eq!(mbid_ids.len(), 1);

    let count_mbid: (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM artists WHERE musicbrainz_id = ?")
            .bind("mb-concurrent-sakamoto")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(count_mbid.0, 1);
}
