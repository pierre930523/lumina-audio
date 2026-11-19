use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

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

pub fn is_scannable_audio(path: &Path) -> bool {
    let file_name = match path.file_name().and_then(|n| n.to_str()) {
        Some(name) => name,
        None => return false,
    };

    // Ignore hidden files (e.g. .DS_Store, .hidden.flac)
    if file_name.starts_with('.') {
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
    let mut file_names = Vec::new();
    let mut path_map = std::collections::HashMap::new();

    for entry in entries.flatten() {
        if let Ok(file_type) = entry.file_type() {
            if file_type.is_file() {
                if let Some(name) = entry.file_name().to_str() {
                    let name_str = name.to_string();
                    file_names.push(name_str.clone());
                    path_map.insert(name_str.to_ascii_lowercase(), entry.path());
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
        let mut audio_files = Vec::new();
        self.traverse(root, &mut audio_files);
        audio_files
    }

    fn traverse(&mut self, current: &Path, results: &mut Vec<PathBuf>) {
        let canonical = match fs::canonicalize(current) {
            Ok(p) => p,
            Err(_) => return,
        };

        if !self.visited_paths.insert(canonical) {
            // Already visited or circular symlink detected
            return;
        }

        let entries = match fs::read_dir(current) {
            Ok(iter) => iter,
            Err(_) => return,
        };

        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = match path.file_name().and_then(|n| n.to_str()) {
                Some(name) => name,
                None => continue,
            };

            // Ignore hidden directories and files
            if file_name.starts_with('.') {
                continue;
            }

            let file_type = match entry.file_type() {
                Ok(ft) => ft,
                Err(_) => continue,
            };

            if file_type.is_symlink() && !self.follow_symlinks {
                continue;
            }

            let is_dir = file_type.is_dir()
                || (file_type.is_symlink() && self.follow_symlinks && path.is_dir());

            if is_dir {
                self.traverse(&path, results);
            } else if file_type.is_file()
                || (file_type.is_symlink() && self.follow_symlinks && path.is_file())
            {
                if is_scannable_audio(&path) {
                    results.push(path);
                }
            }
        }
    }
}
