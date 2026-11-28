use super::DEFAULT_STDERR_RING_BYTES;

/// Bounded circular byte buffer keeping only the trailing `capacity` bytes.
#[derive(Debug, Clone)]
pub struct RingLogBuffer {
    buf: Vec<u8>,
    head: usize,
    len: usize,
    capacity: usize,
    truncated: bool,
}

impl Default for RingLogBuffer {
    fn default() -> Self {
        Self::new(DEFAULT_STDERR_RING_BYTES)
    }
}

impl RingLogBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            buf: vec![0u8; capacity],
            head: 0,
            len: 0,
            capacity,
            truncated: false,
        }
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn is_truncated(&self) -> bool {
        self.truncated
    }

    pub fn push(&mut self, bytes: &[u8]) {
        if self.capacity == 0 || bytes.is_empty() {
            if !bytes.is_empty() {
                self.truncated = true;
            }
            return;
        }

        if bytes.len() >= self.capacity {
            let had_data = self.len > 0;
            let tail = &bytes[bytes.len() - self.capacity..];
            self.buf[..self.capacity].copy_from_slice(tail);
            self.head = 0;
            self.len = self.capacity;
            self.truncated = self.truncated || had_data || bytes.len() > self.capacity;
            return;
        }

        let write_start = (self.head + self.len) % self.capacity;
        let first_part = bytes.len().min(self.capacity - write_start);
        self.buf[write_start..write_start + first_part].copy_from_slice(&bytes[..first_part]);
        let remaining = bytes.len() - first_part;
        if remaining > 0 {
            self.buf[..remaining].copy_from_slice(&bytes[first_part..]);
        }

        let total = self.len + bytes.len();
        if total > self.capacity {
            let overflow = total - self.capacity;
            self.head = (self.head + overflow) % self.capacity;
            self.len = self.capacity;
            self.truncated = true;
        } else {
            self.len = total;
        }
    }

    /// Return the currently buffered bytes in chronological order.
    pub fn as_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.len);
        if self.len == 0 {
            return out;
        }
        let first_part = self.len.min(self.capacity - self.head);
        out.extend_from_slice(&self.buf[self.head..self.head + first_part]);
        let remaining = self.len - first_part;
        if remaining > 0 {
            out.extend_from_slice(&self.buf[..remaining]);
        }
        out
    }

    /// Decode the buffered bytes as UTF-8, trimming any split leading multi-byte
    /// UTF-8 continuation bytes so ring wrap-around never produces leading garbage or panics.
    pub fn as_string_lossy(&self) -> String {
        let bytes = self.as_bytes();
        let mut start = 0usize;
        if self.truncated {
            // Skip up to 3 orphaned UTF-8 continuation bytes (10xxxxxx) left by ring truncation.
            while start < bytes.len() && start < 3 && (bytes[start] & 0b1100_0000) == 0b1000_0000 {
                start += 1;
            }
        }
        String::from_utf8_lossy(&bytes[start..]).into_owned()
    }
}
