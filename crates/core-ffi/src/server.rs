use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, LUMINA_OK};
use core_server::discovery::{MdnsConfig, MdnsService};
use core_server::routes::build_router;
use core_server::serve_with_shutdown;
use core_server::state::AppState;
use std::os::raw::c_int;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use tokio::sync::oneshot;

#[unsafe(no_mangle)]
pub extern "C" fn lumina_server_start(port: u16, enable_mdns: c_int) -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_server_start", || {
        let engine = get_engine();

        // Gracefully stop any active embedded server first
        if let Ok(mut guard) = engine.server_shutdown.write()
            && let Some(prev_tx) = guard.take()
        {
            let _ = prev_tx.send(());
        }

        let requested_port = if port == 0 { 9888 } else { port };
        let db_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let player = engine.player.read().ok().and_then(|g| g.clone());

        let (listener, bound_port) = engine.runtime.block_on(async move {
            let primary = format!("0.0.0.0:{}", requested_port);
            match tokio::net::TcpListener::bind(&primary).await {
                Ok(l) => {
                    let p = l.local_addr().map(|a| a.port()).unwrap_or(requested_port);
                    Ok((l, p))
                }
                Err(_) => {
                    let l = tokio::net::TcpListener::bind("0.0.0.0:0").await?;
                    let p = l.local_addr().map(|a| a.port()).unwrap_or(0);
                    Ok::<_, std::io::Error>((l, p))
                }
            }
        })?;

        let mut app_state = AppState::with_player(db_pool, player);
        app_state.provider_manager = engine.provider_manager.clone();
        app_state.zone_manager = engine.zone_manager.clone();
        let state = Arc::new(app_state);
        engine.runtime.block_on(state.bootstrap_from_db());

        let router = build_router(state.clone());
        let mdns = if enable_mdns != 0 {
            Some(MdnsService::new(MdnsConfig {
                port: bound_port,
                ..Default::default()
            }))
        } else {
            None
        };

        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        if let Ok(mut guard) = engine.server_shutdown.write() {
            *guard = Some(shutdown_tx);
        }

        engine.server_port.store(bound_port, Ordering::SeqCst);
        engine.server_running.store(true, Ordering::SeqCst);

        engine.runtime.spawn(async move {
            let watcher_handle = core_server::spawn_playback_transition_watcher(state);
            if let Some(ref svc) = mdns {
                svc.start().await;
            }
            let _ = serve_with_shutdown(listener, router, async move {
                let _ = shutdown_rx.await;
            })
            .await;
            if let Some(handle) = watcher_handle {
                handle.abort();
            }
            if let Some(ref svc) = mdns {
                svc.stop().await;
            }
        });

        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_server_stop() -> c_int {
    catch_unwind_ffi(crate::error::LUMINA_ERR_GENERAL, "lumina_server_stop", || {
        let engine = get_engine();
        if let Ok(mut guard) = engine.server_shutdown.write()
            && let Some(tx) = guard.take()
        {
            let _ = tx.send(());
        }
        engine.server_running.store(false, Ordering::SeqCst);
        engine.server_port.store(0, Ordering::SeqCst);
        Ok(LUMINA_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_server_get_port() -> u16 {
    let engine = get_engine();
    engine.server_port.load(Ordering::SeqCst)
}
