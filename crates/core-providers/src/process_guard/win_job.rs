use std::ffi::c_void;
use std::io;
use windows::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, HANDLE};
use windows::Win32::System::JobObjects::{
    AssignProcessToJobObject, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
    SetInformationJobObject,
};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_SET_QUOTA, PROCESS_TERMINATE};

// `windows::Win32::System::JobObjects::CreateJobObjectW` requires the `Win32_Security` feature
// solely for the optional `SECURITY_ATTRIBUTES` parameter. Since we always pass NULL, linking
// directly to `kernel32::CreateJobObjectW` avoids pulling an extra crate feature.
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateJobObjectW(lpjobattributes: *const c_void, lpname: *const u16) -> *mut c_void;
}

/// RAII wrapper around a Win32 Job Object handle configured with
/// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
pub(super) struct WinJobObject(HANDLE);

// SAFETY: Win32 kernel Job Object handles are thread-safe to transfer and close
// from any thread.
unsafe impl Send for WinJobObject {}
unsafe impl Sync for WinJobObject {}

impl WinJobObject {
    pub(super) fn create() -> io::Result<Self> {
        // SAFETY: Passing NULL for security attributes and name creates an unnamed
        // job object with default security descriptor.
        let raw = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if raw.is_null() {
            return Err(io::Error::last_os_error());
        }

        let job = Self(HANDLE(raw));

        let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        // SAFETY: `info` is properly initialized and sized for
        // `JobObjectExtendedLimitInformation`, and `job.0` is a valid job handle.
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                (&raw const info).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        }
        .map_err(|e| io::Error::other(format!("SetInformationJobObject failed: {e}")))?;

        Ok(job)
    }

    /// Assign a child process to this job object.
    ///
    /// Returns `Ok(true)` if assigned, `Ok(false)` if `ERROR_ACCESS_DENIED` was returned
    /// (caller should check if the process already exited).
    pub(super) fn assign_raw_or_pid(
        &self,
        raw_handle: Option<*mut std::ffi::c_void>,
        pid: Option<u32>,
    ) -> io::Result<bool> {
        if let Some(raw) = raw_handle {
            let proc_handle = HANDLE(raw);
            // SAFETY: `self.0` is a valid job handle and `proc_handle` is owned by `Child`.
            return match unsafe { AssignProcessToJobObject(self.0, proc_handle) } {
                Ok(()) => Ok(true),
                Err(e) if e.code() == ERROR_ACCESS_DENIED.to_hresult() => Ok(false),
                Err(e) => Err(io::Error::other(format!(
                    "AssignProcessToJobObject failed: {e}"
                ))),
            };
        }

        let Some(pid) = pid else {
            return Ok(false);
        };

        // SAFETY: Opening process by PID with minimal required rights for job assignment.
        let proc_handle =
            match unsafe { OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, pid) } {
                Ok(h) => h,
                Err(e) if e.code() == ERROR_ACCESS_DENIED.to_hresult() => return Ok(false),
                Err(e) => {
                    return Err(io::Error::other(format!("OpenProcess({pid}) failed: {e}")));
                }
            };

        // SAFETY: Both handles are valid; `proc_handle` is closed immediately afterward.
        let res = unsafe { AssignProcessToJobObject(self.0, proc_handle) };
        let _ = unsafe { CloseHandle(proc_handle) };

        match res {
            Ok(()) => Ok(true),
            Err(e) if e.code() == ERROR_ACCESS_DENIED.to_hresult() => Ok(false),
            Err(e) => Err(io::Error::other(format!(
                "AssignProcessToJobObject failed: {e}"
            ))),
        }
    }
}

impl Drop for WinJobObject {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            // SAFETY: `self.0` is uniquely owned by `WinJobObject` and closed once here.
            // Closing the handle triggers `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
            let _ = unsafe { CloseHandle(self.0) };
            self.0 = HANDLE::default();
        }
    }
}
