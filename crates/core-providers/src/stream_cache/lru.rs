use std::collections::HashMap;

use core_types::StreamKey;

use super::CachedStreamEntry;

struct LruSlot {
    entry: CachedStreamEntry,
    last_access: u64,
}

pub(super) struct LruCacheState {
    entries: HashMap<StreamKey, LruSlot>,
    access_seq: u64,
    max_entries: usize,
}

impl LruCacheState {
    pub(super) fn new(max_entries: usize) -> Self {
        Self {
            entries: HashMap::new(),
            access_seq: 0,
            max_entries,
        }
    }

    fn next_seq(&mut self) -> u64 {
        self.access_seq = self.access_seq.wrapping_add(1);
        self.access_seq
    }

    pub(super) fn get(
        &mut self,
        key: &StreamKey,
        now_epoch_secs: u64,
    ) -> Option<CachedStreamEntry> {
        let valid = self
            .entries
            .get(key)
            .is_some_and(|slot| slot.entry.is_valid_at(now_epoch_secs));

        if !valid {
            self.entries.remove(key);
            return None;
        }

        let seq = self.next_seq();
        if let Some(slot) = self.entries.get_mut(key) {
            slot.last_access = seq;
            return Some(slot.entry.clone());
        }
        None
    }

    pub(super) fn contains_valid(&self, key: &StreamKey, now_epoch_secs: u64) -> bool {
        self.entries
            .get(key)
            .is_some_and(|slot| slot.entry.is_valid_at(now_epoch_secs))
    }

    pub(super) fn put(&mut self, entry: CachedStreamEntry, now_epoch_secs: u64) {
        if self.max_entries == 0 {
            return;
        }

        if !entry.is_valid_at(now_epoch_secs) {
            self.entries.remove(&entry.key);
            return;
        }

        if !self.entries.contains_key(&entry.key) && self.entries.len() >= self.max_entries {
            // Opportunistically purge expired entries first before evicting a live LRU entry.
            self.entries
                .retain(|_, slot| slot.entry.is_valid_at(now_epoch_secs));

            while self.entries.len() >= self.max_entries {
                let oldest_key = self
                    .entries
                    .iter()
                    .min_by_key(|(_, slot)| slot.last_access)
                    .map(|(k, _)| k.clone());
                match oldest_key {
                    Some(k) => {
                        self.entries.remove(&k);
                    }
                    None => break,
                }
            }
        }

        let seq = self.next_seq();
        self.entries.insert(
            entry.key.clone(),
            LruSlot {
                entry,
                last_access: seq,
            },
        );
    }

    pub(super) fn remove(&mut self, key: &StreamKey) {
        self.entries.remove(key);
    }

    pub(super) fn remove_provider(&mut self, provider_id: &str) {
        self.entries
            .retain(|k, _| !k.provider_id.eq_ignore_ascii_case(provider_id));
    }

    pub(super) fn len(&self) -> usize {
        self.entries.len()
    }
}
