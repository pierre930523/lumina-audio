mod fingerprint;
#[cfg(target_os = "macos")]
mod macos_net;
mod monitor;
#[cfg(target_os = "windows")]
mod win_net;

pub use fingerprint::{
    DEFAULT_DEBOUNCE_DURATION, EpochListener, FingerprintProvider, L1PruneHook,
    NETWORK_EPOCH_RESET_PROVIDERS, NetworkFingerprint, NetworkMonitorConfig, is_vpn_interface_name,
};
pub use monitor::{NetworkMonitor, execute_network_change_cascade};
