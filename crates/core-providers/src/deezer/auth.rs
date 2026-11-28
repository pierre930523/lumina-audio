use super::client::DeezerProvider;
use super::models::{
    DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL, DeezerGwResponse, DeezerSession, DeezerUser,
    DeezerUserDataResult,
};
use crate::error::ProviderError;
use crate::http::HttpRequest;

pub fn validate_arl_cookie(arl: &str) -> bool {
    let trimmed = arl.trim();
    if trimmed.len() < 32 {
        return false;
    }
    trimmed.chars().all(|c| c.is_ascii_hexdigit() || c == '_')
}

impl DeezerProvider {
    pub(crate) async fn active_arl_cookie(&self) -> Result<String, ProviderError> {
        self.get_valid_arl().await
    }

    pub(crate) async fn clear_session(&self) {
        *self.session.write().await = None;
    }

    pub async fn login_with_arl(&self, arl: &str) -> Result<DeezerUser, ProviderError> {
        let trimmed = arl.trim();
        if !validate_arl_cookie(trimmed) {
            return Err(ProviderError::AuthenticationFailed(
                "Deezer ARL must be hex/underscore string >= 32 characters".to_string(),
            ));
        }

        let gw_url = self.config.read().await.gw_base_url.clone();
        let req = HttpRequest::post_json(&gw_url, "{}")
            .with_header("Cookie", format!("arl={trimmed}"))
            .with_query("method", "deezer.getUserData")
            .with_query("input", "3")
            .with_query("api_version", "1.0")
            .with_query("api_token", "null");

        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "Deezer ARL rejected (HTTP {})",
                resp.status
            )));
        }
        if resp.status == 429 {
            let retry_after = resp
                .header("retry-after")
                .and_then(crate::resilience::parse_retry_after);
            return Err(ProviderError::rate_limited(
                "Deezer getUserData rate limited (HTTP 429)",
                retry_after,
            ));
        }
        if resp.status >= 400 {
            return Err(ProviderError::Network(format!(
                "Deezer getUserData failed (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        let parsed: DeezerGwResponse<DeezerUserDataResult> = serde_json::from_str(&resp.body)
            .map_err(|e| {
                ProviderError::AuthenticationFailed(format!(
                    "Failed to parse Deezer getUserData response: {e}"
                ))
            })?;

        if let Some(err_val) = parsed.error {
            if is_non_empty_gw_error(&err_val) {
                return Err(ProviderError::AuthenticationFailed(format!(
                    "Deezer gw-light error: {err_val}"
                )));
            }
        }

        let results = parsed.results.ok_or_else(|| {
            ProviderError::AuthenticationFailed(
                "Missing results in Deezer getUserData response".to_string(),
            )
        })?;
        let gw_user = results.user.ok_or_else(|| {
            ProviderError::AuthenticationFailed(
                "Missing USER in Deezer getUserData response".to_string(),
            )
        })?;

        if gw_user.user_id == 0 {
            return Err(ProviderError::AuthenticationFailed(
                "Deezer ARL is invalid or expired (USER_ID == 0)".to_string(),
            ));
        }

        let opts = gw_user.options;
        let can_hq = opts.as_ref().and_then(|o| o.web_hq).unwrap_or(true);
        let can_lossless = opts.as_ref().and_then(|o| o.web_lossless).unwrap_or(false);
        let license_token = opts.and_then(|o| o.license_token);

        let user = DeezerUser {
            id: gw_user.user_id,
            name: gw_user
                .blog_name
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| format!("Deezer User {}", gw_user.user_id)),
            offer: results.offer_name.unwrap_or_else(|| {
                if can_lossless {
                    "Deezer HiFi".to_string()
                } else {
                    "Deezer Standard".to_string()
                }
            }),
            can_stream_hq: can_hq,
            can_stream_lossless: can_lossless,
        };

        let sid = extract_sid_cookie(&resp.headers);
        let sess = DeezerSession {
            arl: trimmed.to_string(),
            sid,
            api_token: results.check_form.filter(|s| !s.trim().is_empty()),
            license_token: license_token.filter(|s| !s.trim().is_empty()),
            user: user.clone(),
        };

        if let Some(ref store) = self.credential_store {
            store
                .set_secret(DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL, trimmed)
                .await?;
        }

        *self.active_arl.write().await = Some(trimmed.to_string());
        *self.session.write().await = Some(sess);

        Ok(user)
    }

    pub(super) async fn get_valid_arl(&self) -> Result<String, ProviderError> {
        {
            let r = self.active_arl.read().await;
            if let Some(arl) = &*r {
                if validate_arl_cookie(arl) {
                    return Ok(arl.clone());
                }
            }
        }

        if let Some(ref store) = self.credential_store {
            if let Some(arl) = store
                .get_secret(DEEZER_CREDENTIAL_SERVICE, DEEZER_KEY_ARL)
                .await?
            {
                if validate_arl_cookie(&arl) {
                    *self.active_arl.write().await = Some(arl.clone());
                    return Ok(arl);
                }
            }
        }

        Err(ProviderError::not_authenticated("deezer"))
    }

    pub(super) async fn ensure_session(&self) -> Result<DeezerSession, ProviderError> {
        if let Some(sess) = self.session.read().await.clone() {
            return Ok(sess);
        }
        let arl = self.get_valid_arl().await?;
        self.login_with_arl(&arl).await?;
        self.session
            .read()
            .await
            .clone()
            .ok_or_else(|| ProviderError::not_authenticated("deezer"))
    }
}

fn is_non_empty_gw_error(err: &serde_json::Value) -> bool {
    match err {
        serde_json::Value::Null => false,
        serde_json::Value::Array(arr) => !arr.is_empty(),
        serde_json::Value::Object(map) => !map.is_empty(),
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::String(s) => !s.trim().is_empty(),
        _ => true,
    }
}

fn extract_sid_cookie(headers: &[(String, String)]) -> Option<String> {
    for (k, v) in headers {
        if k.eq_ignore_ascii_case("set-cookie") {
            for part in v.split(';') {
                let trimmed = part.trim();
                if let Some(val) = trimmed.strip_prefix("sid=") {
                    if !val.trim().is_empty() {
                        return Some(val.trim().to_string());
                    }
                }
            }
        }
    }
    None
}
