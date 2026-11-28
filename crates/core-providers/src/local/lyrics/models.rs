use serde::{Deserialize, Serialize};

/// Format of the parsed lyrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsFormat {
    Lrc,
    EnhancedLrc,
    Ttml,
    Plain,
}

/// Synchronization kind matching Interface Contract #3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsKind {
    Synced,
    Unsynced,
    None,
}

/// Source origin of the lyrics matching Interface Contract #3.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LyricsSource {
    UserFile,
    EmbeddedSynced,
    SidecarLrc,
    SidecarTtml,
    EmbeddedUnsynced,
    SidecarTxt,
    None,
}

/// Word-level timing metadata for Enhanced LRC.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricWord {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// Line-level lyrics entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricLine {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_ms: Option<u64>,
    pub text: String,
    #[serde(default)]
    pub words: Vec<LyricWord>,
}

/// Exact JSON-serializable output struct matching Interface Contract #3.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LyricsResult {
    pub found: bool,
    pub kind: LyricsKind,
    pub source: LyricsSource,
    pub format: LyricsFormat,
    pub offset_ms: i64,
    pub lines: Vec<LyricLine>,
}

impl Default for LyricsResult {
    fn default() -> Self {
        Self::empty()
    }
}

impl LyricsResult {
    pub fn empty() -> Self {
        Self {
            found: false,
            kind: LyricsKind::None,
            source: LyricsSource::None,
            format: LyricsFormat::Plain,
            offset_ms: 0,
            lines: Vec::new(),
        }
    }
}

/// Target selector for lyrics queries and user overrides.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LyricsTarget {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub track_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
}

pub struct LyricsManager;

#[derive(Default)]
pub(super) struct EmbeddedLyricsPair {
    pub(super) synced: Option<String>,
    pub(super) unsynced: Option<String>,
}
