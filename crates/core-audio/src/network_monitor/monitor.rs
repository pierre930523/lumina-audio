use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use super::fingerprint::{
    FingerprintProvider, NETWORK_EPOCH_RESET_PROVIDERS, NetworkFingerprint, NetworkMonitorConfig,
};
use crate::streaming::{
    StreamError, broadcast_network_epoch, increment_network_epoch_atomic, reset_shared_http_client,
    streaming_runtime,
};

#[cfg(target_os = "windows")]
type OsRouteListenerGuard = super::win_net::WinRouteListenerGuard;

#[cfg(target_os = "macos")]
type OsRouteListenerGuard = super::macos_net::MacRouteListenerGuard;

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
struct OsRouteListenerGuard;

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
impl OsRouteListenerGuard {
    fn start(_tx: mpsc::UnboundedSender<()>) -> Result<Self, String> {
        Ok(Self)
    }
}

struct SystemFingerprintProvider;

impl FingerprintProvider for SystemFingerprintProvider {
    fn snapshot(&self) -> NetworkFingerprint {
        #[cfg(target_os = "windows")]
        {
            super::win_net::snapshot_fingerprint()
        }
        #[cfg(target_os = "macos")]
        {
            super::macos_net::snapshot_fingerprint()
        }
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        {
            NetworkFingerprint::default()
        }
    }
}

/// Cross-platform OS network change monitor with 600–800 ms debouncing, fingerprint diffing,
/// and 4-step cascade execution on real network/VPN transitions.
pub struct NetworkMonitor {
    cancel: CancellationToken,
    trigger_tx: mpsc::UnboundedSender<()>,
    last_fingerprint: Arc<Mutex<NetworkFingerprint>>,
    _os_guard: Option<OsRouteListenerGuard>,
}

impl NetworkMonitor {
    /// Starts the production OS network monitor (Win32 IP Helper on Windows, `SCDynamicStore` /
    /// `Network.framework` on macOS) on `STREAMING_RUNTIME`.
    pub fn start_system(config: NetworkMonitorConfig) -> Result<Self, StreamError> {
        let provider: Arc<dyn FingerprintProvider> = Arc::new(SystemFingerprintProvider);
        let (trigger_tx, trigger_rx) = mpsc::unbounded_channel();
        let os_guard = match OsRouteListenerGuard::start(trigger_tx.clone()) {
            Ok(g) => Some(g),
            Err(err) => {
                tracing::warn!("OS network route listener unavailable: {err}");
                None
            }
        };
        Self::spawn_debouncer(provider, config, trigger_tx, trigger_rx, os_guard)
    }

    /// Starts a [`NetworkMonitor`] backed by a custom [`FingerprintProvider`] without registering
    /// OS listeners. Call [`notify_raw_event`](Self::notify_raw_event) to drive debouncing in tests.
    pub fn start_with_provider(
        provider: Arc<dyn FingerprintProvider>,
        config: NetworkMonitorConfig,
    ) -> Result<Self, StreamError> {
        let (trigger_tx, trigger_rx) = mpsc::unbounded_channel();
        Self::spawn_debouncer(provider, config, trigger_tx, trigger_rx, None)
    }

    fn spawn_debouncer(
        provider: Arc<dyn FingerprintProvider>,
        config: NetworkMonitorConfig,
        trigger_tx: mpsc::UnboundedSender<()>,
        mut trigger_rx: mpsc::UnboundedReceiver<()>,
        os_guard: Option<OsRouteListenerGuard>,
    ) -> Result<Self, StreamError> {
        let rt = streaming_runtime()?;
        let initial_fp = provider.snapshot();
        let last_fingerprint = Arc::new(Mutex::new(initial_fp));
        let cancel = CancellationToken::new();

        let task_cancel = cancel.clone();
        let task_fp = Arc::clone(&last_fingerprint);
        let debounce = config.debounce;

        rt.spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = task_cancel.cancelled() => break,
                    maybe_evt = trigger_rx.recv() => {
                        if maybe_evt.is_none() {
                            break;
                        }
                    }
                }

                // Quiet-window debounce: reset timer whenever additional raw OS events arrive.
                let sleep = tokio::time::sleep(debounce);
                tokio::pin!(sleep);
                loop {
                    tokio::select! {
                        biased;
                        _ = task_cancel.cancelled() => return,
                        _ = &mut sleep => break,
                        maybe_evt = trigger_rx.recv() => {
                            match maybe_evt {
                                Some(()) => {
                                    sleep.as_mut().reset(tokio::time::Instant::now() + debounce);
                                }
                                None => return,
                            }
                        }
                    }
                }

                // Snapshot current OS fingerprint off the Tokio worker thread to avoid stalling I/O.
                let provider_clone = Arc::clone(&provider);
                let new_fp =
                    match tokio::task::spawn_blocking(move || provider_clone.snapshot()).await {
                        Ok(fp) => fp,
                        Err(_) => continue,
                    };
                if task_cancel.is_cancelled() {
                    return;
                }

                let changed = {
                    let Ok(mut guard) = task_fp.lock() else {
                        continue;
                    };
                    if *guard == new_fp {
                        false
                    } else {
                        *guard = new_fp;
                        true
                    }
                };

                if changed {
                    execute_network_change_cascade(&config);
                }
            }
        });

        Ok(Self {
            cancel,
            trigger_tx,
            last_fingerprint,
            _os_guard: os_guard,
        })
    }

    /// Injects a raw network-change trigger into the debouncer (used by OS hooks and tests).
    pub fn notify_raw_event(&self) {
        let _ = self.trigger_tx.send(());
    }

    /// Returns the last committed [`NetworkFingerprint`].
    pub fn current_fingerprint(&self) -> NetworkFingerprint {
        self.last_fingerprint
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    /// Stops the background debouncer task and cancels any active OS notifications.
    pub fn stop(&self) {
        self.cancel.cancel();
    }
}

impl Drop for NetworkMonitor {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

/// Executes the 4-step cascade when a real network fingerprint change is confirmed:
/// 1. Atomically increment global `network_epoch` (immediate O(1) logical invalidation).
/// 2. Trigger low-priority background SQLite L1 prune for `needs_network_epoch_reset` providers.
/// 3. Drop and rebuild Rust HTTP Keep-Alive connection pools.
/// 4. Broadcast `network_epoch` to wake active Rust proxies onto the freshly rebuilt HTTP pools
///    and notify external epoch listeners (e.g. Dart FFI callback for YTM PO Token refresh).
pub fn execute_network_change_cascade(config: &NetworkMonitorConfig) -> u64 {
    // Step 1: Atomic increment global network_epoch (immediate O(1) logical invalidation)
    let new_epoch = increment_network_epoch_atomic();
    tracing::info!("Network fingerprint changed -> network_epoch={new_epoch}");

    // Step 2: Background L1 prune for IP-bound providers (e.g. youtube_music)
    if let Some(ref prune_hook) = config.on_l1_prune {
        prune_hook(NETWORK_EPOCH_RESET_PROVIDERS, new_epoch);
    }

    // Step 3: Drop & rebuild HTTP Keep-Alive connection pools BEFORE waking active proxies
    if config.reset_http_pools {
        if let Err(e) = reset_shared_http_client() {
            tracing::warn!("Failed to rebuild shared streaming HTTP client: {e}");
        }
        crate::stream::reset_http_client();
    }

    // Step 4: Wake active Rust proxies (so retries hit the rebuilt pool) & notify Dart listeners
    broadcast_network_epoch(new_epoch);
    if let Some(ref listener) = config.on_epoch_changed {
        listener(new_epoch);
    }

    new_epoch
}
