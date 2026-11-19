use crate::error::ServerError;
use crate::state::AppState;
use axum::extract::{Request, State};
use axum::http::header::AUTHORIZATION;
use axum::middleware::Next;
use axum::response::Response;
use std::sync::Arc;

pub async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Result<Response, ServerError> {
    let auth_header = req
        .headers()
        .get(AUTHORIZATION)
        .and_then(|h| h.to_str().ok());

    let token = match auth_header {
        Some(header_val) if header_val.starts_with("Bearer ") => {
            let t = header_val[7..].trim();
            if t.is_empty() {
                return Err(ServerError::Unauthorized);
            }
            t
        }
        _ => return Err(ServerError::Unauthorized),
    };

    if !state.pairing_manager.is_token_valid(token).await {
        // Check DB-persisted tokens lazily in case the server restarted since pairing
        let _ = state.pairing_manager.load_tokens_from_db().await;
        if !state.pairing_manager.is_token_valid(token).await {
            return Err(ServerError::Unauthorized);
        }
    }

    Ok(next.run(req).await)
}
