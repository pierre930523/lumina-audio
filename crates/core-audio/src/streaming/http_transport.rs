use async_trait::async_trait;
use bytes::{Bytes, BytesMut};
use reqwest::header::{
    ACCEPT_ENCODING, CONNECTION, CONTENT_LENGTH, HOST, HeaderMap, HeaderValue, LOCATION, RANGE,
    USER_AGENT,
};
use reqwest::{Client, Method};
use tokio_util::sync::CancellationToken;

use super::http_utils::{
    parse_content_length, parse_content_range_total, same_trusted_redirect_scope,
    strip_sensitive_cross_origin_headers,
};
use super::runtime::{DEFAULT_STREAM_USER_AGENT, shared_http_client};
use super::types::{
    HttpRequestSpec, HttpResponseData, StreamError, StreamHttpConfig, StreamHttpTransport,
};

#[derive(Debug, Clone)]
enum TransportClient {
    Shared,
    Custom(Client),
}

/// Default [`StreamHttpTransport`] backed by `reqwest::Client` with HTTP/2 adaptive window,
/// connection pooling, manual header-preserving redirects, and strict timeout/cancellation hooks.
#[derive(Debug, Clone)]
pub struct ReqwestStreamTransport {
    client: TransportClient,
}

impl ReqwestStreamTransport {
    /// Returns a transport using the shared process-wide HTTP/2 keep-alive `reqwest::Client`.
    /// Each request reads the latest shared client so pool resets take effect immediately.
    pub fn shared() -> Result<Self, StreamError> {
        let _ = shared_http_client()?;
        Ok(Self {
            client: TransportClient::Shared,
        })
    }

    /// Creates a transport wrapping a caller-supplied `reqwest::Client`.
    pub fn from_client(client: Client) -> Self {
        Self {
            client: TransportClient::Custom(client),
        }
    }

    fn resolve_client(&self) -> Result<Client, StreamError> {
        match &self.client {
            TransportClient::Shared => shared_http_client(),
            TransportClient::Custom(c) => Ok(c.clone()),
        }
    }
}

fn is_stale_pooled_send_error(err: &reqwest::Error) -> bool {
    err.is_request() && !err.is_connect() && !err.is_timeout()
}

#[async_trait]
impl StreamHttpTransport for ReqwestStreamTransport {
    async fn execute(
        &self,
        req: HttpRequestSpec,
        read_body: bool,
        config: &StreamHttpConfig,
        cancel: &CancellationToken,
    ) -> Result<HttpResponseData, StreamError> {
        if cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }

        let mut current_url = reqwest::Url::parse(&req.url)
            .map_err(|e| StreamError::Network(format!("Invalid HTTP URL '{}': {e}", req.url)))?;
        if current_url.scheme() != "http" && current_url.scheme() != "https" {
            return Err(StreamError::Unsupported(format!(
                "Unsupported stream URL scheme: {current_url}"
            )));
        }

        let mut req_headers = HeaderMap::new();
        for (name, value) in &req.headers {
            if *name == HOST
                || *name == CONTENT_LENGTH
                || *name == CONNECTION
                || *name == ACCEPT_ENCODING
                || *name == RANGE
            {
                continue;
            }
            req_headers.insert(name.clone(), value.clone());
        }
        if !req_headers.contains_key(USER_AGENT) {
            req_headers.insert(
                USER_AGENT,
                HeaderValue::from_static(DEFAULT_STREAM_USER_AGENT),
            );
        }
        if let Some((start, end)) = req.range {
            let range_val = format!("bytes={start}-{end}");
            let hv = HeaderValue::from_str(&range_val)
                .map_err(|e| StreamError::Io(format!("Invalid Range header '{range_val}': {e}")))?;
            req_headers.insert(RANGE, hv);
        }

        let mut method = req.method;
        for _hop in 0..=config.max_redirects {
            let mut retried_stale = false;
            let resp = loop {
                let client = self.resolve_client()?;
                let builder = client
                    .request(method.clone(), current_url.clone())
                    .headers(req_headers.clone());

                let send_res = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                    timed = tokio::time::timeout(config.request_timeout, builder.send()) => {
                        match timed {
                            Ok(res) => res,
                            Err(_) => return Err(StreamError::Timeout),
                        }
                    }
                };

                match send_res {
                    Ok(r) => break r,
                    Err(e) if !retried_stale && is_stale_pooled_send_error(&e) => {
                        retried_stale = true;
                        continue;
                    }
                    Err(e) if e.is_timeout() => return Err(StreamError::Timeout),
                    Err(e) => {
                        return Err(StreamError::Network(format!(
                            "HTTP {method} failed for {current_url}: {e:?}"
                        )));
                    }
                }
            };

            let status = resp.status();
            if status.is_redirection()
                && let Some(loc_val) = resp.headers().get(LOCATION)
            {
                let loc_str = loc_val.to_str().map_err(|e| {
                    StreamError::Network(format!(
                        "Invalid redirect Location header from {current_url}: {e}"
                    ))
                })?;
                let next_url = current_url.join(loc_str).map_err(|e| {
                    StreamError::Network(format!(
                        "Invalid redirect Location '{loc_str}' from {current_url}: {e}"
                    ))
                })?;
                if next_url.scheme() != "http" && next_url.scheme() != "https" {
                    return Err(StreamError::Unsupported(format!(
                        "Unsupported redirect URL scheme: {next_url}"
                    )));
                }
                if !same_trusted_redirect_scope(&current_url, &next_url) {
                    strip_sensitive_cross_origin_headers(&mut req_headers);
                }
                if status == reqwest::StatusCode::SEE_OTHER && method != Method::HEAD {
                    method = Method::GET;
                }
                current_url = next_url;
                continue;
            }

            let final_url = resp.url().to_string();
            let resp_headers = resp.headers().clone();
            let content_length = parse_content_length(&resp_headers).or(resp.content_length());
            let content_range_total = parse_content_range_total(&resp_headers);

            if !read_body {
                drop(resp);
                return Ok(HttpResponseData {
                    status: status.as_u16(),
                    final_url,
                    headers: resp_headers,
                    content_length,
                    content_range_total,
                    body: Bytes::new(),
                });
            }

            let mut out = BytesMut::new();
            let mut resp = resp;
            loop {
                let maybe_chunk = tokio::select! {
                    biased;
                    _ = cancel.cancelled() => return Err(StreamError::Cancelled),
                    timed = tokio::time::timeout(config.read_timeout, resp.chunk()) => {
                        match timed {
                            Ok(Ok(c)) => c,
                            Ok(Err(e)) if e.is_timeout() => return Err(StreamError::Timeout),
                            Ok(Err(e)) => {
                                return Err(StreamError::Network(format!(
                                    "HTTP body chunk failed for {final_url}: {e:?}"
                                )));
                            }
                            Err(_) => return Err(StreamError::Timeout),
                        }
                    }
                };
                match maybe_chunk {
                    Some(chunk) => out.extend_from_slice(&chunk),
                    None => break,
                }
            }

            return Ok(HttpResponseData {
                status: status.as_u16(),
                final_url,
                headers: resp_headers,
                content_length,
                content_range_total,
                body: out.freeze(),
            });
        }

        Err(StreamError::Network(format!(
            "Too many HTTP redirects (>{}) fetching {}",
            config.max_redirects, req.url
        )))
    }
}
