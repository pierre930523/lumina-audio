use std::collections::{HashMap, VecDeque};
use std::ops::RangeInclusive;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use super::super::StreamError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum SegmentSlot {
    Init,
    Media(usize),
}

pub(super) type InFlightSegRx = watch::Receiver<Option<Result<Bytes, StreamError>>>;

#[derive(Debug)]
pub(super) struct SegmentLruCache {
    pub(super) max_bytes: usize,
    pub(super) max_entries: usize,
    pub(super) total_bytes: usize,
    pub(super) entries: HashMap<usize, Bytes>,
    pub(super) lru: VecDeque<usize>,
}

impl SegmentLruCache {
    pub(super) fn new(max_bytes: usize, max_entries: usize) -> Self {
        Self {
            max_bytes: max_bytes.max(1),
            max_entries: max_entries.max(1),
            total_bytes: 0,
            entries: HashMap::new(),
            lru: VecDeque::new(),
        }
    }

    pub(super) fn touch(&mut self, seg_idx: usize) {
        if let Some(pos) = self.lru.iter().position(|&k| k == seg_idx) {
            self.lru.remove(pos);
            self.lru.push_back(seg_idx);
        }
    }

    pub(super) fn get(&mut self, seg_idx: usize) -> Option<Bytes> {
        let bytes = self.entries.get(&seg_idx)?.clone();
        self.touch(seg_idx);
        Some(bytes)
    }

    pub(super) fn peek(&self, seg_idx: usize) -> Option<&Bytes> {
        self.entries.get(&seg_idx)
    }

    pub(super) fn contains_key(&self, seg_idx: usize) -> bool {
        self.entries.contains_key(&seg_idx)
    }

    pub(super) fn insert(
        &mut self,
        seg_idx: usize,
        bytes: Bytes,
        protected: RangeInclusive<usize>,
    ) {
        if let Some(old) = self.entries.insert(seg_idx, bytes.clone()) {
            self.total_bytes = self.total_bytes.saturating_sub(old.len());
            self.total_bytes = self.total_bytes.saturating_add(bytes.len());
            self.touch(seg_idx);
        } else {
            self.total_bytes = self.total_bytes.saturating_add(bytes.len());
            self.lru.push_back(seg_idx);
        }

        while (self.total_bytes > self.max_bytes || self.entries.len() > self.max_entries)
            && self.entries.len() > 1
        {
            let Some(pos) = self
                .lru
                .iter()
                .position(|&k| k != seg_idx && !protected.contains(&k))
            else {
                break;
            };
            if let Some(evicted_key) = self.lru.remove(pos)
                && let Some(evicted_bytes) = self.entries.remove(&evicted_key)
            {
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes.len());
            }
        }
    }

    pub(super) fn retain_only(&mut self, keep_seg: usize) -> usize {
        let before = self.total_bytes;
        if let Some(bytes) = self.entries.remove(&keep_seg) {
            self.entries.clear();
            self.lru.clear();
            self.total_bytes = bytes.len();
            self.entries.insert(keep_seg, bytes);
            self.lru.push_back(keep_seg);
        } else {
            self.entries.clear();
            self.lru.clear();
            self.total_bytes = 0;
        }
        before.saturating_sub(self.total_bytes)
    }
}

pub(super) struct InFlightSegment {
    pub(super) allow_refresh: bool,
    pub(super) rx: InFlightSegRx,
}

pub(super) struct WindowState {
    pub(super) window_epoch: u64,
    pub(super) window_start_seg: usize,
    pub(super) window_cancel: CancellationToken,
    pub(super) init_bytes: Option<Bytes>,
    pub(super) segment_cache: SegmentLruCache,
    pub(super) in_flight: HashMap<(u64, SegmentSlot), InFlightSegment>,
}

pub(super) struct SegFlightCleanup {
    pub(super) key: (u64, SegmentSlot),
    pub(super) in_flight_active: Arc<Mutex<WindowState>>,
    pub(super) tx: watch::Sender<Option<Result<Bytes, StreamError>>>,
    pub(super) completed: bool,
}

impl Drop for SegFlightCleanup {
    fn drop(&mut self) {
        if let Ok(mut st) = self.in_flight_active.lock() {
            st.in_flight.remove(&self.key);
        }
        if !self.completed {
            let _ = self.tx.send(Some(Err(StreamError::Cancelled)));
        }
    }
}
