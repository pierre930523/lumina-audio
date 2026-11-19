use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

use core_db::credential::MemoryCredentialStore;
use core_db::{open_test_database, search_library, LibraryRepository};
use core_types::{AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use core_providers::{
    clean_discogs_artist_name, extract_edition_label, parse_remote_share_uri, AlbumSyncMetadata,
    CreditEnrichmentService, DiscogsClient, DiscogsConfig, EnrichmentConfig, LibrarySyncService,
    LocalProviderConfig, MockSmbTransport, MusicBrainzClient, MusicBrainzConfig, ProviderManager,
    SmbConfig, SmbEntry, SyncResult,
};

struct CapturedEnrichReq {
    target: String,
    headers: HashMap<String, String>,
}

async fn spawn_enrichment_server<F>(handler: F) -> (String, tokio::task::JoinHandle<()>)
where
    F: Fn(CapturedEnrichReq) -> (u16, Vec<(String, String)>, String) + Send + Sync + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let handler = Arc::new(handler);

    let handle = tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let h = handler.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let header_end = loop {
                        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            break pos + 4;
                        }
                        let Ok(n) = socket.read(&mut chunk).await else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                    };
                    let header_str = String::from_utf8_lossy(&buf[..header_end]).to_string();
                    let mut lines = header_str.split("\r\n");
                    let req_line = lines.next().unwrap_or("");
                    let target = req_line.split_whitespace().nth(1).unwrap_or("/").to_string();
                    let mut headers = HashMap::new();
                    let mut content_length = 0usize;
                    for line in lines {
                        if let Some((k, v)) = line.split_once(':') {
                            let kl = k.trim().to_ascii_lowercase();
                            let vt = v.trim().to_string();
                            if kl == "content-length" {
                                content_length = vt.parse::<usize>().unwrap_or(0);
                            }
                            headers.insert(kl, vt);
                        }
                    }
                    while buf.len() < header_end + content_length {
                        let Ok(n) = socket.read(&mut chunk).await else {
                            return;
                        };
                        if n == 0 {
                            break;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                    }
                    let body_end = (header_end + content_length).min(buf.len());
                    buf.drain(..body_end);

                    let (status, resp_headers, body) = h(CapturedEnrichReq { target, headers });
                    let reason = match status {
                        200 => "OK",
                        429 => "Too Many Requests",
                        404 => "Not Found",
                        _ => "Status",
                    };
                    let mut raw = format!(
                        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: keep-alive\r\n",
                        body.len()
                    );
                    for (k, v) in resp_headers {
                        raw.push_str(&format!("{k}: {v}\r\n"));
                    }
                    raw.push_str("\r\n");
                    let mut payload = raw.into_bytes();
                    payload.extend_from_slice(body.as_bytes());
                    if socket.write_all(&payload).await.is_err() {
                        return;
                    }
                    let _ = socket.flush().await;
                }
            });
        }
    });

    (format!("http://127.0.0.1:{port}"), handle)
}

#[test]
fn test_edition_label_extraction_preserves_regular_titles() {
    assert_eq!(
        extract_edition_label("The Dark Side of the Moon"),
        ("The Dark Side of the Moon".to_string(), None)
    );
    assert_eq!(
        extract_edition_label("Kind of Blue (Deluxe Edition)"),
        ("Kind of Blue".to_string(), Some("Deluxe Edition".to_string()))
    );
    assert_eq!(
        extract_edition_label("Dark Side of the Moon (2011 Remaster) [24-Bit/96kHz]"),
        (
            "Dark Side of the Moon".to_string(),
            Some("2011 Remaster / 24-Bit/96kHz".to_string())
        )
    );
    assert_eq!(
        clean_discogs_artist_name("Alan Parsons (2)"),
        "Alan Parsons"
    );
}

#[tokio::test]
async fn test_f37_cross_source_dedup_across_all_providers_and_unknown_guard() {
    let pool = open_test_database().await.unwrap();

    let fmt_local = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();
    let fmt_hires = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let fmt_dsd = AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 2).unwrap();

    // 1. Local: base album with UPC + ISRC
    let mut alb_local = CanonicalAlbum::new("The Dark Side of the Moon", "Pink Floyd")
        .unwrap()
        .with_release_year(1973)
        .unwrap();
    let ver_local = AlbumVersion::new(&alb_local.id, ProviderKind::Local, "/music/dsotm", fmt_local.clone())
        .unwrap();
    let trk_local = TrackSource::new(
        &ver_local.id,
        ProviderKind::Local,
        "/music/dsotm/01.flac",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_local.clone(),
    )
    .unwrap()
    .with_isrc("GBAYE7300001")
    .unwrap();
    alb_local.add_version(ver_local);
    let mut meta_local = HashMap::new();
    meta_local.insert(
        alb_local.id.clone(),
        AlbumSyncMetadata {
            upc: Some("5099902987620".to_string()),
        },
    );
    LibrarySyncService::persist_sync_result_with_metadata(
        &pool,
        &SyncResult {
            albums: vec![alb_local],
            tracks: vec![trk_local],
            ..Default::default()
        },
        &meta_local,
    )
    .await
    .unwrap();

    // 2. SMB: punctuation/casing variation
    let mut alb_smb = CanonicalAlbum::new("the dark side of the moon!", "Pink Floyd").unwrap();
    let ver_smb = AlbumVersion::new(&alb_smb.id, ProviderKind::Smb, "nas/dsotm", fmt_dsd.clone()).unwrap();
    let trk_smb = TrackSource::new(
        &ver_smb.id,
        ProviderKind::Smb,
        "dsotm/01.dsf",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_dsd,
    )
    .unwrap();
    alb_smb.add_version(ver_smb);
    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![alb_smb],
            tracks: vec![trk_smb],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // 3. WebDAV: Edition suffix "(2011 Remaster)"
    let mut alb_dav =
        CanonicalAlbum::new("The Dark Side of the Moon (2011 Remaster)", "Pink Floyd").unwrap();
    let ver_dav =
        AlbumVersion::new(&alb_dav.id, ProviderKind::WebDav, "dav/dsotm", fmt_hires.clone())
            .unwrap()
            .with_edition_label("2011 Remaster");
    let trk_dav = TrackSource::new(
        &ver_dav.id,
        ProviderKind::WebDav,
        "dav/dsotm/01.flac",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_hires.clone(),
    )
    .unwrap();
    alb_dav.add_version(ver_dav);
    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![alb_dav],
            tracks: vec![trk_dav],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // 4. Qobuz: matches by UPC even with variant title
    let mut alb_qb = CanonicalAlbum::new("Dark Side (Immersion)", "Pink Floyd").unwrap();
    let ver_qb = AlbumVersion::new(&alb_qb.id, ProviderKind::Qobuz, "qb-dsotm", fmt_hires.clone()).unwrap();
    let trk_qb = TrackSource::new(
        &ver_qb.id,
        ProviderKind::Qobuz,
        "qb-trk-1",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_hires.clone(),
    )
    .unwrap();
    alb_qb.add_version(ver_qb);
    let mut meta_qb = HashMap::new();
    meta_qb.insert(
        alb_qb.id.clone(),
        AlbumSyncMetadata {
            upc: Some("5099902987620".to_string()),
        },
    );
    LibrarySyncService::persist_sync_result_with_metadata(
        &pool,
        &SyncResult {
            albums: vec![alb_qb],
            tracks: vec![trk_qb],
            ..Default::default()
        },
        &meta_qb,
    )
    .await
    .unwrap();

    // 5. Tidal: matches by overlapping track ISRC
    let mut alb_tid = CanonicalAlbum::new("DSOTM Live/Alt", "Pink Floyd").unwrap();
    let ver_tid = AlbumVersion::new(&alb_tid.id, ProviderKind::Tidal, "tid-dsotm", fmt_hires.clone()).unwrap();
    let trk_tid = TrackSource::new(
        &ver_tid.id,
        ProviderKind::Tidal,
        "tid-trk-1",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_hires,
    )
    .unwrap()
    .with_isrc("GBAYE7300001")
    .unwrap();
    alb_tid.add_version(ver_tid);
    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![alb_tid],
            tracks: vec![trk_tid],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // 6. Deezer: matches by MusicBrainz Release Group ID
    let mut alb_dz = CanonicalAlbum::new("DSOTM DZ", "Pink Floyd")
        .unwrap()
        .with_musicbrainz_id("f5093c06-23e3-404f-aeaa-40f72885ee3a");
    let ver_dz = AlbumVersion::new(&alb_dz.id, ProviderKind::Deezer, "dz-dsotm", fmt_local.clone()).unwrap();
    let trk_dz = TrackSource::new(
        &ver_dz.id,
        ProviderKind::Deezer,
        "dz-trk-1",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_local.clone(),
    )
    .unwrap()
    .with_isrc("GBAYE7300001")
    .unwrap();
    alb_dz.add_version(ver_dz);
    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![alb_dz],
            tracks: vec![trk_dz],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // Verify all 6 providers merged into 1 CanonicalAlbum with 6 AlbumVersions!
    let albums = LibrarySyncService::list_canonical_albums(&pool, 50, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].versions.len(), 6);

    let detail = LibrarySyncService::get_album_detail(&pool, &albums[0].id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(detail.versions.len(), 6);

    // FTS5 search
    let fts_hits = search_library(&pool, "Dark Side").await.unwrap();
    assert!(!fts_hits.is_empty());

    // Idempotent re-scan of Local preserves existing artist bio/mbid & updates ReplayGain without FK error
    let enriched_artist = LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "Pink Floyd",
        Some("83d91898-7763-47d7-b03b-b92132375c47"),
        Some("English rock band"),
        None,
    )
    .await
    .unwrap();
    assert!(enriched_artist.biography.is_some());

    let mut alb_rescan = CanonicalAlbum::new("The Dark Side of the Moon", "Pink Floyd").unwrap();
    let ver_rescan = AlbumVersion::new(&alb_rescan.id, ProviderKind::Local, "/music/dsotm", fmt_local.clone())
        .unwrap();
    let trk_rescan = TrackSource::new(
        &ver_rescan.id,
        ProviderKind::Local,
        "/music/dsotm/01.flac",
        "Speak to Me",
        1,
        1,
        65000,
        fmt_local.clone(),
    )
    .unwrap()
    .with_replay_gain(Some(-4.1), None, None, None);
    alb_rescan.add_version(ver_rescan);
    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![alb_rescan],
            tracks: vec![trk_rescan],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    let artist_after = LibrarySyncService::get_artist_detail(&pool, &enriched_artist.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(artist_after.biography.as_deref(), Some("English rock band"));

    // "Unknown Album" / "Unknown Artist" safety guard: two distinct untagged albums must NOT merge!
    let mut unk1 = CanonicalAlbum::new("Unknown Album", "Unknown Artist").unwrap();
    let v_u1 = AlbumVersion::new(&unk1.id, ProviderKind::Local, "/tmp/u1", fmt_local.clone()).unwrap();
    let t_u1 = TrackSource::new(&v_u1.id, ProviderKind::Local, "/tmp/u1/01.flac", "Track A", 1, 1, 1000, fmt_local.clone()).unwrap();
    unk1.add_version(v_u1);

    let mut unk2 = CanonicalAlbum::new("Unknown Album", "Unknown Artist").unwrap();
    let v_u2 = AlbumVersion::new(&unk2.id, ProviderKind::Local, "/tmp/u2", fmt_local.clone()).unwrap();
    let t_u2 = TrackSource::new(&v_u2.id, ProviderKind::Local, "/tmp/u2/01.flac", "Track B", 1, 1, 1000, fmt_local).unwrap();
    unk2.add_version(v_u2);

    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![unk1, unk2],
            tracks: vec![t_u1, t_u2],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    let merged_extra = LibrarySyncService::deduplicate_library(&pool).await.unwrap();
    assert_eq!(merged_extra, 0);
    let all_after = LibrarySyncService::list_canonical_albums(&pool, 50, 0)
        .await
        .unwrap();
    assert_eq!(all_after.len(), 3); // 1 Pink Floyd + 2 distinct Unknown Albums
}

#[tokio::test]
async fn test_f38_musicbrainz_discogs_enrichment_rate_limit_and_collision_merge() {
    let mb_calls = Arc::new(AtomicUsize::new(0));
    let mb_calls_c = mb_calls.clone();

    let (mb_base, mb_server) = spawn_enrichment_server(move |req| {
        assert_eq!(
            req.headers.get("user-agent").map(String::as_str),
            Some("LuminaTest/1.0")
        );
        assert!(req.target.contains("fmt=json"));

        let n = mb_calls_c.fetch_add(1, Ordering::SeqCst);
        if n == 0 {
            // Simulate 429 Retry-After: 0 on first call to test backoff retry
            return (429, vec![("Retry-After".into(), "0".into())], "Rate limited".into());
        }

        if req.target.starts_with("/release-group?") {
            return (
                200,
                vec![],
                r#"{"release-groups":[{"id":"rg-dsotm-1","title":"The Dark Side of the Moon"}]}"#.into(),
            );
        }
        if req.target.starts_with("/release-group/rg-dsotm-1") {
            return (
                200,
                vec![],
                r#"{"id":"rg-dsotm-1","title":"The Dark Side of the Moon","releases":[{"id":"rel-1","title":"DSOTM"}]}"#.into(),
            );
        }
        if req.target.starts_with("/release/rel-1") {
            return (
                200,
                vec![],
                r#"{
                    "id":"rel-1",
                    "title":"The Dark Side of the Moon",
                    "barcode":"5099902987620",
                    "release-group":{"id":"rg-dsotm-1","title":"The Dark Side of the Moon"},
                    "artist-credit":[{"artist":{"id":"art-pf","name":"Pink Floyd"}}],
                    "relations":[
                        {"type":"engineer","target-type":"artist","attributes":[],"artist":{"id":"art-ap","name":"Alan Parsons"}}
                    ],
                    "media":[{
                        "tracks":[{
                            "id":"trk-1",
                            "title":"Time",
                            "recording":{
                                "id":"rec-1",
                                "title":"Time",
                                "relations":[
                                    {"type":"instrument","target-type":"artist","attributes":["guitar"],"artist":{"id":"art-dg","name":"David Gilmour"}}
                                ]
                            }
                        }]
                    }]
                }"#.into(),
            );
        }
        if req.target.starts_with("/artist/art-ap") {
            return (
                200,
                vec![],
                r#"{"id":"art-ap","name":"Alan Parsons","disambiguation":"English audio engineer"}"#.into(),
            );
        }
        if req.target.starts_with("/artist/art-dg") {
            return (
                200,
                vec![],
                r#"{"id":"art-dg","name":"David Gilmour","disambiguation":"Pink Floyd guitarist"}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let (dg_base, dg_server) = spawn_enrichment_server(move |req| {
        assert_eq!(
            req.headers.get("authorization").map(String::as_str),
            Some("Discogs token=dg_secret_tok")
        );
        assert_eq!(
            req.headers.get("user-agent").map(String::as_str),
            Some("LuminaTest/1.0")
        );

        if req.target.starts_with("/database/search") {
            return (
                200,
                vec![],
                r#"{"results":[{"id":10562,"title":"The Dark Side of the Moon","master_id":10362}]}"#.into(),
            );
        }
        if req.target.starts_with("/releases/10562") {
            return (
                200,
                vec![],
                r#"{
                    "id":10562,
                    "title":"The Dark Side of the Moon",
                    "master_id":10362,
                    "notes":"Landmark 1973 progressive rock album recorded at Abbey Road.",
                    "images":[{"uri":"https://img.discogs.com/dsotm.jpg","type":"primary"}],
                    "extraartists":[
                        {"id":99,"name":"Alan Parsons (2)","role":"Producer, Mixed By"}
                    ]
                }"#.into(),
            );
        }
        if req.target.starts_with("/artists/99") {
            return (
                200,
                vec![],
                r#"{"id":99,"name":"Alan Parsons (2)","profile":"Legendary Abbey Road engineer and producer."}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let pool = open_test_database().await.unwrap();
    let fmt = AudioFormat::cd_quality();

    // Insert 2 separate albums that will resolve to the same MusicBrainz release group ID
    let mut alb1 = CanonicalAlbum::new("The Dark Side of the Moon", "Pink Floyd").unwrap();
    let v1 = AlbumVersion::new(&alb1.id, ProviderKind::Local, "/a1", fmt.clone()).unwrap();
    alb1.add_version(v1);

    let mut alb2 = CanonicalAlbum::new("DSOTM Alternate Press", "Pink Floyd Variant").unwrap();
    let v2 = AlbumVersion::new(&alb2.id, ProviderKind::Qobuz, "qb-alt", fmt).unwrap();
    alb2.add_version(v2);

    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![alb1.clone(), alb2.clone()],
            tracks: vec![],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // Verify RateLimiter spacing works (>= 40ms across 2 acquires)
    let mb_client = MusicBrainzClient::new(MusicBrainzConfig {
        base_url: mb_base,
        user_agent: "LuminaTest/1.0".to_string(),
        min_interval_ms: 40,
        max_retries: 2,
        timeout_secs: 5,
    })
    .unwrap();
    let dg_client = DiscogsClient::new(DiscogsConfig {
        base_url: dg_base,
        user_agent: "LuminaTest/1.0".to_string(),
        token: Some("dg_secret_tok".to_string()),
        min_interval_ms: 0,
        max_retries: 1,
        timeout_secs: 5,
    })
    .unwrap();

    let svc = CreditEnrichmentService::new(
        Some(mb_client),
        Some(dg_client),
        EnrichmentConfig::default(),
    );

    let t0 = Instant::now();
    let res1 = svc.enrich_album(&pool, &alb1.id).await.unwrap();
    assert!(t0.elapsed().as_millis() >= 35); // RateLimiter enforced across 429 retry + lookups
    assert!(!res1.skipped);
    assert_eq!(res1.mb_release_group_id.as_deref(), Some("rg-dsotm-1"));
    assert!(res1.credits_added >= 4); // Engineer, Instrument: Guitar, Producer, Mixed By

    let detail = LibrarySyncService::get_album_detail(&pool, &alb1.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        detail.album.cover_url.as_deref(),
        Some("https://img.discogs.com/dsotm.jpg")
    );
    let roles: Vec<&str> = detail.credits.iter().map(|c| c.role.as_str()).collect();
    assert!(roles.contains(&"Engineer"));
    assert!(roles.contains(&"Instrument: Guitar"));
    assert!(roles.contains(&"Producer"));
    assert!(roles.contains(&"Mixed By"));

    // Stripped "(2)" artist name should link cleanly to "Alan Parsons"
    let alan = detail
        .credits
        .iter()
        .find(|c| c.artist_name == "Alan Parsons")
        .expect("Alan Parsons credit must exist without (2) suffix");
    let alan_detail = LibrarySyncService::get_artist_detail(&pool, &alan.artist_id)
        .await
        .unwrap()
        .unwrap();
    assert!(!alan_detail.credits.is_empty());

    // Idempotency: second run skips cleanly with zero duplicate credits
    let res_idem = svc.enrich_album(&pool, &alb1.id).await.unwrap();
    assert!(res_idem.skipped);

    // Enriching alb2 resolves to same rg-dsotm-1 and merges into alb1 without SQLite UNIQUE failure
    let res2 = svc.enrich_album(&pool, &alb2.id).await.unwrap();
    assert_eq!(res2.merged_into_album_id.as_deref(), Some(alb1.id.as_str()));

    let remaining = LibrarySyncService::list_canonical_albums(&pool, 50, 0)
        .await
        .unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].versions.len(), 2);

    // Also test enrich_library pagination & FTS rebuild
    let batch_report = svc.enrich_library(&pool).await.unwrap();
    assert_eq!(batch_report.albums_processed, 1);
    assert_eq!(batch_report.albums_skipped, 1);

    mb_server.abort();
    dg_server.abort();
}

#[tokio::test]
async fn test_provider_manager_sync_and_persist_plus_initialize_credentials() {
    let pool = open_test_database().await.unwrap();
    let cred_store = Arc::new(MemoryCredentialStore::new());
    let manager = ProviderManager::with_credential_store(cred_store);

    // Safe offline initialization
    manager.initialize_credentials().await;

    let dir = tempdir().unwrap();
    manager
        .configure_local(LocalProviderConfig {
            root_paths: vec![dir.path().to_path_buf()],
            follow_symlinks: false,
        })
        .await;

    let smb_mock = Arc::new(MockSmbTransport::new());
    smb_mock
        .add_entry(SmbEntry {
            relative_path: "Miles Davis/Birth of the Cool/01 - Move.flac".to_string(),
            local_path: None,
            metadata: None,
        })
        .await;
    let smb_uri = parse_remote_share_uri("smb://user:pass@nas.local/Music/").unwrap();
    manager
        .configure_smb(
            SmbConfig {
                uri: smb_uri,
                domain: None,
            },
            Some(smb_mock),
        )
        .await;

    let (results, report) = manager.sync_and_persist(&pool).await.unwrap();
    assert_eq!(results.len(), 2);
    assert_eq!(report.albums_inserted, 1);
    assert_eq!(report.tracks_upserted, 1);

    let albums = LibrarySyncService::list_canonical_albums(&pool, 10, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].title, "Birth of the Cool");
}

#[test]
fn test_edition_keyword_word_boundary_and_discogs_bracketed_roles() {
    use core_providers::{
        extract_discogs_credits, DiscogsExtraArtist, DiscogsRelease,
    };

    // Word-boundary check: "Olive" must NOT match "live"; "Monolith" must NOT match "mono"
    assert_eq!(
        extract_edition_label("Song (Olive)"),
        ("Song (Olive)".to_string(), None)
    );
    assert_eq!(
        extract_edition_label("Album (Monolith)"),
        ("Album (Monolith)".to_string(), None)
    );
    assert_eq!(
        extract_edition_label("Concert (Live at Wembley)"),
        (
            "Concert".to_string(),
            Some("Live at Wembley".to_string())
        )
    );

    // Bracket-aware Discogs role splitting: "Vocals [Lead, Backing]" stays 1 role
    let release = DiscogsRelease {
        id: 1,
        title: "Test".to_string(),
        extraartists: vec![
            DiscogsExtraArtist {
                id: Some(10),
                name: "Clare Torry".to_string(),
                role: "Vocals [Lead, Backing]".to_string(),
            },
            DiscogsExtraArtist {
                id: Some(11),
                name: "Alan Parsons (2)".to_string(),
                role: "Producer, Mixed By, Guitar (Acoustic, 12-String)".to_string(),
            },
        ],
        ..Default::default()
    };
    let extracted = extract_discogs_credits(&release);
    let roles: Vec<(String, String)> = extracted
        .credits
        .into_iter()
        .map(|c| (c.artist_name, c.role))
        .collect();
    assert!(roles.contains(&("Clare Torry".into(), "Vocals [Lead, Backing]".into())));
    assert!(roles.contains(&("Alan Parsons".into(), "Producer".into())));
    assert!(roles.contains(&("Alan Parsons".into(), "Mixed By".into())));
    assert!(roles.contains(&(
        "Alan Parsons".into(),
        "Guitar (Acoustic, 12-String)".into()
    )));
    assert_eq!(roles.len(), 4);
}

#[tokio::test]
async fn test_f37_intra_batch_isrc_dedup_upc_deduplicate_library_and_local_upc() {
    let pool = open_test_database().await.unwrap();
    let fmt = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();

    // 1. Intra-batch ISRC dedup: 3 albums in a single persist_sync_result call sharing only ISRC
    let mut a1 = CanonicalAlbum::new("Blue Train", "John Coltrane").unwrap();
    let v1 = AlbumVersion::new(&a1.id, ProviderKind::Local, "/music/bluetrain", fmt.clone()).unwrap();
    let t1 = TrackSource::new(&v1.id, ProviderKind::Local, "/music/bt/01.flac", "Blue Train", 1, 1, 600_000, fmt.clone())
        .unwrap()
        .with_isrc("USBN25700001")
        .unwrap();
    a1.add_version(v1);

    let mut a2 = CanonicalAlbum::new("Blue Train Tidal", "John Coltrane").unwrap();
    let v2 = AlbumVersion::new(&a2.id, ProviderKind::Tidal, "tid-bt-1", fmt.clone()).unwrap();
    let t2 = TrackSource::new(&v2.id, ProviderKind::Tidal, "tid-trk-bt-1", "Blue Train", 1, 1, 600_000, fmt.clone())
        .unwrap()
        .with_isrc("USBN25700001")
        .unwrap();
    a2.add_version(v2);

    let mut a3 = CanonicalAlbum::new("Blue Train Deezer", "John Coltrane")
        .unwrap()
        .with_musicbrainz_id("rg-bluetrain-1");
    let v3 = AlbumVersion::new(&a3.id, ProviderKind::Deezer, "dz-bt-1", fmt.clone()).unwrap();
    let t3 = TrackSource::new(&v3.id, ProviderKind::Deezer, "dz-trk-bt-1", "Blue Train", 1, 1, 600_000, fmt.clone())
        .unwrap()
        .with_isrc("USBN25700001")
        .unwrap();
    a3.add_version(v3);

    let rep = LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: vec![a1, a2, a3],
            tracks: vec![t1, t2, t3],
            ..Default::default()
        },
    )
    .await
    .unwrap();
    assert_eq!(rep.albums_inserted, 1);
    assert_eq!(rep.albums_matched, 2);

    let stored = LibrarySyncService::list_canonical_albums(&pool, 50, 0)
        .await
        .unwrap();
    assert_eq!(stored.len(), 1);
    assert_eq!(stored[0].versions.len(), 3);

    // 2. deduplicate_library UPC matching across differing titles without MBID or ISRC
    let mut u1 = CanonicalAlbum::new("Album Alpha", "Artist One").unwrap();
    let uv1 = AlbumVersion::new(&u1.id, ProviderKind::Local, "/u1", fmt.clone()).unwrap();
    u1.add_version(uv1);
    let mut u2 = CanonicalAlbum::new("Alpha Deluxe Different Title", "Artist One").unwrap();
    let uv2 = AlbumVersion::new(&u2.id, ProviderKind::Qobuz, "qb-u2", fmt).unwrap();
    u2.add_version(uv2);

    let artist = LibraryRepository::upsert_artist_by_mbid_or_name(&pool, "Artist One", None, None, None)
        .await
        .unwrap();
    LibraryRepository::insert_canonical_album(&pool, &u1, Some(&artist.id))
        .await
        .unwrap();
    LibraryRepository::update_canonical_album_metadata(&pool, &u1.id, Some("098765432109"), None, None, None)
        .await
        .unwrap();
    LibraryRepository::insert_canonical_album(&pool, &u2, Some(&artist.id))
        .await
        .unwrap();
    LibraryRepository::update_canonical_album_metadata(&pool, &u2.id, Some("098765432109"), None, None, None)
        .await
        .unwrap();

    let merged_upc = LibrarySyncService::deduplicate_library(&pool).await.unwrap();
    assert_eq!(merged_upc, 1);

    let upc_found = LibraryRepository::find_canonical_album_by_upc(&pool, "098765432109")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(upc_found.versions.len(), 2);

    // 3. LocalProvider + ProviderManager::sync_and_persist preserves UPC from local FLAC tags
    let pool_local = open_test_database().await.unwrap();
    let dir = tempdir().unwrap();
    let alb_dir = dir.path().join("Miles Davis").join("Kind of Blue");
    std::fs::create_dir_all(&alb_dir).unwrap();
    let flac_bytes = build_minimal_flac_with_comments(&[
        "TITLE=So What",
        "ARTIST=Miles Davis",
        "ALBUM=Kind of Blue",
        "UPC=886443927018",
    ]);
    std::fs::write(alb_dir.join("01 - So What.flac"), flac_bytes).unwrap();

    let manager = ProviderManager::with_credential_store(Arc::new(MemoryCredentialStore::new()));
    manager
        .configure_local(LocalProviderConfig {
            root_paths: vec![dir.path().to_path_buf()],
            follow_symlinks: false,
        })
        .await;
    manager.sync_and_persist(&pool_local).await.unwrap();

    let by_upc = LibraryRepository::find_canonical_album_by_upc(&pool_local, "886443927018")
        .await
        .unwrap();
    assert!(by_upc.is_some());
    assert_eq!(by_upc.unwrap().title, "Kind of Blue");
}

#[tokio::test]
async fn test_f38_enrich_library_pagination_on_merge_upstream_errors_and_force_refresh_count() {
    // Part A: 52-album pagination-on-merge must enrich all albums without skipping Album 050
    let (mb_base, mb_server) = spawn_enrichment_server(move |req| {
        if req.target.starts_with("/release-group?") {
            let decoded_target = core_providers::percent_decode(&req.target).replace('+', " ");
            if decoded_target.contains("Album 001") || decoded_target.contains("Album 051") {
                return (
                    200,
                    vec![],
                    r#"{"release-groups":[{"id":"rg-collide","title":"Album 000"}]}"#.into(),
                );
            }
            let digits: String = decoded_target
                .split("Album ")
                .nth(1)
                .unwrap_or("")
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            let rg_id = if digits.is_empty() {
                "rg-other".to_string()
            } else {
                format!("rg-{digits}")
            };
            return (
                200,
                vec![],
                format!(r#"{{"release-groups":[{{"id":"{rg_id}","title":"Album {digits}"}}]}}"#),
            );
        }
        if req.target.starts_with("/release-group/") {
            let rg = req
                .target
                .trim_start_matches("/release-group/")
                .split('?')
                .next()
                .unwrap_or("rg-000");
            return (
                200,
                vec![],
                format!(r#"{{"id":"{rg}","title":"T","releases":[{{"id":"rel-{rg}","title":"T"}}]}}"#),
            );
        }
        if req.target.starts_with("/release/") {
            let rel = req
                .target
                .trim_start_matches("/release/")
                .split('?')
                .next()
                .unwrap_or("rel-000");
            return (
                200,
                vec![],
                format!(
                    r#"{{"id":"{rel}","title":"T","relations":[{{"type":"producer","target-type":"artist","attributes":[],"artist":{{"id":"art-1","name":"Producer One"}}}}]}}"#
                ),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let pool = open_test_database().await.unwrap();
    let fmt = AudioFormat::cd_quality();
    let mut seed_albums = Vec::new();
    for i in 0..52 {
        let mut alb = CanonicalAlbum::new(format!("Album {i:03}"), format!("Artist {i:03}")).unwrap();
        if i == 0 {
            alb = alb.with_musicbrainz_id("rg-collide");
        }
        let ver = AlbumVersion::new(&alb.id, ProviderKind::Local, format!("/a/{i:03}"), fmt.clone())
            .unwrap();
        alb.add_version(ver);
        seed_albums.push(alb);
    }
    LibrarySyncService::persist_sync_result(
        &pool,
        &SyncResult {
            albums: seed_albums,
            tracks: vec![],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    let mb_client = MusicBrainzClient::new(MusicBrainzConfig {
        base_url: mb_base,
        user_agent: "LuminaTest/1.0".to_string(),
        min_interval_ms: 0,
        max_retries: 0,
        timeout_secs: 5,
    })
    .unwrap();

    let svc = CreditEnrichmentService::new(
        Some(mb_client),
        None,
        EnrichmentConfig {
            fetch_artist_bios: false,
            max_albums_per_run: 100,
            ..Default::default()
        },
    );

    let report = svc.enrich_library(&pool).await.unwrap();
    assert_eq!(report.albums_merged, 2); // Album 001 + Album 051 merged into Album 000
    assert!(report.errors.is_empty());

    let unenriched: Vec<(String,)> =
        sqlx::query_as("SELECT title FROM canonical_albums WHERE enriched_at IS NULL")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert!(
        unenriched.is_empty(),
        "Expected 0 unenriched albums, got {unenriched:?}"
    );

    mb_server.abort();

    // Part B: force_refresh credits_added == 0 AND total HTTP 500 failure must NOT mark enriched_at
    let (err_base, err_server) = spawn_enrichment_server(move |_req| {
        (500, vec![], "Internal Server Error".into())
    })
    .await;
    let (ok_base, ok_server) = spawn_enrichment_server(move |req| {
        if req.target.starts_with("/release-group?") {
            return (
                200,
                vec![],
                r#"{"release-groups":[{"id":"rg-ok","title":"OK"}]}"#.into(),
            );
        }
        if req.target.starts_with("/release-group/rg-ok") {
            return (
                200,
                vec![],
                r#"{"id":"rg-ok","title":"OK","releases":[{"id":"rel-ok","title":"OK"}]}"#.into(),
            );
        }
        if req.target.starts_with("/release/rel-ok") {
            return (
                200,
                vec![],
                r#"{"id":"rel-ok","title":"OK","relations":[{"type":"engineer","target-type":"artist","attributes":[],"artist":{"id":"art-e","name":"Bob Ludwig"}}]}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let pool2 = open_test_database().await.unwrap();
    let mut alb = CanonicalAlbum::new("OK Album", "OK Artist").unwrap();
    let v = AlbumVersion::new(&alb.id, ProviderKind::Local, "/ok", fmt).unwrap();
    alb.add_version(v);
    let alb_id = alb.id.clone();
    LibrarySyncService::persist_sync_result(
        &pool2,
        &SyncResult {
            albums: vec![alb],
            tracks: vec![],
            ..Default::default()
        },
    )
    .await
    .unwrap();

    // Failing upstream leaves enriched_at NULL and records error in EnrichmentReport
    let failing_svc = CreditEnrichmentService::new(
        Some(
            MusicBrainzClient::new(MusicBrainzConfig {
                base_url: err_base.clone(),
                user_agent: "LuminaTest/1.0".to_string(),
                min_interval_ms: 0,
                max_retries: 0,
                timeout_secs: 5,
            })
            .unwrap(),
        ),
        Some(
            DiscogsClient::new(DiscogsConfig {
                base_url: err_base,
                user_agent: "LuminaTest/1.0".to_string(),
                token: None,
                min_interval_ms: 0,
                max_retries: 0,
                timeout_secs: 5,
            })
            .unwrap(),
        ),
        EnrichmentConfig::default(),
    );
    let err_res = failing_svc.enrich_album(&pool2, &alb_id).await;
    assert!(err_res.is_err());
    let fail_report = failing_svc.enrich_library(&pool2).await.unwrap();
    assert_eq!(fail_report.albums_enriched, 0);
    assert_eq!(fail_report.errors.len(), 1);
    let enriched_at: (Option<String>,) =
        sqlx::query_as("SELECT enriched_at FROM canonical_albums WHERE id = ?")
            .bind(&alb_id)
            .fetch_one(&pool2)
            .await
            .unwrap();
    assert!(enriched_at.0.is_none());

    // Succeeding enrichment adds 1 credit, and force_refresh reports 0 newly added credits
    let ok_svc = CreditEnrichmentService::new(
        Some(
            MusicBrainzClient::new(MusicBrainzConfig {
                base_url: ok_base,
                user_agent: "LuminaTest/1.0".to_string(),
                min_interval_ms: 0,
                max_retries: 0,
                timeout_secs: 5,
            })
            .unwrap(),
        ),
        None,
        EnrichmentConfig {
            force_refresh: true,
            fetch_artist_bios: false,
            ..Default::default()
        },
    );
    let r1 = ok_svc.enrich_album(&pool2, &alb_id).await.unwrap();
    assert_eq!(r1.credits_added, 1);
    let r2 = ok_svc.enrich_album(&pool2, &alb_id).await.unwrap();
    assert_eq!(r2.credits_added, 0);

    err_server.abort();
    ok_server.abort();
}

fn build_minimal_flac_with_comments(comments: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"fLaC");
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0x22]);
    let mut si = [0u8; 34];
    si[0..2].copy_from_slice(&4096u16.to_be_bytes());
    si[2..4].copy_from_slice(&4096u16.to_be_bytes());
    let packed: u64 = (44100u64 << 44) | (1u64 << 41) | (15u64 << 36) | 44100u64;
    si[10..18].copy_from_slice(&packed.to_be_bytes());
    out.extend_from_slice(&si);

    let mut vc = Vec::new();
    let vendor = b"LuminaTest";
    vc.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    vc.extend_from_slice(vendor);
    vc.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for c in comments {
        let cb = c.as_bytes();
        vc.extend_from_slice(&(cb.len() as u32).to_le_bytes());
        vc.extend_from_slice(cb);
    }
    let vc_len = vc.len() as u32;
    out.push(0x84);
    out.push(((vc_len >> 16) & 0xFF) as u8);
    out.push(((vc_len >> 8) & 0xFF) as u8);
    out.push((vc_len & 0xFF) as u8);
    out.extend_from_slice(&vc);

    let hdr = [0xFFu8, 0xF8, 0xC9, 0x18, 0x00];
    let mut crc = 0u8;
    for b in hdr {
        crc ^= b;
        for _ in 0..8 {
            crc = if (crc & 0x80) != 0 {
                (crc << 1) ^ 0x07
            } else {
                crc << 1
            };
        }
    }
    out.extend_from_slice(&hdr);
    out.push(crc);
    out.extend_from_slice(&[0u8; 8]);
    out
}
