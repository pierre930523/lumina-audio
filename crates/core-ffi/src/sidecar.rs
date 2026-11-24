use crate::error::{catch_unwind_ffi, set_last_error, LUMINA_ERR_GENERAL, LUMINA_OK};
use std::os::raw::c_int;

#[cfg(target_os = "windows")]
mod win_job {
    use std::ffi::c_void;
    use std::sync::OnceLock;
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
        SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    use windows::Win32::System::Threading::{
        OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE,
    };

    pub(super) struct JobObjectGuard(HANDLE);

    // SAFETY: Win32 kernel HANDLEs are process-wide and thread-safe for AssignProcessToJobObject.
    unsafe impl Send for JobObjectGuard {}
    unsafe impl Sync for JobObjectGuard {}

    impl JobObjectGuard {
        pub(super) fn create_kill_on_close() -> Result<Self, String> {
            unsafe {
                let job = CreateJobObjectW(None, None)
                    .map_err(|e| format!("CreateJobObjectW failed: {e}"))?;
                let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if let Err(e) = SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast::<c_void>(),
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ) {
                    let _ = CloseHandle(job);
                    return Err(format!("SetInformationJobObject failed: {e}"));
                }
                Ok(Self(job))
            }
        }

        pub(super) fn assign_pid(&self, pid: u32) -> Result<(), String> {
            unsafe {
                let proc_handle = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid)
                    .map_err(|e| format!("OpenProcess(pid={pid}) failed: {e}"))?;
                let res = AssignProcessToJobObject(self.0, proc_handle);
                let _ = CloseHandle(proc_handle);
                res.map_err(|e| format!("AssignProcessToJobObject(pid={pid}) failed: {e}"))
            }
        }
    }

    impl Drop for JobObjectGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }

    static GLOBAL_SIDECAR_JOB: OnceLock<Result<JobObjectGuard, String>> = OnceLock::new();

    pub(super) fn assign_pid_to_global_job(pid: u32) -> Result<(), String> {
        let job_res = GLOBAL_SIDECAR_JOB.get_or_init(JobObjectGuard::create_kill_on_close);
        match job_res {
            Ok(job) => job.assign_pid(pid),
            Err(err) => Err(err.clone()),
        }
    }
}

/// Assigns a local sidecar child process `pid` to a Win32 Job Object configured with
/// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` so the OS automatically terminates the sidecar
/// if the host process exits or crashes. On non-Windows platforms (macOS uses `stdin`
/// anonymous pipe EOF monitoring), this is a clean no-op returning `LUMINA_OK`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_sidecar_assign_job(pid: u32) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_sidecar_assign_job", || {
        if pid == 0 {
            set_last_error("pid must be greater than 0");
            return Ok(LUMINA_ERR_GENERAL);
        }

        #[cfg(target_os = "windows")]
        {
            if let Err(err) = win_job::assign_pid_to_global_job(pid) {
                set_last_error(err);
                return Ok(LUMINA_ERR_GENERAL);
            }
        }

        Ok(LUMINA_OK)
    })
}

/// Triggers non-blocking HTTP/2 TLS connection pool warmup on `core-audio`'s
/// shared `reqwest` client (`youtube.com` / `music.youtube.com`).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_streaming_warmup_h2() -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_streaming_warmup_h2", || {
        core_audio::streaming::spawn_http2_warmup();
        Ok(LUMINA_OK)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sidecar_assign_job_rejects_zero_pid() {
        assert_ne!(lumina_sidecar_assign_job(0), LUMINA_OK);
    }

    #[test]
    fn test_streaming_warmup_h2_non_blocking() {
        assert_eq!(lumina_streaming_warmup_h2(), LUMINA_OK);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn test_windows_job_object_kills_child_on_close() {
        use std::process::Command;
        use std::time::{Duration, Instant};

        let mut child = Command::new("cmd")
            .args(["/C", "ping -n 30 127.0.0.1 >NUL"])
            .spawn()
            .expect("spawn dummy child process");
        let pid = child.id();

        let job = win_job::JobObjectGuard::create_kill_on_close()
            .expect("create JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE job");
        job.assign_pid(pid).expect("assign child pid to job object");

        // Closing the Job Object handle must immediately terminate the assigned child.
        drop(job);

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut exited = false;
        while Instant::now() < deadline {
            if let Ok(Some(_status)) = child.try_wait() {
                exited = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        if !exited {
            let _ = child.kill();
            let _ = child.wait();
        }
        assert!(
            exited,
            "Child process must be terminated immediately when KILL_ON_JOB_CLOSE handle closes"
        );
    }
}
