use super::state::{EngineState, get_engine};
use core_audio::AudioPlayer;
use core_audio::network_monitor::{NetworkMonitor, NetworkMonitorConfig};
use core_db::{L1StreamCacheRepository, SqlitePool};
use core_providers::{IngestionPipeline, StorageWatcherManager};
use core_types::{QueueState, RepeatMode};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

impl EngineState {
    pub fn shutdown_ingestion(&self) {
        if let Ok(mut guard) = self.scan_progress_relay_task.lock()
            && let Some(handle) = guard.take()
        {
            handle.abort();
        }
        let taken_watcher = self.watcher_manager.write().ok().and_then(|mut g| g.take());
        if let Some(watcher) = taken_watcher {
            self.runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), watcher.shutdown()).await;
            });
        }
        if let Ok(mut guard) = self.ingestion_pipeline.write() {
            *guard = None;
        }
    }

    pub fn init_ingestion_for_pool(
        &self,
        pool: SqlitePool,
    ) -> (IngestionPipeline, StorageWatcherManager) {
        self.shutdown_ingestion();
        let pipeline = IngestionPipeline::with_defaults(pool);
        let watcher = {
            let _enter = self.runtime.enter();
            StorageWatcherManager::with_default_debounce(pipeline.clone())
        };
        let restore_watcher = watcher.clone();
        self.runtime.spawn(async move {
            let _ = restore_watcher.restore_watched_roots().await;
        });

        let mut rx = pipeline.subscribe_progress();
        let relay_handle = self.runtime.spawn(async move {
            use core_types::{ScanLifecycleState, ScanProgressEvent};
            const RELAY_COALESCE: Duration = Duration::from_millis(200);
            let mut last_sent: Option<Instant> = None;
            let mut pending: Option<ScanProgressEvent> = None;
            let mut flush_tick = tokio::time::interval(Duration::from_millis(50));
            flush_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

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
                                crate::library::dispatch_scan_progress_event(&ev);
                                last_sent = Some(Instant::now());
                            } else {
                                pending = Some(ev);
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                            if let Some(ev) = pending.take() {
                                crate::library::dispatch_scan_progress_event(&ev);
                            }
                            break;
                        }
                    },
                    _ = flush_tick.tick(), if pending.is_some() => {
                        if last_sent.is_none_or(|t| t.elapsed() >= RELAY_COALESCE)
                            && let Some(ev) = pending.take()
                        {
                            crate::library::dispatch_scan_progress_event(&ev);
                            last_sent = Some(Instant::now());
                        }
                    }
                }
            }
        });

        if let Ok(mut guard) = self.scan_progress_relay_task.lock() {
            *guard = Some(relay_handle);
        }
        if let Ok(mut guard) = self.ingestion_pipeline.write() {
            *guard = Some(pipeline.clone());
        }
        if let Ok(mut guard) = self.watcher_manager.write() {
            *guard = Some(watcher.clone());
        }
        (pipeline, watcher)
    }

    pub fn init_player(&self, headless: bool) {
        if let Ok(mut mon_guard) = self.network_monitor.lock()
            && let Some(prev) = mon_guard.take()
        {
            prev.stop();
        }
        #[cfg(target_os = "windows")]
        if let Ok(mut dw_guard) = self.device_watcher.lock() {
            *dw_guard = None;
        }

        let saved_vol = f32::from_bits(self.volume_bits.load(Ordering::Relaxed) as u32);
        let new_player = if headless {
            AudioPlayer::new_headless()
        } else {
            AudioPlayer::new()
        };
        new_player.set_dsp_bypass(self.dsp_bypassed.load(Ordering::Relaxed));
        new_player.set_volume(saved_vol);
        new_player.set_stream_refresh_handler(Some(
            crate::streaming_bridge::ffi_stream_refresh_handler(),
        ));
        if let Ok(guard) = self.l2_cache_manager.read()
            && let Some(ref mgr) = *guard
        {
            new_player.set_l2_cache_manager(Some(Arc::clone(mgr)));
        } else if let Some(mgr) = crate::l2_cache::ensure_default_l2_cache_manager(self) {
            new_player.set_l2_cache_manager(Some(mgr));
        }

        let hook_player = new_player.clone();
        crate::streaming_bridge::register_provider_cancel_hook(Some(Arc::new(
            move |provider_id: &str| {
                let cancelled = hook_player.cancel_active_stream_for_provider(provider_id);
                let eng = get_engine();
                let loading_matches = eng
                    .active_track_json
                    .read()
                    .ok()
                    .and_then(|g| g.clone())
                    .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
                    .and_then(|v| {
                        v.get("provider_id")
                            .or_else(|| v.get("provider"))
                            .or_else(|| {
                                v.get("source_spec")
                                    .and_then(|s| s.get("key"))
                                    .and_then(|k| k.get("provider_id"))
                            })
                            .and_then(|s| s.as_str())
                            .map(|s| s.eq_ignore_ascii_case(provider_id))
                    })
                    .unwrap_or(false);
                if cancelled || loading_matches {
                    eng.clear_pending_commands();
                    eng.cancel_active_play_token();
                    eng.cancel_active_standby_token();
                    eng.async_generation.fetch_add(1, Ordering::SeqCst);
                    eng.advance_playback_epoch(None);
                    eng.has_real_stream.store(false, Ordering::SeqCst);
                    eng.playback_state.store(4, Ordering::SeqCst);
                    let req_id = eng.play_request_id.load(Ordering::SeqCst);
                    eng.loaded_request_id.store(req_id, Ordering::SeqCst);
                    if let Ok(mut e) = eng.async_last_error.write() {
                        *e = Some(format!("Authentication required for {provider_id}"));
                    }
                    if let Ok(mut c) = eng.async_last_error_code.write() {
                        *c = Some("AUTH_REQUIRED".to_string());
                    }
                    if let Ok(mut pr) = eng.async_last_error_provider.write() {
                        *pr = Some(provider_id.to_string());
                    }
                }
            },
        )));

        let prev_player = if let Ok(mut lock) = self.player.write() {
            lock.replace(new_player.clone())
        } else {
            None
        };
        if let Some(prev) = prev_player {
            prev.shutdown();
        }

        if !headless {
            let mon_cfg = NetworkMonitorConfig {
                on_l1_prune: Some(Arc::new(|providers: &[&str], epoch: u64| {
                    let eng = get_engine();
                    let provider_ids: Vec<String> =
                        providers.iter().map(|s| (*s).to_string()).collect();
                    crate::l1_cache::enqueue_prune_stale_epoch(&eng, provider_ids, epoch);
                })),
                on_epoch_changed: Some(Arc::new(|epoch: u64| {
                    crate::streaming_bridge::notify_network_epoch_changed(epoch);
                })),
                reset_http_pools: true,
                ..Default::default()
            };
            match NetworkMonitor::start_system(mon_cfg) {
                Ok(mon) => {
                    if let Ok(mut mon_guard) = self.network_monitor.lock() {
                        *mon_guard = Some(mon);
                    }
                }
                Err(e) => {
                    tracing::warn!("Failed to start NetworkMonitor: {e}");
                }
            }

            #[cfg(target_os = "windows")]
            {
                let watcher_player = new_player.clone();
                match core_audio::backend::device_watcher_win::DeviceWatcher::start(move |ev| {
                    watcher_player.handle_device_event(ev);
                }) {
                    Ok(watcher) => {
                        if let Ok(mut dw_guard) = self.device_watcher.lock() {
                            *dw_guard = Some(watcher);
                        }
                    }
                    Err(e) => {
                        tracing::warn!("Failed to start Windows DeviceWatcher: {e}");
                    }
                }
            }
        }

        self.runtime
            .block_on(self.zone_manager.sync_local_default_zone(Some(&new_player)));
        self.has_real_stream.store(false, Ordering::SeqCst);
        self.initialized.store(true, Ordering::SeqCst);
        self.playback_state.store(1, Ordering::SeqCst); // 1 = Stopped / Ready
    }

    pub fn reset(&self) {
        // 1. Stop OS network & hardware device monitors first so no callbacks fire during teardown.
        if let Ok(mut mon_guard) = self.network_monitor.lock()
            && let Some(mon) = mon_guard.take()
        {
            mon.stop();
        }
        #[cfg(target_os = "windows")]
        if let Ok(mut dw_guard) = self.device_watcher.lock() {
            *dw_guard = None;
        }

        // 2. Unregister provider cancel hook and abort all pending FFI 403/410 refreshes.
        crate::streaming_bridge::register_provider_cancel_hook(None);
        crate::streaming_bridge::cancel_all_pending_refreshes();

        // 3. Cancel active playback/standby tokens and stop audio player + embedded server.
        self.clear_pending_commands();
        self.cancel_active_play_token();
        self.cancel_active_standby_token();
        self.clear_structured_error();
        crate::error::clear_last_errors();
        self.async_generation.fetch_add(1, Ordering::SeqCst);
        self.playback_epoch.store(0, Ordering::SeqCst);
        self.epoch.store(0, Ordering::SeqCst);
        self.last_caller_epoch.store(0, Ordering::SeqCst);
        self.last_play_dispatch_ms.store(0, Ordering::SeqCst);
        self.play_request_id.store(0, Ordering::SeqCst);
        self.loaded_request_id.store(0, Ordering::SeqCst);
        self.initialized.store(false, Ordering::SeqCst);
        self.playback_state.store(0, Ordering::SeqCst);
        self.has_real_stream.store(false, Ordering::SeqCst);
        self.position_ms.store(0, Ordering::Relaxed);
        self.is_muted.store(false, Ordering::SeqCst);
        self.pre_mute_volume_bits
            .store((1.0f32).to_bits() as u64, Ordering::Relaxed);
        self.set_volume(1.0);
        if let Ok(mut lock) = self.repeat_mode.write() {
            *lock = RepeatMode::Off;
        }
        self.shuffle.store(false, Ordering::SeqCst);
        if let Ok(mut lock) = self.active_zone_id.write() {
            *lock = Some("zone-local".to_string());
        }
        if let Ok(mut lock) = self.active_device_id.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.queue_state.write() {
            *lock = QueueState::default();
        }
        self.sequence.store(0, Ordering::SeqCst);
        self.dsp_bypassed.store(false, Ordering::Relaxed);
        self.server_running.store(false, Ordering::SeqCst);
        self.server_port.store(0, Ordering::SeqCst);

        let taken_player = self.player.write().ok().and_then(|mut g| g.take());
        if let Some(p) = taken_player {
            p.shutdown();
        }
        if let Ok(mut lock) = self.server_shutdown.write()
            && let Some(tx) = lock.take()
        {
            let _ = tx.send(());
        }

        // 4. Stop ingestion watchers & flush pending background SQLite L1 & L2 cache writes BEFORE closing the pool.
        self.shutdown_ingestion();
        crate::l1_cache::flush_pending_writes(self);
        let taken_l2 = self
            .l2_cache_manager
            .write()
            .ok()
            .and_then(|mut g| g.take());
        if let Some(mgr) = taken_l2 {
            self.runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), mgr.shutdown()).await;
            });
        }

        // 5. Run WAL TRUNCATE checkpoint & close SQLite pool with a bounded 2s timeout.
        let taken_pool = self.db_pool.write().ok().and_then(|mut g| g.take());
        if let Some(pool) = taken_pool {
            self.runtime.block_on(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), async move {
                    let _ = L1StreamCacheRepository::wal_checkpoint_truncate(&pool).await;
                    pool.close().await;
                })
                .await;
            });
        }

        if let Ok(mut lock) = self.active_track_json.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.active_profile_id.write() {
            *lock = None;
        }
        if let Ok(mut lock) = self.db_path.write() {
            *lock = None;
        }

        // 6. Drop & rebuild shared Rust HTTP Keep-Alive connection pools cleanly.
        let _ = core_audio::streaming::reset_shared_http_client();
        core_audio::stream::reset_http_client();
    }
}
