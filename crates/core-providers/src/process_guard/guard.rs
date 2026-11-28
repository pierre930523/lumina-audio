use std::fmt;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::process::{Child, ChildStdout, Command};
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::error::ProviderError;

#[cfg(target_os = "windows")]
use super::win_job::WinJobObject;
use super::{ProcessOutput, ProcessSpec, RingLogBuffer};

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Check whether an OS process with `pid` is currently alive.
#[cfg(target_os = "windows")]
pub fn is_process_alive(pid: u32) -> bool {
    use windows::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    if pid == 0 {
        return false;
    }

    // SAFETY: Querying process liveness with read-only limited information access.
    unsafe {
        let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let mut exit_code: u32 = 0;
        let ok = GetExitCodeProcess(handle, &mut exit_code).is_ok();
        let _ = CloseHandle(handle);
        ok && exit_code == STILL_ACTIVE.0 as u32
    }
}

/// Check whether an OS process with `pid` is currently alive.
#[cfg(unix)]
pub fn is_process_alive(pid: u32) -> bool {
    if pid == 0 || pid > i32::MAX as u32 {
        return false;
    }
    // SAFETY: Signal 0 performs an existence/permission check without sending a signal.
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(any(target_os = "windows", unix)))]
pub fn is_process_alive(_pid: u32) -> bool {
    false
}

/// RAII child-process guard that guarantees process-tree termination on drop or cancellation
/// and continuously drains `stderr` into a bounded [`RingLogBuffer`].
pub struct ProcessGuard {
    program_label: String,
    child: Child,
    pid: Option<u32>,
    cancel: CancellationToken,
    max_stdout_bytes: usize,
    #[cfg(unix)]
    grace_period: Duration,
    stderr_ring: Arc<Mutex<RingLogBuffer>>,
    stderr_task: Option<JoinHandle<()>>,
    #[cfg(target_os = "windows")]
    job: Option<WinJobObject>,
    terminated: bool,
}

impl fmt::Debug for ProcessGuard {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProcessGuard")
            .field("program", &self.program_label)
            .field("pid", &self.pid)
            .field("terminated", &self.terminated)
            .finish()
    }
}

impl ProcessGuard {
    /// Spawn a child process under OS process-tree isolation with immediate background stderr draining.
    pub fn spawn(spec: &ProcessSpec, cancel: CancellationToken) -> Result<Self, ProviderError> {
        if cancel.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }

        let program_label = spec.program_label();

        #[cfg(target_os = "windows")]
        let job = WinJobObject::create().map_err(ProviderError::Io)?;

        let mut cmd = Command::new(&spec.program);
        cmd.args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        if let Some(dir) = &spec.current_dir {
            cmd.current_dir(dir);
        }
        for (k, v) in &spec.envs {
            cmd.env(k, v);
        }

        #[cfg(target_os = "windows")]
        {
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        #[cfg(unix)]
        {
            cmd.process_group(0);
        }

        let mut child = cmd.spawn().map_err(ProviderError::Io)?;
        let pid = child.id();

        #[cfg(target_os = "windows")]
        {
            match job.assign_raw_or_pid(child.raw_handle(), pid) {
                Ok(true) => {}
                Ok(false) => {
                    // Handle the race where the child exited before job assignment completed.
                    if matches!(child.try_wait(), Ok(Some(_))) {
                        debug!(
                            program = %program_label,
                            pid = ?pid,
                            "child already exited before job assignment"
                        );
                    } else {
                        let _ = child.start_kill();
                        drop(job);
                        return Err(ProviderError::Io(std::io::Error::new(
                            std::io::ErrorKind::PermissionDenied,
                            format!(
                                "failed to assign process '{program_label}' (pid={pid:?}) to Windows Job Object"
                            ),
                        )));
                    }
                }
                Err(err) => {
                    let _ = child.start_kill();
                    drop(job);
                    return Err(ProviderError::Io(err));
                }
            }
        }

        let stderr_ring = Arc::new(Mutex::new(RingLogBuffer::new(spec.stderr_ring_bytes)));
        let stderr_task = child.stderr.take().map(|mut stderr_pipe| {
            let ring = Arc::clone(&stderr_ring);
            let label = program_label.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 4096];
                loop {
                    match stderr_pipe.read(&mut buf).await {
                        Ok(0) => break,
                        Ok(n) => {
                            if let Ok(mut guard) = ring.lock() {
                                guard.push(&buf[..n]);
                            }
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => break,
                        Err(e) => {
                            debug!(program = %label, error = %e, "stderr drain stopped on I/O error");
                            break;
                        }
                    }
                }
            })
        });

        Ok(Self {
            program_label,
            child,
            pid,
            cancel,
            max_stdout_bytes: spec.max_stdout_bytes,
            #[cfg(unix)]
            grace_period: spec.grace_period,
            stderr_ring,
            stderr_task,
            #[cfg(target_os = "windows")]
            job: Some(job),
            terminated: false,
        })
    }

    /// Convenience helper to spawn a process, capture its output, and enforce cancellation.
    pub async fn run_capture(
        spec: &ProcessSpec,
        cancel: CancellationToken,
    ) -> Result<ProcessOutput, ProviderError> {
        let guard = Self::spawn(spec, cancel)?;
        guard.wait_with_output().await
    }

    /// OS process identifier captured when the child was spawned.
    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Take ownership of the child's `stdout` pipe for streaming callers.
    pub fn take_stdout(&mut self) -> Option<ChildStdout> {
        self.child.stdout.take()
    }

    /// Snapshot the trailing bounded `stderr` ring buffer as lossy UTF-8 text.
    pub fn stderr_snapshot(&self) -> String {
        self.stderr_ring
            .lock()
            .map(|ring| ring.as_string_lossy())
            .unwrap_or_default()
    }

    /// Immediately terminate the entire process tree and reap the child process.
    pub async fn terminate(&mut self) {
        if self.terminated {
            return;
        }
        self.terminated = true;

        #[cfg(target_os = "windows")]
        {
            // Dropping the Job Object handle immediately kills the entire process tree.
            drop(self.job.take());
            let _ = self.child.start_kill();
            let _ = tokio::time::timeout(Duration::from_secs(2), self.child.wait()).await;
        }

        #[cfg(unix)]
        {
            if !matches!(self.child.try_wait(), Ok(Some(_))) {
                if let Some(pgid) = self.pid.map(|p| p as libc::pid_t) {
                    // SAFETY: `pgid` was created as our child's process group leader (`process_group(0)`).
                    unsafe {
                        libc::killpg(pgid, libc::SIGTERM);
                    }
                    if tokio::time::timeout(self.grace_period, self.child.wait())
                        .await
                        .is_err()
                    {
                        // SAFETY: Escalate to SIGKILL for the whole process group after grace period.
                        unsafe {
                            libc::killpg(pgid, libc::SIGKILL);
                        }
                        let _ = self.child.wait().await;
                    } else {
                        // Ensure no lingering grandchildren survive after leader exit.
                        unsafe {
                            libc::killpg(pgid, libc::SIGKILL);
                        }
                    }
                } else {
                    let _ = self.child.kill().await;
                }
            }
        }

        #[cfg(not(any(target_os = "windows", unix)))]
        {
            let _ = self.child.kill().await;
        }

        if let Some(handle) = self.stderr_task.take() {
            if tokio::time::timeout(Duration::from_millis(200), handle)
                .await
                .is_err()
            {
                warn!(program = %self.program_label, "timed out waiting for stderr drain task during terminate");
            }
        }
    }

    /// Drain `stdout` (capped at `max_stdout_bytes`), wait for exit, and honor cancellation.
    pub async fn wait_with_output(mut self) -> Result<ProcessOutput, ProviderError> {
        if self.cancel.is_cancelled() {
            self.terminate().await;
            return Err(ProviderError::Cancelled);
        }

        let stdout = self.child.stdout.take();
        let max_stdout_bytes = self.max_stdout_bytes;
        let cancel = self.cancel.clone();

        enum Outcome {
            Cancelled,
            Finished(
                std::io::Result<(Vec<u8>, bool)>,
                std::io::Result<std::process::ExitStatus>,
            ),
        }

        let outcome = tokio::select! {
            biased;
            _ = cancel.cancelled() => Outcome::Cancelled,
            res = async {
                let (stdout_res, status_res) = tokio::join!(
                    drain_stdout_capped(stdout, max_stdout_bytes),
                    self.child.wait(),
                );
                Outcome::Finished(stdout_res, status_res)
            } => res,
        };

        // Note: `stdout` has already been dropped here if `Outcome::Cancelled` won,
        // so the read pipe is closed before terminating the process tree.
        match outcome {
            Outcome::Cancelled => {
                self.terminate().await;
                Err(ProviderError::Cancelled)
            }
            Outcome::Finished(stdout_res, status_res) => {
                self.terminated = true;
                #[cfg(target_os = "windows")]
                {
                    // Close the job handle so any lingering detached grandchildren are cleaned up.
                    drop(self.job.take());
                }

                if let Some(handle) = self.stderr_task.take() {
                    let _ = tokio::time::timeout(Duration::from_secs(1), handle).await;
                }

                let status = status_res.map_err(ProviderError::Io)?;
                let (stdout_bytes, stdout_truncated) = stdout_res.map_err(ProviderError::Io)?;
                let stderr = self.stderr_snapshot();
                let exit_code = status.code();

                if !status.success() {
                    return Err(ProviderError::ProcessFailed {
                        binary: self.program_label.clone(),
                        exit_code,
                        stderr,
                    });
                }

                Ok(ProcessOutput {
                    exit_code,
                    stdout: stdout_bytes,
                    stderr,
                    stdout_truncated,
                })
            }
        }
    }
}

impl Drop for ProcessGuard {
    fn drop(&mut self) {
        if let Some(handle) = self.stderr_task.take() {
            handle.abort();
        }

        if self.terminated {
            #[cfg(target_os = "windows")]
            {
                drop(self.job.take());
            }
            return;
        }
        self.terminated = true;

        #[cfg(target_os = "windows")]
        {
            // Closing the Job Object handle synchronously terminates the entire process tree.
            drop(self.job.take());
            let _ = self.child.start_kill();
        }

        #[cfg(unix)]
        {
            if let Some(pgid) = self.pid.map(|p| p as libc::pid_t) {
                // SAFETY: `pgid` is the child's dedicated process group created via `process_group(0)`.
                unsafe {
                    libc::killpg(pgid, libc::SIGKILL);
                }
            }
            let _ = self.child.start_kill();
            let _ = self.child.try_wait();
            if let Some(pgid) = self.pid.map(|p| p as libc::pid_t) {
                // SAFETY: Non-blocking reap of any already-terminated members in our process group.
                unsafe {
                    libc::waitpid(-pgid, std::ptr::null_mut(), libc::WNOHANG);
                }
            }
        }

        #[cfg(not(any(target_os = "windows", unix)))]
        {
            let _ = self.child.start_kill();
        }
    }
}

async fn drain_stdout_capped(
    stdout: Option<ChildStdout>,
    max_bytes: usize,
) -> std::io::Result<(Vec<u8>, bool)> {
    let Some(mut pipe) = stdout else {
        return Ok((Vec::new(), false));
    };

    let mut out = Vec::new();
    let mut truncated = false;
    let mut scratch = [0u8; 8192];

    loop {
        match pipe.read(&mut scratch).await {
            Ok(0) => break,
            Ok(n) => {
                if out.len() < max_bytes {
                    let remaining = max_bytes - out.len();
                    let take = n.min(remaining);
                    out.extend_from_slice(&scratch[..take]);
                    if take < n {
                        truncated = true;
                    }
                } else {
                    // Keep draining to prevent child pipe-buffer deadlock.
                    truncated = true;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => break,
            Err(e) => return Err(e),
        }
    }

    Ok((out, truncated))
}
