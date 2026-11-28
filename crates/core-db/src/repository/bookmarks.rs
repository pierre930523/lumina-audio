use chrono::Utc;
use core_types::{BookmarkDto, CreateBookmarkRequest, UpdateBookmarkRequest};
use sqlx::SqlitePool;
use uuid::Uuid;

use crate::error::{DbError, Result};
use crate::repository::tx::ImmediateTx;

#[derive(Debug, sqlx::FromRow)]
struct BookmarkRow {
    id: String,
    name: String,
    target_route: String,
    focus_query_json: Option<String>,
    view_state_json: Option<String>,
    sort_order: i64,
    created_at: String,
    updated_at: String,
}

impl From<BookmarkRow> for BookmarkDto {
    fn from(r: BookmarkRow) -> Self {
        Self {
            id: r.id,
            name: r.name,
            target_route: r.target_route,
            focus_query_json: r.focus_query_json,
            view_state_json: r.view_state_json,
            sort_order: r.sort_order,
            created_at: r.created_at,
            updated_at: r.updated_at,
        }
    }
}

fn clean_opt(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

pub struct BookmarkRepository;

impl BookmarkRepository {
    pub async fn list_bookmarks(pool: &SqlitePool) -> Result<Vec<BookmarkDto>> {
        let rows: Vec<BookmarkRow> = sqlx::query_as(
            "SELECT id, name, target_route, focus_query_json, view_state_json, \
                    sort_order, created_at, updated_at \
             FROM bookmarks \
             ORDER BY sort_order ASC, created_at ASC, id ASC",
        )
        .fetch_all(pool)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn create_bookmark(
        pool: &SqlitePool,
        req: &CreateBookmarkRequest,
    ) -> Result<BookmarkDto> {
        let name = req.name.trim();
        let target_route = req.target_route.trim();
        if name.is_empty() {
            return Err(DbError::ConstraintViolation(
                "Bookmark name must not be empty".into(),
            ));
        }
        if target_route.is_empty() {
            return Err(DbError::ConstraintViolation(
                "Bookmark target_route must not be empty".into(),
            ));
        }

        let focus_query_json = clean_opt(req.focus_query_json.as_deref());
        let view_state_json = clean_opt(req.view_state_json.as_deref());

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<BookmarkDto> = async {
            let sort_order = match req.sort_order {
                Some(v) => v,
                None => {
                    let (next,): (i64,) = sqlx::query_as(
                        "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM bookmarks",
                    )
                    .fetch_one(tx.conn())
                    .await?;
                    next
                }
            };
            let id = Uuid::new_v4().to_string();
            let now = Utc::now().to_rfc3339();
            sqlx::query(
                "INSERT INTO bookmarks \
                     (id, name, target_route, focus_query_json, view_state_json, sort_order, created_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(name)
            .bind(target_route)
            .bind(&focus_query_json)
            .bind(&view_state_json)
            .bind(sort_order)
            .bind(&now)
            .bind(&now)
            .execute(tx.conn())
            .await?;

            Ok(BookmarkDto {
                id,
                name: name.to_string(),
                target_route: target_route.to_string(),
                focus_query_json,
                view_state_json,
                sort_order,
                created_at: now.clone(),
                updated_at: now,
            })
        }
        .await;

        match res {
            Ok(created) => {
                tx.commit().await?;
                Ok(created)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    pub async fn update_bookmark(
        pool: &SqlitePool,
        req: &UpdateBookmarkRequest,
    ) -> Result<BookmarkDto> {
        let id = req.id.trim();
        if id.is_empty() {
            return Err(DbError::NotFound("Bookmark id must not be empty".into()));
        }

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<BookmarkDto> = async {
            let existing: BookmarkRow = sqlx::query_as(
                "SELECT id, name, target_route, focus_query_json, view_state_json, \
                        sort_order, created_at, updated_at \
                 FROM bookmarks WHERE id = ?",
            )
            .bind(id)
            .fetch_optional(tx.conn())
            .await?
            .ok_or_else(|| DbError::NotFound(format!("Bookmark '{id}' not found")))?;

            let name = match req.name.as_deref() {
                Some(raw) => {
                    let trimmed = raw.trim();
                    if trimmed.is_empty() {
                        return Err(DbError::ConstraintViolation(
                            "Bookmark name must not be empty".into(),
                        ));
                    }
                    trimmed.to_string()
                }
                None => existing.name,
            };

            let target_route = match req.target_route.as_deref() {
                Some(raw) => {
                    let trimmed = raw.trim();
                    if trimmed.is_empty() {
                        return Err(DbError::ConstraintViolation(
                            "Bookmark target_route must not be empty".into(),
                        ));
                    }
                    trimmed.to_string()
                }
                None => existing.target_route,
            };

            let focus_query_json = if req.clear_focus_query {
                None
            } else if req.focus_query_json.is_some() {
                clean_opt(req.focus_query_json.as_deref())
            } else {
                existing.focus_query_json
            };

            let view_state_json = if req.clear_view_state {
                None
            } else if req.view_state_json.is_some() {
                clean_opt(req.view_state_json.as_deref())
            } else {
                existing.view_state_json
            };

            let sort_order = req.sort_order.unwrap_or(existing.sort_order);
            let updated_at = Utc::now().to_rfc3339();

            sqlx::query(
                "UPDATE bookmarks \
                 SET name = ?, target_route = ?, focus_query_json = ?, view_state_json = ?, \
                     sort_order = ?, updated_at = ? \
                 WHERE id = ?",
            )
            .bind(&name)
            .bind(&target_route)
            .bind(&focus_query_json)
            .bind(&view_state_json)
            .bind(sort_order)
            .bind(&updated_at)
            .bind(id)
            .execute(tx.conn())
            .await?;

            Ok(BookmarkDto {
                id: existing.id,
                name,
                target_route,
                focus_query_json,
                view_state_json,
                sort_order,
                created_at: existing.created_at,
                updated_at,
            })
        }
        .await;

        match res {
            Ok(updated) => {
                tx.commit().await?;
                Ok(updated)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    pub async fn delete_bookmark(pool: &SqlitePool, id: &str) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = sqlx::query("DELETE FROM bookmarks WHERE id = ?")
            .bind(id.trim())
            .execute(tx.conn())
            .await
            .map(|d| d.rows_affected() > 0)
            .map_err(DbError::from);
        match res {
            Ok(deleted) => {
                tx.commit().await?;
                Ok(deleted)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    pub async fn reorder_bookmarks(
        pool: &SqlitePool,
        ordered_ids: &[String],
    ) -> Result<Vec<BookmarkDto>> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let now = Utc::now().to_rfc3339();
        let res: Result<()> = async {
            for (idx, raw_id) in ordered_ids.iter().enumerate() {
                let id = raw_id.trim();
                if id.is_empty() {
                    continue;
                }
                sqlx::query("UPDATE bookmarks SET sort_order = ?, updated_at = ? WHERE id = ?")
                    .bind(idx as i64)
                    .bind(&now)
                    .bind(id)
                    .execute(tx.conn())
                    .await?;
            }
            Ok(())
        }
        .await;

        match res {
            Ok(()) => {
                tx.commit().await?;
                Self::list_bookmarks(pool).await
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }
}
