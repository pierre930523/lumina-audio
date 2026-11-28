use std::collections::{BTreeMap, VecDeque};
use std::ops::Bound;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use tokio::sync::watch;

use super::super::StreamError;

pub(super) struct FetchedRange {
    pub(super) requested: Bytes,
    pub(super) full_body_200: Option<Bytes>,
    pub(super) raw_downloaded_bytes: usize,
}

pub(super) type InFlightChunkRx = watch::Receiver<Option<Result<Bytes, StreamError>>>;

#[derive(Debug)]
pub(super) struct RangeLruCache {
    pub(super) max_bytes: usize,
    pub(super) total_bytes: usize,
    /// Non-overlapping byte spans keyed by `start_offset`.
    pub(super) entries: BTreeMap<u64, Bytes>,
    /// LRU recency order of `start_offset` keys (front = oldest, back = MRU).
    pub(super) lru: VecDeque<u64>,
}

impl RangeLruCache {
    pub(super) fn new(max_bytes: usize) -> Self {
        Self {
            max_bytes: max_bytes.max(1),
            total_bytes: 0,
            entries: BTreeMap::new(),
            lru: VecDeque::new(),
        }
    }

    pub(super) fn touch(&mut self, start: u64) {
        if let Some(pos) = self.lru.iter().position(|&k| k == start) {
            self.lru.remove(pos);
            self.lru.push_back(start);
        }
    }

    pub(super) fn get_covering(&mut self, offset: u64) -> Option<(u64, Bytes)> {
        let (&start, data) = self.entries.range(..=offset).next_back()?;
        if offset >= start.saturating_add(data.len() as u64) {
            return None;
        }
        let cloned = data.clone();
        self.touch(start);
        Some((start, cloned))
    }

    pub(super) fn covering_bounds(&self, offset: u64) -> Option<(u64, u64)> {
        let (&start, data) = self.entries.range(..=offset).next_back()?;
        let end = start.saturating_add(data.len() as u64);
        (offset < end).then_some((start, end))
    }

    pub(super) fn has_contiguous_predecessor(&self, offset: u64) -> bool {
        if offset == 0 {
            return false;
        }
        self.entries
            .range(..offset)
            .next_back()
            .is_some_and(|(&start, data)| start.saturating_add(data.len() as u64) == offset)
    }

    pub(super) fn next_start_after(&self, offset: u64) -> Option<u64> {
        self.entries
            .range((Bound::Excluded(offset), Bound::Unbounded))
            .next()
            .map(|(&s, _)| s)
    }

    pub(super) fn insert(&mut self, start: u64, bytes: Bytes) {
        if bytes.is_empty() {
            return;
        }
        let new_end = start.saturating_add(bytes.len() as u64);

        // Remove any existing spans overlapping [start, new_end) to maintain strict non-overlap.
        let mut overlapping = Vec::new();
        if let Some((&prev_s, prev_b)) = self.entries.range(..start).next_back()
            && prev_s.saturating_add(prev_b.len() as u64) > start
        {
            overlapping.push(prev_s);
        }
        for (&s, _) in self.entries.range(start..new_end) {
            overlapping.push(s);
        }
        for k in overlapping {
            if let Some(old) = self.entries.remove(&k) {
                self.total_bytes = self.total_bytes.saturating_sub(old.len());
                if let Some(pos) = self.lru.iter().position(|&id| id == k) {
                    self.lru.remove(pos);
                }
            }
        }

        self.total_bytes = self.total_bytes.saturating_add(bytes.len());
        self.entries.insert(start, bytes);
        self.lru.push_back(start);

        while self.total_bytes > self.max_bytes && self.entries.len() > 1 {
            let Some(evicted_key) = self.lru.pop_front() else {
                break;
            };
            if let Some(evicted_bytes) = self.entries.remove(&evicted_key) {
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes.len());
            }
        }
    }

    pub(super) fn retain_only_covering(&mut self, offset: Option<u64>) -> usize {
        let before = self.total_bytes;
        let keep_key = offset.and_then(|off| {
            self.entries
                .range(..=off)
                .next_back()
                .filter(|(start, data)| off < start.saturating_add(data.len() as u64))
                .map(|(&start, _)| start)
                .or_else(|| {
                    let prev = off.saturating_sub(1);
                    self.entries
                        .range(..=prev)
                        .next_back()
                        .filter(|(start, data)| prev < start.saturating_add(data.len() as u64))
                        .map(|(&start, _)| start)
                })
        });
        if let Some(k) = keep_key {
            if let Some(bytes) = self.entries.remove(&k) {
                self.entries.clear();
                self.lru.clear();
                self.total_bytes = bytes.len();
                self.entries.insert(k, bytes);
                self.lru.push_back(k);
            }
        } else {
            self.entries.clear();
            self.lru.clear();
            self.total_bytes = 0;
        }
        before.saturating_sub(self.total_bytes)
    }
}

pub(super) struct InFlightRange {
    pub(super) id: u64,
    pub(super) start: u64,
    pub(super) end: u64,
    pub(super) allow_refresh: bool,
    pub(super) rx: InFlightChunkRx,
}

pub(super) struct ProxyState {
    pub(super) cache: RangeLruCache,
    pub(super) in_flight: Vec<InFlightRange>,
    pub(super) next_flight_id: u64,
    pub(super) last_read_end: Option<u64>,
}

pub(super) struct ChunkFlightCleanup {
    pub(super) flight_id: u64,
    pub(super) state: Arc<Mutex<ProxyState>>,
    pub(super) tx: watch::Sender<Option<Result<Bytes, StreamError>>>,
    pub(super) completed: bool,
}

impl Drop for ChunkFlightCleanup {
    fn drop(&mut self) {
        if let Ok(mut st) = self.state.lock() {
            st.in_flight.retain(|f| f.id != self.flight_id);
        }
        if !self.completed {
            let _ = self.tx.send(Some(Err(StreamError::Cancelled)));
        }
    }
}
