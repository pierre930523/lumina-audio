mod auth;
mod client;
mod models;
mod stream;

#[cfg(test)]
mod tests;

pub use auth::validate_arl_cookie;
pub use client::DeezerProvider;
pub use models::{
    DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL, DEFAULT_DEEZER_API_BASE_URL,
    DEFAULT_DEEZER_GW_BASE_URL, DEFAULT_DEEZER_MEDIA_BASE_URL, DeezerConfig, DeezerUser,
};
