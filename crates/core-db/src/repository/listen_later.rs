use chrono::Utc;
use core_types::{AddListenLaterRequest, ListenLaterItemDto};
use sqlx::{SqliteConnection, SqlitePool};
use uuid::Uuid;

use crate::error::{DbError, Result};
use crate::repository::tx::ImmediateTx;

#[derive(Debug, sqlx::FromRow)]
struct ListenLaterRow {
    id: String,
    source_kind: String,
    entity_type: String,
    entity_id: Option<String>,
    provider_id: Option<String>,
    external_id: Option<String>,
    title: String,
    artist_name: String,
    album_title: String,
    cover_url: Option<String>,
    track_count: Option<i64>,
    metadata_json: Option<String>,
    note: String,
    status: String,
    added_at: String,
    listened_at: Option<String>,
    promoted_entity_id: Option<String>,
}

impl From<ListenLaterRow> for ListenLaterItemDto {
    fn from(r: ListenLaterRow) -> Self {
        Self {
            id: r.id,
            source_kind: r.source_kind,
            entity_type: r.entity_type,
            entity_id: r.entity_id,
            provider_id: r.provider_id,
            external_id: r.external_id,
            title: r.title,
            artist_name: r.artist_name,
            album_title: r.album_title,
            cover_url: r.cover_url,
            track_count: r.track_count.and_then(|v| u32::try_from(v).ok()),
            metadata_json: r.metadata_json,
            note: r.note,
            status: r.status,
            added_at: r.added_at,
            listened_at: r.listened_at,
            promoted_entity_id: r.promoted_entity_id,
        }
    }
}

fn clean_opt(raw: Option<&str>) -> Option<String> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

const SELECT_COLS: &str = "\
    SELECT id, source_kind, entity_type, entity_id, provider_id, external_id, \
           title, artist_name, album_title, cover_url, track_count, metadata_json, \
           note, status, added_at, listened_at, promoted_entity_id \
    FROM listen_later_items";

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

async fn fetch_by_id_tx(conn: &mut SqliteConnection, id: &str) -> Result<ListenLaterItemDto> {
    let row: ListenLaterRow = sqlx::query_as(&format!("{SELECT_COLS} WHERE id = ?"))
        .bind(id)
        .fetch_one(&mut *conn)
        .await?;
    Ok(row.into())
}

pub struct ListenLaterRepository;

impl ListenLaterRepository {
    /// Adds a library reference or external streaming snapshot to Listen Later.
    /// Deduplicates via partial unique index; external snapshots never touch catalog tables.
    pub async fn add_to_listen_later(
        pool: &SqlitePool,
        req: &AddListenLaterRequest,
    ) -> Result<ListenLaterItemDto> {
        let source_kind = req.source_kind.trim().to_ascii_lowercase();
        let entity_type = req.entity_type.trim().to_ascii_lowercase();
        let title = req.title.trim();

        if !matches!(source_kind.as_str(), "library" | "external") {
            return Err(DbError::ConstraintViolation(format!(
                "source_kind must be 'library' or 'external' (got '{}')",
                req.source_kind
            )));
        }
        if !matches!(entity_type.as_str(), "album" | "track") {
            return Err(DbError::ConstraintViolation(format!(
                "entity_type must be 'album' or 'track' (got '{}')",
                req.entity_type
            )));
        }
        if title.is_empty() {
            return Err(DbError::ConstraintViolation(
                "Listen Later title must not be empty".into(),
            ));
        }

        let entity_id = clean_opt(req.entity_id.as_deref());
        let provider_id = clean_opt(req.provider_id.as_deref()).map(|s| s.to_ascii_lowercase());
        let external_id = clean_opt(req.external_id.as_deref());
        if source_kind == "library" && entity_id.is_none() {
            return Err(DbError::ConstraintViolation(
                "library Listen Later item requires entity_id".into(),
            ));
        }
        if source_kind == "external" && (provider_id.is_none() || external_id.is_none()) {
            return Err(DbError::ConstraintViolation(
                "external Listen Later item requires provider_id and external_id".into(),
            ));
        }

        let artist_name = req.artist_name.trim().to_string();
        let album_title = req.album_title.trim().to_string();
        let cover_url = clean_opt(req.cover_url.as_deref());
        let metadata_json = clean_opt(req.metadata_json.as_deref());
        let note = req.note.trim().to_string();
        let track_count = req.track_count.map(i64::from);

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<ListenLaterItemDto> = async {
            let existing: Option<ListenLaterRow> = if source_kind == "library" {
                sqlx::query_as(&format!(
                    "{SELECT_COLS} WHERE source_kind = 'library' AND entity_type = ? AND entity_id = ? LIMIT 1"
                ))
                .bind(&entity_type)
                .bind(entity_id.as_deref())
                .fetch_optional(tx.conn())
                .await?
            } else {
                sqlx::query_as(&format!(
                    "{SELECT_COLS} WHERE source_kind = 'external' AND provider_id = ? AND entity_type = ? AND external_id = ? LIMIT 1"
                ))
                .bind(provider_id.as_deref())
                .bind(&entity_type)
                .bind(external_id.as_deref())
                .fetch_optional(tx.conn())
                .await?
            };

            if let Some(found) = existing {
                let updated_note = if note.is_empty() { found.note } else { note };
                let updated_artist = if artist_name.is_empty() { found.artist_name } else { artist_name };
                let updated_album = if album_title.is_empty() { found.album_title } else { album_title };
                sqlx::query(
                    "UPDATE listen_later_items \
                     SET title = ?, artist_name = ?, album_title = ?, cover_url = ?, \
                         track_count = ?, metadata_json = ?, note = ?, \
                         status = 'pending', listened_at = NULL \
                     WHERE id = ?",
                )
                .bind(title)
                .bind(&updated_artist)
                .bind(&updated_album)
                .bind(cover_url.or(found.cover_url))
                .bind(track_count.or(found.track_count))
                .bind(metadata_json.or(found.metadata_json))
                .bind(&updated_note)
                .bind(&found.id)
                .execute(tx.conn())
                .await?;
                return fetch_by_id_tx(tx.conn(), &found.id).await;
            }

            let id = Uuid::new_v4().to_string();
            let added_at = Utc::now().to_rfc3339();
            sqlx::query(
                "INSERT INTO listen_later_items \
                     (id, source_kind, entity_type, entity_id, provider_id, external_id, \
                      title, artist_name, album_title, cover_url, track_count, metadata_json, \
                      note, status, added_at, listened_at, promoted_entity_id) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, NULL, NULL)",
            )
            .bind(&id)
            .bind(&source_kind)
            .bind(&entity_type)
            .bind(&entity_id)
            .bind(&provider_id)
            .bind(&external_id)
            .bind(title)
            .bind(&artist_name)
            .bind(&album_title)
            .bind(&cover_url)
            .bind(track_count)
            .bind(&metadata_json)
            .bind(&note)
            .bind(&added_at)
            .execute(tx.conn())
            .await?;

            Ok(ListenLaterItemDto {
                id,
                source_kind,
                entity_type,
                entity_id,
                provider_id,
                external_id,
                title: title.to_string(),
                artist_name,
                album_title,
                cover_url,
                track_count: req.track_count,
                metadata_json,
                note,
                status: "pending".to_string(),
                added_at,
                listened_at: None,
                promoted_entity_id: None,
            })
        }
        .await;
        finish_tx(tx, res).await
    }

    pub async fn list_listen_later(
        pool: &SqlitePool,
        status: Option<&str>,
    ) -> Result<Vec<ListenLaterItemDto>> {
        let cleaned = status.map(str::trim).filter(|s| !s.is_empty());
        let rows: Vec<ListenLaterRow> = match cleaned {
            Some(st) => {
                let norm = st.to_ascii_lowercase();
                if !matches!(norm.as_str(), "pending" | "listened") {
                    return Err(DbError::ConstraintViolation(format!(
                        "Listen Later status must be 'pending' or 'listened' (got '{st}')"
                    )));
                }
                sqlx::query_as(&format!(
                    "{SELECT_COLS} WHERE status = ? ORDER BY added_at DESC, id ASC"
                ))
                .bind(norm)
                .fetch_all(pool)
                .await?
            }
            None => {
                sqlx::query_as(&format!("{SELECT_COLS} ORDER BY added_at DESC, id ASC"))
                    .fetch_all(pool)
                    .await?
            }
        };
        Ok(rows.into_iter().map(Into::into).collect())
    }

    pub async fn get_listen_later_item(
        pool: &SqlitePool,
        id: &str,
    ) -> Result<Option<ListenLaterItemDto>> {
        let row: Option<ListenLaterRow> = sqlx::query_as(&format!("{SELECT_COLS} WHERE id = ?"))
            .bind(id.trim())
            .fetch_optional(pool)
            .await?;
        Ok(row.map(Into::into))
    }

    pub async fn mark_listen_later_status(
        pool: &SqlitePool,
        id: &str,
        status: &str,
    ) -> Result<ListenLaterItemDto> {
        let norm_status = status.trim().to_ascii_lowercase();
        if !matches!(norm_status.as_str(), "pending" | "listened") {
            return Err(DbError::ConstraintViolation(format!(
                "Listen Later status must be 'pending' or 'listened' (got '{status}')"
            )));
        }
        let item_id = id.trim();
        let listened_at = (norm_status == "listened").then(|| Utc::now().to_rfc3339());

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<ListenLaterItemDto> = async {
            let done = sqlx::query(
                "UPDATE listen_later_items SET status = ?, listened_at = ? WHERE id = ?",
            )
            .bind(&norm_status)
            .bind(&listened_at)
            .bind(item_id)
            .execute(tx.conn())
            .await?;
            if done.rows_affected() == 0 {
                return Err(DbError::NotFound(format!(
                    "Listen Later item '{item_id}' not found"
                )));
            }
            fetch_by_id_tx(tx.conn(), item_id).await
        }
        .await;
        finish_tx(tx, res).await
    }

    pub async fn update_listen_later_note(
        pool: &SqlitePool,
        id: &str,
        note: &str,
    ) -> Result<ListenLaterItemDto> {
        let item_id = id.trim();
        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<ListenLaterItemDto> = async {
            let done = sqlx::query("UPDATE listen_later_items SET note = ? WHERE id = ?")
                .bind(note.trim())
                .bind(item_id)
                .execute(tx.conn())
                .await?;
            if done.rows_affected() == 0 {
                return Err(DbError::NotFound(format!(
                    "Listen Later item '{item_id}' not found"
                )));
            }
            fetch_by_id_tx(tx.conn(), item_id).await
        }
        .await;
        finish_tx(tx, res).await
    }

    pub async fn remove_listen_later(pool: &SqlitePool, id: &str) -> Result<bool> {
        let mut tx = ImmediateTx::begin(pool).await?;
        let res = sqlx::query("DELETE FROM listen_later_items WHERE id = ?")
            .bind(id.trim())
            .execute(tx.conn())
            .await
            .map(|d| d.rows_affected() > 0)
            .map_err(DbError::from);
        finish_tx(tx, res).await
    }

    pub async fn mark_listen_later_promoted(
        pool: &SqlitePool,
        id: &str,
        promoted_entity_id: &str,
    ) -> Result<ListenLaterItemDto> {
        let item_id = id.trim();
        let eid = promoted_entity_id.trim();
        if eid.is_empty() {
            return Err(DbError::ConstraintViolation(
                "promoted_entity_id must not be empty".into(),
            ));
        }

        let mut tx = ImmediateTx::begin(pool).await?;
        let res: Result<ListenLaterItemDto> = async {
            let now = Utc::now().to_rfc3339();
            let done = sqlx::query(
                "UPDATE listen_later_items \
                 SET promoted_entity_id = ?, \
                     status = 'listened', \
                     listened_at = COALESCE(listened_at, ?) \
                 WHERE id = ?",
            )
            .bind(eid)
            .bind(&now)
            .bind(item_id)
            .execute(tx.conn())
            .await?;
            if done.rows_affected() == 0 {
                return Err(DbError::NotFound(format!(
                    "Listen Later item '{item_id}' not found"
                )));
            }
            fetch_by_id_tx(tx.conn(), item_id).await
        }
        .await;
        finish_tx(tx, res).await
    }

    /// Resolves the persisted local library entity ID (`canonical_albums.id` for `"album"` or
    /// `track_sources.id` for `"track"`) after an external catalog ingest batch completes.
    pub async fn resolve_promoted_entity_id(
        pool: &SqlitePool,
        entity_type: &str,
        provider_id: &str,
        external_id: &str,
    ) -> Result<Option<String>> {
        let prov = provider_id.trim();
        let ext = external_id.trim();
        if prov.is_empty() || ext.is_empty() {
            return Ok(None);
        }
        let row: Option<(String,)> = match entity_type.trim().to_ascii_lowercase().as_str() {
            "album" => {
                sqlx::query_as(
                    "SELECT canonical_album_id FROM album_versions \
                     WHERE LOWER(provider_id) = LOWER(?) AND external_album_id = ? LIMIT 1",
                )
                .bind(prov)
                .bind(ext)
                .fetch_optional(pool)
                .await?
            }
            "track" => {
                sqlx::query_as(
                    "SELECT id FROM track_sources \
                     WHERE LOWER(provider_id) = LOWER(?) AND external_track_id = ? LIMIT 1",
                )
                .bind(prov)
                .bind(ext)
                .fetch_optional(pool)
                .await?
            }
            _ => None,
        };
        Ok(row.map(|(id,)| id))
    }
}
