use base64::prelude::*;
use serde::{Deserialize, Serialize};

use crate::error::ProviderError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteShareUri {
    pub protocol: String,
    pub host: String,
    pub port: u16,
    pub share_name: String,
    pub relative_path: String,
    pub username: Option<String>,
    pub password: Option<String>,
    pub is_authenticated: bool,
    #[serde(default)]
    pub is_ssl: bool,
}

impl RemoteShareUri {
    pub fn is_ssl(&self) -> bool {
        self.is_ssl || self.port == 443
    }

    /// Formats the host for URIs, wrapping IPv6 addresses in square brackets per RFC 3986.
    pub fn formatted_host(&self) -> String {
        if self.host.contains(':') && !self.host.starts_with('[') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        }
    }
}

pub fn make_basic_auth(username: &str, password: &str) -> String {
    let credentials = format!("{username}:{password}");
    let encoded = BASE64_STANDARD.encode(credentials.as_bytes());
    format!("Basic {encoded}")
}

pub fn percent_decode(input: &str) -> String {
    let mut result = Vec::new();
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(val) =
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16)
            {
                result.push(val);
                i += 3;
                continue;
            }
        }
        result.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&result).to_string()
}

pub fn parse_remote_share_uri(uri_str: &str) -> Result<RemoteShareUri, ProviderError> {
    let trimmed = uri_str.trim();

    // Check scheme
    let scheme_end = trimmed.find("://").ok_or_else(|| {
        ProviderError::InvalidConfig(format!("Missing scheme in URI '{trimmed}'"))
    })?;
    let raw_scheme = &trimmed[..scheme_end].to_ascii_lowercase();
    let after_scheme = &trimmed[scheme_end + 3..];

    let (protocol, default_port, is_ssl) = match raw_scheme.as_str() {
        "smb" => ("smb".to_string(), 445, false),
        "davs" | "https" => ("web_dav".to_string(), 443, true),
        "dav" | "http" => ("web_dav".to_string(), 80, false),
        other => {
            return Err(ProviderError::InvalidConfig(format!(
                "Unsupported remote scheme '{other}': only smb, http, https, dav, davs are supported"
            )));
        }
    };

    // Extract authority and path
    let (authority, path) = match after_scheme.find('/') {
        Some(idx) => (&after_scheme[..idx], &after_scheme[idx..]),
        None => (after_scheme, ""),
    };

    // Parse userinfo if present: username[:password]@host[:port]
    let (userinfo, host_port) = match authority.rfind('@') {
        Some(idx) => (Some(&authority[..idx]), &authority[idx + 1..]),
        None => (None, authority),
    };

    let mut username = None;
    let mut password = None;
    let mut is_authenticated = false;

    if let Some(ui) = userinfo {
        if let Some(colon_pos) = ui.find(':') {
            username = Some(percent_decode(&ui[..colon_pos]));
            password = Some(percent_decode(&ui[colon_pos + 1..]));
        } else {
            username = Some(percent_decode(ui));
        }
        is_authenticated = username.is_some() || password.is_some();
    }

    // Parse host and port: handle bracketed IPv6 e.g. [fe80::1] or [fe80::1]:8443
    let (host, port) = if host_port.starts_with('[') {
        if let Some(close_bracket) = host_port.find(']') {
            let ipv6 = &host_port[1..close_bracket];
            let after_bracket = &host_port[close_bracket + 1..];
            let port = if let Some(colon_idx) = after_bracket.find(':') {
                after_bracket[colon_idx + 1..]
                    .parse::<u16>()
                    .map_err(|e| ProviderError::InvalidConfig(format!("Invalid port: {e}")))?
            } else {
                default_port
            };
            (ipv6.to_string(), port)
        } else {
            return Err(ProviderError::InvalidConfig(format!(
                "Unclosed IPv6 bracket in '{host_port}'"
            )));
        }
    } else if let Some(colon_idx) = host_port.rfind(':') {
        let h = &host_port[..colon_idx];
        let p = host_port[colon_idx + 1..]
            .parse::<u16>()
            .map_err(|e| ProviderError::InvalidConfig(format!("Invalid port: {e}")))?;
        (h.to_string(), p)
    } else {
        (host_port.to_string(), default_port)
    };

    if host.trim().is_empty() {
        return Err(ProviderError::InvalidConfig(
            "Host cannot be empty in remote share URI".to_string(),
        ));
    }

    // Parse path: for SMB, first component is share_name
    let clean_path = path.trim_start_matches('/');
    let (share_name, relative_path) = if protocol == "smb" {
        if clean_path.is_empty() {
            (String::new(), String::new())
        } else if let Some(slash_idx) = clean_path.find('/') {
            (
                clean_path[..slash_idx].to_string(),
                clean_path[slash_idx + 1..].to_string(),
            )
        } else {
            (clean_path.to_string(), String::new())
        }
    } else {
        (String::new(), clean_path.to_string())
    };

    Ok(RemoteShareUri {
        protocol,
        host,
        port,
        share_name,
        relative_path,
        username,
        password,
        is_authenticated,
        is_ssl,
    })
}
