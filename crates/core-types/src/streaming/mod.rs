pub mod deck;
pub mod key;
pub mod l2_store;
pub mod loudness;
pub mod spec;

pub use deck::{DeckId, DeckState, DeckTrackMetadata, DualDeckStatusSnapshot};
pub use key::{StreamKey, StreamProviderCapabilities};
pub use l2_store::{
    L2_DEEZER_STRIPE_ALIGNMENT, L2_DEFAULT_HIGH_WATERMARK_BYTES, L2_DEFAULT_LOW_WATERMARK_BYTES,
    L2_MAX_TARGET_BYTES, L2_MIN_TARGET_BYTES, L2_TAIL_FINGERPRINT_LEN, L2AccessUpdate, L2CacheKind,
    L2CacheStoreError, L2HeadCacheStore, L2HeadChunkRecord, compute_l2_target_bytes,
};
pub use loudness::NormalizedLoudness;
pub use spec::{
    DEFAULT_DEEZER_BLOCK_SIZE, DEFAULT_DEEZER_STRIDE, ManifestFormat, StreamCipher,
    StreamSourceSpec,
};
