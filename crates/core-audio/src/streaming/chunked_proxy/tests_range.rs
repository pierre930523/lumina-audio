use super::*;
use std::collections::BTreeMap;
use std::sync::atomic::AtomicUsize;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub(super) fn make_pattern_bytes(len: usize) -> Vec<u8> {
    (0..len)
        .map(|i| ((i * 31 + (i >> 8) * 17) & 0xFF) as u8)
        .collect()
}

pub(super) struct MockRangeServer {
    pub(super) addr: std::net::SocketAddr,
    pub(super) ranges_seen: Arc<Mutex<Vec<String>>>,
    pub(super) head_count: Arc<AtomicUsize>,
    pub(super) delay_per_get: Duration,
    pub(super) stall_body: bool,
}

pub(super) async fn spawn_mock_range_server(
    payload: Arc<Vec<u8>>,
    delay_per_get: Duration,
    stall_body: bool,
    reject_head: bool,
) -> MockRangeServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let ranges_seen = Arc::new(Mutex::new(Vec::new()));
    let head_count = Arc::new(AtomicUsize::new(0));

    let ranges_clone = Arc::clone(&ranges_seen);
    let head_clone = Arc::clone(&head_count);
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let payload = Arc::clone(&payload);
            let ranges_seen = Arc::clone(&ranges_clone);
            let head_count = Arc::clone(&head_clone);
            tokio::spawn(async move {
                let mut req_buf = Vec::with_capacity(2048);
                let mut tmp = [0u8; 512];
                loop {
                    req_buf.clear();
                    let header_end = loop {
                        if let Some(pos) = req_buf.windows(4).position(|w| w == b"\r\n\r\n") {
                            break pos + 4;
                        }
                        match socket.read(&mut tmp).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => req_buf.extend_from_slice(&tmp[..n]),
                        }
                    };
                    let req_str = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                    let first_line = req_str.lines().next().unwrap_or("");
                    let method = first_line.split_whitespace().next().unwrap_or("GET");
                    let range_hdr = req_str
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        .and_then(|l| l.split_once(':'))
                        .map(|(_, v)| v.trim().to_string());

                    if method == "HEAD" {
                        head_count.fetch_add(1, Ordering::SeqCst);
                        let resp = if reject_head {
                            "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n"
                                .to_string()
                        } else {
                            format!(
                                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nContent-Type: audio/flac\r\n\r\n",
                                payload.len()
                            )
                        };
                        if socket.write_all(resp.as_bytes()).await.is_err()
                            || socket.flush().await.is_err()
                        {
                            return;
                        }
                        continue;
                    }

                    if !delay_per_get.is_zero() {
                        tokio::time::sleep(delay_per_get).await;
                    }

                    if let Some(ref range_val) = range_hdr {
                        ranges_seen.lock().unwrap().push(range_val.clone());
                        if let Some(spec) = range_val.strip_prefix("bytes=")
                            && let Some((s, e)) = spec.split_once('-')
                            && let (Ok(start), Ok(end)) = (s.parse::<usize>(), e.parse::<usize>())
                        {
                            if start >= payload.len() || end >= payload.len() || start > end {
                                let resp = format!(
                                    "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\n\r\n",
                                    payload.len()
                                );
                                if socket.write_all(resp.as_bytes()).await.is_err()
                                    || socket.flush().await.is_err()
                                {
                                    return;
                                }
                                continue;
                            }
                            let slice = &payload[start..=end];
                            let hdr = format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {start}-{end}/{}\r\nAccept-Ranges: bytes\r\n\r\n",
                                slice.len(),
                                payload.len()
                            );
                            if socket.write_all(hdr.as_bytes()).await.is_err() {
                                return;
                            }
                            if stall_body {
                                if !slice.is_empty() {
                                    let _ = socket.write_all(&slice[..1.min(slice.len())]).await;
                                    let _ = socket.flush().await;
                                }
                                tokio::time::sleep(Duration::from_secs(5)).await;
                                return;
                            }
                            if socket.write_all(slice).await.is_err()
                                || socket.flush().await.is_err()
                            {
                                return;
                            }
                            continue;
                        }
                    }

                    let hdr = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
                        payload.len()
                    );
                    if socket.write_all(hdr.as_bytes()).await.is_err()
                        || socket.write_all(&payload).await.is_err()
                        || socket.flush().await.is_err()
                    {
                        return;
                    }
                }
            });
        }
    });

    MockRangeServer {
        addr,
        ranges_seen,
        head_count,
        delay_per_get,
        stall_body,
    }
}

#[tokio::test]
async fn test_chunked_proxy_adaptive_128k_startup_512k_sequential_and_last_chunk_clamp() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    // 128 KiB initial + 512 KiB sequential + 12_345 byte tail
    let total = DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE + 12_345;
    let payload = Arc::new(make_pattern_bytes(total));
    let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, false).await;

    let url = format!("http://{}/track.flac", server.addr);
    let proxy = ChunkedStreamProxy::new(
        url,
        &BTreeMap::new(),
        None,
        Some("flac".to_string()),
        Some("audio/flac".to_string()),
    )
    .unwrap();

    // 1. Startup fetch uses 128 KiB (0..=131071).
    let mut head_buf = vec![0u8; 64];
    assert_eq!(proxy.read_at(0, &mut head_buf).await.unwrap(), 64);
    assert_eq!(&head_buf[..], &payload[..64]);
    assert_eq!(proxy.len(), Some(total as u64));
    assert_eq!(server.head_count.load(Ordering::SeqCst), 1);

    // 2. Sequential continuation across 128 KiB boundary uses 512 KiB (131072..=655359).
    let mut seq_buf = vec![0u8; 64];
    assert_eq!(
        proxy
            .read_at(DEFAULT_INITIAL_CHUNK_SIZE as u64, &mut seq_buf)
            .await
            .unwrap(),
        64
    );
    assert_eq!(
        &seq_buf[..],
        &payload[DEFAULT_INITIAL_CHUNK_SIZE..DEFAULT_INITIAL_CHUNK_SIZE + 64]
    );

    // 3. Continuation into tail clamps cleanly to total - 1 (no HTTP 416).
    let tail_start = DEFAULT_INITIAL_CHUNK_SIZE + DEFAULT_CHUNK_SIZE;
    let mut tail_buf = vec![0u8; 32_768];
    let n = proxy
        .read_at((tail_start - 16) as u64, &mut tail_buf)
        .await
        .unwrap();
    assert_eq!(n, 16 + 12_345);
    assert_eq!(&tail_buf[..n], &payload[tail_start - 16..]);

    // 4. Reading at or past EOF returns 0 without issuing an HTTP request.
    let ranges_before_eof = server.ranges_seen.lock().unwrap().len();
    assert_eq!(proxy.read_at(total as u64, &mut head_buf).await.unwrap(), 0);
    assert_eq!(
        proxy
            .read_at(total as u64 + 500, &mut head_buf)
            .await
            .unwrap(),
        0
    );
    let ranges = server.ranges_seen.lock().unwrap().clone();
    assert_eq!(ranges.len(), ranges_before_eof);

    let expected_last_end = total - 1;
    assert_eq!(
        ranges,
        vec![
            "bytes=0-131071".to_string(),
            "bytes=131072-655359".to_string(),
            format!("bytes=655360-{expected_last_end}"),
        ]
    );
}

#[tokio::test]
async fn test_chunked_proxy_seek_128k_first_chunk_and_backward_seek_lru_hit() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let total = 2 * 1024 * 1024;
    let payload = Arc::new(make_pattern_bytes(total));
    let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, false).await;

    let url = format!("http://{}/seek.flac", server.addr);
    let proxy =
        ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(total as u64), None, None).unwrap();

    // Startup at 0 -> 128 KiB
    let mut buf = vec![0u8; 256];
    assert_eq!(proxy.read_at(0, &mut buf).await.unwrap(), 256);
    assert_eq!(&buf[..], &payload[0..256]);

    // Discontinuous forward seek to 1 MiB -> first chunk after seek is 128 KiB
    let seek_off = 1024 * 1024usize;
    assert_eq!(proxy.read_at(seek_off as u64, &mut buf).await.unwrap(), 256);
    assert_eq!(&buf[..], &payload[seek_off..seek_off + 256]);

    // Sequential continuation after seek -> 512 KiB
    let next_off = seek_off + DEFAULT_INITIAL_CHUNK_SIZE;
    assert_eq!(proxy.read_at(next_off as u64, &mut buf).await.unwrap(), 256);
    assert_eq!(&buf[..], &payload[next_off..next_off + 256]);

    let ranges_before_back = server.ranges_seen.lock().unwrap().clone();
    assert_eq!(
        ranges_before_back,
        vec![
            "bytes=0-131071".to_string(),
            "bytes=1048576-1179647".to_string(),
            "bytes=1179648-1703935".to_string(),
        ]
    );

    // Short backward seek into previously cached spans -> ZERO HTTP requests!
    assert_eq!(
        proxy
            .read_at(seek_off as u64 + 4096, &mut buf)
            .await
            .unwrap(),
        256
    );
    assert_eq!(&buf[..], &payload[seek_off + 4096..seek_off + 4096 + 256]);
    assert_eq!(proxy.read_at(1024, &mut buf).await.unwrap(), 256);
    assert_eq!(&buf[..], &payload[1024..1280]);

    let ranges_after_back = server.ranges_seen.lock().unwrap().clone();
    assert_eq!(
        ranges_after_back.len(),
        ranges_before_back.len(),
        "backward seeks inside RAM LRU cache must issue zero HTTP requests"
    );
}

#[tokio::test]
async fn test_chunked_proxy_deezer_6144_alignment_129024_and_522240_and_lru_eviction() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let total = 2 * 1024 * 1024 + 137; // intentionally unaligned tail
    let payload = Arc::new(make_pattern_bytes(total));
    let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, false).await;

    let url = format!("http://{}/deezer.bin", server.addr);
    let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(total as u64), None, None)
        .unwrap()
        .with_initial_chunk_size(DEEZER_INITIAL_CHUNK_SIZE)
        .with_chunk_size(DEEZER_ALIGNED_CHUNK_SIZE)
        .with_range_alignment(6144)
        .with_max_cache_bytes(DEEZER_INITIAL_CHUNK_SIZE + DEEZER_ALIGNED_CHUNK_SIZE);

    let mut buf = vec![0u8; 512];
    // Startup -> 129,024 bytes (0..=129023)
    assert_eq!(proxy.read_at(0, &mut buf).await.unwrap(), 512);
    assert_eq!(&buf[..], &payload[0..512]);

    // Sequential -> 522,240 bytes (129024..=651263)
    assert_eq!(
        proxy
            .read_at(DEEZER_INITIAL_CHUNK_SIZE as u64, &mut buf)
            .await
            .unwrap(),
        512
    );
    assert_eq!(
        &buf[..],
        &payload[DEEZER_INITIAL_CHUNK_SIZE..DEEZER_INITIAL_CHUNK_SIZE + 512]
    );

    // Unaligned seek offset (1_000_000) -> snapped down to 6144 boundary (995_328), span 129,024 B
    assert_eq!(proxy.read_at(1_000_000, &mut buf).await.unwrap(), 512);
    assert_eq!(&buf[..], &payload[1_000_000..1_000_512]);

    let ranges = server.ranges_seen.lock().unwrap().clone();
    assert_eq!(
        ranges,
        vec![
            "bytes=0-129023".to_string(),
            "bytes=129024-651263".to_string(),
            "bytes=995328-1124351".to_string(),
        ]
    );
    for r in &ranges {
        let (s, e) = r.strip_prefix("bytes=").unwrap().split_once('-').unwrap();
        let start = s.parse::<usize>().unwrap();
        let end = e.parse::<usize>().unwrap();
        assert_eq!(start % 6144, 0);
        assert!((end + 1) % 6144 == 0 || end + 1 == total);
    }

    // Byte cap evicted the oldest entry (offset 0) when 995328 was inserted
    assert!(proxy.cached_bytes() <= DEEZER_INITIAL_CHUNK_SIZE + DEEZER_ALIGNED_CHUNK_SIZE);
}

#[tokio::test]
async fn test_chunked_proxy_probe_falls_back_from_405_head_to_range_zero() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let payload = Arc::new(make_pattern_bytes(4096));
    let server = spawn_mock_range_server(Arc::clone(&payload), Duration::ZERO, false, true).await;
    let url = format!("http://{}/stream", server.addr);
    let proxy = ChunkedStreamProxy::new(url, &BTreeMap::new(), None, None, None).unwrap();

    let mut out = vec![0u8; 512];
    let n = proxy.read_at(1024, &mut out).await.unwrap();
    assert_eq!(n, 512);
    assert_eq!(&out[..], &payload[1024..1536]);
    assert_eq!(proxy.len(), Some(4096));

    let ranges = server.ranges_seen.lock().unwrap().clone();
    assert_eq!(
        ranges,
        vec!["bytes=0-0".to_string(), "bytes=1024-4095".to_string()]
    );
}

#[tokio::test]
async fn test_chunked_proxy_single_flight_coalescing_and_ram_lru() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let payload = Arc::new(make_pattern_bytes(600_000));
    let server = spawn_mock_range_server(
        Arc::clone(&payload),
        Duration::from_millis(25),
        false,
        false,
    )
    .await;
    let url = format!("http://{}/coalesce.flac", server.addr);
    let proxy = Arc::new(
        ChunkedStreamProxy::new(url, &BTreeMap::new(), Some(600_000), None, None).unwrap(),
    );

    let (r1, r2, r3) = tokio::join!(
        async {
            let mut b = vec![0u8; 128];
            let n = proxy.read_at(0, &mut b).await.unwrap();
            (n, b)
        },
        async {
            let mut b = vec![0u8; 128];
            let n = proxy.read_at(100, &mut b).await.unwrap();
            (n, b)
        },
        async {
            let mut b = vec![0u8; 128];
            let n = proxy.read_at(200, &mut b).await.unwrap();
            (n, b)
        }
    );

    assert_eq!(r1.0, 128);
    assert_eq!(&r1.1[..], &payload[0..128]);
    assert_eq!(&r2.1[..], &payload[100..228]);
    assert_eq!(&r3.1[..], &payload[200..328]);

    let ranges = server.ranges_seen.lock().unwrap().clone();
    assert_eq!(ranges.len(), 1, "concurrent reads of chunk 0 must coalesce");
}
