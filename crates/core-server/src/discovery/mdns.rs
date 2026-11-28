use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::{info, warn};

pub const MDNS_SERVICE_TYPE: &str = "_lumina._tcp.local.";
pub const MDNS_DEFAULT_PORT: u16 = 9888;
pub const MDNS_MULTICAST_IPV4: &str = "224.0.0.251";
pub const MDNS_PORT: u16 = 5353;

#[derive(Debug, Clone)]
pub struct MdnsConfig {
    pub service_type: String,
    pub port: u16,
    pub hostname: String,
    pub txt_records: HashMap<String, String>,
}

impl Default for MdnsConfig {
    fn default() -> Self {
        let mut txt = HashMap::new();
        txt.insert("server_name".to_string(), "Lumina-Desktop".to_string());
        txt.insert("version".to_string(), "0.1.0".to_string());
        txt.insert("api_version".to_string(), "1".to_string());
        txt.insert("pairing_required".to_string(), "true".to_string());

        Self {
            service_type: MDNS_SERVICE_TYPE.to_string(),
            port: MDNS_DEFAULT_PORT,
            hostname: "Lumina-Server".to_string(),
            txt_records: txt,
        }
    }
}

impl MdnsConfig {
    pub fn instance_name(&self) -> String {
        format!("{}.{}", self.hostname, self.service_type)
    }

    pub fn host_fqdn(&self) -> String {
        format!("{}.local.", self.hostname)
    }

    /// Validates DNS-SD TXT entry constraints:
    /// key + '=' + value <= 255 bytes per attribute
    pub fn validate_txt_records(&self) -> bool {
        for (k, v) in &self.txt_records {
            if k.is_empty() || (k.len() + 1 + v.len()) > 255 {
                return false;
            }
        }
        true
    }

    /// Strict RFC 6763 recommendation helper (key <= 9 bytes, value <= 255 bytes)
    pub fn validate_strict_txt_entry(key: &str, val: &str) -> bool {
        key.len() <= 9 && val.len() <= 255
    }

    /// Builds an RFC 6762 / RFC 6763 DNS-SD response packet (`0x8400`, ANCOUNT=4: PTR, SRV, TXT, A).
    pub fn build_announcement_packet(&self, ipv4: Ipv4Addr) -> Vec<u8> {
        let mut pkt = Vec::with_capacity(256);

        // Header: ID=0, Flags=0x8400 (QR=1, AA=1), QD=0, AN=4, NS=0, AR=0
        pkt.extend_from_slice(&0u16.to_be_bytes());
        pkt.extend_from_slice(&0x8400u16.to_be_bytes());
        pkt.extend_from_slice(&0u16.to_be_bytes());
        pkt.extend_from_slice(&4u16.to_be_bytes());
        pkt.extend_from_slice(&0u16.to_be_bytes());
        pkt.extend_from_slice(&0u16.to_be_bytes());

        let service_type = self.service_type.trim();
        let instance_name = self.instance_name();
        let host_fqdn = self.host_fqdn();
        let ttl: u32 = 120;

        // 1. PTR record: _lumina._tcp.local. -> <instance>
        let mut ptr_rdata = Vec::new();
        encode_dns_name(&mut ptr_rdata, &instance_name);
        push_rr(&mut pkt, service_type, 12, 0x0001, ttl, &ptr_rdata);

        // 2. SRV record: <instance> -> host_fqdn:port
        let mut srv_rdata = Vec::new();
        srv_rdata.extend_from_slice(&0u16.to_be_bytes()); // priority
        srv_rdata.extend_from_slice(&0u16.to_be_bytes()); // weight
        srv_rdata.extend_from_slice(&self.port.to_be_bytes());
        encode_dns_name(&mut srv_rdata, &host_fqdn);
        push_rr(&mut pkt, &instance_name, 33, 0x8001, ttl, &srv_rdata);

        // 3. TXT record: <instance>
        let mut txt_rdata = Vec::new();
        let mut sorted_keys: Vec<&String> = self.txt_records.keys().collect();
        sorted_keys.sort();
        for key in sorted_keys {
            if let Some(val) = self.txt_records.get(key) {
                let entry = format!("{}={}", key, val);
                let bytes = entry.as_bytes();
                let len = bytes.len().min(255);
                txt_rdata.push(len as u8);
                txt_rdata.extend_from_slice(&bytes[..len]);
            }
        }
        if txt_rdata.is_empty() {
            txt_rdata.push(0);
        }
        push_rr(&mut pkt, &instance_name, 16, 0x8001, ttl, &txt_rdata);

        // 4. A record: <hostname>.local. -> ipv4
        push_rr(&mut pkt, &host_fqdn, 1, 0x8001, ttl, &ipv4.octets());

        pkt
    }
}

fn encode_dns_name(buf: &mut Vec<u8>, name: &str) {
    for label in name.trim_end_matches('.').split('.') {
        if !label.is_empty() {
            let bytes = label.as_bytes();
            let len = bytes.len().min(63);
            buf.push(len as u8);
            buf.extend_from_slice(&bytes[..len]);
        }
    }
    buf.push(0);
}

fn push_rr(buf: &mut Vec<u8>, name: &str, rr_type: u16, class: u16, ttl: u32, rdata: &[u8]) {
    encode_dns_name(buf, name);
    buf.extend_from_slice(&rr_type.to_be_bytes());
    buf.extend_from_slice(&class.to_be_bytes());
    buf.extend_from_slice(&ttl.to_be_bytes());
    buf.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
    buf.extend_from_slice(rdata);
}

fn detect_local_ipv4() -> Ipv4Addr {
    if let Ok(sock) = std::net::UdpSocket::bind("0.0.0.0:0")
        && sock.connect("8.8.8.8:80").is_ok()
        && let Ok(SocketAddr::V4(addr)) = sock.local_addr()
        && !addr.ip().is_loopback()
    {
        return *addr.ip();
    }
    Ipv4Addr::LOCALHOST
}

pub struct MdnsService {
    config: MdnsConfig,
    running: Arc<RwLock<bool>>,
}

impl MdnsService {
    pub fn new(config: MdnsConfig) -> Self {
        Self {
            config,
            running: Arc::new(RwLock::new(false)),
        }
    }

    pub async fn start(&self) {
        let mut running = self.running.write().await;
        if *running {
            return;
        }
        *running = true;

        info!(
            "mDNS service discovery registered: {} on port {}",
            self.config.instance_name(),
            self.config.port
        );

        let running_clone = self.running.clone();
        let cfg = self.config.clone();

        tokio::spawn(async move {
            let bind_addr: SocketAddr = format!("0.0.0.0:{}", MDNS_PORT).parse().unwrap();
            let socket = match tokio::net::UdpSocket::bind(bind_addr).await {
                Ok(s) => {
                    let mcast_ip: Ipv4Addr = MDNS_MULTICAST_IPV4.parse().unwrap();
                    let _ = s.join_multicast_v4(mcast_ip, Ipv4Addr::UNSPECIFIED);
                    Some(s)
                }
                Err(e) => {
                    warn!(
                        "mDNS UDP 5353 bind not permitted ({}), running in virtual discovery mode",
                        e
                    );
                    None
                }
            };

            let mcast_target = SocketAddr::V4(SocketAddrV4::new(
                MDNS_MULTICAST_IPV4.parse().unwrap(),
                MDNS_PORT,
            ));
            let packet = cfg.build_announcement_packet(detect_local_ipv4());

            if let Some(ref sock) = socket {
                let _ = sock.send_to(&packet, mcast_target).await;
            }

            let mut recv_buf = [0u8; 1500];
            let mut ticks = 0u32;

            while *running_clone.read().await {
                if let Some(ref sock) = socket {
                    let recv_fut = sock.recv_from(&mut recv_buf);
                    if let Ok(Ok((len, _peer))) =
                        tokio::time::timeout(tokio::time::Duration::from_secs(1), recv_fut).await
                    {
                        let slice = &recv_buf[..len];
                        if slice.windows(7).any(|w| w.eq_ignore_ascii_case(b"_lumina")) {
                            let _ = sock.send_to(&packet, mcast_target).await;
                        }
                    }
                    ticks += 1;
                    if ticks.is_multiple_of(15) {
                        let _ = sock.send_to(&packet, mcast_target).await;
                    }
                } else {
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                }
            }
            info!("mDNS service on port {} stopped cleanly", cfg.port);
        });
    }

    pub async fn stop(&self) {
        let mut running = self.running.write().await;
        *running = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mdns_defaults_and_contracts() {
        let cfg = MdnsConfig::default();
        assert_eq!(cfg.service_type, "_lumina._tcp.local.");
        assert_eq!(cfg.port, 9888);
        assert_eq!(
            cfg.txt_records.get("server_name").unwrap(),
            "Lumina-Desktop"
        );
        assert_eq!(cfg.txt_records.get("version").unwrap(), "0.1.0");
        assert_eq!(cfg.txt_records.get("api_version").unwrap(), "1");
        assert_eq!(cfg.txt_records.get("pairing_required").unwrap(), "true");
        assert!(cfg.validate_txt_records());
    }

    #[test]
    fn test_mdns_instance_formatting() {
        let cfg = MdnsConfig {
            hostname: "Studio-PC".to_string(),
            ..Default::default()
        };
        assert_eq!(cfg.instance_name(), "Studio-PC._lumina._tcp.local.");
    }

    #[test]
    fn test_mdns_announcement_packet_wire_format() {
        let cfg = MdnsConfig::default();
        let pkt = cfg.build_announcement_packet(Ipv4Addr::new(192, 168, 1, 50));

        // DNS response header: ID=0, Flags=0x8400 (QR+AA), QD=0, AN=4
        assert!(pkt.len() > 40);
        assert_eq!(&pkt[0..4], &[0x00, 0x00, 0x84, 0x00]);
        assert_eq!(u16::from_be_bytes([pkt[4], pkt[5]]), 0);
        assert_eq!(u16::from_be_bytes([pkt[6], pkt[7]]), 4);

        assert!(pkt.windows(7).any(|w| w == b"_lumina"));
        assert!(pkt.windows(4).any(|w| w == b"_tcp"));
        assert!(pkt.windows(5).any(|w| w == b"local"));
        assert!(pkt.windows(26).any(|w| w == b"server_name=Lumina-Desktop"));
        assert!(pkt.windows(13).any(|w| w == b"version=0.1.0"));
        assert!(pkt.windows(4).any(|w| w == [192, 168, 1, 50]));
    }
}
