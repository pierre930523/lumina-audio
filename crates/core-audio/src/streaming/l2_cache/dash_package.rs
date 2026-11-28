use core_types::{L2_MAX_TARGET_BYTES, L2_TAIL_FINGERPRINT_LEN};
use sha2::{Digest, Sha512};

use super::super::StreamError;

/// Magic header for binary-encoded L2 DASH head packages (`.dash.head`).
pub const L2_DASH_MAGIC: &[u8; 5] = b"L2DH\x01";

/// Maximum number of media segments cached inside a [`DashL2Package`].
pub const MAX_DASH_L2_SEGMENTS: usize = 2;

/// Single media segment cached inside a [`DashL2Package`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashL2SegmentEntry {
    pub number: u64,
    pub start_ms: u64,
    pub duration_ms: u64,
    pub bytes: Vec<u8>,
}

/// Binary-serializable DASH L2 head package storing `init` + up to first 2 `.m4s` segments,
/// capped at `4 MiB` total payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashL2Package {
    pub mime_type: String,
    pub codecs: Option<String>,
    pub bandwidth: Option<u64>,
    pub total_duration_ms: Option<u64>,
    pub init_bytes: Vec<u8>,
    pub segments: Vec<DashL2SegmentEntry>,
}

impl DashL2Package {
    /// Returns the total raw media payload bytes (`init_bytes + sum(segments)`).
    pub fn payload_bytes(&self) -> usize {
        self.init_bytes
            .len()
            .saturating_add(self.segments.iter().map(|s| s.bytes.len()).sum::<usize>())
    }

    /// Trims `segments` to at most 2 entries whose combined payload stays within `max_payload_bytes`.
    pub fn trim_to_budget(&mut self, max_payload_bytes: usize) {
        let cap = max_payload_bytes.min(L2_MAX_TARGET_BYTES as usize);
        if self.init_bytes.len() > cap {
            self.segments.clear();
            return;
        }
        let mut used = self.init_bytes.len();
        let mut kept = 0usize;
        for seg in self.segments.iter().take(MAX_DASH_L2_SEGMENTS) {
            if used.saturating_add(seg.bytes.len()) <= cap {
                used += seg.bytes.len();
                kept += 1;
            } else {
                break;
            }
        }
        self.segments.truncate(kept);
    }

    /// Computes a deterministic 64-byte integrity fingerprint for this package.
    pub fn tail_fingerprint(&self) -> [u8; L2_TAIL_FINGERPRINT_LEN] {
        let mut hasher = Sha512::new();
        hasher.update(L2_DASH_MAGIC);

        hasher.update((self.mime_type.len() as u32).to_le_bytes());
        hasher.update(self.mime_type.as_bytes());

        match &self.codecs {
            Some(c) => {
                hasher.update([1u8]);
                hasher.update((c.len() as u32).to_le_bytes());
                hasher.update(c.as_bytes());
            }
            None => hasher.update([0u8]),
        }

        match self.bandwidth {
            Some(bw) => {
                hasher.update([1u8]);
                hasher.update(bw.to_le_bytes());
            }
            None => hasher.update([0u8]),
        }

        match self.total_duration_ms {
            Some(dur) => {
                hasher.update([1u8]);
                hasher.update(dur.to_le_bytes());
            }
            None => hasher.update([0u8]),
        }

        hasher.update((self.init_bytes.len() as u32).to_le_bytes());
        hasher.update(&self.init_bytes);

        hasher.update([self.segments.len().min(u8::MAX as usize) as u8]);
        for seg in &self.segments {
            hasher.update(seg.number.to_le_bytes());
            hasher.update(seg.start_ms.to_le_bytes());
            hasher.update(seg.duration_ms.to_le_bytes());
            hasher.update((seg.bytes.len() as u32).to_le_bytes());
            hasher.update(&seg.bytes);
        }

        let digest = hasher.finalize();
        let mut out = [0u8; L2_TAIL_FINGERPRINT_LEN];
        out.copy_from_slice(&digest[..L2_TAIL_FINGERPRINT_LEN]);
        out
    }

    /// Serializes this package into the `L2DH\x01` binary format, enforcing max 2 segments and `4 MiB` payload.
    pub fn encode(&self) -> Result<Vec<u8>, StreamError> {
        if self.segments.len() > MAX_DASH_L2_SEGMENTS {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package supports at most {MAX_DASH_L2_SEGMENTS} segments, got {}",
                self.segments.len()
            )));
        }
        let payload_len = self.payload_bytes();
        if payload_len > L2_MAX_TARGET_BYTES as usize {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package payload {payload_len} exceeds {} byte cap",
                L2_MAX_TARGET_BYTES
            )));
        }
        if self.init_bytes.is_empty() && self.segments.is_empty() {
            return Err(StreamError::InvalidManifest(
                "DashL2Package cannot be completely empty".to_string(),
            ));
        }

        let mime_len = u32::try_from(self.mime_type.len())
            .map_err(|_| StreamError::InvalidManifest("mime_type too long".to_string()))?;
        let init_len = u32::try_from(self.init_bytes.len())
            .map_err(|_| StreamError::InvalidManifest("init_bytes too long".to_string()))?;

        let mut out = Vec::with_capacity(64 + self.mime_type.len() + payload_len);
        out.extend_from_slice(L2_DASH_MAGIC);

        out.extend_from_slice(&mime_len.to_le_bytes());
        out.extend_from_slice(self.mime_type.as_bytes());

        match &self.codecs {
            Some(codecs) => {
                let len = u32::try_from(codecs.len())
                    .map_err(|_| StreamError::InvalidManifest("codecs too long".to_string()))?;
                out.push(1);
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(codecs.as_bytes());
            }
            None => out.push(0),
        }

        match self.bandwidth {
            Some(bw) => {
                out.push(1);
                out.extend_from_slice(&bw.to_le_bytes());
            }
            None => out.push(0),
        }

        match self.total_duration_ms {
            Some(dur) => {
                out.push(1);
                out.extend_from_slice(&dur.to_le_bytes());
            }
            None => out.push(0),
        }

        out.extend_from_slice(&init_len.to_le_bytes());
        out.extend_from_slice(&self.init_bytes);

        out.push(self.segments.len() as u8);
        for seg in &self.segments {
            let seg_len = u32::try_from(seg.bytes.len())
                .map_err(|_| StreamError::InvalidManifest("segment bytes too long".to_string()))?;
            out.extend_from_slice(&seg.number.to_le_bytes());
            out.extend_from_slice(&seg.start_ms.to_le_bytes());
            out.extend_from_slice(&seg.duration_ms.to_le_bytes());
            out.extend_from_slice(&seg_len.to_le_bytes());
            out.extend_from_slice(&seg.bytes);
        }

        Ok(out)
    }

    /// Decodes a `L2DH\x01` binary package from disk bytes.
    pub fn decode(bytes: &[u8]) -> Result<Self, StreamError> {
        let mut cursor = BinaryCursor::new(bytes);
        let magic = cursor.read_exact(L2_DASH_MAGIC.len())?;
        if magic != L2_DASH_MAGIC {
            return Err(StreamError::InvalidManifest(
                "Invalid DashL2Package magic header".to_string(),
            ));
        }

        let mime_type = cursor.read_string()?;
        let codecs = if cursor.read_u8()? != 0 {
            Some(cursor.read_string()?)
        } else {
            None
        };
        let bandwidth = if cursor.read_u8()? != 0 {
            Some(cursor.read_u64_le()?)
        } else {
            None
        };
        let total_duration_ms = if cursor.read_u8()? != 0 {
            Some(cursor.read_u64_le()?)
        } else {
            None
        };

        let init_len = cursor.read_u32_le()? as usize;
        if init_len > L2_MAX_TARGET_BYTES as usize {
            return Err(StreamError::InvalidManifest(
                "DashL2Package init_bytes exceeds max cap".to_string(),
            ));
        }
        let init_bytes = cursor.read_exact(init_len)?.to_vec();

        let seg_count = cursor.read_u8()? as usize;
        if seg_count > MAX_DASH_L2_SEGMENTS {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package segment count {seg_count} exceeds max {MAX_DASH_L2_SEGMENTS}"
            )));
        }

        let mut total_payload = init_bytes.len();
        let mut segments = Vec::with_capacity(seg_count);
        for _ in 0..seg_count {
            let number = cursor.read_u64_le()?;
            let start_ms = cursor.read_u64_le()?;
            let duration_ms = cursor.read_u64_le()?;
            let seg_len = cursor.read_u32_le()? as usize;
            total_payload = total_payload.saturating_add(seg_len);
            if total_payload > L2_MAX_TARGET_BYTES as usize {
                return Err(StreamError::InvalidManifest(
                    "DashL2Package payload exceeds 4 MiB cap".to_string(),
                ));
            }
            let seg_bytes = cursor.read_exact(seg_len)?.to_vec();
            segments.push(DashL2SegmentEntry {
                number,
                start_ms,
                duration_ms,
                bytes: seg_bytes,
            });
        }

        if cursor.remaining() != 0 {
            return Err(StreamError::InvalidManifest(format!(
                "DashL2Package has {} trailing bytes",
                cursor.remaining()
            )));
        }

        Ok(Self {
            mime_type,
            codecs,
            bandwidth,
            total_duration_ms,
            init_bytes,
            segments,
        })
    }
}

struct BinaryCursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> BinaryCursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    fn read_exact(&mut self, len: usize) -> Result<&'a [u8], StreamError> {
        let end = self.pos.checked_add(len).ok_or_else(|| {
            StreamError::InvalidManifest("DashL2Package offset overflow".to_string())
        })?;
        if end > self.data.len() {
            return Err(StreamError::InvalidManifest(
                "Unexpected EOF decoding DashL2Package".to_string(),
            ));
        }
        let slice = &self.data[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn read_u8(&mut self) -> Result<u8, StreamError> {
        Ok(self.read_exact(1)?[0])
    }

    fn read_u32_le(&mut self) -> Result<u32, StreamError> {
        let bytes = self.read_exact(4)?;
        Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn read_u64_le(&mut self) -> Result<u64, StreamError> {
        let bytes = self.read_exact(8)?;
        Ok(u64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]))
    }

    fn read_string(&mut self) -> Result<String, StreamError> {
        let len = self.read_u32_le()? as usize;
        if len > L2_MAX_TARGET_BYTES as usize {
            return Err(StreamError::InvalidManifest(
                "DashL2Package string field too large".to_string(),
            ));
        }
        let raw = self.read_exact(len)?;
        std::str::from_utf8(raw).map(str::to_string).map_err(|e| {
            StreamError::InvalidManifest(format!("Invalid UTF-8 in DashL2Package: {e}"))
        })
    }
}
