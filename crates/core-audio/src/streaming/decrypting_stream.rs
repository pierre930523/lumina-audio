use std::sync::Arc;

use async_trait::async_trait;
use blowfish::Blowfish;
use cbc::Decryptor;
use cipher::inout::InOutBuf;
use cipher::{BlockModeDecrypt, KeyIvInit};
use md5::{Digest, Md5};
use tokio_util::sync::CancellationToken;

use super::{ByteStreamSource, SegmentedSeekTarget, StreamError, read_all_at};

/// Standard Deezer encrypted/plaintext block size in bytes.
pub const DEFAULT_DEEZER_BLOCK_SIZE: usize = 2048;

/// Standard Deezer stripe period (`1` encrypted block followed by `stride - 1` plaintext blocks).
pub const DEFAULT_DEEZER_STRIDE: usize = 3;

/// Fixed 16-byte XOR secret used by Deezer BF-CBC key derivation.
pub const DEEZER_BLOWFISH_SECRET: &[u8; 16] = b"g4el58wc0zvf9na1";

/// Fixed 8-byte CBC initialization vector reset for every encrypted 2048-byte block.
pub const DEEZER_BLOWFISH_IV: [u8; 8] = [0, 1, 2, 3, 4, 5, 6, 7];

/// Derives the 16-byte Deezer Blowfish-CBC key from `track_id`.
///
/// Formula:
/// - `hash = md5_hex(track_id)` (32 lowercase ASCII hex bytes)
/// - `key[i] = hash[i] ^ hash[i + 16] ^ b"g4el58wc0zvf9na1"[i]` for `0..16`
pub fn derive_deezer_blowfish_key(track_id: &str) -> [u8; 16] {
    let digest = Md5::digest(track_id.as_bytes());
    let mut hex_bytes = [0u8; 32];
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for (idx, &b) in digest.iter().enumerate() {
        hex_bytes[idx * 2] = HEX[(b >> 4) as usize];
        hex_bytes[idx * 2 + 1] = HEX[(b & 0x0F) as usize];
    }

    let mut key = [0u8; 16];
    for i in 0..16 {
        key[i] = hex_bytes[i] ^ hex_bytes[i + 16] ^ DEEZER_BLOWFISH_SECRET[i];
    }
    key
}

/// [`ByteStreamSource`] decorator performing stateless Blowfish-CBC stripe decryption (every
/// `block_index % stride == 0` full 2048-byte block) while aligning all underlying `read_at`
/// requests to exact `block_size * stride` (`6144`-byte) stripe boundaries.
pub struct DecryptingByteStream {
    inner: Arc<dyn ByteStreamSource>,
    key: [u8; 16],
    block_size: usize,
    stride: usize,
    stripe_size: usize,
}

impl DecryptingByteStream {
    /// Wraps `inner` with standard Deezer Blowfish-CBC stripe geometry (`2048` / `3` = `6144` bytes).
    pub fn new(inner: Arc<dyn ByteStreamSource>, track_id: &str) -> Result<Self, StreamError> {
        Self::with_geometry(
            inner,
            track_id,
            DEFAULT_DEEZER_BLOCK_SIZE,
            DEFAULT_DEEZER_STRIDE,
        )
    }

    /// Wraps `inner` with an explicit `block_size` (non-zero multiple of 8) and `stride` (`>= 1`).
    pub fn with_geometry(
        inner: Arc<dyn ByteStreamSource>,
        track_id: &str,
        block_size: usize,
        stride: usize,
    ) -> Result<Self, StreamError> {
        let trimmed_id = track_id.trim();
        if trimmed_id.is_empty() {
            return Err(StreamError::Unsupported(
                "Deezer Blowfish decryption requires a non-empty track_id".to_string(),
            ));
        }
        if block_size == 0 || !block_size.is_multiple_of(8) {
            return Err(StreamError::Unsupported(format!(
                "Invalid Blowfish-CBC block_size {block_size}: must be a non-zero multiple of 8"
            )));
        }
        if stride == 0 {
            return Err(StreamError::Unsupported(
                "Invalid Blowfish-CBC stride 0: must be >= 1".to_string(),
            ));
        }
        let stripe_size = block_size
            .checked_mul(stride)
            .ok_or_else(|| StreamError::Unsupported("Blowfish stripe_size overflow".to_string()))?;

        Ok(Self {
            inner,
            key: derive_deezer_blowfish_key(trimmed_id),
            block_size,
            stride,
            stripe_size,
        })
    }

    /// Returns the derived 16-byte Blowfish key.
    pub fn key(&self) -> &[u8; 16] {
        &self.key
    }

    /// Returns the cipher block size in bytes (`2048` by default).
    pub fn block_size(&self) -> usize {
        self.block_size
    }

    /// Returns the stripe period (`3` by default, meaning `1` encrypted block per `3` blocks).
    pub fn stride(&self) -> usize {
        self.stride
    }

    /// Returns the stripe size in bytes (`6144` by default).
    pub fn stripe_size(&self) -> usize {
        self.stripe_size
    }

    fn decrypt_block_in_place(&self, block: &mut [u8]) -> Result<(), StreamError> {
        debug_assert_eq!(block.len(), self.block_size);
        let mut decryptor = Decryptor::<Blowfish>::new_from_slices(&self.key, &DEEZER_BLOWFISH_IV)
            .map_err(|e| StreamError::Io(format!("Blowfish-CBC init failed: {e}")))?;
        let (blocks, tail) = InOutBuf::from(block).into_chunks();
        if !tail.is_empty() {
            return Err(StreamError::Io(
                "Blowfish-CBC block length is not a multiple of 8 bytes".to_string(),
            ));
        }
        decryptor.decrypt_blocks_inout(blocks);
        Ok(())
    }
}

#[async_trait]
impl ByteStreamSource for DecryptingByteStream {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
        if self.inner.cancellation_token().is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if buf.is_empty() {
            return Ok(0);
        }

        let total_len = self.inner.len();
        if let Some(len) = total_len
            && offset >= len
        {
            return Ok(0);
        }

        let stripe = self.stripe_size as u64;
        let req_end = match total_len {
            Some(len) => offset.saturating_add(buf.len() as u64).min(len),
            None => offset.saturating_add(buf.len() as u64),
        };
        if req_end <= offset {
            return Ok(0);
        }

        let aligned_start = (offset / stripe) * stripe;
        let aligned_end_unclamped = req_end.div_ceil(stripe).saturating_mul(stripe);
        let aligned_end = match total_len {
            Some(len) => aligned_end_unclamped.min(len),
            None => aligned_end_unclamped,
        };

        let raw_len = (aligned_end - aligned_start) as usize;
        let mut raw = vec![0u8; raw_len];
        let actual_read = read_all_at(self.inner.as_ref(), aligned_start, &mut raw).await?;

        let inner_offset = (offset - aligned_start) as usize;
        if actual_read <= inner_offset {
            return Ok(0);
        }

        let block_size_u64 = self.block_size as u64;
        let stride_u64 = self.stride as u64;
        let start_block_idx = aligned_start / block_size_u64;

        for (local_idx, block) in raw[..actual_read].chunks_mut(self.block_size).enumerate() {
            let global_block_idx = start_block_idx + local_idx as u64;
            if block.len() == self.block_size && global_block_idx.is_multiple_of(stride_u64) {
                self.decrypt_block_in_place(block)?;
            }
        }

        let available = &raw[inner_offset..actual_read];
        let to_copy = available.len().min(buf.len());
        buf[..to_copy].copy_from_slice(&available[..to_copy]);
        Ok(to_copy)
    }

    fn len(&self) -> Option<u64> {
        self.inner.len()
    }

    fn cancel(&self) {
        self.inner.cancel();
    }

    fn cancellation_token(&self) -> CancellationToken {
        self.inner.cancellation_token()
    }

    fn hint_extension(&self) -> Option<&str> {
        self.inner.hint_extension()
    }

    fn mime_type(&self) -> Option<&str> {
        self.inner.mime_type()
    }

    async fn seek_to_time_ms(
        &self,
        target_ms: u64,
    ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
        self.inner.seek_to_time_ms(target_ms).await
    }

    fn reclaim_idle_memory(&self) -> usize {
        self.inner.reclaim_idle_memory()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cbc::Encryptor;
    use cipher::BlockModeEncrypt;
    use std::sync::Mutex;

    fn encrypt_deezer_payload(plaintext: &[u8], key: &[u8; 16]) -> Vec<u8> {
        let mut out = plaintext.to_vec();
        for (idx, block) in out.chunks_mut(DEFAULT_DEEZER_BLOCK_SIZE).enumerate() {
            if block.len() == DEFAULT_DEEZER_BLOCK_SIZE && idx % DEFAULT_DEEZER_STRIDE == 0 {
                let mut enc =
                    Encryptor::<Blowfish>::new_from_slices(key, &DEEZER_BLOWFISH_IV).unwrap();
                let (blocks, tail) = InOutBuf::from(block).into_chunks();
                assert!(tail.is_empty());
                enc.encrypt_blocks_inout(blocks);
            }
        }
        out
    }

    struct RecordingMockSource {
        data: Vec<u8>,
        report_len: bool,
        reads: Mutex<Vec<(u64, usize)>>,
        cancel: CancellationToken,
    }

    impl RecordingMockSource {
        fn new(data: Vec<u8>, report_len: bool) -> Self {
            Self {
                data,
                report_len,
                reads: Mutex::new(Vec::new()),
                cancel: CancellationToken::new(),
            }
        }
    }

    #[async_trait]
    impl ByteStreamSource for RecordingMockSource {
        async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
            self.reads.lock().unwrap().push((offset, buf.len()));
            let start = offset as usize;
            if start >= self.data.len() {
                return Ok(0);
            }
            let available = &self.data[start..];
            // Simulate partial read capped at 3000 bytes to test `read_all_at` looping as well.
            let n = available.len().min(buf.len()).min(3000);
            buf[..n].copy_from_slice(&available[..n]);
            Ok(n)
        }

        fn len(&self) -> Option<u64> {
            if self.report_len {
                Some(self.data.len() as u64)
            } else {
                None
            }
        }

        fn cancel(&self) {
            self.cancel.cancel();
        }

        fn cancellation_token(&self) -> CancellationToken {
            self.cancel.clone()
        }

        fn hint_extension(&self) -> Option<&str> {
            Some("flac")
        }

        fn mime_type(&self) -> Option<&str> {
            Some("audio/flac")
        }
    }

    #[test]
    fn test_deezer_key_derivation_known_vector() {
        // track_id = "3135556" -> md5 = "a1326a734955d0a1a29671158bf9a4f8"
        let digest = Md5::digest(b"3135556");
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex.len(), 32);

        let key = derive_deezer_blowfish_key("3135556");
        let h = hex.as_bytes();
        for i in 0..16 {
            assert_eq!(key[i], h[i] ^ h[i + 16] ^ b"g4el58wc0zvf9na1"[i]);
        }
    }

    #[tokio::test]
    async fn test_decrypting_stream_alignment_round_trip_tail_and_random_seek() {
        // 3 full 6144-byte stripes + 1 full encrypted 2048-byte block + 511-byte unencrypted tail
        let total_len = 6144 * 3 + 2048 + 511;
        let plaintext: Vec<u8> = (0..total_len)
            .map(|i| ((i * 19 + (i >> 7) * 13) & 0xFF) as u8)
            .collect();

        let key = derive_deezer_blowfish_key("554433");
        let encrypted = encrypt_deezer_payload(&plaintext, &key);
        // Verify tail < 2048 bytes and plaintext stripe blocks stayed unencrypted on wire.
        assert_eq!(&encrypted[2048..6144], &plaintext[2048..6144]);
        assert_eq!(&encrypted[total_len - 511..], &plaintext[total_len - 511..]);
        assert_ne!(&encrypted[0..2048], &plaintext[0..2048]);
        assert_ne!(
            &encrypted[6144 * 3..6144 * 3 + 2048],
            &plaintext[6144 * 3..6144 * 3 + 2048]
        );

        let inner = Arc::new(RecordingMockSource::new(encrypted, true));
        let stream = DecryptingByteStream::new(inner.clone(), "554433").unwrap();

        // 1. Unaligned random seek inside stripe 1 (offset 6144 + 777), crossing into stripe 2.
        let mut slice_a = vec![0u8; 7000];
        let n_a = stream.read_at(6144 + 777, &mut slice_a).await.unwrap();
        assert_eq!(n_a, 7000);
        assert_eq!(&slice_a[..], &plaintext[6144 + 777..6144 + 777 + 7000]);

        // Verify the first underlying read started on 6144 and spanned to 18432 (3 * 6144).
        {
            let recorded = inner.reads.lock().unwrap();
            let first = recorded[0];
            assert_eq!(first.0, 6144);
            assert_eq!(first.0 % 6144, 0);
            assert_eq!(first.1, 12_288);
            assert_eq!((first.0 + first.1 as u64) % 6144, 0);
        }

        // 2. Unaligned read across last full encrypted block + trailing <2048 byte tail.
        let tail_start = 6144 * 3 + 1000;
        let mut tail_buf = vec![0u8; 4096];
        let n_tail = stream
            .read_at(tail_start as u64, &mut tail_buf)
            .await
            .unwrap();
        assert_eq!(n_tail, total_len - tail_start);
        assert_eq!(&tail_buf[..n_tail], &plaintext[tail_start..]);

        // Verify the read starting at 6144*3 was clamped cleanly to total_len.
        {
            let recorded = inner.reads.lock().unwrap();
            let tail_req = recorded.last().unwrap();
            assert_eq!(tail_req.0, (6144 * 3) as u64);
            assert_eq!(tail_req.0 + tail_req.1 as u64, total_len as u64);
        }

        // 3. Full sequential read from 0 verifies every single byte matches plaintext.
        let mut full = vec![0u8; total_len];
        let n_full = read_all_at(&stream, 0, &mut full).await.unwrap();
        assert_eq!(n_full, total_len);
        assert_eq!(full, plaintext);

        // 4. Read at EOF returns 0.
        assert_eq!(
            stream
                .read_at(total_len as u64, &mut tail_buf)
                .await
                .unwrap(),
            0
        );
    }

    #[tokio::test]
    async fn test_decrypting_stream_works_with_unknown_content_length() {
        let total_len = 6144 + 1024;
        let plaintext: Vec<u8> = (0..total_len).map(|i| (i & 0xFF) as u8).collect();
        let key = derive_deezer_blowfish_key("999888");
        let encrypted = encrypt_deezer_payload(&plaintext, &key);

        let inner = Arc::new(RecordingMockSource::new(encrypted, false));
        let stream = DecryptingByteStream::new(inner, "999888").unwrap();
        assert_eq!(stream.len(), None);

        let mut out = vec![0u8; total_len + 500];
        let n = stream.read_at(500, &mut out).await.unwrap();
        assert_eq!(n, total_len - 500);
        assert_eq!(&out[..n], &plaintext[500..]);
    }
}
