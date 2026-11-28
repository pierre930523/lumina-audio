//! Cross-platform child-process lifecycle guard (Windows Job Object / Unix process groups),
//! bounded stderr ring buffer, and external binary locator.

mod guard;
mod locator;
mod ring_log;
#[cfg(target_os = "windows")]
mod win_job;

pub use guard::{ProcessGuard, is_process_alive};
pub use locator::{BinaryKind, BinaryLocator};
pub use ring_log::RingLogBuffer;

use std::ffi::OsStr;
use std::path::PathBuf;
use std::time::Duration;

/// Default maximum captured stdout size (8 MiB).
pub const DEFAULT_MAX_STDOUT_BYTES: usize = 8 * 1024 * 1024;
/// Default bounded stderr ring buffer capacity (4 KiB).
pub const DEFAULT_STDERR_RING_BYTES: usize = 4096;
/// Default grace period between `SIGTERM` and `SIGKILL` on Unix.
pub const DEFAULT_GRACE_PERIOD: Duration = Duration::from_millis(250);

// ---------------------------------------------------------------------------
// ProcessSpec & ProcessOutput
// ---------------------------------------------------------------------------

/// Specification for launching a guarded child process.
#[derive(Debug, Clone)]
pub struct ProcessSpec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub envs: Vec<(String, String)>,
    pub current_dir: Option<PathBuf>,
    pub max_stdout_bytes: usize,
    pub stderr_ring_bytes: usize,
    pub grace_period: Duration,
}

impl ProcessSpec {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            envs: Vec::new(),
            current_dir: None,
            max_stdout_bytes: DEFAULT_MAX_STDOUT_BYTES,
            stderr_ring_bytes: DEFAULT_STDERR_RING_BYTES,
            grace_period: DEFAULT_GRACE_PERIOD,
        }
    }

    pub fn arg(mut self, arg: impl Into<String>) -> Self {
        self.args.push(arg.into());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.envs.push((key.into(), value.into()));
        self
    }

    pub fn envs<I, K, V>(mut self, envs: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        self.envs
            .extend(envs.into_iter().map(|(k, v)| (k.into(), v.into())));
        self
    }

    pub fn current_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.current_dir = Some(dir.into());
        self
    }

    pub fn max_stdout_bytes(mut self, bytes: usize) -> Self {
        self.max_stdout_bytes = bytes;
        self
    }

    pub fn stderr_ring_bytes(mut self, bytes: usize) -> Self {
        self.stderr_ring_bytes = bytes;
        self
    }

    pub fn grace_period(mut self, duration: Duration) -> Self {
        self.grace_period = duration;
        self
    }

    pub(super) fn program_label(&self) -> String {
        self.program
            .file_name()
            .and_then(OsStr::to_str)
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| self.program.display().to_string())
    }
}

/// Captured result of a completed guarded process.
#[derive(Debug, Clone)]
pub struct ProcessOutput {
    pub exit_code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: String,
    pub stdout_truncated: bool,
}

impl ProcessOutput {
    pub fn stdout_string_lossy(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_log_buffer_wraps_and_trims_utf8_boundaries() {
        let mut ring = RingLogBuffer::new(10);
        ring.push(b"0123456789");
        assert_eq!(ring.len(), 10);
        assert_eq!(ring.as_string_lossy(), "0123456789");
        assert!(!ring.is_truncated());

        ring.push(b"abcde");
        assert_eq!(ring.len(), 10);
        assert_eq!(ring.as_string_lossy(), "56789abcde");
        assert!(ring.is_truncated());

        // Push multi-byte UTF-8 ("音樂" = 6 bytes) so it wraps mid-character.
        let mut utf8_ring = RingLogBuffer::new(5);
        utf8_ring.push("音樂".as_bytes()); // 6 bytes: [E9, 9F, B3, E6, A8, 82] -> keeps last 5: [9F, B3, E6, A8, 82]
        assert_eq!(utf8_ring.len(), 5);
        assert_eq!(utf8_ring.as_string_lossy(), "樂");
    }

    #[test]
    fn binary_kind_names_and_env_vars() {
        assert_eq!(BinaryKind::YtDlp.base_name(), "yt-dlp");
        assert_eq!(BinaryKind::YtDlp.env_var(), "LUMINA_YT_DLP_PATH");
        assert_eq!(BinaryKind::Ffmpeg.env_var(), "LUMINA_FFMPEG_PATH");
        assert_eq!(BinaryKind::Deno.env_var(), "LUMINA_DENO_PATH");

        #[cfg(target_os = "windows")]
        {
            assert_eq!(BinaryKind::YtDlp.executable_name(), "yt-dlp.exe");
            assert_eq!(BinaryKind::Ffmpeg.executable_name(), "ffmpeg.exe");
            assert_eq!(BinaryKind::Deno.executable_name(), "deno.exe");
        }
        #[cfg(not(target_os = "windows"))]
        {
            assert_eq!(BinaryKind::YtDlp.executable_name(), "yt-dlp");
            assert_eq!(BinaryKind::Ffmpeg.executable_name(), "ffmpeg");
            assert_eq!(BinaryKind::Deno.executable_name(), "deno");
        }
    }
}
