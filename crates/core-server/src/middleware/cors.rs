use axum::extract::DefaultBodyLimit;
use axum::http::Method;
use axum::http::header::{AUTHORIZATION, CONTENT_TYPE};
use tower_http::cors::{Any, CorsLayer};

pub const MAX_BODY_LIMIT_BYTES: usize = 10 * 1024 * 1024; // 10MB

pub fn build_cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([AUTHORIZATION, CONTENT_TYPE])
}

pub fn build_body_limit_layer() -> DefaultBodyLimit {
    DefaultBodyLimit::max(MAX_BODY_LIMIT_BYTES)
}
