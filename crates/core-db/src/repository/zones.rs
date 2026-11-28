use crate::error::Result;
use chrono::Utc;
use core_types::ZoneInfo;
use sqlx::SqlitePool;

pub struct ZonesRepository;

impl ZonesRepository {
    pub async fn upsert_zone(pool: &SqlitePool, zone: &ZoneInfo) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO zones (id, name, backend, device_id, exclusive_mode, dsp_bypass, \
             dsp_config_json, group_id, volume, is_active, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET \
             name = excluded.name, backend = excluded.backend, device_id = excluded.device_id, \
             exclusive_mode = excluded.exclusive_mode, dsp_bypass = excluded.dsp_bypass, \
             group_id = excluded.group_id, volume = excluded.volume, is_active = excluded.is_active, \
             updated_at = excluded.updated_at",
        )
        .bind(&zone.id)
        .bind(&zone.name)
        .bind(&zone.backend)
        .bind(&zone.device_id)
        .bind(if zone.exclusive_mode { 1 } else { 0 })
        .bind(if zone.dsp_bypass { 1 } else { 0 })
        .bind(&zone.group_id)
        .bind(zone.volume as f64)
        .bind(if zone.is_active { 1 } else { 0 })
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await?;
        Ok(())
    }
}
