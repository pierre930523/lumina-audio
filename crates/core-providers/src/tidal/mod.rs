mod auth;
mod client;
mod models;
mod stream;

#[cfg(test)]
mod tests;

pub use auth::{generate_pkce_challenge, is_token_expired, validate_pkce_verifier};
pub use client::TidalProvider;
pub use models::{
    DEFAULT_TIDAL_API_BASE_URL, DEFAULT_TIDAL_AUTH_BASE_URL, DEFAULT_TIDAL_CLIENT_ID,
    DEFAULT_TIDAL_REDIRECT_URI, TIDAL_CREDENTIAL_SERVICE, TIDAL_KEY_OAUTH, TidalConfig,
    TidalPkceSession, TidalTokenResponse,
};
