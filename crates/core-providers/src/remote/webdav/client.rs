use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::time::Instant;

use core_db::normalize_match_key;
use core_types::{AlbumVersion, AudioFormat, CanonicalAlbum, ProviderKind, TrackSource};
use tokio::sync::mpsc::Sender;

use super::super::uri::{make_basic_auth, percent_decode};
use super::xml::{DavEntry, parse_propfind_xml};
use super::{WEBDAV_CREDENTIAL_SERVICE, WebDavProvider, infer_format_from_ext};
use crate::error::ProviderError;
use crate::http::HttpRequest;
use crate::local::{
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, extract_edition_label,
    find_folder_cover_in_files, is_scannable_audio, normalize_album_base_title,
};
use crate::traits::{ScanErrorItem, SyncProgress, SyncResult, SyncResultSummary};

type GroupedTrack = (String, String, u16, AudioFormat, String);

impl WebDavProvider {
    fn base_origin(&self) -> String {
        let scheme = if self.config.uri.is_ssl() {
            "https"
        } else {
            "http"
        };
        let host = self.config.uri.formatted_host();
        format!("{scheme}://{host}:{}", self.config.uri.port)
    }

    pub(super) fn root_rel_prefix_decoded(&self) -> String {
        percent_decode(&self.config.uri.relative_path)
            .trim_matches('/')
            .to_string()
    }

    pub(super) fn url_for_dav_path(&self, dav_path: &str) -> String {
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

    pub(super) async fn get_auth_header(&self) -> Option<(String, String)> {
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

    pub(super) async fn sync_library_impl(
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

                let name = display_trimmed.map(str::to_string).unwrap_or(href_segment);

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
        let mut grouped: HashMap<(String, String), Vec<GroupedTrack>> = HashMap::new();

        let mut last_progress_emit = Instant::now();
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
                if last_progress_emit.elapsed() >= std::time::Duration::from_millis(200)
                    || idx + 1 == scanned_count
                {
                    let _ = tx
                        .send(SyncProgress::FileScanned {
                            path: rel.clone(),
                            current: idx + 1,
                            total: Some(scanned_count),
                        })
                        .await;
                    last_progress_emit = Instant::now();
                }
            }
        }

        let mut albums = Vec::new();
        let mut all_tracks = Vec::new();

        for (_, mut items) in grouped {
            if items.is_empty() {
                continue;
            }
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

            let mut version_tracks = Vec::with_capacity(items.len());
            for (rel, title, track_num, format, _) in items {
                match TrackSource::new(
                    &version.id,
                    ProviderKind::WebDav,
                    rel.clone(),
                    title,
                    1,
                    track_num,
                    180_000,
                    format,
                ) {
                    Ok(trk) => version_tracks.push(trk),
                    Err(e) => errors.push(ScanErrorItem {
                        path: rel,
                        error: e.to_string(),
                    }),
                }
            }

            if !version_tracks.is_empty() {
                all_tracks.extend(version_tracks);
                album.add_version(version);
                albums.push(album);
            }
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
