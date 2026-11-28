use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Instant;

use windows::Win32::Foundation::{
    E_NOINTERFACE, E_POINTER, PROPERTYKEY, S_FALSE, S_OK, WAIT_OBJECT_0,
};
use windows::Win32::Media::Audio::{
    DEVICE_STATE, DEVICE_STATE_ACTIVE, EDataFlow, ERole, IMMDeviceEnumerator,
    IMMNotificationClient, IMMNotificationClient_Vtbl, MMDeviceEnumerator, eConsole, eRender,
};
use windows::Win32::System::Com::{
    CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows::Win32::System::Power::{
    DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS, HPOWERNOTIFY, PowerUnregisterSuspendResumeNotification,
};
use windows::Win32::System::Threading::{INFINITE, WaitForMultipleObjects};
use windows::core::{GUID, HRESULT, IUnknown, IUnknown_Vtbl, Interface, PCWSTR};

use crate::backend::wasapi_win::Win32Event;
use crate::backend::{DeviceEvent, DeviceEventDebouncer};
use crate::error::BackendError;

/// `DEVICE_NOTIFY_CALLBACK` flag for `PowerRegisterSuspendResumeNotification`.
const DEVICE_NOTIFY_CALLBACK_FLAG: u32 = 2;

/// Win32 power broadcast event codes delivered to `DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS::Callback`.
pub const PBT_APMSUSPEND: u32 = 0x0004;
pub const PBT_APMRESUMESUSPEND: u32 = 0x0007;
pub const PBT_APMRESUMEAUTOMATIC: u32 = 0x0012;

/// Maps raw Win32 `PBT_*` power notification codes to platform-agnostic [`DeviceEvent`]s.
pub fn map_power_event(event_type: u32) -> Option<DeviceEvent> {
    match event_type {
        PBT_APMSUSPEND => Some(DeviceEvent::SystemSuspend),
        PBT_APMRESUMEAUTOMATIC | PBT_APMRESUMESUSPEND => Some(DeviceEvent::SystemResume),
        _ => None,
    }
}

struct ComMtaGuard(bool);

impl ComMtaGuard {
    fn init() -> Self {
        let hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        Self(hr == S_OK || hr == S_FALSE)
    }
}

impl Drop for ComMtaGuard {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() };
        }
    }
}

#[inline]
fn pcwstr_to_nonempty_string(p: PCWSTR) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { p.to_string() }
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Self-contained COM implementation of `IMMNotificationClient` (zero extra crate dependencies).
#[repr(C)]
struct ComNotificationClient {
    vtbl: *const IMMNotificationClient_Vtbl,
    ref_count: AtomicU32,
    tx: mpsc::Sender<DeviceEvent>,
    wake: Arc<Win32Event>,
}

impl ComNotificationClient {
    const VTBL: IMMNotificationClient_Vtbl = IMMNotificationClient_Vtbl {
        base__: IUnknown_Vtbl {
            QueryInterface: Self::query_interface,
            AddRef: Self::add_ref,
            Release: Self::release,
        },
        OnDeviceStateChanged: Self::on_device_state_changed,
        OnDeviceAdded: Self::on_device_added,
        OnDeviceRemoved: Self::on_device_removed,
        OnDefaultDeviceChanged: Self::on_default_device_changed,
        OnPropertyValueChanged: Self::on_property_value_changed,
    };

    fn into_interface(
        tx: mpsc::Sender<DeviceEvent>,
        wake: Arc<Win32Event>,
    ) -> IMMNotificationClient {
        let raw = Box::into_raw(Box::new(Self {
            vtbl: &Self::VTBL,
            ref_count: AtomicU32::new(1),
            tx,
            wake,
        })) as *mut c_void;
        unsafe { IMMNotificationClient::from_raw(raw) }
    }

    #[inline]
    fn emit(&self, ev: DeviceEvent) {
        if self.tx.send(ev).is_ok() {
            self.wake.signal();
        }
    }

    unsafe extern "system" fn query_interface(
        this: *mut c_void,
        iid: *const GUID,
        interface: *mut *mut c_void,
    ) -> HRESULT {
        if interface.is_null() {
            return E_POINTER;
        }
        if iid.is_null() {
            unsafe { *interface = std::ptr::null_mut() };
            return E_NOINTERFACE;
        }
        let target = unsafe { &*iid };
        if *target == IUnknown::IID || *target == IMMNotificationClient::IID {
            unsafe {
                Self::add_ref(this);
                *interface = this;
            }
            S_OK
        } else {
            unsafe { *interface = std::ptr::null_mut() };
            E_NOINTERFACE
        }
    }

    unsafe extern "system" fn add_ref(this: *mut c_void) -> u32 {
        let obj = unsafe { &*(this as *const Self) };
        obj.ref_count
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_add(1)
    }

    unsafe extern "system" fn release(this: *mut c_void) -> u32 {
        let obj = unsafe { &*(this as *const Self) };
        let prev = obj.ref_count.fetch_sub(1, Ordering::Release);
        if prev == 1 {
            std::sync::atomic::fence(Ordering::Acquire);
            unsafe {
                drop(Box::from_raw(this as *mut Self));
            }
            0
        } else {
            prev.saturating_sub(1)
        }
    }

    unsafe extern "system" fn on_device_state_changed(
        this: *mut c_void,
        pwstrdeviceid: PCWSTR,
        dwnewstate: DEVICE_STATE,
    ) -> HRESULT {
        let obj = unsafe { &*(this as *const Self) };
        if let Some(id) = pcwstr_to_nonempty_string(pwstrdeviceid) {
            if dwnewstate == DEVICE_STATE_ACTIVE {
                obj.emit(DeviceEvent::DeviceAdded(id));
            } else {
                obj.emit(DeviceEvent::DeviceRemoved(id));
            }
        }
        S_OK
    }

    unsafe extern "system" fn on_device_added(this: *mut c_void, pwstrdeviceid: PCWSTR) -> HRESULT {
        let obj = unsafe { &*(this as *const Self) };
        if let Some(id) = pcwstr_to_nonempty_string(pwstrdeviceid) {
            obj.emit(DeviceEvent::DeviceAdded(id));
        }
        S_OK
    }

    unsafe extern "system" fn on_device_removed(
        this: *mut c_void,
        pwstrdeviceid: PCWSTR,
    ) -> HRESULT {
        let obj = unsafe { &*(this as *const Self) };
        if let Some(id) = pcwstr_to_nonempty_string(pwstrdeviceid) {
            obj.emit(DeviceEvent::DeviceRemoved(id));
        }
        S_OK
    }

    unsafe extern "system" fn on_default_device_changed(
        this: *mut c_void,
        flow: EDataFlow,
        role: ERole,
        pwstrdefaultdeviceid: PCWSTR,
    ) -> HRESULT {
        let obj = unsafe { &*(this as *const Self) };
        if flow == eRender
            && role == eConsole
            && let Some(id) = pcwstr_to_nonempty_string(pwstrdefaultdeviceid)
        {
            obj.emit(DeviceEvent::DefaultRenderChanged(id));
        }
        S_OK
    }

    unsafe extern "system" fn on_property_value_changed(
        _this: *mut c_void,
        _pwstrdeviceid: PCWSTR,
        _key: PROPERTYKEY,
    ) -> HRESULT {
        S_OK
    }
}

struct PowerCallbackContext {
    tx: mpsc::Sender<DeviceEvent>,
    wake: Arc<Win32Event>,
}

unsafe extern "system" fn power_notify_callback(
    context: *const c_void,
    event_type: u32,
    _setting: *const c_void,
) -> u32 {
    if !context.is_null()
        && let Some(ev) = map_power_event(event_type)
    {
        let ctx = unsafe { &*(context as *const PowerCallbackContext) };
        if ctx.tx.send(ev).is_ok() {
            ctx.wake.signal();
        }
    }
    0 // ERROR_SUCCESS
}

unsafe fn register_suspend_resume_callback(
    params: &DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS,
) -> Option<HPOWERNOTIFY> {
    #[link(name = "powrprof")]
    unsafe extern "system" {
        fn PowerRegisterSuspendResumeNotification(
            flags: u32,
            recipient: *const c_void,
            registrationhandle: *mut *mut c_void,
        ) -> u32;
    }
    let mut raw: *mut c_void = std::ptr::null_mut();
    let rc = unsafe {
        PowerRegisterSuspendResumeNotification(
            DEVICE_NOTIFY_CALLBACK_FLAG,
            params as *const DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS as *const c_void,
            &mut raw,
        )
    };
    if rc == 0 && !raw.is_null() {
        Some(HPOWERNOTIFY(raw as isize))
    } else {
        tracing::warn!("PowerRegisterSuspendResumeNotification failed with Win32 error {rc}");
        None
    }
}

/// Windows hardware endpoint & suspend/resume watcher backed by `IMMNotificationClient` and
/// `PowerRegisterSuspendResumeNotification` on a dedicated lightweight MTA thread.
///
/// All COM and Win32 power registrations are cleanly unregistered on [`Drop`].
pub struct DeviceWatcher {
    stop_event: Arc<Win32Event>,
    handle: Option<JoinHandle<()>>,
}

impl DeviceWatcher {
    /// Starts watching Windows render endpoint changes, USB DAC hotplug, and system sleep/wake,
    /// delivering debounced [`DeviceEvent`]s to `on_event`.
    pub fn start<F>(on_event: F) -> Result<Self, BackendError>
    where
        F: Fn(DeviceEvent) + Send + Sync + 'static,
    {
        Self::start_with_debouncer(DeviceEventDebouncer::new(), on_event)
    }

    /// Starts the watcher with a custom [`DeviceEventDebouncer`] configuration.
    pub fn start_with_debouncer<F>(
        mut debouncer: DeviceEventDebouncer,
        on_event: F,
    ) -> Result<Self, BackendError>
    where
        F: Fn(DeviceEvent) + Send + Sync + 'static,
    {
        let stop_event = Arc::new(Win32Event::new_manual_reset()?);
        let wake_event = Arc::new(Win32Event::new_auto_reset()?);
        let th_stop = Arc::clone(&stop_event);
        let th_wake = Arc::clone(&wake_event);
        let (ack_tx, ack_rx) = mpsc::sync_channel::<Result<(), BackendError>>(1);

        let handle = thread::Builder::new()
            .name("lumina-device-watcher".to_string())
            .spawn(move || {
                let _com = ComMtaGuard::init();
                let enumerator: IMMDeviceEnumerator =
                    match unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) } {
                        Ok(e) => e,
                        Err(e) => {
                            let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                                "DeviceWatcher CoCreateInstance(MMDeviceEnumerator) failed: {e}"
                            ))));
                            return;
                        }
                    };

                let (raw_tx, raw_rx) = mpsc::channel::<DeviceEvent>();
                let client =
                    ComNotificationClient::into_interface(raw_tx.clone(), Arc::clone(&th_wake));

                if let Err(e) = unsafe { enumerator.RegisterEndpointNotificationCallback(&client) }
                {
                    let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                        "RegisterEndpointNotificationCallback failed: {e}"
                    ))));
                    return;
                }

                // Pin callback context on heap until PowerUnregisterSuspendResumeNotification completes.
                let power_ctx = Box::new(PowerCallbackContext {
                    tx: raw_tx,
                    wake: Arc::clone(&th_wake),
                });
                let subscribe_params = DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
                    Callback: Some(power_notify_callback),
                    Context: (&*power_ctx as *const PowerCallbackContext) as *mut c_void,
                };
                let power_handle = unsafe { register_suspend_resume_callback(&subscribe_params) };

                if ack_tx.send(Ok(())).is_err() {
                    if let Some(h) = power_handle {
                        unsafe {
                            let _ = PowerUnregisterSuspendResumeNotification(h);
                        }
                    }
                    unsafe {
                        let _ = enumerator.UnregisterEndpointNotificationCallback(&client);
                    }
                    drop(power_ctx);
                    return;
                }

                let wait_handles = [th_stop.raw(), th_wake.raw()];
                loop {
                    let timeout_ms = match debouncer.next_deadline() {
                        Some(dl) => dl
                            .saturating_duration_since(Instant::now())
                            .as_millis()
                            .min((INFINITE - 1) as u128) as u32,
                        None => INFINITE,
                    };

                    let wait = unsafe { WaitForMultipleObjects(&wait_handles, false, timeout_ms) };
                    if wait.0 == WAIT_OBJECT_0.0 || wait.0 == 0xFFFF_FFFF {
                        break;
                    }

                    let now = Instant::now();
                    while let Ok(raw_ev) = raw_rx.try_recv() {
                        if let Some(immediate) = debouncer.push(raw_ev, now) {
                            on_event(immediate);
                        }
                    }
                    for due_ev in debouncer.poll_due(Instant::now()) {
                        on_event(due_ev);
                    }
                }

                // Strictly unregister callbacks BEFORE freeing context / COM interfaces.
                if let Some(h) = power_handle {
                    unsafe {
                        let _ = PowerUnregisterSuspendResumeNotification(h);
                    }
                }
                unsafe {
                    let _ = enumerator.UnregisterEndpointNotificationCallback(&client);
                }
                drop(power_ctx);
                drop(client);
                drop(enumerator);
            })
            .map_err(|e| {
                BackendError::DriverError(format!("Failed to spawn DeviceWatcher thread: {e}"))
            })?;

        match ack_rx.recv() {
            Ok(Ok(())) => Ok(Self {
                stop_event,
                handle: Some(handle),
            }),
            Ok(Err(e)) => {
                stop_event.signal();
                let _ = handle.join();
                Err(e)
            }
            Err(_) => {
                stop_event.signal();
                let _ = handle.join();
                Err(BackendError::DriverError(
                    "DeviceWatcher thread terminated during startup".into(),
                ))
            }
        }
    }

    pub fn stop(mut self) {
        self.shutdown_internal();
    }

    fn shutdown_internal(&mut self) {
        self.stop_event.signal();
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for DeviceWatcher {
    fn drop(&mut self) {
        self.shutdown_internal();
    }
}
