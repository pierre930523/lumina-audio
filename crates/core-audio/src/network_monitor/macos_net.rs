use super::fingerprint::{NetworkFingerprint, is_vpn_interface_name};
use std::collections::BTreeSet;
use std::ffi::{CStr, c_char, c_int, c_void};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use tokio::sync::mpsc;

type CFTypeRef = *const c_void;
type CFAllocatorRef = *const c_void;
type CFStringRef = *const c_void;
type CFArrayRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFRunLoopRef = *const c_void;
type CFRunLoopSourceRef = *const c_void;
type SCDynamicStoreRef = *const c_void;

const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
const IFF_UP: u32 = 0x1;
const IFF_LOOPBACK: u32 = 0x8;
const AF_INET_MAC: u8 = 2;
const AF_INET6_MAC: u8 = 30;

#[repr(C)]
struct SCDynamicStoreContext {
    version: isize,
    info: *mut c_void,
    retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    release: Option<extern "C" fn(*const c_void)>,
    copy_description: Option<extern "C" fn(*const c_void) -> CFStringRef>,
}

#[repr(C)]
struct SockAddrMac {
    sa_len: u8,
    sa_family: u8,
    sa_data: [u8; 14],
}

#[repr(C)]
struct SockAddrInMac {
    sin_len: u8,
    sin_family: u8,
    sin_port: u16,
    sin_addr: [u8; 4],
    sin_zero: [u8; 8],
}

#[repr(C)]
struct SockAddrIn6Mac {
    sin6_len: u8,
    sin6_family: u8,
    sin6_port: u16,
    sin6_flowinfo: u32,
    sin6_addr: [u8; 16],
    sin6_scope_id: u32,
}

#[repr(C)]
struct IfAddrs {
    ifa_next: *mut IfAddrs,
    ifa_name: *mut c_char,
    ifa_flags: u32,
    ifa_addr: *mut SockAddrMac,
    ifa_netmask: *mut SockAddrMac,
    ifa_dstaddr: *mut SockAddrMac,
    ifa_data: *mut c_void,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopDefaultMode: CFStringRef;
    fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        c_str: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFStringGetCString(
        the_string: CFStringRef,
        buffer: *mut c_char,
        buffer_size: isize,
        encoding: u32,
    ) -> bool;
    fn CFArrayCreate(
        allocator: CFAllocatorRef,
        values: *const *const c_void,
        num_values: isize,
        callbacks: *const c_void,
    ) -> CFArrayRef;
    fn CFDictionaryGetValue(dict: CFDictionaryRef, key: *const c_void) -> *const c_void;
    fn CFRunLoopGetCurrent() -> CFRunLoopRef;
    fn CFRunLoopAddSource(rl: CFRunLoopRef, source: CFRunLoopSourceRef, mode: CFStringRef);
    fn CFRunLoopRun();
    fn CFRunLoopStop(rl: CFRunLoopRef);
    fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    fn CFRelease(cf: CFTypeRef);
}

#[link(name = "SystemConfiguration", kind = "framework")]
unsafe extern "C" {
    fn SCDynamicStoreCreate(
        allocator: CFAllocatorRef,
        name: CFStringRef,
        callout: Option<extern "C" fn(SCDynamicStoreRef, CFArrayRef, *mut c_void)>,
        context: *mut SCDynamicStoreContext,
    ) -> SCDynamicStoreRef;
    fn SCDynamicStoreSetNotificationKeys(
        store: SCDynamicStoreRef,
        keys: CFArrayRef,
        patterns: CFArrayRef,
    ) -> bool;
    fn SCDynamicStoreCreateRunLoopSource(
        allocator: CFAllocatorRef,
        store: SCDynamicStoreRef,
        order: isize,
    ) -> CFRunLoopSourceRef;
    fn SCDynamicStoreCopyValue(store: SCDynamicStoreRef, key: CFStringRef) -> CFTypeRef;
}

unsafe extern "C" {
    fn getifaddrs(ifap: *mut *mut IfAddrs) -> c_int;
    fn freeifaddrs(ifa: *mut IfAddrs);
}

extern "C" fn on_sc_change(
    _store: SCDynamicStoreRef,
    _changed_keys: CFArrayRef,
    info: *mut c_void,
) {
    if !info.is_null() {
        let tx = unsafe { &*(info as *const mpsc::UnboundedSender<()>) };
        let _ = tx.send(());
    }
}

pub(super) struct MacRouteListenerGuard {
    stop_flag: Arc<AtomicBool>,
    run_loop: Arc<std::sync::Mutex<Option<usize>>>,
    thread: Option<JoinHandle<()>>,
}

impl MacRouteListenerGuard {
    pub(super) fn start(tx: mpsc::UnboundedSender<()>) -> Result<Self, String> {
        let stop_flag = Arc::new(AtomicBool::new(false));
        let run_loop = Arc::new(std::sync::Mutex::new(None));
        let stop_clone = Arc::clone(&stop_flag);
        let rl_clone = Arc::clone(&run_loop);

        let handle = thread::Builder::new()
            .name("lumina-macos-netmon".to_string())
            .spawn(move || {
                let tx_box = Box::into_raw(Box::new(tx));
                unsafe {
                    let name = CFStringCreateWithCString(
                        std::ptr::null(),
                        c"lumina-network-monitor".as_ptr(),
                        K_CF_STRING_ENCODING_UTF8,
                    );
                    let mut ctx = SCDynamicStoreContext {
                        version: 0,
                        info: tx_box.cast::<c_void>(),
                        retain: None,
                        release: None,
                        copy_description: None,
                    };
                    let store =
                        SCDynamicStoreCreate(std::ptr::null(), name, Some(on_sc_change), &mut ctx);
                    if !name.is_null() {
                        CFRelease(name);
                    }
                    if !store.is_null() {
                        let k_v4 = CFStringCreateWithCString(
                            std::ptr::null(),
                            c"State:/Network/Global/IPv4".as_ptr(),
                            K_CF_STRING_ENCODING_UTF8,
                        );
                        let k_v6 = CFStringCreateWithCString(
                            std::ptr::null(),
                            c"State:/Network/Global/IPv6".as_ptr(),
                            K_CF_STRING_ENCODING_UTF8,
                        );
                        let p_if = CFStringCreateWithCString(
                            std::ptr::null(),
                            c"State:/Network/Interface/.*/IPv4".as_ptr(),
                            K_CF_STRING_ENCODING_UTF8,
                        );
                        let keys_raw = [k_v4, k_v6];
                        let pats_raw = [p_if];
                        let keys = CFArrayCreate(
                            std::ptr::null(),
                            keys_raw.as_ptr(),
                            keys_raw.len() as isize,
                            std::ptr::null(),
                        );
                        let pats = CFArrayCreate(
                            std::ptr::null(),
                            pats_raw.as_ptr(),
                            pats_raw.len() as isize,
                            std::ptr::null(),
                        );
                        SCDynamicStoreSetNotificationKeys(store, keys, pats);
                        let source = SCDynamicStoreCreateRunLoopSource(std::ptr::null(), store, 0);
                        if !source.is_null() {
                            let rl = CFRunLoopGetCurrent();
                            CFRetain(rl);
                            if let Ok(mut g) = rl_clone.lock() {
                                *g = Some(rl as usize);
                            }
                            if !stop_clone.load(Ordering::SeqCst) {
                                CFRunLoopAddSource(rl, source, kCFRunLoopDefaultMode);
                                CFRunLoopRun();
                            }
                            if let Ok(mut g) = rl_clone.lock() {
                                *g = None;
                            }
                            CFRelease(rl);
                            CFRelease(source);
                        }
                        if !keys.is_null() {
                            CFRelease(keys);
                        }
                        if !pats.is_null() {
                            CFRelease(pats);
                        }
                        if !k_v4.is_null() {
                            CFRelease(k_v4);
                        }
                        if !k_v6.is_null() {
                            CFRelease(k_v6);
                        }
                        if !p_if.is_null() {
                            CFRelease(p_if);
                        }
                        CFRelease(store);
                    }
                    drop(Box::from_raw(tx_box));
                }
            })
            .map_err(|e| format!("Failed to spawn macOS network monitor thread: {e}"))?;

        Ok(Self {
            stop_flag,
            run_loop,
            thread: Some(handle),
        })
    }
}

impl Drop for MacRouteListenerGuard {
    fn drop(&mut self) {
        self.stop_flag.store(true, Ordering::SeqCst);
        if let Ok(g) = self.run_loop.lock()
            && let Some(rl_addr) = *g
        {
            unsafe {
                CFRunLoopStop(rl_addr as CFRunLoopRef);
            }
        }
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

fn primary_interface_from_sc() -> Option<String> {
    unsafe {
        let name = CFStringCreateWithCString(
            std::ptr::null(),
            c"lumina-network-snapshot".as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );
        let store = SCDynamicStoreCreate(std::ptr::null(), name, None, std::ptr::null_mut());
        if !name.is_null() {
            CFRelease(name);
        }
        if store.is_null() {
            return None;
        }
        let mut result = None;
        for key_cstr in [c"State:/Network/Global/IPv4", c"State:/Network/Global/IPv6"] {
            let key = CFStringCreateWithCString(
                std::ptr::null(),
                key_cstr.as_ptr(),
                K_CF_STRING_ENCODING_UTF8,
            );
            let dict = SCDynamicStoreCopyValue(store, key);
            if !key.is_null() {
                CFRelease(key);
            }
            if !dict.is_null() {
                let pi_key = CFStringCreateWithCString(
                    std::ptr::null(),
                    c"PrimaryInterface".as_ptr(),
                    K_CF_STRING_ENCODING_UTF8,
                );
                let val = CFDictionaryGetValue(dict, pi_key);
                if !pi_key.is_null() {
                    CFRelease(pi_key);
                }
                if !val.is_null() {
                    let mut buf = [0u8; 128];
                    if CFStringGetCString(
                        val,
                        buf.as_mut_ptr().cast::<c_char>(),
                        buf.len() as isize,
                        K_CF_STRING_ENCODING_UTF8,
                    ) {
                        if let Ok(s) = CStr::from_ptr(buf.as_ptr().cast::<c_char>()).to_str()
                            && !s.is_empty()
                        {
                            result = Some(s.to_string());
                        }
                    }
                }
                CFRelease(dict);
                if result.is_some() {
                    break;
                }
            }
        }
        CFRelease(store);
        result
    }
}

fn is_link_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_link_local() || v4.is_loopback() || v4.is_unspecified(),
        IpAddr::V6(v6) => {
            v6.is_loopback() || v6.is_unspecified() || (v6.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

pub(super) fn snapshot_fingerprint() -> NetworkFingerprint {
    let default_route_if = primary_interface_from_sc();
    let mut primary_v4: Option<IpAddr> = None;
    let mut primary_v6: Option<IpAddr> = None;
    let mut vpn_interfaces = BTreeSet::new();

    unsafe {
        let mut ifap: *mut IfAddrs = std::ptr::null_mut();
        if getifaddrs(&mut ifap) == 0 && !ifap.is_null() {
            let mut cur = ifap;
            while !cur.is_null() {
                let ifa = &*cur;
                cur = ifa.ifa_next;

                if (ifa.ifa_flags & IFF_UP) == 0
                    || (ifa.ifa_flags & IFF_LOOPBACK) != 0
                    || ifa.ifa_name.is_null()
                    || ifa.ifa_addr.is_null()
                {
                    continue;
                }

                let Ok(if_name) = CStr::from_ptr(ifa.ifa_name).to_str() else {
                    continue;
                };
                let family = (*ifa.ifa_addr).sa_family;
                let ip = if family == AF_INET_MAC {
                    let sin = &*(ifa.ifa_addr.cast::<SockAddrInMac>());
                    Some(IpAddr::V4(Ipv4Addr::from(sin.sin_addr)))
                } else if family == AF_INET6_MAC {
                    let sin6 = &*(ifa.ifa_addr.cast::<SockAddrIn6Mac>());
                    Some(IpAddr::V6(Ipv6Addr::from(sin6.sin6_addr)))
                } else {
                    None
                };

                if let Some(addr) = ip
                    && !is_link_local(addr)
                {
                    if default_route_if.as_deref() == Some(if_name) {
                        match addr {
                            IpAddr::V4(_) if primary_v4.is_none() => primary_v4 = Some(addr),
                            IpAddr::V6(_) if primary_v6.is_none() => primary_v6 = Some(addr),
                            _ => {}
                        }
                    }
                    if is_vpn_interface_name(if_name) {
                        vpn_interfaces.insert(if_name.to_string());
                    }
                }
            }
            freeifaddrs(ifap);
        }
    }

    NetworkFingerprint {
        default_route_if,
        primary_local_ip: primary_v4.or(primary_v6),
        vpn_interfaces,
    }
}
