use super::runtime::Ipv4OnlyDnsResolver;
use super::*;
use cbc::Encryptor;
use cipher::BlockModeEncrypt;
use cipher::KeyIvInit;
use cipher::inout::InOutBuf;
use reqwest::Method;
use reqwest::dns::{Name, Resolve};
use reqwest::header::{ACCEPT_ENCODING, AUTHORIZATION, COOKIE, ORIGIN, RANGE, REFERER, USER_AGENT};
use std::collections::BTreeMap;
use std::io::{Read, Seek, SeekFrom};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

#[tokio::test]
async fn test_manual_redirect_preserves_caller_headers_and_range() {
    let _guard = GLOBAL_DL_TEST_GUARD.lock().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let seen_headers = Arc::new(Mutex::new(Vec::<String>::new()));
    let seen_clone = Arc::clone(&seen_headers);

    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let seen_headers = Arc::clone(&seen_clone);
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
                    let req = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                    let path = req
                        .lines()
                        .next()
                        .and_then(|l| l.split_whitespace().nth(1))
                        .unwrap_or("/");
                    seen_headers.lock().unwrap().push(req.clone());

                    let resp = if path == "/hop1" {
                        format!(
                            "HTTP/1.1 302 Found\r\nLocation: http://{addr}/final\r\nContent-Length: 0\r\n\r\n"
                        )
                        .into_bytes()
                    } else {
                        let body = b"REDIRECT_OK";
                        format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes 0-10/11\r\n\r\n",
                            body.len()
                        )
                        .into_bytes()
                        .into_iter()
                        .chain(body.iter().copied())
                        .collect()
                    };
                    if socket.write_all(&resp).await.is_err() || socket.flush().await.is_err() {
                        return;
                    }
                }
            });
        }
    });

    let mut custom = BTreeMap::new();
    custom.insert("Authorization".to_string(), "Bearer secret-tok".to_string());
    custom.insert(
        "Referer".to_string(),
        "https://music.example.com/".to_string(),
    );
    custom.insert("User-Agent".to_string(), "LuminaTest/1.0".to_string());
    let headers = build_sanitized_headers(&custom).unwrap();

    let transport = ReqwestStreamTransport::shared().unwrap();
    let req = HttpRequestSpec {
        method: Method::GET,
        url: format!("http://{addr}/hop1"),
        headers,
        range: Some((0, 10)),
    };
    let cancel = CancellationToken::new();
    let resp = transport
        .execute(req, true, &StreamHttpConfig::default(), &cancel)
        .await
        .unwrap();

    assert_eq!(resp.status, 206);
    assert_eq!(resp.final_url, format!("http://{addr}/final"));
    assert_eq!(&resp.body[..], b"REDIRECT_OK");

    let recorded = seen_headers.lock().unwrap();
    assert_eq!(recorded.len(), 2);
    let hop2_lower = recorded[1].to_ascii_lowercase();
    assert!(hop2_lower.contains("authorization: bearer secret-tok"));
    assert!(hop2_lower.contains("referer: https://music.example.com/"));
    assert!(hop2_lower.contains("user-agent: luminatest/1.0"));
    assert!(hop2_lower.contains("range: bytes=0-10"));
}

#[tokio::test]
async fn test_end_to_end_chunked_deezer_decrypt_and_blocking_bridge() {
    let _guard = GLOBAL_DL_TEST_GUARD.lock().await;
    let total = 6144 * 2 + 1234;
    let plaintext: Vec<u8> = (0..total).map(|i| ((i * 29 + 7) & 0xFF) as u8).collect();
    let key = decrypting_stream::derive_deezer_blowfish_key("123456789");

    let mut encrypted = plaintext.clone();
    for (idx, block) in encrypted.chunks_mut(DEFAULT_DEEZER_BLOCK_SIZE).enumerate() {
        if block.len() == DEFAULT_DEEZER_BLOCK_SIZE && idx % DEFAULT_DEEZER_STRIDE == 0 {
            let mut enc = Encryptor::<blowfish::Blowfish>::new_from_slices(
                &key,
                &decrypting_stream::DEEZER_BLOWFISH_IV,
            )
            .unwrap();
            let (blocks, _) = InOutBuf::from(block).into_chunks();
            enc.encrypt_blocks_inout(blocks);
        }
    }
    let wire = Arc::new(encrypted);

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let wire = Arc::clone(&wire);
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
                    let req = String::from_utf8_lossy(&req_buf[..header_end]).into_owned();
                    let range = req
                        .lines()
                        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                        .and_then(|l| l.split_once(':'))
                        .and_then(|(_, v)| v.trim().strip_prefix("bytes="))
                        .and_then(|s| s.split_once('-'))
                        .and_then(|(a, b)| {
                            Some((a.parse::<usize>().ok()?, b.parse::<usize>().ok()?))
                        });
                    let (s, e) = range.unwrap_or((0, wire.len() - 1));
                    let slice = &wire[s..=e.min(wire.len() - 1)];
                    let hdr = format!(
                        "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\nContent-Range: bytes {s}-{e}/{}\r\n\r\n",
                        slice.len(),
                        wire.len()
                    );
                    if socket.write_all(hdr.as_bytes()).await.is_err()
                        || socket.write_all(slice).await.is_err()
                        || socket.flush().await.is_err()
                    {
                        return;
                    }
                }
            });
        }
    });

    let proxy = Arc::new(
        ChunkedStreamProxy::new(
            format!("http://{addr}/deezer.flac"),
            &BTreeMap::new(),
            Some(total as u64),
            Some("flac".to_string()),
            Some("audio/flac".to_string()),
        )
        .unwrap()
        .with_chunk_size(DEEZER_ALIGNED_CHUNK_SIZE),
    );
    let decrypting = Arc::new(DecryptingByteStream::new(proxy, "123456789").unwrap());
    let mut bridge = BlockingStreamBridge::new(decrypting).unwrap();

    let expected = plaintext.clone();
    tokio::task::spawn_blocking(move || {
        let mut full = vec![0u8; total];
        let mut off = 0;
        while off < total {
            let n = bridge.read(&mut full[off..]).unwrap();
            assert!(n > 0);
            off += n;
        }
        assert_eq!(full, expected);

        bridge.seek(SeekFrom::Start(6144 + 333)).unwrap();
        let mut slice = [0u8; 3000];
        let n = bridge.read(&mut slice).unwrap();
        assert_eq!(n, 3000);
        assert_eq!(&slice[..], &expected[6144 + 333..6144 + 333 + 3000]);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn test_streaming_http_client_strict_ipv4_dns_and_local_bind() {
    let resolver = Ipv4OnlyDnsResolver;
    let name: Name = "localhost".parse().unwrap();
    let addrs: Vec<SocketAddr> = resolver.resolve(name).await.unwrap().collect();
    assert!(
        !addrs.is_empty(),
        "localhost must resolve to at least one IPv4 address"
    );
    assert!(
        addrs.iter().all(SocketAddr::is_ipv4),
        "Ipv4OnlyDnsResolver must return IPv4 addresses only, got {addrs:?}"
    );

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        if let Ok((mut socket, _)) = listener.accept().await {
            let mut tmp = [0u8; 512];
            let _ = socket.read(&mut tmp).await;
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                .await;
            let _ = socket.flush().await;
        }
    });

    let client = build_streaming_http_client(Duration::from_secs(2)).unwrap();
    let resp = client
        .get(format!("http://{addr}/ping"))
        .send()
        .await
        .expect("IPv4 loopback request must succeed");
    assert_eq!(resp.status().as_u16(), 200);

    // Local IPv4 socket binding must reject IPv6 targets rather than silently switching IP family.
    let v6_res = client.get("http://[::1]:1/ping").send().await;
    assert!(
        v6_res.is_err(),
        "IPv4-bound streaming client must not connect to IPv6 addresses"
    );
}

#[test]
fn test_build_sanitized_headers_and_google_redirect_scope() {
    let mut raw = BTreeMap::new();
    raw.insert("User-Agent".to_string(), "CustomUA/1.0".to_string());
    raw.insert("Cookie".to_string(), "SID=abc".to_string());
    raw.insert(
        "Origin".to_string(),
        "https://music.youtube.com".to_string(),
    );
    raw.insert(
        "Referer".to_string(),
        "https://music.youtube.com/".to_string(),
    );
    raw.insert("Authorization".to_string(), "Bearer tok".to_string());
    raw.insert(
        "Accept-Encoding".to_string(),
        "gzip, deflate, br".to_string(),
    );
    raw.insert("Range".to_string(), "bytes=0-100".to_string());
    raw.insert("X-Empty".to_string(), "   ".to_string());
    raw.insert("Bad Header Name".to_string(), "val".to_string());
    raw.insert("X-Non-Ascii".to_string(), "caf\u{00e9}".to_string());
    raw.insert("X-Ctl-Inject".to_string(), "ok\r\nEvil: 1".to_string());

    let sanitized = build_sanitized_headers(&raw).unwrap();
    assert_eq!(
        sanitized.get(USER_AGENT).and_then(|v| v.to_str().ok()),
        Some("CustomUA/1.0")
    );
    assert_eq!(
        sanitized.get(COOKIE).and_then(|v| v.to_str().ok()),
        Some("SID=abc")
    );
    assert_eq!(
        sanitized.get(ORIGIN).and_then(|v| v.to_str().ok()),
        Some("https://music.youtube.com")
    );
    assert_eq!(
        sanitized.get(REFERER).and_then(|v| v.to_str().ok()),
        Some("https://music.youtube.com/")
    );
    assert_eq!(
        sanitized.get(AUTHORIZATION).and_then(|v| v.to_str().ok()),
        Some("Bearer tok")
    );
    assert!(!sanitized.contains_key(ACCEPT_ENCODING));
    assert!(!sanitized.contains_key(RANGE));
    assert!(!sanitized.contains_key("x-empty"));
    assert!(!sanitized.contains_key("x-non-ascii"));
    assert!(!sanitized.contains_key("x-ctl-inject"));

    let mut empty_ua = BTreeMap::new();
    empty_ua.insert("User-Agent".to_string(), "   ".to_string());
    empty_ua.insert("Cookie".to_string(), "".to_string());
    let fallback = build_sanitized_headers(&empty_ua).unwrap();
    assert_eq!(
        fallback.get(USER_AGENT).and_then(|v| v.to_str().ok()),
        Some(DEFAULT_STREAM_USER_AGENT)
    );
    assert!(!fallback.contains_key(COOKIE));

    let from = reqwest::Url::parse("https://rr1---sn-a.googlevideo.com/videoplayback").unwrap();
    let to_gvt = reqwest::Url::parse("https://r2---sn-b.gvt1.com/videoplayback").unwrap();
    let to_ext = reqwest::Url::parse("https://cdn.megaphone.fm/episode.mp3").unwrap();
    assert!(same_trusted_redirect_scope(&from, &to_gvt));
    assert!(!same_trusted_redirect_scope(&from, &to_ext));
    assert_eq!(StreamHttpConfig::default().max_redirects, 15);
}
