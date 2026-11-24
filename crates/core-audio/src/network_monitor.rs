use std::collections::BTreeSet;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::streaming::{
    StreamError, broadcast_network_epoch, increment_network_epoch_atomic, reset_shared_http_client,
    streaming_runtime,
};

/// Default quiet-window debounce duration (700 ms, within the 600–800 ms target) for collapsing
/// OS route/DHCP/VPN churn into a single fingerprint evaluation.
pub const DEFAULT_DEBOUNCE_DURATION: Duration = Duration::from_millis(700);

/// Providers whose L1 cached URLs are IP/session-bound and must be invalidated on `network_epoch` change.
pub const NETWORK_EPOCH_RESET_PROVIDERS: &[&str] = &["youtube_music"];

/// Platform-agnostic snapshot of active routing and VPN state used to filter out no-op OS network
/// notifications (e.g. DHCP lease renewals that keep the exact same interface, IP, and VPN set).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NetworkFingerprint {
    pub default_route_if: Option<String>,
    pub primary_local_ip: Option<IpAddr>,
    pub vpn_interfaces: BTreeSet<String>,
}

/// Injectable provider producing a [`NetworkFingerprint`] snapshot (real OS implementation in
/// production, deterministic mock in unit tests).
pub trait FingerprintProvider: Send + Sync {
    fn snapshot(&self) -> NetworkFingerprint;
}

/// Low-priority background hook invoked during Step 2 of the network-change cascade to prune stale
/// SQLite L1 entries belonging to providers with `needs_network_epoch_reset == true`.
pub type L1PruneHook = Arc<dyn Fn(&[&str], u64) + Send + Sync>;

/// Notification listener invoked during Step 4 of the network-change cascade with the newly
/// incremented `network_epoch`.
pub type EpochListener = Arc<dyn Fn(u64) + Send + Sync>;

/// Configuration for [`NetworkMonitor`].
#[derive(Clone)]
pub struct NetworkMonitorConfig {
    pub debounce: Duration,
    pub on_l1_prune: Option<L1PruneHook>,
    pub on_epoch_changed: Option<EpochListener>,
    pub reset_http_pools: bool,
}

impl Default for NetworkMonitorConfig {
    fn default() -> Self {
        Self {
            debounce: DEFAULT_DEBOUNCE_DURATION,
            on_l1_prune: None,
            on_epoch_changed: None,
            reset_http_pools: true,
        }
    }
}

/// Returns `true` when an interface name or description indicates a VPN / tunnel adapter.
pub fn is_vpn_interface_name(name_or_desc: &str) -> bool {
    let lower = name_or_desc.trim().to_ascii_lowercase();
    if lower.is_empty() {
        return false;
    }
    lower.starts_with("utun")
        || lower.starts_with("ipsec")
        || lower.starts_with("ppp")
        || lower.starts_with("wg")
        || lower.starts_with("tun")
        || lower.starts_with("tap")
        || lower.contains("vpn")
        || lower.contains("wireguard")
        || lower.contains("wintun")
        || lower.contains("tailscale")
        || lower.contains("openvpn")
        || lower.contains("clash")
        || lower.contains("sing-box")
        || lower.contains("zerotier")
        || lower.contains("nordlynx")
        || lower.contains("mullvad")
        || lower.contains("tap-windows")
}

/// Cross-platform OS network change monitor with 600–800 ms debouncing, fingerprint diffing,
/// and 4-step cascade execution on real network/VPN transitions.
pub struct NetworkMonitor {
    cancel: CancellationToken,
    trigger_tx: mpsc::UnboundedSender<()>,
    last_fingerprint: Arc<Mutex<NetworkFingerprint>>,
    _os_guard: Option<OsRouteListenerGuard>,
}

impl NetworkMonitor {
    /// Starts the production OS network monitor (Win32 IP Helper on Windows, `SCDynamicStore` /
    /// `Network.framework` on macOS) on `STREAMING_RUNTIME`.
    pub fn start_system(config: NetworkMonitorConfig) -> Result<Self, StreamError> {
        let provider: Arc<dyn FingerprintProvider> = Arc::new(SystemFingerprintProvider);
        let (trigger_tx, trigger_rx) = mpsc::unbounded_channel();
        let os_guard = match OsRouteListenerGuard::start(trigger_tx.clone()) {
            Ok(g) => Some(g),
            Err(err) => {
                tracing::warn!("OS network route listener unavailable: {err}");
                None
            }
        };
        Self::spawn_debouncer(provider, config, trigger_tx, trigger_rx, os_guard)
    }

    /// Starts a [`NetworkMonitor`] backed by a custom [`FingerprintProvider`] without registering
    /// OS listeners. Call [`notify_raw_event`](Self::notify_raw_event) to drive debouncing in tests.
    pub fn start_with_provider(
        provider: Arc<dyn FingerprintProvider>,
        config: NetworkMonitorConfig,
    ) -> Result<Self, StreamError> {
        let (trigger_tx, trigger_rx) = mpsc::unbounded_channel();
        Self::spawn_debouncer(provider, config, trigger_tx, trigger_rx, None)
    }

    fn spawn_debouncer(
        provider: Arc<dyn FingerprintProvider>,
        config: NetworkMonitorConfig,
        trigger_tx: mpsc::UnboundedSender<()>,
        mut trigger_rx: mpsc::UnboundedReceiver<()>,
        os_guard: Option<OsRouteListenerGuard>,
    ) -> Result<Self, StreamError> {
        let rt = streaming_runtime()?;
        let initial_fp = provider.snapshot();
        let last_fingerprint = Arc::new(Mutex::new(initial_fp));
        let cancel = CancellationToken::new();

        let task_cancel = cancel.clone();
        let task_fp = Arc::clone(&last_fingerprint);
        let debounce = config.debounce;

        rt.spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = task_cancel.cancelled() => break,
                    maybe_evt = trigger_rx.recv() => {
                        if maybe_evt.is_none() {
                            break;
                        }
                    }
                }

                // Quiet-window debounce: reset timer whenever additional raw OS events arrive.
                let sleep = tokio::time::sleep(debounce);
                tokio::pin!(sleep);
                loop {
                    tokio::select! {
                        biased;
                        _ = task_cancel.cancelled() => return,
                        _ = &mut sleep => break,
                        maybe_evt = trigger_rx.recv() => {
                            match maybe_evt {
                                Some(()) => {
                                    sleep.as_mut().reset(tokio::time::Instant::now() + debounce);
                                }
                                None => return,
                            }
                        }
                    }
                }

                // Snapshot current OS fingerprint off the Tokio worker thread to avoid stalling I/O.
                let provider_clone = Arc::clone(&provider);
                let new_fp = match tokio::task::spawn_blocking(move || provider_clone.snapshot()).await {
                    Ok(fp) => fp,
                    Err(_) => continue,
                };
                if task_cancel.is_cancelled() {
                    return;
                }

                let changed = {
                    let Ok(mut guard) = task_fp.lock() else {
                        continue;
                    };
                    if *guard == new_fp {
                        false
                    } else {
                        *guard = new_fp;
                        true
                    }
                };

                if changed {
                    execute_network_change_cascade(&config);
                }
            }
        });

        Ok(Self {
            cancel,
            trigger_tx,
            last_fingerprint,
            _os_guard: os_guard,
        })
    }

    /// Injects a raw network-change trigger into the debouncer (used by OS hooks and tests).
    pub fn notify_raw_event(&self) {
        let _ = self.trigger_tx.send(());
    }

    /// Returns the last committed [`NetworkFingerprint`].
    pub fn current_fingerprint(&self) -> NetworkFingerprint {
        self.last_fingerprint
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    /// Stops the background debouncer task and cancels any active OS notifications.
    pub fn stop(&self) {
        self.cancel.cancel();
    }
}

impl Drop for NetworkMonitor {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

/// Executes the 4-step cascade when a real network fingerprint change is confirmed:
/// 1. Atomically increment global `network_epoch` (immediate O(1) logical invalidation).
/// 2. Trigger low-priority background SQLite L1 prune for `needs_network_epoch_reset` providers.
/// 3. Drop and rebuild Rust HTTP Keep-Alive connection pools.
/// 4. Broadcast `network_epoch` to wake active Rust proxies onto the freshly rebuilt HTTP pools
///    and notify external epoch listeners (e.g. Dart FFI callback for YTM PO Token refresh).
pub fn execute_network_change_cascade(config: &NetworkMonitorConfig) -> u64 {
    // Step 1: Atomic increment global network_epoch (immediate O(1) logical invalidation)
    let new_epoch = increment_network_epoch_atomic();
    tracing::info!("Network fingerprint changed -> network_epoch={new_epoch}");

    // Step 2: Background L1 prune for IP-bound providers (e.g. youtube_music)
    if let Some(ref prune_hook) = config.on_l1_prune {
        prune_hook(NETWORK_EPOCH_RESET_PROVIDERS, new_epoch);
    }

    // Step 3: Drop & rebuild HTTP Keep-Alive connection pools BEFORE waking active proxies
    if config.reset_http_pools {
        if let Err(e) = reset_shared_http_client() {
            tracing::warn!("Failed to rebuild shared streaming HTTP client: {e}");
        }
        crate::stream::reset_http_client();
    }

    // Step 4: Wake active Rust proxies (so retries hit the rebuilt pool) & notify Dart listeners
    broadcast_network_epoch(new_epoch);
    if let Some(ref listener) = config.on_epoch_changed {
        listener(new_epoch);
    }

    new_epoch
}

struct SystemFingerprintProvider;

impl FingerprintProvider for SystemFingerprintProvider {
    fn snapshot(&self) -> NetworkFingerprint {
        #[cfg(target_os = "windows")]
        {
            win_net::snapshot_fingerprint()
        }
        #[cfg(target_os = "macos")]
        {
            macos_net::snapshot_fingerprint()
        }
        #[cfg(not(any(target_os = "windows", target_os = "macos")))]
        {
            NetworkFingerprint::default()
        }
    }
}

#[cfg(target_os = "windows")]
type OsRouteListenerGuard = win_net::WinRouteListenerGuard;

#[cfg(target_os = "macos")]
type OsRouteListenerGuard = macos_net::MacRouteListenerGuard;

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
struct OsRouteListenerGuard;

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
impl OsRouteListenerGuard {
    fn start(_tx: mpsc::UnboundedSender<()>) -> Result<Self, String> {
        Ok(Self)
    }
}

#[cfg(target_os = "windows")]
mod win_net {
    use super::{NetworkFingerprint, is_vpn_interface_name};
    use std::collections::BTreeSet;
    use std::ffi::c_void;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
    use tokio::sync::mpsc;
    use windows::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, HANDLE, NO_ERROR};
    use windows::Win32::NetworkManagement::IpHelper::{
        CancelMibChangeNotify2, FreeMibTable, GAA_FLAG_INCLUDE_GATEWAYS, GetAdaptersAddresses,
        GetIpForwardTable2, IF_TYPE_PPP, IF_TYPE_PROP_VIRTUAL, IF_TYPE_SOFTWARE_LOOPBACK,
        IF_TYPE_TUNNEL, IP_ADAPTER_ADDRESSES_LH, MIB_IPFORWARD_ROW2, MIB_IPFORWARD_TABLE2,
        MIB_NOTIFICATION_TYPE, MIB_UNICASTIPADDRESS_ROW, NotifyRouteChange2,
        NotifyUnicastIpAddressChange,
    };
    use windows::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    use windows::Win32::Networking::WinSock::{
        AF_INET, AF_INET6, AF_UNSPEC, SOCKADDR_IN, SOCKADDR_IN6,
    };

    struct CallbackContext {
        tx: mpsc::UnboundedSender<()>,
    }

    unsafe extern "system" fn on_route_change(
        caller_context: *const c_void,
        _row: *const MIB_IPFORWARD_ROW2,
        _notification_type: MIB_NOTIFICATION_TYPE,
    ) {
        if !caller_context.is_null() {
            let ctx = unsafe { &*(caller_context as *const CallbackContext) };
            let _ = ctx.tx.send(());
        }
    }

    unsafe extern "system" fn on_unicast_change(
        caller_context: *const c_void,
        _row: *const MIB_UNICASTIPADDRESS_ROW,
        _notification_type: MIB_NOTIFICATION_TYPE,
    ) {
        if !caller_context.is_null() {
            let ctx = unsafe { &*(caller_context as *const CallbackContext) };
            let _ = ctx.tx.send(());
        }
    }

    pub(super) struct WinRouteListenerGuard {
        route_handle: HANDLE,
        unicast_handle: HANDLE,
        ctx_ptr: *mut CallbackContext,
    }

    // SAFETY: Win32 MIB notification handles are process-wide kernel handles cancelled in Drop.
    unsafe impl Send for WinRouteListenerGuard {}
    unsafe impl Sync for WinRouteListenerGuard {}

    impl WinRouteListenerGuard {
        pub(super) fn start(tx: mpsc::UnboundedSender<()>) -> Result<Self, String> {
            let ctx_ptr = Box::into_raw(Box::new(CallbackContext { tx }));
            let mut route_handle = HANDLE::default();
            let mut unicast_handle = HANDLE::default();

            unsafe {
                let rc_route = NotifyRouteChange2(
                    AF_UNSPEC,
                    Some(on_route_change),
                    ctx_ptr.cast::<c_void>(),
                    false,
                    &mut route_handle,
                );
                if rc_route != NO_ERROR {
                    drop(Box::from_raw(ctx_ptr));
                    return Err(format!("NotifyRouteChange2 failed: {rc_route:?}"));
                }

                let rc_unicast = NotifyUnicastIpAddressChange(
                    AF_UNSPEC,
                    Some(on_unicast_change),
                    Some(ctx_ptr.cast::<c_void>()),
                    false,
                    &mut unicast_handle,
                );
                if rc_unicast != NO_ERROR {
                    let _ = CancelMibChangeNotify2(route_handle);
                    drop(Box::from_raw(ctx_ptr));
                    return Err(format!("NotifyUnicastIpAddressChange failed: {rc_unicast:?}"));
                }
            }

            Ok(Self {
                route_handle,
                unicast_handle,
                ctx_ptr,
            })
        }
    }

    impl Drop for WinRouteListenerGuard {
        fn drop(&mut self) {
            unsafe {
                // Cancel both notifications FIRST; CancelMibChangeNotify2 blocks until any
                // active OS callback exits, making subsequent Box::from_raw sound.
                if !self.route_handle.is_invalid() && !self.route_handle.0.is_null() {
                    let _ = CancelMibChangeNotify2(self.route_handle);
                }
                if !self.unicast_handle.is_invalid() && !self.unicast_handle.0.is_null() {
                    let _ = CancelMibChangeNotify2(self.unicast_handle);
                }
                if !self.ctx_ptr.is_null() {
                    drop(Box::from_raw(self.ctx_ptr));
                    self.ctx_ptr = std::ptr::null_mut();
                }
            }
        }
    }

    fn default_route_interface_index() -> Option<u32> {
        let mut table_ptr: *mut MIB_IPFORWARD_TABLE2 = std::ptr::null_mut();
        unsafe {
            if GetIpForwardTable2(AF_UNSPEC, &mut table_ptr) != NO_ERROR || table_ptr.is_null() {
                return None;
            }
            let num_entries = (*table_ptr).NumEntries as usize;
            let rows = std::slice::from_raw_parts((*table_ptr).Table.as_ptr(), num_entries);

            let mut best_v4: Option<(u32, u32)> = None;
            let mut best_v6: Option<(u32, u32)> = None;

            for row in rows {
                if row.DestinationPrefix.PrefixLength != 0 {
                    continue;
                }
                let family = row.DestinationPrefix.Prefix.si_family;
                let metric = row.Metric;
                let if_idx = row.InterfaceIndex;
                if family == AF_INET {
                    if best_v4.is_none_or(|(m, _)| metric < m) {
                        best_v4 = Some((metric, if_idx));
                    }
                } else if family == AF_INET6 && best_v6.is_none_or(|(m, _)| metric < m) {
                    best_v6 = Some((metric, if_idx));
                }
            }

            FreeMibTable(table_ptr.cast::<c_void>());
            best_v4.or(best_v6).map(|(_, idx)| idx)
        }
    }

    fn pwstr_to_string(ptr: *const u16) -> String {
        if ptr.is_null() {
            return String::new();
        }
        unsafe {
            let mut len = 0usize;
            while *ptr.add(len) != 0 && len < 512 {
                len += 1;
            }
            String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len))
        }
    }

    fn is_link_local(ip: IpAddr) -> bool {
        match ip {
            IpAddr::V4(v4) => v4.is_link_local() || v4.is_loopback() || v4.is_unspecified(),
            IpAddr::V6(v6) => {
                v6.is_loopback()
                    || v6.is_unspecified()
                    || (v6.segments()[0] & 0xffc0) == 0xfe80
            }
        }
    }

    pub(super) fn snapshot_fingerprint() -> NetworkFingerprint {
        let default_if_idx = default_route_interface_index();
        let mut buf_len: u32 = 16 * 1024;
        let mut buffer = vec![0u8; buf_len as usize];

        let rc = unsafe {
            let mut ret = GetAdaptersAddresses(
                AF_UNSPEC.0 as u32,
                GAA_FLAG_INCLUDE_GATEWAYS,
                None,
                Some(buffer.as_mut_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>()),
                &mut buf_len,
            );
            if ret == ERROR_BUFFER_OVERFLOW.0 {
                buffer.resize(buf_len as usize, 0);
                ret = GetAdaptersAddresses(
                    AF_UNSPEC.0 as u32,
                    GAA_FLAG_INCLUDE_GATEWAYS,
                    None,
                    Some(buffer.as_mut_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>()),
                    &mut buf_len,
                );
            }
            ret
        };

        if rc != NO_ERROR.0 {
            return NetworkFingerprint {
                default_route_if: default_if_idx.map(|i| format!("if-{i}")),
                primary_local_ip: None,
                vpn_interfaces: BTreeSet::new(),
            };
        }

        let mut default_route_if = default_if_idx.map(|i| format!("if-{i}"));
        let mut primary_local_ip: Option<IpAddr> = None;
        let mut vpn_interfaces = BTreeSet::new();

        unsafe {
            let mut cur = buffer.as_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
            while !cur.is_null() {
                let adapter = &*cur;
                cur = adapter.Next;

                if adapter.IfType == IF_TYPE_SOFTWARE_LOOPBACK
                    || adapter.OperStatus != IfOperStatusUp
                {
                    continue;
                }

                let if_index = adapter.Anonymous1.Anonymous.IfIndex;
                let ipv6_if_index = adapter.Ipv6IfIndex;
                let friendly = pwstr_to_string(adapter.FriendlyName.0);
                let desc = pwstr_to_string(adapter.Description.0);

                // Extract unicast IPs on this adapter
                let mut best_v4: Option<IpAddr> = None;
                let mut best_v6: Option<IpAddr> = None;
                let mut has_usable_ip = false;
                let mut uni = adapter.FirstUnicastAddress;
                while !uni.is_null() {
                    let ua = &*uni;
                    uni = ua.Next;
                    let sa = ua.Address.lpSockaddr;
                    if sa.is_null() {
                        continue;
                    }
                    let family = (*sa).sa_family;
                    let ip = if family == AF_INET {
                        let sin = &*(sa.cast::<SOCKADDR_IN>());
                        let octets = sin.sin_addr.S_un.S_addr.to_ne_bytes();
                        Some(IpAddr::V4(Ipv4Addr::from(octets)))
                    } else if family == AF_INET6 {
                        let sin6 = &*(sa.cast::<SOCKADDR_IN6>());
                        let octets = sin6.sin6_addr.u.Byte;
                        Some(IpAddr::V6(Ipv6Addr::from(octets)))
                    } else {
                        None
                    };

                    if let Some(addr) = ip
                        && !is_link_local(addr)
                    {
                        has_usable_ip = true;
                        match addr {
                            IpAddr::V4(_) if best_v4.is_none() => best_v4 = Some(addr),
                            IpAddr::V6(_) if best_v6.is_none() => best_v6 = Some(addr),
                            _ => {}
                        }
                    }
                }

                let is_default_adapter = default_if_idx
                    .is_some_and(|idx| idx == if_index || (ipv6_if_index != 0 && idx == ipv6_if_index));
                if is_default_adapter {
                    let label = if friendly.is_empty() {
                        format!("if-{if_index}")
                    } else {
                        format!("{if_index}:{friendly}")
                    };
                    default_route_if = Some(label);
                    primary_local_ip = best_v4.or(best_v6);
                }

                let is_tunnel_type = matches!(
                    adapter.IfType,
                    IF_TYPE_TUNNEL | IF_TYPE_PPP | IF_TYPE_PROP_VIRTUAL
                );
                if has_usable_ip
                    && (is_tunnel_type
                        || is_vpn_interface_name(&friendly)
                        || is_vpn_interface_name(&desc))
                {
                    let vpn_id = if friendly.is_empty() {
                        format!("vpn-{if_index}")
                    } else {
                        friendly
                    };
                    vpn_interfaces.insert(vpn_id);
                }
            }
        }

        NetworkFingerprint {
            default_route_if,
            primary_local_ip,
            vpn_interfaces,
        }
    }
}

#[cfg(target_os = "macos")]
mod macos_net {
    use super::{NetworkFingerprint, is_vpn_interface_name};
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

    extern "C" fn on_sc_change(_store: SCDynamicStoreRef, _changed_keys: CFArrayRef, info: *mut c_void) {
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
                        let store = SCDynamicStoreCreate(
                            std::ptr::null(),
                            name,
                            Some(on_sc_change),
                            &mut ctx,
                        );
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
                v6.is_loopback()
                    || v6.is_unspecified()
                    || (v6.segments()[0] & 0xffc0) == 0xfe80
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
}
