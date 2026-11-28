use std::collections::BTreeSet;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::Duration;

/// Default quiet-window debounce duration (700 ms, within the 600–800 ms target) for collapsing
/// OS route/DHCP/VPN churn into a single fingerprint evaluation.
pub const DEFAULT_DEBOUNCE_DURATION: Duration = Duration::from_millis(700);

/// Providers whose L1 cached URLs are IP/session-bound and must be invalidated on `network_epoch` change.
pub const NETWORK_EPOCH_RESET_PROVIDERS: &[&str] = &["youtube_music"];

/// Platform-agnostic snapshot of active routing and VPN state used to filter out no-op OS network
/// notifications (e.g. DHCP lease renewals that keep the exact same interface, IP, and VPN set).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NetworkFingerprint {
    pub default_route_if: Option<String>,
    pub primary_local_ip: Option<IpAddr>,
    pub vpn_interfaces: BTreeSet<String>,
}

/// Injectable provider producing a [`NetworkFingerprint`] snapshot (real OS implementation in
/// production, deterministic mock in unit tests).
pub trait FingerprintProvider: Send + Sync {
    fn snapshot(&self) -> NetworkFingerprint;
}

/// Low-priority background hook invoked during Step 2 of the network-change cascade to prune stale
/// SQLite L1 entries belonging to providers with `needs_network_epoch_reset == true`.
pub type L1PruneHook = Arc<dyn Fn(&[&str], u64) + Send + Sync>;

/// Notification listener invoked during Step 4 of the network-change cascade with the newly
/// incremented `network_epoch`.
pub type EpochListener = Arc<dyn Fn(u64) + Send + Sync>;

/// Configuration for [`super::NetworkMonitor`].
#[derive(Clone)]
pub struct NetworkMonitorConfig {
    pub debounce: Duration,
    pub on_l1_prune: Option<L1PruneHook>,
    pub on_epoch_changed: Option<EpochListener>,
    pub reset_http_pools: bool,
}

impl Default for NetworkMonitorConfig {
    fn default() -> Self {
        Self {
            debounce: DEFAULT_DEBOUNCE_DURATION,
            on_l1_prune: None,
            on_epoch_changed: None,
            reset_http_pools: true,
        }
    }
}

/// Returns `true` when an interface name or description indicates a VPN / tunnel adapter.
pub fn is_vpn_interface_name(name_or_desc: &str) -> bool {
    let lower = name_or_desc.trim().to_ascii_lowercase();
    if lower.is_empty() {
        return false;
    }
    lower.starts_with("utun")
        || lower.starts_with("ipsec")
        || lower.starts_with("ppp")
        || lower.starts_with("wg")
        || lower.starts_with("tun")
        || lower.starts_with("tap")
        || lower.contains("vpn")
        || lower.contains("wireguard")
        || lower.contains("wintun")
        || lower.contains("tailscale")
        || lower.contains("openvpn")
        || lower.contains("clash")
        || lower.contains("sing-box")
        || lower.contains("zerotier")
        || lower.contains("nordlynx")
        || lower.contains("mullvad")
        || lower.contains("tap-windows")
}
