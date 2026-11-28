use super::*;
use crate::streaming::{
    BlockingStreamBridge, DEEZER_ALIGNED_CHUNK_SIZE, DEFAULT_DEEZER_BLOCK_SIZE,
    DEFAULT_DEEZER_STRIDE, DecryptingByteStream, HttpResponseData, InMemoryL2HeadCacheStore,
    StreamHttpConfig, StreamHttpTransport, decrypting_stream, read_all_at,
};
use cbc::Encryptor;
use cipher::BlockModeEncrypt;
use cipher::KeyIvInit;
use cipher::inout::InOutBuf;
use core_types::{L2HeadCacheStore, compute_l2_target_bytes};
use reqwest::header::HeaderMap;
use std::collections::BTreeMap;
use std::io::Read;
use std::sync::atomic::AtomicUsize;
use std::time::{Duration, Instant};
use tempfile::TempDir;

struct MockRangeTransport {
    payload: Arc<RwLockPayload>,
    #[allow(clippy::type_complexity)]
    ranges_seen: Arc<Mutex<Vec<Option<(u64, u64)>>>>,
    delay: Duration,
    request_count: Arc<AtomicUsize>,
}

struct RwLockPayload {
    bytes: std::sync::RwLock<Vec<u8>>,
}

impl MockRangeTransport {
    fn new(bytes: Vec<u8>, delay: Duration) -> Self {
        Self {
            payload: Arc::new(RwLockPayload {
                bytes: std::sync::RwLock::new(bytes),
            }),
            ranges_seen: Arc::new(Mutex::new(Vec::new())),
            delay,
            request_count: Arc::new(AtomicUsize::new(0)),
        }
    }
}

#[async_trait]
impl StreamHttpTransport for MockRangeTransport {
    async fn execute(
        &self,
        req: super::super::HttpRequestSpec,
        _read_body: bool,
        _config: &StreamHttpConfig,
        cancel: &CancellationToken,
    ) -> Result<HttpResponseData, StreamError> {
        self.request_count.fetch_add(1, Ordering::SeqCst);
        self.ranges_seen.lock().unwrap().push(req.range);
        if !self.delay.is_zero() {
            tokio::select! {
                _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                _ = tokio::time::sleep(self.delay) => {}
            }
        }
        let data = self.payload.bytes.read().unwrap().clone();
        let total = data.len() as u64;
        let (s, e) = req.range.unwrap_or((0, total.saturating_sub(1)));
        if s >= total || e >= total || s > e {
            return Ok(HttpResponseData {
                status: 416,
                final_url: req.url,
                headers: HeaderMap::new(),
                content_length: Some(0),
                content_range_total: Some(total),
                body: Bytes::new(),
            });
        }
        let slice = Bytes::copy_from_slice(&data[s as usize..=e as usize]);
        Ok(HttpResponseData {
            status: 206,
            final_url: req.url,
            headers: HeaderMap::new(),
            content_length: Some(slice.len() as u64),
            content_range_total: Some(total),
            body: slice,
        })
    }
}

fn make_pattern(len: usize, seed: u8) -> Vec<u8> {
    (0..len)
        .map(|i| ((i * 37 + (i >> 8) * 13 + seed as usize) & 0xFF) as u8)
        .collect()
}

fn test_l2_cfg(dir: &TempDir) -> super::super::L2CacheConfig {
    super::super::L2CacheConfig::new(dir.path())
        .with_access_flush_interval(Duration::from_secs(3600))
        .with_orphan_sweep_delay(Duration::from_secs(3600))
}

#[tokio::test]
async fn test_hybrid_stream_zero_latency_head_overlap_and_boundary_splice() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store, test_l2_cfg(&tmp)).unwrap());

    let total_len = 128 * 1024 + 4096;
    let cached_len = 64 * 1024;
    let full_payload = make_pattern(total_len, 1);

    let key = StreamKey::new("qobuz", "hybrid_ok", "27");
    l2.store_direct_head(&key, &full_payload[..cached_len], Some(total_len as u64), 0)
        .await
        .unwrap();
    let hit = l2.lookup_direct_head(&key).await.unwrap().unwrap();

    // Remote transport adds a 120ms network delay; local head read must finish far faster.
    let transport = Arc::new(MockRangeTransport::new(
        full_payload.clone(),
        Duration::from_millis(120),
    ));
    let proxy = Arc::new(
        ChunkedStreamProxy::with_transport(
            "https://cdn.example.com/track.flac",
            &BTreeMap::new(),
            Some(total_len as u64),
            Some("flac".to_string()),
            Some("audio/flac".to_string()),
            transport.clone(),
        )
        .unwrap()
        .with_initial_chunk_size(32 * 1024)
        .with_chunk_size(64 * 1024),
    );

    let hybrid = HybridByteStream::new(key, hit, proxy, Arc::clone(&l2), None).unwrap();
    assert_eq!(hybrid.len(), Some(total_len as u64));

    // 1. Local prefix read completes immediately (<20ms) despite 120ms remote latency.
    let started = Instant::now();
    let mut head_buf = vec![0u8; 4096];
    let n = hybrid.read_at(0, &mut head_buf).await.unwrap();
    assert_eq!(n, 4096);
    assert!(started.elapsed() < Duration::from_millis(40));
    assert_eq!(&head_buf[..], &full_payload[..4096]);

    // 2. Boundary-straddling read splices local [cached_len - 1024 .. cached_len) + remote [cached_len ..).
    let straddle_off = (cached_len - 1024) as u64;
    let mut straddle_buf = vec![0u8; 4096];
    let n_straddle = read_all_at(&hybrid, straddle_off, &mut straddle_buf)
        .await
        .unwrap();
    assert_eq!(n_straddle, 4096);
    assert_eq!(
        &straddle_buf[..],
        &full_payload[straddle_off as usize..straddle_off as usize + 4096]
    );

    // 3. Full read matches remote byte-for-byte.
    let mut full_out = vec![0u8; total_len];
    let n_all = read_all_at(&hybrid, 0, &mut full_out).await.unwrap();
    assert_eq!(n_all, total_len);
    assert_eq!(full_out, full_payload);

    // Confirm first range started at cached_len - 64!
    let ranges = transport.ranges_seen.lock().unwrap().clone();
    assert_eq!(
        ranges[0],
        Some((
            (cached_len - 64) as u64,
            (cached_len + 32 * 1024 - 1) as u64
        ))
    );

    drop(hybrid);
    l2.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_hybrid_stream_deezer_6144_alignment_and_decrypting_wrapper() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store, test_l2_cfg(&tmp)).unwrap());

    let total_len = 6144 * 110 + 777;
    let plaintext = make_pattern(total_len, 9);
    let track_id = "987654321";
    let bf_key = decrypting_stream::derive_deezer_blowfish_key(track_id);

    let mut encrypted = plaintext.clone();
    for (idx, block) in encrypted.chunks_mut(DEFAULT_DEEZER_BLOCK_SIZE).enumerate() {
        if block.len() == DEFAULT_DEEZER_BLOCK_SIZE && idx % DEFAULT_DEEZER_STRIDE == 0 {
            let mut enc = Encryptor::<blowfish::Blowfish>::new_from_slices(
                &bf_key,
                &decrypting_stream::DEEZER_BLOWFISH_IV,
            )
            .unwrap();
            let (blocks, _) = InOutBuf::from(block).into_chunks();
            enc.encrypt_blocks_inout(blocks);
        }
    }

    let target = compute_l2_target_bytes("deezer", Some(320_000), Some(total_len as u64), false);
    assert_eq!(target % 6144, 0);
    assert!(target < total_len as u64);

    let key = StreamKey::new("deezer", track_id, "FLAC");
    l2.store_direct_head(
        &key,
        &encrypted[..target as usize],
        Some(total_len as u64),
        0,
    )
    .await
    .unwrap();
    let hit = l2.lookup_direct_head(&key).await.unwrap().unwrap();

    let transport = Arc::new(MockRangeTransport::new(encrypted, Duration::ZERO));
    let proxy = Arc::new(
        ChunkedStreamProxy::with_transport(
            "https://e-cdns.dzcdn.net/stream",
            &BTreeMap::new(),
            Some(total_len as u64),
            Some("flac".to_string()),
            Some("audio/flac".to_string()),
            transport.clone(),
        )
        .unwrap()
        .with_expected_kind("encrypted_range")
        .with_chunk_size(DEEZER_ALIGNED_CHUNK_SIZE)
        .with_range_alignment(6144),
    );

    let hybrid = Arc::new(HybridByteStream::new(key, hit, proxy, Arc::clone(&l2), None).unwrap());
    let decrypting = Arc::new(DecryptingByteStream::new(hybrid, track_id).unwrap());
    let mut bridge = BlockingStreamBridge::new(decrypting).unwrap();

    let expected = plaintext.clone();
    tokio::task::spawn_blocking(move || {
        let mut decoded = Vec::with_capacity(total_len);
        let mut chunk = [0u8; 8192];
        loop {
            let n = bridge.read(&mut chunk).unwrap();
            if n == 0 {
                break;
            }
            decoded.extend_from_slice(&chunk[..n]);
        }
        assert_eq!(decoded, expected);
    })
    .await
    .unwrap();

    // Confirm overlap fetch started at target - 64 and subsequent read-ahead aligned on 6144!
    let ranges = transport.ranges_seen.lock().unwrap().clone();
    assert_eq!(ranges[0].unwrap().0, target - 64);
    for &(s, _) in ranges.iter().skip(1).flatten() {
        assert_eq!(
            s % 6144,
            0,
            "subsequent range start {s} must remain 6144-aligned"
        );
    }

    l2.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_hybrid_stream_format_mismatch_preserves_head_and_cleans_l2() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store.clone(), test_l2_cfg(&tmp)).unwrap());

    let old_payload = make_pattern(4096, 2);
    let mut new_payload = make_pattern(4096, 2);
    // Corrupt byte at cached_len - 10 so the 64-byte tail fingerprint mismatches!
    new_payload[1024 - 10] ^= 0xFF;

    let key = StreamKey::new("youtube_music", "vid_mismatch", "opus");
    l2.store_direct_head(&key, &old_payload[..1024], Some(4096), 0)
        .await
        .unwrap();
    let hit = l2.lookup_direct_head(&key).await.unwrap().unwrap();

    let mismatch_events = Arc::new(Mutex::new(Vec::new()));
    let events_clone = Arc::clone(&mismatch_events);
    let cb: FormatMismatchCallback = Arc::new(move |k, reason| {
        events_clone.lock().unwrap().push((k, reason));
    });

    let transport = Arc::new(MockRangeTransport::new(new_payload, Duration::ZERO));
    let proxy = Arc::new(
        ChunkedStreamProxy::with_transport(
            "https://rr1.googlevideo.com/audio",
            &BTreeMap::new(),
            Some(4096),
            Some("webm".to_string()),
            Some("audio/webm".to_string()),
            transport,
        )
        .unwrap(),
    );

    let hybrid = HybridByteStream::new(key.clone(), hit, proxy, Arc::clone(&l2), Some(cb)).unwrap();
    let err = hybrid.wait_verified().await.unwrap_err();
    assert!(matches!(err, StreamError::Io(_)));
    assert_eq!(
        hybrid.mismatch_reason(),
        Some(FormatMismatchReason::TailFingerprintMismatch)
    );

    // Stale L2 row + file must already be deleted, and callback fired once.
    assert!(store.get(&key).await.unwrap().is_none());
    assert_eq!(mismatch_events.lock().unwrap().len(), 1);

    // Active Deck MUST still read inside [0, cached_bytes) cleanly without dropping audio!
    let mut head_buf = vec![0u8; 1024];
    let n = read_all_at(&hybrid, 0, &mut head_buf).await.unwrap();
    assert_eq!(n, 1024);
    assert_eq!(head_buf, old_payload[..1024]);

    // Reading beyond cached_bytes returns clean EOF (0) so Active Deck's decoder never dies
    // before the Standby Deck's +800ms takeover.
    let mut remote_buf = [0u8; 64];
    assert_eq!(hybrid.read_at(1024, &mut remote_buf).await.unwrap(), 0);

    drop(hybrid);
    l2.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_hybrid_stream_content_length_change_detected() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store.clone(), test_l2_cfg(&tmp)).unwrap());

    let old_payload = make_pattern(4096, 5);
    let new_payload = make_pattern(8192, 5); // Same prefix, changed total length!

    let key = StreamKey::new("qobuz", "len_changed", "27");
    l2.store_direct_head(&key, &old_payload[..1024], Some(4096), 0)
        .await
        .unwrap();
    let hit = l2.lookup_direct_head(&key).await.unwrap().unwrap();

    let transport = Arc::new(MockRangeTransport::new(new_payload, Duration::ZERO));
    let proxy = Arc::new(
        ChunkedStreamProxy::with_transport(
            "https://cdn.example.com/track.flac",
            &BTreeMap::new(),
            Some(4096),
            Some("flac".to_string()),
            Some("audio/flac".to_string()),
            transport,
        )
        .unwrap(),
    );

    let hybrid = HybridByteStream::new(key.clone(), hit, proxy, Arc::clone(&l2), None).unwrap();
    assert!(hybrid.wait_verified().await.is_err());
    assert_eq!(
        hybrid.mismatch_reason(),
        Some(FormatMismatchReason::ContentLengthChanged {
            expected: 4096,
            actual: 8192,
        })
    );
    assert!(store.get(&key).await.unwrap().is_none());

    drop(hybrid);
    l2.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_hybrid_stream_tiny_file_under_64_bytes() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store, test_l2_cfg(&tmp)).unwrap());

    let payload = make_pattern(48, 3);
    let key = StreamKey::new("qobuz", "tiny_48", "27");
    l2.store_direct_head(&key, &payload[..24], Some(48), 0)
        .await
        .unwrap();
    let hit = l2.lookup_direct_head(&key).await.unwrap().unwrap();

    let transport = Arc::new(MockRangeTransport::new(payload.clone(), Duration::ZERO));
    let proxy = Arc::new(
        ChunkedStreamProxy::with_transport(
            "https://cdn.example.com/tiny.flac",
            &BTreeMap::new(),
            Some(48),
            Some("flac".to_string()),
            Some("audio/flac".to_string()),
            transport,
        )
        .unwrap(),
    );

    let hybrid = HybridByteStream::new(key, hit, proxy, Arc::clone(&l2), None).unwrap();
    hybrid.wait_verified().await.unwrap();

    let mut out = vec![0u8; 48];
    let n = read_all_at(&hybrid, 0, &mut out).await.unwrap();
    assert_eq!(n, 48);
    assert_eq!(out, payload);

    drop(hybrid);
    l2.shutdown().await.unwrap();
}
