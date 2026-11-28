mod dash_package;
mod eviction;
mod lease;
mod manager;
mod memory_store;
mod path;

#[cfg(test)]
mod tests;

pub use dash_package::{DashL2Package, DashL2SegmentEntry, L2_DASH_MAGIC, MAX_DASH_L2_SEGMENTS};
pub use lease::{L2DashHit, L2DirectHit, L2EvictionReport, L2FileLease, L2OrphanSweepReport};
pub use manager::L2CacheManager;
pub use memory_store::InMemoryL2HeadCacheStore;
pub use path::{L2CacheConfig, build_l2_rel_path, should_admit_to_l2};
