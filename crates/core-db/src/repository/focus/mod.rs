mod albums;
mod compiler;
mod compiler_meta;
mod facets;
mod facets_meta;
mod tracks;

use core_types::{
    AlbumGroupSummaryRow, FocusEntity, FocusFacetsResponse, FocusQuery, FocusQueryRequest,
    FocusQueryResponse,
};
use sqlx::SqlitePool;

use crate::error::Result;
use crate::repository::CatalogTrackRow;

pub use compiler::{FocusCompileScope, compile_focus_query_to_sql};
pub(crate) use compiler_meta::parse_preference_value;
pub(crate) use tracks::push_track_order_by;

pub struct FocusRepository;

impl FocusRepository {
    /// Executes a paginated, sorted, multi-dimensional Focus query for either
    /// `FocusEntity::Albums` or `FocusEntity::Tracks`.
    pub async fn query_focus_entities(
        pool: &SqlitePool,
        req: &FocusQueryRequest,
    ) -> Result<FocusQueryResponse<AlbumGroupSummaryRow, CatalogTrackRow>> {
        let clamped_limit = req.limit.clamp(1, 500);
        let offset = req.offset;

        match req.query.entity {
            FocusEntity::Albums => {
                let (total_count, rows) =
                    albums::query_focus_albums(pool, &req.query, clamped_limit, offset).await?;
                Ok(FocusQueryResponse::for_albums(
                    total_count,
                    clamped_limit,
                    offset,
                    rows,
                ))
            }
            FocusEntity::Tracks => {
                let (total_count, rows) =
                    tracks::query_focus_tracks(pool, &req.query, clamped_limit, offset).await?;
                Ok(FocusQueryResponse::for_tracks(
                    total_count,
                    clamped_limit,
                    offset,
                    rows,
                ))
            }
        }
    }

    /// Computes live disjunctive cross-filtering facet counts and `year_range`
    /// for the given `FocusQuery`.
    pub async fn get_focus_facets(
        pool: &SqlitePool,
        query: &FocusQuery,
    ) -> Result<FocusFacetsResponse> {
        facets::compute_focus_facets(pool, query).await
    }
}
