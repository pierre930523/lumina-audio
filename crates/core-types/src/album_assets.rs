use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

use crate::ValidationError;

// ============================================================================
// Step 5: Album Assets (PDF Booklets & Multi-Image Gallery) DTOs
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlbumAssetKind {
    Pdf,
    Image,
}

impl AlbumAssetKind {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Pdf => "pdf",
            Self::Image => "image",
        }
    }
}

impl fmt::Display for AlbumAssetKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for AlbumAssetKind {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "pdf" => Ok(Self::Pdf),
            "image" => Ok(Self::Image),
            _ => Err(ValidationError::EmptyField {
                field: "asset_kind",
                message: "asset_kind must be 'pdf' or 'image'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlbumAssetSourceKind {
    File,
    Embedded,
}

impl AlbumAssetSourceKind {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::File => "file",
            Self::Embedded => "embedded",
        }
    }
}

impl fmt::Display for AlbumAssetSourceKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for AlbumAssetSourceKind {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "file" => Ok(Self::File),
            "embedded" => Ok(Self::Embedded),
            _ => Err(ValidationError::EmptyField {
                field: "source_kind",
                message: "source_kind must be 'file' or 'embedded'",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlbumAssetRole {
    Front,
    Back,
    Media,
    Booklet,
    #[default]
    Other,
}

impl AlbumAssetRole {
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Front => "front",
            Self::Back => "back",
            Self::Media => "media",
            Self::Booklet => "booklet",
            Self::Other => "other",
        }
    }
}

impl fmt::Display for AlbumAssetRole {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for AlbumAssetRole {
    type Err = ValidationError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "front" => Ok(Self::Front),
            "back" => Ok(Self::Back),
            "media" => Ok(Self::Media),
            "booklet" => Ok(Self::Booklet),
            "other" => Ok(Self::Other),
            _ => Err(ValidationError::EmptyField {
                field: "role",
                message: "asset role must be 'front', 'back', 'media', 'booklet', or 'other'",
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumAssetRecord {
    pub id: String,
    pub album_version_id: String,
    pub asset_kind: AlbumAssetKind,
    pub source_kind: AlbumAssetSourceKind,
    pub role: AlbumAssetRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedded_track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedded_pic_index: Option<i64>,
    pub mime_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size: Option<u64>,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub sort_order: i64,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AlbumAssetsResponse {
    pub album_version_id: String,
    #[serde(default)]
    pub pdfs: Vec<AlbumAssetRecord>,
    #[serde(default)]
    pub images: Vec<AlbumAssetRecord>,
    #[serde(default)]
    pub total_count: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_album_assets_serde_roundtrip() {
        let rec = AlbumAssetRecord {
            id: "asset-1".into(),
            album_version_id: "ver-1".into(),
            asset_kind: AlbumAssetKind::Pdf,
            source_kind: AlbumAssetSourceKind::File,
            role: AlbumAssetRole::Booklet,
            file_path: Some("/music/album/booklet.pdf".into()),
            embedded_track_id: None,
            embedded_pic_index: None,
            mime_type: "application/pdf".into(),
            width: None,
            height: None,
            file_size: Some(204_800),
            display_name: "Digital Booklet".into(),
            sort_order: 0,
            created_at: "2026-11-27T00:00:00Z".into(),
            updated_at: "2026-11-27T00:00:00Z".into(),
        };
        let v = serde_json::to_value(&rec).unwrap();
        assert_eq!(v["asset_kind"], "pdf");
        assert_eq!(v["source_kind"], "file");
        assert_eq!(v["role"], "booklet");
        assert_eq!(serde_json::from_value::<AlbumAssetRecord>(v).unwrap(), rec);
    }
}
