use std::collections::HashMap;

use sqlx::{QueryBuilder, Sqlite, SqliteConnection};

use crate::error::Result;

/// Remaps library album `listen_later_items` and preserves non-zero album `preference`
/// when `source_album_id` is merged or moved into `target_album_id`.
pub(super) async fn migrate_album_step4_refs_tx(
    conn: &mut SqliteConnection,
    target_album_id: &str,
    source_album_id: &str,
) -> Result<()> {
    if target_album_id == source_album_id {
        return Ok(());
    }

    // Adopt source album's non-zero preference if target album is currently neutral (0)
    sqlx::query(
        "UPDATE canonical_albums \
         SET preference = COALESCE( \
             (SELECT s.preference FROM canonical_albums s WHERE s.id = ? AND s.preference != 0), \
             preference \
         ) \
         WHERE id = ? AND preference = 0",
    )
    .bind(source_album_id)
    .bind(target_album_id)
    .execute(&mut *conn)
    .await?;

    // Conflict-safe remap of library album listen_later_items (respects idx_listen_later_lib_unique)
    remap_listen_later_album_id_tx(conn, target_album_id, source_album_id).await?;
    Ok(())
}

/// Remaps `listen_later_items.entity_id` for `source_kind = 'library' AND entity_type = 'album'`
/// from `old_album_id` to `new_album_id`, deleting any duplicate that would collide with the
/// partial unique index `idx_listen_later_lib_unique`.
pub(super) async fn remap_listen_later_album_id_tx(
    conn: &mut SqliteConnection,
    new_album_id: &str,
    old_album_id: &str,
) -> Result<()> {
    if new_album_id == old_album_id {
        return Ok(());
    }

    let target_exists: Option<(i32,)> = sqlx::query_as(
        "SELECT 1 FROM listen_later_items \
         WHERE source_kind = 'library' AND entity_type = 'album' AND entity_id = ? LIMIT 1",
    )
    .bind(new_album_id)
    .fetch_optional(&mut *conn)
    .await?;

    if target_exists.is_some() {
        sqlx::query(
            "DELETE FROM listen_later_items \
             WHERE source_kind = 'library' AND entity_type = 'album' AND entity_id = ?",
        )
        .bind(old_album_id)
        .execute(&mut *conn)
        .await?;
    } else {
        sqlx::query(
            "UPDATE listen_later_items \
             SET entity_id = ? \
             WHERE source_kind = 'library' AND entity_type = 'album' AND entity_id = ?",
        )
        .bind(new_album_id)
        .bind(old_album_id)
        .execute(&mut *conn)
        .await?;
    }

    Ok(())
}

/// Snapshots non-zero `canonical_albums.preference` for the given `album_ids` before a force rebuild.
pub(super) async fn snapshot_album_preferences_tx(
    conn: &mut SqliteConnection,
    album_ids: &[String],
) -> Result<HashMap<String, i32>> {
    let mut out = HashMap::new();
    for chunk in album_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT id, preference FROM canonical_albums WHERE preference != 0 AND id IN (",
        );
        let mut sep = qb.separated(", ");
        for aid in chunk {
            sep.push_bind(aid);
        }
        sep.push_unseparated(")");
        let rows: Vec<(String, i32)> = qb.build_query_as().fetch_all(&mut *conn).await?;
        for (aid, pref) in rows {
            out.insert(aid, pref);
        }
    }
    Ok(out)
}

/// Restores a snapshotted album preference onto `new_album_id` if `new_album_id` is neutral (0).
pub(super) async fn restore_album_preference_tx(
    conn: &mut SqliteConnection,
    new_album_id: &str,
    preference: i32,
) -> Result<()> {
    if preference == 0 {
        return Ok(());
    }
    sqlx::query("UPDATE canonical_albums SET preference = ? WHERE id = ? AND preference = 0")
        .bind(preference)
        .bind(new_album_id)
        .execute(&mut *conn)
        .await?;
    Ok(())
}
