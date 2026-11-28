use std::fmt;
use std::path::{Path, PathBuf};

use crate::error::ProviderError;

const MAX_VENDOR_PARENT_DEPTH: usize = 6;

/// External helper binaries managed by Lumina providers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinaryKind {
    YtDlp,
    Ffmpeg,
    Deno,
}

impl BinaryKind {
    /// Platform-independent logical binary name.
    pub fn base_name(self) -> &'static str {
        match self {
            Self::YtDlp => "yt-dlp",
            Self::Ffmpeg => "ffmpeg",
            Self::Deno => "deno",
        }
    }

    /// Platform-specific executable filename.
    pub fn executable_name(self) -> &'static str {
        #[cfg(target_os = "windows")]
        {
            match self {
                Self::YtDlp => "yt-dlp.exe",
                Self::Ffmpeg => "ffmpeg.exe",
                Self::Deno => "deno.exe",
            }
        }
        #[cfg(not(target_os = "windows"))]
        {
            self.base_name()
        }
    }

    /// Environment variable name that overrides this binary's path.
    pub fn env_var(self) -> &'static str {
        match self {
            Self::YtDlp => "LUMINA_YT_DLP_PATH",
            Self::Ffmpeg => "LUMINA_FFMPEG_PATH",
            Self::Deno => "LUMINA_DENO_PATH",
        }
    }
}

impl fmt::Display for BinaryKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.base_name())
    }
}

/// Cross-platform resolver for bundled, user-updated, and system binaries.
///
/// Resolution order:
/// 1. Explicit override path in [`BinaryLocator`] + `LUMINA_*_PATH` environment variable
///    (+ any `extra_search_dirs`).
/// 2. User-updated directory (`%LOCALAPPDATA%\LuminaAudio\bin` on Windows;
///    `$XDG_DATA_HOME/lumina-audio/bin` or `$HOME/.local/share/lumina-audio/bin` on Unix).
/// 3. Bundled directory relative to `current_exe()` (`<exe_dir>/bin/<name>`, plus walking up
///    to 6 parent directories checking `app/windows/vendor/bin/<name>` and
///    `windows/vendor/bin/<name>`).
/// 4. System `PATH` fallback (respecting `PATHEXT` on Windows).
#[derive(Debug, Clone)]
pub struct BinaryLocator {
    pub yt_dlp_override: Option<PathBuf>,
    pub ffmpeg_override: Option<PathBuf>,
    pub deno_override: Option<PathBuf>,
    pub extra_search_dirs: Vec<PathBuf>,
    pub allow_system_fallback: bool,
}

impl Default for BinaryLocator {
    fn default() -> Self {
        Self::new()
    }
}

impl BinaryLocator {
    pub fn new() -> Self {
        Self {
            yt_dlp_override: None,
            ffmpeg_override: None,
            deno_override: None,
            extra_search_dirs: Vec::new(),
            allow_system_fallback: true,
        }
    }

    pub fn with_override(mut self, kind: BinaryKind, path: impl Into<PathBuf>) -> Self {
        let path = Some(path.into());
        match kind {
            BinaryKind::YtDlp => self.yt_dlp_override = path,
            BinaryKind::Ffmpeg => self.ffmpeg_override = path,
            BinaryKind::Deno => self.deno_override = path,
        }
        self
    }

    pub fn with_extra_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.extra_search_dirs.push(dir.into());
        self
    }

    /// Toggle steps 2-4 (user-updated dir, bundled dir, and system `PATH`).
    /// Useful in tests to deterministically assert [`ProviderError::BinaryMissing`].
    pub fn with_system_fallback(mut self, enabled: bool) -> Self {
        self.allow_system_fallback = enabled;
        self
    }

    pub fn resolve(&self, kind: BinaryKind) -> Result<PathBuf, ProviderError> {
        let explicit = match kind {
            BinaryKind::YtDlp => self.yt_dlp_override.as_deref(),
            BinaryKind::Ffmpeg => self.ffmpeg_override.as_deref(),
            BinaryKind::Deno => self.deno_override.as_deref(),
        };
        self.resolve_internal(
            kind.base_name(),
            kind.executable_name(),
            explicit,
            Some(kind.env_var()),
        )
    }

    /// Resolve a binary by arbitrary base name (and optional env override var).
    pub fn resolve_custom(
        &self,
        base_name: &str,
        env_var: Option<&str>,
    ) -> Result<PathBuf, ProviderError> {
        #[cfg(target_os = "windows")]
        let exe_name = if base_name.ends_with(".exe") {
            base_name.to_string()
        } else {
            format!("{base_name}.exe")
        };
        #[cfg(not(target_os = "windows"))]
        let exe_name = base_name.to_string();

        self.resolve_internal(base_name, &exe_name, None, env_var)
    }

    fn resolve_internal(
        &self,
        base_name: &str,
        exe_name: &str,
        explicit_override: Option<&Path>,
        env_var: Option<&str>,
    ) -> Result<PathBuf, ProviderError> {
        let mut searched = Vec::new();

        // 1a. Explicit override path in locator config.
        if let Some(override_path) = explicit_override {
            if let Some(found) = check_candidate(override_path, exe_name, &mut searched) {
                return Ok(found);
            }
        }

        // 1b. Environment variable override.
        if let Some(var) = env_var {
            if let Some(val) = std::env::var_os(var) {
                if !val.is_empty() {
                    let env_path = PathBuf::from(val);
                    if let Some(found) = check_candidate(&env_path, exe_name, &mut searched) {
                        return Ok(found);
                    }
                }
            }
        }

        // 1c. Extra caller-provided search directories.
        for dir in &self.extra_search_dirs {
            let candidate = dir.join(exe_name);
            if check_file(&candidate, &mut searched) {
                return Ok(candidate);
            }
        }

        if !self.allow_system_fallback {
            if searched.is_empty() {
                searched.push("explicit/env overrides only (system fallback disabled)".into());
            }
            return Err(ProviderError::BinaryMissing {
                binary: base_name.to_string(),
                searched,
            });
        }

        // 2. User-updated directory.
        if let Some(user_bin_dir) = user_updated_bin_dir() {
            let candidate = user_bin_dir.join(exe_name);
            if check_file(&candidate, &mut searched) {
                return Ok(candidate);
            }
        }

        // 3. Bundled directory relative to current_exe().
        if let Ok(exe_path) = std::env::current_exe() {
            if let Some(exe_dir) = exe_path.parent() {
                let bundled = exe_dir.join("bin").join(exe_name);
                if check_file(&bundled, &mut searched) {
                    return Ok(bundled);
                }

                for ancestor in exe_dir.ancestors().take(MAX_VENDOR_PARENT_DEPTH + 1) {
                    let app_vendor = ancestor
                        .join("app")
                        .join("windows")
                        .join("vendor")
                        .join("bin")
                        .join(exe_name);
                    if check_file(&app_vendor, &mut searched) {
                        return Ok(app_vendor);
                    }

                    let win_vendor = ancestor
                        .join("windows")
                        .join("vendor")
                        .join("bin")
                        .join(exe_name);
                    if check_file(&win_vendor, &mut searched) {
                        return Ok(win_vendor);
                    }
                }
            }
        }

        // 4. System PATH fallback.
        if let Some(found) = search_system_path(base_name, exe_name) {
            return Ok(found);
        }
        searched.push(format!("PATH ({exe_name})"));

        Err(ProviderError::BinaryMissing {
            binary: base_name.to_string(),
            searched,
        })
    }
}

fn check_candidate(path: &Path, exe_name: &str, searched: &mut Vec<String>) -> Option<PathBuf> {
    if path.is_file() {
        return Some(path.to_path_buf());
    }
    if path.is_dir() {
        let nested = path.join(exe_name);
        if nested.is_file() {
            return Some(nested);
        }
        searched.push(nested.display().to_string());
        return None;
    }
    searched.push(path.display().to_string());
    None
}

fn check_file(path: &Path, searched: &mut Vec<String>) -> bool {
    if path.is_file() {
        true
    } else {
        searched.push(path.display().to_string());
        false
    }
}

fn user_updated_bin_dir() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("LOCALAPPDATA")
            .filter(|v| !v.is_empty())
            .map(|base| PathBuf::from(base).join("LuminaAudio").join("bin"))
    }
    #[cfg(not(target_os = "windows"))]
    {
        if let Some(xdg) = std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
            return Some(PathBuf::from(xdg).join("lumina-audio").join("bin"));
        }
        std::env::var_os("HOME")
            .filter(|v| !v.is_empty())
            .map(|home| {
                PathBuf::from(home)
                    .join(".local")
                    .join("share")
                    .join("lumina-audio")
                    .join("bin")
            })
    }
}

fn search_system_path(base_name: &str, exe_name: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;

    #[cfg(target_os = "windows")]
    let pathext: Vec<String> = std::env::var("PATHEXT")
        .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_string())
        .split(';')
        .filter(|ext| !ext.is_empty())
        .map(|ext| ext.to_ascii_lowercase())
        .collect();

    for dir in std::env::split_paths(&path_var) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        let direct = dir.join(exe_name);
        if direct.is_file() {
            return Some(direct);
        }

        #[cfg(target_os = "windows")]
        {
            for ext in &pathext {
                if ext == ".exe" {
                    continue;
                }
                let candidate = dir.join(format!("{base_name}{ext}"));
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
        #[cfg(not(target_os = "windows"))]
        let _ = base_name;
    }
    None
}
