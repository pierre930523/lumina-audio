use std::collections::HashSet;
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use core_types::SkipReason;

use super::ignore::{classify_unsupported_container, is_playlist_sidecar, should_ignore_name};

pub const SCANNABLE_AUDIO_EXTENSIONS: &[&str] = &[
    "flac", "alac", "wav", "wave", "aiff", "aif", "dsf", "dff", "mp3", "m4a", "aac", "ogg", "opus",
];

pub const COVER_ART_FILENAMES: &[&str] = &[
    "cover.jpg",
    "cover.jpeg",
    "cover.png",
    "folder.jpg",
    "folder.jpeg",
    "folder.png",
    "front.jpg",
    "front.png",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanSkippedCandidate {
    pub path: PathBuf,
    pub reason: SkipReason,
    pub detail: String,
    pub file_size: Option<u64>,
    pub file_mtime: Option<i64>,
}

#[derive(Debug, Clone, Default)]
pub struct DetailedScanOutput {
    pub audio_files: Vec<PathBuf>,
    pub playlist_files: Vec<PathBuf>,
    pub skipped_candidates: Vec<ScanSkippedCandidate>,
}

pub fn is_scannable_audio(path: &Path) -> bool {
    let file_name = match path.file_name().and_then(|n| n.to_str()) {
        Some(name) => name,
        None => return false,
    };

    if should_ignore_name(file_name) {
        return false;
    }

    let ext = match path.extension().and_then(|e| e.to_str()) {
        Some(ext) => ext.to_ascii_lowercase(),
        None => return false,
    };

    SCANNABLE_AUDIO_EXTENSIONS.contains(&ext.as_str())
}

pub fn normalize_path(path: impl AsRef<Path>) -> String {
    let p = path.as_ref();
    let s = p.to_string_lossy().replace('\\', "/");
    #[cfg(windows)]
    {
        s.to_ascii_lowercase()
    }
    #[cfg(not(windows))]
    {
        if s.len() >= 2 && s.as_bytes()[1] == b':' {
            s.to_ascii_lowercase()
        } else {
            s
        }
    }
}

pub fn find_folder_cover_in_files(files: &[&str]) -> Option<String> {
    for expected in COVER_ART_FILENAMES {
        for file in files {
            if file.eq_ignore_ascii_case(expected) {
                return Some((*file).to_string());
            }
        }
    }
    None
}

pub fn find_folder_cover(dir: &Path) -> Option<PathBuf> {
    let entries = fs::read_dir(dir).ok()?;
    let mut path_map = std::collections::HashMap::new();

    for entry in entries.flatten() {
        if let Ok(file_type) = entry.file_type() {
            if file_type.is_file() {
                if let Some(name) = entry.file_name().to_str() {
                    path_map.insert(name.to_ascii_lowercase(), entry.path());
                }
            }
        }
    }

    for expected in COVER_ART_FILENAMES {
        if let Some(path) = path_map.get(*expected) {
            return Some(path.clone());
        }
    }

    None
}

pub struct DirectoryScanner {
    visited_paths: HashSet<PathBuf>,
    follow_symlinks: bool,
}

impl DirectoryScanner {
    pub fn new(follow_symlinks: bool) -> Self {
        Self {
            visited_paths: HashSet::new(),
            follow_symlinks,
        }
    }

    pub fn scan_directory(&mut self, root: &Path) -> Vec<PathBuf> {
        self.scan_detailed(root).audio_files
    }

    pub fn scan_detailed(&mut self, root: &Path) -> DetailedScanOutput {
        let mut output = DetailedScanOutput::default();
        self.traverse(root, &mut output);
        output
    }

    fn traverse(&mut self, current: &Path, output: &mut DetailedScanOutput) {
        let canonical = match fs::canonicalize(current) {
            Ok(p) => p,
            Err(e) => {
                if e.kind() == ErrorKind::PermissionDenied {
                    output.skipped_candidates.push(ScanSkippedCandidate {
                        path: current.to_path_buf(),
                        reason: SkipReason::PermissionDenied,
                        detail: format!("Permission denied accessing directory: {e}"),
                        file_size: None,
                        file_mtime: None,
                    });
                }
                return;
            }
        };

        if !self.visited_paths.insert(canonical) {
            return;
        }

        let entries = match fs::read_dir(current) {
            Ok(iter) => iter,
            Err(e) => {
                let reason = if e.kind() == ErrorKind::PermissionDenied {
                    SkipReason::PermissionDenied
                } else {
                    SkipReason::IoError
                };
                output.skipped_candidates.push(ScanSkippedCandidate {
                    path: current.to_path_buf(),
                    reason,
                    detail: format!("Failed to read directory: {e}"),
                    file_size: None,
                    file_mtime: None,
                });
                return;
            }
        };

        for entry_res in entries {
            let entry = match entry_res {
                Ok(e) => e,
                Err(e) => {
                    let reason = if e.kind() == ErrorKind::PermissionDenied {
                        SkipReason::PermissionDenied
                    } else {
                        SkipReason::IoError
                    };
                    output.skipped_candidates.push(ScanSkippedCandidate {
                        path: current.to_path_buf(),
                        reason,
                        detail: format!("Failed to read directory entry: {e}"),
                        file_size: None,
                        file_mtime: None,
                    });
                    continue;
                }
            };

            let path = entry.path();
            let file_name = match path.file_name().and_then(|n| n.to_str()) {
                Some(name) => name,
                None => continue,
            };

            if should_ignore_name(file_name) {
                continue;
            }

            let file_type = match entry.file_type() {
                Ok(ft) => ft,
                Err(e) => {
                    let reason = if e.kind() == ErrorKind::PermissionDenied {
                        SkipReason::PermissionDenied
                    } else {
                        SkipReason::IoError
                    };
                    output.skipped_candidates.push(ScanSkippedCandidate {
                        path,
                        reason,
                        detail: format!("Failed to inspect file type: {e}"),
                        file_size: None,
                        file_mtime: None,
                    });
                    continue;
                }
            };

            if file_type.is_symlink() && !self.follow_symlinks {
                continue;
            }

            let is_dir = file_type.is_dir()
                || (file_type.is_symlink() && self.follow_symlinks && path.is_dir());

            if is_dir {
                self.traverse(&path, output);
            } else if file_type.is_file()
                || (file_type.is_symlink() && self.follow_symlinks && path.is_file())
            {
                if is_scannable_audio(&path) {
                    output.audio_files.push(path);
                } else if is_playlist_sidecar(&path) {
                    output.playlist_files.push(path);
                } else if let Some(reason) = classify_unsupported_container(&path) {
                    let (file_size, file_mtime) = read_size_mtime(&path);
                    let detail = match reason {
                        SkipReason::UnsplitCueOrIso => {
                            "Unsplit CUE sheet or disc ISO image is not directly playable"
                                .to_string()
                        }
                        _ => format!(
                            "Unsupported audio container (.{})",
                            path.extension()
                                .and_then(|e| e.to_str())
                                .unwrap_or("unknown")
                        ),
                    };
                    output.skipped_candidates.push(ScanSkippedCandidate {
                        path,
                        reason,
                        detail,
                        file_size,
                        file_mtime,
                    });
                }
            }
        }
    }
}

pub(crate) fn read_size_mtime(path: &Path) -> (Option<u64>, Option<i64>) {
    match fs::metadata(path) {
        Ok(m) => {
            let mtime = m
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64);
            (Some(m.len()), mtime)
        }
        Err(_) => (None, None),
    }
}
