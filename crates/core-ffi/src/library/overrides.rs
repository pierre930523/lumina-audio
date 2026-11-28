use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{
    LUMINA_ERR_GENERAL, LUMINA_ERR_NULL_POINTER, LUMINA_OK, catch_unwind_ffi, set_last_error,
    string_to_c_char,
};
use core_db::{DbWriteCoordinator, IngestionRepository};
use core_providers::IngestionPipeline;
use core_types::{ExternalCatalogIngestBatch, MetadataLayer};
use serde_json::json;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_set_metadata_override(
    entity_type: *const c_char,
    entity_id: *const c_char,
    field_name: *const c_char,
    value_json: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_set_metadata_override",
        || {
            if entity_type.is_null()
                || entity_id.is_null()
                || field_name.is_null()
                || value_json.is_null()
            {
                set_last_error("null pointer passed to lumina_library_set_metadata_override");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et = unsafe { CStr::from_ptr(entity_type) }.to_str()?.trim();
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();
            let field = unsafe { CStr::from_ptr(field_name) }.to_str()?.trim();
            let val = unsafe { CStr::from_ptr(value_json) }.to_str()?;

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    IngestionRepository::set_metadata_override(
                        &pool,
                        et,
                        eid,
                        field,
                        val,
                        MetadataLayer::UserEdit,
                    )
                    .await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_clear_metadata_override(
    entity_type: *const c_char,
    entity_id: *const c_char,
    field_name: *const c_char,
) -> c_int {
    catch_unwind_ffi(
        LUMINA_ERR_GENERAL,
        "lumina_library_clear_metadata_override",
        || {
            if entity_type.is_null() || entity_id.is_null() || field_name.is_null() {
                set_last_error("null pointer passed to lumina_library_clear_metadata_override");
                return Ok(LUMINA_ERR_NULL_POINTER);
            }
            let et = unsafe { CStr::from_ptr(entity_type) }.to_str()?.trim();
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();
            let field = unsafe { CStr::from_ptr(field_name) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let coord = DbWriteCoordinator::for_pool(&pool);
            let _ = engine
                .runtime
                .block_on(async {
                    let _wg = coord.write_lock().await;
                    IngestionRepository::clear_metadata_override(&pool, et, eid, field).await
                })
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            Ok(LUMINA_OK)
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_metadata_overrides(
    entity_type: *const c_char,
    entity_id: *const c_char,
) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_metadata_overrides",
        || {
            if entity_type.is_null() || entity_id.is_null() {
                set_last_error("null pointer passed to lumina_library_get_metadata_overrides");
                return Ok(std::ptr::null_mut());
            }
            let et = unsafe { CStr::from_ptr(entity_type) }.to_str()?.trim();
            let eid = unsafe { CStr::from_ptr(entity_id) }.to_str()?.trim();

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let overrides = engine
                .runtime
                .block_on(IngestionRepository::get_overrides_for_entity(
                    &pool, et, eid,
                ))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&overrides)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_ingest_external_catalog(batch_json: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_ingest_external_catalog",
        || {
            if batch_json.is_null() {
                set_last_error("batch_json is null");
                return Ok(std::ptr::null_mut());
            }
            let raw = unsafe { CStr::from_ptr(batch_json) }.to_str()?;
            let batch: ExternalCatalogIngestBatch = serde_json::from_str(raw)?;

            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;
            let rep = engine
                .runtime
                .block_on(IngestionPipeline::ingest_external_catalog(&pool, &batch))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let summary = json!({
                "albums_ingested": rep.albums_inserted + rep.albums_matched,
                "tracks_ingested": rep.tracks_upserted,
                "albums_inserted": rep.albums_inserted,
                "albums_matched": rep.albums_matched,
                "versions_upserted": rep.versions_upserted,
            });
            let json_str = serde_json::to_string(&summary)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}
