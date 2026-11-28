pub mod bridge;
pub mod chunked_proxy;
pub mod decrypting_stream;
mod http_transport;
mod http_utils;
pub mod hybrid_segmented_stream;
pub mod hybrid_stream;
pub mod l2_cache;
mod runtime;
pub mod segmented_proxy;
mod types;

#[cfg(test)]
mod tests;

pub use bridge::BlockingStreamBridge;
pub use chunked_proxy::{
    ChunkedProxyMetrics, ChunkedStreamProxy, DEEZER_ALIGNED_CHUNK_SIZE, DEEZER_INITIAL_CHUNK_SIZE,
    DEFAULT_CHUNK_PREFETCH_AHEAD, DEFAULT_CHUNK_SIZE, DEFAULT_INITIAL_CHUNK_SIZE,
    DEFAULT_MAX_CACHE_BYTES, DEFAULT_MAX_CACHED_CHUNKS, OverlapVerifyOutcome,
};
pub use decrypting_stream::{
    DEFAULT_DEEZER_BLOCK_SIZE, DEFAULT_DEEZER_STRIDE, DecryptingByteStream,
};
pub use http_transport::ReqwestStreamTransport;
#[allow(unused_imports)]
pub(crate) use http_utils::{
    accepts_byte_ranges, await_watch_result, execute_with_epoch_watch, header_map_to_btree,
    header_str, normalize_mime_base, parse_content_length, parse_content_range_total,
    same_trusted_redirect_scope, strip_sensitive_cross_origin_headers,
};
pub use http_utils::{build_sanitized_headers, read_all_at};
pub use hybrid_segmented_stream::{HybridSegmentedConfig, HybridSegmentedStream};
pub use hybrid_stream::HybridByteStream;
pub use l2_cache::{
    DashL2Package, DashL2SegmentEntry, InMemoryL2HeadCacheStore, L2_DASH_MAGIC, L2CacheConfig,
    L2CacheManager, L2DashHit, L2DirectHit, L2EvictionReport, L2FileLease, L2OrphanSweepReport,
    MAX_DASH_L2_SEGMENTS, build_l2_rel_path, should_admit_to_l2,
};
#[cfg(test)]
pub(crate) use runtime::GLOBAL_DL_TEST_GUARD;
pub use runtime::{
    DEFAULT_REFRESH_403_BACKOFFS, DEFAULT_STREAM_USER_AGENT, InFlightDownloadGuard,
    active_in_flight_downloads, advance_network_epoch, build_streaming_http_client,
    current_network_epoch, drop_idle_http_connections, reset_shared_http_client,
    shared_http_client, shared_http_client_generation, spawn_http2_warmup, streaming_runtime,
    subscribe_network_epoch,
};
#[allow(unused_imports)]
pub(crate) use runtime::{broadcast_network_epoch, increment_network_epoch_atomic};
pub use segmented_proxy::{
    DEFAULT_MAX_CACHED_SEGMENTS, DEFAULT_MAX_SEGMENT_CACHE_BYTES, DEFAULT_PREFETCH_AHEAD,
    DashSegment, ParsedDashManifest, SegmentedStreamProxy, validate_dash_package_compatibility,
};
pub use types::{
    ByteStreamSource, FormatMismatchCallback, FormatMismatchReason, HttpRequestSpec,
    HttpResponseData, SegmentedSeekTarget, StreamError, StreamHttpConfig, StreamHttpTransport,
    StreamRefreshHandler, StreamRefreshOutcome, StreamRefreshRequest,
};
