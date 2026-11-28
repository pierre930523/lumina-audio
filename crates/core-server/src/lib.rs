pub mod discovery;
pub mod error;
pub mod middleware;
pub mod pairing;
pub mod routes;
pub mod state;
pub mod ws;
pub mod zones;

use anyhow::Result;
use core_audio::AudioPlayer;
use core_db::SqlitePool;
use discovery::{MdnsConfig, MdnsService};
use routes::build_router;
use state::AppState;
pub use state::spawn_playback_transition_watcher;
use std::net::SocketAddr;
use std::sync::Arc;
use tracing::info;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bind_addr: SocketAddr,
    pub enable_mdns: bool,
    pub db_pool: Option<SqlitePool>,
    pub player: Option<AudioPlayer>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            bind_addr: "0.0.0.0:9888".parse().expect("valid default socket addr"),
            enable_mdns: true,
            db_pool: None,
            player: None,
        }
    }
}

pub struct AppServer {
    pub config: ServerConfig,
    pub state: Arc<AppState>,
    pub mdns: Option<MdnsService>,
}

impl AppServer {
    pub fn new(config: ServerConfig) -> Self {
        let state = Arc::new(AppState::with_player(
            config.db_pool.clone(),
            config.player.clone(),
        ));
        let mdns = if config.enable_mdns {
            let mdns_cfg = MdnsConfig {
                port: config.bind_addr.port(),
                ..Default::default()
            };
            Some(MdnsService::new(mdns_cfg))
        } else {
            None
        };

        Self {
            config,
            state,
            mdns,
        }
    }

    pub async fn run(self) -> Result<()> {
        self.state.bootstrap_from_db().await;
        if let Some(mdns) = &self.mdns {
            mdns.start().await;
        }

        let app = build_router(self.state.clone());
        info!(
            "Lumina Server listening on http://{}",
            self.config.bind_addr
        );

        let listener = tokio::net::TcpListener::bind(self.config.bind_addr).await?;
        let watcher_handle = spawn_playback_transition_watcher(self.state.clone());
        let serve_res = axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await;

        if let Some(handle) = watcher_handle {
            handle.abort();
        }
        if let Some(mdns) = &self.mdns {
            mdns.stop().await;
        }

        serve_res?;
        Ok(())
    }
}

pub async fn start_embedded_server(config: ServerConfig) -> Result<()> {
    let server = AppServer::new(config);
    server.run().await
}

pub async fn serve_with_shutdown<F>(
    listener: tokio::net::TcpListener,
    app: axum::Router,
    shutdown_signal: F,
) -> Result<()>
where
    F: std::future::Future<Output = ()> + Send + 'static,
{
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal)
    .await?;
    Ok(())
}
