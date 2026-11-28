use super::tests_manifest::spawn_dash_server;
use super::*;
use crate::streaming::{ByteStreamSource, SegmentedSeekTarget, StreamError};
use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::time::Duration;

#[tokio::test]
async fn test_segmented_proxy_virtual_stream_bounded_prefetch_and_timeline_seek() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let mut routes = HashMap::new();
    routes.insert("/init.mp4".to_string(), b"INIT".to_vec());
    for idx in 0..8 {
        routes.insert(
            format!("/seg-{idx}.m4s"),
            format!("SEG{idx:02}").into_bytes(),
        );
    }

    let mpd_xml = r#"<MPD mediaPresentationDuration="PT16S">
  <Period>
<AdaptationSet contentType="audio" mimeType="audio/mp4">
  <Representation id="flac" bandwidth="2000000">
    <SegmentTemplate initialization="/init.mp4" media="/seg-$Number$.m4s" timescale="1000" startNumber="0">
      <SegmentTimeline>
        <S t="0" d="2000" r="7"/>
      </SegmentTimeline>
    </SegmentTemplate>
  </Representation>
</AdaptationSet>
  </Period>
</MPD>"#;
    routes.insert("/manifest.mpd".to_string(), mpd_xml.as_bytes().to_vec());

    let (addr, hits) = spawn_dash_server(routes, Duration::from_millis(5)).await;
    let manifest_url = format!("http://{addr}/manifest.mpd");
    let proxy = SegmentedStreamProxy::open(manifest_url, &BTreeMap::new(), None, None)
        .await
        .unwrap()
        .with_prefetch_ahead(3);

    // Read init + seg 0 + seg 1 sequentially from offset 0.
    let mut buf = [0u8; 14];
    let mut read_total = 0;
    while read_total < buf.len() {
        let n = proxy
            .read_at(read_total as u64, &mut buf[read_total..])
            .await
            .unwrap();
        assert!(n > 0);
        read_total += n;
    }
    assert_eq!(&buf, b"INITSEG00SEG01");

    // Allow bounded prefetch ahead (SEG02, SEG03, SEG04) to finish without fetching SEG05..07.
    tokio::time::sleep(Duration::from_millis(60)).await;
    {
        let recorded = hits.lock().unwrap();
        assert!(recorded.contains(&"/seg-2.m4s".to_string()));
        assert!(recorded.contains(&"/seg-4.m4s".to_string()));
        assert!(
            !recorded.contains(&"/seg-5.m4s".to_string()),
            "prefetch must remain bounded to PREFETCH_AHEAD=3, saw {recorded:?}"
        );
    }

    // Seek by timeline to 10_500ms -> segment 5 (start_ms = 10_000ms), virtual_offset = 0.
    let target = proxy.seek_to_time_ms(10_500).await.unwrap().unwrap();
    assert_eq!(
        target,
        SegmentedSeekTarget {
            virtual_offset: 0,
            segment_index: 5,
            segment_start_ms: 10_000,
        }
    );

    let mut after_seek = [0u8; 9];
    let n = proxy.read_at(0, &mut after_seek).await.unwrap();
    assert_eq!(n, 9);
    assert_eq!(&after_seek, b"INITSEG05");

    // Read until EOF of the remaining window [init, seg5, seg6, seg7].
    let mut rest = [0u8; 16];
    let n_rest = proxy.read_at(9, &mut rest).await.unwrap();
    assert_eq!(n_rest, 10);
    assert_eq!(&rest[..n_rest], b"SEG06SEG07");
    assert_eq!(proxy.read_at(19, &mut rest).await.unwrap(), 0);
}

#[tokio::test]
async fn test_segmented_proxy_seek_cancels_previous_prefetch_and_cancel_clears_downloads() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let mut routes = HashMap::new();
    routes.insert("/init.mp4".to_string(), b"INIT".to_vec());
    for idx in 0..6 {
        routes.insert(
            format!("/seg-{idx}.m4s"),
            format!("SEG{idx:02}").into_bytes(),
        );
    }
    let mpd_xml = r#"<MPD>
  <Period>
<AdaptationSet contentType="audio" mimeType="audio/mp4">
  <Representation id="1" bandwidth="1000000">
    <SegmentTemplate initialization="/init.mp4" media="/seg-$Number$.m4s" timescale="1000" startNumber="0">
      <SegmentTimeline>
        <S t="0" d="2000" r="5"/>
      </SegmentTimeline>
    </SegmentTemplate>
  </Representation>
</AdaptationSet>
  </Period>
</MPD>"#;
    let (addr, _hits) = spawn_dash_server(routes, Duration::from_secs(2)).await;
    let base_url = format!("http://{addr}/manifest.mpd");
    let proxy = Arc::new(
        SegmentedStreamProxy::from_mpd_xml(mpd_xml, Some(&base_url), &BTreeMap::new(), None, None)
            .unwrap(),
    );

    let p2 = Arc::clone(&proxy);
    let slow_read = tokio::spawn(async move {
        let mut buf = [0u8; 4];
        p2.read_at(0, &mut buf).await
    });

    tokio::time::sleep(Duration::from_millis(40)).await;
    assert_eq!(proxy.active_downloads(), 1);

    // Seeking cancels the active window's child token immediately.
    let target = proxy.seek_to_time_ms(6_000).await.unwrap().unwrap();
    assert_eq!(target.segment_index, 3);
    assert_eq!(
        slow_read.await.unwrap().unwrap_err(),
        StreamError::Cancelled
    );
    assert_eq!(proxy.active_downloads(), 0);

    proxy.cancel();
    assert_eq!(proxy.active_downloads(), 0);
}

#[tokio::test]
async fn test_segmented_proxy_backward_seek_hits_ram_lru_and_byte_cap_evicts_oldest() {
    let _guard = crate::streaming::GLOBAL_DL_TEST_GUARD.lock().await;
    let mut routes = HashMap::new();
    routes.insert("/init.mp4".to_string(), b"INIT".to_vec());
    // Each segment is 100 bytes so we can test exact byte-capped LRU eviction cleanly.
    for idx in 0..6 {
        let mut seg = vec![b'0' + (idx as u8); 100];
        seg[0] = b'S';
        seg[1] = b'0' + (idx as u8);
        routes.insert(format!("/seg-{idx}.m4s"), seg);
    }

    let mpd_xml = r#"<MPD mediaPresentationDuration="PT12S">
  <Period>
<AdaptationSet contentType="audio" mimeType="audio/mp4">
  <Representation id="flac" bandwidth="2000000">
    <SegmentTemplate initialization="/init.mp4" media="/seg-$Number$.m4s" timescale="1000" startNumber="0">
      <SegmentTimeline>
        <S t="0" d="2000" r="5"/>
      </SegmentTimeline>
    </SegmentTemplate>
  </Representation>
</AdaptationSet>
  </Period>
</MPD>"#;
    routes.insert("/manifest.mpd".to_string(), mpd_xml.as_bytes().to_vec());

    let (addr, hits) = spawn_dash_server(routes, Duration::ZERO).await;
    let manifest_url = format!("http://{addr}/manifest.mpd");
    let proxy = SegmentedStreamProxy::open(manifest_url, &BTreeMap::new(), None, None)
        .await
        .unwrap()
        .with_prefetch_ahead(0)
        .with_max_cache_bytes(300); // holds at most 3 * 100B segments (+ pinned init)

    // Read init + seg 0 + seg 1
    let mut buf = vec![0u8; 204];
    let mut got = 0;
    while got < buf.len() {
        let n = proxy.read_at(got as u64, &mut buf[got..]).await.unwrap();
        assert!(n > 0);
        got += n;
    }
    assert_eq!(&buf[0..4], b"INIT");
    assert_eq!(&buf[4..6], b"S0");
    assert_eq!(&buf[104..106], b"S1");

    // Forward seek to seg 4 (8_000 ms) and read init + seg 4
    let target = proxy.seek_to_time_ms(8_000).await.unwrap().unwrap();
    assert_eq!(target.segment_index, 4);
    let mut fwd = vec![0u8; 104];
    assert_eq!(proxy.read_at(0, &mut fwd).await.unwrap(), 104);
    assert_eq!(&fwd[0..4], b"INIT");
    assert_eq!(&fwd[4..6], b"S4");

    let hits_before_back = hits.lock().unwrap().len();
    assert_eq!(proxy.cached_segment_bytes(), 300); // seg 0, 1, 4 all resident!

    // Backward seek to seg 0 -> must serve init + seg 0 + seg 1 with ZERO new HTTP downloads!
    let back_target = proxy.seek_to_time_ms(500).await.unwrap().unwrap();
    assert_eq!(back_target.segment_index, 0);
    let mut back_buf = vec![0u8; 204];
    let mut got_back = 0;
    while got_back < back_buf.len() {
        let n = proxy
            .read_at(got_back as u64, &mut back_buf[got_back..])
            .await
            .unwrap();
        assert!(n > 0);
        got_back += n;
    }
    assert_eq!(&back_buf[..], &buf[..]);
    assert_eq!(
        hits.lock().unwrap().len(),
        hits_before_back,
        "backward seek inside DASH LRU cache must issue zero HTTP requests"
    );

    // Now seg 4 is LRU (seg 0 and seg 1 were just touched). Seeking to seg 5 evicts seg 4,
    // keeping cached bytes <= 300 while init_bytes stays pinned (never re-fetched).
    proxy.seek_to_time_ms(10_000).await.unwrap().unwrap();
    let mut s5 = vec![0u8; 104];
    assert_eq!(proxy.read_at(0, &mut s5).await.unwrap(), 104);
    assert_eq!(&s5[0..4], b"INIT");
    assert_eq!(&s5[4..6], b"S5");
    assert!(proxy.cached_segment_bytes() <= 300);
    let init_fetches = hits
        .lock()
        .unwrap()
        .iter()
        .filter(|p| p.as_str() == "/init.mp4")
        .count();
    assert_eq!(
        init_fetches, 1,
        "init segment must remain pinned across LRU evictions"
    );
}
