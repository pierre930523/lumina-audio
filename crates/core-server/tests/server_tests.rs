use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode, header};
use core_server::ServerConfig;
use core_server::discovery::MdnsConfig;
use core_server::error::ServerError;
use core_server::pairing::qr::{generate_qr_pairing_uri, validate_qr_pairing_uri};
use core_server::pairing::{PinPairingManager, validate_pin_format};
use core_server::routes::build_router;
use core_server::state::AppState;
use core_server::ws::messages::{PlaybackStatePayload, WsMessage};
use std::sync::Arc;
use tower::ServiceExt;

#[test]
fn test_server_config_defaults() {
    let cfg = ServerConfig::default();
    assert_eq!(cfg.bind_addr.to_string(), "0.0.0.0:9888");
    assert!(cfg.enable_mdns);
}

#[tokio::test]
async fn test_pin_pairing_flow_and_replay_prevention() {
    let manager = PinPairingManager::new(60.0, 5, None);
    let pin = manager.generate_pin("iPhone").await;

    assert_eq!(pin.len(), 6);
    assert!(validate_pin_format(&pin));

    // Valid pairing
    let token = manager
        .attempt_pairing("192.168.1.10", "client-1", "iPhone", "iOS", &pin)
        .await
        .expect("Valid PIN pairing should succeed");

    assert!(token.starts_with("lum_sec_"));
    assert!(manager.is_token_valid(&token).await);

    // Replay with consumed PIN must fail
    let replay = manager
        .attempt_pairing("192.168.1.10", "client-1", "iPhone", "iOS", &pin)
        .await;
    assert!(matches!(replay, Err(ServerError::PinNotFoundOrExpired)));
}

#[tokio::test]
async fn test_pin_rate_limiter_lockout() {
    let manager = PinPairingManager::new(60.0, 5, None);
    let malicious_ip = "192.168.1.200";

    // 5 consecutive wrong PINs
    for _ in 0..5 {
        let res = manager
            .attempt_pairing(malicious_ip, "attacker", "device", "linux", "000000")
            .await;
        assert!(res.is_err());
    }

    // 6th attempt should be locked out
    let locked_res = manager
        .attempt_pairing(malicious_ip, "attacker", "device", "linux", "123456")
        .await;
    assert!(matches!(locked_res, Err(ServerError::IpLockedOut)));
}

#[test]
fn test_qr_pairing_uri_contracts() {
    let uri = generate_qr_pairing_uri("849201", "192.168.1.100", 9888, None);
    assert_eq!(uri, "lumina://pair?pin=849201&host=192.168.1.100&port=9888");
    assert!(validate_qr_pairing_uri(&uri));

    let uri_nonce = generate_qr_pairing_uri("849201", "192.168.1.100", 9888, Some("abc123nonce"));
    assert!(validate_qr_pairing_uri(&uri_nonce));
}

#[test]
fn test_mdns_config_attributes() {
    let mdns = MdnsConfig::default();
    assert_eq!(mdns.service_type, "_lumina._tcp.local.");
    assert_eq!(mdns.port, 9888);
    assert_eq!(
        mdns.txt_records.get("server_name").unwrap(),
        "Lumina-Desktop"
    );
    assert_eq!(mdns.txt_records.get("version").unwrap(), "0.1.0");
    assert_eq!(mdns.txt_records.get("api_version").unwrap(), "1");
    assert_eq!(mdns.txt_records.get("pairing_required").unwrap(), "true");
}

#[tokio::test]
async fn test_axum_router_pairing_and_auth_middleware() {
    let state = Arc::new(AppState::new(None));
    let app = build_router(state.clone());

    // 1. Unauthenticated request to /api/v1/playback/state must return 401 Unauthorized
    let unauth_req = Request::builder()
        .uri("/api/v1/playback/state")
        .method("GET")
        .body(Body::empty())
        .unwrap();

    let response = app.clone().oneshot(unauth_req).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    // 2. Initiate pairing via POST /api/v1/pair/initiate
    let init_req = Request::builder()
        .uri("/api/v1/pair/initiate")
        .method("POST")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"device_name": "Test-Client"}"#))
        .unwrap();

    let init_resp = app.clone().oneshot(init_req).await.unwrap();
    assert_eq!(init_resp.status(), StatusCode::OK);
    let init_bytes = to_bytes(init_resp.into_body(), 1024 * 1024).await.unwrap();
    let init_val: serde_json::Value = serde_json::from_slice(&init_bytes).unwrap();
    let pin = init_val["pin"].as_str().expect("valid pin returned");

    // 3. Verify pairing via POST /api/v1/pair/verify
    let verify_body = format!(
        r#"{{"pin": "{}", "client_id": "c1", "device_name": "Test-Client", "platform": "desktop"}}"#,
        pin
    );
    let verify_req = Request::builder()
        .uri("/api/v1/pair/verify")
        .method("POST")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(verify_body))
        .unwrap();

    let verify_resp = app.clone().oneshot(verify_req).await.unwrap();
    assert_eq!(verify_resp.status(), StatusCode::OK);
    let verify_bytes = to_bytes(verify_resp.into_body(), 1024 * 1024)
        .await
        .unwrap();
    let verify_val: serde_json::Value = serde_json::from_slice(&verify_bytes).unwrap();
    let token = verify_val["token"].as_str().expect("valid token returned");

    // 4. Authenticated request to /api/v1/playback/state with Bearer token must succeed (200 OK)
    let auth_req = Request::builder()
        .uri("/api/v1/playback/state")
        .method("GET")
        .header(header::AUTHORIZATION, format!("Bearer {}", token))
        .body(Body::empty())
        .unwrap();

    let auth_resp = app.clone().oneshot(auth_req).await.unwrap();
    assert_eq!(auth_resp.status(), StatusCode::OK);

    // 5. Authenticated request to /api/v1/playback/play must succeed
    let play_req = Request::builder()
        .uri("/api/v1/playback/play")
        .method("POST")
        .header(header::AUTHORIZATION, format!("Bearer {}", token))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(r#"{"track_id": "trk-001"}"#))
        .unwrap();

    let play_resp = app.clone().oneshot(play_req).await.unwrap();
    assert_eq!(play_resp.status(), StatusCode::OK);

    // 6. Check updated state
    let state_req = Request::builder()
        .uri("/api/v1/playback/state")
        .method("GET")
        .header(header::AUTHORIZATION, format!("Bearer {}", token))
        .body(Body::empty())
        .unwrap();

    let state_resp = app.clone().oneshot(state_req).await.unwrap();
    assert_eq!(state_resp.status(), StatusCode::OK);
    let state_bytes = to_bytes(state_resp.into_body(), 1024 * 1024).await.unwrap();
    let state_val: serde_json::Value = serde_json::from_slice(&state_bytes).unwrap();
    assert_eq!(state_val["status"], "playing");
    assert_eq!(state_val["track_id"], "trk-001");
}

#[tokio::test]
async fn test_cors_headers_present() {
    let state = Arc::new(AppState::new(None));
    let app = build_router(state);

    let req = Request::builder()
        .uri("/api/v1/pair/initiate")
        .method("OPTIONS")
        .header(header::ORIGIN, "http://localhost:3000")
        .header(header::ACCESS_CONTROL_REQUEST_METHOD, "POST")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        resp.headers()
            .get(header::ACCESS_CONTROL_ALLOW_ORIGIN)
            .unwrap(),
        "*"
    );
}

#[test]
fn test_ws_message_serialization() {
    let ws_msg = WsMessage::PlaybackStateChanged {
        payload: PlaybackStatePayload {
            status: "playing".to_string(),
            track_id: Some("trk-001".to_string()),
            position_ms: 12500,
            duration_ms: 163000,
            ..Default::default()
        },
    };

    let serialized = serde_json::to_string(&ws_msg).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&serialized).unwrap();
    assert_eq!(parsed["type"], "PlaybackStateChanged");
    assert_eq!(parsed["payload"]["status"], "playing");
    assert_eq!(parsed["payload"]["track_id"], "trk-001");
    assert_eq!(parsed["payload"]["position_ms"], 12500);
    assert_eq!(parsed["payload"]["duration_ms"], 163000);
}

fn write_test_wav(path: &std::path::Path, sample_rate: u32, channels: u16, num_frames: u32) {
    let mut buf = Vec::new();
    let block_align = channels * 2;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = num_frames * (block_align as u32);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    for n in 0..num_frames {
        let t = n as f64 / sample_rate as f64;
        let sample = ((2.0 * std::f64::consts::PI * 440.0 * t).sin() * 20000.0) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample.to_le_bytes());
        }
    }
    std::fs::write(path, buf).unwrap();
}

#[tokio::test]
async fn test_server_sqlite_scan_search_tracks_and_headless_playback() {
    let pool = core_db::open_test_database()
        .await
        .expect("open in-memory test DB");
    let player = core_audio::AudioPlayer::new_headless();
    let state = Arc::new(AppState::with_player(Some(pool), Some(player.clone())));
    let app = build_router(state);

    // Pair client
    let init_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/initiate")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    let init_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(init_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    let pin = init_val["pin"].as_str().unwrap();

    let verify_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/verify")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    let verify_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(verify_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    let token = verify_val["token"].as_str().unwrap().to_string();

    // Create temp music folder Artist/Album/01 - Dawn.wav
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root_dir = std::env::temp_dir().join(format!("lumina_srv_scan_{ts}"));
    let album_dir = root_dir.join("Pink Floyd").join("Meddle");
    std::fs::create_dir_all(&album_dir).unwrap();
    write_test_wav(&album_dir.join("01 - Dawn.wav"), 48_000, 2, 96_000);

    // POST /api/v1/library/scan
    let scan_req = Request::builder()
        .uri("/api/v1/library/scan")
        .method("POST")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            serde_json::json!({"path": root_dir.to_string_lossy()}).to_string(),
        ))
        .unwrap();
    let scan_resp = app.clone().oneshot(scan_req).await.unwrap();
    assert_eq!(scan_resp.status(), StatusCode::OK);
    let scan_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(scan_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    assert_eq!(scan_val["tracks_count"], 1);
    assert_eq!(scan_val["albums_count"], 1);

    // GET /api/v1/library/albums
    let albums_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/albums")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(albums_resp.status(), StatusCode::OK);
    let albums: serde_json::Value =
        serde_json::from_slice(&to_bytes(albums_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(albums.as_array().unwrap().len(), 1);
    assert_eq!(albums[0]["title"], "Meddle");
    assert_eq!(albums[0]["artist"], "Pink Floyd");

    // GET /api/v1/library/tracks
    let tracks_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/tracks")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(tracks_resp.status(), StatusCode::OK);
    let tracks: serde_json::Value =
        serde_json::from_slice(&to_bytes(tracks_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    let track_id = tracks[0]["id"].as_str().unwrap().to_string();
    assert_eq!(tracks[0]["sample_rate_hz"], 48_000);

    // GET /api/v1/library/search?q=Dawn
    let search_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/search?q=Dawn")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(search_resp.status(), StatusCode::OK);
    let search_hits: serde_json::Value =
        serde_json::from_slice(&to_bytes(search_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert!(!search_hits.as_array().unwrap().is_empty());

    // POST /api/v1/playback/play
    let play_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/play")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"track_id":"{track_id}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(play_resp.status(), StatusCode::OK);

    tokio::time::sleep(std::time::Duration::from_millis(80)).await;

    // GET /api/v1/playback/state -> real position_ms > 0
    let state_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/state")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let pb_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(state_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(pb_val["status"], "playing");
    assert!(pb_val["position_ms"].as_u64().unwrap_or(0) > 0);

    player.shutdown();
    let _ = std::fs::remove_dir_all(root_dir);
}

#[tokio::test]
async fn test_server_m7c_profiles_dsp_devices_dedup_enrich_and_http_stream() {
    let pool = core_db::open_test_database().await.unwrap();
    let player = core_audio::AudioPlayer::new_headless();
    let state = Arc::new(AppState::with_player(
        Some(pool.clone()),
        Some(player.clone()),
    ));
    state.bootstrap_from_db().await;
    let app = build_router(state.clone());

    // 1. Public health and info routes
    let health = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);
    let info = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/info")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(info.status(), StatusCode::OK);

    // Register a Bearer token for API testing
    let token = "lum_sec_test_m7c_token";
    state.pairing_manager.register_token(token).await;

    // 2. Profiles CRUD + switching
    let create_prof = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/profiles")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    r##"{"name":"Studio","avatar_color":"#AA22CC","is_default":false}"##,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create_prof.status(), StatusCode::OK);
    let prof_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(create_prof.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    let prof_id = prof_val["id"].as_str().unwrap().to_string();

    let act_prof = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/profiles/{prof_id}/activate"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(act_prof.status(), StatusCode::OK);

    // 3. AutoEQ import & DSP config + Audio devices
    let autoeq_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/dsp/autoeq")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "text": "Preamp: -3.0 dB\nFilter 1: ON PK Fc 105 Hz Gain 3.2 dB Q 0.71\n",
                        "apply": true
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(autoeq_resp.status(), StatusCode::OK);
    let autoeq_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(autoeq_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert!(!autoeq_val["peq_bands"].as_array().unwrap().is_empty());

    let devs_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/audio/devices")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(devs_resp.status(), StatusCode::OK);
    let devs: Vec<serde_json::Value> =
        serde_json::from_slice(&to_bytes(devs_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    assert!(!devs.is_empty());

    // 4. Local mock HTTP WAV server -> HTTP stream playback
    let mut wav_bytes = Vec::new();
    let sample_rate = 44_100u32;
    let channels = 2u16;
    let frames = 44_100u32;
    let data_len = frames * 4;
    wav_bytes.extend_from_slice(b"RIFF");
    wav_bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav_bytes.extend_from_slice(b"WAVEfmt ");
    wav_bytes.extend_from_slice(&16u32.to_le_bytes());
    wav_bytes.extend_from_slice(&1u16.to_le_bytes());
    wav_bytes.extend_from_slice(&channels.to_le_bytes());
    wav_bytes.extend_from_slice(&sample_rate.to_le_bytes());
    wav_bytes.extend_from_slice(&(sample_rate * 4).to_le_bytes());
    wav_bytes.extend_from_slice(&4u16.to_le_bytes());
    wav_bytes.extend_from_slice(&16u16.to_le_bytes());
    wav_bytes.extend_from_slice(b"data");
    wav_bytes.extend_from_slice(&data_len.to_le_bytes());
    wav_bytes.resize(wav_bytes.len() + data_len as usize, 0x10);
    let wav_arc = Arc::new(wav_bytes);

    let mock_http = axum::Router::new().route(
        "/stream.wav",
        axum::routing::get({
            let data = wav_arc.clone();
            move |headers: axum::http::HeaderMap| {
                let d = data.clone();
                async move {
                    if let Some(range) = headers.get(header::RANGE).and_then(|v| v.to_str().ok())
                        && let Some(spec) = range.strip_prefix("bytes=")
                        && let Some((s, e)) = spec.split_once('-')
                    {
                        let start: usize = s.parse().unwrap_or(0);
                        let end: usize = e
                            .parse()
                            .unwrap_or(d.len().saturating_sub(1))
                            .min(d.len() - 1);
                        return (
                            StatusCode::PARTIAL_CONTENT,
                            [
                                (header::ACCEPT_RANGES, "bytes".to_string()),
                                (
                                    header::CONTENT_RANGE,
                                    format!("bytes {start}-{end}/{}", d.len()),
                                ),
                                (header::CONTENT_TYPE, "audio/wav".to_string()),
                            ],
                            d[start..=end].to_vec(),
                        );
                    }
                    (
                        StatusCode::OK,
                        [
                            (header::ACCEPT_RANGES, "bytes".to_string()),
                            (
                                header::CONTENT_RANGE,
                                format!("bytes 0-{}/{}", d.len() - 1, d.len()),
                            ),
                            (header::CONTENT_TYPE, "audio/wav".to_string()),
                        ],
                        (*d).clone(),
                    )
                }
            }
        }),
    );
    let http_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let http_port = http_listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let _ = axum::serve(http_listener, mock_http).await;
    });

    let stream_play = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/play")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "stream_url": format!("http://127.0.0.1:{http_port}/stream.wav"),
                        "hint_extension": "wav",
                        "source": "Qobuz Stream"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(stream_play.status(), StatusCode::OK);
    tokio::time::sleep(std::time::Duration::from_millis(80)).await;
    assert!(player.position_ms() > 0);

    // 5. Deduplicate + Enrich against local mock MusicBrainz HTTP server
    let a1 = core_types::CanonicalAlbum::new("Animals", "Pink Floyd").unwrap();
    let v1 = core_types::AlbumVersion::new(
        &a1.id,
        core_types::ProviderKind::Local,
        "loc-animals",
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    let mut a1_full = a1.clone();
    a1_full.versions.push(v1.clone());
    let a2 = core_types::CanonicalAlbum::new("Animals", "Pink Floyd").unwrap();
    let v2 = core_types::AlbumVersion::new(
        &a2.id,
        core_types::ProviderKind::Qobuz,
        "qob-animals",
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    let t1 = core_types::TrackSource::new(
        &v1.id,
        core_types::ProviderKind::Local,
        "/music/animals/01_dogs.flac",
        "Dogs",
        1,
        1,
        1_024_000,
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    let t2 = core_types::TrackSource::new(
        &v2.id,
        core_types::ProviderKind::Qobuz,
        "qob-animals-1",
        "Dogs",
        1,
        1,
        1_024_000,
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    let mut a2_full = a2.clone();
    a2_full.versions.push(v2);

    core_db::LibraryRepository::insert_artist(
        &pool,
        &core_db::Artist {
            id: "art-pf".to_string(),
            name: "Pink Floyd".to_string(),
            sort_name: "Pink Floyd".to_string(),
            musicbrainz_id: None,
            biography: None,
            image_path: None,
            preference: 0,
        },
    )
    .await
    .unwrap();
    core_db::LibraryRepository::insert_canonical_album(&pool, &a1_full, Some("art-pf"))
        .await
        .unwrap();
    core_db::LibraryRepository::insert_canonical_album(&pool, &a2_full, Some("art-pf"))
        .await
        .unwrap();
    core_db::LibraryRepository::insert_track_source(&pool, &t1)
        .await
        .unwrap();
    core_db::LibraryRepository::insert_track_source(&pool, &t2)
        .await
        .unwrap();

    let dedup_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/deduplicate")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(dedup_resp.status(), StatusCode::OK);
    let dedup_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(dedup_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(dedup_val["merged_albums"], 1);

    let mb_mock = axum::Router::new()
        .route(
            "/ws/2/release-group",
            axum::routing::get(|| async {
                axum::Json(serde_json::json!({
                    "release-groups": [{
                        "id": "rg-animals-001",
                        "title": "Animals",
                        "primary-type": "Album",
                        "first-release-date": "1977-01-23"
                    }]
                }))
            }),
        )
        .route(
            "/ws/2/release-group/rg-animals-001",
            axum::routing::get(|| async {
                axum::Json(serde_json::json!({
                    "id": "rg-animals-001",
                    "title": "Animals",
                    "releases": [{ "id": "rel-animals-001", "title": "Animals" }]
                }))
            }),
        )
        .route(
            "/ws/2/release/rel-animals-001",
            axum::routing::get(|| async {
                axum::Json(serde_json::json!({
                    "id": "rel-animals-001",
                    "title": "Animals",
                    "relations": [{
                        "type": "producer",
                        "target-type": "artist",
                        "artist": {
                            "id": "art-mb-rg",
                            "name": "Roger Waters",
                            "sort-name": "Waters, Roger"
                        }
                    }]
                }))
            }),
        );
    let mb_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mb_port = mb_listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let _ = axum::serve(mb_listener, mb_mock).await;
    });

    let enrich_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/enrich")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "musicbrainz_base_url": format!("http://127.0.0.1:{mb_port}/ws/2")
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(enrich_resp.status(), StatusCode::OK);
    let enrich_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(enrich_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(enrich_val["albums_enriched"], 1);
    assert!(enrich_val["credits_added"].as_u64().unwrap() >= 1);

    let album_detail_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/albums/{}", a1.id))
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(album_detail_resp.status(), StatusCode::OK);
    let detail_val: serde_json::Value = serde_json::from_slice(
        &to_bytes(album_detail_resp.into_body(), 1024 * 64)
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(detail_val["versions"].as_array().unwrap().len(), 2);
    assert!(!detail_val["credits"].as_array().unwrap().is_empty());

    player.shutdown();
}

#[tokio::test]
async fn test_server_phase4_dlna_airplay_and_clock_sync_zones() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, UdpSocket};

    // 1. Mock ClockSync UDP server (+12_000 us simulated offset)
    let clock_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let clock_addr = clock_sock.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        let mut buf = [0u8; 1024];
        while let Ok((n, peer)) = clock_sock.recv_from(&mut buf).await {
            if let Ok(req) = serde_json::from_slice::<serde_json::Value>(&buf[..n]) {
                let t1 = req["t1_us"].as_i64().unwrap_or(0);
                let now_us = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_micros() as i64;
                let t2 = now_us + 12_000;
                let resp = serde_json::json!({
                    "t1_us": t1,
                    "t2_us": t2,
                    "t3_us": t2 + 20,
                });
                let _ = clock_sock
                    .send_to(&serde_json::to_vec(&resp).unwrap(), peer)
                    .await;
            }
        }
    });

    // 2. Mock DLNA HTTP + SSDP responder
    let played_uri = Arc::new(tokio::sync::RwLock::new(String::new()));
    let played_uri_clone = played_uri.clone();
    let dlna_router = axum::Router::new()
        .route(
            "/description.xml",
            axum::routing::get(|| async {
                r#"<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room Renderer</friendlyName>
    <UDN>uuid:test-dlna-1</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/ctrl/av</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/ctrl/rc</controlURL>
      </service>
    </serviceList>
  </device>
</root>"#
            }),
        )
        .route(
            "/ctrl/av",
            axum::routing::post(move |body: String| {
                let uri_lock = played_uri_clone.clone();
                async move {
                    if let Some(u) = core_server::zones::dlna::extract_soap_tag(&body, "CurrentURI") {
                        *uri_lock.write().await = u;
                    }
                    r#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><CurrentTransportState>PLAYING</CurrentTransportState><RelTime>00:00:05</RelTime><TrackURI>http://127.0.0.1/a.flac</TrackURI></s:Body></s:Envelope>"#
                }
            }),
        )
        .route(
            "/ctrl/rc",
            axum::routing::post(|| async {
                r#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><CurrentVolume>60</CurrentVolume></s:Body></s:Envelope>"#
            }),
        );
    let dlna_http_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dlna_http_port = dlna_http_listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        let _ = axum::serve(dlna_http_listener, dlna_router).await;
    });

    let ssdp_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let ssdp_addr = ssdp_sock.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        let mut buf = [0u8; 2048];
        while let Ok((_n, peer)) = ssdp_sock.recv_from(&mut buf).await {
            let resp = format!(
                "HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:{dlna_http_port}/description.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:test-dlna-1\r\n\r\n"
            );
            let _ = ssdp_sock.send_to(resp.as_bytes(), peer).await;
        }
    });

    // 3. Mock AirPlay RTSP + UDP RTP receiver
    let rtp_sock = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let rtp_port = rtp_sock.local_addr().unwrap().port();
    let rtp_received = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let rtp_rx_flag = rtp_received.clone();
    tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        while let Ok((n, _)) = rtp_sock.recv_from(&mut buf).await {
            if n >= 12 {
                rtp_rx_flag.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
        }
    });

    let rtsp_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let rtsp_addr = rtsp_listener.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = rtsp_listener.accept().await {
            tokio::spawn(async move {
                let mut stream_buf = Vec::with_capacity(4096);
                let mut tmp = [0u8; 2048];
                loop {
                    while !stream_buf.windows(4).any(|w| w == b"\r\n\r\n") {
                        match sock.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => stream_buf.extend_from_slice(&tmp[..n]),
                        }
                    }
                    let hdr_end = stream_buf
                        .windows(4)
                        .position(|w| w == b"\r\n\r\n")
                        .unwrap()
                        + 4;
                    let head_txt = String::from_utf8_lossy(&stream_buf[..hdr_end]).to_string();
                    let clen: usize = head_txt
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
                        .and_then(|l| l.split_once(':'))
                        .and_then(|(_, v)| v.trim().parse().ok())
                        .unwrap_or(0);
                    while stream_buf.len() < hdr_end + clen {
                        match sock.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => stream_buf.extend_from_slice(&tmp[..n]),
                        }
                    }
                    stream_buf.drain(..hdr_end + clen);

                    let method = head_txt.split_whitespace().next().unwrap_or("OPTIONS");
                    let cseq = head_txt
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("cseq:"))
                        .and_then(|l| l.split_once(':'))
                        .map(|(_, v)| v.trim())
                        .unwrap_or("1");
                    let extra = match method {
                        "SETUP" => format!(
                            "Session: 1\r\nTransport: RTP/AVP/UDP;unicast;mode=record;server_port={rtp_port};control_port=0;timing_port=0\r\n"
                        ),
                        "RECORD" => "Audio-Latency: 11025\r\n".to_string(),
                        _ => String::new(),
                    };
                    let resp = format!("RTSP/1.0 200 OK\r\nCSeq: {cseq}\r\n{extra}\r\n");
                    if sock.write_all(resp.as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });

    // Exercise REST /api/v1/zones endpoints
    let state = Arc::new(AppState::new(None));
    let token = "lum_sec_zones_test";
    state.pairing_manager.register_token(token).await;
    let app = build_router(state);

    let disc_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/zones/discover")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "ssdp_addr": ssdp_addr,
                        "airplay_addrs": [rtsp_addr.clone()],
                        "clock_sync_addr": clock_addr.clone(),
                        "timeout_ms": 200
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(disc_resp.status(), StatusCode::OK);
    let zones: Vec<serde_json::Value> =
        serde_json::from_slice(&to_bytes(disc_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    let dlna_id = zones
        .iter()
        .find(|z| z["backend"] == "network_dlna")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let airplay_id = zones
        .iter()
        .find(|z| z["backend"] == "network_airplay")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Sync clock
    let sync_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/zones/{dlna_id}/sync"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"samples": 3, "sample_interval_ms": 5}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(sync_resp.status(), StatusCode::OK);
    let sync_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(sync_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    let offset = sync_val["offset_us"].as_i64().unwrap();
    assert!((offset - 12_000).abs() < 5_000);

    // Group + Cast DLNA & AirPlay
    let grp_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/zones/group")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "group_id": "party-mode",
                        "zone_ids": [dlna_id.clone(), airplay_id.clone()]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(grp_resp.status(), StatusCode::OK);

    let cast_dlna = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/zones/{dlna_id}/cast"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    r#"{"action":"play","media_uri":"http://127.0.0.1/track.flac"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(cast_dlna.status(), StatusCode::OK);
    assert_eq!(*played_uri.read().await, "http://127.0.0.1/track.flac");

    let cast_ap = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/zones/{airplay_id}/cast"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"action":"play"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(cast_ap.status(), StatusCode::OK);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert!(rtp_received.load(std::sync::atomic::Ordering::SeqCst) >= 1);
}

#[tokio::test]
async fn test_server_contract1_2_3_routes() {
    let pool = core_db::open_test_database().await.unwrap();
    let player = core_audio::AudioPlayer::new_headless();
    let state = Arc::new(AppState::with_player(
        Some(pool.clone()),
        Some(player.clone()),
    ));
    let app = build_router(state);

    // Pair client
    let init_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/initiate")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"device_name":"ContractTester"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    let init_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(init_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    let pin = init_val["pin"].as_str().unwrap();

    let verify_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/verify")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    let verify_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(verify_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    let token = verify_val["token"].as_str().unwrap().to_string();

    // 1. Contract #1: Playback state, resume, reconnect
    let state_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/state")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(state_resp.status(), StatusCode::OK);
    let pb_state: serde_json::Value =
        serde_json::from_slice(&to_bytes(state_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(pb_state["state_code"], 1);
    assert_eq!(pb_state["state_name"], "Stopped");
    assert_eq!(pb_state["clock_source"], "stream_frames");
    assert_eq!(pb_state["device_lost"], false);

    // Pause then Resume
    let pause_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/pause")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(pause_resp.status(), StatusCode::OK);

    let resume_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/resume")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resume_resp.status(), StatusCode::OK);
    let res_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(resume_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(res_val["status"], "playing");

    // Reconnect
    let rec_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/reconnect")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(rec_resp.status(), StatusCode::OK);

    // 2. Setup audio files for Contract #2 & #3
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root_dir = std::env::temp_dir().join(format!("lumina_srv_contracts_{ts}"));
    let album_dir = root_dir.join("Artist C").join("Album C");
    std::fs::create_dir_all(&album_dir).unwrap();
    let track_path = album_dir.join("01 - Song.wav");
    write_test_wav(&track_path, 44_100, 2, 44_100);

    let lrc_path = album_dir.join("01 - Song.lrc");
    std::fs::write(
        &lrc_path,
        "[00:01.00]Sidecar line 1\n[00:04.00]Sidecar line 2\n",
    )
    .unwrap();

    let cover_path = album_dir.join("cover.png");
    let dummy_png = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
        0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00,
        0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    std::fs::write(&cover_path, dummy_png).unwrap();

    // Scan
    let scan_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/scan")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({"path": root_dir.to_string_lossy()}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(scan_resp.status(), StatusCode::OK);

    // Get tracks and verify enriched fields
    let tracks_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/tracks")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(tracks_resp.status(), StatusCode::OK);
    let tracks: serde_json::Value =
        serde_json::from_slice(&to_bytes(tracks_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    let trk = &tracks[0];
    let tid = trk["id"].as_str().unwrap().to_string();
    assert!(trk.get("sample_rate_hz").is_some());
    assert!(trk.get("bit_depth").is_some());
    assert!(trk.get("channels").is_some());
    assert!(trk.get("codec").is_some());
    assert!(trk.get("has_lyrics").is_some());
    assert!(trk.get("cover_url").is_some());

    // 2. Contract #2: Artwork endpoints
    let art_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/artwork/{tid}"))
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(art_resp.status(), StatusCode::OK);
    assert!(
        art_resp
            .headers()
            .get(header::CONTENT_TYPE)
            .unwrap()
            .to_str()
            .unwrap()
            .starts_with("image/")
    );
    let art_bytes = to_bytes(art_resp.into_body(), 1024 * 64).await.unwrap();
    assert!(!art_bytes.is_empty());

    // Artwork override
    let dummy_user_img = root_dir.join("user_cover.png");
    std::fs::write(&dummy_user_img, dummy_png).unwrap();
    let art_ovr_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/artwork/{tid}/override"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({"image_path": dummy_user_img.to_string_lossy()}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(art_ovr_resp.status().is_success());

    // Clear artwork override
    let del_art_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/artwork/{tid}/override"))
                .method("DELETE")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(del_art_resp.status().is_success());

    // Rescan library
    let rescan_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/rescan")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"force":false}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(rescan_resp.status(), StatusCode::OK);

    // 3. Contract #3: Lyrics endpoints
    let lyr_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/lyrics/{tid}"))
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(lyr_resp.status(), StatusCode::OK);
    let lyr_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(lyr_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    assert_eq!(lyr_val["found"], true);
    assert_eq!(lyr_val["source"], "sidecar_lrc");

    // Lyrics override
    let manual_lrc = root_dir.join("manual.lrc");
    std::fs::write(&manual_lrc, "[00:00.50]Manual REST lyric\n").unwrap();
    let lyr_ovr_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/lyrics/{tid}/override"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({"file_path": manual_lrc.to_string_lossy()}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(lyr_ovr_resp.status().is_success());

    // Query lyrics after override -> user_file
    let lyr_resp2 = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/lyrics/{tid}"))
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(lyr_resp2.status(), StatusCode::OK);
    let lyr_val2: serde_json::Value =
        serde_json::from_slice(&to_bytes(lyr_resp2.into_body(), 1024 * 64).await.unwrap()).unwrap();
    assert_eq!(lyr_val2["source"], "user_file");

    // Delete lyrics override
    let del_lyr_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/lyrics/{tid}/override"))
                .method("DELETE")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert!(del_lyr_resp.status().is_success());

    player.shutdown();
    let _ = std::fs::remove_dir_all(root_dir);
}

#[tokio::test]
async fn test_server_transition_watcher_emits_track_changed_and_queue_updated() {
    use core_audio::stream::StreamSource;
    use core_server::spawn_playback_transition_watcher;
    use core_types::{DeckState, DeckTrackMetadata};

    // Without player, watcher returns None.
    let no_player_state = Arc::new(AppState::new(None));
    assert!(spawn_playback_transition_watcher(no_player_state).is_none());

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_srv_watcher_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav1 = tmp_dir.join("w1.wav");
    let wav2 = tmp_dir.join("w2.wav");
    write_test_wav(&wav1, 48_000, 2, 48_000 / 2); // 500ms
    write_test_wav(&wav2, 48_000, 2, 48_000 * 3); // 3000ms

    let player = core_audio::AudioPlayer::new_headless();
    let state = Arc::new(AppState::with_player(None, Some(player.clone())));
    let app = build_router(state.clone());

    // Pair client for REST verification
    let init_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/initiate")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    let init_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(init_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    let pin = init_val["pin"].as_str().unwrap();
    let verify_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/verify")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    let verify_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(verify_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    let token = verify_val["token"].as_str().unwrap().to_string();

    let mut rx = state.broadcast_tx.subscribe();
    let watcher =
        spawn_playback_transition_watcher(state.clone()).expect("watcher handle when player Some");

    let meta1 = DeckTrackMetadata {
        track_id: "srv-trk-1".to_string(),
        provider_id: "local".to_string(),
        title: "Server Track 1".to_string(),
        artist: "Artist 1".to_string(),
        album: "Album 1".to_string(),
        cover_url: Some("https://cdn.example.com/srv-1.jpg".to_string()),
        duration_ms: 500,
    };
    let meta2 = DeckTrackMetadata {
        track_id: "srv-trk-2".to_string(),
        provider_id: "qobuz".to_string(),
        title: "Server Track 2".to_string(),
        artist: "Artist 2".to_string(),
        album: "Album 2".to_string(),
        cover_url: Some("https://cdn.example.com/srv-2.jpg".to_string()),
        duration_ms: 3_000,
    };

    player
        .play_stream_with_metadata(StreamSource::local_file(&wav1), "Local 1", Some(meta1))
        .expect("play wav1");
    player
        .prepare_standby_with_metadata(StreamSource::local_file(&wav2), "Qobuz 2", Some(meta2))
        .expect("prepare standby wav2");

    // Wait for standby to become ready before track 1 finishes if needed
    let mut ready = false;
    for _ in 0..80 {
        if player.dual_deck_status().deck_b_state == DeckState::StandbyReady
            || player.swap_generation() >= 1
        {
            ready = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(15)).await;
    }
    assert!(ready);

    let mut saw_track_changed = None;
    let mut saw_queue_updated = None;
    let mut saw_pb_changed = None;
    let mut saw_sp_updated = false;

    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(4);
    while tokio::time::Instant::now() < deadline
        && (saw_track_changed.is_none()
            || saw_queue_updated.is_none()
            || saw_pb_changed.is_none()
            || !saw_sp_updated)
    {
        match tokio::time::timeout(std::time::Duration::from_millis(200), rx.recv()).await {
            Ok(Ok(WsMessage::Event { event, payload })) if event == "track_changed" => {
                saw_track_changed = Some(payload);
            }
            Ok(Ok(WsMessage::Event { event, payload })) if event == "queue_updated" => {
                saw_queue_updated = Some(payload);
            }
            Ok(Ok(WsMessage::PlaybackStateChanged { payload })) if payload.swap_generation >= 1 => {
                saw_pb_changed = Some(payload);
            }
            Ok(Ok(WsMessage::SignalPathUpdated { payload })) if !payload.nodes.is_empty() => {
                saw_sp_updated = true;
            }
            _ => {}
        }
    }

    let tc = saw_track_changed.expect("watcher must emit track_changed");
    assert_eq!(tc["swap_generation"], 1);
    assert_eq!(tc["position_ms"], 0);
    assert!(tc["duration_ms"].as_u64().unwrap_or(0) >= 2_500);
    assert_eq!(tc["track"]["track_id"], "srv-trk-2");
    assert_eq!(tc["track_id"], "srv-trk-2");
    assert_eq!(tc["provider_id"], "qobuz");
    assert_eq!(tc["title"], "Server Track 2");
    assert_eq!(tc["artist"], "Artist 2");
    assert_eq!(tc["album"], "Album 2");
    assert_eq!(tc["cover_url"], "https://cdn.example.com/srv-2.jpg");

    let qu = saw_queue_updated.expect("watcher must emit queue_updated");
    assert_eq!(qu["swap_generation"], 1);
    assert_eq!(qu["track_id"], "srv-trk-2");

    let pb = saw_pb_changed.expect("watcher must emit PlaybackStateChanged");
    assert_eq!(pb.swap_generation, 1);
    assert_eq!(pb.track_id.as_deref(), Some("srv-trk-2"));
    assert_eq!(
        pb.track.as_ref().map(|t| t.title.as_str()),
        Some("Server Track 2")
    );
    assert!(saw_sp_updated, "watcher must emit SignalPathUpdated");

    // REST /api/v1/playback/state reflects current_track & swap_generation
    let state_resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/state")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(state_resp.status(), StatusCode::OK);
    let state_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(state_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(state_val["swap_generation"], 1);
    assert_eq!(state_val["current_track_id"], "srv-trk-2");
    assert_eq!(state_val["track_id"], "srv-trk-2");
    assert_eq!(state_val["current_track"]["track_id"], "srv-trk-2");
    assert_eq!(state_val["current_track"]["title"], "Server Track 2");

    watcher.abort();
    player.shutdown();
    let _ = std::fs::remove_dir_all(tmp_dir);
}

#[tokio::test]
async fn test_server_rapid_30_play_requests_latest_wins_and_no_state_lock_stall() {
    use core_types::{DeckTrackMetadata, StreamKey, StreamSourceSpec};
    use std::collections::BTreeMap;
    use std::time::{Duration, Instant};

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_srv_rapid30_{ts}"));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let wav_44 = tmp_dir.join("s44.wav");
    let wav_48 = tmp_dir.join("s48.wav");
    let wav_96 = tmp_dir.join("s96.wav");
    write_test_wav(&wav_44, 44_100, 2, 44_100 * 2);
    write_test_wav(&wav_48, 48_000, 2, 48_000 * 2);
    write_test_wav(&wav_96, 96_000, 2, 96_000 * 2);
    let wav_96_bytes = Arc::new(std::fs::read(&wav_96).unwrap());

    // Mock HTTP server with a stalled endpoint and a fast 96kHz WAV endpoint
    let mock_http = axum::Router::new()
        .route(
            "/stalled.wav",
            axum::routing::get(|| async {
                tokio::time::sleep(Duration::from_secs(15)).await;
                (StatusCode::OK, Vec::<u8>::new())
            }),
        )
        .route(
            "/ok96.wav",
            axum::routing::get({
                let data = wav_96_bytes.clone();
                move |headers: axum::http::HeaderMap| {
                    let d = data.clone();
                    async move {
                        if let Some(range) =
                            headers.get(header::RANGE).and_then(|v| v.to_str().ok())
                            && let Some(spec) = range.strip_prefix("bytes=")
                            && let Some((s, e)) = spec.split_once('-')
                        {
                            let start: usize = s.parse().unwrap_or(0).min(d.len() - 1);
                            let end: usize = if e.is_empty() {
                                d.len() - 1
                            } else {
                                e.parse().unwrap_or(d.len() - 1).min(d.len() - 1)
                            };
                            return (
                                StatusCode::PARTIAL_CONTENT,
                                [
                                    (header::ACCEPT_RANGES, "bytes".to_string()),
                                    (
                                        header::CONTENT_RANGE,
                                        format!("bytes {start}-{end}/{}", d.len()),
                                    ),
                                    (header::CONTENT_TYPE, "audio/wav".to_string()),
                                ],
                                d[start..=end].to_vec(),
                            );
                        }
                        (
                            StatusCode::OK,
                            [
                                (header::ACCEPT_RANGES, "bytes".to_string()),
                                (
                                    header::CONTENT_RANGE,
                                    format!("bytes 0-{}/{}", d.len() - 1, d.len()),
                                ),
                                (header::CONTENT_TYPE, "audio/wav".to_string()),
                            ],
                            (*d).clone(),
                        )
                    }
                }
            }),
        );
    let http_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let http_port = http_listener.local_addr().unwrap().port();
    let http_srv = tokio::spawn(async move {
        let _ = axum::serve(http_listener, mock_http).await;
    });

    let player = core_audio::AudioPlayer::new_headless();
    let state = Arc::new(AppState::with_player(None, Some(player.clone())));
    let watcher = core_server::spawn_playback_transition_watcher(state.clone())
        .expect("watcher handle when player Some");
    let token = "lum_sec_rapid30_test_token";
    state.pairing_manager.register_token(token).await;
    let app = build_router(state.clone());
    let mut ws_rx = state.broadcast_tx.subscribe();

    let mut max_post_ms: u128 = 0;
    let mut max_get_ms: u128 = 0;
    let mut last_epoch: u64 = 0;

    for i in 1u64..=30 {
        let body = if i == 30 {
            serde_json::json!({
                "track_id": "srv-rapid-30",
                "playback_epoch": i,
                "source": "Tidal HI_RES",
                "track": DeckTrackMetadata {
                    track_id: "srv-rapid-30".to_string(),
                    provider_id: "tidal".to_string(),
                    title: "Settled Server Track 30".to_string(),
                    artist: "Artist 30".to_string(),
                    album: "Album 30".to_string(),
                    cover_url: None,
                    duration_ms: 2000,
                },
                "source_spec": StreamSourceSpec::DirectRange {
                    key: StreamKey::new("tidal", "srv-rapid-30", "HI_RES"),
                    url: format!("http://127.0.0.1:{http_port}/ok96.wav"),
                    headers: BTreeMap::new(),
                    bitrate_bps: Some(4_608_000),
                    mime_type: Some("audio/wav".to_string()),
                    hint_extension: Some("wav".to_string()),
                    content_length: Some(wav_96_bytes.len() as u64),
                    expire_at: None,
                    init_range_end: None,
                    index_range_start: None,
                    index_range_end: None,
                    loudness: None,
                    album_loudness: None,
                }
            })
        } else if i % 2 == 1 {
            serde_json::json!({
                "track_id": format!("srv-rapid-{i}"),
                "playback_epoch": i,
                "stream_url": format!("http://127.0.0.1:{http_port}/stalled.wav"),
                "hint_extension": "wav",
            })
        } else {
            let p = if i % 4 == 0 { &wav_48 } else { &wav_44 };
            serde_json::json!({
                "track_id": format!("srv-rapid-{i}"),
                "playback_epoch": i,
                "file_path": p.to_string_lossy(),
            })
        };

        let t0 = Instant::now();
        let play_resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/playback/play")
                    .method("POST")
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        max_post_ms = max_post_ms.max(t0.elapsed().as_millis());
        assert_eq!(play_resp.status(), StatusCode::OK);
        let play_val: serde_json::Value =
            serde_json::from_slice(&to_bytes(play_resp.into_body(), 1024 * 64).await.unwrap())
                .unwrap();
        let ep = play_val["playback_epoch"].as_u64().unwrap_or(0);
        assert!(
            ep >= last_epoch,
            "monotonic epoch prev={last_epoch} cur={ep}"
        );
        last_epoch = ep;

        // Verify GET /api/v1/playback/state never stalls behind playback_state write lock
        let t1 = Instant::now();
        let st_resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/playback/state")
                    .method("GET")
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        max_get_ms = max_get_ms.max(t1.elapsed().as_millis());
        assert_eq!(st_resp.status(), StatusCode::OK);
    }

    assert!(
        max_post_ms < 100,
        "POST /api/v1/playback/play stalled for {max_post_ms}ms"
    );
    assert!(
        max_get_ms < 100,
        "GET /api/v1/playback/state stalled for {max_get_ms}ms"
    );

    // Wait for track 30 to settle into playing
    let mut settled = None;
    for _ in 0..120 {
        let st_resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/playback/state")
                    .method("GET")
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let val: serde_json::Value =
            serde_json::from_slice(&to_bytes(st_resp.into_body(), 1024 * 64).await.unwrap())
                .unwrap();
        if val["status"] == "playing" && val["current_track_id"] == "srv-rapid-30" {
            settled = Some(val);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let settled = settled.expect("final track 30 must settle into playing");
    assert!(settled["playback_epoch"].as_u64().unwrap_or(0) >= 30);

    // Stale epoch (5 < 30) must be ignored
    let stale_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/play")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "track_id": "srv-stale-5",
                        "playback_epoch": 5,
                        "file_path": wav_44.to_string_lossy(),
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(stale_resp.status(), StatusCode::OK);
    let stale_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(stale_resp.into_body(), 1024 * 64).await.unwrap())
            .unwrap();
    assert_eq!(stale_val["status"], "ignored");

    // Epoch-less stalled play right after epoched track 30:
    // 1. Must advance playback_epoch > 30
    // 2. Even after transition watcher ticks (80ms), GET /api/v1/playback/state and WS broadcasts
    //    must stay in "loading" for Track 31 and NEVER flash back to Old Track 30 ("playing").
    let ep30 = settled["playback_epoch"].as_u64().unwrap();
    // Drain prior WS messages first
    while ws_rx.try_recv().is_ok() {}
    let ep31_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/play")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "track_id": "srv-epochless-31",
                        "stream_url": format!("http://127.0.0.1:{http_port}/stalled.wav"),
                        "hint_extension": "wav",
                        "track": DeckTrackMetadata {
                            track_id: "srv-epochless-31".to_string(),
                            provider_id: "youtube_music".to_string(),
                            title: "Loading Server Track 31".to_string(),
                            artist: "Artist 31".to_string(),
                            album: "Album 31".to_string(),
                            cover_url: None,
                            duration_ms: 180_000,
                        },
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(ep31_resp.status(), StatusCode::OK);
    let ep31_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(ep31_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    let ep31 = ep31_val["playback_epoch"].as_u64().unwrap_or(0);
    assert!(
        ep31 > ep30,
        "epoch-less server play must advance epoch past {ep30}, got {ep31}"
    );

    // Wait > 50ms so spawn_playback_transition_watcher ticks at least once while Track 31 is Loading
    tokio::time::sleep(Duration::from_millis(80)).await;
    let st31_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/state")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let st31_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(st31_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    assert_eq!(st31_val["status"], "loading");
    assert_eq!(st31_val["state_code"], 5);
    assert_eq!(st31_val["current_track_id"], "srv-epochless-31");
    assert_eq!(st31_val["current_track"]["track_id"], "srv-epochless-31");
    while let Ok(msg) = ws_rx.try_recv() {
        if let WsMessage::PlaybackStateChanged { payload } = msg {
            assert_ne!(
                payload.track_id.as_deref(),
                Some("srv-rapid-30"),
                "transition watcher must never flash back to old track srv-rapid-30 while loading"
            );
        }
    }

    // Epoch-less fast play right after epoched play must NOT be dropped (must settle into playing)
    let ep32_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/play")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "track_id": "srv-epochless-32",
                        "file_path": wav_48.to_string_lossy(),
                        "track": DeckTrackMetadata {
                            track_id: "srv-epochless-32".to_string(),
                            provider_id: "local".to_string(),
                            title: "Settled Server Track 32".to_string(),
                            artist: "Artist 32".to_string(),
                            album: "Album 32".to_string(),
                            cover_url: None,
                            duration_ms: 2000,
                        },
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(ep32_resp.status(), StatusCode::OK);
    let mut settled_32 = None;
    for _ in 0..100 {
        let st_resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/playback/state")
                    .method("GET")
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let val: serde_json::Value =
            serde_json::from_slice(&to_bytes(st_resp.into_body(), 1024 * 64).await.unwrap())
                .unwrap();
        if val["status"] == "playing" && val["current_track_id"] == "srv-epochless-32" {
            settled_32 = Some(val);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let settled_32 =
        settled_32.expect("epoch-less play 32 after epoched play must settle to playing");
    let ep32 = settled_32["playback_epoch"].as_u64().unwrap_or(0);
    assert!(ep32 > ep31);

    // Stop must succeed cleanly and advance playback_epoch
    let stop_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/stop")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(stop_resp.status(), StatusCode::OK);
    let stop_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(stop_resp.into_body(), 1024 * 64).await.unwrap()).unwrap();
    assert!(stop_val["playback_epoch"].as_u64().unwrap_or(0) > ep32);

    // Confirm WS broadcast received PlaybackStateChanged with playback_epoch >= 32
    let mut saw_epoch_ws = false;
    while let Ok(msg) = ws_rx.try_recv() {
        if let WsMessage::PlaybackStateChanged { payload } = msg
            && payload.playback_epoch >= ep32
        {
            saw_epoch_ws = true;
            break;
        }
    }
    assert!(
        saw_epoch_ws,
        "WS broadcast should carry playback_epoch >= {ep32}"
    );

    watcher.abort();
    http_srv.abort();
    player.shutdown();
    let _ = std::fs::remove_dir_all(tmp_dir);
}

#[tokio::test]
async fn test_rest_and_ws_ingestion_layer_endpoints() {
    let pool = core_db::open_test_database().await.unwrap();
    let state = Arc::new(AppState::with_player(Some(pool), None));
    state.bootstrap_from_db().await;
    let token = "lum_sec_ingestion_test_token";
    state.pairing_manager.register_token(token).await;
    let mut ws_rx = state.broadcast_tx.subscribe();
    let app = build_router(state.clone());

    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let tmp_dir = std::env::temp_dir().join(format!("lumina_srv_ingest_{ts}"));
    let album_dir = tmp_dir.join("Miles Davis").join("Kind of Blue");
    std::fs::create_dir_all(&album_dir).unwrap();
    write_test_wav(&album_dir.join("01 - So What.wav"), 48_000, 2, 48_000);
    let corrupt_path = album_dir.join("02 - Corrupt.wav");
    std::fs::write(&corrupt_path, b"BAD_RIFF_DATA_0000").unwrap();

    // 1. POST /api/v1/library/watch & GET /api/v1/library/watch
    let add_watch = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/watch")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "root_path": tmp_dir.to_string_lossy(),
                        "watch_mode": "manual",
                        "poll_interval_sec": 90
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(add_watch.status(), StatusCode::OK);
    let added_root: serde_json::Value =
        serde_json::from_slice(&to_bytes(add_watch.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(added_root["watch_mode"], "manual");
    assert_eq!(added_root["poll_interval_sec"], 90);

    let list_watch = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/watch")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(list_watch.status(), StatusCode::OK);
    let roots: Vec<serde_json::Value> =
        serde_json::from_slice(&to_bytes(list_watch.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    assert_eq!(roots.len(), 1);

    // 2. POST /api/v1/library/scan/start -> WS library.scan_progress completed event
    let scan_start = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/scan/start")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "dir_path": tmp_dir.to_string_lossy(),
                        "force": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(scan_start.status(), StatusCode::OK);
    let start_body: serde_json::Value =
        serde_json::from_slice(&to_bytes(scan_start.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    assert!(
        start_body["scan_id"]
            .as_str()
            .is_some_and(|s| !s.is_empty())
    );

    let mut saw_completed_ws = false;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while tokio::time::Instant::now() < deadline {
        if let Ok(Ok(WsMessage::Event { event, payload })) =
            tokio::time::timeout(std::time::Duration::from_millis(200), ws_rx.recv()).await
            && event == "library.scan_progress"
            && payload["state"] == "completed"
        {
            saw_completed_ws = true;
            break;
        }
    }
    assert!(
        saw_completed_ws,
        "Expected WS broadcast to receive library.scan_progress with state='completed'"
    );

    // 3. GET /api/v1/library/skipped, retry (still_skipped -> fix -> imported), dismiss
    let skip_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/skipped")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(skip_resp.status(), StatusCode::OK);
    let skipped: Vec<serde_json::Value> =
        serde_json::from_slice(&to_bytes(skip_resp.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(skipped.len(), 1);
    let skip_id = skipped[0]["id"].as_str().unwrap().to_string();

    // Retry while still corrupt -> still_skipped
    let retry1 = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/skipped/{skip_id}/retry"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(retry1.status(), StatusCode::OK);
    let retry1_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(retry1.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(retry1_val["status"], "still_skipped");

    // Replace corrupt file with valid WAV and retry -> imported
    write_test_wav(&corrupt_path, 48_000, 2, 48_000);
    let retry2 = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/skipped/{skip_id}/retry"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(retry2.status(), StatusCode::OK);
    let retry2_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(retry2.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(retry2_val["status"], "imported");

    // Dismiss endpoint works cleanly
    let dismiss_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/skipped/{skip_id}/dismiss"))
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(dismiss_resp.status(), StatusCode::OK);

    // 4. PUT / GET / DELETE /api/v1/library/overrides/{entity_type}/{entity_id}
    let put_ov = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/overrides/track/trk-ov-1")
                .method("PUT")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "field_name": "title",
                        "value_json": "\"Edited Track Title\""
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(put_ov.status(), StatusCode::OK);

    let get_ov = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/overrides/track/trk-ov-1")
                .method("GET")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(get_ov.status(), StatusCode::OK);
    let ovs: Vec<serde_json::Value> =
        serde_json::from_slice(&to_bytes(get_ov.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(ovs.len(), 1);
    assert_eq!(ovs[0]["field_name"], "title");

    let del_ov = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/overrides/track/trk-ov-1/title")
                .method("DELETE")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(del_ov.status(), StatusCode::OK);

    // 5. POST /api/v1/library/ingest
    let ingest_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/ingest")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "provider": "youtube_music",
                        "albums": [{
                            "external_album_id": "ytm-alb-1",
                            "title": "Digital Horizons",
                            "artist_name": "Nujabes",
                            "tracks": [{
                                "external_track_id": "ytm-trk-1",
                                "title": "Aruarian Dance",
                                "artist_name": "Nujabes",
                                "album_title": "Digital Horizons",
                                "disc_number": 1,
                                "track_number": 1,
                                "duration_ms": 250000,
                                "codec": "opus",
                                "sample_rate_hz": 48000,
                                "bit_depth": 16,
                                "channels": 2,
                                "is_dsd": false
                            }]
                        }]
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(ingest_resp.status(), StatusCode::OK);
    let ing_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(ingest_resp.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    assert_eq!(ing_val["albums_ingested"], 1);
    assert_eq!(ing_val["tracks_ingested"], 1);

    // 6. DELETE /api/v1/library/watch?id=...
    let root_id = added_root["id"].as_str().unwrap();
    let del_watch = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/v1/library/watch?id={root_id}"))
                .method("DELETE")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(del_watch.status(), StatusCode::OK);
    let del_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(del_watch.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(del_val["ok"], true);

    if let Some(watcher) = state.watcher_manager.write().await.take() {
        watcher.shutdown().await;
    }
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[tokio::test]
async fn test_server_bug1_albums_hide_zero_track_bug2_rescan_start_and_ws_lagged_resilience() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let pool = core_db::open_test_database().await.unwrap();
    let state = Arc::new(AppState::new(Some(pool.clone())));
    let token = "lum_sec_bug12_server_test_tok";
    state.pairing_manager.register_token(token).await;

    // Seed 1 album WITH tracks and 1 empty 0-track album directly into SQLite
    let mut real_alb = core_types::CanonicalAlbum::new("Populated Album", "Valid Artist").unwrap();
    let real_ver = core_types::AlbumVersion::new(
        &real_alb.id,
        core_types::ProviderKind::Local,
        "/music/valid",
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    let real_trk = core_types::TrackSource::new(
        &real_ver.id,
        core_types::ProviderKind::Local,
        "/music/valid/01.flac",
        "Track 1",
        1,
        1,
        180_000,
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    real_alb.add_version(real_ver);

    let mut empty_alb =
        core_types::CanonicalAlbum::new("Empty Orphan Album", "Ghost Artist").unwrap();
    let empty_ver = core_types::AlbumVersion::new(
        &empty_alb.id,
        core_types::ProviderKind::Local,
        "/music/ghost",
        core_types::AudioFormat::cd_quality(),
    )
    .unwrap();
    empty_alb.add_version(empty_ver);

    let artist_ok = core_db::LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "Valid Artist",
        None,
        None,
        None,
    )
    .await
    .unwrap();
    let artist_ghost = core_db::LibraryRepository::upsert_artist_by_mbid_or_name(
        &pool,
        "Ghost Artist",
        None,
        None,
        None,
    )
    .await
    .unwrap();
    core_db::LibraryRepository::insert_canonical_album(&pool, &real_alb, Some(&artist_ok.id))
        .await
        .unwrap();
    core_db::LibraryRepository::insert_track_source(&pool, &real_trk)
        .await
        .unwrap();
    core_db::LibraryRepository::insert_canonical_album(&pool, &empty_alb, Some(&artist_ghost.id))
        .await
        .unwrap();

    let app = core_server::routes::build_router(state.clone());

    // 1. GET /api/v1/library/albums must hide 0-track album and report track_count == 1
    let albums_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/albums?limit=50")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(albums_resp.status(), StatusCode::OK);
    let albums_val: Vec<serde_json::Value> =
        serde_json::from_slice(&to_bytes(albums_resp.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    assert_eq!(albums_val.len(), 1);
    assert_eq!(albums_val[0]["title"], "Populated Album");
    assert_eq!(albums_val[0]["track_count"], 1);

    // 2. POST /api/v1/library/rescan/start accepts `directory` alias & emits correlated scan_id
    let tmp_dir = std::env::temp_dir().join(format!("lumina_srv_rescan_{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let mut progress_rx = state
        .ingestion_pipeline
        .as_ref()
        .unwrap()
        .subscribe_progress();

    let rescan_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/library/rescan/start")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "directory": tmp_dir.to_string_lossy().to_string(),
                        "force": true
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(rescan_resp.status(), StatusCode::OK);
    let rescan_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(rescan_resp.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    let expected_scan_id = rescan_val["scan_id"].as_str().unwrap().to_string();
    assert!(!expected_scan_id.is_empty());

    let mut saw_completed = false;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        if let Ok(Ok(ev)) =
            tokio::time::timeout(std::time::Duration::from_millis(200), progress_rx.recv()).await
            && ev.scan_id == expected_scan_id
            && ev.state == core_types::ScanLifecycleState::Completed
        {
            saw_completed = true;
            break;
        }
    }
    assert!(
        saw_completed,
        "POST /api/v1/library/rescan/start must emit correlated Completed ScanProgressEvent"
    );

    // 3. WebSocket Lagged resilience: flooding > 128 broadcast messages must NOT drop WS connection
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let srv_handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    let handshake = format!(
        "GET /api/v1/ws?token={token} HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\n\r\n"
    );
    tcp.write_all(handshake.as_bytes()).await.unwrap();

    // Read HTTP 101 Switching Protocols response header
    let mut header_buf = Vec::new();
    let mut byte = [0u8; 1];
    while !header_buf.ends_with(b"\r\n\r\n") {
        tcp.read_exact(&mut byte).await.unwrap();
        header_buf.push(byte[0]);
    }
    let header_str = String::from_utf8_lossy(&header_buf);
    assert!(
        header_str.starts_with("HTTP/1.1 101"),
        "Expected 101 Switching Protocols, got: {header_str}"
    );

    // Give the server socket task a moment to subscribe to broadcast_tx
    tokio::time::sleep(std::time::Duration::from_millis(40)).await;

    // Flood 200 messages past the 128-slot broadcast channel capacity to force RecvError::Lagged
    for i in 0..200u32 {
        let _ = state
            .broadcast_tx
            .send(core_server::ws::messages::WsMessage::StateChanged {
                extra: serde_json::json!({ "seq": i }),
            });
    }
    // Send a sentinel message after the flood
    let _ = state
        .broadcast_tx
        .send(core_server::ws::messages::WsMessage::StateChanged {
            extra: serde_json::json!({ "sentinel": "still_alive" }),
        });

    let mut saw_sentinel = false;
    let mut raw_stream_bytes = Vec::new();
    let mut tmp_buf = [0u8; 4096];
    let ws_deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while tokio::time::Instant::now() < ws_deadline {
        match tokio::time::timeout(
            std::time::Duration::from_millis(300),
            tcp.read(&mut tmp_buf),
        )
        .await
        {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                raw_stream_bytes.extend_from_slice(&tmp_buf[..n]);
                if String::from_utf8_lossy(&raw_stream_bytes).contains("still_alive") {
                    saw_sentinel = true;
                    break;
                }
            }
            _ => break,
        }
    }
    assert!(
        saw_sentinel,
        "WebSocket client must stay connected and deliver subsequent messages after RecvError::Lagged"
    );
    srv_handle.abort();
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

async fn pair_test_token(app: &axum::Router) -> String {
    let init_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/initiate")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    let init_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(init_resp.into_body(), 64 * 1024).await.unwrap()).unwrap();
    let pin = init_val["pin"].as_str().unwrap();

    let verify_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/pair/verify")
                .method("POST")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    let verify_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(verify_resp.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    verify_val["token"].as_str().unwrap().to_string()
}

fn encode_ws_client_text_frame(text: &str) -> Vec<u8> {
    let payload = text.as_bytes();
    let mask = [0x37u8, 0xFA, 0x21, 0x3D];
    let mut frame = Vec::with_capacity(14 + payload.len());
    frame.push(0x81); // FIN + Text opcode
    if payload.len() <= 125 {
        frame.push(0x80 | (payload.len() as u8));
    } else if payload.len() <= 65535 {
        frame.push(0x80 | 126);
        frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    } else {
        frame.push(0x80 | 127);
        frame.extend_from_slice(&(payload.len() as u64).to_be_bytes());
    }
    frame.extend_from_slice(&mask);
    for (i, b) in payload.iter().enumerate() {
        frame.push(b ^ mask[i % 4]);
    }
    frame
}

async fn read_ws_server_text_frame(
    stream: &mut tokio::net::TcpStream,
    timeout: std::time::Duration,
) -> Option<String> {
    use tokio::io::AsyncReadExt;
    let mut hdr = [0u8; 2];
    tokio::time::timeout(timeout, stream.read_exact(&mut hdr))
        .await
        .ok()?
        .ok()?;
    let opcode = hdr[0] & 0x0F;
    let masked = (hdr[1] & 0x80) != 0;
    let len_byte = hdr[1] & 0x7F;
    let payload_len: usize = match len_byte {
        126 => {
            let mut ext = [0u8; 2];
            stream.read_exact(&mut ext).await.ok()?;
            u16::from_be_bytes(ext) as usize
        }
        127 => {
            let mut ext = [0u8; 8];
            stream.read_exact(&mut ext).await.ok()?;
            u64::from_be_bytes(ext) as usize
        }
        n => n as usize,
    };
    let mask = if masked {
        let mut m = [0u8; 4];
        stream.read_exact(&mut m).await.ok()?;
        Some(m)
    } else {
        None
    };
    let mut payload = vec![0u8; payload_len];
    stream.read_exact(&mut payload).await.ok()?;
    if let Some(m) = mask {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= m[i % 4];
        }
    }
    if opcode == 0x1 {
        String::from_utf8(payload).ok()
    } else {
        None
    }
}

async fn connect_raw_ws(port: u16, path_and_query: &str) -> tokio::net::TcpStream {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    let handshake = format!(
        "GET {path_and_query} HTTP/1.1\r\n\
         Host: 127.0.0.1:{port}\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
         Sec-WebSocket-Version: 13\r\n\r\n"
    );
    tcp.write_all(handshake.as_bytes()).await.unwrap();
    let mut header_buf = Vec::new();
    let mut byte = [0u8; 1];
    while !header_buf.ends_with(b"\r\n\r\n") {
        tcp.read_exact(&mut byte).await.unwrap();
        header_buf.push(byte[0]);
    }
    let header_str = String::from_utf8_lossy(&header_buf);
    assert!(
        header_str.starts_with("HTTP/1.1 101"),
        "Expected 101 Switching Protocols, got: {header_str}"
    );
    tcp
}

#[tokio::test]
async fn test_server_unified_protocol_snapshot_commands_queue_and_lumina_errors() {
    use core_types::{
        LuminaError, LuminaErrorCode, PlaybackCommand, PlaybackLifecycleState, PlaybackState,
        ProtocolSnapshot, QueueState, RepeatMode, TrackMetadata,
    };

    let player = core_audio::AudioPlayer::new_headless();
    let state = Arc::new(AppState::with_player(None, Some(player.clone())));
    let app = build_router(state.clone());
    let token = pair_test_token(&app).await;

    // 1. Unauthenticated request must return structured LuminaError + legacy keys
    let unauth_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/snapshot")
                .method("GET")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(unauth_resp.status(), StatusCode::UNAUTHORIZED);
    let unauth_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(unauth_resp.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    assert_eq!(unauth_val["status"], "error");
    assert!(unauth_val["error"].as_str().is_some());
    let unauth_err: LuminaError = serde_json::from_value(unauth_val).unwrap();
    assert_eq!(unauth_err.code, LuminaErrorCode::StreamAuthRequired);
    assert_eq!(unauth_err.http_status, Some(401));

    // 2. GET /api/v1/snapshot returns canonical ProtocolSnapshot with monotonic sequence
    let snap1_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/snapshot")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(snap1_resp.status(), StatusCode::OK);
    let snap1: ProtocolSnapshot =
        serde_json::from_slice(&to_bytes(snap1_resp.into_body(), 256 * 1024).await.unwrap())
            .unwrap();
    assert!(snap1.server_time_ms > 0);
    assert_eq!(snap1.sequence, 1);
    assert_eq!(snap1.playback.status, PlaybackLifecycleState::Stopped);
    assert!(snap1.signal_path.is_some());
    assert!(!snap1.devices.is_empty());
    assert!(!snap1.zones.is_empty());

    // 3. Queue REST endpoints: load, enqueue (append & play_next), reorder, delete, OOB error, clear
    let t1 = TrackMetadata {
        track_id: "q-trk-1".into(),
        provider_id: "local".into(),
        title: "Track One".into(),
        artist: "Artist A".into(),
        album: "Album X".into(),
        duration_ms: 180_000,
        ..Default::default()
    };
    let t2 = TrackMetadata {
        track_id: "q-trk-2".into(),
        provider_id: "local".into(),
        title: "Track Two".into(),
        artist: "Artist A".into(),
        album: "Album X".into(),
        duration_ms: 210_000,
        ..Default::default()
    };
    let t3 = TrackMetadata {
        track_id: "q-trk-3".into(),
        provider_id: "qobuz".into(),
        title: "Track Three".into(),
        artist: "Artist B".into(),
        album: "Album Y".into(),
        duration_ms: 240_000,
        ..Default::default()
    };

    let load_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/queue/load")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "items": [t1, t2],
                        "start_index": 0,
                        "auto_play": false
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(load_resp.status(), StatusCode::OK);
    let q_loaded: QueueState =
        serde_json::from_slice(&to_bytes(load_resp.into_body(), 128 * 1024).await.unwrap())
            .unwrap();
    assert_eq!(q_loaded.items.len(), 2);
    assert_eq!(q_loaded.current_index, Some(0));
    assert_eq!(q_loaded.items[0].track.track_id, "q-trk-1");
    assert!(q_loaded.queue_epoch >= 1);

    // Enqueue play_next inserts right after current_index (at index 1)
    let enq_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/queue/enqueue")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({ "items": [t3], "play_next": true }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(enq_resp.status(), StatusCode::OK);
    let q_enq: QueueState =
        serde_json::from_slice(&to_bytes(enq_resp.into_body(), 128 * 1024).await.unwrap()).unwrap();
    assert_eq!(q_enq.items.len(), 3);
    assert_eq!(q_enq.items[1].track.track_id, "q-trk-3");
    assert!(q_enq.items[1].is_user_queued);

    // Reorder: move index 2 -> 0 (current_index 0 shifts to 1)
    let reorder_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/queue/reorder")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({ "from_index": 2, "to_index": 0 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(reorder_resp.status(), StatusCode::OK);
    let q_reordered: QueueState = serde_json::from_slice(
        &to_bytes(reorder_resp.into_body(), 128 * 1024)
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(q_reordered.items[0].track.track_id, "q-trk-2");
    assert_eq!(q_reordered.current_index, Some(1));

    // Delete out-of-bounds returns 400 + structured LuminaError
    let oob_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/queue/99")
                .method("DELETE")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(oob_resp.status(), StatusCode::BAD_REQUEST);
    let oob_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(oob_resp.into_body(), 64 * 1024).await.unwrap()).unwrap();
    assert_eq!(oob_val["status"], "error");
    let oob_err: LuminaError = serde_json::from_value(oob_val).unwrap();
    assert_eq!(oob_err.code, LuminaErrorCode::InvalidCommand);

    // Delete valid index 0 -> current_index shifts 1 -> 0
    let del_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/queue/0")
                .method("DELETE")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(del_resp.status(), StatusCode::OK);
    let q_del: QueueState =
        serde_json::from_slice(&to_bytes(del_resp.into_body(), 128 * 1024).await.unwrap()).unwrap();
    assert_eq!(q_del.items.len(), 2);
    assert_eq!(q_del.current_index, Some(0));
    assert_eq!(q_del.items[0].track.track_id, "q-trk-1");

    // 4. POST /api/v1/playback/command: SetVolume, SetMute, SetRepeatMode, SetShuffle, Next, Previous
    for cmd in [
        PlaybackCommand::SetVolume { volume: 0.65 },
        PlaybackCommand::SetMute { muted: true },
        PlaybackCommand::SetRepeatMode {
            mode: RepeatMode::All,
        },
        PlaybackCommand::SetShuffle { enabled: true },
        PlaybackCommand::Next,
    ] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/playback/command")
                    .method("POST")
                    .header(header::AUTHORIZATION, format!("Bearer {token}"))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(serde_json::to_string(&cmd).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "command {cmd:?} failed");
    }

    // Verify GET /api/v1/playback/state deserializes as canonical PlaybackState + legacy fields
    let st_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/state")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(st_resp.status(), StatusCode::OK);
    let st_val: serde_json::Value =
        serde_json::from_slice(&to_bytes(st_resp.into_body(), 128 * 1024).await.unwrap()).unwrap();
    assert!(st_val.get("epoch").is_some());
    assert!(st_val["timestamp_ms"].as_u64().unwrap_or(0) > 0);
    let canonical_pb: PlaybackState = serde_json::from_value(st_val).unwrap();
    assert!(canonical_pb.is_muted);
    assert!((canonical_pb.volume - 0.65).abs() < 1e-4);
    assert_eq!(canonical_pb.repeat_mode, RepeatMode::All);
    assert!(canonical_pb.shuffle);
    assert_eq!(canonical_pb.track_id.as_deref(), Some("q-trk-3"));

    // Unknown zone in SetActiveZone returns 404 + DeviceNotFound LuminaError
    let bad_zone_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/playback/command")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::to_string(&PlaybackCommand::SetActiveZone {
                        zone_id: "zone-does-not-exist".into(),
                    })
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(bad_zone_resp.status(), StatusCode::NOT_FOUND);
    let bad_zone_err: LuminaError = serde_json::from_slice(
        &to_bytes(bad_zone_resp.into_body(), 64 * 1024)
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(bad_zone_err.code, LuminaErrorCode::DeviceNotFound);

    // Clear queue & verify snapshot sequence advances
    let clear_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/queue/clear")
                .method("POST")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(clear_resp.status(), StatusCode::OK);
    let q_cleared: QueueState =
        serde_json::from_slice(&to_bytes(clear_resp.into_body(), 64 * 1024).await.unwrap())
            .unwrap();
    assert!(q_cleared.items.is_empty());
    assert_eq!(q_cleared.current_index, None);

    let snap2_resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/snapshot")
                .header(header::AUTHORIZATION, format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let snap2: ProtocolSnapshot =
        serde_json::from_slice(&to_bytes(snap2_resp.into_body(), 256 * 1024).await.unwrap())
            .unwrap();
    assert!(snap2.sequence > snap1.sequence);

    player.shutdown();
}

#[tokio::test]
async fn test_server_ws_snapshot_typed_command_invalid_json_unicast_and_lagged_resync() {
    use core_types::{LuminaErrorCode, PlaybackCommand, RepeatMode, WsServerEvent};
    use tokio::io::AsyncWriteExt;

    let state = Arc::new(AppState::new(None));
    let app = build_router(state.clone());
    let token = pair_test_token(&app).await;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let srv_handle = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    // 1. Client A connects with ?snapshot=true -> must receive WsServerEvent::Snapshot
    let mut client_a =
        connect_raw_ws(port, &format!("/api/v1/ws?token={token}&snapshot=true")).await;
    let first_frame = read_ws_server_text_frame(&mut client_a, std::time::Duration::from_secs(2))
        .await
        .expect("snapshot=true must send Snapshot frame");
    let first_ev: WsServerEvent = serde_json::from_str(&first_frame).unwrap();
    match first_ev {
        WsServerEvent::Snapshot(snap) => {
            assert!(snap.server_time_ms > 0);
            assert!(snap.sequence >= 1);
            assert!(!snap.zones.is_empty());
        }
        other => panic!("Expected WsServerEvent::Snapshot first, got {other:?}"),
    }
    // Drain the 2 follow-up legacy compat frames (PlaybackStateChanged + SignalPathUpdated)
    let _ = read_ws_server_text_frame(&mut client_a, std::time::Duration::from_secs(2)).await;
    let _ = read_ws_server_text_frame(&mut client_a, std::time::Duration::from_secs(2)).await;

    // 2. Client B connects without snapshot
    let mut client_b = connect_raw_ws(port, &format!("/api/v1/ws?token={token}")).await;
    tokio::time::sleep(std::time::Duration::from_millis(40)).await;

    // 3. Invalid JSON from Client A must unicast WsServerEvent::Error ONLY to Client A (NOT Client B)
    client_a
        .write_all(&encode_ws_client_text_frame("{{{not-valid-json"))
        .await
        .unwrap();
    let err_frame = read_ws_server_text_frame(&mut client_a, std::time::Duration::from_secs(2))
        .await
        .expect("sender must receive unicast Error frame on invalid JSON");
    let err_ev: WsServerEvent = serde_json::from_str(&err_frame).unwrap();
    match err_ev {
        WsServerEvent::Error(err) => {
            assert_eq!(err.code, LuminaErrorCode::InvalidCommand);
            assert!(err.message.contains("Invalid JSON"));
        }
        other => panic!("Expected WsServerEvent::Error, got {other:?}"),
    }
    let b_unexpected =
        read_ws_server_text_frame(&mut client_b, std::time::Duration::from_millis(150)).await;
    assert!(
        b_unexpected.is_none(),
        "Client B must NOT receive Client A's invalid-JSON error, got: {b_unexpected:?}"
    );

    // 4. Typed PlaybackCommand over WS from Client A updates state and broadcasts to Client B
    let cmd_json = serde_json::to_string(&PlaybackCommand::SetRepeatMode {
        mode: RepeatMode::One,
    })
    .unwrap();
    client_a
        .write_all(&encode_ws_client_text_frame(&cmd_json))
        .await
        .unwrap();

    let mut saw_repeat_one = false;
    for _ in 0..4 {
        if let Some(frame) =
            read_ws_server_text_frame(&mut client_b, std::time::Duration::from_secs(2)).await
            && let Ok(WsServerEvent::PlaybackStateChanged(pb)) = serde_json::from_str(&frame)
            && pb.repeat_mode == RepeatMode::One
        {
            saw_repeat_one = true;
            break;
        }
    }
    assert!(
        saw_repeat_one,
        "Typed PlaybackCommand::SetRepeatMode over WS must broadcast updated PlaybackStateChanged"
    );

    // 5. Flood >128 broadcast messages on idle Client B -> RecvError::Lagged must push fresh Snapshot
    // Drain any remaining frames on Client A/B first
    while read_ws_server_text_frame(&mut client_b, std::time::Duration::from_millis(30))
        .await
        .is_some()
    {}

    for i in 0..200u32 {
        let _ = state.broadcast_tx.send(WsMessage::StateChanged {
            extra: serde_json::json!({ "flood": i }),
        });
    }
    let mut saw_lagged_snapshot = false;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(3);
    while tokio::time::Instant::now() < deadline {
        if let Some(frame) =
            read_ws_server_text_frame(&mut client_b, std::time::Duration::from_millis(250)).await
            && let Ok(WsServerEvent::Snapshot(snap)) = serde_json::from_str(&frame)
        {
            assert_eq!(snap.playback.repeat_mode, RepeatMode::One);
            saw_lagged_snapshot = true;
            break;
        }
    }
    assert!(
        saw_lagged_snapshot,
        "WebSocket RecvError::Lagged must push a fresh WsServerEvent::Snapshot for resync"
    );

    srv_handle.abort();
}
