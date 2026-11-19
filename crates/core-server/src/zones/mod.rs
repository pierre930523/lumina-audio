pub mod airplay;
pub mod clock_sync;
pub mod dlna;

pub use airplay::{AirPlayClient, AirPlaySessionInfo};
pub use clock_sync::{
    aligned_start_delay_us, estimate_drift_ppm, measure_clock_sync, sync_json_once, sync_sntp_once,
    ClockSyncMeasurement, ClockSyncSample,
};
pub use dlna::{discover_dlna_devices, DlnaController, DlnaDeviceDescriptor, DlnaPositionInfo, DEFAULT_SSDP_ADDR};

use anyhow::{anyhow, Result};
use chrono::Utc;
use core_audio::AudioPlayer;
use core_db::SqlitePool;
use core_types::OutputBackendKind;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneInfo {
    pub id: String,
    pub name: String,
    pub backend: String,
    pub device_id: Option<String>,
    pub endpoint_url: Option<String>,
    pub control_url: Option<String>,
    pub rendering_url: Option<String>,
    pub clock_sync_addr: Option<String>,
    pub group_id: Option<String>,
    pub exclusive_mode: bool,
    pub dsp_bypass: bool,
    pub volume: f32,
    pub is_active: bool,
    pub clock_offset_us: Option<i64>,
    pub rtt_us: Option<i64>,
    pub drift_ppm: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ZoneDiscoverRequest {
    pub ssdp_addr: Option<String>,
    pub airplay_addrs: Option<Vec<String>>,
    pub clock_sync_addr: Option<String>,
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneGroupRequest {
    pub group_id: String,
    pub zone_ids: Vec<String>,
    pub master_pts_us: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZoneGroupStatus {
    pub group_id: String,
    pub zone_ids: Vec<String>,
    pub scheduled_delays_us: HashMap<String, i64>,
}

#[derive(Clone)]
pub struct ZoneManager {
    zones: Arc<RwLock<HashMap<String, ZoneInfo>>>,
    db_pool: Option<SqlitePool>,
}

impl ZoneManager {
    pub fn new(db_pool: Option<SqlitePool>) -> Self {
        let mut initial = HashMap::new();
        initial.insert(
            "zone-local".to_string(),
            ZoneInfo {
                id: "zone-local".to_string(),
                name: "Local DAC".to_string(),
                backend: OutputBackendKind::WindowsWasapiShared.as_str().to_string(),
                device_id: None,
                endpoint_url: None,
                control_url: None,
                rendering_url: None,
                clock_sync_addr: None,
                group_id: None,
                exclusive_mode: false,
                dsp_bypass: false,
                volume: 1.0,
                is_active: true,
                clock_offset_us: Some(0),
                rtt_us: Some(0),
                drift_ppm: Some(0.0),
            },
        );
        Self {
            zones: Arc::new(RwLock::new(initial)),
            db_pool,
        }
    }

    pub async fn list_zones(&self) -> Vec<ZoneInfo> {
        let map = self.zones.read().await;
        let mut list: Vec<ZoneInfo> = map.values().cloned().collect();
        list.sort_by(|a, b| a.id.cmp(&b.id));
        list
    }

    pub async fn get_zone(&self, id: &str) -> Option<ZoneInfo> {
        self.zones.read().await.get(id).cloned()
    }

    pub async fn upsert_zone(&self, zone: ZoneInfo) -> ZoneInfo {
        if let Some(ref pool) = self.db_pool {
            let now = Utc::now().to_rfc3339();
            let _ = sqlx::query(
                "INSERT INTO zones (id, name, backend, device_id, exclusive_mode, dsp_bypass, \
                 dsp_config_json, group_id, volume, is_active, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?) \
                 ON CONFLICT(id) DO UPDATE SET \
                 name = excluded.name, backend = excluded.backend, device_id = excluded.device_id, \
                 exclusive_mode = excluded.exclusive_mode, dsp_bypass = excluded.dsp_bypass, \
                 group_id = excluded.group_id, volume = excluded.volume, is_active = excluded.is_active, \
                 updated_at = excluded.updated_at",
            )
            .bind(&zone.id)
            .bind(&zone.name)
            .bind(&zone.backend)
            .bind(&zone.device_id)
            .bind(if zone.exclusive_mode { 1 } else { 0 })
            .bind(if zone.dsp_bypass { 1 } else { 0 })
            .bind(&zone.group_id)
            .bind(zone.volume as f64)
            .bind(if zone.is_active { 1 } else { 0 })
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await;
        }
        self.zones
            .write()
            .await
            .insert(zone.id.clone(), zone.clone());
        zone
    }

    pub async fn sync_local_default_zone(&self, player: Option<&AudioPlayer>) {
        let Some(p) = player else {
            return;
        };
        let devs = p.list_output_devices();
        let chosen = devs
            .iter()
            .find(|d| d.id != "virtual-exclusive-dac" && d.is_default)
            .or_else(|| devs.iter().find(|d| d.id != "virtual-exclusive-dac"))
            .or_else(|| devs.first())
            .cloned();

        let Some(dev) = chosen else {
            return;
        };

        let mut zone = self
            .get_zone("zone-local")
            .await
            .unwrap_or_else(|| ZoneInfo {
                id: "zone-local".to_string(),
                name: "Local DAC".to_string(),
                backend: OutputBackendKind::WindowsWasapiShared.as_str().to_string(),
                device_id: None,
                endpoint_url: None,
                control_url: None,
                rendering_url: None,
                clock_sync_addr: None,
                group_id: None,
                exclusive_mode: false,
                dsp_bypass: false,
                volume: 1.0,
                is_active: true,
                clock_offset_us: Some(0),
                rtt_us: Some(0),
                drift_ppm: Some(0.0),
            });

        zone.device_id = Some(dev.id);
        zone.name = dev.name;
        zone.backend = dev.backend.as_str().to_string();
        zone.exclusive_mode = dev.is_exclusive;
        self.upsert_zone(zone).await;
    }

    /// Synchronous in-memory helper safe to call inside `AppState::with_player`
    /// regardless of whether a Tokio runtime is active on the current thread.
    pub fn sync_local_default_zone_in_memory(&self, player: Option<&AudioPlayer>) {
        let Some(p) = player else {
            return;
        };
        let devs = p.list_output_devices();
        let chosen = devs
            .iter()
            .find(|d| d.id != "virtual-exclusive-dac" && d.is_default)
            .or_else(|| devs.iter().find(|d| d.id != "virtual-exclusive-dac"))
            .or_else(|| devs.first())
            .cloned();
        let Some(dev) = chosen else {
            return;
        };
        if let Ok(mut map) = self.zones.try_write()
            && let Some(zone) = map.get_mut("zone-local")
        {
            zone.device_id = Some(dev.id);
            zone.name = dev.name;
            zone.backend = dev.backend.as_str().to_string();
            zone.exclusive_mode = dev.is_exclusive;
        }
    }

    pub async fn sync_local_zone_selected_device(
        &self,
        device_id: Option<&str>,
        player: Option<&AudioPlayer>,
    ) {
        let Some(mut zone) = self.get_zone("zone-local").await else {
            return;
        };
        if let Some(id) = device_id
            && let Some(p) = player
            && let Some(dev) = p.list_output_devices().into_iter().find(|d| d.id == id)
        {
            zone.device_id = Some(dev.id);
            zone.name = dev.name;
            zone.backend = dev.backend.as_str().to_string();
            zone.exclusive_mode = dev.is_exclusive;
            self.upsert_zone(zone).await;
            return;
        }
        if device_id.is_none() {
            self.sync_local_default_zone(player).await;
        }
    }

    pub async fn discover_zones(
        &self,
        player: Option<&AudioPlayer>,
        req: ZoneDiscoverRequest,
    ) -> Result<Vec<ZoneInfo>> {
        let timeout = Duration::from_millis(req.timeout_ms.unwrap_or(400).clamp(50, 5000));

        if let Some(p) = player {
            for dev in p.list_output_devices() {
                let zid = format!("zone-local-{}", dev.id.replace([':', ' ', '/'], "_"));
                let existing = self.get_zone(&zid).await;
                let zone = ZoneInfo {
                    id: zid,
                    name: dev.name,
                    backend: dev.backend.as_str().to_string(),
                    device_id: Some(dev.id),
                    endpoint_url: None,
                    control_url: None,
                    rendering_url: None,
                    clock_sync_addr: existing.as_ref().and_then(|z| z.clock_sync_addr.clone()),
                    group_id: existing.as_ref().and_then(|z| z.group_id.clone()),
                    exclusive_mode: dev.is_exclusive,
                    dsp_bypass: p.is_dsp_bypassed(),
                    volume: existing.as_ref().map(|z| z.volume).unwrap_or_else(|| p.volume()),
                    is_active: existing.as_ref().map(|z| z.is_active).unwrap_or(dev.is_default),
                    clock_offset_us: existing.as_ref().and_then(|z| z.clock_offset_us).or(Some(0)),
                    rtt_us: existing.as_ref().and_then(|z| z.rtt_us).or(Some(0)),
                    drift_ppm: existing.as_ref().and_then(|z| z.drift_ppm).or(Some(0.0)),
                };
                self.upsert_zone(zone).await;
            }
        }

        if let Some(ssdp_addr) = req.ssdp_addr.as_deref() {
            let discovered = discover_dlna_devices(ssdp_addr, timeout).await?;
            for dev in discovered {
                let zid = format!("dlna:{}", dev.udn);
                let zone = ZoneInfo {
                    id: zid,
                    name: dev.friendly_name,
                    backend: OutputBackendKind::NetworkDlna.as_str().to_string(),
                    device_id: Some(dev.udn),
                    endpoint_url: Some(dev.location),
                    control_url: Some(dev.av_transport_control_url),
                    rendering_url: Some(dev.rendering_control_url),
                    clock_sync_addr: req.clock_sync_addr.clone(),
                    group_id: None,
                    exclusive_mode: false,
                    dsp_bypass: true,
                    volume: 0.5,
                    is_active: false,
                    clock_offset_us: None,
                    rtt_us: None,
                    drift_ppm: None,
                };
                self.upsert_zone(zone).await;
            }
        }

        if let Some(airplay_list) = req.airplay_addrs {
            for addr in airplay_list {
                let clean = addr.strip_prefix("rtsp://").unwrap_or(&addr).to_string();
                let mut client = AirPlayClient::connect(&clean).await?;
                client.options().await?;
                let zid = format!("airplay:{}", clean.replace(':', "_"));
                let zone = ZoneInfo {
                    id: zid,
                    name: format!("AirPlay ({clean})"),
                    backend: OutputBackendKind::NetworkAirPlay.as_str().to_string(),
                    device_id: Some(clean.clone()),
                    endpoint_url: Some(format!("rtsp://{clean}")),
                    control_url: None,
                    rendering_url: None,
                    clock_sync_addr: req.clock_sync_addr.clone(),
                    group_id: None,
                    exclusive_mode: false,
                    dsp_bypass: true,
                    volume: 0.5,
                    is_active: false,
                    clock_offset_us: None,
                    rtt_us: None,
                    drift_ppm: None,
                };
                self.upsert_zone(zone).await;
            }
        }

        Ok(self.list_zones().await)
    }

    pub async fn group_zones(&self, req: ZoneGroupRequest) -> Result<ZoneGroupStatus> {
        let mut delays = HashMap::new();
        let now_us = clock_sync::now_unix_us();
        let master_pts = req.master_pts_us.unwrap_or(now_us + 250_000);

        let mut updates = Vec::new();
        {
            let map = self.zones.read().await;
            for zid in &req.zone_ids {
                let mut zone = map
                    .get(zid)
                    .cloned()
                    .ok_or_else(|| anyhow!("Zone not found: {zid}"))?;
                zone.group_id = Some(req.group_id.clone());
                let offset = zone.clock_offset_us.unwrap_or(0);
                delays.insert(
                    zid.clone(),
                    aligned_start_delay_us(master_pts, now_us, offset),
                );
                updates.push(zone);
            }
        }

        for z in updates {
            self.upsert_zone(z).await;
        }

        Ok(ZoneGroupStatus {
            group_id: req.group_id,
            zone_ids: req.zone_ids,
            scheduled_delays_us: delays,
        })
    }

    pub async fn set_zone_volume(&self, zone_id: &str, volume: f32) -> Result<ZoneInfo> {
        let clamped = if volume.is_nan() {
            0.0
        } else {
            volume.clamp(0.0, 1.0)
        };

        let mut zone = self
            .get_zone(zone_id)
            .await
            .ok_or_else(|| anyhow!("Zone not found: {zone_id}"))?;

        if zone.backend == OutputBackendKind::NetworkDlna.as_str()
            && let Some(ref rendering_url) = zone.rendering_url
            && !rendering_url.is_empty()
        {
            let ctrl = DlnaController::new();
            ctrl.set_volume(rendering_url, (clamped * 100.0).round() as u8)
                .await?;
        } else if zone.backend == OutputBackendKind::NetworkAirPlay.as_str()
            && let Some(ref endpoint) = zone.endpoint_url
        {
            let db = if clamped <= 0.001 {
                -144.0
            } else {
                -30.0 * (1.0 - clamped)
            };
            let mut client = AirPlayClient::connect(endpoint).await?;
            client.set_volume_db(db).await?;
        }

        zone.volume = clamped;
        Ok(self.upsert_zone(zone).await)
    }

    pub async fn sync_zone_clock(
        &self,
        zone_id: &str,
        clock_addr_override: Option<&str>,
        samples: usize,
        sample_interval_ms: u64,
        use_sntp_binary: bool,
    ) -> Result<ClockSyncMeasurement> {
        let mut zone = self
            .get_zone(zone_id)
            .await
            .ok_or_else(|| anyhow!("Zone not found: {zone_id}"))?;

        let addr = clock_addr_override
            .map(str::to_string)
            .or_else(|| zone.clock_sync_addr.clone())
            .ok_or_else(|| anyhow!("No clock_sync_addr configured for zone {zone_id}"))?;

        let measurement = measure_clock_sync(
            &addr,
            samples,
            sample_interval_ms,
            Duration::from_millis(800),
            use_sntp_binary,
        )
        .await?;

        zone.clock_sync_addr = Some(addr);
        zone.clock_offset_us = Some(measurement.offset_us);
        zone.rtt_us = Some(measurement.rtt_us);
        zone.drift_ppm = Some(measurement.drift_ppm);
        self.upsert_zone(zone).await;

        Ok(measurement)
    }

    pub async fn cast_to_zone(
        &self,
        zone_id: &str,
        action: &str,
        media_uri: Option<&str>,
        seek_secs: Option<u64>,
    ) -> Result<serde_json::Value> {
        let zone = self
            .get_zone(zone_id)
            .await
            .ok_or_else(|| anyhow!("Zone not found: {zone_id}"))?;

        if zone.backend == OutputBackendKind::NetworkDlna.as_str() {
            let ctrl_url = zone
                .control_url
                .as_deref()
                .ok_or_else(|| anyhow!("DLNA zone missing control_url"))?;
            let dlna = DlnaController::new();
            match action {
                "play" => {
                    if let Some(uri) = media_uri {
                        dlna.set_av_transport_uri(ctrl_url, uri, "").await?;
                    }
                    dlna.play(ctrl_url).await?;
                }
                "pause" => dlna.pause(ctrl_url).await?,
                "stop" => dlna.stop(ctrl_url).await?,
                "seek" => dlna.seek_seconds(ctrl_url, seek_secs.unwrap_or(0)).await?,
                _ => return Err(anyhow!("Unsupported DLNA cast action: {action}")),
            }
            let state = dlna.get_transport_state(ctrl_url).await?;
            let pos = dlna.get_position_info(ctrl_url).await?;
            return Ok(serde_json::json!({
                "zone_id": zone_id,
                "backend": zone.backend,
                "transport_state": state,
                "position_secs": pos.position_secs,
                "track_uri": pos.track_uri,
            }));
        }

        if zone.backend == OutputBackendKind::NetworkAirPlay.as_str() {
            let endpoint = zone
                .endpoint_url
                .as_deref()
                .ok_or_else(|| anyhow!("AirPlay zone missing endpoint_url"))?;
            let mut client = AirPlayClient::connect(endpoint).await?;
            client.options().await?;
            client.announce_pcm_sdp().await?;
            let session = client.setup().await?;
            let latency = client.record().await?;
            let silence = vec![0u8; 352 * 4];
            let frames = vec![silence.as_slice(), silence.as_slice()];
            let rtp_sent = client.send_rtp_frames(&frames, 0x4C55_4D4E).await?;
            if action == "stop" {
                client.teardown().await?;
            }
            return Ok(serde_json::json!({
                "zone_id": zone_id,
                "backend": zone.backend,
                "session_id": session.session_id,
                "server_port": session.server_port,
                "audio_latency": latency,
                "rtp_packets_sent": rtp_sent,
            }));
        }

        Err(anyhow!(
            "Cast operation requires a DLNA or AirPlay network zone"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
