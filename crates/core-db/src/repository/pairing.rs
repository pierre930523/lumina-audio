use crate::error::Result;
use crate::repository::PairedClient;
use chrono::Utc;
use sqlx::SqlitePool;

pub struct PairingRepository;

impl PairingRepository {
    pub async fn insert_paired_client(pool: &SqlitePool, client: &PairedClient) -> Result<()> {
        sqlx::query(
            "INSERT INTO paired_clients (id, device_name, platform, token_hash, created_at, last_seen_at) \
             VALUES (?, ?, ?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET \
                device_name = excluded.device_name, \
                platform = excluded.platform, \
                token_hash = excluded.token_hash, \
                last_seen_at = excluded.last_seen_at",
        )
        .bind(&client.id)
        .bind(&client.device_name)
        .bind(&client.platform)
        .bind(&client.token_hash)
        .bind(&client.created_at)
        .bind(&client.last_seen_at)
        .execute(pool)
        .await?;

        Ok(())
    }

    pub async fn list_paired_clients(pool: &SqlitePool) -> Result<Vec<PairedClient>> {
        let rows: Vec<PairedClient> = sqlx::query_as(
            "SELECT id, device_name, platform, token_hash, created_at, last_seen_at \
             FROM paired_clients ORDER BY last_seen_at DESC, created_at DESC",
        )
        .fetch_all(pool)
        .await?;

        Ok(rows)
    }

    pub async fn list_paired_token_hashes(pool: &SqlitePool) -> Result<Vec<String>> {
        let rows: Vec<(String,)> =
            sqlx::query_as("SELECT token_hash FROM paired_clients ORDER BY created_at DESC")
                .fetch_all(pool)
                .await?;

        Ok(rows.into_iter().map(|(h,)| h).collect())
    }

    pub async fn touch_paired_client_by_hash(pool: &SqlitePool, token_hash: &str) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        sqlx::query("UPDATE paired_clients SET last_seen_at = ? WHERE token_hash = ?")
            .bind(now)
            .bind(token_hash)
            .execute(pool)
            .await?;
        Ok(())
    }

    pub async fn delete_paired_client(pool: &SqlitePool, id: &str) -> Result<bool> {
        let res = sqlx::query("DELETE FROM paired_clients WHERE id = ?")
            .bind(id)
            .execute(pool)
            .await?;
        Ok(res.rows_affected() > 0)
    }
}
