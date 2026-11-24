use crate::engine::{get_engine, EngineState};
use crate::error::{
    catch_unwind_ffi, set_last_error, string_to_c_char, LUMINA_ERR_DATABASE, LUMINA_ERR_GENERAL,
    LUMINA_ERR_NOT_INITIALIZED, LUMINA_ERR_NULL_POINTER, LUMINA_OK,
};
use core_db::{L1StreamCacheRepository, L1StreamUrlRecord, SqlitePool};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::OnceLock;
use tokio::sync::{mpsc, oneshot};

enum L1WriteOp {
    Upsert {
        pool: SqlitePool,
        record: Box<L1StreamUrlRecord>,
    },
    Delete {
        pool: SqlitePool,
        provider_id: String,
        track_id: String,
        quality_key: Option<String>,
    },
    ClearProvider {
        pool: SqlitePool,
        provider_id: String,
    },
    PruneStaleEpoch {
        pool: SqlitePool,
        provider_ids: Vec<String>,
        current_epoch: i64,
    },
    Flush(oneshot::Sender<()>),
}

static L1_WRITE_TX: OnceLock<mpsc::UnboundedSender<L1WriteOp>> = OnceLock::new();

fn l1_write_sender(engine: &EngineState) -> &'static mpsc::UnboundedSender<L1WriteOp> {
    L1_WRITE_TX.get_or_init(|| {
        let (tx, mut rx) = mpsc::unbounded_channel::<L1WriteOp>();
        engine.runtime.spawn(async move {
            while let Some(op) = rx.recv().await {
                match op {
                    L1WriteOp::Upsert { pool, record } => {
                        if let Err(e) = L1StreamCacheRepository::upsert(&pool, &record).await {
                            tracing::warn!("L1 cache SQLite upsert failed: {e}");
                        }
                    }
                    L1WriteOp::Delete {
                        pool,
                        provider_id,
                        track_id,
                        quality_key,
                    } => {
                        if let Err(e) = L1StreamCacheRepository::delete(
                            &pool,
                            &provider_id,
                            &track_id,
                            quality_key.as_deref(),
                        )
                        .await
                        {
                            tracing::warn!("L1 cache SQLite delete failed: {e}");
                        }
                    }
                    L1WriteOp::ClearProvider { pool, provider_id } => {
                        if let Err(e) =
                            L1StreamCacheRepository::clear_provider(&pool, &provider_id).await
                        {
                            tracing::warn!("L1 cache SQLite clear_provider failed: {e}");
                        }
                    }
                    L1WriteOp::PruneStaleEpoch {
                        pool,
                        provider_ids,
                        current_epoch,
                    } => {
                        let refs: Vec<&str> = provider_ids.iter().map(String::as_str).collect();
                        if let Err(e) = L1StreamCacheRepository::prune_stale_network_epoch(
                            &pool,
                            &refs,
                            current_epoch,
                        )
                        .await
                        {
                            tracing::warn!("L1 cache SQLite prune_stale_network_epoch failed: {e}");
                        }
                    }
                    L1WriteOp::Flush(done) => {
                        let _ = done.send(());
                    }
                }
            }
        });
        tx
    })
}

pub(crate) fn flush_pending_writes(engine: &EngineState) {
    if let Some(tx) = L1_WRITE_TX.get() {
        let (done_tx, done_rx) = oneshot::channel();
        if tx.send(L1WriteOp::Flush(done_tx)).is_ok() {
            let _ = engine.runtime.block_on(done_rx);
        }
    }
}

pub(crate) fn enqueue_prune_stale_epoch(
    engine: &EngineState,
    provider_ids: Vec<String>,
    current_epoch: u64,
) {
    if provider_ids.is_empty() {
        return;
    }
    let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
    let Some(pool) = maybe_pool else {
        return;
    };
    let tx = l1_write_sender(engine);
    let _ = tx.send(L1WriteOp::PruneStaleEpoch {
        pool,
        provider_ids,
        current_epoch: current_epoch as i64,
    });
}

/// Loads all unexpired rows from `l1_stream_urls` (`expire_at > now_sec`) as a JSON array
/// and spawns background cleanup of expired rows.
/// Caller must free the returned string with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l1_cache_load_unexpired(now_sec: u64) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_l1_cache_load_unexpired",
        || {
            let engine = get_engine();
            flush_pending_writes(&engine);

            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                return Ok(string_to_c_char("[]"));
            };

            let cutoff = now_sec as i64;
            let records = engine
                .runtime
                .block_on(L1StreamCacheRepository::load_unexpired(&pool, cutoff))
                .map_err(|e| anyhow::anyhow!("Failed to load L1 stream cache: {e}"))?;

            let pool_bg = pool.clone();
            engine.runtime.spawn(async move {
                let _ = L1StreamCacheRepository::prune_expired(&pool_bg, cutoff).await;
            });

            let json_str = serde_json::to_string(&records)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Validates and enqueues a non-blocking FIFO write-through upsert into `l1_stream_urls`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l1_cache_upsert(record_json: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_GENERAL, "lumina_l1_cache_upsert", || {
        if record_json.is_null() {
            set_last_error("record_json is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let raw = unsafe { CStr::from_ptr(record_json) }
            .to_str()
            .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in record_json: {e}"))?;
        let record: L1StreamUrlRecord = serde_json::from_str(raw)
            .map_err(|e| anyhow::anyhow!("Invalid L1StreamUrlRecord JSON: {e}"))?;

        if record.provider_id.trim().is_empty() || record.track_id.trim().is_empty() {
            set_last_error("L1 cache record requires non-empty provider_id and track_id");
            return Ok(LUMINA_ERR_GENERAL);
        }

        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            set_last_error("Library database not initialized");
            return Ok(LUMINA_ERR_NOT_INITIALIZED);
        };

        let tx = l1_write_sender(&engine);
        tx.send(L1WriteOp::Upsert {
            pool,
            record: Box::new(record),
        })
        .map_err(|_| anyhow::anyhow!("L1 write queue closed"))?;

        Ok(LUMINA_OK)
    })
}

/// Enqueues a non-blocking FIFO delete from `l1_stream_urls`.
/// When `quality_key` is null or empty, deletes all quality entries for `(provider_id, track_id)`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l1_cache_delete(
    provider_id: *const c_char,
    track_id: *const c_char,
    quality_key: *const c_char,
) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_DATABASE, "lumina_l1_cache_delete", || {
        if provider_id.is_null() || track_id.is_null() {
            set_last_error("provider_id or track_id is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let pid = unsafe { CStr::from_ptr(provider_id) }
            .to_str()
            .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in provider_id: {e}"))?
            .trim()
            .to_string();
        let tid = unsafe { CStr::from_ptr(track_id) }
            .to_str()
            .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in track_id: {e}"))?
            .trim()
            .to_string();
        let qk = if quality_key.is_null() {
            None
        } else {
            let s = unsafe { CStr::from_ptr(quality_key) }
                .to_str()
                .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in quality_key: {e}"))?
                .trim();
            if s.is_empty() {
                None
            } else {
                Some(s.to_string())
            }
        };

        if pid.is_empty() || tid.is_empty() {
            set_last_error("provider_id and track_id must be non-empty");
            return Ok(LUMINA_ERR_GENERAL);
        }

        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            return Ok(LUMINA_OK);
        };

        let tx = l1_write_sender(&engine);
        tx.send(L1WriteOp::Delete {
            pool,
            provider_id: pid,
            track_id: tid,
            quality_key: qk,
        })
        .map_err(|_| anyhow::anyhow!("L1 write queue closed"))?;

        Ok(LUMINA_OK)
    })
}

/// Enqueues a non-blocking FIFO delete of all `l1_stream_urls` entries belonging to `provider_id`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l1_cache_clear_provider(provider_id: *const c_char) -> c_int {
    catch_unwind_ffi(LUMINA_ERR_DATABASE, "lumina_l1_cache_clear_provider", || {
        if provider_id.is_null() {
            set_last_error("provider_id is null");
            return Ok(LUMINA_ERR_NULL_POINTER);
        }
        let pid = unsafe { CStr::from_ptr(provider_id) }
            .to_str()
            .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in provider_id: {e}"))?
            .trim()
            .to_string();
        if pid.is_empty() {
            set_last_error("provider_id must be non-empty");
            return Ok(LUMINA_ERR_GENERAL);
        }

        let engine = get_engine();
        let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
        let Some(pool) = maybe_pool else {
            return Ok(LUMINA_OK);
        };

        let tx = l1_write_sender(&engine);
        tx.send(L1WriteOp::ClearProvider {
            pool,
            provider_id: pid,
        })
        .map_err(|_| anyhow::anyhow!("L1 write queue closed"))?;

        Ok(LUMINA_OK)
    })
}

/// Enqueues a low-priority background SQLite prune deleting rows with `network_epoch < current_epoch`
/// for the specified providers (`provider_ids_csv_or_json` accepts comma-separated IDs, a JSON
/// string array, or null/empty defaulting to `"youtube_music"`).
#[unsafe(no_mangle)]
pub extern "C" fn lumina_l1_cache_prune_stale_epoch(
    provider_ids_csv_or_json: *const c_char,
    current_epoch: u64,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_DATABASE,
        "lumina_l1_cache_prune_stale_epoch",
        || {
            let provider_ids: Vec<String> = if provider_ids_csv_or_json.is_null() {
                vec!["youtube_music".to_string()]
            } else {
                let raw = unsafe { CStr::from_ptr(provider_ids_csv_or_json) }
                    .to_str()
                    .map_err(|e| anyhow::anyhow!("Invalid UTF-8 in provider_ids: {e}"))?
                    .trim();
                if raw.is_empty() {
                    vec!["youtube_music".to_string()]
                } else if raw.starts_with('[') {
                    serde_json::from_str::<Vec<String>>(raw)
                        .map_err(|e| anyhow::anyhow!("Invalid JSON array in provider_ids: {e}"))?
                        .into_iter()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                } else {
                    raw.split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                }
            };

            let engine = get_engine();
            enqueue_prune_stale_epoch(&engine, provider_ids, current_epoch);
            Ok(LUMINA_OK)
        },
    )
}
