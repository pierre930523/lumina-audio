use async_trait::async_trait;
use tokio_util::sync::CancellationToken;

use super::super::{ByteStreamSource, SegmentedSeekTarget, StreamError};
use super::proxy::SegmentedStreamProxy;
use super::scheduler::SegmentSlot;

#[async_trait]
impl ByteStreamSource for SegmentedStreamProxy {
    async fn read_at(&self, offset: u64, buf: &mut [u8]) -> Result<usize, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        if buf.is_empty() {
            return Ok(0);
        }

        let (epoch, window_start_seg, window_cancel) = {
            let st = self
                .state
                .lock()
                .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;
            (
                st.window_epoch,
                st.window_start_seg,
                st.window_cancel.clone(),
            )
        };

        let (has_init, total_segs) = self
            .manifest
            .read()
            .map(|m| (m.init_url.is_some(), m.segments.len()))
            .unwrap_or((false, 0));
        let mut cum_offset = 0u64;
        let mut cursor = offset;
        let mut written = 0usize;
        let mut slot_pos = 0usize;

        while written < buf.len() {
            let (slot, active_seg_hint) = if has_init {
                if slot_pos == 0 {
                    (SegmentSlot::Init, window_start_seg)
                } else {
                    let seg_idx = window_start_seg + (slot_pos - 1);
                    if seg_idx >= total_segs {
                        break;
                    }
                    (SegmentSlot::Media(seg_idx), seg_idx)
                }
            } else {
                let seg_idx = window_start_seg + slot_pos;
                if seg_idx >= total_segs {
                    break;
                }
                (SegmentSlot::Media(seg_idx), seg_idx)
            };

            let bytes = self
                .get_or_fetch_slot(epoch, &window_cancel, slot, active_seg_hint)
                .await?;
            let slot_end = cum_offset + bytes.len() as u64;

            if cursor < slot_end {
                let prefetch_anchor = match slot {
                    SegmentSlot::Init => window_start_seg.saturating_sub(1),
                    SegmentSlot::Media(idx) => idx,
                };
                if matches!(slot, SegmentSlot::Media(_)) {
                    self.schedule_prefetch_ahead(epoch, &window_cancel, prefetch_anchor);
                } else if total_segs > window_start_seg && self.prefetch_ahead > 0 {
                    // When reading init, prefetch starting from window_start_seg within the bound.
                    self.schedule_prefetch_ahead(
                        epoch,
                        &window_cancel,
                        window_start_seg.saturating_sub(1),
                    );
                }

                let inner_offset = (cursor - cum_offset) as usize;
                let available = &bytes[inner_offset..];
                let to_copy = available.len().min(buf.len() - written);
                buf[written..written + to_copy].copy_from_slice(&available[..to_copy]);
                written += to_copy;
                cursor += to_copy as u64;
            }

            cum_offset = slot_end;
            slot_pos += 1;
        }

        Ok(written)
    }

    fn len(&self) -> Option<u64> {
        let st = self.state.lock().ok()?;
        let manifest = self.manifest.read().ok()?;
        let mut total = 0u64;
        if manifest.init_url.is_some() {
            total += st.init_bytes.as_ref()?.len() as u64;
        }
        for seg_idx in st.window_start_seg..manifest.segments.len() {
            total += st.segment_cache.peek(seg_idx)?.len() as u64;
        }
        Some(total)
    }

    fn cancel(&self) {
        self.cancel.cancel();
        if let Ok(st) = self.state.lock() {
            st.window_cancel.cancel();
        }
    }

    fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    fn hint_extension(&self) -> Option<&str> {
        self.hint_extension.as_deref()
    }

    fn mime_type(&self) -> Option<&str> {
        self.mime_type.as_deref()
    }

    async fn seek_to_time_ms(
        &self,
        target_ms: u64,
    ) -> Result<Option<SegmentedSeekTarget>, StreamError> {
        if self.cancel.is_cancelled() {
            return Err(StreamError::Cancelled);
        }
        let (idx, segment_start_ms) = {
            let manifest = self.manifest.read().map_err(|_| {
                StreamError::Io("segmented proxy manifest lock poisoned".to_string())
            })?;
            if manifest.segments.is_empty() {
                return Ok(None);
            }
            let idx = manifest
                .segments
                .partition_point(|s| s.start_ms <= target_ms)
                .saturating_sub(1)
                .min(manifest.segments.len() - 1);
            (idx, manifest.segments[idx].start_ms)
        };

        {
            let mut st = self
                .state
                .lock()
                .map_err(|_| StreamError::Io("segmented proxy state lock poisoned".to_string()))?;
            st.window_cancel.cancel();
            st.window_epoch = st.window_epoch.wrapping_add(1);
            st.window_start_seg = idx;
            st.window_cancel = self.cancel.child_token();
            // Retain previously cached segments in the LRU cache so backward seeks hit RAM.
        }

        Ok(Some(SegmentedSeekTarget {
            virtual_offset: 0,
            segment_index: idx,
            segment_start_ms,
        }))
    }

    fn reclaim_idle_memory(&self) -> usize {
        self.state
            .lock()
            .map(|mut st| {
                st.window_cancel.cancel();
                st.window_epoch = st.window_epoch.wrapping_add(1);
                st.window_cancel = self.cancel.child_token();
                st.in_flight.clear();
                let keep_seg = st.window_start_seg;
                st.segment_cache.retain_only(keep_seg)
            })
            .unwrap_or(0)
    }
}
