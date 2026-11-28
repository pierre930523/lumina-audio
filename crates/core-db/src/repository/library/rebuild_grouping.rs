use sqlx::{QueryBuilder, Sqlite, SqliteConnection};
use std::collections::{HashMap, HashSet};

use super::LibraryRepository;
use crate::error::Result;
use crate::search::sync_single_album_fts_visibility_conn;

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct LockedPrimaryBinding {
    pub old_album_id: String,
    pub primary_version_id: String,
    pub provider_id: String,
    pub external_album_id: String,
    pub track_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct HiddenVersionBinding {
    pub version_id: String,
    pub provider_id: String,
    pub external_album_id: String,
    pub track_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ManualGroupVersionBinding {
    pub version_id: String,
    pub provider_id: String,
    pub external_album_id: String,
    pub old_manual_group_id: String,
    pub track_ids: Vec<String>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ManualTrackBinding {
    pub track_source_id: String,
    pub manual_version_id: Option<String>,
    pub manual_disc_number: Option<i64>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct AlbumGroupingBindingsSnapshot {
    #[serde(default)]
    pub locked_primaries: Vec<LockedPrimaryBinding>,
    #[serde(default)]
    pub hidden_versions: Vec<HiddenVersionBinding>,
    #[serde(default)]
    pub manual_group_versions: Vec<ManualGroupVersionBinding>,
    #[serde(default)]
    pub manual_tracks: Vec<ManualTrackBinding>,
}

impl AlbumGroupingBindingsSnapshot {
    pub fn is_empty(&self) -> bool {
        self.locked_primaries.is_empty()
            && self.hidden_versions.is_empty()
            && self.manual_group_versions.is_empty()
            && self.manual_tracks.is_empty()
    }
}

async fn tracks_for_version_tx(
    conn: &mut SqliteConnection,
    version_id: &str,
) -> Result<Vec<String>> {
    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT id FROM track_sources WHERE version_id = ? ORDER BY id ASC")
            .bind(version_id)
            .fetch_all(&mut *conn)
            .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
}

async fn resolve_majority_version_and_album_tx(
    conn: &mut SqliteConnection,
    track_ids: &[String],
) -> Result<Option<(String, String)>> {
    if track_ids.is_empty() {
        return Ok(None);
    }
    let mut counts: HashMap<(String, String), usize> = HashMap::new();
    for chunk in track_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT av.id, av.canonical_album_id \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             WHERE ts.file_status = 'present' AND ts.id IN (",
        );
        let mut sep = qb.separated(", ");
        for tid in chunk {
            sep.push_bind(tid);
        }
        sep.push_unseparated(")");
        let rows: Vec<(String, String)> = qb.build_query_as().fetch_all(&mut *conn).await?;
        for pair in rows {
            *counts.entry(pair).or_insert(0) += 1;
        }
    }
    Ok(counts
        .into_iter()
        .max_by(|(a, ca), (b, cb)| ca.cmp(cb).then_with(|| b.cmp(a)))
        .map(|(pair, _)| pair))
}

async fn find_version_by_provider_ext_tx(
    conn: &mut SqliteConnection,
    provider_id: &str,
    external_album_id: &str,
) -> Result<Option<(String, String)>> {
    let row: Option<(String, String)> = sqlx::query_as(
        "SELECT id, canonical_album_id FROM album_versions \
         WHERE provider_id = ? AND external_album_id = ? LIMIT 1",
    )
    .bind(provider_id)
    .bind(external_album_id)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(row)
}

/// Captures Step 2 manual grouping, primary locks, hidden flags, and track-level locks before Force Rebuild.
pub(super) async fn snapshot_album_grouping_bindings_tx(
    conn: &mut SqliteConnection,
) -> Result<AlbumGroupingBindingsSnapshot> {
    let mut snap = AlbumGroupingBindingsSnapshot::default();

    let locked_rows: Vec<(String, String, String, String)> = sqlx::query_as(
        "SELECT ca.id, av.id, av.provider_id, av.external_album_id \
         FROM canonical_albums ca \
         JOIN album_versions av ON av.id = ca.primary_version_id \
         WHERE ca.is_primary_locked = 1",
    )
    .fetch_all(&mut *conn)
    .await?;
    for (old_album_id, primary_version_id, provider_id, external_album_id) in locked_rows {
        let track_ids = tracks_for_version_tx(conn, &primary_version_id).await?;
        snap.locked_primaries.push(LockedPrimaryBinding {
            old_album_id,
            primary_version_id,
            provider_id,
            external_album_id,
            track_ids,
        });
    }

    let hidden_rows: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT id, provider_id, external_album_id FROM album_versions WHERE is_hidden = 1",
    )
    .fetch_all(&mut *conn)
    .await?;
    for (version_id, provider_id, external_album_id) in hidden_rows {
        let track_ids = tracks_for_version_tx(conn, &version_id).await?;
        snap.hidden_versions.push(HiddenVersionBinding {
            version_id,
            provider_id,
            external_album_id,
            track_ids,
        });
    }

    let manual_group_rows: Vec<(String, String, String, String)> = sqlx::query_as(
        "SELECT id, provider_id, external_album_id, manual_group_id \
         FROM album_versions WHERE manual_group_id IS NOT NULL",
    )
    .fetch_all(&mut *conn)
    .await?;
    for (version_id, provider_id, external_album_id, old_manual_group_id) in manual_group_rows {
        let track_ids = tracks_for_version_tx(conn, &version_id).await?;
        snap.manual_group_versions.push(ManualGroupVersionBinding {
            version_id,
            provider_id,
            external_album_id,
            old_manual_group_id,
            track_ids,
        });
    }

    let manual_track_rows: Vec<(String, Option<String>, Option<i64>)> = sqlx::query_as(
        "SELECT id, manual_version_id, manual_disc_number FROM track_sources \
         WHERE manual_version_id IS NOT NULL OR manual_disc_number IS NOT NULL",
    )
    .fetch_all(&mut *conn)
    .await?;
    for (track_source_id, manual_version_id, manual_disc_number) in manual_track_rows {
        snap.manual_tracks.push(ManualTrackBinding {
            track_source_id,
            manual_version_id,
            manual_disc_number,
        });
    }

    Ok(snap)
}

/// Restores Step 2 manual grouping, primary locks, hidden flags, and track-level locks after Force Rebuild
/// and refreshes `quality_score` / `primary_version_id` across surviving album groups.
pub(super) async fn restore_album_grouping_bindings_tx(
    conn: &mut SqliteConnection,
    snap: &AlbumGroupingBindingsSnapshot,
) -> Result<usize> {
    let mut restored = 0usize;
    let mut touched_groups: HashSet<String> = HashSet::new();

    for mt in &snap.manual_tracks {
        let valid_ver = if let Some(ref mvid) = mt.manual_version_id {
            let exists: Option<(String,)> =
                sqlx::query_as("SELECT id FROM album_versions WHERE id = ?")
                    .bind(mvid)
                    .fetch_optional(&mut *conn)
                    .await?;
            exists.map(|(id,)| id)
        } else {
            None
        };
        if valid_ver.is_some() || mt.manual_disc_number.is_some() {
            let res = sqlx::query(
                "UPDATE track_sources \
                 SET version_id = COALESCE(?, version_id), \
                     manual_version_id = COALESCE(?, manual_version_id), \
                     manual_disc_number = COALESCE(?, manual_disc_number), \
                     disc_number = COALESCE(?, disc_number) \
                 WHERE id = ?",
            )
            .bind(&valid_ver)
            .bind(&valid_ver)
            .bind(mt.manual_disc_number)
            .bind(mt.manual_disc_number)
            .bind(&mt.track_source_id)
            .execute(&mut *conn)
            .await?;
            if res.rows_affected() > 0 {
                restored += 1;
            }
        }
    }

    for hv in &snap.hidden_versions {
        let target = find_version_by_provider_ext_tx(conn, &hv.provider_id, &hv.external_album_id)
            .await?
            .or(resolve_majority_version_and_album_tx(conn, &hv.track_ids).await?);
        if let Some((vid, gid)) = target {
            sqlx::query("UPDATE album_versions SET is_hidden = 1 WHERE id = ?")
                .bind(&vid)
                .execute(&mut *conn)
                .await?;
            touched_groups.insert(gid);
            restored += 1;
        }
    }

    for mg in &snap.manual_group_versions {
        let target = find_version_by_provider_ext_tx(conn, &mg.provider_id, &mg.external_album_id)
            .await?
            .or(resolve_majority_version_and_album_tx(conn, &mg.track_ids).await?);
        if let Some((vid, cur_gid)) = target {
            let group_exists: Option<(String,)> =
                sqlx::query_as("SELECT id FROM canonical_albums WHERE id = ?")
                    .bind(&mg.old_manual_group_id)
                    .fetch_optional(&mut *conn)
                    .await?;
            let lock_gid = group_exists.map(|(id,)| id).unwrap_or(cur_gid);
            sqlx::query(
                "UPDATE album_versions SET canonical_album_id = ?, manual_group_id = ? WHERE id = ?",
            )
            .bind(&lock_gid)
            .bind(&lock_gid)
            .bind(&vid)
            .execute(&mut *conn)
            .await?;
            touched_groups.insert(lock_gid);
            restored += 1;
        }
    }

    for lp in &snap.locked_primaries {
        let target = find_version_by_provider_ext_tx(conn, &lp.provider_id, &lp.external_album_id)
            .await?
            .or(resolve_majority_version_and_album_tx(conn, &lp.track_ids).await?);
        if let Some((vid, gid)) = target {
            sqlx::query(
                "UPDATE canonical_albums SET primary_version_id = ?, is_primary_locked = 1 WHERE id = ?",
            )
            .bind(&vid)
            .bind(&gid)
            .execute(&mut *conn)
            .await?;
            touched_groups.insert(gid);
            restored += 1;
        }
    }

    // Ensure every surviving album with present tracks has fresh scores & primary_version_id
    let all_groups: Vec<(String,)> = sqlx::query_as(
        "SELECT DISTINCT av.canonical_album_id \
         FROM album_versions av \
         JOIN track_sources ts ON ts.version_id = av.id \
         WHERE ts.file_status = 'present'",
    )
    .fetch_all(&mut *conn)
    .await?;
    for (gid,) in all_groups {
        touched_groups.insert(gid);
    }

    for gid in touched_groups {
        let _ = LibraryRepository::resolve_primary_version_tx(conn, &gid).await?;
        sync_single_album_fts_visibility_conn(conn, &gid).await?;
    }

    Ok(restored)
}
