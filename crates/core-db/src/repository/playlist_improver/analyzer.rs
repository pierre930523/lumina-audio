use std::collections::{HashMap, HashSet};

use core_types::{
    PlaylistImprovementKind, PlaylistImprovementReport, PlaylistImprovementSuggestion,
};
use sqlx::{SqliteConnection, SqlitePool};

use super::PlaylistImproverRepository;
use super::helpers::{DiskCheckMode, compare_track_quality};
use super::matchers::{
    LibraryCatalogIndex, UnionFind, find_repair_for_broken, find_repair_for_unresolved,
    find_upgrade_candidate, items_are_duplicates,
};
use super::queries::{load_healthy_library_tracks_conn, load_playlist_items_conn};
use crate::error::{DbError, Result};

pub(crate) async fn analyze_playlist_conn(
    conn: &mut SqliteConnection,
    playlist_id: &str,
    mode: DiskCheckMode,
) -> Result<PlaylistImprovementReport> {
    let pid = playlist_id.trim();
    let header: Option<(String, String)> =
        sqlx::query_as("SELECT id, name FROM playlists WHERE id = ?")
            .bind(pid)
            .fetch_optional(&mut *conn)
            .await?;
    let Some((id, playlist_name)) = header else {
        return Err(DbError::NotFound(format!(
            "Static playlist '{pid}' not found"
        )));
    };

    let items = load_playlist_items_conn(conn, &id, mode).await?;
    let healthy_library = load_healthy_library_tracks_conn(conn, mode).await?;
    let index = LibraryCatalogIndex::build(healthy_library);

    let mut suggestions: Vec<PlaylistImprovementSuggestion> = Vec::new();
    let mut duplicate_removed_positions: HashSet<i64> = HashSet::new();

    // 1. Duplicate detection (exact track_id, canonical_track_id, or normalized title+artist+duration±3s)
    let mut uf = UnionFind::new(items.len());
    for (i, item_i) in items.iter().enumerate() {
        let Some(ref ti) = item_i.track else {
            continue;
        };
        for (j, item_j) in items.iter().enumerate().skip(i + 1) {
            let Some(ref tj) = item_j.track else {
                continue;
            };
            if items_are_duplicates(ti, tj) {
                uf.union(i, j);
            }
        }
    }

    let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
    for (idx, item) in items.iter().enumerate() {
        if item.track.is_some() {
            groups.entry(uf.find(idx)).or_default().push(idx);
        }
    }

    for mut members in groups.into_values() {
        if members.len() < 2 {
            continue;
        }
        members.sort_by(|&a, &b| {
            let ia = &items[a];
            let ib = &items[b];
            let ta = ia.track.as_ref().expect("checked");
            let tb = ib.track.as_ref().expect("checked");
            ib.is_healthy
                .cmp(&ia.is_healthy)
                .then_with(|| compare_track_quality(tb, ta))
                .then_with(|| ia.position.cmp(&ib.position))
        });

        let keeper = &items[members[0]];
        let keeper_track = keeper.track.as_ref().expect("checked");

        for &dup_idx in &members[1..] {
            let dup = &items[dup_idx];
            let dup_track = dup.track.as_ref().expect("checked");
            duplicate_removed_positions.insert(dup.position);

            let exact_same = dup_track.summary.track_id == keeper_track.summary.track_id;
            let same_canonical = dup_track.canonical_track_id.is_some()
                && dup_track.canonical_track_id == keeper_track.canonical_track_id;
            let confidence = if exact_same || same_canonical {
                1.0
            } else {
                0.95
            };
            let reason = if exact_same {
                format!(
                    "Duplicate of position {} (keeping highest quality copy)",
                    keeper.position
                )
            } else {
                format!(
                    "Duplicate of '{}' at position {} (keeping {} {}Hz/{}-bit, score {:.0})",
                    keeper_track.summary.title,
                    keeper.position,
                    keeper_track.summary.codec.to_uppercase(),
                    keeper_track.summary.sample_rate_hz,
                    keeper_track.summary.bit_depth,
                    keeper_track.effective_score,
                )
            };

            suggestions.push(PlaylistImprovementSuggestion {
                suggestion_id: format!("dup:{}:{}", dup.position, dup_track.summary.track_id),
                kind: PlaylistImprovementKind::Duplicate,
                position: dup.position,
                duplicate_of_position: Some(keeper.position),
                raw_entry: dup.raw_entry.clone(),
                current_track: Some(dup_track.summary.clone()),
                candidate_track: Some(keeper_track.summary.clone()),
                reason,
                confidence,
            });
        }
    }

    // 2. Repair detection (broken/missing non-duplicate items)
    for item in &items {
        if duplicate_removed_positions.contains(&item.position) || item.is_healthy {
            continue;
        }
        let repair_match = match &item.track {
            Some(broken) => find_repair_for_broken(broken, &index),
            None => find_repair_for_unresolved(&item.raw_entry, &index),
        };
        if let Some((candidate, confidence, reason)) = repair_match {
            suggestions.push(PlaylistImprovementSuggestion {
                suggestion_id: format!("repair:{}:{}", item.position, candidate.summary.track_id),
                kind: PlaylistImprovementKind::Repair,
                position: item.position,
                duplicate_of_position: None,
                raw_entry: item.raw_entry.clone(),
                current_track: item.track.as_ref().map(|t| t.summary.clone()),
                candidate_track: Some(candidate.summary.clone()),
                reason,
                confidence,
            });
        }
    }

    // 3. Upgrade detection (healthy non-duplicate items with significantly higher-quality match)
    for item in &items {
        if duplicate_removed_positions.contains(&item.position) || !item.is_healthy {
            continue;
        }
        let Some(ref current) = item.track else {
            continue;
        };
        if let Some((candidate, confidence, reason)) = find_upgrade_candidate(current, &index) {
            suggestions.push(PlaylistImprovementSuggestion {
                suggestion_id: format!("upgrade:{}:{}", item.position, candidate.summary.track_id),
                kind: PlaylistImprovementKind::Upgrade,
                position: item.position,
                duplicate_of_position: None,
                raw_entry: item.raw_entry.clone(),
                current_track: Some(current.summary.clone()),
                candidate_track: Some(candidate.summary.clone()),
                reason,
                confidence,
            });
        }
    }

    suggestions.sort_by(|a, b| {
        a.position
            .cmp(&b.position)
            .then_with(|| kind_sort_rank(a.kind).cmp(&kind_sort_rank(b.kind)))
            .then_with(|| a.suggestion_id.cmp(&b.suggestion_id))
    });

    let duplicate_count = suggestions
        .iter()
        .filter(|s| s.kind == PlaylistImprovementKind::Duplicate)
        .count() as u64;
    let repair_count = suggestions
        .iter()
        .filter(|s| s.kind == PlaylistImprovementKind::Repair)
        .count() as u64;
    let upgrade_count = suggestions
        .iter()
        .filter(|s| s.kind == PlaylistImprovementKind::Upgrade)
        .count() as u64;

    Ok(PlaylistImprovementReport {
        playlist_id: id,
        playlist_name,
        total_items: items.len() as u64,
        duplicate_count,
        repair_count,
        upgrade_count,
        suggestions,
    })
}

fn kind_sort_rank(kind: PlaylistImprovementKind) -> u8 {
    match kind {
        PlaylistImprovementKind::Duplicate => 0,
        PlaylistImprovementKind::Repair => 1,
        PlaylistImprovementKind::Upgrade => 2,
    }
}

impl PlaylistImproverRepository {
    /// Pure read-only analysis of a static playlist for duplicate, repair, and upgrade suggestions.
    ///
    /// Uses smart disk verification: checks on-disk existence for `local` tracks only when
    /// their non-root parent directory exists on disk, in addition to checking `file_status`.
    pub async fn analyze_playlist_improvements(
        pool: &SqlitePool,
        playlist_id: &str,
    ) -> Result<PlaylistImprovementReport> {
        let mut conn = pool.acquire().await?;
        analyze_playlist_conn(&mut conn, playlist_id, DiskCheckMode::Smart).await
    }

    /// Pure read-only analysis with explicit control over local on-disk file existence checks.
    pub async fn analyze_playlist_improvements_with_options(
        pool: &SqlitePool,
        playlist_id: &str,
        verify_local_files_on_disk: bool,
    ) -> Result<PlaylistImprovementReport> {
        let mode = if verify_local_files_on_disk {
            DiskCheckMode::Always
        } else {
            DiskCheckMode::Never
        };
        let mut conn = pool.acquire().await?;
        analyze_playlist_conn(&mut conn, playlist_id, mode).await
    }
}
