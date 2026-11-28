use super::*;
use crate::streaming::{
    DashL2SegmentEntry, HttpRequestSpec, HttpResponseData, InMemoryL2HeadCacheStore, L2CacheConfig,
    read_all_at,
};
use core_types::L2HeadCacheStore;
use reqwest::header::HeaderMap;
use std::collections::HashMap;
use std::time::Instant;
use tempfile::TempDir;

struct MockDashTransport {
    mpd_xml: String,
    blobs: HashMap<String, Vec<u8>>,
    urls_requested: Arc<Mutex<Vec<String>>>,
    mpd_delay: Duration,
}

#[async_trait]
impl StreamHttpTransport for MockDashTransport {
    async fn execute(
        &self,
        req: HttpRequestSpec,
        _read_body: bool,
        _config: &StreamHttpConfig,
        cancel: &CancellationToken,
    ) -> Result<HttpResponseData, StreamError> {
        self.urls_requested.lock().unwrap().push(req.url.clone());
        if req.url.ends_with(".mpd") && !self.mpd_delay.is_zero() {
            tokio::select! {
                _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                _ = tokio::time::sleep(self.mpd_delay) => {}
            }
        }
        if req.url.ends_with(".mpd") {
            let bytes = Bytes::from(self.mpd_xml.clone().into_bytes());
            return Ok(HttpResponseData {
                status: 200,
                final_url: req.url,
                headers: HeaderMap::new(),
                content_length: Some(bytes.len() as u64),
                content_range_total: None,
                body: bytes,
            });
        }
        if let Some(data) = self.blobs.get(&req.url) {
            let bytes = Bytes::copy_from_slice(data);
            return Ok(HttpResponseData {
                status: 200,
                final_url: req.url,
                headers: HeaderMap::new(),
                content_length: Some(bytes.len() as u64),
                content_range_total: None,
                body: bytes,
            });
        }
        Ok(HttpResponseData {
            status: 404,
            final_url: req.url,
            headers: HeaderMap::new(),
            content_length: Some(0),
            content_range_total: None,
            body: Bytes::new(),
        })
    }
}

fn build_sample_mpd(codecs: &str, seg_dur_ms: u64, seg_count: usize) -> String {
    let total_secs = (seg_dur_ms as f64 * seg_count as f64) / 1000.0;
    let d_ticks = seg_dur_ms;
    let r = seg_count.saturating_sub(1);
    format!(
        r#"<MPD mediaPresentationDuration="PT{total_secs}S">
  <Period>
    <AdaptationSet contentType="audio" mimeType="audio/mp4" codecs="{codecs}">
      <Representation id="flac_1" bandwidth="3200000">
        <SegmentTemplate timescale="1000" startNumber="1" initialization="https://cdn.fresh.example/init.mp4" media="https://cdn.fresh.example/seg_$Number$.m4s">
          <SegmentTimeline>
            <S t="0" d="{d_ticks}" r="{r}"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>"#
    )
}

fn test_l2_cfg(dir: &TempDir) -> L2CacheConfig {
    L2CacheConfig::new(dir.path())
        .with_access_flush_interval(Duration::from_secs(3600))
        .with_orphan_sweep_delay(Duration::from_secs(3600))
}

#[tokio::test]
async fn test_hybrid_segmented_serves_init_seg0_seg1_then_splices_seg2() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store, test_l2_cfg(&tmp)).unwrap());

    let init = b"INIT_BOX_BYTES".to_vec();
    let seg1 = b"SEG_ONE_AUDIO".to_vec();
    let seg2 = b"SEG_TWO_AUDIO".to_vec();
    let seg3 = b"SEG_THREE_FROM_FRESH_CDN".to_vec();
    let seg4 = b"SEG_FOUR_FROM_FRESH_CDN".to_vec();

    let pkg = DashL2Package {
        mime_type: "audio/mp4".to_string(),
        codecs: Some("flac".to_string()),
        bandwidth: Some(3_200_000),
        total_duration_ms: Some(16_000),
        init_bytes: init.clone(),
        segments: vec![
            DashL2SegmentEntry {
                number: 1,
                start_ms: 0,
                duration_ms: 4_000,
                bytes: seg1.clone(),
            },
            DashL2SegmentEntry {
                number: 2,
                start_ms: 4_000,
                duration_ms: 4_000,
                bytes: seg2.clone(),
            },
        ],
    };

    let key = StreamKey::new("tidal", "dash_ok", "HI_RES_LOSSLESS");
    l2.store_dash_head(&key, &pkg, 0).await.unwrap();
    let hit = l2.lookup_dash_head(&key).await.unwrap().unwrap();

    let mut blobs = HashMap::new();
    blobs.insert(
        "https://cdn.fresh.example/seg_3.m4s".to_string(),
        seg3.clone(),
    );
    blobs.insert(
        "https://cdn.fresh.example/seg_4.m4s".to_string(),
        seg4.clone(),
    );
    let transport = Arc::new(MockDashTransport {
        mpd_xml: build_sample_mpd("flac", 4_000, 4),
        blobs,
        urls_requested: Arc::new(Mutex::new(Vec::new())),
        mpd_delay: Duration::from_millis(120),
    });

    let stream = HybridSegmentedStream::new(
        key,
        hit,
        "https://api.tidal.example/track.mpd",
        transport.clone(),
        Arc::clone(&l2),
        CancellationToken::new(),
        HybridSegmentedConfig::default(),
    )
    .unwrap();

    // Local [init + seg_0 + seg_1] MUST be readable in < 40ms despite 120ms MPD fetch!
    let local_expected: Vec<u8> = [init.as_slice(), seg1.as_slice(), seg2.as_slice()].concat();
    let started = Instant::now();
    let mut local_buf = vec![0u8; local_expected.len()];
    let n_local = read_all_at(&stream, 0, &mut local_buf).await.unwrap();
    assert_eq!(n_local, local_expected.len());
    assert_eq!(local_buf, local_expected);
    assert!(started.elapsed() < Duration::from_millis(40));

    // Reading across boundary into segment index 2 (seg_3.m4s) & 3 (seg_4.m4s) splices seamlessly!
    let full_expected: Vec<u8> = [
        init.as_slice(),
        seg1.as_slice(),
        seg2.as_slice(),
        seg3.as_slice(),
        seg4.as_slice(),
    ]
    .concat();
    let mut tail_buf = vec![0u8; seg3.len() + seg4.len()];
    let n_tail = read_all_at(&stream, local_expected.len() as u64, &mut tail_buf)
        .await
        .unwrap();
    assert_eq!(n_tail, tail_buf.len());
    assert_eq!(&[local_buf, tail_buf].concat()[..], &full_expected[..]);

    // Fresh manifest must NEVER re-fetch init.mp4, seg_1.m4s, or seg_2.m4s!
    let urls = transport.urls_requested.lock().unwrap().clone();
    assert!(!urls.iter().any(|u| u.ends_with("init.mp4")));
    assert!(!urls.iter().any(|u| u.ends_with("seg_1.m4s")));
    assert!(!urls.iter().any(|u| u.ends_with("seg_2.m4s")));
    assert!(urls.iter().any(|u| u.ends_with("seg_3.m4s")));

    // Seek to segment 3 (start_ms = 8000) delegates to primed proxy and yields init + seg3 + seg4.
    let seek_target = stream.seek_to_time_ms(8_500).await.unwrap().unwrap();
    assert_eq!(seek_target.segment_index, 2);
    let mut seek_buf = vec![0u8; init.len() + seg3.len() + seg4.len()];
    let n_seek = read_all_at(&stream, 0, &mut seek_buf).await.unwrap();
    assert_eq!(n_seek, seek_buf.len());
    assert_eq!(
        seek_buf,
        [init.as_slice(), seg3.as_slice(), seg4.as_slice()].concat()
    );

    drop(stream);
    l2.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_hybrid_segmented_mismatch_deletes_l2_and_preserves_local_head() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let l2 = Arc::new(L2CacheManager::new(store.clone(), test_l2_cfg(&tmp)).unwrap());

    let init = b"OLD_INIT".to_vec();
    let seg1 = b"OLD_SEG1".to_vec();
    let seg2 = b"OLD_SEG2".to_vec();
    let pkg = DashL2Package {
        mime_type: "audio/mp4".to_string(),
        codecs: Some("flac".to_string()),
        bandwidth: Some(3_200_000),
        total_duration_ms: Some(16_000),
        init_bytes: init.clone(),
        segments: vec![
            DashL2SegmentEntry {
                number: 1,
                start_ms: 0,
                duration_ms: 4_000,
                bytes: seg1.clone(),
            },
            DashL2SegmentEntry {
                number: 2,
                start_ms: 4_000,
                duration_ms: 4_000,
                bytes: seg2.clone(),
            },
        ],
    };

    let key = StreamKey::new("tidal", "dash_mismatch", "HI_RES");
    l2.store_dash_head(&key, &pkg, 0).await.unwrap();
    let hit = l2.lookup_dash_head(&key).await.unwrap().unwrap();

    let mismatch_events = Arc::new(Mutex::new(Vec::new()));
    let events_clone = Arc::clone(&mismatch_events);
    let cb: FormatMismatchCallback = Arc::new(move |k, reason| {
        events_clone.lock().unwrap().push((k, reason));
    });

    // Fresh MPD switched codec from flac to mp4a.40.2!
    let transport = Arc::new(MockDashTransport {
        mpd_xml: build_sample_mpd("mp4a.40.2", 4_000, 4),
        blobs: HashMap::new(),
        urls_requested: Arc::new(Mutex::new(Vec::new())),
        mpd_delay: Duration::ZERO,
    });

    let stream = HybridSegmentedStream::new(
        key.clone(),
        hit,
        "https://api.tidal.example/mismatch.mpd",
        transport,
        Arc::clone(&l2),
        CancellationToken::new(),
        HybridSegmentedConfig {
            on_mismatch: Some(cb),
            ..Default::default()
        },
    )
    .unwrap();

    assert!(stream.wait_ready().await.is_err());
    assert!(matches!(
        stream.mismatch_reason(),
        Some(FormatMismatchReason::DashSpecMismatch { .. })
    ));
    assert_eq!(mismatch_events.lock().unwrap().len(), 1);
    assert!(store.get(&key).await.unwrap().is_none());

    // Local [0, local_end) remains readable cleanly!
    let local_expected: Vec<u8> = [init.as_slice(), seg1.as_slice(), seg2.as_slice()].concat();
    let mut local_buf = vec![0u8; local_expected.len()];
    let n = read_all_at(&stream, 0, &mut local_buf).await.unwrap();
    assert_eq!(n, local_expected.len());
    assert_eq!(local_buf, local_expected);

    // Reading beyond local_end returns clean EOF (0) so Active Deck's decoder never dies
    // before the Standby Deck's +800ms takeover.
    let mut remote_buf = [0u8; 32];
    assert_eq!(
        stream
            .read_at(local_expected.len() as u64, &mut remote_buf)
            .await
            .unwrap(),
        0
    );

    drop(stream);
    l2.shutdown().await.unwrap();
}
