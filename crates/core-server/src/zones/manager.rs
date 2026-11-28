use super::airplay::AirPlayClient;
use super::clock_sync::{self, ClockSyncMeasurement, aligned_start_delay_us, measure_clock_sync};
use super::dlna::{DlnaController, discover_dlna_devices};
use super::models::{ZoneDiscoverRequest, ZoneGroupRequest, ZoneGroupStatus};
use anyhow::{Result, anyhow};
use core_audio::AudioPlayer;
use core_db::{SqlitePool, ZonesRepository};
use core_types::{OutputBackendKind, ZoneInfo};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

#[derive(Clone)]
pub struct ZoneManager {
    zones: Arc<RwLock<HashMap<String, ZoneInfo>>>,
    db_pool: Arc<RwLock<Option<SqlitePool>>>,
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
                is_muted: false,
                active_device_id: None,
                playback_status: None,
            },
        );
        Self {
            zones: Arc::new(RwLock::new(initial)),
            db_pool: Arc::new(RwLock::new(db_pool)),
        }
    }

    pub async fn swap_db_pool(&self, pool: Option<SqlitePool>) {
        let mut guard = self.db_pool.write().await;
        *guard = pool;
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
        {
            let guard = self.db_pool.read().await;
            if let Some(ref pool) = *guard {
                let _ = ZonesRepository::upsert_zone(pool, &zone).await;
            }
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
                is_muted: false,
                active_device_id: None,
                playback_status: None,
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
                    volume: existing
                        .as_ref()
                        .map(|z| z.volume)
                        .unwrap_or_else(|| p.volume()),
                    is_active: existing
                        .as_ref()
                        .map(|z| z.is_active)
                        .unwrap_or(dev.is_default),
                    clock_offset_us: existing
                        .as_ref()
                        .and_then(|z| z.clock_offset_us)
                        .or(Some(0)),
                    rtt_us: existing.as_ref().and_then(|z| z.rtt_us).or(Some(0)),
                    drift_ppm: existing.as_ref().and_then(|z| z.drift_ppm).or(Some(0.0)),
                    is_muted: existing.as_ref().is_some_and(|z| z.is_muted),
                    active_device_id: existing.as_ref().and_then(|z| z.active_device_id.clone()),
                    playback_status: existing.as_ref().and_then(|z| z.playback_status),
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
                    is_muted: false,
                    active_device_id: None,
                    playback_status: None,
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
                    is_muted: false,
                    active_device_id: None,
                    playback_status: None,
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
