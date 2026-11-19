use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Write;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use core_db::credential::MemoryCredentialStore;
use core_types::{AudioCodec, AudioFormat, ProviderKind, TrackSource};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use core_providers::{
    parse_remote_share_uri, DeezerConfig, DeezerProvider, FilesystemSmbTransport, HttpRequest,
    HttpTransport, LocalProviderConfig, MockSmbTransport, MusicProvider, ProviderError,
    ProviderManager, QobuzConfig, QobuzProvider, ReqwestHttpTransport, SmbConfig, SmbEntry,
    SmbProvider, TidalConfig, TidalProvider, WebDavConfig, WebDavProvider,
};

struct MockCapturedRequest {
    method: String,
    target: String,
    headers: HashMap<String, String>,
    body: String,
}

async fn spawn_http_server<F>(handler: F) -> (String, tokio::task::JoinHandle<()>)
where
    F: Fn(MockCapturedRequest) -> (u16, Vec<(String, String)>, String) + Send + Sync + 'static,
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
                    let mut parts = req_line.split_whitespace();
                    let method = parts.next().unwrap_or("GET").to_string();
                    let target = parts.next().unwrap_or("/").to_string();

                    let mut headers = HashMap::new();
                    let mut content_length = 0usize;
                    let mut wants_close = false;
                    for line in lines {
                        if let Some((k, v)) = line.split_once(':') {
                            let kl = k.trim().to_ascii_lowercase();
                            let vt = v.trim().to_string();
                            if kl == "content-length" {
                                content_length = vt.parse::<usize>().unwrap_or(0);
                            } else if kl == "connection" && vt.eq_ignore_ascii_case("close") {
                                wants_close = true;
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
                    let body = String::from_utf8_lossy(&buf[header_end..body_end]).to_string();
                    buf.drain(..body_end);

                    let (status, resp_headers, resp_body) = h(MockCapturedRequest {
                        method,
                        target,
                        headers,
                        body,
                    });

                    let reason = match status {
                        200 => "OK",
                        207 => "Multi-Status",
                        401 => "Unauthorized",
                        403 => "Forbidden",
                        404 => "Not Found",
                        429 => "Too Many Requests",
                        _ => "Status",
                    };
                    let conn_hdr = if wants_close { "close" } else { "keep-alive" };
                    let mut raw = format!(
                        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: {conn_hdr}\r\n",
                        resp_body.len()
                    );
                    for (k, v) in resp_headers {
                        raw.push_str(&format!("{k}: {v}\r\n"));
                    }
                    raw.push_str("\r\n");
                    let mut payload = raw.into_bytes();
                    payload.extend_from_slice(resp_body.as_bytes());
                    if socket.write_all(&payload).await.is_err() {
                        return;
                    }
                    let _ = socket.flush().await;
                    if wants_close {
                        let _ = socket.shutdown().await;
                        return;
                    }
                }
            });
        }
    });

    (format!("http://127.0.0.1:{port}"), handle)
}

#[tokio::test]
async fn test_reqwest_transport_and_qobuz_live_http_flow() {
    let saw_sig = Arc::new(AtomicUsize::new(0));
    let saw_sig_clone = saw_sig.clone();

    let (base_url, server) = spawn_http_server(move |req| {
        if req.target.starts_with("/api/user/get") {
            let tok = req.headers.get("x-user-auth-token").map(String::as_str);
            if tok != Some("qb_live_tok") {
                return (401, vec![], r#"{"status":"error","message":"bad token"}"#.into());
            }
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"status":"success","user":{"id":42,"credential":{"parameters":{"hires":true,"max_streaming_quality":27}}}}"#.into(),
            );
        }
        if req.target.starts_with("/api/catalog/search") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"albums":{"total":1,"items":[{"id":"qb-alb-1","title":"Kind of Blue (Legacy Edition)","artist":{"name":"Miles Davis"},"maximum_sampling_rate":192.0,"maximum_bit_depth":24,"upc":"886443927018","release_date_original":"1959-08-17","image":{"large":"https://img.example/kob.jpg"}}]}}"#.into(),
            );
        }
        if req.target.starts_with("/api/album/get") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"id":"qb-alb-1","title":"Kind of Blue","artist":{"name":"Miles Davis"},"maximum_sampling_rate":192.0,"maximum_bit_depth":24,"release_date_original":"1959-08-17","image":{"large":"https://img.example/kob.jpg"}}"#.into(),
            );
        }
        if req.target.starts_with("/api/track/getFileUrl") {
            if req.target.contains("request_ts=") && req.target.contains("request_sig=") && req.target.contains("format_id=7") {
                saw_sig_clone.fetch_add(1, Ordering::SeqCst);
            }
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"track_id":"101","format_id":7,"mime_type":"audio/flac","sampling_rate":96.0,"bit_depth":24,"url":"http://cdn.example/101.flac"}"#.into(),
            );
        }
        if req.target.starts_with("/api/track/get") && req.target.contains("track_id=404") {
            return (404, vec![], r#"{"status":"error"}"#.into());
        }
        (404, vec![], "{}".into())
    })
    .await;

    // Test ReqwestHttpTransport directly first (without trailing slash)
    let transport = ReqwestHttpTransport::new();
    let direct_resp = transport
        .execute(
            HttpRequest::get(format!("{base_url}/api/user/get"))
                .with_header("X-User-Auth-Token", "qb_live_tok"),
        )
        .await
        .unwrap();
    assert_eq!(direct_resp.status, 200);

    // Note: base_url intentionally lacks trailing slash to verify endpoint_url normalization
    let mut cfg = QobuzConfig::from_token_with_app(
        "qb_live_tok",
        Some("12345".into()),
        Some("app_sec_xyz".into()),
    )
    .unwrap();
    cfg.base_url = format!("{base_url}/api");
    cfg.default_format_id = Some(7);

    let cred_store = Arc::new(MemoryCredentialStore::new());
    let qobuz = QobuzProvider::live(cfg, Some(cred_store));

    let session = qobuz.authenticate().await.unwrap();
    assert_eq!(session.user_id, 42);

    let albums = qobuz.search("Kind of Blue", 5).await.unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].title, "Kind of Blue");
    assert_eq!(albums[0].release_year, Some(1959));
    assert_eq!(albums[0].versions[0].edition_label.as_deref(), Some("Legacy Edition"));

    let fetched_album = qobuz.get_album("qb-alb-1").await.unwrap();
    assert_eq!(fetched_album.cover_url.as_deref(), Some("https://img.example/kob.jpg"));

    let err_404 = qobuz.get_track("404").await.unwrap_err();
    assert!(matches!(err_404, ProviderError::TrackNotFound(_)));

    let fmt = AudioFormat::pcm(AudioCodec::Flac, 192000, 24, 2).unwrap();
    let trk = TrackSource::new("v1", ProviderKind::Qobuz, "101", "So What", 1, 1, 540000, fmt)
        .unwrap()
        .with_replay_gain(Some(-5.2), Some(-6.0), Some(0.92), Some(0.95));

    let resolved = qobuz.resolve_stream(&trk).await.unwrap();
    assert_eq!(resolved.url_or_path, "http://cdn.example/101.flac");
    assert_eq!(resolved.format.sample_rate_hz, 96000);
    assert_eq!(resolved.replay_gain_track_db, Some(-5.2));
    assert_eq!(resolved.replay_gain_album_peak, Some(0.95));
    assert_eq!(saw_sig.load(Ordering::SeqCst), 1);

    server.abort();
}

#[tokio::test]
async fn test_tidal_live_pkce_refresh_search_and_bts_manifest() {
    let refresh_calls = Arc::new(AtomicUsize::new(0));
    let refresh_calls_c = refresh_calls.clone();

    let bts_json = serde_json::json!({
        "mimeType": "audio/flac",
        "codecs": "flac",
        "encryptionType": "NONE",
        "urls": ["https://sp-cf.tidal.com/audio/777.flac"]
    })
    .to_string();
    let bts_b64 = STANDARD.encode(bts_json.as_bytes());

    let (base_url, server) = spawn_http_server(move |req| {
        if req.target == "/auth/token" && req.method == "POST" {
            if req.body.contains("grant_type=authorization_code") {
                return (
                    200,
                    vec![("Content-Type".into(), "application/json".into())],
                    r#"{"access_token":"tid_acc_1","refresh_token":"tid_ref_1","token_type":"Bearer","expires_in":10,"user_id":9001}"#.into(),
                );
            }
            if req.body.contains("grant_type=refresh_token") {
                refresh_calls_c.fetch_add(1, Ordering::SeqCst);
                return (
                    200,
                    vec![("Content-Type".into(), "application/json".into())],
                    r#"{"access_token":"tid_acc_refreshed","token_type":"Bearer","expires_in":3600,"user_id":9001}"#.into(),
                );
            }
        }
        if req.target.starts_with("/v1/search/albums") {
            let auth = req.headers.get("authorization").map(String::as_str);
            if auth != Some("Bearer tid_acc_refreshed") {
                return (401, vec![], "{}".into());
            }
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"items":[{"id":888,"title":"Aja (Remastered)","artist":{"name":"Steely Dan"},"releaseDate":"1977-09-23","audioQuality":"HI_RES_LOSSLESS","cover":"abcd-1234"}]}"#.into(),
            );
        }
        if req.target.starts_with("/v1/tracks/777/playbackinfo") {
            let body = serde_json::json!({
                "audioQuality": "HI_RES_LOSSLESS",
                "sampleRate": 96000,
                "bitDepth": 24,
                "manifestMimeType": "application/vnd.tidal.bts",
                "manifest": bts_b64,
                "trackReplayGain": -4.8,
                "albumReplayGain": -5.1,
                "trackPeakAmplitude": 0.98
            })
            .to_string();
            return (200, vec![("Content-Type".into(), "application/json".into())], body);
        }
        if req.target.starts_with("/v1/tracks/666/playbackinfo") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"manifestMimeType":"application/dash+xml","manifest":"PE1QRD4="}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let cfg = TidalConfig {
        auth_base_url: format!("{base_url}/auth"),
        api_base_url: format!("{base_url}/v1"),
        ..Default::default()
    };
    let cred_store = Arc::new(MemoryCredentialStore::new());
    let tidal = TidalProvider::live(cfg, Some(cred_store));

    let pkce = tidal.start_pkce_login().await;
    assert!(pkce.auth_url.starts_with(&format!("{base_url}/auth/authorize")));

    let tokens = tidal.exchange_pkce_code("auth_code_xyz", &pkce.verifier).await.unwrap();
    assert_eq!(tokens.access_token, "tid_acc_1");
    assert_eq!(tokens.user_id, 9001);

    // Trigger auto-refresh because expires_in=10 is inside 60s skew window
    let albums = tidal.search("Aja", 5).await.unwrap();
    assert_eq!(refresh_calls.load(Ordering::SeqCst), 1);
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].title, "Aja");
    assert_eq!(albums[0].versions[0].edition_label.as_deref(), Some("Remastered"));

    let fmt = AudioFormat::pcm(AudioCodec::Flac, 96000, 24, 2).unwrap();
    let trk = TrackSource::new("v1", ProviderKind::Tidal, "777", "Aja", 1, 1, 470000, fmt.clone()).unwrap();
    let resolved = tidal.resolve_stream(&trk).await.unwrap();
    assert_eq!(resolved.url_or_path, "https://sp-cf.tidal.com/audio/777.flac");
    assert_eq!(resolved.replay_gain_track_db, Some(-4.8));
    assert_eq!(resolved.replay_gain_album_db, Some(-5.1));
    assert_eq!(resolved.replay_gain_track_peak, Some(0.98));

    let drm_trk = TrackSource::new("v1", ProviderKind::Tidal, "666", "DRM", 1, 2, 1000, fmt).unwrap();
    let drm_err = tidal.resolve_stream(&drm_trk).await.unwrap_err();
    assert!(matches!(drm_err, ProviderError::DrmRestricted(_)));

    server.abort();
}

#[tokio::test]
async fn test_deezer_live_arl_search_and_media_resolution() {
    let (base_url, server) = spawn_http_server(move |req| {
        if req.target.contains("method=deezer.getUserData") {
            let cookie = req.headers.get("cookie").map(String::as_str).unwrap_or("");
            if cookie.contains("00000000000000000000000000000000") {
                return (
                    200,
                    vec![("Content-Type".into(), "application/json".into())],
                    r#"{"error":[],"results":{"USER":{"USER_ID":0}}}"#.into(),
                );
            }
            return (
                200,
                vec![
                    ("Content-Type".into(), "application/json".into()),
                    ("Set-Cookie".into(), "sid=dz_sid_99; Path=/".into()),
                ],
                r#"{"error":[],"results":{"checkForm":"tok_form_1","OFFER_NAME":"Deezer HiFi","USER":{"USER_ID":777,"BLOG_NAME":"AudUser","OPTIONS":{"web_hq":true,"web_lossless":true,"license_token":"lic_123"}}}}"#.into(),
            );
        }
        if req.target.contains("method=song.getData") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"error":[],"results":{"TRACK_TOKEN":"trk_tok_abc","GAIN":-6.4}}"#.into(),
            );
        }
        if req.target.starts_with("/api/search/album") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"data":[{"id":302127,"title":"Discovery","artist":{"name":"Daft Punk"},"cover_xl":"https://e-cdns-images.dzcdn.net/discovery.jpg"}]}"#.into(),
            );
        }
        if req.target == "/media/get_url" {
            assert!(req.body.contains("trk_tok_abc"));
            assert!(req.body.contains("lic_123"));
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"data":[{"media":[{"format":"FLAC","sources":[{"url":"https://e-cdns-proxy.dzcdn.net/stream/discovery_01.flac"}]}]}]}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let cfg = DeezerConfig {
        arl: None,
        api_base_url: format!("{base_url}/api"),
        gw_base_url: format!("{base_url}/gw"),
        media_base_url: format!("{base_url}/media/get_url"),
    };
    let cred_store = Arc::new(MemoryCredentialStore::new());
    let deezer = DeezerProvider::with_config(cfg, Some(cred_store));

    // Invalid USER_ID == 0 must fail
    let bad_err = deezer
        .login_with_arl("00000000000000000000000000000000")
        .await
        .unwrap_err();
    assert!(matches!(bad_err, ProviderError::AuthenticationFailed(_)));

    let valid_arl = "abcdef1234567890abcdef1234567890";
    let user = deezer.login_with_arl(valid_arl).await.unwrap();
    assert_eq!(user.id, 777);
    assert!(user.can_stream_lossless);

    let albums = deezer.search("Discovery", 5).await.unwrap();
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].title, "Discovery");
    assert_eq!(albums[0].artist_name, "Daft Punk");

    let trk = TrackSource::new(
        "v1",
        ProviderKind::Deezer,
        "3135556",
        "One More Time",
        1,
        1,
        320000,
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let resolved = deezer.resolve_stream(&trk).await.unwrap();
    assert_eq!(
        resolved.url_or_path,
        "https://e-cdns-proxy.dzcdn.net/stream/discovery_01.flac"
    );
    assert_eq!(resolved.replay_gain_track_db, Some(-6.4));
    assert_eq!(
        resolved.headers[0],
        ("Cookie".to_string(), format!("arl={valid_arl}"))
    );

    server.abort();
}

#[tokio::test]
async fn test_webdav_live_propfind_xml_scan_search_and_stream() {
    let (base_url, server) = spawn_http_server(move |req| {
        assert_eq!(req.method, "PROPFIND");
        assert_eq!(req.headers.get("depth").map(String::as_str), Some("1"));
        let auth = req.headers.get("authorization").map(String::as_str);
        if auth != Some("Basic dXNlcjpwYXNz") {
            return (401, vec![], "Unauthorized".into());
        }

        let xml = match req.target.as_str() {
            "/music/" => r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/music/Talk%20Talk/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/music/.Trash/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
</D:multistatus>"#,
            "/music/Talk%20Talk/" | "/music/Talk Talk/" => r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/music/Talk%20Talk/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
</D:multistatus>"#,
            "/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/" | "/music/Talk Talk/Spirit of Eden (Remastered)/" => r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
  <D:response><D:href>/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/01%20-%20The%20Rainbow.flac</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
  <D:response><D:href>/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/cover.jpg</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
  <D:response><D:href>/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/.hidden.flac</D:href><D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat></D:response>
</D:multistatus>"#,
            _ => return (404, vec![], "Not found".into()),
        };

        (
            207,
            vec![("Content-Type".into(), "application/xml; charset=utf-8".into())],
            xml.into(),
        )
    })
    .await;

    let host_port = base_url.strip_prefix("http://").unwrap();
    let dav_uri = parse_remote_share_uri(&format!("http://user:pass@{host_port}/music/")).unwrap();
    let webdav = WebDavProvider::new(WebDavConfig { uri: dav_uri }, None);

    let sync = webdav.sync_library().await.unwrap();
    assert_eq!(sync.albums.len(), 1);
    assert_eq!(sync.tracks.len(), 1);
    assert_eq!(sync.albums[0].title, "Spirit of Eden");
    assert_eq!(sync.albums[0].artist_name, "Talk Talk");
    assert_eq!(sync.albums[0].versions[0].edition_label.as_deref(), Some("Remastered"));
    assert!(sync.albums[0]
        .cover_url
        .as_deref()
        .unwrap()
        .ends_with("/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/cover.jpg"));
    assert_eq!(sync.tracks[0].title, "The Rainbow");

    let search = webdav.search("Spirit", 10).await.unwrap();
    assert_eq!(search.len(), 1);

    let stream = webdav.resolve_stream(&sync.tracks[0]).await.unwrap();
    assert!(stream
        .url_or_path
        .ends_with("/music/Talk%20Talk/Spirit%20of%20Eden%20(Remastered)/01%20-%20The%20Rainbow.flac"));
    assert_eq!(stream.headers[0].0, "Authorization");

    server.abort();
}

#[tokio::test]
async fn test_smb_filesystem_and_mock_transports_plus_manager() {
    let dir = tempdir().unwrap();
    let alb_dir = dir.path().join("Miles Davis").join("Ascenseur");
    fs::create_dir_all(&alb_dir).unwrap();
    // Create a minimal valid synthetic FLAC file for MetadataExtractor
    let flac_bytes = build_minimal_flac();
    let file_path = alb_dir.join("01 - Generique.flac");
    File::create(&file_path).unwrap().write_all(&flac_bytes).unwrap();

    let smb_uri = parse_remote_share_uri("smb://user:pass@nas.local/Music/").unwrap();
    let fs_transport = Arc::new(FilesystemSmbTransport::new(dir.path()));
    let smb = SmbProvider::with_transport(
        SmbConfig {
            uri: smb_uri.clone(),
            domain: None,
        },
        fs_transport,
        None,
    );

    let sync = smb.sync_library().await.unwrap();
    assert_eq!(sync.albums.len(), 1);
    assert_eq!(sync.tracks.len(), 1);
    assert_eq!(sync.tracks[0].title, "Generique");

    let stream = smb.resolve_stream(&sync.tracks[0]).await.unwrap();
    assert!(stream.is_local_file());

    let found = smb.search("Ascenseur", 5).await.unwrap();
    assert_eq!(found.len(), 1);

    // MockSmbTransport + ProviderManager orchestration
    let mock_smb = Arc::new(MockSmbTransport::new());
    mock_smb
        .add_entry(SmbEntry {
            relative_path: "Artist/Album/01 - Mock.flac".to_string(),
            local_path: None,
            metadata: None,
        })
        .await;

    let manager = ProviderManager::with_credential_store(Arc::new(MemoryCredentialStore::new()));
    manager
        .configure_smb(
            SmbConfig {
                uri: smb_uri,
                domain: None,
            },
            Some(mock_smb),
        )
        .await;
    manager.configure_local(LocalProviderConfig::default()).await;

    let smb_sync = manager.sync_provider(ProviderKind::Smb).await.unwrap();
    assert_eq!(smb_sync.tracks.len(), 1);
    assert_eq!(smb_sync.tracks[0].external_track_id, "Artist/Album/01 - Mock.flac");
}

fn build_minimal_flac() -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"fLaC");
    // STREAMINFO block (last block = 0x80 | 0, length = 34)
    out.extend_from_slice(&[0x80, 0x00, 0x00, 0x22]);
    let mut si = [0u8; 34];
    si[0..2].copy_from_slice(&4096u16.to_be_bytes());
    si[2..4].copy_from_slice(&4096u16.to_be_bytes());
    // sample rate 44100 (20 bits), channels-1 = 1 (3 bits), bps-1 = 15 (5 bits), total_samples = 44100 (36 bits)
    let packed: u64 = (44100u64 << 44) | (1u64 << 41) | (15u64 << 36) | 44100u64;
    si[10..18].copy_from_slice(&packed.to_be_bytes());
    out.extend_from_slice(&si);
    // Minimal FLAC frame header + CRC8
    let hdr = [0xFFu8, 0xF8, 0xC9, 0x18, 0x00];
    let crc = crc8(&hdr);
    out.extend_from_slice(&hdr);
    out.push(crc);
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]);
    out
}

#[tokio::test]
async fn test_webdav_hardening_encoding_prefix_status_dotdir_and_truncated_xml() {
    let dir_a_hits = Arc::new(AtomicUsize::new(0));
    let dir_a_hits_c = dir_a_hits.clone();
    let seen_stream_target = Arc::new(tokio::sync::Mutex::new(String::new()));
    let seen_stream_target_c = seen_stream_target.clone();

    let (base_url, server) = spawn_http_server(move |req| {
        if req.method == "GET" {
            *seen_stream_target_c.try_lock().unwrap() = req.target.clone();
            return (200, vec![], "AUDIO_OK".into());
        }

        assert_eq!(req.method, "PROPFIND");
        match req.target.as_str() {
            "/My%20Music/" => (
                207,
                vec![("Content-Type".into(), "application/xml".into())],
                r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/My%20Music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/dir%20a/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/dir a/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/.hidden_dir/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:displayname>VisibleName</D:displayname></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/unreadable.flac</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/forbidden.flac</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music-alt/other.flac</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"#.into(),
            ),
            "/My%20Music/dir%20a/" => {
                dir_a_hits_c.fetch_add(1, Ordering::SeqCst);
                (
                    207,
                    vec![("Content-Type".into(), "application/xml".into())],
                    r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/My%20Music/dir%20a/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/dir%20a/Album%20%231/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"#.into(),
                )
            }
            "/My%20Music/dir%20a/Album%20%231/" => (
                207,
                vec![("Content-Type".into(), "application/xml".into())],
                r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/My%20Music/dir%20a/Album%20%231/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/My%20Music/dir%20a/Album%20%231/01%20-%20Song%20%231%3F.flac</D:href><D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"#.into(),
            ),
            "/truncated/" => (
                207,
                vec![("Content-Type".into(), "application/xml".into())],
                r#"<D:multistatus xmlns:D="DAV:"><D:response><D:href>/truncated/a.flac</D:href>"#.into(),
            ),
            _ => (404, vec![], "Not found".into()),
        }
    })
    .await;

    let host_port = base_url.strip_prefix("http://").unwrap();
    let dav_uri = parse_remote_share_uri(&format!("http://{host_port}/My%20Music/")).unwrap();
    let webdav = WebDavProvider::new(WebDavConfig { uri: dav_uri }, None);

    let sync = webdav.sync_library().await.unwrap();
    // /dir%20a/ and /dir a/ must share the normalized decoded visited key -> crawled once
    assert_eq!(dir_a_hits.load(Ordering::SeqCst), 1);

    // 404/403 propstats and .hidden_dir must be excluded; /My Music-alt/ must NOT have /My Music stripped
    let track_ids: Vec<&str> = sync
        .tracks
        .iter()
        .map(|t| t.external_track_id.as_str())
        .collect();
    assert!(!track_ids.iter().any(|id| id.contains("unreadable")));
    assert!(!track_ids.iter().any(|id| id.contains("forbidden")));
    assert!(!track_ids.iter().any(|id| id.contains(".hidden_dir")));
    assert!(track_ids.contains(&"My Music-alt/other.flac"));

    let special_track = sync
        .tracks
        .iter()
        .find(|t| t.external_track_id.contains("Song #1?.flac"))
        .expect("track with # and ? must be scanned");
    assert_eq!(special_track.external_track_id, "dir a/Album #1/01 - Song #1?.flac");

    // resolve_stream percent-encodes #, ?, spaces and never doubles "My%20Music"
    let resolved = webdav.resolve_stream(special_track).await.unwrap();
    assert_eq!(
        resolved.url_or_path,
        format!("{base_url}/My%20Music/dir%20a/Album%20%231/01%20-%20Song%20%231%3F.flac")
    );

    // Execute GET over ReqwestHttpTransport to verify wire request is not truncated at '#'
    let transport = ReqwestHttpTransport::new();
    let get_resp = transport
        .execute(HttpRequest::get(&resolved.url_or_path))
        .await
        .unwrap();
    assert_eq!(get_resp.status, 200);
    assert_eq!(
        seen_stream_target.lock().await.as_str(),
        "/My%20Music/dir%20a/Album%20%231/01%20-%20Song%20%231%3F.flac"
    );

    // Truncated XML must fail with ProviderError::ScanError
    let trunc_uri = parse_remote_share_uri(&format!("http://{host_port}/truncated/")).unwrap();
    let trunc_dav = WebDavProvider::new(WebDavConfig { uri: trunc_uri }, None);
    let trunc_err = trunc_dav.sync_library().await.unwrap_err();
    assert!(matches!(trunc_err, ProviderError::ScanError(_)));

    server.abort();
}

#[tokio::test]
async fn test_qobuz_token_is_authenticated_and_manager_anonymous_lan_resolve_stream() {
    let (base_url, server) = spawn_http_server(move |req| {
        if req.target.starts_with("/api/track/getFileUrl") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"track_id":"101","format_id":27,"mime_type":"audio/flac","sampling_rate":96.0,"bit_depth":24,"url":"http://cdn.example/101.flac"}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    // 1. QobuzProvider::is_authenticated returns true with inline QobuzAuthMode::Token even without authenticate()
    let mut q_cfg = QobuzConfig::from_token("tok_inline_only").unwrap();
    q_cfg.base_url = format!("{base_url}/api");
    let q_prov = QobuzProvider::live(q_cfg.clone(), None);
    assert!(q_prov.is_authenticated().await);

    let manager = ProviderManager::with_credential_store(Arc::new(MemoryCredentialStore::new()));
    manager.configure_qobuz(q_cfg, false).await.unwrap();

    let fmt = AudioFormat::cd_quality();
    let q_trk = TrackSource::new("v1", ProviderKind::Qobuz, "101", "Song", 1, 1, 1000, fmt.clone()).unwrap();
    let q_stream = manager.resolve_stream(&q_trk).await.unwrap();
    assert_eq!(q_stream.url_or_path, "http://cdn.example/101.flac");

    // 2. Anonymous SMB and WebDAV shares resolve streams via ProviderManager without Unauthenticated error
    let smb_uri = parse_remote_share_uri("smb://nas.local/PublicShare/").unwrap();
    let mock_smb = Arc::new(MockSmbTransport::new());
    manager
        .configure_smb(
            SmbConfig {
                uri: smb_uri,
                domain: None,
            },
            Some(mock_smb),
        )
        .await;
    let smb_trk = TrackSource::new("v2", ProviderKind::Smb, "Artist/Track.flac", "Track", 1, 1, 1000, fmt.clone()).unwrap();
    let smb_stream = manager.resolve_stream(&smb_trk).await.unwrap();
    assert_eq!(smb_stream.url_or_path, "smb://nas.local/PublicShare/Artist/Track.flac");

    let dav_uri = parse_remote_share_uri("http://127.0.0.1:9999/public/").unwrap();
    manager.configure_webdav(WebDavConfig { uri: dav_uri }).await;
    let dav_trk = TrackSource::new("v3", ProviderKind::WebDav, "Artist/Track.flac", "Track", 1, 1, 1000, fmt.clone()).unwrap();
    let dav_stream = manager.resolve_stream(&dav_trk).await.unwrap();
    assert_eq!(dav_stream.url_or_path, "http://127.0.0.1:9999/public/Artist/Track.flac");

    // 3. Unauthenticated streaming provider (Tidal) is still gated with Unauthenticated
    let tidal_trk = TrackSource::new("v4", ProviderKind::Tidal, "999", "Tidal Track", 1, 1, 1000, fmt).unwrap();
    manager.register_provider(Arc::new(TidalProvider::new(None))).await;
    let tidal_err = manager.resolve_stream(&tidal_trk).await.unwrap_err();
    assert!(matches!(tidal_err, ProviderError::Unauthenticated(_)));

    server.abort();
}

#[tokio::test]
async fn test_deezer_media_fallback_and_non_lossless_codec_inference() {
    let (base_url, server) = spawn_http_server(move |req| {
        if req.target.contains("method=deezer.getUserData") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"error":[],"results":{"checkForm":"tok_form_2","OFFER_NAME":"Deezer Free","USER":{"USER_ID":888,"BLOG_NAME":"StdUser","OPTIONS":{"web_hq":true,"web_lossless":false,"license_token":"lic_std"}}}}"#.into(),
            );
        }
        if req.target.contains("method=song.getData") {
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"error":[],"results":{"TRACK_TOKEN":"trk_tok_std"}}"#.into(),
            );
        }
        if req.target == "/media/get_url" {
            if req.body.contains("trk_tok_std") && req.body.contains("lic_std") {
                static MEDIA_CALLS: std::sync::atomic::AtomicUsize =
                    std::sync::atomic::AtomicUsize::new(0);
                let call = MEDIA_CALLS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                if call == 0 {
                    return (
                        200,
                        vec![("Content-Type".into(), "application/json".into())],
                        r#"{"data":[{"media":[{"format":"FLAC","sources":[]},{"format":"MP3_320","sources":[{"url":"https://cdn.dz/ok.mp3"}]}]}]}"#.into(),
                    );
                }
                return (
                    200,
                    vec![("Content-Type".into(), "application/json".into())],
                    r#"{"url":"https://cdn.dz/simple.mp3"}"#.into(),
                );
            }
            return (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"url":"https://cdn.dz/simple.mp3"}"#.into(),
            );
        }
        (404, vec![], "{}".into())
    })
    .await;

    let cfg = DeezerConfig {
        arl: None,
        api_base_url: format!("{base_url}/api"),
        gw_base_url: format!("{base_url}/gw"),
        media_base_url: format!("{base_url}/media/get_url"),
    };
    let deezer = DeezerProvider::with_config(cfg, None);
    let arl = "abcdef1234567890abcdef1234567890";
    let user = deezer.login_with_arl(arl).await.unwrap();
    assert!(!user.can_stream_lossless);

    // 1. Media fallback: media[0] has empty sources, media[1] has MP3_320 URL
    let trk = TrackSource::new("v1", ProviderKind::Deezer, "111", "Fallback Track", 1, 1, 200000, AudioFormat::cd_quality()).unwrap();
    let res = deezer.resolve_stream(&trk).await.unwrap();
    assert_eq!(res.url_or_path, "https://cdn.dz/ok.mp3");
    assert_eq!(res.format.codec, AudioCodec::Mp3);
    assert_eq!(res.hint_extension.as_deref(), Some("mp3"));

    // 2. Simplified {"url": ...} response infers MP3 when can_stream_lossless == false
    let res_simple = deezer.resolve_stream(&trk).await.unwrap();
    assert_eq!(res_simple.url_or_path, "https://cdn.dz/simple.mp3");
    assert_eq!(res_simple.format.codec, AudioCodec::Mp3);
    assert_eq!(res_simple.hint_extension.as_deref(), Some("mp3"));

    server.abort();
}

fn crc8(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &b in data {
        crc ^= b;
        for _ in 0..8 {
            if (crc & 0x80) != 0 {
                crc = (crc << 1) ^ 0x07;
            } else {
                crc <<= 1;
            }
        }
    }
    crc
}
