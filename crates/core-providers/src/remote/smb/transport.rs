use std::collections::HashMap;
use std::path::PathBuf;

use async_trait::async_trait;
use tokio::sync::RwLock;

use super::{SmbConfig, SmbEntry};
use crate::error::ProviderError;
use crate::local::DirectoryScanner;

#[async_trait]
pub trait SmbTransport: Send + Sync {
    async fn list_entries(&self, config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError>;

    async fn resolve_stream_target(
        &self,
        config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError>;
}

/// Pure-Rust Windows UNC transport (`\\host\share\...`), requiring zero native C SMB libraries.
#[derive(Debug, Default, Clone)]
pub struct UncSmbTransport;

impl UncSmbTransport {
    pub fn unc_root(config: &SmbConfig) -> PathBuf {
        let host = config.uri.host.trim();
        let share = config.uri.share_name.trim_matches(['/', '\\']);
        let rel = config
            .uri
            .relative_path
            .trim_matches(['/', '\\'])
            .replace('/', "\\");
        let base = if share.is_empty() {
            format!(r"\\{host}")
        } else if rel.is_empty() {
            format!(r"\\{host}\{share}")
        } else {
            format!(r"\\{host}\{share}\{rel}")
        };
        PathBuf::from(base)
    }
}

#[async_trait]
impl SmbTransport for UncSmbTransport {
    async fn list_entries(&self, config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError> {
        #[cfg(windows)]
        {
            let root = Self::unc_root(config);
            if !root.exists() {
                return Err(ProviderError::ScanError(format!(
                    "SMB UNC path '{}' does not exist or is unreachable",
                    root.display()
                )));
            }
            let mut scanner = DirectoryScanner::new(false);
            let files = scanner.scan_directory(&root);
            let entries = files
                .into_iter()
                .map(|p| {
                    let rel = p
                        .strip_prefix(&root)
                        .map(|r| r.to_string_lossy().replace('\\', "/"))
                        .unwrap_or_else(|_| p.to_string_lossy().replace('\\', "/"));
                    SmbEntry {
                        relative_path: rel,
                        local_path: Some(p),
                        metadata: None,
                    }
                })
                .collect();
            Ok(entries)
        }
        #[cfg(not(windows))]
        {
            let _ = config;
            Err(ProviderError::ScanError(
                "UNC SMB scanning requires Windows or a mounted FilesystemSmbTransport root"
                    .to_string(),
            ))
        }
    }

    async fn resolve_stream_target(
        &self,
        _config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError> {
        if external_track_id.starts_with("smb://") {
            return Ok(None);
        }
        let p = PathBuf::from(external_track_id);
        if p.exists() { Ok(Some(p)) } else { Ok(None) }
    }
}

/// Pure-Rust filesystem-backed SMB transport for mounted shares or integration tests.
#[derive(Debug, Clone)]
pub struct FilesystemSmbTransport {
    mounted_root: PathBuf,
}

impl FilesystemSmbTransport {
    pub fn new(mounted_root: impl Into<PathBuf>) -> Self {
        Self {
            mounted_root: mounted_root.into(),
        }
    }

    fn effective_root(&self, config: &SmbConfig) -> PathBuf {
        let rel = config.uri.relative_path.trim_matches(['/', '\\']);
        if rel.is_empty() {
            self.mounted_root.clone()
        } else {
            let candidate = self.mounted_root.join(rel);
            if candidate.exists() {
                candidate
            } else {
                self.mounted_root.clone()
            }
        }
    }
}

#[async_trait]
impl SmbTransport for FilesystemSmbTransport {
    async fn list_entries(&self, config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError> {
        let root = self.effective_root(config);
        if !root.exists() {
            return Err(ProviderError::ScanError(format!(
                "Mounted SMB root '{}' does not exist",
                root.display()
            )));
        }
        let mut scanner = DirectoryScanner::new(false);
        let files = scanner.scan_directory(&root);
        let entries = files
            .into_iter()
            .map(|p| {
                let rel = p
                    .strip_prefix(&self.mounted_root)
                    .map(|r| r.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_else(|_| p.to_string_lossy().replace('\\', "/"));
                SmbEntry {
                    relative_path: rel,
                    local_path: Some(p),
                    metadata: None,
                }
            })
            .collect();
        Ok(entries)
    }

    async fn resolve_stream_target(
        &self,
        _config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError> {
        let direct = PathBuf::from(external_track_id);
        if direct.exists() {
            return Ok(Some(direct));
        }
        let trimmed = external_track_id.trim_start_matches(['/', '\\']);
        let joined = self.mounted_root.join(trimmed);
        if joined.exists() {
            Ok(Some(joined))
        } else {
            Ok(None)
        }
    }
}

/// In-memory mock SMB transport for deterministic tests.
#[derive(Default)]
pub struct MockSmbTransport {
    entries: RwLock<Vec<SmbEntry>>,
    resolved_targets: RwLock<HashMap<String, PathBuf>>,
}

impl MockSmbTransport {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn add_entry(&self, entry: SmbEntry) {
        self.entries.write().await.push(entry);
    }

    pub async fn register_target(&self, external_track_id: impl Into<String>, path: PathBuf) {
        self.resolved_targets
            .write()
            .await
            .insert(external_track_id.into(), path);
    }
}

#[async_trait]
impl SmbTransport for MockSmbTransport {
    async fn list_entries(&self, _config: &SmbConfig) -> Result<Vec<SmbEntry>, ProviderError> {
        Ok(self.entries.read().await.clone())
    }

    async fn resolve_stream_target(
        &self,
        _config: &SmbConfig,
        external_track_id: &str,
    ) -> Result<Option<PathBuf>, ProviderError> {
        Ok(self
            .resolved_targets
            .read()
            .await
            .get(external_track_id)
            .cloned())
    }
}
