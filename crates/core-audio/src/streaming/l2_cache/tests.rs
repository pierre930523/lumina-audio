use std::fs;
use std::sync::Arc;
use std::time::Duration;

use super::*;
use core_types::{
    L2_DEEZER_STRIPE_ALIGNMENT, L2_MAX_TARGET_BYTES, L2_MIN_TARGET_BYTES, L2CacheKind,
    L2HeadCacheStore, StreamKey, compute_l2_target_bytes,
};
use sha2::{Digest, Sha256};
use tempfile::TempDir;

fn test_config(dir: &TempDir) -> L2CacheConfig {
    L2CacheConfig::new(dir.path())
        .with_access_flush_interval(Duration::from_secs(3600))
        .with_orphan_sweep_delay(Duration::from_secs(3600))
}

#[test]
fn test_two_level_hash_paths_and_sanitization() {
    let key = StreamKey::new("qobuz", "track/12:34?", "hi_res:192");
    let direct_rel = build_l2_rel_path(&key, L2CacheKind::DirectHead);
    let dash_rel = build_l2_rel_path(&key, L2CacheKind::DashInitSegs);

    let mut hasher = Sha256::new();
    hasher.update(b"qobuz:track/12:34?:hi_res:192");
    let digest = hasher.finalize();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let h2 = &hex[0..2];
    let h4 = &hex[0..4];

    assert_eq!(
        direct_rel,
        format!("cache/l2/qobuz/{h2}/{h4}_track_12_34__hi_res_192.head")
    );
    assert_eq!(
        dash_rel,
        format!("cache/l2/qobuz/{h2}/{h4}_track_12_34__hi_res_192.dash.head")
    );
}

#[test]
fn test_dynamic_target_bytes_and_admission_gate() {
    assert_eq!(
        compute_l2_target_bytes("youtube_music", Some(128_000), Some(4_000_000), false),
        L2_MIN_TARGET_BYTES
    );
    assert_eq!(
        compute_l2_target_bytes("qobuz", Some(4_608_000), Some(80_000_000), false),
        L2_MAX_TARGET_BYTES
    );
    let dz = compute_l2_target_bytes("deezer", Some(1_411_200), Some(30_000_000), false);
    assert_eq!(dz % L2_DEEZER_STRIPE_ALIGNMENT, 0);

    let apple_key = StreamKey::new("apple_music", "999", "lossless");
    assert!(!should_admit_to_l2(
        &apple_key, 524_288, 15_000, 5_000, 1, None, false
    ));

    let local_key = StreamKey::new("local", "/music/a.flac", "native");
    assert!(!should_admit_to_l2(
        &local_key, 524_288, 15_000, 5_000, 1, None, false
    ));

    let ytm_key = StreamKey::new("youtube_music", "abc", "opus_160");
    // Short skip (< min_stable_play_ms) rejected unless pinned
    assert!(!should_admit_to_l2(
        &ytm_key,
        524_288,
        2_500,
        5_000,
        0,
        Some(1_200),
        false
    ));
    assert!(should_admit_to_l2(
        &ytm_key,
        524_288,
        2_500,
        5_000,
        1,
        Some(1_200),
        false
    ));
    // Index beyond target_bytes or seek table at EOF rejected
    assert!(!should_admit_to_l2(
        &ytm_key,
        524_288,
        10_000,
        5_000,
        0,
        Some(600_000),
        false
    ));
    assert!(!should_admit_to_l2(
        &ytm_key, 524_288, 10_000, 5_000, 0, None, true
    ));
    assert!(should_admit_to_l2(
        &ytm_key,
        524_288,
        5_000,
        5_000,
        0,
        Some(1_105),
        false
    ));
}

#[test]
fn test_dash_l2_package_binary_roundtrip_and_caps() {
    let pkg = DashL2Package {
        mime_type: "audio/mp4".to_string(),
        codecs: Some("flac".to_string()),
        bandwidth: Some(2_400_000),
        total_duration_ms: Some(180_000),
        init_bytes: vec![0xAA; 1024],
        segments: vec![
            DashL2SegmentEntry {
                number: 1,
                start_ms: 0,
                duration_ms: 4_000,
                bytes: vec![0x11; 4096],
            },
            DashL2SegmentEntry {
                number: 2,
                start_ms: 4_000,
                duration_ms: 4_000,
                bytes: vec![0x22; 4096],
            },
        ],
    };

    let encoded = pkg.encode().unwrap();
    assert!(encoded.starts_with(L2_DASH_MAGIC));
    let decoded = DashL2Package::decode(&encoded).unwrap();
    assert_eq!(decoded, pkg);
    assert_eq!(decoded.tail_fingerprint(), pkg.tail_fingerprint());

    // >2 segments must be rejected by encode()
    let mut too_many = pkg.clone();
    too_many.segments.push(DashL2SegmentEntry {
        number: 3,
        start_ms: 8_000,
        duration_ms: 4_000,
        bytes: vec![0x33; 128],
    });
    assert!(too_many.encode().is_err());

    // >4 MiB payload must be rejected by encode(), and trim_to_budget caps it cleanly
    let mut huge = DashL2Package {
        mime_type: "audio/mp4".to_string(),
        codecs: Some("flac".to_string()),
        bandwidth: Some(4_600_000),
        total_duration_ms: Some(240_000),
        init_bytes: vec![0x01; 1024],
        segments: vec![
            DashL2SegmentEntry {
                number: 1,
                start_ms: 0,
                duration_ms: 4_000,
                bytes: vec![0x02; 2_500_000],
            },
            DashL2SegmentEntry {
                number: 2,
                start_ms: 4_000,
                duration_ms: 4_000,
                bytes: vec![0x03; 2_500_000],
            },
        ],
    };
    assert!(huge.encode().is_err());
    huge.trim_to_budget(L2_MAX_TARGET_BYTES as usize);
    assert_eq!(huge.segments.len(), 1);
    assert!(huge.encode().is_ok());
}

#[tokio::test]
async fn test_atomic_store_lookup_deferred_access_flush_and_apple_skip() {
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let mgr = L2CacheManager::new(store.clone(), test_config(&tmp)).unwrap();

    let apple_key = StreamKey::new("apple_music", "123", "lossless");
    assert!(
        mgr.store_direct_head(&apple_key, &[1u8; 512], Some(1000), 0)
            .await
            .unwrap()
            .is_none()
    );

    let key = StreamKey::new("qobuz", "777", "27");
    let payload: Vec<u8> = (0..1024).map(|i| (i % 251) as u8).collect();
    let stored = mgr
        .store_direct_head(&key, &payload, Some(10_000_000), 0)
        .await
        .unwrap()
        .expect("qobuz entry must store");

    let abs_path = mgr.resolve_rel_path(&stored.file_rel_path);
    assert!(abs_path.is_file());
    assert_eq!(stored.tail_fingerprint, payload[payload.len() - 64..]);

    // Hot lookup must NOT synchronously update store access_count.
    let hit1 = mgr.lookup_direct_head(&key).await.unwrap().unwrap();
    assert_eq!(&hit1.head_bytes[..], &payload[..]);
    assert!(mgr.is_in_use(&key));
    let row_before_flush = store.get(&key).await.unwrap().unwrap();
    assert_eq!(row_before_flush.access_count, 1);

    drop(hit1);
    assert!(!mgr.is_in_use(&key));

    let hit2 = mgr.lookup_direct_head(&key).await.unwrap().unwrap();
    drop(hit2);

    // Batch flush persists both hits in a single batch.
    let flushed = mgr.flush_pending_access().await.unwrap();
    assert_eq!(flushed, 1);
    let row_after_flush = store.get(&key).await.unwrap().unwrap();
    assert_eq!(row_after_flush.access_count, 3);

    mgr.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_dual_watermark_eviction_skips_leased_and_pinned() {
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let cfg = test_config(&tmp).with_watermarks(2500, 1500);
    let mgr = L2CacheManager::new(store.clone(), cfg).unwrap();

    let k_leased = StreamKey::new("qobuz", "t_leased", "27");
    let k_old_unleased = StreamKey::new("qobuz", "t_old", "27");
    let k_pinned = StreamKey::new("tidal", "t_pinned", "HI_RES");
    let k_newest = StreamKey::new("deezer", "t_new", "FLAC");

    mgr.store_direct_head(&k_leased, &vec![1u8; 700], Some(9000), 0)
        .await
        .unwrap();
    mgr.store_direct_head(&k_old_unleased, &vec![2u8; 900], Some(9000), 0)
        .await
        .unwrap();
    mgr.store_direct_head(&k_pinned, &vec![3u8; 400], Some(9000), 1)
        .await
        .unwrap();

    // Set explicit last_accessed_at timestamps directly via store so eviction ordering
    // is deterministic (pinned=50, leased=100, old=200).
    for (key, ts) in [(&k_leased, 100i64), (&k_old_unleased, 200), (&k_pinned, 50)] {
        let mut rec = store.get(key).await.unwrap().unwrap();
        rec.last_accessed_at = ts;
        store.upsert(&rec).await.unwrap();
    }

    let lease = mgr.acquire_lease(&k_leased);

    // Storing k_newest (800 bytes) pushes total = 700 + 900 + 400 + 800 = 2800 > 2500 high watermark.
    // k_leased (700) is skipped due to active lease -> k_old_unleased (900) and k_newest (800) are evicted
    // -> remaining = 2800 - 1700 = 1100 <= 1500 low watermark, so k_pinned (400) survives!
    mgr.store_direct_head(&k_newest, &vec![4u8; 800], Some(9000), 0)
        .await
        .unwrap();

    // Leased and pinned entries MUST survive.
    assert!(store.get(&k_leased).await.unwrap().is_some());
    assert!(store.get(&k_pinned).await.unwrap().is_some());
    // Unleased oldest MUST be evicted.
    assert!(store.get(&k_old_unleased).await.unwrap().is_none());
    let old_file =
        mgr.resolve_rel_path(&build_l2_rel_path(&k_old_unleased, L2CacheKind::DirectHead));
    assert!(!old_file.exists());

    drop(lease);
    let report = mgr.enforce_watermarks().await.unwrap();
    assert!(report.remaining_bytes <= 1500);
    assert!(store.get(&k_pinned).await.unwrap().is_some());

    mgr.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_orphan_sweep_cleans_tmp_unreferenced_and_dangling_rows() {
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let mgr = L2CacheManager::new(store.clone(), test_config(&tmp)).unwrap();

    // Valid stored entry
    let k_valid = StreamKey::new("qobuz", "valid", "27");
    mgr.store_direct_head(&k_valid, &[9u8; 256], Some(1024), 0)
        .await
        .unwrap();

    // Entry whose file gets deleted externally -> dangling store record
    let k_dangling = StreamKey::new("qobuz", "dangling", "27");
    let rec_dangling = mgr
        .store_direct_head(&k_dangling, &[8u8; 256], Some(1024), 0)
        .await
        .unwrap()
        .unwrap();
    fs::remove_file(mgr.resolve_rel_path(&rec_dangling.file_rel_path)).unwrap();

    // Stray .tmp file and stray unreferenced .head + .dash.head files
    let stray_dir = tmp.path().join("cache").join("l2").join("qobuz").join("aa");
    fs::create_dir_all(&stray_dir).unwrap();
    let stray_tmp = stray_dir.join("aa11_x_27.head.tmp.999.1");
    let stray_head = stray_dir.join("aa11_orphan_27.head");
    let stray_dash = stray_dir.join("aa11_orphan_27.dash.head");
    fs::write(&stray_tmp, b"partial").unwrap();
    fs::write(&stray_head, b"orphan").unwrap();
    fs::write(&stray_dash, b"orphan-dash").unwrap();

    // Leased unreferenced file must NOT be deleted by orphan sweep
    let k_leased_new = StreamKey::new("tidal", "leased_uncommitted", "LOSSLESS");
    let leased_rel = build_l2_rel_path(&k_leased_new, L2CacheKind::DirectHead);
    let leased_abs = mgr.resolve_rel_path(&leased_rel);
    fs::create_dir_all(leased_abs.parent().unwrap()).unwrap();
    fs::write(&leased_abs, b"writing").unwrap();
    let _lease = mgr.acquire_lease(&k_leased_new);

    let report = mgr.run_orphan_sweep().await.unwrap();
    assert_eq!(report.deleted_tmp_files, 1);
    assert_eq!(report.deleted_orphan_files, 2);
    assert_eq!(report.removed_dangling_rows, 1);

    assert!(!stray_tmp.exists());
    assert!(!stray_head.exists());
    assert!(!stray_dash.exists());
    assert!(leased_abs.is_file());
    assert!(store.get(&k_valid).await.unwrap().is_some());
    assert!(store.get(&k_dangling).await.unwrap().is_none());

    mgr.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_dash_head_store_lookup_and_corruption_cleanup() {
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();
    let mgr = L2CacheManager::new(store.clone(), test_config(&tmp)).unwrap();

    let key = StreamKey::new("tidal", "dash_1", "HI_RES");
    let pkg = DashL2Package {
        mime_type: "audio/mp4".to_string(),
        codecs: Some("flac".to_string()),
        bandwidth: Some(3_200_000),
        total_duration_ms: Some(120_000),
        init_bytes: vec![0x10; 256],
        segments: vec![
            DashL2SegmentEntry {
                number: 1,
                start_ms: 0,
                duration_ms: 4_000,
                bytes: vec![0x20; 512],
            },
            DashL2SegmentEntry {
                number: 2,
                start_ms: 4_000,
                duration_ms: 4_000,
                bytes: vec![0x30; 512],
            },
        ],
    };

    let rec = mgr.store_dash_head(&key, &pkg, 0).await.unwrap().unwrap();
    assert_eq!(rec.cache_kind, "dash_init_segs");
    assert!(rec.file_rel_path.ends_with(".dash.head"));

    // Direct lookup must NOT match a dash_init_segs entry.
    assert!(mgr.lookup_direct_head(&key).await.unwrap().is_none());

    let hit = mgr.lookup_dash_head(&key).await.unwrap().unwrap();
    assert_eq!(hit.package, pkg);
    assert!(mgr.is_in_use(&key));
    drop(hit);

    // Corrupt a byte on disk; next lookup detects fingerprint mismatch and cleans up.
    let abs = mgr.resolve_rel_path(&rec.file_rel_path);
    let mut disk_bytes = fs::read(&abs).unwrap();
    let last = disk_bytes.len() - 1;
    disk_bytes[last] ^= 0xFF;
    fs::write(&abs, &disk_bytes).unwrap();

    assert!(mgr.lookup_dash_head(&key).await.unwrap().is_none());
    assert!(!abs.exists());
    assert!(store.get(&key).await.unwrap().is_none());

    mgr.shutdown().await.unwrap();
}

#[tokio::test]
async fn test_background_access_flush_and_delayed_orphan_sweep() {
    let store = Arc::new(InMemoryL2HeadCacheStore::new());
    let tmp = TempDir::new().unwrap();

    let stray_dir = tmp.path().join("cache").join("l2").join("qobuz").join("bb");
    fs::create_dir_all(&stray_dir).unwrap();
    let stray_tmp = stray_dir.join("bb22_stray_27.head.tmp.1.1");
    fs::write(&stray_tmp, b"stale_tmp").unwrap();

    let cfg = L2CacheConfig::new(tmp.path())
        .with_access_flush_interval(Duration::from_millis(30))
        .with_orphan_sweep_delay(Duration::from_millis(20));
    let mgr = L2CacheManager::new(store.clone(), cfg).unwrap();

    let key = StreamKey::new("qobuz", "bg_flush", "27");
    mgr.store_direct_head(&key, &[5u8; 256], Some(1024), 0)
        .await
        .unwrap();
    let hit = mgr.lookup_direct_head(&key).await.unwrap().unwrap();
    drop(hit);

    // Wait briefly for the 20ms delayed orphan sweep & 30ms access flush tasks to run.
    tokio::time::sleep(Duration::from_millis(120)).await;

    assert!(!stray_tmp.exists());
    let row = store.get(&key).await.unwrap().unwrap();
    assert_eq!(row.access_count, 2);

    mgr.shutdown().await.unwrap();
}
