use anyhow::{anyhow, Result};
use quick_xml::events::Event;
use quick_xml::Reader;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::time::{timeout_at, Instant};
use url::Url;

pub const DEFAULT_SSDP_ADDR: &str = "239.255.255.250:1900";
const AV_TRANSPORT_TYPE: &str = "urn:schemas-upnp-org:service:AVTransport:1";
const RENDERING_CONTROL_TYPE: &str = "urn:schemas-upnp-org:service:RenderingControl:1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DlnaDeviceDescriptor {
    pub udn: String,
    pub friendly_name: String,
    pub manufacturer: String,
    pub model_name: String,
    pub location: String,
    pub av_transport_control_url: String,
    pub rendering_control_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DlnaPositionInfo {
    pub track_uri: String,
    pub track_duration: String,
    pub rel_time: String,
    pub position_secs: u64,
}

pub fn format_hms(seconds: u64) -> String {
    let h = seconds / 3600;
    let m = (seconds % 3600) / 60;
    let s = seconds % 60;
    format!("{h:02}:{m:02}:{s:02}")
}

pub fn parse_hms(hms: &str) -> u64 {
    let parts: Vec<u64> = hms
        .trim()
        .split(':')
        .filter_map(|p| p.trim().parse::<u64>().ok())
        .collect();
    match parts.len() {
        3 => parts[0] * 3600 + parts[1] * 60 + parts[2],
        2 => parts[0] * 60 + parts[1],
        1 => parts[0],
        _ => 0,
    }
}

fn xml_escape(input: &str) -> String {
    input
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn extract_header_value(raw_http: &str, name: &str) -> Option<String> {
    let target = name.to_ascii_lowercase();
    for line in raw_http.lines() {
        if let Some((k, v)) = line.split_once(':')
            && k.trim().to_ascii_lowercase() == target
        {
            return Some(v.trim().to_string());
        }
    }
    None
}

fn resolve_control_url(base_location: &str, raw_ctrl: &str) -> String {
    if raw_ctrl.starts_with("http://") || raw_ctrl.starts_with("https://") {
        return raw_ctrl.to_string();
    }
    if let Ok(base) = Url::parse(base_location)
        && let Ok(joined) = base.join(raw_ctrl)
    {
        return joined.to_string();
    }
    raw_ctrl.to_string()
}

pub fn parse_device_description_xml(location: &str, xml: &str) -> Result<DlnaDeviceDescriptor> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut current_tag = String::new();
    let mut in_service = false;
    let mut friendly_name = String::new();
    let mut manufacturer = String::new();
    let mut model_name = String::new();
    let mut udn = String::new();

    let mut cur_service_type = String::new();
    let mut cur_control_url = String::new();
    let mut av_transport_url = String::new();
    let mut rendering_url = String::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if name == "service" {
                    in_service = true;
                    cur_service_type.clear();
                    cur_control_url.clear();
                }
                current_tag = name;
            }
            Ok(Event::End(e)) => {
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if name == "service" && in_service {
                    if cur_service_type.contains("AVTransport") && !cur_control_url.is_empty() {
                        av_transport_url = resolve_control_url(location, &cur_control_url);
                    } else if cur_service_type.contains("RenderingControl")
                        && !cur_control_url.is_empty()
                    {
                        rendering_url = resolve_control_url(location, &cur_control_url);
                    }
                    in_service = false;
                }
                current_tag.clear();
            }
            Ok(Event::Text(t)) => {
                let text = t.unescape()?.into_owned();
                if in_service {
                    match current_tag.as_str() {
                        "serviceType" => cur_service_type = text,
                        "controlURL" => cur_control_url = text,
                        _ => {}
                    }
                } else {
                    match current_tag.as_str() {
                        "friendlyName" if friendly_name.is_empty() => friendly_name = text,
                        "manufacturer" if manufacturer.is_empty() => manufacturer = text,
                        "modelName" if model_name.is_empty() => model_name = text,
                        "UDN" if udn.is_empty() => udn = text,
                        _ => {}
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => return Err(anyhow!("Invalid DLNA description XML: {e}")),
            _ => {}
        }
    }

    if friendly_name.is_empty() {
        friendly_name = "DLNA MediaRenderer".to_string();
    }
    if udn.is_empty() {
        udn = format!("uuid:dlna-{}", location.len());
    }

    Ok(DlnaDeviceDescriptor {
        udn,
        friendly_name,
        manufacturer,
        model_name,
        location: location.to_string(),
        av_transport_control_url: av_transport_url,
        rendering_control_url: rendering_url,
    })
}

pub fn extract_soap_tag(xml: &str, tag_name: &str) -> Option<String> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut active = false;
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                active = local == tag_name;
            }
            Ok(Event::End(_)) => active = false,
            Ok(Event::Text(t)) if active => {
                return t.unescape().ok().map(|v| v.into_owned());
            }
            Ok(Event::Eof) | Err(_) => return None,
            _ => {}
        }
    }
}

pub async fn discover_dlna_devices(
    ssdp_target: &str,
    listen_window: Duration,
) -> Result<Vec<DlnaDeviceDescriptor>> {
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    let host_hdr = if ssdp_target == DEFAULT_SSDP_ADDR {
        DEFAULT_SSDP_ADDR
    } else {
        ssdp_target
    };

    let msearch = format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: {host_hdr}\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: {AV_TRANSPORT_TYPE}\r\n\r\n"
    );
    // Also query MediaRenderer device type for strict SSDP responders
    let msearch_dev = format!(
        "M-SEARCH * HTTP/1.1\r\nHOST: {host_hdr}\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
    );

    sock.send_to(msearch_dev.as_bytes(), ssdp_target).await?;
    let _ = sock.send_to(msearch.as_bytes(), ssdp_target).await;

    let mut locations = HashSet::new();
    let deadline = Instant::now() + listen_window;
    let mut buf = [0u8; 4096];

    while Instant::now() < deadline {
        match timeout_at(deadline, sock.recv_from(&mut buf)).await {
            Ok(Ok((n, _addr))) => {
                let text = String::from_utf8_lossy(&buf[..n]);
                if let Some(loc) = extract_header_value(&text, "LOCATION") {
                    locations.insert(loc);
                }
            }
            _ => break,
        }
    }

    let client = Client::builder().timeout(Duration::from_secs(5)).build()?;
    let mut devices = Vec::new();
    for loc in locations {
        if let Ok(resp) = client.get(&loc).send().await
            && resp.status().is_success()
            && let Ok(xml) = resp.text().await
            && let Ok(desc) = parse_device_description_xml(&loc, &xml)
        {
            devices.push(desc);
        }
    }
    Ok(devices)
}

#[derive(Debug, Clone)]
pub struct DlnaController {
    client: Client,
}

impl Default for DlnaController {
    fn default() -> Self {
        Self::new()
    }
}

impl DlnaController {
    pub fn new() -> Self {
        Self {
            client: Client::builder()
                .timeout(Duration::from_secs(8))
                .build()
                .unwrap_or_else(|_| Client::new()),
        }
    }

    async fn soap_call(
        &self,
        control_url: &str,
        service_type: &str,
        action: &str,
        inner_body: &str,
    ) -> Result<String> {
        let envelope = format!(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\
             <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
             s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\
             <s:Body><u:{action} xmlns:u=\"{service_type}\">{inner_body}</u:{action}></s:Body>\
             </s:Envelope>"
        );

        let resp = self
            .client
            .post(control_url)
            .header("Content-Type", "text/xml; charset=\"utf-8\"")
            .header("SOAPACTION", format!("\"{service_type}#{action}\""))
            .body(envelope)
            .send()
            .await?;

        let status = resp.status();
        let text = resp.text().await?;
        if !status.is_success() {
            return Err(anyhow!("DLNA SOAP {action} failed ({status}): {text}"));
        }
        Ok(text)
    }

    pub async fn set_av_transport_uri(
        &self,
        control_url: &str,
        media_uri: &str,
        metadata: &str,
    ) -> Result<()> {
        let inner = format!(
            "<InstanceID>0</InstanceID><CurrentURI>{}</CurrentURI><CurrentURIMetaData>{}</CurrentURIMetaData>",
            xml_escape(media_uri),
            xml_escape(metadata)
        );
        self.soap_call(control_url, AV_TRANSPORT_TYPE, "SetAVTransportURI", &inner)
            .await?;
        Ok(())
    }

    pub async fn play(&self, control_url: &str) -> Result<()> {
        self.soap_call(
            control_url,
            AV_TRANSPORT_TYPE,
            "Play",
            "<InstanceID>0</InstanceID><Speed>1</Speed>",
        )
        .await?;
        Ok(())
    }

    pub async fn pause(&self, control_url: &str) -> Result<()> {
        self.soap_call(
            control_url,
            AV_TRANSPORT_TYPE,
            "Pause",
            "<InstanceID>0</InstanceID>",
        )
        .await?;
        Ok(())
    }

    pub async fn stop(&self, control_url: &str) -> Result<()> {
        self.soap_call(
            control_url,
            AV_TRANSPORT_TYPE,
            "Stop",
            "<InstanceID>0</InstanceID>",
        )
        .await?;
        Ok(())
    }

    pub async fn seek_seconds(&self, control_url: &str, position_secs: u64) -> Result<()> {
        let target = format_hms(position_secs);
        let inner = format!(
            "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>{target}</Target>"
        );
        self.soap_call(control_url, AV_TRANSPORT_TYPE, "Seek", &inner)
            .await?;
        Ok(())
    }

    pub async fn get_position_info(&self, control_url: &str) -> Result<DlnaPositionInfo> {
        let xml = self
            .soap_call(
                control_url,
                AV_TRANSPORT_TYPE,
                "GetPositionInfo",
                "<InstanceID>0</InstanceID>",
            )
            .await?;
        let rel_time = extract_soap_tag(&xml, "RelTime").unwrap_or_else(|| "00:00:00".to_string());
        let position_secs = parse_hms(&rel_time);
        Ok(DlnaPositionInfo {
            track_uri: extract_soap_tag(&xml, "TrackURI").unwrap_or_default(),
            track_duration: extract_soap_tag(&xml, "TrackDuration").unwrap_or_default(),
            rel_time,
            position_secs,
        })
    }

    pub async fn get_transport_state(&self, control_url: &str) -> Result<String> {
        let xml = self
            .soap_call(
                control_url,
                AV_TRANSPORT_TYPE,
                "GetTransportInfo",
                "<InstanceID>0</InstanceID>",
            )
            .await?;
        Ok(extract_soap_tag(&xml, "CurrentTransportState").unwrap_or_else(|| "UNKNOWN".to_string()))
    }

    pub async fn set_volume(&self, rendering_url: &str, volume_0_100: u8) -> Result<()> {
        let clamped = volume_0_100.min(100);
        let inner = format!(
            "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>{clamped}</DesiredVolume>"
        );
        self.soap_call(rendering_url, RENDERING_CONTROL_TYPE, "SetVolume", &inner)
            .await?;
        Ok(())
    }

    pub async fn get_volume(&self, rendering_url: &str) -> Result<u8> {
        let xml = self
            .soap_call(
                rendering_url,
                RENDERING_CONTROL_TYPE,
                "GetVolume",
                "<InstanceID>0</InstanceID><Channel>Master</Channel>",
            )
            .await?;
        let val = extract_soap_tag(&xml, "CurrentVolume")
            .and_then(|s| s.parse::<u8>().ok())
            .unwrap_or(0);
        Ok(val)
    }
}
