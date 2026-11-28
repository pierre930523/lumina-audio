use serde::{Deserialize, Serialize};

fn default_folder_online() -> bool {
    true
}

// ============================================================================
// Step 3: Physical Folder Browsing DTOs
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FolderNode {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    pub name: String,
    pub norm_path: String,
    pub display_path: String,
    #[serde(default)]
    pub depth: u32,
    #[serde(default)]
    pub direct_track_count: u64,
    #[serde(default)]
    pub recursive_track_count: u64,
    #[serde(default = "default_folder_online")]
    pub is_online: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FolderBreadcrumb {
    pub id: String,
    pub name: String,
    pub display_path: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FolderContentsResponse<T> {
    pub folder: FolderNode,
    #[serde(default)]
    pub breadcrumbs: Vec<FolderBreadcrumb>,
    #[serde(default)]
    pub subfolders: Vec<FolderNode>,
    #[serde(default)]
    pub tracks: Vec<T>,
}

impl<T> FolderContentsResponse<T> {
    pub fn map_tracks<T2>(self, f: impl FnMut(T) -> T2) -> FolderContentsResponse<T2> {
        FolderContentsResponse {
            folder: self.folder,
            breadcrumbs: self.breadcrumbs,
            subfolders: self.subfolders,
            tracks: self.tracks.into_iter().map(f).collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_folder_json_contract_roundtrip() {
        let root = FolderNode {
            id: "fld-root".into(),
            root_id: Some("root-1".into()),
            parent_id: None,
            name: "Music".into(),
            norm_path: "d:/music".into(),
            display_path: r"D:\Music".into(),
            depth: 0,
            direct_track_count: 0,
            recursive_track_count: 42,
            is_online: true,
        };
        let resp = FolderContentsResponse {
            folder: root.clone(),
            breadcrumbs: vec![FolderBreadcrumb {
                id: root.id.clone(),
                name: root.name.clone(),
                display_path: root.display_path.clone(),
            }],
            subfolders: vec![],
            tracks: vec!["trk-1".to_string()],
        };

        let json = serde_json::to_string(&resp).unwrap();
        let decoded: FolderContentsResponse<String> = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, resp);
    }
}
