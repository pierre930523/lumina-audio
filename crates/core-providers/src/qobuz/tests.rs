use std::sync::Arc;

use core_types::{StreamKey, StreamProviderCapabilities, StreamSourceSpec};

use super::*;
use crate::error::ProviderError;
use crate::traits::StreamResolver;

fn make_qobuz_provider(transport: Arc<MockHttpTransport>) -> QobuzProvider {
    let cfg = QobuzConfig::from_token_with_app(
        "qb_tok_stream_1",
        Some("123456".to_string()),
        Some("secret_xyz".to_string()),
    )
    .unwrap();
    QobuzProvider::new(cfg, transport, None)
}

#[tokio::test]
async fn test_qobuz_stream_resolver_respects_quality_key_and_aliases() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_fn("track/getFileUrl", |req| {
            let fmt = req
                .query_params
                .iter()
                .find(|(k, _)| k == "format_id")
                .map(|(_, v)| v.as_str())
                .unwrap_or("0");
            let track_id = req
                .query_params
                .iter()
                .find(|(k, _)| k == "track_id")
                .map(|(_, v)| v.as_str())
                .unwrap_or("0");
            let (mime, sr, bd) = match fmt {
                "27" => ("audio/flac", 192.0, 24),
                "7" => ("audio/flac", 96.0, 24),
                "6" => ("audio/flac", 44.1, 16),
                "5" => ("audio/mpeg", 44.1, 16),
                _ => unreachable!("unexpected format_id {fmt}"),
            };
            Ok(HttpResponse::ok_json(
                serde_json::json!({
                    "track_id": track_id,
                    "format_id": fmt.parse::<u32>().unwrap(),
                    "mime_type": mime,
                    "sampling_rate": sr,
                    "bit_depth": bd,
                    "url": format!("https://streaming-qobuz.example.com/{track_id}/{fmt}?exp=1765000000")
                })
                .to_string(),
            ))
        })
        .await;

    let provider = make_qobuz_provider(transport);
    assert_eq!(StreamResolver::provider_id(&provider), "qobuz");
    assert_eq!(
        StreamResolver::capabilities(&provider),
        StreamProviderCapabilities::qobuz()
    );

    let cases = [
        ("27", "flac", "audio/flac", None, "27"),
        ("hi_res_192", "flac", "audio/flac", None, "27"),
        ("hi_res_96", "flac", "audio/flac", None, "7"),
        ("lossless", "flac", "audio/flac", None, "6"),
        ("mp3_320", "mp3", "audio/mpeg", Some(320_000), "5"),
    ];

    for (quality_key, expected_ext, expected_mime, expected_bps, expected_fmt) in cases {
        let key = StreamKey::new("qobuz", "4242", quality_key);
        let spec = provider.resolve_source(&key).await.unwrap();
        match spec {
            StreamSourceSpec::DirectRange {
                key: k,
                url,
                headers,
                bitrate_bps,
                mime_type,
                hint_extension,
                expire_at,
                ..
            } => {
                assert_eq!(k, key);
                assert_eq!(
                    url,
                    format!(
                        "https://streaming-qobuz.example.com/4242/{expected_fmt}?exp=1765000000"
                    )
                );
                assert_eq!(headers.get("X-App-Id").map(String::as_str), Some("123456"));
                assert_eq!(
                    headers.get("X-User-Auth-Token").map(String::as_str),
                    Some("qb_tok_stream_1")
                );
                assert_eq!(hint_extension.as_deref(), Some(expected_ext));
                assert_eq!(mime_type.as_deref(), Some(expected_mime));
                assert_eq!(bitrate_bps, expected_bps);
                assert_eq!(expire_at, Some(1_765_000_000));
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn test_qobuz_stream_resolver_fallback_chain() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_fn("track/getFileUrl", |req| {
            let fmt = req
                .query_params
                .iter()
                .find(|(k, _)| k == "format_id")
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            if fmt == "27" {
                return Ok(HttpResponse::ok_json(
                    r#"{"status":"error","message":"format 27 unavailable"}"#,
                ));
            }
            Ok(HttpResponse::ok_json(format!(
                r#"{{"format_id":7,"mime_type":"audio/flac","sampling_rate":96.0,"bit_depth":24,"url":"https://cdn.qobuz.example.com/fallback-{fmt}.flac"}}"#
            )))
        })
        .await;

    let provider = make_qobuz_provider(transport);
    let spec = provider
        .resolve_source(&StreamKey::new("qobuz", "99", "hi_res_192"))
        .await
        .unwrap();
    match spec {
        StreamSourceSpec::DirectRange { url, .. } => {
            assert_eq!(url, "https://cdn.qobuz.example.com/fallback-7.flac");
        }
        other => panic!("expected DirectRange, got {other:?}"),
    }
}

#[tokio::test]
async fn test_qobuz_stream_resolver_rejects_drm_and_mismatched_provider() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_exact(
            "track/getFileUrl",
            HttpResponse::ok_json(r#"{"restrictions":["NOT_AVAILABLE"],"url":null}"#),
        )
        .await;

    let provider = make_qobuz_provider(transport);
    let drm_err = provider
        .resolve_source(&StreamKey::new("qobuz", "999", "lossless"))
        .await
        .unwrap_err();
    assert!(matches!(drm_err, ProviderError::DrmRestricted(_)));

    let wrong_prov = provider
        .resolve_source(&StreamKey::new("tidal", "999", "lossless"))
        .await
        .unwrap_err();
    assert!(matches!(wrong_prov, ProviderError::UnsupportedFormat(_)));
}

#[tokio::test]
async fn test_qobuz_splits_http_401_and_403_strictly() {
    let transport = Arc::new(MockHttpTransport::new());
    transport
        .register_fn("track/getFileUrl", |req| {
            let track_id = req
                .query_params
                .iter()
                .find(|(k, _)| k == "track_id")
                .map(|(_, v)| v.as_str())
                .unwrap_or("");
            if track_id == "401" {
                return Ok(HttpResponse {
                    status: 401,
                    headers: vec![],
                    body: r#"{"message":"Unauthorized"}"#.to_string(),
                });
            }
            Ok(HttpResponse {
                status: 403,
                headers: vec![],
                body: r#"{"message":"Forbidden"}"#.to_string(),
            })
        })
        .await;

    let provider = make_qobuz_provider(transport);
    let err_401 = provider
        .resolve_source(&StreamKey::new("qobuz", "401", "lossless"))
        .await
        .unwrap_err();
    assert!(matches!(err_401, ProviderError::AuthenticationFailed(_)));

    let err_403 = provider
        .resolve_source(&StreamKey::new("qobuz", "403", "lossless"))
        .await
        .unwrap_err();
    assert!(matches!(err_403, ProviderError::StreamResolutionFailed(_)));
}
