use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use reqwest::Method;
use tokio::sync::RwLock;

use crate::error::ProviderError;

#[derive(Debug, Clone)]
pub struct HttpRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub query_params: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
}

impl HttpRequest {
    pub fn get(url: impl Into<String>) -> Self {
        Self::with_method("GET", url)
    }

    pub fn with_method(method: impl Into<String>, url: impl Into<String>) -> Self {
        Self {
            method: method.into(),
            url: url.into(),
            headers: Vec::new(),
            query_params: Vec::new(),
            body: None,
        }
    }

    pub fn post_form(url: impl Into<String>, pairs: &[(&str, &str)]) -> Self {
        let encoded: String = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(pairs.iter().copied())
            .finish();
        Self {
            method: "POST".to_string(),
            url: url.into(),
            headers: vec![(
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            )],
            query_params: Vec::new(),
            body: Some(encoded.into_bytes()),
        }
    }

    pub fn post_json(url: impl Into<String>, json_body: impl Into<String>) -> Self {
        Self {
            method: "POST".to_string(),
            url: url.into(),
            headers: vec![("Content-Type".to_string(), "application/json".to_string())],
            query_params: Vec::new(),
            body: Some(json_body.into().into_bytes()),
        }
    }

    pub fn with_header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    pub fn with_query(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.query_params.push((key.into(), value.into()));
        self
    }

    pub fn with_body(mut self, body: impl Into<Vec<u8>>) -> Self {
        self.body = Some(body.into());
        self
    }
}

#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl HttpResponse {
    pub fn ok_json(body: impl Into<String>) -> Self {
        Self {
            status: 200,
            headers: vec![("Content-Type".to_string(), "application/json".to_string())],
            body: body.into(),
        }
    }

    pub fn error_json(status: u16, body: impl Into<String>) -> Self {
        Self {
            status,
            headers: vec![("Content-Type".to_string(), "application/json".to_string())],
            body: body.into(),
        }
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

#[async_trait]
pub trait HttpTransport: Send + Sync {
    async fn execute(&self, req: HttpRequest) -> Result<HttpResponse, ProviderError>;
}

/// Live HTTP transport powered by `reqwest` with `rustls-tls`.
#[derive(Clone)]
pub struct ReqwestHttpTransport {
    client: reqwest::Client,
}

impl Default for ReqwestHttpTransport {
    fn default() -> Self {
        Self::new()
    }
}

impl ReqwestHttpTransport {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self { client }
    }

    pub fn with_client(client: reqwest::Client) -> Self {
        Self { client }
    }

    pub fn client(&self) -> &reqwest::Client {
        &self.client
    }
}

#[async_trait]
impl HttpTransport for ReqwestHttpTransport {
    async fn execute(&self, req: HttpRequest) -> Result<HttpResponse, ProviderError> {
        let method = Method::from_bytes(req.method.trim().as_bytes()).map_err(|e| {
            ProviderError::InvalidConfig(format!("Invalid HTTP method '{}': {e}", req.method))
        })?;

        let mut header_map = HeaderMap::new();
        for (k, v) in &req.headers {
            let name = HeaderName::from_bytes(k.trim().as_bytes()).map_err(|e| {
                ProviderError::InvalidConfig(format!("Invalid HTTP header name '{k}': {e}"))
            })?;
            let val = HeaderValue::from_str(v).map_err(|e| {
                ProviderError::InvalidConfig(format!("Invalid HTTP header value for '{k}': {e}"))
            })?;
            header_map.append(name, val);
        }

        let mut builder = self.client.request(method, &req.url).headers(header_map);
        if !req.query_params.is_empty() {
            builder = builder.query(&req.query_params);
        }
        if let Some(body) = req.body {
            builder = builder.body(body);
        }

        let resp = builder
            .send()
            .await
            .map_err(|e| ProviderError::Network(format!("HTTP request to '{}' failed: {e:?}", req.url)))?;

        let status = resp.status().as_u16();
        let headers = resp
            .headers()
            .iter()
            .filter_map(|(k, v)| {
                v.to_str()
                    .ok()
                    .map(|val_str| (k.as_str().to_string(), val_str.to_string()))
            })
            .collect();

        let body_bytes = resp
            .bytes()
            .await
            .map_err(|e| ProviderError::Network(format!("Failed reading HTTP response body: {e}")))?;
        let body = String::from_utf8_lossy(&body_bytes).into_owned();

        Ok(HttpResponse {
            status,
            headers,
            body,
        })
    }
}

type RouteHandler = Box<dyn Fn(&HttpRequest) -> Result<HttpResponse, ProviderError> + Send + Sync>;
type MockRouteEntry = (Option<String>, String, RouteHandler);

/// Offline mock HTTP transport for deterministic testing and isolation.
#[derive(Default)]
pub struct MockHttpTransport {
    routes: Arc<RwLock<Vec<MockRouteEntry>>>,
}

impl MockHttpTransport {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn register_exact(&self, path_substring: &str, response: HttpResponse) {
        let pattern = path_substring.to_string();
        let mut routes = self.routes.write().await;
        routes.push((None, pattern, Box::new(move |_req| Ok(response.clone()))));
    }

    pub async fn register_fn<F>(&self, path_substring: &str, handler: F)
    where
        F: Fn(&HttpRequest) -> Result<HttpResponse, ProviderError> + Send + Sync + 'static,
    {
        let pattern = path_substring.to_string();
        let mut routes = self.routes.write().await;
        routes.push((None, pattern, Box::new(handler)));
    }

    pub async fn register_method_fn<F>(&self, method: &str, path_substring: &str, handler: F)
    where
        F: Fn(&HttpRequest) -> Result<HttpResponse, ProviderError> + Send + Sync + 'static,
    {
        let method_upper = method.trim().to_ascii_uppercase();
        let pattern = path_substring.to_string();
        let mut routes = self.routes.write().await;
        routes.push((Some(method_upper), pattern, Box::new(handler)));
    }
}

#[async_trait]
impl HttpTransport for MockHttpTransport {
    async fn execute(&self, req: HttpRequest) -> Result<HttpResponse, ProviderError> {
        let routes = self.routes.read().await;
        for (method_filter, pattern, handler) in routes.iter() {
            let method_ok = method_filter
                .as_ref()
                .is_none_or(|m| m.eq_ignore_ascii_case(&req.method));
            if method_ok && req.url.contains(pattern) {
                return handler(&req);
            }
        }
        Err(ProviderError::Network(format!(
            "MockHttpTransport: unhandled route for {} {}",
            req.method, req.url
        )))
    }
}

pub fn endpoint_url(base_url: &str, path: &str) -> String {
    let b = base_url.trim_end_matches('/');
    let p = path.trim_start_matches('/');
    if p.is_empty() {
        b.to_string()
    } else {
        format!("{b}/{p}")
    }
}
