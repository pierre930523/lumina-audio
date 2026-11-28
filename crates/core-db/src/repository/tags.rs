use std::collections::{HashMap, HashSet};

use chrono::Utc;
use core_types::{
    BatchTagItemsRequest, BatchTagItemsResponse, CreateTagRequest, TagBatchOp, TagEntityType,
    TagLinkRequest, TagSummary, UpdateTagRequest,
};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};
use uuid::Uuid;

use crate::error::{DbError, Result};
use crate::repository::tx::ImmediateTx;

#[derive(Debug, sqlx::FromRow)]
struct TagRow {
    id: String,
    name: String,
    normalized_name: String,
    color: Option<String>,
    created_at: String,
    updated_at: String,
}

fn normalize_tag_name(raw: &str) -> Result<(String, String)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(DbError::ConstraintViolation(
            "Tag name must not be empty".into(),
        ));
    }
    Ok((trimmed.to_string(), trimmed.to_lowercase()))
}

fn clean_color(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn dedup_non_empty(values: &[String]) -> Vec<String> {
    let mut seen = HashSet::with_capacity(values.len());
    values
        .iter()
        .map(|v| v.trim())
        .filter(|v| !v.is_empty() && seen.insert((*v).to_string()))
        .map(str::to_string)
        .collect()
}

async fn finish_tx<T>(tx: ImmediateTx, res: Result<T>) -> Result<T> {
    match res {
        Ok(val) => {
            tx.commit().await?;
            Ok(val)
        }
        Err(err) => {
            let _ = tx.rollback().await;
            Err(err)
        }
    }
}

async fn ensure_tag_exists_tx(conn: &mut SqliteConnection, tag_id: &str) -> Result<()> {
    let exists: Option<(i64,)> = sqlx::query_as("SELECT 1 FROM tags WHERE id = ? LIMIT 1")
        .bind(tag_id)
        .fetch_optional(&mut *conn)
        .await?;
    exists
        .map(|_| ())
        .ok_or_else(|| DbError::NotFound(format!("Tag '{tag_id}' not found")))
}

async fn ensure_unique_name_tx(
    conn: &mut SqliteConnection,
    display_name: &str,
    normalized_name: &str,
    exclude_id: Option<&str>,
) -> Result<()> {
    let dup: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM tags WHERE normalized_name = ? AND (? IS NULL OR id != ?) LIMIT 1",
    )
    .bind(normalized_name)
    .bind(exclude_id)
    .bind(exclude_id)
    .fetch_optional(&mut *conn)
    .await?;
    if dup.is_some() {
        return Err(DbError::ConstraintViolation(format!(
            "Tag with name '{display_name}' already exists"
        )));
    }
    Ok(())
}

async fn fetch_tag_rows_conn(
    conn: &mut SqliteConnection,
    filter_ids: Option<&[String]>,
) -> Result<Vec<TagRow>> {
    match filter_ids {
        None => Ok(sqlx::query_as(
            "SELECT id, name, normalized_name, color, created_at, updated_at \
             FROM tags ORDER BY normalized_name ASC, id ASC",
        )
        .fetch_all(&mut *conn)
        .await?),
        Some([]) => Ok(Vec::new()),
        Some(ids) => {
            let mut rows = Vec::with_capacity(ids.len());
            for chunk in ids.chunks(500) {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
                    "SELECT id, name, normalized_name, color, created_at, updated_at \
                     FROM tags WHERE id IN (",
                );
                let mut sep = qb.separated(", ");
                for id in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(")");
                rows.extend(qb.build_query_as::<TagRow>().fetch_all(&mut *conn).await?);
            }
            rows.sort_by(|a, b| {
                a.normalized_name
                    .cmp(&b.normalized_name)
                    .then(a.id.cmp(&b.id))
            });
            Ok(rows)
        }
    }
}

async fn load_tag_summaries_conn(
    conn: &mut SqliteConnection,
    filter_ids: Option<&[String]>,
) -> Result<Vec<TagSummary>> {
    let tag_rows = fetch_tag_rows_conn(conn, filter_ids).await?;
    if tag_rows.is_empty() {
        return Ok(Vec::new());
    }

    let link_rows: Vec<(String, String)> = sqlx::query_as(
        "SELECT parent_tag_id, child_tag_id FROM tag_links \
         ORDER BY parent_tag_id ASC, child_tag_id ASC",
    )
    .fetch_all(&mut *conn)
    .await?;

    let mut parents_by_child: HashMap<String, Vec<String>> = HashMap::new();
    let mut children_by_parent: HashMap<String, Vec<String>> = HashMap::new();
    for (p, c) in link_rows {
        parents_by_child
            .entry(c.clone())
            .or_default()
            .push(p.clone());
        children_by_parent.entry(p).or_default().push(c);
    }

    let direct_counts: HashMap<String, u64> = sqlx::query_as::<_, (String, i64)>(
        "SELECT tag_id, COUNT(*) FROM tag_items GROUP BY tag_id",
    )
    .fetch_all(&mut *conn)
    .await?
    .into_iter()
    .map(|(id, c)| (id, c.max(0) as u64))
    .collect();

    let recursive_counts: HashMap<String, u64> = sqlx::query_as::<_, (String, i64)>(
        "WITH RECURSIVE tag_closure(root_id, tag_id) AS ( \
             SELECT id, id FROM tags \
             UNION \
             SELECT tc.root_id, tl.child_tag_id \
             FROM tag_closure tc \
             JOIN tag_links tl ON tl.parent_tag_id = tc.tag_id \
         ), \
         distinct_items(root_id, entity_type, entity_id) AS ( \
             SELECT DISTINCT tc.root_id, ti.entity_type, ti.entity_id \
             FROM tag_closure tc \
             JOIN tag_items ti ON ti.tag_id = tc.tag_id \
         ) \
         SELECT root_id, COUNT(*) FROM distinct_items GROUP BY root_id",
    )
    .fetch_all(&mut *conn)
    .await?
    .into_iter()
    .map(|(id, c)| (id, c.max(0) as u64))
    .collect();

    Ok(tag_rows
        .into_iter()
        .map(|row| TagSummary {
            parent_ids: parents_by_child.remove(&row.id).unwrap_or_default(),
            child_ids: children_by_parent.remove(&row.id).unwrap_or_default(),
            direct_item_count: direct_counts.get(&row.id).copied().unwrap_or(0),
            recursive_item_count: recursive_counts.get(&row.id).copied().unwrap_or(0),
            id: row.id,
            name: row.name,
            color: row.color,
            created_at: row.created_at,
            updated_at: row.updated_at,
        })
        .collect())
}

pub struct TagRepository;

impl TagRepository {
    pub async fn list_tags(pool: &SqlitePool) -> Result<Vec<TagSummary>> {
        let mut conn = pool.acquire().await?;
        load_tag_summaries_conn(&mut conn, None).await
    }

    pub async fn create_tag(pool: &SqlitePool, req: &CreateTagRequest) -> Result<TagSummary> {
        let (name, normalized_name) = normalize_tag_name(&req.name)?;
        let color = clean_color(req.color.as_deref());
        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<TagSummary> = async {
            ensure_unique_name_tx(tx.conn(), &name, &normalized_name, None).await?;
            let id = Uuid::new_v4().to_string();
            let now = Utc::now().to_rfc3339();
            sqlx::query(
                "INSERT INTO tags (id, name, normalized_name, color, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(&name)
            .bind(&normalized_name)
            .bind(&color)
            .bind(&now)
            .bind(&now)
            .execute(tx.conn())
            .await?;

            Ok(TagSummary {
                id,
                name,
                color,
                parent_ids: Vec::new(),
                child_ids: Vec::new(),
                direct_item_count: 0,
                recursive_item_count: 0,
                created_at: now.clone(),
                updated_at: now,
            })
        }
        .await;
        finish_tx(tx, res).await
    }

    pub async fn update_tag(pool: &SqlitePool, req: &UpdateTagRequest) -> Result<TagSummary> {
        let tag_id = req.id.trim();
        if tag_id.is_empty() {
            return Err(DbError::NotFound("Tag id must not be empty".into()));
        }
        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<TagSummary> = async {
            let existing: TagRow = sqlx::query_as(
                "SELECT id, name, normalized_name, color, created_at, updated_at \
                 FROM tags WHERE id = ?",
            )
            .bind(tag_id)
            .fetch_optional(tx.conn())
            .await?
            .ok_or_else(|| DbError::NotFound(format!("Tag '{tag_id}' not found")))?;

            let (new_name, new_norm) = match req.name.as_deref() {
                Some(raw) => {
                    let (trimmed, norm) = normalize_tag_name(raw)?;
                    ensure_unique_name_tx(tx.conn(), &trimmed, &norm, Some(tag_id)).await?;
                    (trimmed, norm)
                }
                None => (existing.name, existing.normalized_name),
            };
            let new_color = if req.clear_color {
                None
            } else if req.color.is_some() {
                clean_color(req.color.as_deref())
            } else {
                existing.color
            };

            let updated_at = Utc::now().to_rfc3339();
            sqlx::query(
                "UPDATE tags SET name = ?, normalized_name = ?, color = ?, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&new_name)
            .bind(&new_norm)
            .bind(&new_color)
            .bind(&updated_at)
            .bind(tag_id)
            .execute(tx.conn())
            .await?;

            let filter = [tag_id.to_string()];
            load_tag_summaries_conn(tx.conn(), Some(&filter))
                .await?
                .pop()
                .ok_or_else(|| DbError::NotFound(format!("Tag '{tag_id}' not found")))
        }
        .await;
        finish_tx(tx, res).await
    }

    pub async fn delete_tag(pool: &SqlitePool, tag_id: &str) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = sqlx::query("DELETE FROM tags WHERE id = ?")
            .bind(tag_id)
            .execute(tx.conn())
            .await
            .map(|done| done.rows_affected() > 0)
            .map_err(DbError::from);
        finish_tx(tx, res).await
    }

    pub async fn link_tag_parent(pool: &SqlitePool, req: &TagLinkRequest) -> Result<()> {
        let parent_id = req.parent_tag_id.trim();
        let child_id = req.child_tag_id.trim();
        if parent_id == child_id {
            return Err(DbError::ConstraintViolation(
                "TagCycleDetected: cannot link a tag as its own parent".into(),
            ));
        }

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<()> = async {
            ensure_tag_exists_tx(tx.conn(), parent_id).await?;
            ensure_tag_exists_tx(tx.conn(), child_id).await?;

            let cycle_hit: Option<(i64,)> = sqlx::query_as(
                "WITH RECURSIVE descendants(id) AS ( \
                     SELECT ? \
                     UNION \
                     SELECT tl.child_tag_id \
                     FROM tag_links tl \
                     JOIN descendants d ON tl.parent_tag_id = d.id \
                 ) \
                 SELECT 1 FROM descendants WHERE id = ? LIMIT 1",
            )
            .bind(child_id)
            .bind(parent_id)
            .fetch_optional(tx.conn())
            .await?;
            if cycle_hit.is_some() {
                return Err(DbError::ConstraintViolation(format!(
                    "TagCycleDetected: linking '{parent_id}' -> '{child_id}' creates a cycle"
                )));
            }

            let now = Utc::now().to_rfc3339();
            sqlx::query(
                "INSERT OR IGNORE INTO tag_links (parent_tag_id, child_tag_id, created_at) \
                 VALUES (?, ?, ?)",
            )
            .bind(parent_id)
            .bind(child_id)
            .bind(&now)
            .execute(tx.conn())
            .await?;
            Ok(())
        }
        .await;
        finish_tx(tx, res).await
    }

    pub async fn unlink_tag_parent(pool: &SqlitePool, req: &TagLinkRequest) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = sqlx::query("DELETE FROM tag_links WHERE parent_tag_id = ? AND child_tag_id = ?")
            .bind(req.parent_tag_id.trim())
            .bind(req.child_tag_id.trim())
            .execute(tx.conn())
            .await
            .map(|done| done.rows_affected() > 0)
            .map_err(DbError::from);
        finish_tx(tx, res).await
    }

    pub async fn batch_update_tag_items(
        pool: &SqlitePool,
        req: &BatchTagItemsRequest,
    ) -> Result<BatchTagItemsResponse> {
        let tag_ids = dedup_non_empty(&req.tag_ids);
        let entity_ids = dedup_non_empty(&req.entity_ids);
        if tag_ids.is_empty() || entity_ids.is_empty() {
            return Ok(BatchTagItemsResponse { affected: 0 });
        }
        let entity_type = req.entity_type.as_str();
        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<u64> = async {
            let mut affected = 0u64;
            match req.op {
                TagBatchOp::Add => {
                    for tag_id in &tag_ids {
                        ensure_tag_exists_tx(tx.conn(), tag_id).await?;
                    }
                    let now = Utc::now().to_rfc3339();
                    for tag_id in &tag_ids {
                        for entity_id in &entity_ids {
                            affected += sqlx::query(
                                "INSERT OR IGNORE INTO tag_items \
                                     (tag_id, entity_type, entity_id, created_at) \
                                 VALUES (?, ?, ?, ?)",
                            )
                            .bind(tag_id)
                            .bind(entity_type)
                            .bind(entity_id)
                            .bind(&now)
                            .execute(tx.conn())
                            .await?
                            .rows_affected();
                        }
                    }
                }
                TagBatchOp::Remove => {
                    for tag_id in &tag_ids {
                        for chunk in entity_ids.chunks(500) {
                            let mut qb: QueryBuilder<'_, Sqlite> =
                                QueryBuilder::new("DELETE FROM tag_items WHERE tag_id = ");
                            qb.push_bind(tag_id)
                                .push(" AND entity_type = ")
                                .push_bind(entity_type)
                                .push(" AND entity_id IN (");
                            let mut sep = qb.separated(", ");
                            for entity_id in chunk {
                                sep.push_bind(entity_id);
                            }
                            sep.push_unseparated(")");
                            affected += qb.build().execute(tx.conn()).await?.rows_affected();
                        }
                    }
                }
            }
            Ok(affected)
        }
        .await;
        Ok(BatchTagItemsResponse {
            affected: finish_tx(tx, res).await?,
        })
    }

    pub async fn get_entity_tags(
        pool: &SqlitePool,
        entity_type: TagEntityType,
        entity_id: &str,
    ) -> Result<Vec<TagSummary>> {
        let mut conn = pool.acquire().await?;
        let tag_ids: Vec<String> = sqlx::query_as::<_, (String,)>(
            "SELECT tag_id FROM tag_items WHERE entity_type = ? AND entity_id = ?",
        )
        .bind(entity_type.as_str())
        .bind(entity_id)
        .fetch_all(&mut *conn)
        .await?
        .into_iter()
        .map(|(id,)| id)
        .collect();
        if tag_ids.is_empty() {
            return Ok(Vec::new());
        }
        load_tag_summaries_conn(&mut conn, Some(&tag_ids)).await
    }

    pub async fn expand_tag_subtree_ids(
        pool: &SqlitePool,
        root_tag_id: &str,
    ) -> Result<Vec<String>> {
        let rows: Vec<(String,)> = sqlx::query_as(
            "WITH RECURSIVE subtree(id) AS ( \
                 SELECT id FROM tags WHERE id = ? \
                 UNION \
                 SELECT tl.child_tag_id \
                 FROM tag_links tl \
                 JOIN subtree s ON tl.parent_tag_id = s.id \
             ) \
             SELECT id FROM subtree ORDER BY id ASC",
        )
        .bind(root_tag_id.trim())
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }
}
