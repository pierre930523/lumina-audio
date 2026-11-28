use std::collections::HashMap;
use std::path::Path;

use core_types::{
    CatalogExportFormat, CatalogExportRequest, CatalogExportResult, CatalogExportSource,
    FocusEntity,
};
use serde::Serialize;
use sqlx::{QueryBuilder, Sqlite, SqlitePool};

use crate::error::{DbError, Result};
use crate::repository::SmartPlaylistRepository;
use crate::repository::focus::{
    FocusCompileScope, compile_focus_query_to_sql, push_track_order_by,
};

const MAX_EXPORT_TRACKS: i64 = 100_000;

#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub(super) struct ExportTrackRow {
    pub track_id: String,
    pub title: String,
    pub artist: String,
    pub album_artist: String,
    pub album: String,
    pub disc_number: i32,
    pub track_number: i32,
    pub duration_ms: i64,
    pub codec: String,
    pub sample_rate_hz: i64,
    pub bit_depth: i32,
    pub channels: i32,
    pub is_dsd: bool,
    pub provider_id: String,
    pub quality_score: f64,
    pub file_path: String,
    pub genre: String,
    pub release_year: Option<i32>,
    pub tags: String,
}

const EXPORT_TRACK_SELECT: &str = "\
SELECT trk.id AS track_id, \
       trk.title AS title, \
       COALESCE(NULLIF(trk.artist_name, ''), COALESCE(art.name, 'Unknown Artist')) AS artist, \
       COALESCE(NULLIF(trk.album_artist, ''), NULLIF(alb.album_artist, ''), COALESCE(art.name, '')) AS album_artist, \
       COALESCE(alb.title, 'Unknown Album') AS album, \
       trk.disc_number AS disc_number, \
       trk.track_number AS track_number, \
       trk.duration_ms AS duration_ms, \
       trk.codec AS codec, \
       trk.sample_rate_hz AS sample_rate_hz, \
       trk.bit_depth AS bit_depth, \
       trk.channels AS channels, \
       (trk.is_dsd != 0) AS is_dsd, \
       trk.provider_id AS provider_id, \
       COALESCE(ver.quality_score, 0.0) AS quality_score, \
       trk.external_track_id AS file_path, \
       COALESCE(trk.genre, '') AS genre, \
       alb.release_year AS release_year, \
       COALESCE(( \
           SELECT GROUP_CONCAT(name, '; ') \
           FROM ( \
               SELECT DISTINCT t.name AS name \
               FROM tag_items ti \
               JOIN tags t ON t.id = ti.tag_id \
               WHERE (ti.entity_type = 'track' AND ti.entity_id = trk.id) \
                  OR (ti.entity_type = 'album_group' AND ti.entity_id = alb.id) \
               ORDER BY t.name ASC \
           ) \
       ), '') AS tags \
FROM track_sources trk \
JOIN album_versions ver ON ver.id = trk.version_id \
JOIN canonical_albums alb ON alb.id = ver.canonical_album_id \
LEFT JOIN artists art ON art.id = alb.primary_artist_id";

async fn fetch_tracks_by_ids_ordered(
    pool: &SqlitePool,
    ids: &[String],
) -> Result<Vec<ExportTrackRow>> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }

    let mut by_id: HashMap<String, ExportTrackRow> = HashMap::with_capacity(ids.len());
    for chunk in ids.chunks(400) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(EXPORT_TRACK_SELECT);
        qb.push(" WHERE trk.id IN (");
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(")");

        let rows: Vec<ExportTrackRow> = qb.build_query_as().fetch_all(pool).await?;
        for row in rows {
            by_id.insert(row.track_id.clone(), row);
        }
    }

    let mut ordered = Vec::with_capacity(ids.len());
    for id in ids {
        if let Some(row) = by_id.get(id) {
            ordered.push(row.clone());
        }
    }
    Ok(ordered)
}

pub(super) async fn resolve_export_tracks(
    pool: &SqlitePool,
    source: &CatalogExportSource,
) -> Result<Vec<ExportTrackRow>> {
    match source {
        CatalogExportSource::FocusQuery { query } => {
            let mut normalized = query.clone();
            normalized.entity = FocusEntity::Tracks;
            let scope = FocusCompileScope::for_tracks(normalized.include_hidden);

            let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(EXPORT_TRACK_SELECT);
            qb.push(" WHERE trk.file_status = 'present'");
            if !normalized.include_hidden {
                qb.push(" AND ver.is_hidden = 0 AND trk.is_hidden = 0");
            }
            compile_focus_query_to_sql(&mut qb, &normalized, scope, None);
            push_track_order_by(&mut qb, normalized.sort);
            qb.push(" LIMIT ");
            qb.push_bind(MAX_EXPORT_TRACKS);

            let rows: Vec<ExportTrackRow> = qb.build_query_as().fetch_all(pool).await?;
            Ok(rows)
        }
        CatalogExportSource::StaticPlaylist { playlist_id } => {
            let pid = playlist_id.trim();
            if pid.is_empty() {
                return Err(DbError::NotFound("Playlist id must not be empty".into()));
            }
            let ids: Vec<(String,)> = sqlx::query_as(
                "SELECT pi.resolved_track_source_id \
                 FROM playlist_items pi \
                 WHERE pi.playlist_id = ? \
                   AND pi.resolved_track_source_id IS NOT NULL \
                 ORDER BY pi.position ASC",
            )
            .bind(pid)
            .fetch_all(pool)
            .await?;
            let ordered_ids: Vec<String> = ids.into_iter().map(|(id,)| id).collect();
            fetch_tracks_by_ids_ordered(pool, &ordered_ids).await
        }
        CatalogExportSource::SmartPlaylist { playlist_id } => {
            let eval =
                SmartPlaylistRepository::evaluate_smart_playlist_rows(pool, playlist_id).await?;
            let ordered_ids: Vec<String> = eval.tracks.into_iter().map(|t| t.id).collect();
            fetch_tracks_by_ids_ordered(pool, &ordered_ids).await
        }
        CatalogExportSource::Albums { album_ids } => {
            let clean: Vec<String> = album_ids
                .iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            if clean.is_empty() {
                return Ok(Vec::new());
            }
            let mut rows = Vec::new();
            for chunk in clean.chunks(400) {
                let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(EXPORT_TRACK_SELECT);
                qb.push(" WHERE trk.file_status = 'present' AND ver.canonical_album_id IN (");
                let mut sep = qb.separated(", ");
                for id in chunk {
                    sep.push_bind(id);
                }
                sep.push_unseparated(
                    ") ORDER BY alb.sort_title ASC, trk.disc_number ASC, trk.track_number ASC, trk.id ASC",
                );
                let mut part: Vec<ExportTrackRow> = qb.build_query_as().fetch_all(pool).await?;
                rows.append(&mut part);
            }
            Ok(rows)
        }
        CatalogExportSource::Tracks { track_ids } => {
            let clean: Vec<String> = track_ids
                .iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            fetch_tracks_by_ids_ordered(pool, &clean).await
        }
    }
}

fn escape_csv_field(value: &str) -> String {
    if value.contains([',', '"', '\r', '\n']) {
        let escaped = value.replace('"', "\"\"");
        format!("\"{escaped}\"")
    } else {
        value.to_string()
    }
}

fn push_csv_row(out: &mut String, cols: &[&str]) {
    for (idx, col) in cols.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        out.push_str(&escape_csv_field(col));
    }
    out.push_str("\r\n");
}

fn render_csv(rows: &[ExportTrackRow], include_headers: bool, utf8_bom: bool) -> String {
    let mut out = String::with_capacity(rows.len().saturating_mul(160) + 256);
    if utf8_bom {
        out.push('\u{FEFF}');
    }
    if include_headers {
        push_csv_row(
            &mut out,
            &[
                "track_id",
                "title",
                "artist",
                "album_artist",
                "album",
                "disc_number",
                "track_number",
                "duration_ms",
                "codec",
                "sample_rate_hz",
                "bit_depth",
                "channels",
                "is_dsd",
                "provider_id",
                "quality_score",
                "file_path",
                "genre",
                "release_year",
                "tags",
            ],
        );
    }

    for r in rows {
        let disc = r.disc_number.to_string();
        let trk = r.track_number.to_string();
        let dur = r.duration_ms.to_string();
        let sr = r.sample_rate_hz.to_string();
        let bd = r.bit_depth.to_string();
        let ch = r.channels.to_string();
        let dsd = if r.is_dsd { "true" } else { "false" };
        let qs = format!("{:.2}", r.quality_score);
        let year = r.release_year.map(|y| y.to_string()).unwrap_or_default();

        push_csv_row(
            &mut out,
            &[
                &r.track_id,
                &r.title,
                &r.artist,
                &r.album_artist,
                &r.album,
                &disc,
                &trk,
                &dur,
                &r.codec,
                &sr,
                &bd,
                &ch,
                dsd,
                &r.provider_id,
                &qs,
                &r.file_path,
                &r.genre,
                &year,
                &r.tags,
            ],
        );
    }
    out
}

pub async fn export_catalog(
    pool: &SqlitePool,
    req: &CatalogExportRequest,
) -> Result<CatalogExportResult> {
    let rows = resolve_export_tracks(pool, &req.source).await?;
    let row_count = rows.len() as u64;

    let rendered = match req.format {
        CatalogExportFormat::Csv => render_csv(&rows, req.include_headers, req.utf8_bom),
        CatalogExportFormat::Json => serde_json::to_string_pretty(&rows).map_err(|e| {
            DbError::ConstraintViolation(format!("JSON catalog export failed: {e}"))
        })?,
    };
    let size_bytes = rendered.len() as u64;

    let target = req.output_path.trim();
    if target.is_empty() {
        return Ok(CatalogExportResult {
            format: req.format,
            output_path: String::new(),
            row_count,
            size_bytes,
            content: Some(rendered),
        });
    }

    let out_path = Path::new(target);
    if let Some(parent) = out_path.parent().filter(|p| !p.as_os_str().is_empty()) {
        tokio::fs::create_dir_all(parent).await?;
    }
    let tmp_path = out_path.with_extension(format!(
        "{}.tmp",
        out_path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("export")
    ));
    tokio::fs::write(&tmp_path, rendered.as_bytes()).await?;
    if out_path.exists() {
        let _ = tokio::fs::remove_file(out_path).await;
    }
    if let Err(err) = tokio::fs::rename(&tmp_path, out_path).await {
        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(err.into());
    }

    Ok(CatalogExportResult {
        format: req.format,
        output_path: target.to_string(),
        row_count,
        size_bytes,
        content: None,
    })
}
