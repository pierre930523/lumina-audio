use super::*;
use crate::streaming::StreamError;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub(super) async fn spawn_dash_server(
    routes: HashMap<String, Vec<u8>>,
    delay: Duration,
) -> (std::net::SocketAddr, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let hits = Arc::new(Mutex::new(Vec::new()));
    let routes = Arc::new(routes);
    let hits_clone = Arc::clone(&hits);

    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let routes = Arc::clone(&routes);
            let hits = Arc::clone(&hits_clone);
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
                    let path = req_str
                        .lines()
                        .next()
                        .and_then(|l| l.split_whitespace().nth(1))
                        .unwrap_or("/")
                        .to_string();

                    hits.lock().unwrap().push(path.clone());
                    if !delay.is_zero() {
                        tokio::time::sleep(delay).await;
                    }

                    if let Some(body) = routes.get(&path) {
                        let hdr =
                            format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", body.len());
                        if socket.write_all(hdr.as_bytes()).await.is_err()
                            || socket.write_all(body).await.is_err()
                            || socket.flush().await.is_err()
                        {
                            return;
                        }
                    } else {
                        let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
                        if socket.write_all(resp.as_bytes()).await.is_err()
                            || socket.flush().await.is_err()
                        {
                            return;
                        }
                    }
                }
            });
        }
    });

    (addr, hits)
}

#[test]
fn test_parse_iso8601_duration_ms() {
    assert_eq!(parse_iso8601_duration_ms("PT3M45.5S"), Some(225_500));
    assert_eq!(parse_iso8601_duration_ms("PT1H2M3S"), Some(3_723_000));
    assert_eq!(parse_iso8601_duration_ms("P0DT0H0M30.25S"), Some(30_250));
    assert_eq!(parse_iso8601_duration_ms("invalid"), None);
}

#[test]
fn test_mpd_rejects_content_protection_drm() {
    let drm_mpd = r#"<MPD><Period><AdaptationSet contentType="audio"><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation id="1" bandwidth="128000"><BaseURL>https://cdn.example.com/a.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"#;
    let err = parse_mpd_xml(drm_mpd, None).unwrap_err();
    assert!(matches!(err, StreamError::DrmRestricted(_)));

    let namespaced = r#"<MPD><Period><AdaptationSet><cenc:ContentProtection value="cenc"/></AdaptationSet></Period></MPD>"#;
    let err2 = parse_mpd_xml(namespaced, None).unwrap_err();
    assert!(matches!(err2, StreamError::DrmRestricted(_)));
}

#[test]
fn test_mpd_parses_segment_timeline_and_picks_highest_bandwidth_audio() {
    let mpd = r#"<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT12S">
  <BaseURL>https://cdn.example.com/tracks/42/</BaseURL>
  <Period>
<AdaptationSet contentType="video" mimeType="video/mp4">
  <Representation id="vid" bandwidth="5000000">
    <BaseURL>video.mp4</BaseURL>
  </Representation>
</AdaptationSet>
<AdaptationSet contentType="audio" mimeType="audio/mp4">
  <SegmentTemplate initialization="init-$RepresentationID$.mp4" media="chunk-$RepresentationID$-$Number%03d$-$Time$.m4s" timescale="1000" startNumber="1">
    <SegmentTimeline>
      <S t="0" d="2000" r="1"/>
      <S d="3000"/>
    </SegmentTimeline>
  </SegmentTemplate>
  <Representation id="low" bandwidth="320000" codecs="mp4a.40.2"/>
  <Representation id="hires" bandwidth="3200000" codecs="flac"/>
</AdaptationSet>
  </Period>
</MPD>"#;

    let parsed = parse_mpd_xml(mpd, None).unwrap();
    assert_eq!(parsed.bandwidth, 3_200_000);
    assert_eq!(parsed.codecs.as_deref(), Some("flac"));
    assert_eq!(
        parsed.init_url.as_deref(),
        Some("https://cdn.example.com/tracks/42/init-hires.mp4")
    );
    assert_eq!(parsed.segments.len(), 3);
    assert_eq!(
        parsed.segments[0].url,
        "https://cdn.example.com/tracks/42/chunk-hires-001-0.m4s"
    );
    assert_eq!(parsed.segments[0].start_ms, 0);
    assert_eq!(
        parsed.segments[1].url,
        "https://cdn.example.com/tracks/42/chunk-hires-002-2000.m4s"
    );
    assert_eq!(parsed.segments[1].start_ms, 2000);
    assert_eq!(
        parsed.segments[2].url,
        "https://cdn.example.com/tracks/42/chunk-hires-003-4000.m4s"
    );
    assert_eq!(parsed.segments[2].start_ms, 4000);
    assert_eq!(parsed.segments[2].duration_ms, 3000);
}

#[test]
fn test_mpd_parses_fixed_duration_and_segment_list() {
    let fixed_mpd = r#"<MPD mediaPresentationDuration="PT6.5S">
  <Period>
<AdaptationSet mimeType="audio/mp4">
  <Representation id="1" bandwidth="1411200">
    <SegmentTemplate initialization="https://cdn.example.com/init.mp4" media="https://cdn.example.com/s-$Number$.m4s" timescale="44100" duration="88200" startNumber="10"/>
  </Representation>
</AdaptationSet>
  </Period>
</MPD>"#;
    let parsed = parse_mpd_xml(fixed_mpd, None).unwrap();
    assert_eq!(parsed.segments.len(), 4);
    assert_eq!(parsed.segments[0].number, 10);
    assert_eq!(parsed.segments[0].start_ms, 0);
    assert_eq!(parsed.segments[1].start_ms, 2000);
    assert_eq!(parsed.segments[3].url, "https://cdn.example.com/s-13.m4s");

    let list_mpd = r#"<MPD>
  <Period>
<AdaptationSet contentType="audio">
  <Representation id="a" bandwidth="960000">
    <SegmentList timescale="1000" duration="1500">
      <Initialization sourceURL="init.mp4"/>
      <SegmentURL media="seg0.m4s"/>
      <SegmentURL media="seg1.m4s"/>
    </SegmentList>
  </Representation>
</AdaptationSet>
  </Period>
</MPD>"#;
    let parsed_list =
        parse_mpd_xml(list_mpd, Some("https://cdn.example.com/dash/manifest.mpd")).unwrap();
    assert_eq!(
        parsed_list.init_url.as_deref(),
        Some("https://cdn.example.com/dash/init.mp4")
    );
    assert_eq!(parsed_list.segments.len(), 2);
    assert_eq!(
        parsed_list.segments[1].url,
        "https://cdn.example.com/dash/seg1.m4s"
    );
    assert_eq!(parsed_list.segments[1].start_ms, 1500);
}
