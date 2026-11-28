use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AirPlaySessionInfo {
    pub rtsp_addr: String,
    pub rtp_host: String,
    pub session_id: String,
    pub server_port: u16,
    pub control_port: u16,
    pub timing_port: u16,
    pub audio_latency: Option<u32>,
}

pub struct AirPlayClient {
    rtsp_addr: String,
    rtp_host: String,
    stream: TcpStream,
    cseq: u32,
    session_id: Option<String>,
    pub server_port: u16,
    pub control_port: u16,
    pub timing_port: u16,
}

impl AirPlayClient {
    pub async fn connect(rtsp_addr: &str) -> Result<Self> {
        let clean = rtsp_addr.strip_prefix("rtsp://").unwrap_or(rtsp_addr);
        let rtp_host = clean
            .rsplit_once(':')
            .map(|(h, _)| h)
            .unwrap_or("127.0.0.1")
            .to_string();
        let stream = TcpStream::connect(clean).await?;
        stream.set_nodelay(true)?;
        Ok(Self {
            rtsp_addr: clean.to_string(),
            rtp_host,
            stream,
            cseq: 0,
            session_id: None,
            server_port: 0,
            control_port: 0,
            timing_port: 0,
        })
    }

    async fn send_rtsp(
        &mut self,
        method: &str,
        uri: &str,
        extra_headers: &[(&str, String)],
        body: Option<&[u8]>,
    ) -> Result<(u16, HashMap<String, String>)> {
        self.cseq += 1;
        let mut req = format!("{method} {uri} RTSP/1.0\r\nCSeq: {}\r\n", self.cseq);
        if let Some(ref sid) = self.session_id {
            req.push_str(&format!("Session: {sid}\r\n"));
        }
        for (k, v) in extra_headers {
            req.push_str(&format!("{k}: {v}\r\n"));
        }
        if let Some(b) = body {
            req.push_str(&format!("Content-Length: {}\r\n", b.len()));
        }
        req.push_str("\r\n");

        let mut frame = req.into_bytes();
        if let Some(b) = body {
            frame.extend_from_slice(b);
        }
        self.stream.write_all(&frame).await?;
        self.stream.flush().await?;

        let mut buf = Vec::with_capacity(1024);
        let mut tmp = [0u8; 512];
        loop {
            let n = self.stream.read(&mut tmp).await?;
            if n == 0 {
                return Err(anyhow!(
                    "AirPlay RTSP connection closed cleanly during {method}"
                ));
            }
            buf.extend_from_slice(&tmp[..n]);
            if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }

        let head = String::from_utf8_lossy(&buf);
        let mut lines = head.split("\r\n");
        let status_line = lines.next().unwrap_or("");
        let code = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse::<u16>().ok())
            .ok_or_else(|| anyhow!("Malformed RTSP status line: {status_line}"))?;

        let mut headers = HashMap::new();
        for line in lines {
            if line.is_empty() {
                break;
            }
            if let Some((k, v)) = line.split_once(':') {
                headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }

        if code >= 400 {
            return Err(anyhow!(
                "AirPlay RTSP {method} rejected with HTTP/RTSP {code}"
            ));
        }
        Ok((code, headers))
    }

    pub async fn options(&mut self) -> Result<()> {
        self.send_rtsp("OPTIONS", "*", &[], None).await?;
        Ok(())
    }

    pub async fn announce_pcm_sdp(&mut self) -> Result<()> {
        let sdp = format!(
            "v=0\r\no=Lumina 0 0 IN IP4 127.0.0.1\r\ns=Lumina Audio\r\n\
             c=IN IP4 {}\r\nt=0 0\r\nm=audio 0 RTP/AVP 96\r\n\
             a=rtpmap:96 L16/44100/2\r\n",
            self.rtp_host
        );
        let uri = format!("rtsp://{}/stream", self.rtsp_addr);
        self.send_rtsp(
            "ANNOUNCE",
            &uri,
            &[("Content-Type", "application/sdp".to_string())],
            Some(sdp.as_bytes()),
        )
        .await?;
        Ok(())
    }

    pub async fn setup(&mut self) -> Result<AirPlaySessionInfo> {
        let uri = format!("rtsp://{}/stream", self.rtsp_addr);
        let (_, headers) = self
            .send_rtsp(
                "SETUP",
                &uri,
                &[(
                    "Transport",
                    "RTP/AVP/UDP;unicast;interleaved=0-1;mode=record;control_port=0;timing_port=0"
                        .to_string(),
                )],
                None,
            )
            .await?;

        if let Some(sid) = headers.get("session") {
            self.session_id = Some(sid.clone());
        }
        if let Some(tr) = headers.get("transport") {
            for part in tr.split(';') {
                if let Some((k, v)) = part.trim().split_once('=') {
                    let key_lower = k.trim().to_ascii_lowercase();
                    if key_lower == "source" {
                        let host = v.trim();
                        if !host.is_empty() {
                            self.rtp_host = host.to_string();
                        }
                        continue;
                    }
                    let val = v.parse::<u16>().unwrap_or(0);
                    match key_lower.as_str() {
                        "server_port" => self.server_port = val,
                        "control_port" => self.control_port = val,
                        "timing_port" => self.timing_port = val,
                        _ => {}
                    }
                }
            }
        }

        Ok(AirPlaySessionInfo {
            rtsp_addr: self.rtsp_addr.clone(),
            rtp_host: self.rtp_host.clone(),
            session_id: self.session_id.clone().unwrap_or_else(|| "1".to_string()),
            server_port: self.server_port,
            control_port: self.control_port,
            timing_port: self.timing_port,
            audio_latency: None,
        })
    }

    pub async fn record(&mut self) -> Result<Option<u32>> {
        let uri = format!("rtsp://{}/stream", self.rtsp_addr);
        let (_, headers) = self
            .send_rtsp("RECORD", &uri, &[("Range", "npt=0-".to_string())], None)
            .await?;
        Ok(headers
            .get("audio-latency")
            .and_then(|s| s.parse::<u32>().ok()))
    }

    pub async fn set_volume_db(&mut self, volume_db: f32) -> Result<()> {
        let uri = format!("rtsp://{}/stream", self.rtsp_addr);
        let body = format!("volume: {volume_db:.6}\r\n");
        self.send_rtsp(
            "SET_PARAMETER",
            &uri,
            &[("Content-Type", "text/parameters".to_string())],
            Some(body.as_bytes()),
        )
        .await?;
        Ok(())
    }

    pub async fn flush(&mut self) -> Result<()> {
        let uri = format!("rtsp://{}/stream", self.rtsp_addr);
        self.send_rtsp("FLUSH", &uri, &[], None).await?;
        Ok(())
    }

    pub async fn teardown(&mut self) -> Result<()> {
        let uri = format!("rtsp://{}/stream", self.rtsp_addr);
        self.send_rtsp("TEARDOWN", &uri, &[], None).await?;
        Ok(())
    }

    /// Sends PCM/ALAC RTP audio frames (`payload_type=96`) to the negotiated AirPlay RTP UDP port.
    pub async fn send_rtp_frames(&self, frames: &[&[u8]], ssrc: u32) -> Result<usize> {
        if self.server_port == 0 {
            return Err(anyhow!("AirPlay SETUP has not negotiated server_port"));
        }
        let sock = UdpSocket::bind("0.0.0.0:0").await?;
        let target = format!("{}:{}", self.rtp_host, self.server_port);
        sock.connect(&target).await?;

        let mut sent = 0usize;
        for (idx, payload) in frames.iter().enumerate() {
            let mut pkt = Vec::with_capacity(12 + payload.len());
            pkt.push(0x80); // V=2, P=0, X=0, CC=0
            pkt.push(if idx == 0 { 0x80 | 96 } else { 96 }); // Marker on first packet, PT=96
            pkt.extend_from_slice(&(idx as u16).to_be_bytes());
            pkt.extend_from_slice(&((idx as u32) * 352).to_be_bytes());
            pkt.extend_from_slice(&ssrc.to_be_bytes());
            pkt.extend_from_slice(payload);
            sock.send(&pkt).await?;
            sent += 1;
        }
        Ok(sent)
    }
}
