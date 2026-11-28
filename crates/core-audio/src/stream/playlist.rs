use std::collections::{HashMap, HashSet};
use std::io::ErrorKind;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use reqwest::Method;
use reqwest::header::{CONTENT_TYPE, HeaderMap};
use tokio_util::sync::CancellationToken;

use super::dns::{
    http_client, run_http_future_cancellable, run_http_future_cancellable_token,
    send_following_redirects,
};
use super::http_range::{build_header_map, header_str, map_http_status_err};

const MAX_PLAYLIST_DEPTH: usize = 4;
const MAX_PLAYLIST_BYTES: usize = 256 * 1024;

pub fn is_playlist_extension(ext: &str) -> bool {
    matches!(
        ext.trim()
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str(),
        "m3u" | "m3u8" | "pls"
    )
}

pub fn is_playlist_url(url: &str) -> bool {
    let without_frag = url.split('#').next().unwrap_or(url);
    let without_query = without_frag.split('?').next().unwrap_or(without_frag);
    let Some(last_seg) = without_query.rsplit('/').next() else {
        return false;
    };
    let Some(dot_idx) = last_seg.rfind('.') else {
        return false;
    };
    is_playlist_extension(&last_seg[dot_idx + 1..])
}

pub fn is_playlist_content_type(content_type: &str) -> bool {
    let lower = content_type.to_ascii_lowercase();
    lower.contains("mpegurl")
        || lower.contains("x-scpls")
        || lower.contains("pls+xml")
        || lower.contains("audio/pls")
}

pub fn looks_like_playlist_magic(magic: &[u8]) -> bool {
    let text = String::from_utf8_lossy(magic);
    let trimmed = text.trim_start_matches('\u{feff}').trim_start();
    let lower = trimmed.to_ascii_lowercase();
    lower.starts_with("#extm3u") || lower.starts_with("[playlist]")
}

pub fn parse_m3u_entries(body: &str) -> Vec<String> {
    body.lines()
        .map(|l| l.trim_matches('\u{feff}').trim())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect()
}

pub fn parse_pls_entries(body: &str) -> Vec<String> {
    let mut entries = Vec::new();
    for line in body.lines() {
        let trimmed = line.trim_matches('\u{feff}').trim();
        let lower = trimmed.to_ascii_lowercase();
        if let Some(rest) = lower.strip_prefix("file")
            && let Some(eq_idx) = rest.find('=')
        {
            let index_part = rest[..eq_idx].trim();
            if !index_part.is_empty() && index_part.chars().all(|c| c.is_ascii_digit()) {
                let raw_eq = trimmed.find('=').unwrap_or(0);
                let val = trimmed[raw_eq + 1..].trim();
                if !val.is_empty() {
                    entries.push(val.to_string());
                }
            }
        }
    }
    entries
}

pub fn resolve_playlist_url(
    url: &str,
    headers: &HashMap<String, String>,
) -> std::io::Result<String> {
    resolve_playlist_url_with_token_opt(url, headers, None, Duration::from_secs(10))
}

pub fn resolve_playlist_url_with_token(
    url: &str,
    headers: &HashMap<String, String>,
    cancel: CancellationToken,
    timeout: Duration,
) -> std::io::Result<String> {
    resolve_playlist_url_with_token_opt(url, headers, Some(cancel), timeout)
}

pub fn resolve_playlist_url_with_cancel(
    url: &str,
    headers: &HashMap<String, String>,
    cancel: Option<Arc<AtomicBool>>,
    timeout: Duration,
) -> std::io::Result<String> {
    let header_map = build_header_map(headers)?;
    let start_url = url.trim().to_string();
    run_http_future_cancellable(
        resolve_playlist_url_async(start_url, header_map, timeout),
        cancel,
        timeout,
    )
}

pub(super) fn resolve_playlist_url_with_token_opt(
    url: &str,
    headers: &HashMap<String, String>,
    cancel: Option<CancellationToken>,
    timeout: Duration,
) -> std::io::Result<String> {
    let header_map = build_header_map(headers)?;
    let start_url = url.trim().to_string();
    run_http_future_cancellable_token(
        resolve_playlist_url_async(start_url, header_map, timeout),
        cancel,
        timeout,
    )
}

async fn resolve_playlist_url_async(
    start_url: String,
    header_map: HeaderMap,
    timeout: Duration,
) -> std::io::Result<String> {
    let client = http_client()?;
    let mut current = start_url;
    let mut visited = HashSet::new();

    for _depth in 0..MAX_PLAYLIST_DEPTH {
        if !visited.insert(current.clone()) {
            return Err(std::io::Error::new(
                ErrorKind::InvalidData,
                format!("Playlist redirect/reference cycle detected at {current}"),
            ));
        }

        let resp =
            send_following_redirects(&client, Method::GET, &current, &header_map, Some(timeout))
                .await?;

        let status = resp.status();
        if !status.is_success() {
            return Err(map_http_status_err(status, resp.url().as_str()));
        }

        let final_url = resp.url().clone();
        let content_type = header_str(resp.headers(), &CONTENT_TYPE);
        let mut body_bytes = Vec::new();
        let mut resp = resp;
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| std::io::Error::other(format!("HTTP playlist read failed: {e}")))?
        {
            let remaining = MAX_PLAYLIST_BYTES.saturating_sub(body_bytes.len());
            if remaining == 0 {
                break;
            }
            let take = remaining.min(chunk.len());
            body_bytes.extend_from_slice(&chunk[..take]);
            if body_bytes.len() >= MAX_PLAYLIST_BYTES {
                break;
            }
        }

        let body = String::from_utf8_lossy(&body_bytes);
        let is_pls = current.to_ascii_lowercase().contains(".pls")
            || content_type
                .as_deref()
                .is_some_and(|ct| ct.to_ascii_lowercase().contains("scpls"))
            || body
                .trim_start_matches('\u{feff}')
                .trim_start()
                .to_ascii_lowercase()
                .starts_with("[playlist]");

        let entries = if is_pls {
            parse_pls_entries(&body)
        } else {
            parse_m3u_entries(&body)
        };

        let Some(first_entry) = entries.into_iter().next() else {
            return Err(std::io::Error::new(
                ErrorKind::InvalidData,
                format!("Playlist at {current} contained no playable stream entries"),
            ));
        };

        let resolved = final_url
            .join(&first_entry)
            .map_err(|e| {
                std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("Invalid playlist entry '{first_entry}': {e}"),
                )
            })?
            .to_string();

        if is_playlist_url(&resolved) {
            current = resolved;
            continue;
        }
        return Ok(resolved);
    }

    Err(std::io::Error::new(
        ErrorKind::InvalidData,
        format!("Exceeded max playlist nesting depth ({MAX_PLAYLIST_DEPTH})"),
    ))
}
