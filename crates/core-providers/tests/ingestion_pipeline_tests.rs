use std::fs;
use std::io::Write;
use std::path::Path;
use std::time::Duration;

use core_db::{
    open_test_database, IngestionRepository, LibraryRepository, ProfileRepository,
};
use core_providers::{
    compute_content_fingerprint, extract_disc_number_from_dir_name, should_ignore_name,
    split_artists, IngestionConfig, IngestionPipeline, LyricsFormat, LyricsManager, LyricsSource,
    LyricsTarget, MetadataExtractor, StorageWatcherManager,
};
use core_types::{
    AudioCodec, ExternalAlbumIngest, ExternalCatalogIngestBatch, ExternalTrackIngest, MetadataLayer,
    Profile, ProviderKind, ScanLifecycleState, SkipReason, WatchMode,
};
use tempfile::tempdir;

/// Writes a minimal valid FLAC file with STREAMINFO + VORBIS_COMMENT + raw audio frame payload.
fn write_synthetic_flac(path: &Path, comments: &[(&str, &str)], audio_payload: &[u8]) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let mut f = fs::File::create(path).unwrap();
    f.write_all(b"fLaC").unwrap();

    // STREAMINFO block (type 0, 34 bytes, NOT last)
    f.write_all(&[0x00, 0x00, 0x00, 34]).unwrap();
    let mut si = [0u8; 34];
    // 44100 Hz (20 bits), 2 ch (3 bits -> 1), 16-bit (5 bits -> 15), 441000 samples (10.0s)
    let sr: u32 = 44100;
    let ch_minus_1: u32 = 1;
    let bps_minus_1: u32 = 15;
    let total_samples: u64 = 441_000;
    si[10] = (sr >> 12) as u8;
    si[11] = ((sr >> 4) & 0xFF) as u8;
    si[12] = (((sr & 0x0F) << 4) as u8) | ((ch_minus_1 as u8) << 1) | (((bps_minus_1 >> 4) & 1) as u8);
    si[13] = (((bps_minus_1 & 0x0F) << 4) as u8) | (((total_samples >> 32) & 0x0F) as u8);
    si[14] = ((total_samples >> 24) & 0xFF) as u8;
    si[15] = ((total_samples >> 16) & 0xFF) as u8;
    si[16] = ((total_samples >> 8) & 0xFF) as u8;
    si[17] = (total_samples & 0xFF) as u8;
    f.write_all(&si).unwrap();

    // VORBIS_COMMENT block (type 4, LAST = 0x84)
    let mut vc = Vec::new();
    let vendor = b"LuminaTest";
    vc.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    vc.extend_from_slice(vendor);
    vc.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for (k, v) in comments {
        let entry = format!("{k}={v}");
        vc.extend_from_slice(&(entry.len() as u32).to_le_bytes());
        vc.extend_from_slice(entry.as_bytes());
    }
    let vc_len = vc.len();
    f.write_all(&[
        0x84,
        ((vc_len >> 16) & 0xFF) as u8,
        ((vc_len >> 8) & 0xFF) as u8,
        (vc_len & 0xFF) as u8,
    ])
    .unwrap();
    f.write_all(&vc).unwrap();
    f.write_all(audio_payload).unwrap();
    f.flush().unwrap();
}

#[tokio::test]
async fn test_ignore_rules_quarantine_and_corrupt_file_resilience() {
    let dir = tempdir().unwrap();
    let pool = open_test_database().await.unwrap();

    // Ignored system dirs & files
    assert!(should_ignore_name("@eaDir"));
    assert!(should_ignore_name("$Recycle.Bin"));
    assert!(should_ignore_name(".Trashes"));
    assert!(should_ignore_name(".DS_Store"));
    assert!(should_ignore_name("Thumbs.db"));

    write_synthetic_flac(
        &dir.path().join("@eaDir/ignored.flac"),
        &[("TITLE", "Ignored")],
        &[1u8; 256],
    );
    write_synthetic_flac(
        &dir.path().join("$Recycle.Bin/deleted.flac"),
        &[("TITLE", "Deleted")],
        &[2u8; 256],
    );
    write_synthetic_flac(
        &dir.path().join(".Trashes/trashed.flac"),
        &[("TITLE", "Trashed")],
        &[3u8; 256],
    );

    // Valid track
    write_synthetic_flac(
        &dir.path().join("ArtistA/AlbumA/01 - Valid Track.flac"),
        &[
            ("TITLE", "Valid Track"),
            ("ARTIST", "Artist A"),
            ("ALBUM", "Album A"),
            ("TRACKNUMBER", "1"),
        ],
        &[7u8; 512],
    );

    // Corrupt audio file & unsplit CUE + ISO + unsupported .ape
    fs::write(
        dir.path().join("ArtistA/AlbumA/02 - Corrupt.flac"),
        b"NOT_A_VALID_FLAC_HEADER_AT_ALL",
    )
    .unwrap();
    fs::write(
        dir.path().join("ArtistA/AlbumA/album.cue"),
        b"FILE \"cd.flac\" WAVE\nTRACK 01 AUDIO",
    )
    .unwrap();
    fs::write(dir.path().join("ArtistA/AlbumA/sacd.iso"), b"SACD_ISO").unwrap();
    fs::write(dir.path().join("ArtistA/AlbumA/old.ape"), b"MAC ").unwrap();

    let pipeline = IngestionPipeline::with_defaults(pool.clone());
    let mut rx = pipeline.subscribe_progress();
    let summary = pipeline.scan_root(dir.path(), "local").await.unwrap();

    assert_eq!(summary.state, ScanLifecycleState::Completed);
    assert_eq!(summary.added, 1);
    assert!(summary.skipped >= 4); // corrupt flac + cue + iso + ape

    // Verify progress stream emitted lifecycle states
    let mut states = Vec::new();
    while let Ok(ev) = rx.try_recv() {
        states.push(ev.state);
    }
    assert!(states.contains(&ScanLifecycleState::Discovering));
    assert!(states.contains(&ScanLifecycleState::Completed));

    // Verify valid album imported & ignored folders skipped completely
    let albums = LibraryRepository::list_canonical_albums(&pool, 50, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].title, "Album A");

    // Verify quarantine records
    let skipped = IngestionRepository::list_skipped_files(&pool, false)
        .await
        .unwrap();
    assert!(skipped.iter().any(|s| s.reason == SkipReason::UnsplitCueOrIso && s.file_path.ends_with(".cue")));
    assert!(skipped.iter().any(|s| s.reason == SkipReason::UnsplitCueOrIso && s.file_path.ends_with(".iso")));
    assert!(skipped.iter().any(|s| s.reason == SkipReason::UnsupportedFormat && s.file_path.ends_with(".ape")));
    assert!(skipped.iter().any(|s| s.reason == SkipReason::CorruptHeader && s.file_path.ends_with("02 - corrupt.flac")));
}

#[tokio::test]
async fn test_content_fingerprint_flac_tag_edit_and_move_rename_relink() {
    let dir = tempdir().unwrap();
    let pool = open_test_database().await.unwrap();
    let profile = Profile::default_profile();
    ProfileRepository::create_profile(&pool, &profile)
        .await
        .unwrap();

    let payload: Vec<u8> = (0..4096).map(|i| (i % 251) as u8).collect();
    let old_path = dir.path().join("OldDir/01 - Original.flac");
    write_synthetic_flac(
        &old_path,
        &[
            ("TITLE", "Blue in Green"),
            ("ARTIST", "Miles Davis"),
            ("ALBUM", "Kind of Blue"),
            ("TRACKNUMBER", "1"),
        ],
        &payload,
    );

    let fp_before = compute_content_fingerprint(&old_path).unwrap();

    let pipeline = IngestionPipeline::with_defaults(pool.clone());
    let s1 = pipeline.scan_root(dir.path(), "local").await.unwrap();
    assert_eq!(s1.added, 1);

    let albums = LibraryRepository::list_canonical_albums(&pool, 10, 0)
        .await
        .unwrap();
    let detail = LibraryRepository::get_album_detail(&pool, &albums[0].id)
        .await
        .unwrap()
        .unwrap();
    let orig_track_id = detail.versions[0].tracks[0].id.clone();

    // Attach play history, favorite, and UserEdit metadata override
    LibraryRepository::record_play(&pool, &profile.id, &orig_track_id, 330_000)
        .await
        .unwrap();
    LibraryRepository::add_favorite(&pool, &profile.id, "track", &orig_track_id)
        .await
        .unwrap();
    IngestionRepository::set_metadata_override(
        &pool,
        "track",
        &orig_track_id,
        "title",
        "\"Blue in Green (My Custom Title)\"",
        MetadataLayer::UserEdit,
    )
    .await
    .unwrap();

    // Remove old file and write moved/renamed file with EDITED FLAC tags but IDENTICAL audio payload
    fs::remove_file(&old_path).unwrap();
    let new_path = dir.path().join("RenamedDir/01_Blue_In_Green_Remaster.flac");
    write_synthetic_flac(
        &new_path,
        &[
            ("TITLE", "Blue in Green (Tag Edited)"),
            ("ARTIST", "Miles Davis"),
            ("ALBUM", "Kind of Blue"),
            ("COMMENT", "Added extra comment tag bytes!"),
            ("TRACKNUMBER", "1"),
        ],
        &payload,
    );

    let fp_after = compute_content_fingerprint(&new_path).unwrap();
    assert_eq!(
        fp_before, fp_after,
        "FLAC tag edits must NOT change content fingerprint"
    );

    // Rescan root -> must auto-relink in-place preserving track ID, history, favorites, and UserEdit!
    let s2 = pipeline.scan_root(dir.path(), "local").await.unwrap();
    assert_eq!(s2.added, 0);
    assert_eq!(s2.updated, 1);

    let relinked = LibraryRepository::find_track_source_by_id(&pool, &orig_track_id)
        .await
        .unwrap()
        .expect("Original track_sources.id must survive move/rename + tag edit");
    assert!(relinked.external_track_id.ends_with("01_blue_in_green_remaster.flac"));
    assert_eq!(relinked.title, "Blue in Green (My Custom Title)");

    let history = LibraryRepository::get_recent_history(&pool, &profile.id, 10)
        .await
        .unwrap();
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].track_source_id, orig_track_id);
    assert!(
        LibraryRepository::is_favorite(&pool, &profile.id, "track", &orig_track_id)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn test_offline_root_guard_never_prunes_tracks() {
    let dir = tempdir().unwrap();
    let pool = open_test_database().await.unwrap();
    let root = dir.path().join("RemovableDrive");
    write_synthetic_flac(
        &root.join("Artist/Album/01.flac"),
        &[("TITLE", "Safe Track"), ("ARTIST", "Safe Artist"), ("ALBUM", "Safe Album")],
        &[9u8; 512],
    );

    let pipeline = IngestionPipeline::with_defaults(pool.clone());
    pipeline.scan_root(&root, "local").await.unwrap();

    // Simulate drive disconnect
    fs::remove_dir_all(&root).unwrap();
    let err = pipeline.scan_root(&root, "local").await.unwrap_err();
    assert!(err.to_string().contains("offline"));

    // All tracks remain intact (not deleted/pruned)
    let albums = LibraryRepository::list_canonical_albums(&pool, 10, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
}

#[tokio::test]
async fn test_multi_disc_collapse_disco_negative_toc_ttml_m3u_and_multi_artist() {
    let dir = tempdir().unwrap();
    let pool = open_test_database().await.unwrap();

    // Disc folder pattern unit checks (must NOT false-match "Disco Classics")
    assert_eq!(extract_disc_number_from_dir_name("CD1"), Some(1));
    assert_eq!(extract_disc_number_from_dir_name("Disc 2"), Some(2));
    assert_eq!(extract_disc_number_from_dir_name("Disk 03"), Some(3));
    assert_eq!(extract_disc_number_from_dir_name("Disco Classics"), None);
    assert_eq!(extract_disc_number_from_dir_name("CD-ROM"), None);

    // Multi-artist splitting check
    assert_eq!(
        split_artists("Daft Punk feat. Pharrell Williams; Nile Rodgers"),
        vec!["Daft Punk", "Pharrell Williams", "Nile Rodgers"]
    );

    // Multi-disc album without DISCNUMBER tags (inferred from CD1/CD2 subfolders)
    let d1_track = dir.path().join("Pink Floyd/The Wall/CD1/01 - In the Flesh.flac");
    let d2_track = dir.path().join("Pink Floyd/The Wall/CD2/01 - Hey You.flac");
    write_synthetic_flac(
        &d1_track,
        &[
            ("TITLE", "In the Flesh?"),
            ("ARTIST", "Pink Floyd"),
            ("ARTIST", "Roger Waters"),
            ("ALBUM", "The Wall"),
            ("TRACKNUMBER", "1"),
        ],
        &[11u8; 512],
    );
    write_synthetic_flac(
        &d2_track,
        &[
            ("TITLE", "Hey You"),
            ("ARTIST", "Pink Floyd feat. David Gilmour"),
            ("ALBUM", "The Wall"),
            ("TRACKNUMBER", "1"),
        ],
        &[22u8; 512],
    );

    // "Disco Classics" album folder must NOT be stripped as a disc folder
    let disco_track = dir.path().join("Bee Gees/Disco Classics/01 - Stayin Alive.flac");
    write_synthetic_flac(&disco_track, &[], &[33u8; 512]);

    // Sibling .ttml lyrics sidecar
    let ttml_path = d1_track.with_extension("ttml");
    fs::write(
        &ttml_path,
        r#"<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml">
  <body><div>
    <p begin="00:00:01.500" end="00:00:04.000"><span begin="1.5s" end="2.5s">So ya</span><span begin="2500ms" end="4000ms">thought ya</span></p>
    <p begin="00:05.000" end="00:08.000">Might like to go to the show</p>
  </div></body>
</tt>"#,
    )
    .unwrap();

    // Sibling .m3u8 playlist
    fs::write(
        dir.path().join("Pink Floyd/The Wall/wall_picks.m3u8"),
        "#EXTM3U\n#PLAYLIST:Wall Essentials\nCD1/01 - In the Flesh.flac\nCD2/01 - Hey You.flac\n",
    )
    .unwrap();

    let pipeline = IngestionPipeline::with_defaults(pool.clone());
    pipeline.scan_root(dir.path(), "local").await.unwrap();

    let albums = LibraryRepository::list_canonical_albums(&pool, 20, 0)
        .await
        .unwrap();
    let wall = albums.iter().find(|a| a.title == "The Wall").expect("The Wall album");
    assert_eq!(wall.versions.len(), 1, "CD1 & CD2 must collapse into ONE AlbumVersion");

    let wall_detail = LibraryRepository::get_album_detail(&pool, &wall.id)
        .await
        .unwrap()
        .unwrap();
    let wall_tracks = &wall_detail.versions[0].tracks;
    assert_eq!(wall_tracks.len(), 2);
    assert_eq!(wall_tracks[0].disc_number, 1);
    assert_eq!(wall_tracks[1].disc_number, 2);

    // Verify TOC persisted on album_versions
    let toc_row: (Option<String>, i64, Option<i64>) = sqlx::query_as(
        "SELECT toc_signature, disc_count, track_count FROM album_versions WHERE id = ?",
    )
    .bind(&wall.versions[0].id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(toc_row.0.as_deref().unwrap_or("").starts_with("toc1:d2:n2:"));
    assert_eq!(toc_row.1, 2);
    assert_eq!(toc_row.2, Some(2));

    // Verify multi-artist Vorbis comments persisted on canonical_track
    let ct_id: (Option<String>,) =
        sqlx::query_as("SELECT canonical_track_id FROM track_sources WHERE id = ?")
            .bind(&wall_tracks[0].id)
            .fetch_one(&pool)
            .await
            .unwrap();
    let ct = IngestionRepository::get_canonical_track_with_sources(&pool, &ct_id.0.unwrap())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(ct.artist_names, vec!["Pink Floyd", "Roger Waters"]);

    // Verify "Disco Classics" preserved its album name from directory
    let disco_meta = MetadataExtractor::extract(&disco_track).unwrap();
    assert_eq!(disco_meta.album, "Disco Classics");
    assert_eq!(disco_meta.artist, "Bee Gees");
    assert_eq!(disco_meta.disc_number, 1);

    // Verify .ttml sidecar parsed with word timing
    let lyrics = LyricsManager::get_lyrics(
        &LyricsTarget {
            track_id: None,
            file_path: Some(d1_track.to_string_lossy().to_string()),
        },
        None,
    )
    .await;
    assert!(lyrics.found);
    assert_eq!(lyrics.format, LyricsFormat::Ttml);
    assert_eq!(lyrics.source, LyricsSource::SidecarTtml);
    assert_eq!(lyrics.lines.len(), 2);
    assert_eq!(lyrics.lines[0].start_ms, Some(1500));
    assert_eq!(lyrics.lines[0].words.len(), 2);
    assert_eq!(lyrics.lines[1].start_ms, Some(5000));

    // Verify .m3u8 playlist persisted
    let playlists = IngestionRepository::list_sidecar_playlists(&pool)
        .await
        .unwrap();
    assert_eq!(playlists.len(), 1);
    assert_eq!(playlists[0].name, "Wall Essentials");
    assert_eq!(playlists[0].track_count, 2);
}

#[tokio::test]
async fn test_watcher_debounce_and_nas_polling_and_external_catalog_ingest() {
    let dir = tempdir().unwrap();
    let pool = open_test_database().await.unwrap();
    let pipeline = IngestionPipeline::new(pool.clone(), IngestionConfig::default());
    let watcher = StorageWatcherManager::new(pipeline.clone(), 120);

    // Track 2: NAS polling mode on local temp dir
    let root = watcher
        .add_root("local", dir.path(), WatchMode::NasPolling, 60)
        .await
        .unwrap();
    assert_eq!(root.watch_mode, WatchMode::NasPolling);
    assert_eq!(watcher.list_roots().await.unwrap().len(), 1);

    write_synthetic_flac(
        &dir.path().join("Daft Punk/Discovery/01 - One More Time.flac"),
        &[
            ("TITLE", "One More Time"),
            ("ARTIST", "Daft Punk"),
            ("ALBUM", "Discovery"),
            ("ISRC", "GBDUW0000059"),
            ("TRACKNUMBER", "1"),
        ],
        &[44u8; 512],
    );

    let scan_ev = watcher.trigger_scan(&root.id).await.unwrap();
    assert_eq!(scan_ev.added, 1);

    // External streaming catalog ingest (metadata-only, zero stream URLs) merges with local Discovery album!
    let batch = ExternalCatalogIngestBatch {
        provider: ProviderKind::Qobuz,
        albums: vec![ExternalAlbumIngest {
            external_album_id: "qobuz-discovery-01".to_string(),
            title: "Discovery".to_string(),
            artist_name: "Daft Punk".to_string(),
            album_artist: Some("Daft Punk".to_string()),
            release_year: Some(2001),
            upc: Some("724384960629".to_string()),
            cover_url: Some("https://cdn.example/discovery.jpg".to_string()),
            edition_label: Some("Hi-Res 24/96".to_string()),
            disc_count: 1,
            tracks: vec![ExternalTrackIngest {
                external_track_id: "qobuz-trk-1".to_string(),
                title: "One More Time".to_string(),
                artist_name: Some("Daft Punk".to_string()),
                album_artist: Some("Daft Punk".to_string()),
                disc_number: 1,
                track_number: 1,
                duration_ms: 320_000,
                isrc: Some("GBDUW0000059".to_string()),
                genre: Some("Electronic".to_string()),
                composer: None,
                codec: Some(AudioCodec::Flac),
                sample_rate_hz: Some(96_000),
                bit_depth: Some(24),
                bitrate_kbps: None,
            }],
        }],
    };
    let rep = IngestionPipeline::ingest_external_catalog(&pool, &batch)
        .await
        .unwrap();
    assert_eq!(rep.albums_matched, 1);
    assert_eq!(rep.versions_upserted, 1);

    // Single canonical album now holds BOTH Local and Qobuz versions!
    let albums = LibraryRepository::list_canonical_albums(&pool, 10, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].versions.len(), 2);

    // Track 1: Native watcher debounce coalescing test
    let native_dir = tempdir().unwrap();
    let _native_root = watcher
        .add_root("local", native_dir.path(), WatchMode::NativeOs, 300)
        .await
        .unwrap();
    write_synthetic_flac(
        &native_dir.path().join("Live/Album/01 - Watched.flac"),
        &[("TITLE", "Watched Track"), ("ARTIST", "Watcher Artist"), ("ALBUM", "Watched Album")],
        &[55u8; 512],
    );

    // Wait briefly for debounce window + ingest
    let mut found = false;
    for _ in 0..25 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let albs = LibraryRepository::list_canonical_albums(&pool, 20, 0)
            .await
            .unwrap();
        if albs.iter().any(|a| a.title == "Watched Album") {
            found = true;
            break;
        }
    }
    assert!(found, "Native OS watcher should debounce and ingest newly created FLAC");

    watcher.shutdown().await;
}
