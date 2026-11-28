pub mod airplay;
pub mod clock_sync;
pub mod dlna;
pub mod manager;
pub mod models;

#[cfg(test)]
mod tests;

pub use airplay::{AirPlayClient, AirPlaySessionInfo};
pub use clock_sync::{
    ClockSyncMeasurement, ClockSyncSample, aligned_start_delay_us, estimate_drift_ppm,
    measure_clock_sync, sync_json_once, sync_sntp_once,
};
pub use core_types::ZoneInfo;
pub use dlna::{
    DEFAULT_SSDP_ADDR, DlnaController, DlnaDeviceDescriptor, DlnaPositionInfo,
    discover_dlna_devices,
};
pub use manager::ZoneManager;
pub use models::{ZoneDiscoverRequest, ZoneGroupRequest, ZoneGroupStatus};
