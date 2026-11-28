use super::{AppState, now_unix_ms};
use crate::ws::messages::{PlaybackStatePayload, SignalPathPayload, WsMessage};
use core_providers::StorageWatcherManager;
use core_types::{PlaybackState, ProtocolSnapshot, SignalPath};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;

pub fn signal_path_to_payload(path: &SignalPath) -> SignalPathPayload {
    SignalPathPayload::from(path)
}

impl AppState {
    pub async fn broadcast_playback_state(&self) -> PlaybackState {
        let pb = self.build_playback_state().await;
        let _ = self.broadcast_tx.send(WsMessage::PlaybackStateChanged {
            payload: PlaybackStatePayload::from(pb.clone()),
        });
        pb
    }

    pub async fn build_protocol_snapshot(&self) -> ProtocolSnapshot {
        let playback = self.build_playback_state().await;
        let queue = self.queue.read().await.clone();
        let signal_path = Some(self.current_signal_path().await);
        let devices = self.list_device_infos().await;
        let mut zones = self.zone_manager.list_zones().await;
        let active_zone_id = playback.active_zone_id.clone();
        let active_dev_id = playback.active_device.as_ref().map(|d| d.id.clone());
        for z in &mut zones {
            if active_zone_id.as_deref() == Some(z.id.as_str()) {
                z.is_active = true;
                z.is_muted = playback.is_muted;
                z.playback_status = Some(playback.status);
                if z.active_device_id.is_none() {
                    z.active_device_id = active_dev_id.clone().or_else(|| z.device_id.clone());
                }
            }
        }
        ProtocolSnapshot {
            playback,
            queue,
            signal_path,
            devices,
            zones,
            server_time_ms: now_unix_ms(),
            sequence: self.next_ws_sequence(),
        }
    }

    /// Spawns (once) a background task forwarding `IngestionPipeline` scan progress events
    /// to WebSocket clients as `WsMessage::Event { event: "library.scan_progress", .. }`.
    pub fn ensure_scan_progress_relay(&self) {
        let Some(ref pipeline) = self.ingestion_pipeline else {
            return;
        };
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        if self
            .scan_progress_relay_started
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return;
        }
        let mut rx = pipeline.subscribe_progress();
        let tx = self.broadcast_tx.clone();
        handle.spawn(async move {
            use core_types::{ScanLifecycleState, ScanProgressEvent};
            const RELAY_COALESCE: Duration = Duration::from_millis(200);
            let mut last_sent: Option<Instant> = None;
            let mut pending: Option<ScanProgressEvent> = None;
            let mut flush_tick = tokio::time::interval(Duration::from_millis(50));
            flush_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

            let forward = |ev: &ScanProgressEvent| {
                if let Ok(payload) = serde_json::to_value(ev) {
                    let _ = tx.send(WsMessage::Event {
                        event: "library.scan_progress".to_string(),
                        payload,
                    });
                }
            };

            loop {
                tokio::select! {
                    res = rx.recv() => match res {
                        Ok(ev) => {
                            let is_immediate = matches!(
                                ev.state,
                                ScanLifecycleState::Discovering
                                    | ScanLifecycleState::Completed
                                    | ScanLifecycleState::Failed
                                    | ScanLifecycleState::Watching
                            );
                            if is_immediate
                                || last_sent.is_none_or(|t| t.elapsed() >= RELAY_COALESCE)
                            {
                                pending = None;
                                forward(&ev);
                                last_sent = Some(Instant::now());
                            } else {
                                pending = Some(ev);
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(broadcast::error::RecvError::Closed) => {
                            if let Some(ev) = pending.take() {
                                forward(&ev);
                            }
                            break;
                        }
                    },
                    _ = flush_tick.tick(), if pending.is_some() => {
                        if last_sent.is_none_or(|t| t.elapsed() >= RELAY_COALESCE)
                            && let Some(ev) = pending.take()
                        {
                            forward(&ev);
                            last_sent = Some(Instant::now());
                        }
                    }
                }
            }
        });
    }

    /// Lazily initializes and returns the `StorageWatcherManager` bound to `ingestion_pipeline`.
    pub async fn ensure_watcher_manager(&self) -> Option<StorageWatcherManager> {
        self.ensure_scan_progress_relay();
        if let Some(existing) = self.watcher_manager.read().await.clone() {
            return Some(existing);
        }
        let pipeline = self.ingestion_pipeline.as_ref()?.clone();
        let mut guard = self.watcher_manager.write().await;
        if let Some(existing) = guard.clone() {
            return Some(existing);
        }
        let watcher = StorageWatcherManager::with_default_debounce(pipeline);
        *guard = Some(watcher.clone());
        Some(watcher)
    }
}
