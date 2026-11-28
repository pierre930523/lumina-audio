use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use super::{NormalizedLoudness, StreamKey};

pub const DEFAULT_DEEZER_BLOCK_SIZE: usize = 2048;
pub const DEFAULT_DEEZER_STRIDE: usize = 3;

fn default_deezer_block_size() -> usize {
    DEFAULT_DEEZER_BLOCK_SIZE
}

fn default_deezer_stride() -> usize {
    DEFAULT_DEEZER_STRIDE
}

/// Adaptive streaming manifest format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManifestFormat {
    Dash,
    Hls,
}

/// Stream payload encryption specification for encrypted range transports.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StreamCipher {
    DeezerBlowfish {
        track_id: String,
        #[serde(default = "default_deezer_block_size")]
        block_size: usize,
        #[serde(default = "default_deezer_stride")]
        stride: usize,
    },
}

/// Declarative stream source specification passed from resolvers to audio proxies/backends.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StreamSourceSpec {
    DirectRange {
        key: StreamKey,
        url: String,
        #[serde(default, alias = "http_headers")]
        headers: BTreeMap<String, String>,
        #[serde(default)]
        content_length: Option<u64>,
        #[serde(default)]
        bitrate_bps: Option<u64>,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        hint_extension: Option<String>,
        #[serde(default)]
        expire_at: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        init_range_end: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        index_range_start: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        index_range_end: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    SegmentedManifest {
        key: StreamKey,
        manifest_url_or_xml: String,
        format: ManifestFormat,
        #[serde(default, alias = "http_headers")]
        headers: BTreeMap<String, String>,
        #[serde(default)]
        bitrate_bps: Option<u64>,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        expire_at: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    EncryptedRange {
        key: StreamKey,
        url: String,
        #[serde(default, alias = "http_headers")]
        headers: BTreeMap<String, String>,
        #[serde(default)]
        content_length: Option<u64>,
        #[serde(default)]
        bitrate_bps: Option<u64>,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        hint_extension: Option<String>,
        cipher: StreamCipher,
        #[serde(default)]
        expire_at: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    LocalFile {
        key: StreamKey,
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    ExternalBackend {
        key: StreamKey,
        provider_id: String,
        track_uri: String,
        #[serde(default)]
        external_web_url: Option<String>,
        #[serde(default)]
        preview_url: Option<String>,
        #[serde(default)]
        notice: Option<String>,
    },
}

impl StreamSourceSpec {
    /// Returns the composite stream key associated with this source specification.
    pub fn key(&self) -> &StreamKey {
        match self {
            Self::DirectRange { key, .. }
            | Self::SegmentedManifest { key, .. }
            | Self::EncryptedRange { key, .. }
            | Self::LocalFile { key, .. }
            | Self::ExternalBackend { key, .. } => key,
        }
    }

    /// Returns track-level normalized loudness metadata, if present.
    pub fn loudness(&self) -> Option<NormalizedLoudness> {
        match self {
            Self::DirectRange { loudness, .. }
            | Self::SegmentedManifest { loudness, .. }
            | Self::EncryptedRange { loudness, .. }
            | Self::LocalFile { loudness, .. } => *loudness,
            Self::ExternalBackend { .. } => None,
        }
    }

    /// Returns album-level normalized loudness metadata, if present.
    pub fn album_loudness(&self) -> Option<NormalizedLoudness> {
        match self {
            Self::DirectRange { album_loudness, .. }
            | Self::SegmentedManifest { album_loudness, .. }
            | Self::EncryptedRange { album_loudness, .. }
            | Self::LocalFile { album_loudness, .. } => *album_loudness,
            Self::ExternalBackend { .. } => None,
        }
    }
}
