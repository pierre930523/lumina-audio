//! Isolated concrete `MediaProvider` implementations and adapters.

pub mod apple_music;
pub mod deezer;
pub mod qobuz;
pub mod tidal;
pub mod ytmusic;

pub use apple_music::{
    AppleMusicConfig, AppleMusicCredentialRefresher, AppleMusicCredentials, AppleMusicProvider,
    DEFAULT_APPLE_MUSIC_BASE_URL, DEFAULT_APPLE_MUSIC_STOREFRONT,
};
pub use deezer::DeezerMediaProvider;
pub use qobuz::QobuzMediaProvider;
pub use tidal::TidalMediaProvider;
pub use ytmusic::{
    GuardedProcessRunner, YtDlpCommandRunner, YtMusicAuthUpdate, YtMusicConfig,
    YtMusicCredentialRefresher, YtMusicProvider,
};
