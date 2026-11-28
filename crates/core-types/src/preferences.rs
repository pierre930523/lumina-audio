use serde::{Deserialize, Serialize};

// ============================================================================
// Step 4: Tri-State Entity Preference DTOs (-1 = Banned, 0 = Neutral, 1 = Favorite)
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetEntityPreferenceRequest {
    pub entity_type: String,
    pub entity_id: String,
    pub preference: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetEntityPreferenceResponse {
    pub entity_type: String,
    pub entity_id: String,
    pub preference: i32,
}
