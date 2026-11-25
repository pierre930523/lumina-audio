use std::fs::{self, File};
use std::path::PathBuf;
use std::sync::Arc;

use core_db::credential::MemoryCredentialStore;
use core_types::{AudioCodec, AudioFormat, ProviderKind, TrackSource};
use tempfile::tempdir;

use core_providers::{
    find_folder_cover, find_folder_cover_in_files, generate_pkce_challenge, is_scannable_audio,
    is_token_expired, make_basic_auth, normalize_path, normalize_qobuz_sample_rate,
    parse_remote_share_uri, qobuz_format_ids, resolve_qobuz_format_id, validate_arl_cookie,
    validate_pkce_verifier, AlbumMapper, DeezerConfig, DeezerProvider, DirectoryScanner,
    ExtractedMetadata, HttpResponse, LocalProvider, LocalProviderConfig, MetadataExtractor,
    MockHttpTransport, MusicProvider, ProviderCapabilities, ProviderError, ProviderManager,
    ProviderRegistry, QobuzConfig, QobuzProvider, RemoteShareUri, SmbConfig, SmbProvider,
    TidalConfig, TidalProvider, TidalTokenResponse, WebDavConfig, WebDavProvider,
    COVER_ART_FILENAMES, SCANNABLE_AUDIO_EXTENSIONS,
};

// ==============================================================================
// 1. Local Filesystem Scanner & Path Normalization Tests
// ==============================================================================

#[test]
fn test_normalize_path_deduplication() {
    let p1 = r"C:\Music\Pink Floyd\01.flac";
    let p2 = r"c:/music/pink floyd/01.flac";
    assert_eq!(normalize_path(p1), normalize_path(p2));

    let p3 = "/media/nas/Album/01.flac";
    #[cfg(windows)]
    assert_eq!(normalize_path(p3), "/media/nas/album/01.flac");
    #[cfg(not(windows))]
    assert_eq!(normalize_path(p3), "/media/nas/Album/01.flac");
}

#[test]
fn test_is_scannable_audio_extensions() {
    for ext in SCANNABLE_AUDIO_EXTENSIONS {
        let path_str = format!("song.{ext}");
        assert!(
            is_scannable_audio(std::path::Path::new(&path_str)),
            "Extension {ext} should be scannable"
        );
        let upper_str = format!("song.{}", ext.to_uppercase());
        assert!(
            is_scannable_audio(std::path::Path::new(&upper_str)),
            "Upper extension {upper_str} should be scannable"
        );
    }

    // Rejections
    assert!(!is_scannable_audio(std::path::Path::new("lyrics.txt")));
    assert!(!is_scannable_audio(std::path::Path::new("cover.jpg")));
    assert!(!is_scannable_audio(std::path::Path::new("audio.exe")));
    assert!(!is_scannable_audio(std::path::Path::new(".hidden.flac")));
    assert!(!is_scannable_audio(std::path::Path::new(".DS_Store")));
}

#[test]
fn test_cover_art_detection() {
    let files = ["01 - Track.flac", "02 - Track.flac", "Cover.JPG", "notes.txt"];
    let found = find_folder_cover_in_files(&files);
    assert_eq!(found, Some("Cover.JPG".to_string()));

    let files_png = ["front.png", "track.mp3"];
    let found_png = find_folder_cover_in_files(&files_png);
    assert_eq!(found_png, Some("front.png".to_string()));

    let no_cover = ["track1.flac", "track2.flac"];
    assert_eq!(find_folder_cover_in_files(&no_cover), None);
}

#[test]
fn test_directory_scanner_traversal_and_hidden_filtering() {
    let dir = tempdir().unwrap();
    let root = dir.path();

    // Create subdirs
    let album_dir = root.join("Artist").join("Album");
    fs::create_dir_all(&album_dir).unwrap();

    // Create mock files
    File::create(album_dir.join("01 - Test.flac")).unwrap();
    File::create(album_dir.join("02 - Test.wav")).unwrap();
    File::create(album_dir.join("cover.jpg")).unwrap();
    File::create(album_dir.join(".hidden.mp3")).unwrap();
    File::create(album_dir.join("notes.txt")).unwrap();

    let mut scanner = DirectoryScanner::new(false);
    let scanned = scanner.scan_directory(root);

    assert_eq!(scanned.len(), 2);
    let names: Vec<String> = scanned
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
        .collect();
    assert!(names.contains(&"01 - Test.flac".to_string()));
    assert!(names.contains(&"02 - Test.wav".to_string()));
}

#[test]
fn test_album_mapper_grouping() {
    let path1 = PathBuf::from("c:/Music/Pink Floyd/Dark Side/01 - Speak to Me.flac");
    let path2 = PathBuf::from("c:/Music/Pink Floyd/Dark Side/02 - Breathe.flac");

    let format = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();

    let meta1 = ExtractedMetadata {
        title: "Speak to Me".to_string(),
        artist: "Pink Floyd".to_string(),
        album: "The Dark Side of the Moon".to_string(),
        album_artist: Some("Pink Floyd".to_string()),
        track_number: 1,
        disc_number: 1,
        release_year: Some(1973),
        isrc: Some("GBAYE7300001".to_string()),
        duration_ms: 65000,
        format: format.clone(),
        cover_url: None,
        ..Default::default()
    };

    let meta2 = ExtractedMetadata {
        title: "Breathe".to_string(),
        artist: "Pink Floyd".to_string(),
        album: "The Dark Side of the Moon".to_string(),
        album_artist: Some("Pink Floyd".to_string()),
        track_number: 2,
        disc_number: 1,
        release_year: Some(1973),
        isrc: Some("GBAYE7300002".to_string()),
        duration_ms: 163000,
        format: format.clone(),
        cover_url: None,
        ..Default::default()
    };

    let items = vec![(path1, meta1), (path2, meta2)];
    let (albums, tracks) = AlbumMapper::map_scanned_items(items, ProviderKind::Local).unwrap();

    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].title, "The Dark Side of the Moon");
    assert_eq!(albums[0].artist_name, "Pink Floyd");
    assert_eq!(albums[0].release_year, Some(1973));
    assert_eq!(albums[0].versions.len(), 1);

    assert_eq!(tracks.len(), 2);
    assert_eq!(tracks[0].title, "Speak to Me");
    assert_eq!(tracks[0].track_number, 1);
    assert_eq!(tracks[1].title, "Breathe");
    assert_eq!(tracks[1].track_number, 2);
}

#[tokio::test]
async fn test_local_provider_music_provider_contract() {
    let dir = tempdir().unwrap();
    let root = dir.path();
    let album_dir = root.join("Artist").join("Album");
    fs::create_dir_all(&album_dir).unwrap();

    let config = LocalProviderConfig {
        root_paths: vec![root.to_path_buf()],
        follow_symlinks: false,
    };
    let provider = LocalProvider::new(config);

    assert_eq!(provider.kind(), ProviderKind::Local);
    assert!(provider.capabilities().supports_filesystem_scan);
    assert!(provider.capabilities().supports_hi_res);
    assert!(provider.is_authenticated().await);

    // Empty sync
    let sync_res = provider.sync_library().await.unwrap();
    assert_eq!(sync_res.scanned_files_count, 0);

    // Search empty
    let res = provider.search("Pink", 10).await.unwrap();
    assert!(res.is_empty());
}

// ==============================================================================
// 2. Remote SMB & WebDAV Tests
// ==============================================================================

#[test]
fn test_remote_share_uri_smb_parsing() {
    let uri = "smb://nas.local/HiFiMusic/FLAC/album/";
    let res = parse_remote_share_uri(uri).unwrap();
    assert_eq!(res.protocol, "smb");
    assert_eq!(res.host, "nas.local");
    assert_eq!(res.port, 445);
    assert_eq!(res.share_name, "HiFiMusic");
    assert_eq!(res.relative_path, "FLAC/album/");
    assert!(!res.is_authenticated);
}

#[test]
fn test_remote_share_uri_webdav_parsing() {
    let uri = "https://user:secret@dav.example.com:8443/music/flac/";
    let res = parse_remote_share_uri(uri).unwrap();
    assert_eq!(res.protocol, "web_dav");
    assert_eq!(res.host, "dav.example.com");
    assert_eq!(res.port, 8443);
    assert_eq!(res.username, Some("user".to_string()));
    assert_eq!(res.password, Some("secret".to_string()));
    assert!(res.is_authenticated);
}

#[test]
fn test_remote_share_uri_percent_decoding() {
    let uri = "davs://admin%40domain:p%40ss%20word@webdav.lumina.io:8443/music/hires";
    let res = parse_remote_share_uri(uri).unwrap();
    assert_eq!(res.username, Some("admin@domain".to_string()));
    assert_eq!(res.password, Some("p@ss word".to_string()));
}

#[test]
fn test_remote_share_uri_ipv6_host() {
    let uri = "smb://[fe80::1]:445/Music/album";
    let res = parse_remote_share_uri(uri).unwrap();
    assert_eq!(res.host, "fe80::1");
    assert_eq!(res.port, 445);
    assert_eq!(res.share_name, "Music");
}

#[test]
fn test_remote_share_uri_unsupported_protocol() {
    let uri = "ftp://nas.local/music";
    let err = parse_remote_share_uri(uri).unwrap_err();
    match err {
        ProviderError::InvalidConfig(msg) => {
            assert!(msg.contains("Unsupported remote scheme 'ftp'"));
        }
        _ => panic!("Expected InvalidConfig error"),
    }
}

#[test]
fn test_make_basic_auth() {
    let header = make_basic_auth("audiophile", "p@ssword123");
    assert_eq!(header, "Basic YXVkaW9waGlsZTpwQHNzd29yZDEyMw==");
}

#[tokio::test]
async fn test_smb_provider_stream_resolution_with_credentials() {
    let uri = parse_remote_share_uri("smb://user:pass@nas.local:445/Music/Jazz/").unwrap();
    let config = SmbConfig {
        uri,
        domain: None,
    };
    let provider = SmbProvider::new(config, None);

    assert_eq!(provider.kind(), ProviderKind::Smb);
    assert!(provider.is_authenticated().await);

    let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();
    let track = TrackSource::new(
        "ver-1",
        ProviderKind::Smb,
        "Bill_Evans.flac",
        "Autumn Leaves",
        1,
        1,
        300000,
        format,
    )
    .unwrap();

    let resolved = provider.resolve_stream(&track).await.unwrap();
    assert_eq!(resolved.url_or_path, "smb://nas.local/Music/Bill_Evans.flac");
    assert_eq!(resolved.headers.len(), 1);
    assert_eq!(resolved.headers[0].0, "Authorization");
    assert_eq!(resolved.headers[0].1, "Basic dXNlcjpwYXNz");
}

#[tokio::test]
async fn test_smb_provider_offline_mode() {
    let uri = parse_remote_share_uri("smb://nas.local/Music/").unwrap();
    let config = SmbConfig {
        uri,
        domain: None,
    };
    let provider = SmbProvider::new(config, None);

    provider.set_online(false).await;
    assert!(!provider.is_online().await);

    let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();
    let track = TrackSource::new(
        "ver-1",
        ProviderKind::Smb,
        "track.flac",
        "Track",
        1,
        1,
        1000,
        format,
    )
    .unwrap();

    let err = provider.resolve_stream(&track).await.unwrap_err();
    match err {
        ProviderError::StreamResolutionFailed(msg) => assert!(msg.contains("offline")),
        _ => panic!("Expected StreamResolutionFailed error"),
    }
}

#[tokio::test]
async fn test_webdav_provider_stream_resolution() {
    let uri = parse_remote_share_uri("https://nas.local/dav/").unwrap();
    let config = WebDavConfig { uri };
    let provider = WebDavProvider::new(config, None);

    assert_eq!(provider.kind(), ProviderKind::WebDav);

    let format = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let track = TrackSource::new(
        "ver-1",
        ProviderKind::WebDav,
        "Pink Floyd/01 - Breathe.flac",
        "Breathe",
        1,
        1,
        163000,
        format,
    )
    .unwrap();

    let resolved = provider.resolve_stream(&track).await.unwrap();
    assert_eq!(
        resolved.url_or_path,
        "https://nas.local:443/dav/Pink%20Floyd/01%20-%20Breathe.flac"
    );
}

// ==============================================================================
// 3. Qobuz Direct Token Provider Tests
// ==============================================================================

#[test]
fn test_qobuz_config_direct_token_mode() {
    let cfg = QobuzConfig::from_token("qb_usr_tok_99182371").unwrap();
    assert_eq!(cfg.app_id(), "8912301");
    assert!(cfg.auth.is_token());
}

#[test]
fn test_qobuz_format_id_and_sampling_rate_normalizer() {
    assert_eq!(resolve_qobuz_format_id(27), (192000, 24));
    assert_eq!(resolve_qobuz_format_id(7), (96000, 24));
    assert_eq!(resolve_qobuz_format_id(6), (44100, 16));
    assert_eq!(resolve_qobuz_format_id(5), (44100, 16));
    assert_eq!(resolve_qobuz_format_id(999), (44100, 16));

    assert_eq!(
        normalize_qobuz_sample_rate(&serde_json::json!(192.0)),
        192000
    );
    assert_eq!(normalize_qobuz_sample_rate(&serde_json::json!(44.1)), 44100);
    assert_eq!(normalize_qobuz_sample_rate(&serde_json::json!("96")), 96000);
    assert_eq!(
        normalize_qobuz_sample_rate(&serde_json::json!(96000)),
        96000
    );
}

#[tokio::test]
async fn test_qobuz_direct_token_auth_and_stream_resolution() {
    let transport = Arc::new(MockHttpTransport::new());

    // Register /user/get
    transport
        .register_exact(
            "user/get",
            HttpResponse::ok_json(
                r#"{
                    "status": "success",
                    "user": {
                        "id": 1083921,
                        "user_auth_token": "qb_tok_1",
                        "credential": {
                            "parameters": {
                                "hires": true,
                                "max_streaming_quality": 27
                            }
                        }
                    }
                }"#,
            ),
        )
        .await;

    // Register /track/getFileUrl
    transport
        .register_exact(
            "track/getFileUrl",
            HttpResponse::ok_json(
                r#"{
                    "track_id": 12049182,
                    "format_id": 27,
                    "mime_type": "audio/flac",
                    "sampling_rate": 192.0,
                    "bit_depth": 24,
                    "url": "https://streaming-qobuz.akamaized.net/stream/12049182.flac?token=sig_mock_1"
                }"#,
            ),
        )
        .await;

    let cred_store = Arc::new(MemoryCredentialStore::new());
    let config = QobuzConfig::from_token("qb_tok_1").unwrap();
    let provider = QobuzProvider::new(config, transport, Some(cred_store));

    // Authenticate
    let session = provider.authenticate().await.unwrap();
    assert_eq!(session.user_id, 1083921);
    assert!(session.hires);
    assert_eq!(session.max_streaming_quality, 27);
    assert!(provider.is_authenticated().await);

    // Resolve stream
    let format = AudioFormat::pcm(AudioCodec::Flac, 192000, 24, 2).unwrap();
    let track = TrackSource::new(
        "ver-qobuz",
        ProviderKind::Qobuz,
        "12049182",
        "Hotel California",
        1,
        1,
        391000,
        format,
    )
    .unwrap();

    let resolved = provider.resolve_stream(&track).await.unwrap();
    assert_eq!(resolved.format.sample_rate_hz, 192000);
    assert_eq!(resolved.format.bit_depth, 24);
    assert!(resolved
        .url_or_path
        .contains("streaming-qobuz.akamaized.net"));
    assert!(resolved
        .headers
        .iter()
        .any(|(k, v)| k == "X-User-Auth-Token" && v == "qb_tok_1"));
}

#[tokio::test]
async fn test_qobuz_drm_restricted_track() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "user/get",
            HttpResponse::ok_json(
                r#"{
                    "status": "success",
                    "user": {
                        "id": 100,
                        "credential": { "parameters": { "hires": true, "max_streaming_quality": 27 } }
                    }
                }"#,
            ),
        )
        .await;

    transport
        .register_exact(
            "track/getFileUrl",
            HttpResponse::ok_json(
                r#"{
                    "track_id": 999,
                    "restrictions": ["NOT_AVAILABLE_IN_TERRITORY"],
                    "url": null
                }"#,
            ),
        )
        .await;

    let config = QobuzConfig::from_token("qb_tok_drm").unwrap();
    let provider = QobuzProvider::new(config, transport, None);
    provider.authenticate().await.unwrap();

    let format = AudioFormat::cd_quality();
    let track = TrackSource::new(
        "ver-1",
        ProviderKind::Qobuz,
        "999",
        "Restricted",
        1,
        1,
        1000,
        format,
    )
    .unwrap();

    let err = provider.resolve_stream(&track).await.unwrap_err();
    match err {
        ProviderError::DrmRestricted(msg) => {
            assert!(msg.contains("NOT_AVAILABLE_IN_TERRITORY"));
        }
        _ => panic!("Expected DrmRestricted error"),
    }
}

// ==============================================================================
// 4. Tidal PKCE Provider Tests
// ==============================================================================

#[test]
fn test_tidal_pkce_challenge_generation() {
    let (verifier, challenge, auth_url) = generate_pkce_challenge();

    assert!(validate_pkce_verifier(&verifier));
    assert!(verifier.len() >= 43 && verifier.len() <= 128);

    // Unpadded URL-safe base64: no '=', no '+', no '/'
    assert!(!challenge.contains('='));
    assert!(!challenge.contains('+'));
    assert!(!challenge.contains('/'));
    assert!(challenge.len() >= 30);

    assert!(auth_url.contains(&format!("code_challenge={challenge}")));
    assert!(auth_url.contains("code_challenge_method=S256"));
    assert!(auth_url.contains("scope=r_usr+w_usr"));
}

#[tokio::test]
async fn test_tidal_provider_stream_resolution_and_bearer_header() {
    let cred_store = Arc::new(MemoryCredentialStore::new());
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "tracks/998877/playbackinfo",
            HttpResponse::ok_json(
                r#"{
                    "audioQuality": "HI_RES_LOSSLESS",
                    "sampleRate": 96000,
                    "bitDepth": 24,
                    "url": "https://sp-view.tidal.com/v1/tracks/998877/stream"
                }"#,
            ),
        )
        .await;
    let provider = TidalProvider::with_config(TidalConfig::default(), transport, Some(cred_store));

    assert_eq!(provider.kind(), ProviderKind::Tidal);
    assert!(!provider.is_authenticated().await);

    let format = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let track = TrackSource::new(
        "ver-tidal",
        ProviderKind::Tidal,
        "998877",
        "Track",
        1,
        1,
        200000,
        format,
    )
    .unwrap();

    // Resolving before login fails
    assert!(provider.resolve_stream(&track).await.is_err());

    // Login with mock token
    let tokens = TidalTokenResponse {
        access_token: "mock_tid_access_token_123".to_string(),
        refresh_token: "mock_tid_refresh_token_456".to_string(),
        token_type: "Bearer".to_string(),
        expires_in: 3600,
        user_id: 12345,
        issued_at: 0,
    };
    provider.login_with_tokens(tokens).await.unwrap();

    assert!(provider.is_authenticated().await);

    let resolved = provider.resolve_stream(&track).await.unwrap();
    assert_eq!(
        resolved.url_or_path,
        "https://sp-view.tidal.com/v1/tracks/998877/stream"
    );
    assert_eq!(resolved.format.sample_rate_hz, 96000);
    assert_eq!(
        resolved.headers[0],
        (
            "Authorization".to_string(),
            "Bearer mock_tid_access_token_123".to_string()
        )
    );
}

// ==============================================================================
// 5. Deezer ARL Provider Tests
// ==============================================================================

#[test]
fn test_deezer_arl_cookie_validation() {
    let valid_arl = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
    assert!(validate_arl_cookie(valid_arl));

    let short_arl = "a1b2c3d4e5";
    assert!(!validate_arl_cookie(short_arl));

    let invalid_chars = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz!@#$";
    assert!(!validate_arl_cookie(invalid_chars));
}

#[tokio::test]
async fn test_deezer_provider_stream_resolution_and_cookie_header() {
    let cred_store = Arc::new(MemoryCredentialStore::new());
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "gw-light.php",
            HttpResponse::ok_json(
                r#"{
                    "error": [],
                    "results": {
                        "checkForm": "dz_csrf_1",
                        "OFFER_NAME": "Deezer HiFi",
                        "USER": {
                            "USER_ID": 482910,
                            "BLOG_NAME": "HiFi Subscriber",
                            "OPTIONS": {
                                "web_hq": true,
                                "web_lossless": true,
                                "license_token": "lic_tok_1"
                            }
                        }
                    }
                }"#,
            ),
        )
        .await;
    transport
        .register_exact(
            "get_url",
            HttpResponse::ok_json(
                r#"{
                    "data": [{
                        "media": [{
                            "format": "FLAC",
                            "sources": [{ "url": "https://cdns-preview-d.dzcdn.net/stream/554433" }]
                        }]
                    }]
                }"#,
            ),
        )
        .await;
    let provider =
        DeezerProvider::with_transport(DeezerConfig::default(), transport, Some(cred_store));

    assert_eq!(provider.kind(), ProviderKind::Deezer);
    assert!(!provider.is_authenticated().await);

    let format = AudioFormat::cd_quality();
    let track = TrackSource::new(
        "ver-dz",
        ProviderKind::Deezer,
        "554433",
        "Track",
        1,
        1,
        200000,
        format,
    )
    .unwrap();

    assert!(provider.resolve_stream(&track).await.is_err());

    let valid_arl = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    let user = provider.login_with_arl(valid_arl).await.unwrap();
    assert!(user.can_stream_lossless);
    assert!(provider.is_authenticated().await);

    let resolved = provider.resolve_stream(&track).await.unwrap();
    assert_eq!(
        resolved.url_or_path,
        "https://cdns-preview-d.dzcdn.net/stream/554433"
    );
    assert_eq!(resolved.format.sample_rate_hz, 44100);
    assert_eq!(
        resolved.headers[0],
        ("Cookie".to_string(), format!("arl={valid_arl}"))
    );
}

// ==============================================================================
// 6. Provider Registry & Provider Manager Tests
// ==============================================================================

#[tokio::test]
async fn test_provider_registry_lifecycle() {
    let registry = ProviderRegistry::new();
    assert!(!registry.is_registered(ProviderKind::Local).await);

    let local_prov = Arc::new(LocalProvider::new(LocalProviderConfig::default()));
    registry.register(local_prov.clone()).await;

    assert!(registry.is_registered(ProviderKind::Local).await);
    let retrieved = registry.require(ProviderKind::Local).await.unwrap();
    assert_eq!(retrieved.kind(), ProviderKind::Local);

    let summaries = registry.summaries().await;
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].kind, ProviderKind::Local);

    registry.unregister(ProviderKind::Local).await;
    assert!(!registry.is_registered(ProviderKind::Local).await);
}

#[tokio::test]
async fn test_provider_manager_routing_and_fan_out() {
    let registry = ProviderRegistry::new();
    let cred_store = Arc::new(MemoryCredentialStore::new());

    // Register Qobuz with Mock Transport
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "user/get",
            HttpResponse::ok_json(
                r#"{
                    "status": "success",
                    "user": {
                        "id": 1,
                        "credential": { "parameters": { "hires": true, "max_streaming_quality": 27 } }
                    }
                }"#,
            ),
        )
        .await;

    transport
        .register_exact(
            "catalog/search",
            HttpResponse::ok_json(
                r#"{
                    "albums": {
                        "total": 1,
                        "items": [
                            {
                                "id": "alb-1",
                                "title": "Abbey Road",
                                "artist": { "name": "The Beatles" },
                                "maximum_sampling_rate": 96.0,
                                "maximum_bit_depth": 24
                            }
                        ]
                    }
                }"#,
            ),
        )
        .await;

    let qobuz = Arc::new(QobuzProvider::new(
        QobuzConfig::from_token("token_123").unwrap(),
        transport,
        Some(cred_store.clone()),
    ));
    qobuz.authenticate().await.unwrap();
    registry.register(qobuz).await;

    let manager = ProviderManager::new(registry, cred_store);

    // Search fan-out
    let search_res = manager.search("Abbey Road", 5).await;
    assert_eq!(search_res.albums.len(), 1);
    assert_eq!(search_res.albums[0].title, "Abbey Road");
    assert_eq!(search_res.albums[0].artist_name, "The Beatles");
    assert!(search_res.provider_errors.is_empty());
}

#[test]
fn test_auxiliary_types_and_helpers() {
    // COVER_ART_FILENAMES
    assert!(COVER_ART_FILENAMES.contains(&"cover.jpg"));

    // find_folder_cover on disk
    let dir = tempdir().unwrap();
    let root = dir.path();
    File::create(root.join("folder.jpg")).unwrap();
    let found = find_folder_cover(root);
    assert!(found.is_some());
    assert!(found.unwrap().to_string_lossy().contains("folder.jpg"));

    // is_token_expired
    assert!(is_token_expired(1000, 3600, 60)); // epoch 1000 is long expired
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    assert!(!is_token_expired(now, 3600, 60)); // fresh token

    // qobuz_format_ids
    assert_eq!(qobuz_format_ids::FLAC_24_192, 27);
    assert_eq!(qobuz_format_ids::FLAC_24_96, 7);
    assert_eq!(qobuz_format_ids::FLAC_16_44, 6);
    assert_eq!(qobuz_format_ids::MP3_320, 5);

    // TidalConfig & DeezerConfig
    let _t_cfg = TidalConfig::default();
    let d_cfg = DeezerConfig {
        arl: Some("1234567890abcdef1234567890abcdef".to_string()),
        ..Default::default()
    };
    let d_prov = DeezerProvider::with_config(d_cfg, None);
    assert_eq!(d_prov.kind(), ProviderKind::Deezer);

    // ProviderCapabilities
    let caps = ProviderCapabilities::tidal();
    assert!(caps.supports_oauth);
    assert!(!caps.supports_token_login);

    // MetadataExtractor non-existent file error
    let bad_path = root.join("non_existent.flac");
    assert!(MetadataExtractor::extract(&bad_path).is_err());

    // RemoteShareUri struct
    let uri = RemoteShareUri {
        protocol: "smb".to_string(),
        host: "nas.local".to_string(),
        port: 445,
        share_name: "Music".to_string(),
        relative_path: "".to_string(),
        username: None,
        password: None,
        is_authenticated: false,
        is_ssl: false,
    };
    assert_eq!(uri.port, 445);
}

// ==============================================================================
// 7. Challenger M4-1 Edge Cases: HTTPS custom ports, Symlinks, Resilience, IPv6
// ==============================================================================

#[tokio::test]
async fn test_webdav_custom_port_https_scheme() {
    let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();
    let track = TrackSource::new(
        "ver-1",
        ProviderKind::WebDav,
        "song.flac",
        "Song",
        1,
        1,
        200000,
        format.clone(),
    )
    .unwrap();

    // Standard HTTPS custom port (e.g. 8443)
    let uri_8443 = parse_remote_share_uri("https://dav.lumina.io:8443/music/").unwrap();
    assert!(uri_8443.is_ssl);
    let provider_8443 = WebDavProvider::new(WebDavConfig { uri: uri_8443 }, None);
    let res = provider_8443.resolve_stream(&track).await.unwrap();
    assert_eq!(res.url_or_path, "https://dav.lumina.io:8443/music/song.flac");

    // davs scheme on custom port 5006 (Synology)
    let uri_davs = parse_remote_share_uri("davs://dav.lumina.io:5006/music/").unwrap();
    assert!(uri_davs.is_ssl);
    let provider_davs = WebDavProvider::new(WebDavConfig { uri: uri_davs }, None);
    let res_davs = provider_davs.resolve_stream(&track).await.unwrap();
    assert_eq!(res_davs.url_or_path, "https://dav.lumina.io:5006/music/song.flac");

    // Unencrypted HTTP on custom port 8080 should remain http
    let uri_http = parse_remote_share_uri("http://dav.lumina.io:8080/music/").unwrap();
    assert!(!uri_http.is_ssl);
    let provider_http = WebDavProvider::new(WebDavConfig { uri: uri_http }, None);
    let res_http = provider_http.resolve_stream(&track).await.unwrap();
    assert_eq!(res_http.url_or_path, "http://dav.lumina.io:8080/music/song.flac");

    // dav scheme on port 80 should remain http
    let uri_dav = parse_remote_share_uri("dav://dav.lumina.io/music/").unwrap();
    assert!(!uri_dav.is_ssl);
    let provider_dav = WebDavProvider::new(WebDavConfig { uri: uri_dav }, None);
    let res_dav = provider_dav.resolve_stream(&track).await.unwrap();
    assert_eq!(res_dav.url_or_path, "http://dav.lumina.io:80/music/song.flac");
}

#[test]
fn test_directory_scanner_directory_symlink_traversal() {
    let dir = tempdir().unwrap();
    let root = dir.path().join("root");
    let outside = dir.path().join("outside");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&outside).unwrap();

    File::create(outside.join("01 - OutsideTrack.flac")).unwrap();

    let link_target = root.join("LinkedAlbum");

    #[cfg(windows)]
    {
        let status = std::process::Command::new("cmd")
            .args(["/c", "mklink", "/J", link_target.to_str().unwrap(), outside.to_str().unwrap()])
            .status();
        if status.is_err() || !status.unwrap().success() {
            return;
        }
    }
    #[cfg(unix)]
    {
        if std::os::unix::fs::symlink(&outside, &link_target).is_err() {
            return;
        }
    }

    // With follow_symlinks = false: should not find outside file
    let mut scanner_no_follow = DirectoryScanner::new(false);
    let scanned_no_follow = scanner_no_follow.scan_directory(&root);
    assert!(scanned_no_follow.is_empty(), "Should not traverse symlink when follow_symlinks = false");

    // With follow_symlinks = true: should traverse into LinkedAlbum and find 01 - OutsideTrack.flac
    let mut scanner = DirectoryScanner::new(true);
    let scanned = scanner.scan_directory(&root);
    assert_eq!(scanned.len(), 1, "DirectoryScanner must traverse symlinked directories when follow_symlinks = true");
    assert_eq!(scanned[0].file_name().unwrap(), "01 - OutsideTrack.flac");

    #[cfg(windows)]
    let _ = fs::remove_dir(&link_target);
}

#[test]
fn test_album_mapper_whitespace_tags_and_batch_resilience() {
    let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();

    // Track 1: whitespace title & empty tags, pointing to a path with derivable names
    let path1 = PathBuf::from("BandName/AlbumTitle/01 - FirstTrack.flac");
    let meta_whitespace = ExtractedMetadata {
        title: "   ".to_string(),
        artist: "  ".to_string(),
        album: "".to_string(),
        album_artist: Some("   ".to_string()),
        track_number: 1,
        disc_number: 1,
        release_year: Some(2023),
        isrc: None,
        duration_ms: 180000,
        format: format.clone(),
        cover_url: None,
        ..Default::default()
    };

    // Track 2: valid metadata
    let path2 = PathBuf::from("BandName/AlbumTitle/02 - SecondTrack.flac");
    let meta_valid = ExtractedMetadata {
        title: "Second Track".to_string(),
        artist: "BandName".to_string(),
        album: "AlbumTitle".to_string(),
        album_artist: None,
        track_number: 2,
        disc_number: 1,
        release_year: Some(2023),
        isrc: None,
        duration_ms: 210000,
        format: format.clone(),
        cover_url: None,
        ..Default::default()
    };

    let items = vec![(path1, meta_whitespace), (path2, meta_valid)];
    let (albums, tracks) = AlbumMapper::map_scanned_items(items, ProviderKind::Local).unwrap();

    assert_eq!(albums.len(), 1);
    assert_eq!(tracks.len(), 2);
    // Track 1 should have fallen back to filename-derived title "FirstTrack"
    assert_eq!(tracks[0].title, "FirstTrack");
    assert_eq!(tracks[1].title, "Second Track");
}

#[tokio::test]
async fn test_smb_and_webdav_ipv6_bracket_formatting() {
    let format = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();

    // SMB with IPv6 host and default port 445
    let smb_uri = parse_remote_share_uri("smb://[fe80::1]:445/Music/").unwrap();
    let smb_provider = SmbProvider::new(SmbConfig { uri: smb_uri, domain: None }, None);
    let track = TrackSource::new(
        "ver-1",
        ProviderKind::Smb,
        "track.flac",
        "Track",
        1,
        1,
        1000,
        format.clone(),
    )
    .unwrap();
    let smb_res = smb_provider.resolve_stream(&track).await.unwrap();
    assert_eq!(smb_res.url_or_path, "smb://[fe80::1]/Music/track.flac");

    // SMB with IPv6 host and custom port 4455
    let smb_uri_port = parse_remote_share_uri("smb://[2001:db8::1]:4455/Music/").unwrap();
    let smb_provider_port = SmbProvider::new(SmbConfig { uri: smb_uri_port, domain: None }, None);
    let smb_res_port = smb_provider_port.resolve_stream(&track).await.unwrap();
    assert_eq!(smb_res_port.url_or_path, "smb://[2001:db8::1]:4455/Music/track.flac");

    // WebDAV with IPv6 host
    let dav_uri = parse_remote_share_uri("https://[fe80::1]:8443/music/").unwrap();
    let dav_provider = WebDavProvider::new(WebDavConfig { uri: dav_uri }, None);
    let dav_res = dav_provider.resolve_stream(&track).await.unwrap();
    assert_eq!(dav_res.url_or_path, "https://[fe80::1]:8443/music/track.flac");
}

#[test]
fn test_parse_remote_share_uri_rejects_empty_host() {
    assert!(parse_remote_share_uri("smb://").is_err());
    assert!(parse_remote_share_uri("smb://:445").is_err());
    assert!(parse_remote_share_uri("https://").is_err());
    assert!(parse_remote_share_uri("davs://:8443/music").is_err());
    assert!(parse_remote_share_uri("http:///music").is_err());
    assert!(parse_remote_share_uri("dav://   ").is_err());
}

#[test]
fn test_provider_capabilities_recommendation_flags_and_serde() {
    for caps in [
        ProviderCapabilities::local(),
        ProviderCapabilities::smb(),
        ProviderCapabilities::webdav(),
    ] {
        assert!(!caps.supports_track_radio);
        assert!(!caps.supports_personal_feed);
        assert!(!caps.supports_isrc_lookup);
    }

    for caps in [
        ProviderCapabilities::qobuz(),
        ProviderCapabilities::tidal(),
        ProviderCapabilities::deezer(),
    ] {
        assert!(caps.supports_track_radio);
        assert!(caps.supports_personal_feed);
        assert!(caps.supports_isrc_lookup);

        let json = serde_json::to_string(&caps).unwrap();
        let decoded: ProviderCapabilities = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, caps);
    }

    let local = ProviderCapabilities::local();
    let local_json = serde_json::to_string(&local).unwrap();
    let local_decoded: ProviderCapabilities = serde_json::from_str(&local_json).unwrap();
    assert_eq!(local_decoded, local);

    // Legacy JSON lacking the new recommendation capability fields defaults all three to false.
    let legacy_json = r#"{
        "supports_token_login": true,
        "supports_oauth": false,
        "supports_word_lyrics": true,
        "supports_hi_res": true,
        "supports_filesystem_scan": false,
        "supports_catalog_search": true,
        "supports_stream_resolution": true,
        "supports_favorites_sync": true
    }"#;
    let legacy: ProviderCapabilities = serde_json::from_str(legacy_json).unwrap();
    assert!(!legacy.supports_track_radio);
    assert!(!legacy.supports_personal_feed);
    assert!(!legacy.supports_isrc_lookup);
}
