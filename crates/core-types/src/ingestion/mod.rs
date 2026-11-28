pub mod external;
pub mod fingerprint;
pub mod overrides;
pub mod scan;

pub use external::{ExternalAlbumIngest, ExternalCatalogIngestBatch, ExternalTrackIngest};
pub use fingerprint::{ContentFingerprint, TocSignature};
pub use overrides::{
    CanonicalArtist, CanonicalTrack, FileStatus, MetadataLayer, MetadataOverride, SourceReference,
};
pub use scan::{
    ScanLifecycleState, ScanProgressEvent, SkipReason, SkippedFile, WatchMode, WatchedRoot,
};
