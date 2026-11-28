use super::{ZoneDiscoverRequest, ZoneManager};
use core_audio::AudioPlayer;

#[tokio::test]
async fn test_zone_local_default_not_virtual_and_discover_preserves_state() {
    let mgr = ZoneManager::new(None);
    let initial = mgr.get_zone("zone-local").await.expect("zone-local exists");
    assert_eq!(initial.device_id, None);

    // Customize volume and group before syncing/discovering
    mgr.set_zone_volume("zone-local", 0.62).await.unwrap();
    let mut z = mgr.get_zone("zone-local").await.unwrap();
    z.group_id = Some("grp-test".to_string());
    mgr.upsert_zone(z).await;

    let player = AudioPlayer::new_headless();
    mgr.sync_local_default_zone(Some(&player)).await;
    let synced = mgr.get_zone("zone-local").await.unwrap();
    assert!((synced.volume - 0.62).abs() < 1e-4);
    assert_eq!(synced.group_id.as_deref(), Some("grp-test"));
    assert!(synced.device_id.is_some());

    // First discover creates zone-local-* entries
    let discovered = mgr
        .discover_zones(Some(&player), ZoneDiscoverRequest::default())
        .await
        .unwrap();
    let local_sub_id = discovered
        .iter()
        .find(|item| item.id.starts_with("zone-local-"))
        .expect("discovered local sub-zone")
        .id
        .clone();

    // Set custom volume & active flag on discovered zone, then re-discover
    mgr.set_zone_volume(&local_sub_id, 0.37).await.unwrap();
    let mut sub = mgr.get_zone(&local_sub_id).await.unwrap();
    sub.is_active = false;
    sub.group_id = Some("grp-sub".to_string());
    mgr.upsert_zone(sub).await;

    mgr.discover_zones(Some(&player), ZoneDiscoverRequest::default())
        .await
        .unwrap();
    let after = mgr.get_zone(&local_sub_id).await.unwrap();
    assert!((after.volume - 0.37).abs() < 1e-4);
    assert!(!after.is_active);
    assert_eq!(after.group_id.as_deref(), Some("grp-sub"));

    player.shutdown();
}
