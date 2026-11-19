use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::time::timeout;

const NTP_EPOCH_DELTA_SECS: i64 = 2_208_988_800;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClockSyncSample {
    pub t1_us: i64,
    pub t2_us: i64,
    pub t3_us: i64,
    pub t4_us: i64,
    pub offset_us: i64,
    pub rtt_us: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClockSyncMeasurement {
    pub server_addr: String,
    pub offset_us: i64,
    pub rtt_us: i64,
    pub drift_ppm: f64,
    pub sample_count: usize,
    pub samples: Vec<ClockSyncSample>,
    pub master_now_us: i64,
}

#[derive(Debug, Serialize)]
struct ClockJsonPing {
    t1_us: i64,
}

#[derive(Debug, Deserialize)]
struct ClockJsonPong {
    t1_us: i64,
    t2_us: i64,
    t3_us: i64,
}

pub fn now_unix_us() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as i64)
        .unwrap_or(0)
}

fn unix_us_to_ntp(unix_us: i64) -> (u32, u32) {
    let secs = unix_us.div_euclid(1_000_000) + NTP_EPOCH_DELTA_SECS;
    let rem_us = unix_us.rem_euclid(1_000_000) as u128;
    let frac = ((rem_us << 32) / 1_000_000) as u32;
    (secs as u32, frac)
}

fn ntp_to_unix_us(secs: u32, frac: u32) -> i64 {
    let unix_secs = (secs as i64) - NTP_EPOCH_DELTA_SECS;
    let rem_us = (((frac as u128) * 1_000_000) >> 32) as i64;
    unix_secs * 1_000_000 + rem_us
}

fn compute_sample(t1_us: i64, t2_us: i64, t3_us: i64, t4_us: i64) -> ClockSyncSample {
    let offset_us = ((t2_us - t1_us) + (t3_us - t4_us)) / 2;
    let rtt_us = (t4_us - t1_us) - (t3_us - t2_us);
    ClockSyncSample {
        t1_us,
        t2_us,
        t3_us,
        t4_us,
        offset_us,
        rtt_us,
    }
}

/// Estimates clock drift in parts-per-million using ordinary least squares on sample offsets.
pub fn estimate_drift_ppm(samples: &[ClockSyncSample]) -> f64 {
    if samples.len() < 2 {
        return 0.0;
    }
    let t0 = samples[0].t1_us as f64;
    let mut sum_x = 0.0;
    let mut sum_y = 0.0;
    let mut sum_xx = 0.0;
    let mut sum_xy = 0.0;
    let n = samples.len() as f64;

    for s in samples {
        let x_sec = (s.t1_us as f64 - t0) / 1_000_000.0;
        let y_us = s.offset_us as f64;
        sum_x += x_sec;
        sum_y += y_us;
        sum_xx += x_sec * x_sec;
        sum_xy += x_sec * y_us;
    }

    let denom = n * sum_xx - sum_x * sum_x;
    if denom.abs() < 1e-9 {
        return 0.0;
    }
    (n * sum_xy - sum_x * sum_y) / denom
}

/// Computes local delay in microseconds required to align playback with a master PTS.
pub fn aligned_start_delay_us(master_pts_us: i64, local_now_us: i64, offset_us: i64) -> i64 {
    let target_local_us = master_pts_us - offset_us;
    (target_local_us - local_now_us).max(0)
}

pub async fn sync_sntp_once(server_addr: &str, req_timeout: Duration) -> Result<ClockSyncSample> {
    let clean_addr = server_addr.strip_prefix("udp://").unwrap_or(server_addr);
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.connect(clean_addr).await?;

    let t1_us = now_unix_us();
    let (sec, frac) = unix_us_to_ntp(t1_us);
    let mut pkt = [0u8; 48];
    pkt[0] = 0x23; // LI=0, VN=4, Mode=3 (client)
    pkt[40..44].copy_from_slice(&sec.to_be_bytes());
    pkt[44..48].copy_from_slice(&frac.to_be_bytes());

    sock.send(&pkt).await?;

    let mut resp = [0u8; 64];
    let n = timeout(req_timeout, sock.recv(&mut resp))
        .await
        .map_err(|_| anyhow!("SNTP timeout communicating with {clean_addr}"))??;
    let t4_us = now_unix_us();
    if n < 48 {
        return Err(anyhow!("Truncated SNTP packet ({n} bytes)"));
    }

    let t2_sec = u32::from_be_bytes([resp[32], resp[33], resp[34], resp[35]]);
    let t2_frac = u32::from_be_bytes([resp[36], resp[37], resp[38], resp[39]]);
    let t3_sec = u32::from_be_bytes([resp[40], resp[41], resp[42], resp[43]]);
    let t3_frac = u32::from_be_bytes([resp[44], resp[45], resp[46], resp[47]]);

    let t2_us = ntp_to_unix_us(t2_sec, t2_frac);
    let t3_us = ntp_to_unix_us(t3_sec, t3_frac);
    Ok(compute_sample(t1_us, t2_us, t3_us, t4_us))
}

pub async fn sync_json_once(server_addr: &str, req_timeout: Duration) -> Result<ClockSyncSample> {
    let clean_addr = server_addr.strip_prefix("udp://").unwrap_or(server_addr);
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.connect(clean_addr).await?;

    let t1_us = now_unix_us();
    let payload = serde_json::to_vec(&ClockJsonPing { t1_us })?;
    sock.send(&payload).await?;

    let mut buf = [0u8; 1024];
    let n = timeout(req_timeout, sock.recv(&mut buf))
        .await
        .map_err(|_| anyhow!("Clock sync timeout communicating with {clean_addr}"))??;
    let t4_us = now_unix_us();

    let pong: ClockJsonPong = serde_json::from_slice(&buf[..n])?;
    Ok(compute_sample(pong.t1_us, pong.t2_us, pong.t3_us, t4_us))
}

pub async fn measure_clock_sync(
    server_addr: &str,
    sample_count: usize,
    sample_interval_ms: u64,
    req_timeout: Duration,
    use_sntp_binary: bool,
) -> Result<ClockSyncMeasurement> {
    let count = sample_count.clamp(1, 16);
    let mut samples = Vec::with_capacity(count);
    let mut last_err: Option<anyhow::Error> = None;

    for idx in 0..count {
        let res = if use_sntp_binary {
            sync_sntp_once(server_addr, req_timeout).await
        } else {
            sync_json_once(server_addr, req_timeout).await
        };
        match res {
            Ok(sample) => samples.push(sample),
            Err(e) => last_err = Some(e),
        }
        if idx + 1 < count && sample_interval_ms > 0 {
            tokio::time::sleep(Duration::from_millis(sample_interval_ms)).await;
        }
    }

    if samples.is_empty() {
        return Err(last_err.unwrap_or_else(|| anyhow!("No clock sync samples succeeded")));
    }

    let best = samples
        .iter()
        .min_by_key(|s| s.rtt_us)
        .cloned()
        .expect("non-empty samples");
    let drift_ppm = estimate_drift_ppm(&samples);
    let now_us = now_unix_us();

    Ok(ClockSyncMeasurement {
        server_addr: server_addr.to_string(),
        offset_us: best.offset_us,
        rtt_us: best.rtt_us,
        drift_ppm,
        sample_count: samples.len(),
        samples,
        master_now_us: now_us + best.offset_us,
    })
}
