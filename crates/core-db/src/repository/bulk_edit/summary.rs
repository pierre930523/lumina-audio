use std::collections::{BTreeMap, HashMap};

use core_types::{
    AlbumMetadataLayer, BulkEditEntityType, BulkEditSummary, BulkTagSummaryItem, TagSelectionState,
    TrackMetadataLayer, TriStateFieldValue,
};
use serde_json::Value;
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, SqlitePool};

use super::{tag_entity_type_str, validate_entity_ids};
use crate::error::Result;

const MAX_SAMPLE_VALUES: usize = 5;

#[derive(Debug, sqlx::FromRow)]
struct AlbumSummaryRow {
    id: String,
    title: String,
    sort_title: String,
    effective_album_artist: Option<String>,
    release_year: Option<i32>,
    upc: Option<String>,
    editorial_bio: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
}

#[derive(Debug, sqlx::FromRow)]
struct TrackSummaryRow {
    id: String,
    title: String,
    artist_name: Option<String>,
    album_artist: Option<String>,
    album_title: String,
    disc_number: i64,
    track_number: i64,
    release_year: Option<i32>,
    genre: Option<String>,
    composer: Option<String>,
    isrc: Option<String>,
    lyrics: Option<String>,
    user_edits_json: Option<String>,
    meta_policy: String,
}

#[derive(Debug, sqlx::FromRow)]
struct TagCatalogRow {
    id: String,
    name: String,
    color: Option<String>,
}

struct TriStateAccumulator<T: PartialEq + Clone> {
    distinct: Vec<T>,
    has_empty: bool,
    total_seen: usize,
}

impl<T: PartialEq + Clone> Default for TriStateAccumulator<T> {
    fn default() -> Self {
        Self {
            distinct: Vec::new(),
            has_empty: false,
            total_seen: 0,
        }
    }
}

impl<T: PartialEq + Clone> TriStateAccumulator<T> {
    fn push(&mut self, value: Option<T>) {
        self.total_seen += 1;
        match value {
            None => self.has_empty = true,
            Some(v) => {
                if !self.distinct.iter().any(|existing| existing == &v) {
                    self.distinct.push(v);
                }
            }
        }
    }

    fn finish(self) -> TriStateFieldValue<T> {
        if self.total_seen == 0 || self.distinct.is_empty() {
            return TriStateFieldValue::Empty;
        }
        if self.distinct.len() == 1 && !self.has_empty {
            return TriStateFieldValue::Common {
                value: self.distinct.into_iter().next().expect("checked len == 1"),
            };
        }
        let distinct_count = self.distinct.len() + usize::from(self.has_empty);
        let sample_values = self.distinct.into_iter().take(MAX_SAMPLE_VALUES).collect();
        TriStateFieldValue::Mixed {
            distinct_count,
            sample_values,
        }
    }
}

#[inline]
fn clean_str_value(raw: Option<&str>) -> Option<Value> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| Value::String(s.to_string()))
}

pub(super) async fn get_bulk_edit_summary_impl(
    pool: &SqlitePool,
    entity_type: BulkEditEntityType,
    entity_ids: &[String],
) -> Result<BulkEditSummary> {
    let ids = validate_entity_ids(entity_ids)?;
    let mut conn = pool.acquire().await?;

    let (valid_ids, fields, meta_policy, has_user_edits_count) = match entity_type {
        BulkEditEntityType::Album => summarize_albums_conn(&mut conn, &ids).await?,
        BulkEditEntityType::Track => summarize_tracks_conn(&mut conn, &ids).await?,
    };

    let tags = load_bulk_tag_summary_conn(&mut conn, entity_type, &valid_ids).await?;

    Ok(BulkEditSummary {
        entity_type,
        selected_count: valid_ids.len(),
        fields,
        meta_policy,
        tags,
        has_user_edits_count,
    })
}

async fn summarize_albums_conn(
    conn: &mut SqliteConnection,
    entity_ids: &[String],
) -> Result<(
    Vec<String>,
    BTreeMap<String, TriStateFieldValue<Value>>,
    TriStateFieldValue<String>,
    usize,
)> {
    let mut rows = Vec::with_capacity(entity_ids.len());
    for chunk in entity_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT ca.id, ca.title, ca.sort_title, \
                    COALESCE(NULLIF(TRIM(ca.album_artist), ''), a.name) AS effective_album_artist, \
                    ca.release_year, ca.upc, ca.editorial_bio, ca.user_edits_json, ca.meta_policy \
             FROM canonical_albums ca \
             LEFT JOIN artists a ON a.id = ca.primary_artist_id \
             WHERE ca.id IN (",
        );
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(") ORDER BY ca.id ASC");
        rows.extend(
            qb.build_query_as::<AlbumSummaryRow>()
                .fetch_all(&mut *conn)
                .await?,
        );
    }
    rows.sort_by(|a, b| a.id.cmp(&b.id));

    let mut title = TriStateAccumulator::default();
    let mut sort_title = TriStateAccumulator::default();
    let mut album_artist = TriStateAccumulator::default();
    let mut release_year = TriStateAccumulator::default();
    let mut upc = TriStateAccumulator::default();
    let mut editorial_bio = TriStateAccumulator::default();
    let mut meta_policy = TriStateAccumulator::default();
    let mut has_user_edits_count = 0usize;
    let mut valid_ids = Vec::with_capacity(rows.len());

    for row in rows {
        valid_ids.push(row.id);
        title.push(clean_str_value(Some(&row.title)));
        sort_title.push(clean_str_value(Some(&row.sort_title)));
        album_artist.push(clean_str_value(row.effective_album_artist.as_deref()));
        release_year.push(row.release_year.map(Value::from));
        upc.push(clean_str_value(row.upc.as_deref()));
        editorial_bio.push(clean_str_value(row.editorial_bio.as_deref()));
        meta_policy.push(Some(row.meta_policy.trim().to_string()).filter(|s| !s.is_empty()));
        if AlbumMetadataLayer::from_json_opt(row.user_edits_json.as_deref()).is_some() {
            has_user_edits_count += 1;
        }
    }

    let mut fields = BTreeMap::new();
    fields.insert("title".to_string(), title.finish());
    fields.insert("sort_title".to_string(), sort_title.finish());
    fields.insert("album_artist".to_string(), album_artist.finish());
    fields.insert("release_year".to_string(), release_year.finish());
    fields.insert("upc".to_string(), upc.finish());
    fields.insert("editorial_bio".to_string(), editorial_bio.finish());

    Ok((
        valid_ids,
        fields,
        meta_policy.finish(),
        has_user_edits_count,
    ))
}

async fn summarize_tracks_conn(
    conn: &mut SqliteConnection,
    entity_ids: &[String],
) -> Result<(
    Vec<String>,
    BTreeMap<String, TriStateFieldValue<Value>>,
    TriStateFieldValue<String>,
    usize,
)> {
    let mut rows = Vec::with_capacity(entity_ids.len());
    for chunk in entity_ids.chunks(500) {
        let mut qb: QueryBuilder<'_, Sqlite> = QueryBuilder::new(
            "SELECT ts.id, ts.title, ts.artist_name, ts.album_artist, \
                    ca.title AS album_title, ts.disc_number, ts.track_number, \
                    COALESCE(ts.release_year, ca.release_year) AS release_year, \
                    ts.genre, ts.composer, ts.isrc, ts.embedded_lyrics AS lyrics, \
                    ts.user_edits_json, ts.meta_policy \
             FROM track_sources ts \
             JOIN album_versions av ON av.id = ts.version_id \
             JOIN canonical_albums ca ON ca.id = av.canonical_album_id \
             WHERE ts.id IN (",
        );
        let mut sep = qb.separated(", ");
        for id in chunk {
            sep.push_bind(id);
        }
        sep.push_unseparated(") ORDER BY ts.id ASC");
        rows.extend(
            qb.build_query_as::<TrackSummaryRow>()
                .fetch_all(&mut *conn)
                .await?,
        );
    }
    rows.sort_by(|a, b| a.id.cmp(&b.id));

    let mut title = TriStateAccumulator::default();
    let mut artist_name = TriStateAccumulator::default();
    let mut album_artist = TriStateAccumulator::default();
    let mut album_title = TriStateAccumulator::default();
    let mut disc_number = TriStateAccumulator::default();
    let mut track_number = TriStateAccumulator::default();
    let mut release_year = TriStateAccumulator::default();
    let mut genre = TriStateAccumulator::default();
    let mut composer = TriStateAccumulator::default();
    let mut isrc = TriStateAccumulator::default();
    let mut lyrics = TriStateAccumulator::default();
    let mut meta_policy = TriStateAccumulator::default();
    let mut has_user_edits_count = 0usize;
    let mut valid_ids = Vec::with_capacity(rows.len());

    for row in rows {
        valid_ids.push(row.id);
        title.push(clean_str_value(Some(&row.title)));
        artist_name.push(clean_str_value(row.artist_name.as_deref()));
        album_artist.push(clean_str_value(row.album_artist.as_deref()));
        album_title.push(clean_str_value(Some(&row.album_title)));
        disc_number.push((row.disc_number > 0).then(|| Value::from(row.disc_number)));
        track_number.push((row.track_number > 0).then(|| Value::from(row.track_number)));
        release_year.push(row.release_year.map(Value::from));
        genre.push(clean_str_value(row.genre.as_deref()));
        composer.push(clean_str_value(row.composer.as_deref()));
        isrc.push(clean_str_value(row.isrc.as_deref()));
        lyrics.push(clean_str_value(row.lyrics.as_deref()));
        meta_policy.push(Some(row.meta_policy.trim().to_string()).filter(|s| !s.is_empty()));
        if TrackMetadataLayer::from_json_opt(row.user_edits_json.as_deref()).is_some() {
            has_user_edits_count += 1;
        }
    }

    let mut fields = BTreeMap::new();
    fields.insert("title".to_string(), title.finish());
    fields.insert("artist_name".to_string(), artist_name.finish());
    fields.insert("album_artist".to_string(), album_artist.finish());
    fields.insert("album_title".to_string(), album_title.finish());
    fields.insert("disc_number".to_string(), disc_number.finish());
    fields.insert("track_number".to_string(), track_number.finish());
    fields.insert("release_year".to_string(), release_year.finish());
    fields.insert("genre".to_string(), genre.finish());
    fields.insert("composer".to_string(), composer.finish());
    fields.insert("isrc".to_string(), isrc.finish());
    fields.insert("lyrics".to_string(), lyrics.finish());

    Ok((
        valid_ids,
        fields,
        meta_policy.finish(),
        has_user_edits_count,
    ))
}

async fn load_bulk_tag_summary_conn(
    conn: &mut SqliteConnection,
    entity_type: BulkEditEntityType,
    valid_ids: &[String],
) -> Result<Vec<BulkTagSummaryItem>> {
    let tags: Vec<TagCatalogRow> =
        sqlx::query_as("SELECT id, name, color FROM tags ORDER BY normalized_name ASC, id ASC")
            .fetch_all(&mut *conn)
            .await?;

    if tags.is_empty() {
        return Ok(Vec::new());
    }

    let total_count = valid_ids.len();
    let tag_entity = tag_entity_type_str(entity_type);
    let mut assigned_by_tag: HashMap<String, usize> = HashMap::new();

    if total_count > 0 {
        for chunk in valid_ids.chunks(500) {
            let mut qb: QueryBuilder<'_, Sqlite> =
                QueryBuilder::new("SELECT tag_id, COUNT(*) FROM tag_items WHERE entity_type = ");
            qb.push_bind(tag_entity).push(" AND entity_id IN (");
            let mut sep = qb.separated(", ");
            for id in chunk {
                sep.push_bind(id);
            }
            sep.push_unseparated(") GROUP BY tag_id");
            let rows: Vec<(String, i64)> = qb.build_query_as().fetch_all(&mut *conn).await?;
            for (tag_id, count) in rows {
                *assigned_by_tag.entry(tag_id).or_insert(0) += count.max(0) as usize;
            }
        }
    }

    Ok(tags
        .into_iter()
        .map(|tag| {
            let assigned_count = assigned_by_tag.get(&tag.id).copied().unwrap_or(0);
            let state = if total_count == 0 || assigned_count == 0 {
                TagSelectionState::None
            } else if assigned_count >= total_count {
                TagSelectionState::All
            } else {
                TagSelectionState::Some
            };
            BulkTagSummaryItem {
                tag_id: tag.id,
                name: tag.name,
                color: tag.color,
                state,
                assigned_count,
                total_count,
            }
        })
        .collect())
}
