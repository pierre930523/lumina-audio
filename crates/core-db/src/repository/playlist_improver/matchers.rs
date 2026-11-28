use std::collections::{HashMap, HashSet};

use super::helpers::{
    AnalyzedTrack, compare_track_quality, durations_compatible, durations_compatible_or_unknown,
    is_local_provider, is_lossless_codec, is_streaming_provider, parse_raw_entry_hints,
};
use crate::repository::library::{normalize_local_path_for_compare, normalize_match_key};

const UPGRADE_SCORE_DELTA_MIN: f64 = 50.0;
const STREAMING_TO_LOCAL_LOSSLESS_DELTA_MIN: f64 = 20.0;

pub(crate) struct LibraryCatalogIndex {
    pub tracks: Vec<AnalyzedTrack>,
    pub by_album: HashMap<String, Vec<usize>>,
    pub by_canonical_track: HashMap<String, Vec<usize>>,
    pub by_isrc: HashMap<String, Vec<usize>>,
    pub by_title_artist: HashMap<(String, String), Vec<usize>>,
    pub by_title: HashMap<String, Vec<usize>>,
    pub by_ext_path: HashMap<String, usize>,
}

impl LibraryCatalogIndex {
    pub(crate) fn build(tracks: Vec<AnalyzedTrack>) -> Self {
        let mut by_album: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_canonical_track: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_isrc: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_title_artist: HashMap<(String, String), Vec<usize>> = HashMap::new();
        let mut by_title: HashMap<String, Vec<usize>> = HashMap::new();
        let mut by_ext_path: HashMap<String, usize> = HashMap::new();

        for (idx, t) in tracks.iter().enumerate() {
            by_album
                .entry(t.summary.canonical_album_id.clone())
                .or_default()
                .push(idx);
            if let Some(ref ct) = t.canonical_track_id {
                by_canonical_track.entry(ct.clone()).or_default().push(idx);
            }
            if let Some(ref isrc) = t.norm_isrc {
                by_isrc.entry(isrc.clone()).or_default().push(idx);
            }
            if !t.norm_title.is_empty() {
                by_title.entry(t.norm_title.clone()).or_default().push(idx);
                if !t.norm_artist.is_empty() {
                    by_title_artist
                        .entry((t.norm_title.clone(), t.norm_artist.clone()))
                        .or_default()
                        .push(idx);
                }
            }
            let norm_path = normalize_local_path_for_compare(&t.external_track_id);
            if !norm_path.is_empty() {
                by_ext_path.entry(norm_path).or_insert(idx);
            }
        }

        Self {
            tracks,
            by_album,
            by_canonical_track,
            by_isrc,
            by_title_artist,
            by_title,
            by_ext_path,
        }
    }
}

pub(crate) struct UnionFind {
    parent: Vec<usize>,
}

impl UnionFind {
    pub(crate) fn new(n: usize) -> Self {
        Self {
            parent: (0..n).collect(),
        }
    }

    pub(crate) fn find(&mut self, x: usize) -> usize {
        if self.parent[x] != x {
            let root = self.find(self.parent[x]);
            self.parent[x] = root;
        }
        self.parent[x]
    }

    pub(crate) fn union(&mut self, a: usize, b: usize) {
        let ra = self.find(a);
        let rb = self.find(b);
        if ra != rb {
            if ra < rb {
                self.parent[rb] = ra;
            } else {
                self.parent[ra] = rb;
            }
        }
    }
}

pub(crate) fn items_are_duplicates(a: &AnalyzedTrack, b: &AnalyzedTrack) -> bool {
    if a.summary.track_id == b.summary.track_id {
        return true;
    }
    if a.canonical_track_id.is_some()
        && a.canonical_track_id == b.canonical_track_id
        && durations_compatible_or_unknown(a.summary.duration_ms, b.summary.duration_ms)
    {
        return true;
    }
    !a.norm_title.is_empty()
        && !a.norm_artist.is_empty()
        && a.norm_title == b.norm_title
        && a.norm_artist == b.norm_artist
        && durations_compatible(a.summary.duration_ms, b.summary.duration_ms)
}

fn pick_best_candidate<'a>(
    candidates: impl IntoIterator<Item = &'a AnalyzedTrack>,
) -> Option<&'a AnalyzedTrack> {
    candidates
        .into_iter()
        .max_by(|a, b| compare_track_quality(a, b))
}

pub(crate) fn find_repair_for_broken<'a>(
    broken: &AnalyzedTrack,
    index: &'a LibraryCatalogIndex,
) -> Option<(&'a AnalyzedTrack, f32, String)> {
    // Priority 1: same canonical_album_id (album group)
    if let Some(album_indices) = index.by_album.get(&broken.summary.canonical_album_id) {
        let matches: Vec<&AnalyzedTrack> = album_indices
            .iter()
            .map(|&idx| &index.tracks[idx])
            .filter(|c| c.summary.track_id != broken.summary.track_id)
            .filter(|c| {
                let same_ct = broken.canonical_track_id.is_some()
                    && c.canonical_track_id == broken.canonical_track_id;
                let same_isrc = broken.norm_isrc.is_some() && c.norm_isrc == broken.norm_isrc;
                let same_title_dur = !broken.norm_title.is_empty()
                    && c.norm_title == broken.norm_title
                    && durations_compatible_or_unknown(
                        c.summary.duration_ms,
                        broken.summary.duration_ms,
                    );
                let same_slot = broken.track_number > 0
                    && c.disc_number == broken.disc_number
                    && c.track_number == broken.track_number
                    && ((!broken.norm_title.is_empty() && c.norm_title == broken.norm_title)
                        || durations_compatible(c.summary.duration_ms, broken.summary.duration_ms));
                same_ct || same_isrc || same_title_dur || same_slot
            })
            .collect();

        if let Some(best) = pick_best_candidate(matches) {
            let reason = format!(
                "Broken track repaired from same album group ({} {} {}Hz/{}-bit)",
                best.summary.provider_id,
                best.summary.codec.to_uppercase(),
                best.summary.sample_rate_hz,
                best.summary.bit_depth,
            );
            return Some((best, 0.96, reason));
        }
    }

    // Priority 2: cross-library match by canonical_track_id / ISRC / normalized (title, artist, duration ±3s)
    let mut candidate_indices: HashSet<usize> = HashSet::new();
    let mut strong_match = false;

    if let Some(ref ct) = broken.canonical_track_id
        && let Some(idxs) = index.by_canonical_track.get(ct)
    {
        candidate_indices.extend(idxs.iter().copied());
        strong_match = true;
    }
    if let Some(ref isrc) = broken.norm_isrc
        && let Some(idxs) = index.by_isrc.get(isrc)
    {
        candidate_indices.extend(idxs.iter().copied());
        strong_match = true;
    }
    if !broken.norm_title.is_empty()
        && !broken.norm_artist.is_empty()
        && let Some(idxs) = index
            .by_title_artist
            .get(&(broken.norm_title.clone(), broken.norm_artist.clone()))
    {
        for &idx in idxs {
            let c = &index.tracks[idx];
            if durations_compatible_or_unknown(c.summary.duration_ms, broken.summary.duration_ms) {
                candidate_indices.insert(idx);
            }
        }
    }

    let matches: Vec<&AnalyzedTrack> = candidate_indices
        .into_iter()
        .map(|idx| &index.tracks[idx])
        .filter(|c| c.summary.track_id != broken.summary.track_id)
        .collect();

    pick_best_candidate(matches).map(|best| {
        let confidence = if strong_match { 0.94 } else { 0.88 };
        let reason = format!(
            "Broken track repaired via library match ({} {} {}Hz/{}-bit)",
            best.summary.provider_id,
            best.summary.codec.to_uppercase(),
            best.summary.sample_rate_hz,
            best.summary.bit_depth,
        );
        (best, confidence, reason)
    })
}

pub(crate) fn find_repair_for_unresolved<'a>(
    raw_entry: &str,
    index: &'a LibraryCatalogIndex,
) -> Option<(&'a AnalyzedTrack, f32, String)> {
    let hints = parse_raw_entry_hints(raw_entry);
    if !hints.norm_path.is_empty()
        && let Some(&idx) = index.by_ext_path.get(&hints.norm_path)
    {
        let best = &index.tracks[idx];
        return Some((
            best,
            0.99,
            format!(
                "Unresolved entry matched existing library path ({})",
                best.summary.title
            ),
        ));
    }

    if let Some((ref artist, ref title)) = hints.norm_artist_title
        && let Some(idxs) = index.by_title_artist.get(&(title.clone(), artist.clone()))
        && let Some(best) = pick_best_candidate(idxs.iter().map(|&i| &index.tracks[i]))
    {
        return Some((
            best,
            0.90,
            format!(
                "Unresolved entry matched by artist & title ({} - {})",
                best.summary.artist_name, best.summary.title
            ),
        ));
    }

    if !hints.norm_title.is_empty()
        && let Some(idxs) = index.by_title.get(&hints.norm_title)
    {
        let parent_matched: Vec<&AnalyzedTrack> = hints
            .norm_parent_dir
            .as_deref()
            .map(|dir| {
                idxs.iter()
                    .map(|&i| &index.tracks[i])
                    .filter(|t| {
                        normalize_match_key(&t.summary.album_title) == dir || t.norm_artist == dir
                    })
                    .collect()
            })
            .unwrap_or_default();

        let pool: Vec<&AnalyzedTrack> = if !parent_matched.is_empty() {
            parent_matched
        } else {
            idxs.iter().map(|&i| &index.tracks[i]).collect()
        };

        if let Some(best) = pick_best_candidate(pool) {
            return Some((
                best,
                0.80,
                format!(
                    "Unresolved entry matched library title ({})",
                    best.summary.title
                ),
            ));
        }
    }

    None
}

pub(crate) fn find_upgrade_candidate<'a>(
    current: &AnalyzedTrack,
    index: &'a LibraryCatalogIndex,
) -> Option<(&'a AnalyzedTrack, f32, String)> {
    let mut candidate_indices: HashSet<usize> = HashSet::new();
    let mut id_matched: HashSet<usize> = HashSet::new();

    if let Some(ref ct) = current.canonical_track_id
        && let Some(idxs) = index.by_canonical_track.get(ct)
    {
        for &i in idxs {
            candidate_indices.insert(i);
            id_matched.insert(i);
        }
    }
    if let Some(ref isrc) = current.norm_isrc
        && let Some(idxs) = index.by_isrc.get(isrc)
    {
        for &i in idxs {
            candidate_indices.insert(i);
            id_matched.insert(i);
        }
    }
    if !current.norm_title.is_empty()
        && !current.norm_artist.is_empty()
        && let Some(idxs) = index
            .by_title_artist
            .get(&(current.norm_title.clone(), current.norm_artist.clone()))
    {
        for &idx in idxs {
            let c = &index.tracks[idx];
            if durations_compatible(c.summary.duration_ms, current.summary.duration_ms) {
                candidate_indices.insert(idx);
            }
        }
    }

    let current_is_lossless = is_lossless_codec(&current.summary.codec, current.summary.is_dsd);
    let current_is_streaming = is_streaming_provider(&current.summary.provider_id);

    let eligible: Vec<(usize, &AnalyzedTrack)> = candidate_indices
        .into_iter()
        .map(|idx| (idx, &index.tracks[idx]))
        .filter(|(_, c)| c.summary.track_id != current.summary.track_id)
        .filter(|(_, c)| {
            let delta = c.effective_score - current.effective_score;
            let cand_is_lossless = is_lossless_codec(&c.summary.codec, c.summary.is_dsd);
            let cand_is_local = is_local_provider(&c.summary.provider_id);

            delta >= UPGRADE_SCORE_DELTA_MIN
                || (!current_is_lossless && cand_is_lossless && delta > 0.0)
                || (current_is_streaming
                    && cand_is_local
                    && cand_is_lossless
                    && delta >= STREAMING_TO_LOCAL_LOSSLESS_DELTA_MIN)
        })
        .collect();

    eligible
        .into_iter()
        .max_by(|(_, a), (_, b)| compare_track_quality(a, b))
        .map(|(idx, best)| {
            let delta = best.effective_score - current.effective_score;
            let confidence = if id_matched.contains(&idx) {
                0.98
            } else {
                0.92
            };
            let reason = format!(
                "Higher quality version available: {} {} {}Hz/{}-bit (+{:.0} quality score)",
                best.summary.provider_id,
                best.summary.codec.to_uppercase(),
                best.summary.sample_rate_hz,
                best.summary.bit_depth,
                delta,
            );
            (best, confidence, reason)
        })
}
