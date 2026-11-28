use std::sync::Arc;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use core_types::{ManifestFormat, StreamKey, StreamProviderCapabilities, StreamSourceSpec};

use super::auth::now_secs;
use super::{TidalConfig, TidalProvider, TidalTokenResponse};
use crate::error::ProviderError;
use crate::http::{HttpResponse, MockHttpTransport};
use crate::traits::StreamResolver;

async fn make_logged_in_tidal(transport: Arc<MockHttpTransport>) -> TidalProvider {
    let provider = TidalProvider::with_config(TidalConfig::default(), transport, None);
    provider
        .login_with_tokens(TidalTokenResponse {
            access_token: "tidal_tok_abc".to_string(),
            refresh_token: "tidal_ref_abc".to_string(),
            token_type: "Bearer".to_string(),
            expires_in: 3600,
            user_id: 42,
            issued_at: now_secs(),
        })
        .await
        .unwrap();
    provider
}

#[tokio::test]
async fn test_tidal_stream_resolver_bts_manifest_direct_range() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_fn("tracks/777/playbackinfo", |req| {
            let quality = req
                .query_params
                .iter()
                .find(|(k, _)| k == "audioquality")
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            let manifest_json = if quality == "HIGH" {
                serde_json::json!({
                    "mimeType": "audio/mp4",
                    "codecs": "mp4a.40.2",
                    "encryptionType": "NONE",
                    "urls": ["https://sp-cf.tidal.com/777-high.m4a"]
                })
            } else {
                serde_json::json!({
                    "mimeType": "audio/flac",
                    "codecs": "flac",
                    "encryptionType": "NONE",
                    "urls": ["https://sp-cf.tidal.com/777-lossless.flac"]
                })
            };
            let b64 = STANDARD.encode(manifest_json.to_string().as_bytes());
            Ok(HttpResponse::ok_json(
                serde_json::json!({
                    "audioQuality": quality,
                    "sampleRate": 44100,
                    "bitDepth": 16,
                    "manifestMimeType": "application/vnd.tidal.bts",
                    "manifest": b64
                })
                .to_string(),
            ))
        })
        .await;

    let provider = make_logged_in_tidal(transport).await;
    assert_eq!(StreamResolver::provider_id(&provider), "tidal");
    assert_eq!(
        StreamResolver::capabilities(&provider),
        StreamProviderCapabilities::tidal()
    );

    let flac_spec = provider
        .resolve_source(&StreamKey::new("tidal", "777", "LOSSLESS"))
        .await
        .unwrap();
    match flac_spec {
        StreamSourceSpec::DirectRange {
            url,
            headers,
            mime_type,
            hint_extension,
            ..
        } => {
            assert_eq!(url, "https://sp-cf.tidal.com/777-lossless.flac");
            assert_eq!(
                headers.get("Authorization").map(String::as_str),
                Some("Bearer tidal_tok_abc")
            );
            assert_eq!(mime_type.as_deref(), Some("audio/flac"));
            assert_eq!(hint_extension.as_deref(), Some("flac"));
        }
        other => panic!("expected DirectRange, got {other:?}"),
    }

    let high_spec = provider
        .resolve_source(&StreamKey::new("tidal", "777", "HIGH"))
        .await
        .unwrap();
    match high_spec {
        StreamSourceSpec::DirectRange {
            url,
            mime_type,
            hint_extension,
            ..
        } => {
            assert_eq!(url, "https://sp-cf.tidal.com/777-high.m4a");
            assert_eq!(mime_type.as_deref(), Some("audio/mp4"));
            assert_eq!(hint_extension.as_deref(), Some("m4a"));
        }
        other => panic!("expected DirectRange, got {other:?}"),
    }
}

#[tokio::test]
async fn test_tidal_stream_resolver_unencrypted_dash_segmented_manifest() {
    let mpd_xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4">
      <Representation id="0" codecs="flac" audioSamplingRate="192000">
        <SegmentTemplate initialization="https://cdn.tidal.com/init.mp4" media="https://cdn.tidal.com/seg-$Number$.m4s" startNumber="1"/>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#;
    let mpd_b64 = STANDARD.encode(mpd_xml.as_bytes());

    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "tracks/888/playbackinfo",
            HttpResponse::ok_json(
                serde_json::json!({
                    "audioQuality": "HI_RES_LOSSLESS",
                    "sampleRate": 192000,
                    "bitDepth": 24,
                    "manifestMimeType": "application/dash+xml",
                    "manifest": mpd_b64
                })
                .to_string(),
            ),
        )
        .await;

    let provider = make_logged_in_tidal(transport).await;
    let key = StreamKey::new("tidal", "888", "HI_RES_LOSSLESS");
    let spec = provider.resolve_source(&key).await.unwrap();
    match spec {
        StreamSourceSpec::SegmentedManifest {
            key: k,
            manifest_url_or_xml,
            format,
            headers,
            mime_type,
            ..
        } => {
            assert_eq!(k, key);
            assert_eq!(format, ManifestFormat::Dash);
            assert_eq!(manifest_url_or_xml, mpd_xml);
            assert_eq!(
                headers.get("Authorization").map(String::as_str),
                Some("Bearer tidal_tok_abc")
            );
            assert_eq!(mime_type.as_deref(), Some("application/dash+xml"));
        }
        other => panic!("expected SegmentedManifest, got {other:?}"),
    }
}

#[tokio::test]
async fn test_tidal_stream_resolver_drm_dash_rejected() {
    let drm_mpd = r#"<MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation/></AdaptationSet></Period></MPD>"#;
    let drm_b64 = STANDARD.encode(drm_mpd.as_bytes());

    let namespaced_drm_mpd = r#"<MPD><Period><AdaptationSet><cenc:ContentProtection value="cenc"/></AdaptationSet></Period></MPD>"#;
    let namespaced_b64 = STANDARD.encode(namespaced_drm_mpd.as_bytes());

    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "tracks/666/playbackinfo",
            HttpResponse::ok_json(
                serde_json::json!({
                    "audioQuality": "HI_RES_LOSSLESS",
                    "manifestMimeType": "application/dash+xml",
                    "manifest": drm_b64
                })
                .to_string(),
            ),
        )
        .await;
    transport
        .register_exact(
            "tracks/667/playbackinfo",
            HttpResponse::ok_json(
                serde_json::json!({
                    "audioQuality": "HI_RES_LOSSLESS",
                    "manifestMimeType": "application/dash+xml",
                    "manifest": namespaced_b64
                })
                .to_string(),
            ),
        )
        .await;

    let provider = make_logged_in_tidal(transport).await;
    let err1 = provider
        .resolve_source(&StreamKey::new("tidal", "666", "HI_RES_LOSSLESS"))
        .await
        .unwrap_err();
    assert!(matches!(err1, ProviderError::DrmRestricted(_)));

    let err2 = provider
        .resolve_source(&StreamKey::new("tidal", "667", "HI_RES_LOSSLESS"))
        .await
        .unwrap_err();
    assert!(matches!(err2, ProviderError::DrmRestricted(_)));
}

#[tokio::test]
async fn test_tidal_phase3_401_single_flight_refresh_403_split_and_loudness() {
    use std::sync::atomic::{AtomicUsize, Ordering};

    let transport = Arc::new(MockHttpTransport::new());
    let token_refresh_calls = Arc::new(AtomicUsize::new(0));
    let refresh_counter = token_refresh_calls.clone();

    transport
        .register_fn("token", move |_req| {
            refresh_counter.fetch_add(1, Ordering::SeqCst);
            Ok(HttpResponse::ok_json(
                serde_json::json!({
                    "access_token": "tidal_fresh_tok_2",
                    "refresh_token": "tidal_ref_2",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "user_id": 42
                })
                .to_string(),
            ))
        })
        .await;

    transport
        .register_fn("tracks/501/playbackinfo", |req| {
            let auth = req
                .headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            if auth == "Bearer tidal_tok_abc" {
                return Ok(HttpResponse {
                    status: 401,
                    headers: vec![],
                    body: r#"{"userMessage":"Expired access token"}"#.to_string(),
                });
            }
            let manifest_json = serde_json::json!({
                "mimeType": "audio/flac",
                "codecs": "flac",
                "encryptionType": "NONE",
                "urls": ["https://sp-cf.tidal.com/501-refreshed.flac"]
            });
            let b64 = STANDARD.encode(manifest_json.to_string().as_bytes());
            Ok(HttpResponse::ok_json(
                serde_json::json!({
                    "audioQuality": "LOSSLESS",
                    "sampleRate": 44100,
                    "bitDepth": 16,
                    "trackReplayGain": -6.5,
                    "trackPeakAmplitude": 0.92,
                    "albumReplayGain": -5.0,
                    "albumPeakAmplitude": 0.98,
                    "manifestMimeType": "application/vnd.tidal.bts",
                    "manifest": b64
                })
                .to_string(),
            ))
        })
        .await;

    transport
        .register_exact(
            "tracks/503/playbackinfo",
            HttpResponse {
                status: 403,
                headers: vec![],
                body: r#"{"userMessage":"Forbidden stream"}"#.to_string(),
            },
        )
        .await;

    let provider = Arc::new(make_logged_in_tidal(transport).await);

    // Concurrent 401s must deduplicate token refresh to exactly 1 /token call.
    let p1 = provider.clone();
    let p2 = provider.clone();
    let key1 = StreamKey::new("tidal", "501", "LOSSLESS");
    let key2 = key1.clone();
    let (r1, r2) = tokio::join!(p1.resolve_source(&key1), p2.resolve_source(&key2),);
    assert_eq!(token_refresh_calls.load(Ordering::SeqCst), 1);

    let spec = r1.unwrap();
    assert!(r2.is_ok());
    match spec {
        StreamSourceSpec::DirectRange {
            url,
            loudness,
            album_loudness,
            ..
        } => {
            assert_eq!(url, "https://sp-cf.tidal.com/501-refreshed.flac");
            let track_l = loudness.expect("track loudness should be populated");
            assert!((track_l.gain_db - (-2.5)).abs() < 1e-4);
            assert!((track_l.peak - 0.92).abs() < 1e-4);
            let album_l = album_loudness.expect("album loudness should be populated");
            assert!((album_l.gain_db - (-1.0)).abs() < 1e-4);
            assert!((album_l.peak - 0.98).abs() < 1e-4);
        }
        other => panic!("expected DirectRange, got {other:?}"),
    }

    // HTTP 403 must NOT map to AuthenticationFailed.
    let err_403 = provider
        .resolve_source(&StreamKey::new("tidal", "503", "LOSSLESS"))
        .await
        .unwrap_err();
    assert!(matches!(err_403, ProviderError::StreamResolutionFailed(_)));
}

#[tokio::test]
async fn test_tidal_quality_downgrade_and_region_restricted_451() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_fn("tracks/777/playbackinfo", |req| {
            let quality = req
                .query_params
                .iter()
                .find(|(k, _)| k == "audioquality")
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            if quality == "HI_RES_LOSSLESS" {
                return Ok(HttpResponse {
                    status: 403,
                    headers: vec![],
                    body: r#"{"userMessage":"Tier not entitled"}"#.to_string(),
                });
            }
            let manifest_json = serde_json::json!({
                "mimeType": "audio/flac",
                "codecs": "flac",
                "encryptionType": "NONE",
                "urls": ["https://sp-cf.tidal.com/777-lossless.flac"]
            });
            let b64 = STANDARD.encode(manifest_json.to_string().as_bytes());
            Ok(HttpResponse::ok_json(
                serde_json::json!({
                    "audioQuality": "LOSSLESS",
                    "sampleRate": 44100,
                    "bitDepth": 16,
                    "manifestMimeType": "application/vnd.tidal.bts",
                    "manifest": b64
                })
                .to_string(),
            ))
        })
        .await;

    transport
        .register_exact(
            "tracks/451/playbackinfo",
            HttpResponse {
                status: 451,
                headers: vec![],
                body: r#"{"userMessage":"Not available in your country"}"#.to_string(),
            },
        )
        .await;

    let provider = make_logged_in_tidal(transport).await;

    // HI_RES_LOSSLESS downgrades cleanly to LOSSLESS
    let spec = provider
        .resolve_source(&StreamKey::new("tidal", "777", "HI_RES_LOSSLESS"))
        .await
        .unwrap();
    match spec {
        StreamSourceSpec::DirectRange { url, .. } => {
            assert_eq!(url, "https://sp-cf.tidal.com/777-lossless.flac");
        }
        other => panic!("expected DirectRange, got {other:?}"),
    }

    // HTTP 451 maps directly to RegionRestricted without downgrading
    let err_451 = provider
        .resolve_source(&StreamKey::new("tidal", "451", "LOSSLESS"))
        .await
        .unwrap_err();
    assert!(matches!(err_451, ProviderError::RegionRestricted(_)));
}
