mod provider;
mod transport;

pub use provider::SmbProvider;
pub use transport::{FilesystemSmbTransport, MockSmbTransport, SmbTransport, UncSmbTransport};

use std::path::PathBuf;

use super::uri::RemoteShareUri;
use crate::local::ExtractedMetadata;

pub const SMB_CREDENTIAL_SERVICE: &str = "com.lumina.audio.smb";

#[derive(Debug, Clone)]
pub struct SmbConfig {
    pub uri: RemoteShareUri,
    pub domain: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SmbEntry {
    pub relative_path: String,
    pub local_path: Option<PathBuf>,
    pub metadata: Option<ExtractedMetadata>,
}
