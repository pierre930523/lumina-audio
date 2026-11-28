mod catalog;
mod client;
pub mod config;
pub mod models;
mod stream;
pub mod transport;

#[cfg(test)]
mod tests;

pub use self::client::{
    QOBUZ_CREDENTIAL_SERVICE, QOBUZ_FALLBACK_TOKEN_KEY, QOBUZ_KEYRING_APP_ID_KEY,
    QOBUZ_KEYRING_APP_SECRET_KEY, QOBUZ_KEYRING_TOKEN_KEY, QobuzProvider,
};
pub use self::config::{QobuzConfig, QobuzUserSession, format_ids};
pub use self::models::*;
pub use self::stream::md5_hex;
pub use self::transport::{
    HttpRequest, HttpResponse, HttpTransport, MockHttpTransport, ReqwestHttpTransport,
};
