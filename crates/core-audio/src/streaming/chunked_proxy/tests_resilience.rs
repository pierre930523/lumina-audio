use super::tests_range::{make_pattern_bytes, spawn_mock_range_server};
use super::*;
use crate::streaming::{HttpRequestSpec, active_in_flight_downloads};
use bytes::Bytes;
use core_types::StreamSourceSpec;
use reqwest::Method;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};

#[tokio::test]
async fn test_chunked_proxy_read_timeout() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let payload = Arc::new(make_pattern_bytes(1024));
    let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, true, false).await;
    assert!(server.stall_body);
    assert!(server.delay_per_get.is_zero());

    let url = format!("http://{}/stall.flac", server.addr);
    let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(1024), None, None)
        .unwrap()
        .with_http_config(StreamHttpConfig {
            connect_timeout: Duration::from_millis(200),
            request_timeout: Duration::from_millis(200),
            read_timeout: Duration::from_millis(90),
            max_redirects: 4,
        });

    let mut buf = vec![0u8; 512];
    let err = proxy.read_at(0, &mut buf).await.unwrap_err();
    assert_eq!(err, StreamError::Timeout);
    assert_eq!(proxy.active_downloads(), 0);
}

#[tokio::test]
async fn test_chunked_proxy_cancel_aborts_immediately_and_clears_in_flight() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let payload = Arc::new(make_pattern_bytes(4096));
    let server =
        spawn_mock_range_server(Arc::clone(&payload), Duration::from_secs(5), false, false).await;

    let url = format!("http://{}/slow.flac", server.addr);
    let proxy =
        Arc::new(ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(4096), None, None).unwrap());

    let proxy_clone = Arc::clone(&proxy);
    let read_task = tokio::spawn(async move {
        let mut buf = vec![0u8; 64];
        proxy_clone.read_at(0, &mut buf).await
    });

    tokio::time::sleep(Duration::from_millis(40)).await;
    assert_eq!(proxy.active_downloads(), 1);
    assert!(active_in_flight_downloads() >= 1);

    let start = std::time::Instant::now();
    proxy.cancel();
    let res = read_task.await.unwrap();
    assert_eq!(res.unwrap_err(), StreamError::Cancelled);
    assert!(start.elapsed() < Duration::from_millis(500));
    assert_eq!(proxy.active_downloads(), 0);
    // Yield once so any sibling tests finish dropping guards if run concurrently, then check per-source + global.
    tokio::task::yield_now().await;
    assert_eq!(active_in_flight_downloads(), 0);
}

#[tokio::test]
async fn test_probe_206_without_content_range_total_never_truncates_to_one_byte() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;

    struct UnknownTotal206Transport {
        head_len: Option<u64>,
    }

    #[async_trait]
    impl StreamHttpTransport for UnknownTotal206Transport {
        async fn execute(
            &self,
            req: HttpRequestSpec,
            _read_body: bool,
            _config: &StreamHttpConfig,
            _cancel: &CancellationToken,
        ) -> Result<crate::streaming::HttpResponseData, StreamError> {
            if req.method == Method::HEAD {
                return Ok(crate::streaming::HttpResponseData {
                    status: if self.head_len.is_some() { 200 } else { 405 },
                    final_url: req.url,
                    headers: HeaderMap::new(), // deliberately omits Accept-Ranges to force GET 0-0
                    content_length: self.head_len,
                    content_range_total: None,
                    body: Bytes::new(),
                });
            }
            if req.range == Some((0, 0)) {
                return Ok(crate::streaming::HttpResponseData {
                    status: 206,
                    final_url: req.url,
                    headers: HeaderMap::new(),
                    content_length: Some(1), // 1-byte range length, NOT total!
                    content_range_total: None,
                    body: Bytes::new(),
                });
            }
            let (s, e) = req.range.unwrap_or((0, 15));
            let len = (e - s + 1) as usize;
            Ok(crate::streaming::HttpResponseData {
                status: 206,
                final_url: req.url,
                headers: HeaderMap::new(),
                content_length: Some(len as u64),
                content_range_total: self.head_len,
                body: Bytes::from(vec![0xABu8; len]),
            })
        }
    }

    // Case 1: HEAD 405 + GET 0-0 returns 206 with Content-Range: bytes 0-0/* and Content-Length: 1
    // Must return Unsupported instead of falsely clamping total length to 1 byte!
    let proxy_err = ChunkedStreamProxy::with_transport(
        "https://podcast.example.com/unknown-total.mp3",
        &BTreeMap::new(),
        None,
        Some("mp3".to_string()),
        Some("audio/mpeg".to_string()),
        Arc::new(UnknownTotal206Transport { head_len: None }),
    )
    .unwrap();
    let mut buf = [0u8; 32];
    let err = proxy_err.read_at(0, &mut buf).await.unwrap_err();
    assert!(matches!(err, StreamError::Unsupported(_)), "got {err:?}");
    assert_eq!(proxy_err.len(), None);

    // Case 2: HEAD provided Content-Length=4096 (without Accept-Ranges) + GET 0-0 returns 206 /*
    // Must preserve head_len=4096 rather than overwriting with 1!
    let proxy_ok = ChunkedStreamProxy::with_transport(
        "https://podcast.example.com/head-len.mp3",
        &BTreeMap::new(),
        None,
        Some("mp3".to_string()),
        Some("audio/mpeg".to_string()),
        Arc::new(UnknownTotal206Transport {
            head_len: Some(4096),
        }),
    )
    .unwrap();
    let n = proxy_ok.read_at(0, &mut buf).await.unwrap();
    assert_eq!(n, 32);
    assert_eq!(proxy_ok.len(), Some(4096));
}

#[tokio::test]
async fn test_non_range_200_ok_caches_full_body_without_redownloading() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let payload = Arc::new(make_pattern_bytes(300_000));
    let get_count = Arc::new(AtomicUsize::new(0));

    struct Always200Transport {
        payload: Arc<Vec<u8>>,
        get_count: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl StreamHttpTransport for Always200Transport {
        async fn execute(
            &self,
            req: HttpRequestSpec,
            _read_body: bool,
            _config: &StreamHttpConfig,
            _cancel: &CancellationToken,
        ) -> Result<crate::streaming::HttpResponseData, StreamError> {
            self.get_count.fetch_add(1, Ordering::SeqCst);
            Ok(crate::streaming::HttpResponseData {
                status: 200,
                final_url: req.url,
                headers: HeaderMap::new(),
                content_length: Some(self.payload.len() as u64),
                content_range_total: None,
                body: Bytes::copy_from_slice(&self.payload),
            })
        }
    }

    let proxy = ChunkedStreamProxy::with_transport(
        "https://rss.example.com/no-range.mp3",
        &BTreeMap::new(),
        Some(payload.len() as u64),
        Some("mp3".to_string()),
        Some("audio/mpeg".to_string()),
        Arc::new(Always200Transport {
            payload: Arc::clone(&payload),
            get_count: Arc::clone(&get_count),
        }),
    )
    .unwrap()
    .with_initial_chunk_size(64 * 1024)
    .with_chunk_size(64 * 1024);

    let mut b1 = [0u8; 256];
    let mut b2 = [0u8; 256];
    let mut b3 = [0u8; 256];
    assert_eq!(proxy.read_at(0, &mut b1).await.unwrap(), 256);
    assert_eq!(&b1[..], &payload[0..256]);
    assert_eq!(proxy.read_at(100_000, &mut b2).await.unwrap(), 256);
    assert_eq!(&b2[..], &payload[100_000..100_256]);
    assert_eq!(proxy.read_at(250_000, &mut b3).await.unwrap(), 256);
    assert_eq!(&b3[..], &payload[250_000..250_256]);

    assert_eq!(
        get_count.load(Ordering::SeqCst),
        1,
        "200 OK full response must be cached once and never re-downloaded per chunk"
    );
}

#[tokio::test]
async fn test_chunked_proxy_3_chunk_async_prefetch_and_metrics() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    // 128 KiB initial + 4 * 512 KiB sequential chunks
    let total = DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE * 4;
    let payload = Arc::new(make_pattern_bytes(total));
    let server =
        spawn_mock_range_server(Arc::clone(&payload), Duration::from_millis(5), false, false).await;

    let url = format!("http://{}/prefetch3.webm", server.addr);
    let proxy = ChunkedStreamProxy::new(
        url,
        &BTreeMap::new(),
        Some(total as u64),
        Some("webm".to_string()),
        Some("audio/webm".to_string()),
    )
    .unwrap()
    .with_stream_key(StreamKey::new("youtube_music", "ytm-prefetch-test", "251"));
    assert_eq!(proxy.prefetch_ahead(), DEFAULT_CHUNK_PREFETCH_AHEAD);
    assert_eq!(proxy.metrics().first_chunk_ms, None);

    // Two sequential reads advancing past chunk 0 midpoint (64 KiB) trigger 3-chunk async prefetch!
    let mut first = vec![0u8; 32 * 1024];
    let mut second = vec![0u8; 40 * 1024];
    assert_eq!(proxy.read_at(0, &mut first).await.unwrap(), first.len());
    assert_eq!(
        proxy
            .read_at(first.len() as u64, &mut second)
            .await
            .unwrap(),
        second.len()
    );
    assert_eq!(&first[..], &payload[..first.len()]);
    assert_eq!(
        &second[..],
        &payload[first.len()..first.len() + second.len()]
    );

    // Wait for all 3 background prefetch tasks to complete.
    for _ in 0..80 {
        if proxy.active_downloads() == 0
            && proxy.cached_bytes() >= DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE * 3
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let ranges = server.ranges_seen.lock().unwrap().clone();
    assert!(
        ranges.contains(&"bytes=0-131071".to_string())
            && ranges.contains(&"bytes=131072-655359".to_string())
            && ranges.contains(&"bytes=655360-1179647".to_string())
            && ranges.contains(&"bytes=1179648-1703935".to_string()),
        "Expected initial 128 KiB + 3x 512 KiB async prefetched ranges, got {ranges:?}"
    );
    assert!(
        !ranges.iter().any(|r| r.starts_with("bytes=1703936-")),
        "Must stay bounded to 3 chunks ahead, got {ranges:?}"
    );

    let metrics = proxy.metrics();
    assert!(
        metrics.first_chunk_ms.is_some(),
        "first_chunk_ms must be populated"
    );
    assert!(metrics.download_kbps > 0, "download_kbps must be > 0");
    assert!(
        metrics.total_downloaded_bytes
            >= (DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE * 3) as u64,
        "total_downloaded_bytes={}",
        metrics.total_downloaded_bytes
    );
}

#[tokio::test]
async fn synthesize_format_changed_spec_preserves_loudness_and_bitrate() {
    let track_loudness = NormalizedLoudness::new(-6.5, 0.92);
    let album_loudness = NormalizedLoudness::new(-5.0, 0.98);
    let proxy = ChunkedStreamProxy::new(
        "https://example.com/audio.webm",
        &BTreeMap::new(),
        Some(1024),
        Some("webm".to_string()),
        Some("audio/webm".to_string()),
    )
    .unwrap()
    .with_stream_key(StreamKey::new("youtube_music", "track-1", "251"))
    .with_spec_metadata(Some(160_000), Some(track_loudness), Some(album_loudness));

    let spec = proxy.refresh_context().synthesize_format_changed_spec(2048);
    let StreamSourceSpec::DirectRange {
        content_length,
        bitrate_bps,
        loudness,
        album_loudness: alb,
        ..
    } = spec
    else {
        panic!("expected DirectRange variant");
    };
    assert_eq!(content_length, Some(2048));
    assert_eq!(bitrate_bps, Some(160_000));
    assert_eq!(loudness, Some(track_loudness));
    assert_eq!(alb, Some(album_loudness));
}
