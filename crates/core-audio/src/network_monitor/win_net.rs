use super::fingerprint::{NetworkFingerprint, is_vpn_interface_name};
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
                return Err(format!(
                    "NotifyUnicastIpAddressChange failed: {rc_unicast:?}"
                ));
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
            v6.is_loopback() || v6.is_unspecified() || (v6.segments()[0] & 0xffc0) == 0xfe80
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

            if adapter.IfType == IF_TYPE_SOFTWARE_LOOPBACK || adapter.OperStatus != IfOperStatusUp {
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
