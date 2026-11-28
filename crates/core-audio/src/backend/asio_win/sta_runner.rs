use std::ffi::c_void;
use std::ptr::{NonNull, null_mut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use windows::Win32::System::Com::CLSIDFromString;
use windows::core::PCWSTR;

use crate::buffer::Consumer;
use crate::error::BackendError;
use crate::pipeline::rt_telemetry::RtErrorCode;
use crate::player::{AudioFadeControl, FadeTarget};
use crate::verification::{AudioVerificationEngine, WireSampleFormat};

use super::callbacks::{AsioCallbackSignals, AsioCallbackWatchdog};
use super::driver::AsioDriverEntry;
use super::ffi_types::{
    ASIO_OK, ASIO_ST_INT32_LSB, ASIO_SUCCESS, ASIO_TRUE, AsioBufferInfo, AsioCallbacks,
    AsioChannelInfo, AsioIoFormat, ComAsioPtr, ComStaGuard, IAsioVtbl, K_ASIO_FORMAT_DSD,
    K_ASIO_FORMAT_PCM, K_ASIO_SET_IO_FORMAT, com_create_asio_instance,
};
use super::render_core::AsioRenderCore;
use super::render_trampoline::{
    ACTIVE_ASIO_PTR, ACTIVE_ASIO_SESSION_ID, ASIO_MSG_BUFFER_SIZE, ASIO_MSG_LATENCIES_CHANGED,
    ASIO_MSG_RESET, ASIO_MSG_RESYNC, ASIO_MSG_SAMPLE_RATE_HZ, ASIO_MSG_SESSION_ID,
    ActiveAsioCallbackState, LAST_ASIO_BUFFER_FRAMES, asio_buffer_switch,
    asio_buffer_switch_time_info, asio_message, asio_sample_rate_changed,
    clear_and_drop_active_asio_state,
};

pub(super) struct AsioStaLaunch {
    pub(super) chosen: AsioDriverEntry,
    pub(super) sample_rate: u32,
    pub(super) channels: u16,
    pub(super) wire: WireSampleFormat,
    pub(super) native_dsd: bool,
    pub(super) consumer: Consumer<u8>,
    pub(super) verification: AudioVerificationEngine,
    pub(super) frames_rendered: Arc<std::sync::atomic::AtomicU64>,
    pub(super) nonzero_frames: Arc<std::sync::atomic::AtomicU64>,
    pub(super) state_code: Arc<std::sync::atomic::AtomicI32>,
    pub(super) eof_flag: Arc<AtomicBool>,
    pub(super) session_id: u64,
    pub(super) current_session_id: Arc<std::sync::atomic::AtomicU64>,
    pub(super) startup_watermark_bytes: usize,
    pub(super) fade_ctrl: Option<Arc<AudioFadeControl>>,
    pub(super) buffered_ms: Option<Arc<std::sync::atomic::AtomicU64>>,
    pub(super) th_paused: Arc<AtomicBool>,
    pub(super) th_stopped: Arc<AtomicBool>,
    pub(super) th_signals: Arc<AsioCallbackSignals>,
    pub(super) watchdog_timeout: Duration,
    pub(super) ack_tx: mpsc::SyncSender<Result<(String, u32), BackendError>>,
}

pub(super) fn spawn_asio_sta_thread(launch: AsioStaLaunch) -> Result<JoinHandle<()>, BackendError> {
    let AsioStaLaunch {
        chosen,
        sample_rate,
        channels,
        wire,
        native_dsd,
        consumer,
        verification,
        frames_rendered,
        nonzero_frames,
        state_code,
        eof_flag,
        session_id,
        current_session_id,
        startup_watermark_bytes,
        fade_ctrl,
        buffered_ms,
        th_paused,
        th_stopped,
        th_signals,
        watchdog_timeout,
        ack_tx,
    } = launch;
    let handle = thread::Builder::new()
        .name("lumina-asio-sta".to_string())
        .spawn(move || {
            let _com = ComStaGuard::init();
            let clsid_w: Vec<u16> = chosen
                .clsid_str
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let Ok(clsid) = (unsafe { CLSIDFromString(PCWSTR(clsid_w.as_ptr())) }) else {
                let _ = ack_tx.send(Err(BackendError::DriverError("Invalid ASIO CLSID".into())));
                return;
            };
            let Ok(raw_unk) = (unsafe { com_create_asio_instance(&clsid) }) else {
                let _ = ack_tx.send(Err(BackendError::DriverError(
                    "CoCreateInstance failed".into(),
                )));
                return;
            };
            let Some(nn) = NonNull::new(raw_unk as *mut *const IAsioVtbl) else {
                let _ = ack_tx.send(Err(BackendError::DriverError("Null ASIO object".into())));
                return;
            };
            let asio = ComAsioPtr(nn);

            if unsafe { (asio.vtbl().init)(asio.raw(), null_mut()) } != ASIO_TRUE {
                let err = unsafe { asio.driver_error() };
                let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                    "ASIO driver init failed (DAC disconnected?): {err}"
                ))));
                return;
            }

            if native_dsd {
                let mut fmt = AsioIoFormat {
                    format_type: K_ASIO_FORMAT_DSD,
                    future: [0; 508],
                };
                let rc = unsafe {
                    (asio.vtbl().future)(
                        asio.raw(),
                        K_ASIO_SET_IO_FORMAT,
                        &mut fmt as *mut AsioIoFormat as *mut c_void,
                    )
                };
                if rc != ASIO_SUCCESS && rc != ASIO_OK {
                    let _ = ack_tx.send(Err(BackendError::DriverError(
                        "ASIO driver rejected Native DSD IoFormat switch".into(),
                    )));
                    return;
                }
            } else {
                let mut fmt = AsioIoFormat {
                    format_type: K_ASIO_FORMAT_PCM,
                    future: [0; 508],
                };
                let _ = unsafe {
                    (asio.vtbl().future)(
                        asio.raw(),
                        K_ASIO_SET_IO_FORMAT,
                        &mut fmt as *mut AsioIoFormat as *mut c_void,
                    )
                };
            }

            if unsafe { (asio.vtbl().can_sample_rate)(asio.raw(), sample_rate as f64) } != ASIO_OK {
                let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                    "ASIO driver '{}' does not support exact sample rate {} Hz",
                    chosen.name, sample_rate
                ))));
                return;
            }
            if unsafe { (asio.vtbl().set_sample_rate)(asio.raw(), sample_rate as f64) } != ASIO_OK {
                let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                    "ASIO set_sample_rate({sample_rate}) failed"
                ))));
                return;
            }

            let (mut min_sz, mut max_sz, mut pref_sz, mut gran) = (0i32, 0i32, 0i32, 0i32);
            if unsafe {
                (asio.vtbl().get_buffer_size)(
                    asio.raw(),
                    &mut min_sz,
                    &mut max_sz,
                    &mut pref_sz,
                    &mut gran,
                )
            } != ASIO_OK
            {
                pref_sz = 512;
            }
            let buf_frames = pref_sz.clamp(min_sz.max(64), max_sz.max(64)) as usize;
            LAST_ASIO_BUFFER_FRAMES.store(buf_frames, Ordering::Relaxed);

            let ch = channels.max(1) as usize;
            let mut ch_info = AsioChannelInfo {
                channel: 0,
                is_input: 0,
                is_active: 0,
                channel_group: 0,
                sample_type: ASIO_ST_INT32_LSB,
                name: [0; 32],
            };
            let _ = unsafe { (asio.vtbl().get_channel_info)(asio.raw(), &mut ch_info) };

            let mut buffer_infos: Vec<AsioBufferInfo> = (0..ch)
                .map(|c| AsioBufferInfo {
                    is_input: 0,
                    channel_num: c as i32,
                    buffers: [null_mut(), null_mut()],
                })
                .collect();

            let mut callbacks = Box::new(AsioCallbacks {
                buffer_switch: asio_buffer_switch,
                sample_rate_did_change: asio_sample_rate_changed,
                asio_message,
                buffer_switch_time_info: asio_buffer_switch_time_info,
            });

            ASIO_MSG_RESET.store(false, Ordering::Release);
            ASIO_MSG_RESYNC.store(false, Ordering::Release);
            ASIO_MSG_LATENCIES_CHANGED.store(false, Ordering::Release);
            ASIO_MSG_BUFFER_SIZE.store(0, Ordering::Release);
            ASIO_MSG_SAMPLE_RATE_HZ.store(0, Ordering::Release);
            ASIO_MSG_SESSION_ID.store(session_id, Ordering::Release);

            if unsafe {
                (asio.vtbl().create_buffers)(
                    asio.raw(),
                    buffer_infos.as_mut_ptr(),
                    ch as i32,
                    buf_frames as i32,
                    callbacks.as_mut() as *mut AsioCallbacks,
                )
            } != ASIO_OK
            {
                let err = unsafe { asio.driver_error() };
                let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                    "ASIO createBuffers failed: {err}"
                ))));
                return;
            }

            let (mut in_lat, mut out_lat) = (0i32, 0i32);
            if unsafe { (asio.vtbl().get_latencies)(asio.raw(), &mut in_lat, &mut out_lat) }
                == ASIO_OK
                && out_lat > 0
            {
                th_signals
                    .output_latency_frames
                    .store(out_lat as u32, Ordering::Release);
            }

            let channel_buffers: Vec<[*mut u8; 2]> = buffer_infos
                .iter()
                .map(|bi| [bi.buffers[0] as *mut u8, bi.buffers[1] as *mut u8])
                .collect();

            let sta_fade_ctrl = fade_ctrl.clone();
            let core = AsioRenderCore::new(
                consumer,
                verification,
                frames_rendered,
                nonzero_frames,
                Arc::clone(&state_code),
                eof_flag,
                Arc::clone(&th_paused),
                Arc::clone(&th_stopped),
                Arc::clone(&current_session_id),
                session_id,
                Arc::clone(&th_signals),
                buf_frames,
                ch,
                sample_rate,
                ch_info.sample_type,
                wire,
            )
            .with_phase2_controls(startup_watermark_bytes, fade_ctrl, buffered_ms);

            let vtbl_raw = unsafe { *asio.0.as_ptr() } as usize;
            ACTIVE_ASIO_SESSION_ID.store(session_id, Ordering::SeqCst);
            clear_and_drop_active_asio_state();
            let boxed = Box::into_raw(Box::new(ActiveAsioCallbackState {
                asio_raw: asio.raw() as usize,
                vtbl_raw,
                _buffer_infos: buffer_infos,
                channel_buffers,
                core,
            }));
            ACTIVE_ASIO_PTR.store(boxed, Ordering::Release);

            if unsafe { (asio.vtbl().start)(asio.raw()) } != ASIO_OK {
                let err = unsafe { asio.driver_error() };
                let _ = ack_tx.send(Err(BackendError::DriverError(format!(
                    "ASIO start failed: {err}"
                ))));
                clear_and_drop_active_asio_state();
                let _ = unsafe { (asio.vtbl().dispose_buffers)(asio.raw()) };
                return;
            }

            let _ = ack_tx.send(Ok((chosen.name.clone(), buf_frames as u32)));

            let mut watchdog = AsioCallbackWatchdog::new(
                watchdog_timeout,
                th_signals.callback_count.load(Ordering::Relaxed),
            );

            while !th_stopped.load(Ordering::Acquire)
                && (current_session_id.load(Ordering::Relaxed) == session_id
                    || sta_fade_ctrl.as_ref().is_some_and(|fc| {
                        fc.target() == FadeTarget::StopFadeOut && !fc.is_fade_out_done()
                    }))
            {
                if ASIO_MSG_SESSION_ID.load(Ordering::Acquire) == session_id {
                    let drv_sr = ASIO_MSG_SAMPLE_RATE_HZ.load(Ordering::Acquire);
                    if drv_sr != 0 && drv_sr != sample_rate {
                        th_signals.on_sample_rate_changed(drv_sr as f64);
                    }
                    if ASIO_MSG_RESET.swap(false, Ordering::AcqRel) {
                        let req_buf = ASIO_MSG_BUFFER_SIZE.load(Ordering::Acquire);
                        th_signals
                            .requested_buffer_size
                            .store(req_buf, Ordering::Release);
                        th_signals.reset_requested.store(true, Ordering::Release);
                        th_signals.device_lost.store(true, Ordering::Release);
                        th_signals
                            .telemetry
                            .record_error_rt(RtErrorCode::DriverReset, req_buf);
                        if let Ok(mut g) = th_signals.last_error.write() {
                            *g = Some(if req_buf > 0 {
                                format!(
                                    "ASIO driver requested buffer/reset (buffer_size={req_buf})"
                                )
                            } else {
                                "ASIO driver requested reset (kAsioResetRequest)".to_string()
                            });
                        }
                        let cur_state = state_code.load(Ordering::Acquire);
                        if cur_state == 2 || cur_state == 3 {
                            let _ = state_code.compare_exchange(
                                cur_state,
                                4,
                                Ordering::SeqCst,
                                Ordering::SeqCst,
                            );
                        }
                        th_stopped.store(true, Ordering::Release);
                        break;
                    }
                    if ASIO_MSG_RESYNC.swap(false, Ordering::AcqRel) {
                        th_signals.resync_requested.store(true, Ordering::Release);
                        th_signals.resync_count.fetch_add(1, Ordering::Relaxed);
                        th_signals.request_flush();
                    }
                    if ASIO_MSG_LATENCIES_CHANGED.swap(false, Ordering::AcqRel) {
                        th_signals.latencies_changed.store(true, Ordering::Release);
                        let (mut new_in, mut new_out) = (0i32, 0i32);
                        if unsafe {
                            (asio.vtbl().get_latencies)(asio.raw(), &mut new_in, &mut new_out)
                        } == ASIO_OK
                            && new_out >= 0
                        {
                            th_signals
                                .output_latency_frames
                                .store(new_out as u32, Ordering::Release);
                        }
                    }
                }

                let watchdog_active = !th_paused.load(Ordering::Acquire)
                    && !th_stopped.load(Ordering::Acquire)
                    && !th_signals.eof_drained.load(Ordering::Acquire);
                if watchdog.check(
                    Instant::now(),
                    watchdog_active,
                    th_signals.callback_count.load(Ordering::Relaxed),
                ) {
                    th_signals.device_lost.store(true, Ordering::SeqCst);
                    th_signals
                        .telemetry
                        .record_error_rt(RtErrorCode::DeviceInvalidated, -1);
                    if let Ok(mut g) = th_signals.last_error.write() {
                        *g = Some("ASIO driver callback stalled / DAC disconnected".to_string());
                    }
                    let cur_state = state_code.load(Ordering::Acquire);
                    if cur_state == 2 || cur_state == 3 {
                        let _ = state_code.compare_exchange(
                            cur_state,
                            4,
                            Ordering::SeqCst,
                            Ordering::SeqCst,
                        );
                    }
                    th_stopped.store(true, Ordering::Release);
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }

            if th_signals.device_lost.load(Ordering::Acquire) {
                clear_and_drop_active_asio_state();
                let _ = unsafe { (asio.vtbl().stop)(asio.raw()) };
                let _ = unsafe { (asio.vtbl().dispose_buffers)(asio.raw()) };
            } else {
                let _ = unsafe { (asio.vtbl().stop)(asio.raw()) };
                clear_and_drop_active_asio_state();
                let _ = unsafe { (asio.vtbl().dispose_buffers)(asio.raw()) };
            }
        })
        .map_err(|e| BackendError::DriverError(format!("Spawn ASIO STA thread failed: {e}")))?;
    Ok(handle)
}
