use std::collections::{HashMap, HashSet};

use chrono::Utc;
use core_types::{
    AlbumAssetKind, AlbumAssetRecord, AlbumAssetRole, AlbumAssetSourceKind, AlbumAssetsResponse,
};
use sqlx::{FromRow, SqliteConnection, SqlitePool};
use uuid::Uuid;

use crate::error::{DbError, Result};
use crate::write_coordinator::DbWriteCoordinator;

/// Input descriptor for upserting a metadata-only album asset (file or embedded picture).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewAlbumAsset {
    pub asset_kind: AlbumAssetKind,
    pub source_kind: AlbumAssetSourceKind,
    pub role: AlbumAssetRole,
    pub file_path: Option<String>,
    pub embedded_track_id: Option<String>,
    pub embedded_pic_index: Option<i64>,
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub file_size: Option<u64>,
    pub display_name: String,
    pub sort_order: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum AssetIdentityKey {
    File(String),
    Embedded(String, i64),
}

#[derive(Debug, FromRow)]
struct AlbumAssetRow {
    id: String,
    album_version_id: String,
    asset_kind: String,
    source_kind: String,
    role: String,
    file_path: Option<String>,
    embedded_track_id: Option<String>,
    embedded_pic_index: Option<i64>,
    mime_type: String,
    width: Option<i64>,
    height: Option<i64>,
    file_size: Option<i64>,
    display_name: String,
    sort_order: i64,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, FromRow)]
struct ExistingIdentityRow {
    id: String,
    source_kind: String,
    file_path: Option<String>,
    embedded_track_id: Option<String>,
    embedded_pic_index: Option<i64>,
}

const SELECT_ASSET_COLS: &str = "id, album_version_id, asset_kind, source_kind, role, \
    file_path, embedded_track_id, embedded_pic_index, mime_type, width, height, file_size, \
    display_name, sort_order, created_at, updated_at";

impl AlbumAssetRow {
    fn into_record(self) -> Result<AlbumAssetRecord> {
        let parse_err =
            |e: core_types::ValidationError| DbError::ConstraintViolation(e.to_string());
        Ok(AlbumAssetRecord {
            id: self.id,
            album_version_id: self.album_version_id,
            asset_kind: self.asset_kind.parse().map_err(parse_err)?,
            source_kind: self.source_kind.parse().map_err(parse_err)?,
            role: self.role.parse().map_err(parse_err)?,
            file_path: self.file_path,
            embedded_track_id: self.embedded_track_id,
            embedded_pic_index: self.embedded_pic_index,
            mime_type: self.mime_type,
            width: self.width.and_then(|v| u32::try_from(v).ok()),
            height: self.height.and_then(|v| u32::try_from(v).ok()),
            file_size: self.file_size.and_then(|v| u64::try_from(v).ok()),
            display_name: self.display_name,
            sort_order: self.sort_order,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

pub struct AlbumAssetRepository;

impl AlbumAssetRepository {
    /// Idempotently replaces/upserts all file and embedded asset metadata rows for
    /// `album_version_id` inside an active write transaction without storing any BLOBs.
    pub async fn replace_album_version_assets_tx(
        conn: &mut SqliteConnection,
        album_version_id: &str,
        assets: &[NewAlbumAsset],
    ) -> Result<usize> {
        let version_id = album_version_id.trim();
        if version_id.is_empty() {
            return Err(DbError::ConstraintViolation(
                "album_version_id must not be empty".into(),
            ));
        }

        let mut deduped: Vec<(AssetIdentityKey, &NewAlbumAsset)> = Vec::with_capacity(assets.len());
        let mut incoming_keys: HashSet<AssetIdentityKey> = HashSet::with_capacity(assets.len());
        for asset in assets {
            let key = validate_identity(asset)?;
            if incoming_keys.insert(key.clone()) {
                deduped.push((key, asset));
            }
        }

        let existing: Vec<ExistingIdentityRow> = sqlx::query_as(
            "SELECT id, source_kind, file_path, embedded_track_id, embedded_pic_index \
             FROM album_assets WHERE album_version_id = ?",
        )
        .bind(version_id)
        .fetch_all(&mut *conn)
        .await?;

        let mut existing_by_key: HashMap<AssetIdentityKey, String> =
            HashMap::with_capacity(existing.len());
        for row in existing {
            let key_opt = match row.source_kind.as_str() {
                "file" => row.file_path.map(AssetIdentityKey::File),
                "embedded" => row
                    .embedded_track_id
                    .zip(row.embedded_pic_index)
                    .map(|(tid, idx)| AssetIdentityKey::Embedded(tid, idx)),
                _ => None,
            };
            if let Some(key) = key_opt.filter(|k| incoming_keys.contains(k)) {
                existing_by_key.insert(key, row.id);
            } else {
                sqlx::query("DELETE FROM album_assets WHERE id = ?")
                    .bind(&row.id)
                    .execute(&mut *conn)
                    .await?;
            }
        }

        let now = Utc::now().to_rfc3339();
        for (key, asset) in &deduped {
            let mime = asset.mime_type.trim();
            if mime.is_empty() {
                return Err(DbError::ConstraintViolation(
                    "mime_type must not be empty".into(),
                ));
            }
            let width = asset.width.map(i64::from);
            let height = asset.height.map(i64::from);
            let file_size = asset.file_size.map(|sz| sz.min(i64::MAX as u64) as i64);

            if let Some(existing_id) = existing_by_key.get(key) {
                sqlx::query(
                    "UPDATE album_assets \
                     SET asset_kind = ?, role = ?, mime_type = ?, width = ?, height = ?, \
                         file_size = ?, display_name = ?, sort_order = ?, updated_at = ? \
                     WHERE id = ?",
                )
                .bind(asset.asset_kind.as_str())
                .bind(asset.role.as_str())
                .bind(mime)
                .bind(width)
                .bind(height)
                .bind(file_size)
                .bind(&asset.display_name)
                .bind(asset.sort_order)
                .bind(&now)
                .bind(existing_id)
                .execute(&mut *conn)
                .await?;
            } else {
                let id = Uuid::new_v4().to_string();
                let (file_path, embedded_track_id, embedded_pic_index) = match key {
                    AssetIdentityKey::File(fp) => (Some(fp.as_str()), None, None),
                    AssetIdentityKey::Embedded(tid, idx) => (None, Some(tid.as_str()), Some(*idx)),
                };
                sqlx::query(
                    "INSERT INTO album_assets ( \
                         id, album_version_id, asset_kind, source_kind, role, \
                         file_path, embedded_track_id, embedded_pic_index, mime_type, \
                         width, height, file_size, display_name, sort_order, created_at, updated_at \
                     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(&id)
                .bind(version_id)
                .bind(asset.asset_kind.as_str())
                .bind(asset.source_kind.as_str())
                .bind(asset.role.as_str())
                .bind(file_path)
                .bind(embedded_track_id)
                .bind(embedded_pic_index)
                .bind(mime)
                .bind(width)
                .bind(height)
                .bind(file_size)
                .bind(&asset.display_name)
                .bind(asset.sort_order)
                .bind(&now)
                .bind(&now)
                .execute(&mut *conn)
                .await?;
            }
        }

        Ok(deduped.len())
    }

    /// Acquires the single-writer lock, starts an `ImmediateTx`, and replaces assets for
    /// `album_version_id`.
    pub async fn replace_album_version_assets(
        pool: &SqlitePool,
        album_version_id: &str,
        assets: &[NewAlbumAsset],
    ) -> Result<usize> {
        let (_guard, mut tx) = DbWriteCoordinator::for_pool(pool)
            .begin_immediate(pool)
            .await?;
        match Self::replace_album_version_assets_tx(tx.conn(), album_version_id, assets).await {
            Ok(count) => {
                tx.commit().await?;
                Ok(count)
            }
            Err(err) => {
                let _ = tx.rollback().await;
                Err(err)
            }
        }
    }

    /// Returns PDF booklets and gallery images for an album version, falling back to
    /// `canonical_albums.primary_version_id` (or first version) when passed a `canonical_album_id`.
    pub async fn get_album_assets(
        pool: &SqlitePool,
        album_version_id_or_album_id: &str,
    ) -> Result<AlbumAssetsResponse> {
        let input_id = album_version_id_or_album_id.trim();
        if input_id.is_empty() {
            return Ok(AlbumAssetsResponse::default());
        }

        let Some(resolved_version_id) = resolve_version_id(pool, input_id).await? else {
            return Ok(AlbumAssetsResponse {
                album_version_id: input_id.to_string(),
                pdfs: Vec::new(),
                images: Vec::new(),
                total_count: 0,
            });
        };

        let query = format!(
            "SELECT {SELECT_ASSET_COLS} FROM album_assets WHERE album_version_id = ? \
             ORDER BY \
               CASE role WHEN 'front' THEN 0 WHEN 'back' THEN 1 \
                         WHEN 'media' THEN 2 WHEN 'booklet' THEN 3 ELSE 4 END ASC, \
               sort_order ASC, LOWER(display_name) ASC, display_name ASC, id ASC"
        );
        let rows: Vec<AlbumAssetRow> = sqlx::query_as(&query)
            .bind(&resolved_version_id)
            .fetch_all(pool)
            .await?;

        let mut pdfs = Vec::new();
        let mut images = Vec::new();
        for row in rows {
            let record = row.into_record()?;
            match record.asset_kind {
                AlbumAssetKind::Pdf => pdfs.push(record),
                AlbumAssetKind::Image => images.push(record),
            }
        }
        let total_count = pdfs.len() + images.len();

        Ok(AlbumAssetsResponse {
            album_version_id: resolved_version_id,
            pdfs,
            images,
            total_count,
        })
    }

    /// Fetches a single `album_assets` metadata record by primary ID.
    pub async fn get_asset_by_id(
        pool: &SqlitePool,
        asset_id: &str,
    ) -> Result<Option<AlbumAssetRecord>> {
        let id = asset_id.trim();
        if id.is_empty() {
            return Ok(None);
        }
        let query = format!("SELECT {SELECT_ASSET_COLS} FROM album_assets WHERE id = ? LIMIT 1");
        let row: Option<AlbumAssetRow> =
            sqlx::query_as(&query).bind(id).fetch_optional(pool).await?;
        row.map(AlbumAssetRow::into_record).transpose()
    }
}

async fn resolve_version_id(pool: &SqlitePool, id: &str) -> Result<Option<String>> {
    let direct: Option<(String,)> =
        sqlx::query_as("SELECT id FROM album_versions WHERE id = ? LIMIT 1")
            .bind(id)
            .fetch_optional(pool)
            .await?;
    if let Some((ver_id,)) = direct {
        return Ok(Some(ver_id));
    }

    let primary: Option<(Option<String>,)> =
        sqlx::query_as("SELECT primary_version_id FROM canonical_albums WHERE id = ? LIMIT 1")
            .bind(id)
            .fetch_optional(pool)
            .await?;
    if let Some((Some(primary_vid),)) = primary {
        let trimmed = primary_vid.trim();
        if !trimmed.is_empty() {
            let exists: Option<(String,)> =
                sqlx::query_as("SELECT id FROM album_versions WHERE id = ? LIMIT 1")
                    .bind(trimmed)
                    .fetch_optional(pool)
                    .await?;
            if let Some((ver_id,)) = exists {
                return Ok(Some(ver_id));
            }
        }
    }

    let first: Option<(String,)> = sqlx::query_as(
        "SELECT id FROM album_versions WHERE canonical_album_id = ? \
         ORDER BY is_hidden ASC, quality_score DESC, \
                  CASE WHEN provider_id = 'local' THEN 0 ELSE 1 END, id ASC \
         LIMIT 1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?;
    Ok(first.map(|(ver_id,)| ver_id))
}

fn validate_identity(asset: &NewAlbumAsset) -> Result<AssetIdentityKey> {
    match asset.source_kind {
        AlbumAssetSourceKind::File => {
            let path = asset
                .file_path
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    DbError::ConstraintViolation("file asset requires non-empty file_path".into())
                })?;
            Ok(AssetIdentityKey::File(path.to_string()))
        }
        AlbumAssetSourceKind::Embedded => {
            let track_id = asset
                .embedded_track_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    DbError::ConstraintViolation(
                        "embedded asset requires non-empty embedded_track_id".into(),
                    )
                })?;
            let pic_index = asset
                .embedded_pic_index
                .filter(|&i| i >= 0)
                .ok_or_else(|| {
                    DbError::ConstraintViolation(
                        "embedded asset requires embedded_pic_index >= 0".into(),
                    )
                })?;
            Ok(AssetIdentityKey::Embedded(track_id.to_string(), pic_index))
        }
    }
}
