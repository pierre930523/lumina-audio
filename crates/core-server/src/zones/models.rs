use serde::{Deserialize, Serialize};
use std::collections::HashMap;

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
