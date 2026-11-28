mod manifest;
mod parser;
mod parser_builders;
mod proxy;
mod proxy_ops;
mod recovery;
mod scheduler;
mod source_impl;

#[cfg(test)]
mod tests_manifest;
#[cfg(test)]
mod tests_proxy;

/// Default number of future DASH media segments prefetched ahead of the active read position.
pub const DEFAULT_PREFETCH_AHEAD: usize = 3;

/// Default in-memory RAM LRU byte cap for cached DASH media segments: 16 MiB.
pub const DEFAULT_MAX_SEGMENT_CACHE_BYTES: usize = 16 * 1024 * 1024;

/// Default maximum number of DASH media segments retained in the RAM LRU cache.
pub const DEFAULT_MAX_CACHED_SEGMENTS: usize = 32;

pub(crate) use manifest::infer_dash_extension;
pub use manifest::{DashSegment, ParsedDashManifest, validate_dash_package_compatibility};
pub use parser::{parse_iso8601_duration_ms, parse_mpd_xml};
pub use proxy::SegmentedStreamProxy;
