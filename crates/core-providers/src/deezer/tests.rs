use std::sync::Arc;

use core_types::{StreamCipher, StreamKey, StreamProviderCapabilities, StreamSourceSpec};

use super::{DeezerConfig, DeezerProvider};
use crate::http::{HttpResponse, MockHttpTransport};
use crate::traits::StreamResolver;

#[tokio::test]
async fn test_deezer_stream_resolver_bf_cbc_stripe_encrypted_range() {
    let valid_arl = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_fn("gw-light.php", |req| {
            let is_song = req
                .query_params
                .iter()
                .any(|(k, v)| k == "method" && v == "song.getData");
            if is_song {
                return Ok(HttpResponse::ok_json(
                    r#"{"error":[],"results":{"TRACK_TOKEN":"trk_tok_554433","GAIN":-4.2}}"#,
                ));
            }
            Ok(HttpResponse::ok_json(
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
            ))
        })
        .await;
    transport
        .register_fn("get_url", |req| {
            let body = String::from_utf8_lossy(req.body.as_deref().unwrap_or(&[]));
            if body.contains(r#""format":"FLAC""#) {
                Ok(HttpResponse::ok_json(
                    r#"{
                        "data": [{
                            "media": [{
                                "format": "FLAC",
                                "exp": 1766000000,
                                "sources": [{ "url": "https://e-cdns-proxy.dzcdn.net/stream/554433.flac" }]
                            }]
                        }]
                    }"#,
                ))
            } else {
                Ok(HttpResponse::ok_json(
                    r#"{
                        "data": [{
                            "media": [{
                                "format": "MP3_320",
                                "sources": [{ "url": "https://e-cdns-proxy.dzcdn.net/stream/554433.mp3" }]
                            }]
                        }]
                    }"#,
                ))
            }
        })
        .await;

    let provider = DeezerProvider::with_transport(DeezerConfig::default(), transport, None);
    provider.login_with_arl(valid_arl).await.unwrap();

    assert_eq!(StreamResolver::provider_id(&provider), "deezer");
    assert_eq!(
        StreamResolver::capabilities(&provider),
        StreamProviderCapabilities::deezer()
    );

    let flac_key = StreamKey::new("deezer", "554433", "FLAC");
    let flac_spec = provider.resolve_source(&flac_key).await.unwrap();
    match flac_spec {
        StreamSourceSpec::EncryptedRange {
            key,
            url,
            headers,
            mime_type,
            hint_extension,
            cipher,
            expire_at,
            loudness,
            ..
        } => {
            assert_eq!(key, flac_key);
            assert_eq!(url, "https://e-cdns-proxy.dzcdn.net/stream/554433.flac");
            assert_eq!(
                headers.get("Cookie").map(String::as_str),
                Some(format!("arl={valid_arl}").as_str())
            );
            assert_eq!(mime_type.as_deref(), Some("audio/flac"));
            assert_eq!(hint_extension.as_deref(), Some("flac"));
            assert_eq!(expire_at, Some(1_766_000_000));
            let l = loudness.expect("Deezer GAIN should map to NormalizedLoudness");
            assert!((l.gain_db - (-3.2)).abs() < 1e-4);
            assert!((l.peak - 1.0).abs() < 1e-4);
            assert_eq!(
                cipher,
                StreamCipher::DeezerBlowfish {
                    track_id: "554433".to_string(),
                    block_size: 2048,
                    stride: 3,
                }
            );
        }
        other => panic!("expected EncryptedRange, got {other:?}"),
    }

    let mp3_key = StreamKey::new("deezer", "554433", "MP3_320");
    let mp3_spec = provider.resolve_source(&mp3_key).await.unwrap();
    match mp3_spec {
        StreamSourceSpec::EncryptedRange {
            url,
            bitrate_bps,
            mime_type,
            hint_extension,
            cipher,
            ..
        } => {
            assert_eq!(url, "https://e-cdns-proxy.dzcdn.net/stream/554433.mp3");
            assert_eq!(bitrate_bps, Some(320_000));
            assert_eq!(mime_type.as_deref(), Some("audio/mpeg"));
            assert_eq!(hint_extension.as_deref(), Some("mp3"));
            assert_eq!(
                cipher,
                StreamCipher::DeezerBlowfish {
                    track_id: "554433".to_string(),
                    block_size: 2048,
                    stride: 3,
                }
            );
        }
        other => panic!("expected EncryptedRange, got {other:?}"),
    }
}

#[tokio::test]
async fn test_deezer_stream_resolver_preview_mp3_returns_direct_range() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "track/554433",
            HttpResponse::ok_json(
                r#"{
                    "id": 554433,
                    "title": "Preview Track",
                    "preview": "https://cdns-preview-5.dzcdn.net/stream/c-554433.mp3"
                }"#,
            ),
        )
        .await;

    let provider = DeezerProvider::with_transport(DeezerConfig::default(), transport, None);
    let spec = provider
        .resolve_source(&StreamKey::new("deezer", "554433", "preview"))
        .await
        .unwrap();
    match spec {
        StreamSourceSpec::DirectRange {
            url,
            headers,
            bitrate_bps,
            mime_type,
            hint_extension,
            ..
        } => {
            assert_eq!(url, "https://cdns-preview-5.dzcdn.net/stream/c-554433.mp3");
            assert!(headers.is_empty());
            assert_eq!(bitrate_bps, Some(128_000));
            assert_eq!(mime_type.as_deref(), Some("audio/mpeg"));
            assert_eq!(hint_extension.as_deref(), Some("mp3"));
        }
        other => panic!("expected DirectRange, got {other:?}"),
    }

    // Unauthenticated quality fallback also resolves official 30s preview DirectRange
    let fallback_spec = provider
        .resolve_source(&StreamKey::new("deezer", "554433", "FLAC"))
        .await
        .unwrap();
    assert!(matches!(
        fallback_spec,
        StreamSourceSpec::DirectRange { .. }
    ));
}
