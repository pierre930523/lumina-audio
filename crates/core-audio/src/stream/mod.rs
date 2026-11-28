mod dns;
mod http_range;
mod playlist;
mod range_modes;
mod source;

pub use dns::reset_http_client;
pub use http_range::HttpRangeMediaSource;
pub use playlist::{
    is_playlist_content_type, is_playlist_extension, is_playlist_url, looks_like_playlist_magic,
    parse_m3u_entries, parse_pls_entries, resolve_playlist_url, resolve_playlist_url_with_cancel,
    resolve_playlist_url_with_token,
};
pub use source::{StreamOrigin, StreamSource};
