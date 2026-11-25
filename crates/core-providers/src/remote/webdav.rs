use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_db::credential::CredentialStore;
use core_db::normalize_match_key;
use core_types::{AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use quick_xml::events::Event;
use quick_xml::Reader;
use tokio::sync::{mpsc::Sender, RwLock};

use super::uri::{make_basic_auth, percent_decode, RemoteShareUri};
use crate::error::ProviderError;
use crate::http::{HttpRequest, HttpTransport, ReqwestHttpTransport};
use crate::local::{
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, extract_edition_label,
    find_folder_cover_in_files, is_scannable_audio, normalize_album_base_title,
};
use crate::traits::{
    MusicProvider, ProviderCapabilities, ResolvedStream, ScanErrorItem, SyncProgress, SyncResult,
    SyncResultSummary,
};

pub const WEBDAV_CREDENTIAL_SERVICE: &str = "com.lumina.audio.webdav";

#[derive(Debug, Clone)]
pub struct WebDavConfig {
    pub uri: RemoteShareUri,
}

#[derive(Debug, Clone)]
struct DavEntry {
    href_path: String,
    is_collection: bool,
    display_name: Option<String>,
    last_modified: Option<String>,
    content_length: Option<u64>,
}

pub type WebDavEntryMetaMap = HashMap<String, (Option<String>, Option<u64>)>;

pub struct WebDavProvider {
    config: WebDavConfig,
    transport: Arc<dyn HttpTransport>,
    credential_store: Option<Arc<dyn CredentialStore>>,
    online: Arc<RwLock<bool>>,
    cached_albums: Arc<RwLock<Vec<CanonicalAlbum>>>,
    cached_tracks: Arc<RwLock<Vec<TrackSource>>>,
    cached_entry_metadata: Arc<RwLock<WebDavEntryMetaMap>>,
}

impl WebDavProvider {
    pub fn new(config: WebDavConfig, credential_store: Option<Arc<dyn CredentialStore>>) -> Self {
        Self::with_transport(
            config,
            Arc::new(ReqwestHttpTransport::new()),
            credential_store,
        )
    }

    pub fn with_transport(
        config: WebDavConfig,
        transport: Arc<dyn HttpTransport>,
        credential_store: Option<Arc<dyn CredentialStore>>,
    ) -> Self {
        Self {
            config,
            transport,
            credential_store,
            online: Arc::new(RwLock::new(true)),
            cached_albums: Arc::new(RwLock::new(Vec::new())),
            cached_tracks: Arc::new(RwLock::new(Vec::new())),
            cached_entry_metadata: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn last_entry_metadata(&self) -> HashMap<String, (Option<String>, Option<u64>)> {
        self.cached_entry_metadata.read().await.clone()
    }

    pub async fn set_online(&self, online: bool) {
        let mut w = self.online.write().await;
        *w = online;
    }

    pub async fn is_online(&self) -> bool {
        *self.online.read().await
    }

    pub fn config(&self) -> &WebDavConfig {
        &self.config
    }

    fn base_origin(&self) -> String {
        let scheme = if self.config.uri.is_ssl() {
            "https"
        } else {
            "http"
        };
        let host = self.config.uri.formatted_host();
        format!("{scheme}://{host}:{}", self.config.uri.port)
    }

    fn root_rel_prefix_decoded(&self) -> String {
        percent_decode(&self.config.uri.relative_path)
            .trim_matches('/')
            .to_string()
    }

    fn url_for_dav_path(&self, dav_path: &str) -> String {
        let origin = self.base_origin();
        let is_dir = dav_path.ends_with('/');
        let clean = dav_path.trim_matches('/');
        if clean.is_empty() {
            format!("{origin}/")
        } else {
            let encoded: String = clean
                .split('/')
                .filter(|s| !s.is_empty())
                .map(percent_encode_path_segment)
                .collect::<Vec<_>>()
                .join("/");
            if encoded.is_empty() {
                format!("{origin}/")
            } else if is_dir {
                format!("{origin}/{encoded}/")
            } else {
                format!("{origin}/{encoded}")
            }
        }
    }

    async fn get_auth_header(&self) -> Option<(String, String)> {
        if let (Some(u), Some(p)) = (&self.config.uri.username, &self.config.uri.password) {
            return Some(("Authorization".to_string(), make_basic_auth(u, p)));
        }

        if let Some(ref store) = self.credential_store {
            let key = format!("{}:{}", self.config.uri.host, self.config.uri.port);
            if let Ok(Some(secret)) = store.get_secret(WEBDAV_CREDENTIAL_SERVICE, &key).await {
                if let Some(colon) = secret.find(':') {
                    let u = &secret[..colon];
                    let p = &secret[colon + 1..];
                    return Some(("Authorization".to_string(), make_basic_auth(u, p)));
                } else {
                    return Some(("Authorization".to_string(), format!("Bearer {secret}")));
                }
            }
        }

        None
    }

    async fn propfind_dir(&self, dir_path: &str) -> Result<Vec<DavEntry>, ProviderError> {
        let mut req_url = self.url_for_dav_path(dir_path);
        if !req_url.ends_with('/') {
            req_url.push('/');
        }

        let propfind_body = r#"<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:displayname/>
    <D:getlastmodified/>
    <D:getcontentlength/>
    <D:getcontenttype/>
  </D:prop>
</D:propfind>"#;

        let mut req = HttpRequest::with_method("PROPFIND", req_url)
            .with_header("Depth", "1")
            .with_header("Content-Type", "application/xml; charset=utf-8")
            .with_body(propfind_body.as_bytes().to_vec());

        if let Some((k, v)) = self.get_auth_header().await {
            req = req.with_header(k, v);
        }

        let resp = self.transport.execute(req).await?;
        if resp.status == 401 || resp.status == 403 {
            return Err(ProviderError::AuthenticationFailed(format!(
                "WebDAV PROPFIND unauthorized (HTTP {})",
                resp.status
            )));
        }
        if resp.status >= 400 {
            return Err(ProviderError::ScanError(format!(
                "WebDAV PROPFIND failed on '{dir_path}' (HTTP {}): {}",
                resp.status, resp.body
            )));
        }

        parse_propfind_xml(&resp.body)
    }

    fn strip_base_prefix(&self, raw_path: &str) -> String {
        let decoded = percent_decode(raw_path);
        let trimmed = decoded.trim_start_matches('/');
        let base = self.root_rel_prefix_decoded();
        if base.is_empty() {
            trimmed.to_string()
        } else if trimmed == base {
            String::new()
        } else if let Some(rest) = trimmed.strip_prefix(&base) {
            if rest.starts_with('/') {
                rest.trim_start_matches('/').to_string()
            } else {
                trimmed.to_string()
            }
        } else {
            trimmed.to_string()
        }
    }
}

#[async_trait]
impl MusicProvider for WebDavProvider {
    fn kind(&self) -> ProviderKind {
        ProviderKind::WebDav
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::webdav()
    }

    async fn is_authenticated(&self) -> bool {
        if self.config.uri.is_authenticated {
            return true;
        }

        if let Some(ref store) = self.credential_store {
            let key = format!("{}:{}", self.config.uri.host, self.config.uri.port);
            if let Ok(Some(secret)) = store.get_secret(WEBDAV_CREDENTIAL_SERVICE, &key).await {
                return !secret.trim().is_empty();
            }
        }

        false
    }

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let q = query.trim().to_ascii_lowercase();
        if q.is_empty() || limit == 0 {
            return Ok(Vec::new());
        }
        let albums = self.cached_albums.read().await;
        Ok(albums
            .iter()
            .filter(|a| {
                a.title.to_ascii_lowercase().contains(&q)
                    || a.artist_name.to_ascii_lowercase().contains(&q)
            })
            .take(limit)
            .cloned()
            .collect())
    }

    async fn resolve_stream(&self, track: &TrackSource) -> Result<ResolvedStream, ProviderError> {
        if !self.is_online().await {
            return Err(ProviderError::StreamResolutionFailed(format!(
                "WebDAV server '{}:{}' is offline",
                self.config.uri.host, self.config.uri.port
            )));
        }

        let base_path = self.root_rel_prefix_decoded();
        let track_rel = track.external_track_id.trim_start_matches('/');

        let stream_url = if track.external_track_id.starts_with("http://")
            || track.external_track_id.starts_with("https://")
        {
            track.external_track_id.clone()
        } else if base_path.is_empty() {
            self.url_for_dav_path(track_rel)
        } else {
            self.url_for_dav_path(&format!("{base_path}/{track_rel}"))
        };

        let mut headers = Vec::new();
        if let Some(auth_hdr) = self.get_auth_header().await {
            headers.push(auth_hdr);
        }

        let hint = Path::new(track_rel)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());

        Ok(ResolvedStream::http_stream(
            stream_url,
            track.format.clone(),
            headers,
            hint,
        )
        .with_replay_gain_from_track(track))
    }

    async fn sync_library(&self) -> Result<SyncResult, ProviderError> {
        self.sync_library_with_progress(None).await
    }

    async fn sync_library_with_progress(
        &self,
        progress_tx: Option<Sender<SyncProgress>>,
    ) -> Result<SyncResult, ProviderError> {
        if !self.is_online().await {
            return Err(ProviderError::StreamResolutionFailed(
                "WebDAV server is offline".into(),
            ));
        }

        let start = Instant::now();
        if let Some(ref tx) = progress_tx {
            let _ = tx
                .send(SyncProgress::Started {
                    provider: ProviderKind::WebDav,
                    total_files: None,
                })
                .await;
        }

        let root_dir = format!("/{}", self.root_rel_prefix_decoded());
        let mut queue = VecDeque::new();
        let mut visited: HashSet<String> = HashSet::new();
        queue.push_back(normalize_dav_dir(&root_dir));

        let mut audio_rel_paths: Vec<String> = Vec::new();
        let mut dir_files: HashMap<String, Vec<String>> = HashMap::new();
        let mut entry_meta_map: HashMap<String, (Option<String>, Option<u64>)> = HashMap::new();
        let mut errors: Vec<ScanErrorItem> = Vec::new();

        while let Some(current_dir) = queue.pop_front() {
            let current_decoded = normalize_dav_dir(&percent_decode(&current_dir));
            if !visited.insert(current_decoded.clone()) {
                continue;
            }

            let entries = match self.propfind_dir(&current_decoded).await {
                Ok(list) => list,
                Err(e) => {
                    if visited.len() == 1 {
                        return Err(e);
                    }
                    errors.push(ScanErrorItem {
                        path: current_decoded,
                        error: e.to_string(),
                    });
                    continue;
                }
            };

            for entry in entries {
                let entry_decoded_path = normalize_dav_path(&percent_decode(&entry.href_path));
                let entry_decoded_dir = normalize_dav_dir(&entry_decoded_path);
                if entry_decoded_dir == current_decoded {
                    continue;
                }

                let href_segment = entry_decoded_path
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string();
                let display_trimmed = entry
                    .display_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty());

                if crate::local::ignore::should_ignore_name(&href_segment)
                    || display_trimmed.is_some_and(crate::local::ignore::should_ignore_name)
                {
                    continue;
                }

                let name = display_trimmed
                    .map(str::to_string)
                    .unwrap_or(href_segment);

                if entry.is_collection {
                    if !visited.contains(&entry_decoded_dir) {
                        queue.push_back(entry_decoded_dir);
                    }
                } else {
                    let rel = self.strip_base_prefix(&entry.href_path);
                    if rel.is_empty() {
                        continue;
                    }
                    let parent_rel = Path::new(&rel)
                        .parent()
                        .map(|p| p.to_string_lossy().replace('\\', "/"))
                        .unwrap_or_default();
                    let file_name = Path::new(&rel)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(&name)
                        .to_string();
                    dir_files.entry(parent_rel).or_default().push(file_name);

                    if is_scannable_audio(Path::new(&rel)) {
                        entry_meta_map.insert(
                            rel.clone(),
                            (entry.last_modified.clone(), entry.content_length),
                        );
                        audio_rel_paths.push(rel);
                    }
                }
            }
        }
        *self.cached_entry_metadata.write().await = entry_meta_map;

        let scanned_count = audio_rel_paths.len();
        let mut grouped: HashMap<(String, String), Vec<(String, String, u16, AudioFormat, String)>> =
            HashMap::new();

        for (idx, rel) in audio_rel_paths.iter().enumerate() {
            let p = Path::new(rel);
            let (title, track_num) = derive_title_and_track_from_filename(p);
            let (raw_album, raw_artist) = derive_album_and_artist_from_dir(p);
            let format = infer_format_from_ext(p);

            let norm_artist = normalize_match_key(&raw_artist);
            let norm_album = normalize_album_base_title(&raw_album);
            let parent_rel = p
                .parent()
                .map(|par| par.to_string_lossy().replace('\\', "/"))
                .unwrap_or_default();

            let is_unknown = norm_album.is_empty()
                || norm_artist.is_empty()
                || norm_album == "unknown album"
                || norm_artist == "unknown artist";
            let key = if is_unknown {
                (format!("__unknown__:{parent_rel}"), norm_album)
            } else {
                (norm_artist, norm_album)
            };

            grouped.entry(key).or_default().push((
                rel.clone(),
                title,
                track_num,
                format,
                raw_album,
            ));

            if let Some(ref tx) = progress_tx {
                let _ = tx
                    .send(SyncProgress::FileScanned {
                        path: rel.clone(),
                        current: idx + 1,
                        total: Some(scanned_count),
                    })
                    .await;
            }
        }

        let mut albums = Vec::new();
        let mut all_tracks = Vec::new();

        for (_, mut items) in grouped {
            items.sort_by_key(|(_, _, trk_num, _, _)| *trk_num);
            let first_rel = items[0].0.clone();
            let first_path = Path::new(&first_rel);
            let (_, artist_name) = derive_album_and_artist_from_dir(first_path);
            let raw_album_name = items[0].4.clone();
            let (base_title, edition) = extract_edition_label(&raw_album_name);

            let mut album = match CanonicalAlbum::new(&base_title, &artist_name) {
                Ok(a) => a,
                Err(e) => {
                    errors.push(ScanErrorItem {
                        path: first_rel,
                        error: e.to_string(),
                    });
                    continue;
                }
            };

            let parent_rel = first_path
                .parent()
                .map(|p| p.to_string_lossy().replace('\\', "/"))
                .unwrap_or_default();
            if let Some(files_in_dir) = dir_files.get(&parent_rel) {
                let file_refs: Vec<&str> = files_in_dir.iter().map(String::as_str).collect();
                if let Some(cover_file) = find_folder_cover_in_files(&file_refs) {
                    let cover_rel = if parent_rel.is_empty() {
                        cover_file
                    } else {
                        format!("{parent_rel}/{cover_file}")
                    };
                    let base_path = self.root_rel_prefix_decoded();
                    let full_dav_path = if base_path.is_empty() {
                        cover_rel
                    } else {
                        format!("{base_path}/{cover_rel}")
                    };
                    album = album.with_cover_url(self.url_for_dav_path(&full_dav_path));
                }
            }

            let ext_album_id = if parent_rel.is_empty() {
                "webdav-root".to_string()
            } else {
                parent_rel.clone()
            };
            let rep_format = items[0].3.clone();
            let mut version =
                AlbumVersion::new(&album.id, ProviderKind::WebDav, ext_album_id, rep_format)?;
            if let Some(ed) = edition {
                version = version.with_edition_label(ed);
            }

            for (rel, title, track_num, format, _) in items {
                let trk = TrackSource::new(
                    &version.id,
                    ProviderKind::WebDav,
                    rel,
                    title,
                    1,
                    track_num,
                    180_000,
                    format,
                )?;
                all_tracks.push(trk);
            }

            album.add_version(version);
            albums.push(album);
        }

        *self.cached_albums.write().await = albums.clone();
        *self.cached_tracks.write().await = all_tracks.clone();

        let duration_ms = start.elapsed().as_millis() as u64;
        let failed = errors.len();
        let successful = all_tracks.len();

        if let Some(ref tx) = progress_tx {
            let _ = tx
                .send(SyncProgress::Completed {
                    summary: SyncResultSummary {
                        provider: ProviderKind::WebDav,
                        albums_count: albums.len(),
                        tracks_count: all_tracks.len(),
                        errors_count: failed,
                        duration_ms,
                    },
                })
                .await;
        }

        Ok(SyncResult {
            albums,
            tracks: all_tracks,
            scanned_files_count: scanned_count,
            successful_tracks_count: successful,
            failed_files_count: failed,
            errors,
        })
    }
}

fn parse_propfind_xml(xml: &str) -> Result<Vec<DavEntry>, ProviderError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut entries = Vec::new();
    let mut element_depth: usize = 0;
    let mut saw_root = false;

    let mut in_response = false;
    let mut in_propstat = false;
    let mut in_resourcetype = false;
    let mut current_tag: Option<String> = None;

    let mut cur_href = String::new();
    let mut cur_is_col = false;
    let mut cur_display: Option<String> = None;
    let mut cur_last_modified: Option<String> = None;
    let mut cur_content_length: Option<u64> = None;
    let mut resp_status_text = String::new();
    let mut has_any_propstat = false;
    let mut has_ok_propstat = false;

    let mut ps_is_col = false;
    let mut ps_display: Option<String> = None;
    let mut ps_last_modified: Option<String> = None;
    let mut ps_content_length_str = String::new();
    let mut ps_status_text = String::new();

    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                element_depth += 1;
                saw_root = true;
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                match name.as_str() {
                    "response" => {
                        in_response = true;
                        in_propstat = false;
                        in_resourcetype = false;
                        cur_href.clear();
                        cur_is_col = false;
                        cur_display = None;
                        cur_last_modified = None;
                        cur_content_length = None;
                        resp_status_text.clear();
                        has_any_propstat = false;
                        has_ok_propstat = false;
                    }
                    "propstat" if in_response => {
                        in_propstat = true;
                        has_any_propstat = true;
                        ps_is_col = false;
                        ps_display = None;
                        ps_last_modified = None;
                        ps_content_length_str.clear();
                        ps_status_text.clear();
                    }
                    "resourcetype" if in_response => {
                        in_resourcetype = true;
                    }
                    "collection" if in_response && in_resourcetype => {
                        if in_propstat {
                            ps_is_col = true;
                        } else {
                            cur_is_col = true;
                        }
                    }
                    "href" | "displayname" | "status" | "getlastmodified" | "getcontentlength"
                        if in_response =>
                    {
                        current_tag = Some(name);
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(ref e)) => {
                saw_root = true;
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                if in_response && in_resourcetype && name == "collection" {
                    if in_propstat {
                        ps_is_col = true;
                    } else {
                        cur_is_col = true;
                    }
                }
            }
            Ok(Event::Text(ref e)) => {
                if in_response {
                    if let Some(ref tag) = current_tag {
                        let text = e.unescape().unwrap_or_default().into_owned();
                        match tag.as_str() {
                            "href" => cur_href.push_str(&text),
                            "displayname" => {
                                if in_propstat {
                                    let entry = ps_display.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                } else {
                                    let entry = cur_display.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                }
                            }
                            "getlastmodified" => {
                                if in_propstat {
                                    let entry = ps_last_modified.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                } else {
                                    let entry = cur_last_modified.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                }
                            }
                            "getcontentlength" => {
                                if in_propstat {
                                    ps_content_length_str.push_str(&text);
                                } else if let Ok(len) = text.trim().parse::<u64>() {
                                    cur_content_length = Some(len);
                                }
                            }
                            "status" => {
                                if in_propstat {
                                    ps_status_text.push_str(&text);
                                } else {
                                    resp_status_text.push_str(&text);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Ok(Event::End(ref e)) => {
                element_depth = element_depth.saturating_sub(1);
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                match name.as_str() {
                    "response" => {
                        let resp_status_ok = parse_dav_status_is_ok(&resp_status_text);
                        let propstat_ok = !has_any_propstat || has_ok_propstat;
                        if !cur_href.trim().is_empty() && resp_status_ok && propstat_ok {
                            entries.push(DavEntry {
                                href_path: extract_path_from_href(&cur_href),
                                is_collection: cur_is_col,
                                display_name: cur_display.take(),
                                last_modified: cur_last_modified
                                    .take()
                                    .map(|s| s.trim().to_string())
                                    .filter(|s| !s.is_empty()),
                                content_length: cur_content_length.take(),
                            });
                        }
                        in_response = false;
                        in_propstat = false;
                        in_resourcetype = false;
                        current_tag = None;
                    }
                    "propstat" if in_response => {
                        if parse_dav_status_is_ok(&ps_status_text) {
                            has_ok_propstat = true;
                            if ps_is_col {
                                cur_is_col = true;
                            }
                            if cur_display.is_none() {
                                cur_display = ps_display.take();
                            }
                            if cur_last_modified.is_none() {
                                cur_last_modified = ps_last_modified.take();
                            }
                            if cur_content_length.is_none() {
                                cur_content_length = ps_content_length_str.trim().parse::<u64>().ok();
                            }
                        }
                        in_propstat = false;
                        in_resourcetype = false;
                        current_tag = None;
                    }
                    "resourcetype" => {
                        in_resourcetype = false;
                    }
                    "href" | "displayname" | "status" | "getlastmodified" | "getcontentlength" => {
                        current_tag = None;
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(ProviderError::ScanError(format!(
                    "Failed to parse WebDAV PROPFIND XML: {e}"
                )));
            }
            _ => {}
        }
        buf.clear();
    }

    if !saw_root || in_response || in_propstat || element_depth != 0 {
        return Err(ProviderError::ScanError(
            "Truncated or incomplete WebDAV PROPFIND XML".to_string(),
        ));
    }

    Ok(entries)
}

fn parse_dav_status_is_ok(status_text: &str) -> bool {
    let trimmed = status_text.trim();
    if trimmed.is_empty() {
        return true;
    }
    for tok in trimmed.split_whitespace() {
        if tok.len() == 3 && tok.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(code) = tok.parse::<u16>() {
                return (200..=299).contains(&code);
            }
        }
    }
    false
}

fn percent_encode_path_segment(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for &b in segment.as_bytes() {
        let is_safe = matches!(
            b,
            b'A'..=b'Z'
                | b'a'..=b'z'
                | b'0'..=b'9'
                | b'-'
                | b'.'
                | b'_'
                | b'~'
                | b'('
                | b')'
                | b'!'
                | b'$'
                | b'\''
                | b'*'
                | b'+'
                | b','
                | b';'
                | b'='
                | b':'
                | b'@'
        );
        if is_safe {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn extract_path_from_href(href: &str) -> String {
    let trimmed = href.trim();
    if let Ok(parsed) = url::Url::parse(trimmed) {
        parsed.path().to_string()
    } else {
        trimmed.to_string()
    }
}

fn normalize_dav_path(path: &str) -> String {
    if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    }
}

fn normalize_dav_dir(path: &str) -> String {
    let mut s = normalize_dav_path(path);
    if !s.ends_with('/') {
        s.push('/');
    }
    s
}

fn infer_format_from_ext(path: &Path) -> AudioFormat {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "dsf" => AudioFormat::dsd(AudioCodec::Dsf, 2_822_400, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "dff" => AudioFormat::dsd(AudioCodec::Dsdiff, 2_822_400, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "mp3" => AudioFormat::pcm(AudioCodec::Mp3, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "aac" => AudioFormat::pcm(AudioCodec::Aac, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "m4a" | "alac" => AudioFormat::pcm(AudioCodec::Alac, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "wav" | "wave" => AudioFormat::pcm(AudioCodec::Wav, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "aiff" | "aif" => AudioFormat::pcm(AudioCodec::Aiff, 44100, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        "ogg" | "opus" => AudioFormat::pcm(AudioCodec::Opus, 48000, 16, 2)
            .unwrap_or_else(|_| AudioFormat::cd_quality()),
        _ => AudioFormat::cd_quality(),
    }
}
