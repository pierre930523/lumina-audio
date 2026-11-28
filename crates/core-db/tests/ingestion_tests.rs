use std::collections::HashSet;

use core_db::{
    ImmediateTx, IngestionRepository, LibraryRepository, ProfileRepository, SidecarPlaylistEntry,
    open_test_database, search_library, sync_album_fts_conn, sync_artist_fts_conn,
    sync_track_fts_conn,
};
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, FileStatus, MetadataLayer, Profile,
    ProviderKind, SkipReason, TocSignature, TrackSource, WatchMode,
};

#[tokio::test]
async fn test_migration_0006_and_watched_roots_crud() {
    let pool = open_test_database().await.unwrap();

    let r1 = IngestionRepository::upsert_watched_root(
        &pool,
        "local",
        "D:/Music/Lossless",
        WatchMode::NativeOs,
        300,
    )
    .await
    .unwrap();
    assert_eq!(r1.provider_id, "local");
    assert_eq!(r1.watch_mode, WatchMode::NativeOs);
    assert!(r1.is_online);
    assert!(r1.last_scan_at.is_none());

    // Upsert same path updates mode & interval while preserving ID
    let r1_upd = IngestionRepository::upsert_watched_root(
        &pool,
        "smb",
        "D:/Music/Lossless",
        WatchMode::NasPolling,
        600,
    )
    .await
    .unwrap();
    assert_eq!(r1_upd.id, r1.id);
    assert_eq!(r1_upd.watch_mode, WatchMode::NasPolling);
    assert_eq!(r1_upd.poll_interval_sec, 600);

    assert!(
        IngestionRepository::set_root_online_status(&pool, &r1.id, false)
            .await
            .unwrap()
    );
    assert!(
        IngestionRepository::touch_root_scan_time(&pool, &r1.id)
            .await
            .unwrap()
    );

    let roots = IngestionRepository::list_watched_roots(&pool)
        .await
        .unwrap();
    assert_eq!(roots.len(), 1);
    assert!(!roots[0].is_online);
    assert!(roots[0].last_scan_at.is_some());

    assert!(
        IngestionRepository::remove_watched_root(&pool, &r1.id)
            .await
            .unwrap()
    );
    assert!(
        IngestionRepository::list_watched_roots(&pool)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn test_skipped_files_quarantine_dismiss_and_clear() {
    let pool = open_test_database().await.unwrap();

    let s1 = IngestionRepository::record_skipped_file(
        &pool,
        "local",
        "D:/Music/AlbumA/disc.cue",
        SkipReason::UnsplitCueOrIso,
        "Unsplit CUE sheet",
        Some(1024),
        Some(1_700_000_000),
    )
    .await
    .unwrap();
    let _s2 = IngestionRepository::record_skipped_file(
        &pool,
        "local",
        "D:/Music/AlbumB/broken.flac",
        SkipReason::CorruptHeader,
        "Invalid FLAC marker",
        Some(512),
        Some(1_700_000_010),
    )
    .await
    .unwrap();

    assert_eq!(
        IngestionRepository::list_skipped_files(&pool, false)
            .await
            .unwrap()
            .len(),
        2
    );

    assert!(
        IngestionRepository::dismiss_skipped_file(&pool, &s1.id)
            .await
            .unwrap()
    );
    assert_eq!(
        IngestionRepository::list_skipped_files(&pool, false)
            .await
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        IngestionRepository::list_skipped_files(&pool, true)
            .await
            .unwrap()
            .len(),
        2
    );

    // Re-recording same file with unchanged reason+mtime keeps dismissed=true
    let s1_same = IngestionRepository::record_skipped_file(
        &pool,
        "local",
        "D:/Music/AlbumA/disc.cue",
        SkipReason::UnsplitCueOrIso,
        "Unsplit CUE sheet",
        Some(1024),
        Some(1_700_000_000),
    )
    .await
    .unwrap();
    assert!(s1_same.dismissed);

    // Re-recording with changed mtime un-dismisses so user sees newly modified file
    let s1_changed = IngestionRepository::record_skipped_file(
        &pool,
        "local",
        "D:/Music/AlbumA/disc.cue",
        SkipReason::UnsplitCueOrIso,
        "Still unsplit",
        Some(2048),
        Some(1_700_000_999),
    )
    .await
    .unwrap();
    assert!(!s1_changed.dismissed);

    assert!(
        IngestionRepository::clear_skipped_for_path(&pool, "local", "D:/Music/AlbumB/broken.flac")
            .await
            .unwrap()
    );
    let cleared = IngestionRepository::clear_skipped_for_root(&pool, "local", "D:/Music/AlbumA")
        .await
        .unwrap();
    assert_eq!(cleared, 1);
    assert!(
        IngestionRepository::list_skipped_files(&pool, true)
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn test_layered_metadata_override_precedence_and_non_destructive_rescan() {
    let pool = open_test_database().await.unwrap();

    let artist =
        LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "Miles Davis", None, None, None)
            .await
            .unwrap();
    let album = CanonicalAlbum::new("Kind of Blue", "Miles Davis")
        .unwrap()
        .with_release_year(1959)
        .unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, Some(&artist.id))
        .await
        .unwrap();
    let ver = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "dir::kob",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_album_version(&pool, &ver)
        .await
        .unwrap();

    let track = TrackSource::new(
        &ver.id,
        ProviderKind::Local,
        "D:/Music/Miles/01.flac",
        "So What (Tag)",
        1,
        1,
        562_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_genre("Jazz");
    let saved_track = LibraryRepository::insert_track_source(&pool, &track)
        .await
        .unwrap();

    // FileTag sets authoritative title override
    assert!(
        IngestionRepository::set_metadata_override(
            &pool,
            "track",
            &saved_track.id,
            "title",
            "\"So What (File)\"",
            MetadataLayer::FileTag,
        )
        .await
        .unwrap()
    );
    // CloudEnrichment cannot overwrite FileTag (CloudEnrichment(0) < FileTag(1) < UserEdit(2))
    assert!(
        !IngestionRepository::set_metadata_override(
            &pool,
            "track",
            &saved_track.id,
            "title",
            "\"So What (Cloud)\"",
            MetadataLayer::CloudEnrichment,
        )
        .await
        .unwrap()
    );

    // UserEdit overwrites FileTag
    assert!(
        IngestionRepository::set_metadata_override(
            &pool,
            "track",
            &saved_track.id,
            "title",
            "\"So What (User Master)\"",
            MetadataLayer::UserEdit,
        )
        .await
        .unwrap()
    );
    // CloudEnrichment & FileTag cannot overwrite UserEdit
    assert!(
        !IngestionRepository::set_metadata_override(
            &pool,
            "track",
            &saved_track.id,
            "title",
            "\"So What (Cloud Attempt 2)\"",
            MetadataLayer::CloudEnrichment,
        )
        .await
        .unwrap()
    );
    assert!(
        !IngestionRepository::set_metadata_override(
            &pool,
            "track",
            &saved_track.id,
            "title",
            "\"So What (File Attempt 2)\"",
            MetadataLayer::FileTag,
        )
        .await
        .unwrap()
    );

    // Album UserEdit override
    assert!(
        IngestionRepository::set_metadata_override(
            &pool,
            "album",
            &album.id,
            "title",
            "\"Kind of Blue (My Favorite)\"",
            MetadataLayer::UserEdit,
        )
        .await
        .unwrap()
    );

    // Simulate rescan updating base track_sources row
    let mut rescanned = saved_track.clone();
    rescanned.title = "So What (Rescanned Tag)".to_string();
    LibraryRepository::upsert_track_source_with_cache(
        &pool,
        &rescanned,
        None,
        Some(1_700_000_500),
        Some(50_000_000),
        None,
    )
    .await
    .unwrap();

    // Reads must surface UserEdit override over base rescanned tag
    let detail = LibraryRepository::get_album_detail(&pool, &album.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(detail.album.title, "Kind of Blue (My Favorite)");
    assert_eq!(detail.versions[0].tracks[0].title, "So What (User Master)");

    let loaded_track = LibraryRepository::find_track_source_by_id(&pool, &saved_track.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(loaded_track.title, "So What (User Master)");

    // Clearing UserEdit restores underlying rescanned FileTag value
    assert!(
        IngestionRepository::clear_metadata_override(&pool, "track", &saved_track.id, "title")
            .await
            .unwrap()
    );
    let restored = LibraryRepository::find_track_source_by_id(&pool, &saved_track.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(restored.title, "So What (Rescanned Tag)");
}

#[tokio::test]
async fn test_move_rename_relink_preserves_history_favorites_and_overrides() {
    let pool = open_test_database().await.unwrap();

    let profile = Profile::default_profile();
    ProfileRepository::create_profile(&pool, &profile)
        .await
        .unwrap();

    let album = CanonicalAlbum::new("A Love Supreme", "John Coltrane").unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, None)
        .await
        .unwrap();
    let v1 = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "dir::old",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let v2 = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "dir::new",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_album_version(&pool, &v1)
        .await
        .unwrap();
    LibraryRepository::insert_album_version(&pool, &v2)
        .await
        .unwrap();

    let track = TrackSource::new(
        &v1.id,
        ProviderKind::Local,
        "D:/Music/OldFolder/01_ack.flac",
        "Acknowledgement",
        1,
        1,
        462_000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let saved = LibraryRepository::insert_track_source(&pool, &track)
        .await
        .unwrap();

    // Attach fingerprint, play history, favorite, artwork override, and metadata override
    assert!(
        IngestionRepository::update_track_fingerprint(
            &pool,
            &saved.id,
            "fp_deadbeef_01",
            48_123_456
        )
        .await
        .unwrap()
    );
    LibraryRepository::record_play(&pool, &profile.id, &saved.id, 462_000)
        .await
        .unwrap();
    LibraryRepository::add_favorite(&pool, &profile.id, "track", &saved.id)
        .await
        .unwrap();
    IngestionRepository::set_metadata_override(
        &pool,
        "track",
        &saved.id,
        "title",
        "\"Part I: Acknowledgement\"",
        MetadataLayer::UserEdit,
    )
    .await
    .unwrap();

    // Old path disappears from root -> soft-marked missing (NOT deleted)
    let seen: HashSet<String> = HashSet::new();
    let marked = IngestionRepository::mark_missing_local_tracks_under_root(
        &pool,
        "local",
        "D:/Music/OldFolder",
        &seen,
    )
    .await
    .unwrap();
    assert_eq!(marked, 1);

    // File appears at renamed path with identical fingerprint -> relink candidate found
    let cand = IngestionRepository::find_relink_candidate_by_fingerprint(
        &pool,
        "local",
        "fp_deadbeef_01",
        48_123_456,
        "D:/Music/NewFolder/01 - Acknowledgement.flac",
    )
    .await
    .unwrap()
    .expect("must find missing track by content fingerprint");
    assert_eq!(cand.track_source_id, saved.id);
    assert_eq!(cand.file_status, FileStatus::Missing);

    // Relink in-place
    assert!(
        IngestionRepository::relink_moved_track_source(
            &pool,
            &cand.track_source_id,
            "D:/Music/NewFolder/01 - Acknowledgement.flac",
            &v2.id,
            Some(1_700_002_000),
            Some(48_200_000),
        )
        .await
        .unwrap()
    );

    // Verify identity, path, history, favorites, and user overrides all survived intact
    let relinked = LibraryRepository::find_track_source_by_id(&pool, &saved.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(relinked.id, saved.id);
    assert_eq!(
        relinked.external_track_id,
        "D:/Music/NewFolder/01 - Acknowledgement.flac"
    );
    assert_eq!(relinked.version_id, v2.id);
    assert_eq!(relinked.title, "Part I: Acknowledgement");

    let hist = LibraryRepository::get_recent_history(&pool, &profile.id, 10)
        .await
        .unwrap();
    assert_eq!(hist.len(), 1);
    assert_eq!(hist[0].track_source_id, saved.id);
    assert!(
        LibraryRepository::is_favorite(&pool, &profile.id, "track", &saved.id)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn test_canonical_tracks_multi_source_toc_and_playlists() {
    let pool = open_test_database().await.unwrap();

    let album = CanonicalAlbum::new("Random Access Memories", "Daft Punk").unwrap();
    LibraryRepository::insert_canonical_album(&pool, &album, None)
        .await
        .unwrap();

    let hi_res = AudioFormat::pcm(AudioCodec::Flac, 88_200, 24, 2).unwrap();
    let v_local =
        AlbumVersion::new(&album.id, ProviderKind::Local, "loc::ram", hi_res.clone()).unwrap();
    let v_qobuz = AlbumVersion::new(
        &album.id,
        ProviderKind::Qobuz,
        "qobuz::ram",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    LibraryRepository::insert_album_version(&pool, &v_local)
        .await
        .unwrap();
    LibraryRepository::insert_album_version(&pool, &v_qobuz)
        .await
        .unwrap();

    // Update TOC signature on both versions and verify lookup
    let toc = TocSignature::from_durations(1, vec![274_000, 321_000, 544_000]);
    assert!(
        IngestionRepository::update_album_version_toc(&pool, &v_local.id, &toc.digest, 1, 3)
            .await
            .unwrap()
    );
    assert!(
        IngestionRepository::update_album_version_toc(&pool, &v_qobuz.id, &toc.digest, 1, 3)
            .await
            .unwrap()
    );
    let toc_matches = IngestionRepository::find_versions_by_toc(&pool, &toc.digest)
        .await
        .unwrap();
    assert_eq!(toc_matches.len(), 2);

    // Two sources (Local Hi-Res + Qobuz CD) sharing same ISRC collapse to one CanonicalTrack
    let t_local = TrackSource::new(
        &v_local.id,
        ProviderKind::Local,
        "D:/Music/RAM/08_get_lucky.flac",
        "Get Lucky",
        1,
        8,
        369_000,
        hi_res,
    )
    .unwrap()
    .with_isrc("USQX91300108")
    .unwrap();
    let t_qobuz = TrackSource::new(
        &v_qobuz.id,
        ProviderKind::Qobuz,
        "qobuz-track-88",
        "Get Lucky",
        1,
        8,
        369_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_isrc("USQX91300108")
    .unwrap();
    let s_local = LibraryRepository::insert_track_source(&pool, &t_local)
        .await
        .unwrap();
    let s_qobuz = LibraryRepository::insert_track_source(&pool, &t_qobuz)
        .await
        .unwrap();

    let artists = vec![
        "Daft Punk".to_string(),
        "Pharrell Williams".to_string(),
        "Nile Rodgers".to_string(),
    ];
    let ct1 = IngestionRepository::upsert_canonical_track_for_source(
        &pool,
        &s_local.id,
        &album.id,
        &s_local,
        &artists,
    )
    .await
    .unwrap();
    let ct2 = IngestionRepository::upsert_canonical_track_for_source(
        &pool,
        &s_qobuz.id,
        &album.id,
        &s_qobuz,
        &artists,
    )
    .await
    .unwrap();

    assert_eq!(ct1.id, ct2.id);
    assert_eq!(ct2.artist_names, artists);
    assert_eq!(ct2.sources.len(), 2);
    // Ordered highest sample_rate_hz first
    assert_eq!(ct2.sources[0].provider, ProviderKind::Local);
    assert_eq!(ct2.sources[0].sample_rate_hz, 88_200);
    assert_eq!(ct2.sources[1].provider, ProviderKind::Qobuz);

    // Sidecar .m3u playlist persistence
    let pl = IngestionRepository::upsert_sidecar_playlist(
        &pool,
        "local",
        "D:/Music/RAM/favorites.m3u8",
        "RAM Favorites",
        &[
            SidecarPlaylistEntry {
                raw_entry: "08_get_lucky.flac".to_string(),
                resolved_track_source_id: Some(s_local.id.clone()),
            },
            SidecarPlaylistEntry {
                raw_entry: "99_missing.flac".to_string(),
                resolved_track_source_id: None,
            },
        ],
    )
    .await
    .unwrap();
    assert_eq!(pl.track_count, 2);
    let playlists = IngestionRepository::list_sidecar_playlists(&pool)
        .await
        .unwrap();
    assert_eq!(playlists.len(), 1);
    assert_eq!(playlists[0].name, "RAM Favorites");
}

#[tokio::test]
async fn test_mark_missing_noop_skip_chunked_updates_and_tx_batch_helpers() {
    let pool = open_test_database().await.unwrap();

    // 1. Single-transaction batch persistence using all *_tx and *_conn helpers
    let mut tx = ImmediateTx::begin(&pool).await.unwrap();
    let artist = LibraryRepository::upsert_artist_by_mbid_or_name_tx(
        tx.conn(),
        "Batch Artist",
        None,
        Some("Batch bio"),
        None,
    )
    .await
    .unwrap();

    let album = CanonicalAlbum::new("Box Set 260", "Batch Artist").unwrap();
    LibraryRepository::insert_canonical_album_tx(tx.conn(), &album, Some(&artist.id))
        .await
        .unwrap();

    let ver = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "D:/Music/BoxSet::v1",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let ver_id_first = LibraryRepository::insert_album_version_tx(tx.conn(), &ver)
        .await
        .unwrap();
    assert_eq!(ver_id_first, ver.id);

    // Re-inserting with a new random UUID on same (provider_id, external_album_id) returns authoritative ID
    let ver_conflict = AlbumVersion::new(
        &album.id,
        ProviderKind::Local,
        "D:/Music/BoxSet::v1",
        AudioFormat::pcm(AudioCodec::Flac, 96_000, 24, 2).unwrap(),
    )
    .unwrap();
    let ver_id_resolved = LibraryRepository::insert_album_version_tx(tx.conn(), &ver_conflict)
        .await
        .unwrap();
    assert_eq!(ver_id_resolved, ver_id_first);

    let mut all_paths = HashSet::with_capacity(260);
    let mut first_track_id = String::new();
    let mut first_ct_id = String::new();
    for i in 1..=260u16 {
        let ext_path = format!("D:/Music/BoxSet/{i:03}.flac");
        all_paths.insert(ext_path.clone());
        let mut trk = TrackSource::new(
            &ver_id_resolved,
            ProviderKind::Local,
            &ext_path,
            format!("Track {i}"),
            1,
            i,
            180_000,
            AudioFormat::cd_quality(),
        )
        .unwrap()
        .with_artist_name("Batch Artist");
        if i == 1 {
            trk = trk.with_isrc("USBTX2600001").unwrap();
        }
        let persisted_id = LibraryRepository::upsert_track_source_with_cache_tx(
            tx.conn(),
            &trk,
            None,
            Some(1_700_000_000),
            Some(10_000),
            Some("meta-hash"),
            Some(&format!("fp-{i:03}")),
            Some(9_500),
        )
        .await
        .unwrap();

        let (ct_id, created) = IngestionRepository::upsert_canonical_track_for_source_tx(
            tx.conn(),
            &persisted_id,
            &album.id,
            &trk,
            &["Batch Artist".to_string()],
        )
        .await
        .unwrap();
        assert!(created);

        if i == 1 {
            first_track_id = persisted_id.clone();
            first_ct_id = ct_id;
            sync_track_fts_conn(
                tx.conn(),
                &persisted_id,
                &trk.title,
                Some(&artist.name),
                Some(&album.title),
            )
            .await
            .unwrap();
        }
    }

    // Second source sharing ISRC with Track 1 reuses canonical_track (created == false)
    let ver_qobuz = AlbumVersion::new(
        &album.id,
        ProviderKind::Qobuz,
        "qob-box-1",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let ver_qobuz_id = LibraryRepository::insert_album_version_tx(tx.conn(), &ver_qobuz)
        .await
        .unwrap();
    let trk_qobuz = TrackSource::new(
        &ver_qobuz_id,
        ProviderKind::Qobuz,
        "qob-trk-1",
        "Track 1",
        1,
        1,
        180_000,
        AudioFormat::cd_quality(),
    )
    .unwrap()
    .with_isrc("USBTX2600001")
    .unwrap();
    let trk_qobuz_id = LibraryRepository::upsert_track_source_with_cache_tx(
        tx.conn(),
        &trk_qobuz,
        None,
        None,
        None,
        None,
        None,
        None,
    )
    .await
    .unwrap();
    let (reused_ct_id, created_second) = IngestionRepository::upsert_canonical_track_for_source_tx(
        tx.conn(),
        &trk_qobuz_id,
        &album.id,
        &trk_qobuz,
        &["Batch Artist".to_string()],
    )
    .await
    .unwrap();
    assert!(!created_second);
    assert_eq!(reused_ct_id, first_ct_id);

    assert!(
        IngestionRepository::update_album_version_toc_tx(
            tx.conn(),
            &ver_id_resolved,
            "toc1:d1:n260:abc",
            1,
            260,
        )
        .await
        .unwrap()
    );

    IngestionRepository::record_skipped_file_tx(
        tx.conn(),
        "local",
        "D:/Music/BoxSet/bad.flac",
        SkipReason::CorruptHeader,
        "Corrupt",
        Some(12),
        Some(100),
    )
    .await
    .unwrap();

    sync_artist_fts_conn(
        tx.conn(),
        &artist.id,
        &artist.name,
        artist.biography.as_deref(),
    )
    .await
    .unwrap();
    sync_album_fts_conn(tx.conn(), &album.id, &album.title, Some(&artist.name), None)
        .await
        .unwrap();

    tx.commit().await.unwrap();

    // Verify active skipped paths and clear_skipped_for_path_tx
    let active_skipped = IngestionRepository::list_active_skipped_paths(&pool)
        .await
        .unwrap();
    assert!(active_skipped.contains("D:/Music/BoxSet/bad.flac"));
    {
        let mut tx_clear = ImmediateTx::begin(&pool).await.unwrap();
        assert!(
            IngestionRepository::clear_skipped_for_path_tx(
                tx_clear.conn(),
                "local",
                "D:/Music/BoxSet/bad.flac",
            )
            .await
            .unwrap()
        );
        tx_clear.commit().await.unwrap();
    }
    assert!(
        IngestionRepository::list_active_skipped_paths(&pool)
            .await
            .unwrap()
            .is_empty()
    );

    // Verify FTS conn sync worked
    assert!(
        !search_library(&pool, "Box Set 260")
            .await
            .unwrap()
            .is_empty()
    );

    // 2. mark_missing_local_tracks_under_root: no-op skip when all 260 are seen & present
    let noop = IngestionRepository::mark_missing_local_tracks_under_root(
        &pool,
        "local",
        "D:/Music/BoxSet",
        &all_paths,
    )
    .await
    .unwrap();
    assert_eq!(noop, 0);

    // 3. Chunked mark missing (260 rows -> 250 + 10 chunks)
    let marked = IngestionRepository::mark_missing_local_tracks_under_root(
        &pool,
        "local",
        "D:/Music/BoxSet",
        &HashSet::new(),
    )
    .await
    .unwrap();
    assert_eq!(marked, 260);
    assert!(
        LibraryRepository::find_track_sources_by_version(&pool, &ver_id_resolved)
            .await
            .unwrap()
            .is_empty()
    );

    // 4. Chunked restore (260 rows -> 250 + 10 chunks)
    let restored_call = IngestionRepository::mark_missing_local_tracks_under_root(
        &pool,
        "local",
        "D:/Music/BoxSet",
        &all_paths,
    )
    .await
    .unwrap();
    assert_eq!(restored_call, 0);
    assert_eq!(
        LibraryRepository::find_track_sources_by_version(&pool, &ver_id_resolved)
            .await
            .unwrap()
            .len(),
        260
    );

    // 5. find_relink_candidate_by_fingerprint offloads Path::exists via spawn_blocking for present tracks
    let cand = IngestionRepository::find_relink_candidate_by_fingerprint(
        &pool,
        "local",
        "fp-001",
        9_500,
        "D:/Music/BoxSet/moved_001.flac",
    )
    .await
    .unwrap()
    .expect("non-existent local path should qualify as relink candidate");
    assert_eq!(cand.track_source_id, first_track_id);

    let mut tx_relink = ImmediateTx::begin(&pool).await.unwrap();
    assert!(
        IngestionRepository::relink_moved_track_source_tx(
            tx_relink.conn(),
            &first_track_id,
            "D:/Music/BoxSet/moved_001.flac",
            &ver_id_resolved,
            Some(1_700_009_999),
            Some(10_200),
        )
        .await
        .unwrap()
    );
    tx_relink.commit().await.unwrap();
}
