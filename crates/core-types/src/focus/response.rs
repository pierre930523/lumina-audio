use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use super::FocusEntity;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusQueryResponse<A, T> {
    pub entity: FocusEntity,
    pub total_count: u64,
    pub limit: u32,
    pub offset: u32,
    #[serde(default)]
    pub albums: Vec<A>,
    #[serde(default)]
    pub tracks: Vec<T>,
}

impl<A, T> FocusQueryResponse<A, T> {
    pub fn for_albums(total_count: u64, limit: u32, offset: u32, albums: Vec<A>) -> Self {
        Self {
            entity: FocusEntity::Albums,
            total_count,
            limit,
            offset,
            albums,
            tracks: Vec::new(),
        }
    }

    pub fn for_tracks(total_count: u64, limit: u32, offset: u32, tracks: Vec<T>) -> Self {
        Self {
            entity: FocusEntity::Tracks,
            total_count,
            limit,
            offset,
            albums: Vec::new(),
            tracks,
        }
    }

    pub fn map_items<A2, T2>(
        self,
        f_album: impl FnMut(A) -> A2,
        f_track: impl FnMut(T) -> T2,
    ) -> FocusQueryResponse<A2, T2> {
        FocusQueryResponse {
            entity: self.entity,
            total_count: self.total_count,
            limit: self.limit,
            offset: self.offset,
            albums: self.albums.into_iter().map(f_album).collect(),
            tracks: self.tracks.into_iter().map(f_track).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FocusFacetBucket {
    pub value: String,
    pub label: String,
    pub count: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FocusIntRangeBounds {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<i32>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FocusFacetsResponse {
    pub total_matched: u64,
    #[serde(default)]
    pub facets: BTreeMap<String, Vec<FocusFacetBucket>>,
    #[serde(default)]
    pub year_range: FocusIntRangeBounds,
}
