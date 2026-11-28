use std::ffi::CStr;
use std::os::raw::c_char;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use core_db::AlbumAssetRepository;
use core_types::{AlbumAssetKind, AlbumAssetSourceKind, AlbumAssetsResponse};
use serde_json::json;

use super::ensure_db_pool;
use crate::engine::get_engine;
use crate::error::{catch_unwind_ffi, string_to_c_char};

fn read_c_str<'a>(ptr: *const c_char, name: &str) -> anyhow::Result<&'a str> {
    if ptr.is_null() {
        anyhow::bail!("{name} is null");
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

/// Fetches PDF booklets & gallery images for an album version or canonical album ID as JSON.
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_get_album_assets(album_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_get_album_assets",
        || {
            let aid = read_c_str(album_id, "album_id")?.trim();
            let engine = get_engine();
            let maybe_pool = engine.db_pool.read().ok().and_then(|g| g.clone());
            let Some(pool) = maybe_pool else {
                let empty = AlbumAssetsResponse {
                    album_version_id: aid.to_string(),
                    pdfs: Vec::new(),
                    images: Vec::new(),
                    total_count: 0,
                };
                return Ok(string_to_c_char(&serde_json::to_string(&empty)?));
            };
            let resp = engine
                .runtime
                .block_on(AlbumAssetRepository::get_album_assets(&pool, aid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let json_str = serde_json::to_string(&resp)?;
            Ok(string_to_c_char(&json_str))
        },
    )
}

/// Reads a registered album asset safely and returns a JSON payload:
/// `{"mime_type", "display_name", "file_path", "data_base64"}`.
///
/// For on-disk PDF booklets, returns the verified canonical `file_path` and omits `data_base64`
/// to avoid copying multi-megabyte PDFs across FFI. For images and embedded pictures, returns
/// `data_base64` (plus verified `file_path` when file-backed).
/// Caller must free returned pointer with `lumina_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn lumina_library_read_album_asset_content(asset_id: *const c_char) -> *mut c_char {
    catch_unwind_ffi(
        std::ptr::null_mut(),
        "lumina_library_read_album_asset_content",
        || {
            let aid = read_c_str(asset_id, "asset_id")?.trim();
            let engine = get_engine();
            let pool = ensure_db_pool(&engine)?;

            let record = engine
                .runtime
                .block_on(AlbumAssetRepository::get_asset_by_id(&pool, aid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?
                .ok_or_else(|| anyhow::anyhow!("Album asset '{aid}' not found"))?;

            if record.asset_kind == AlbumAssetKind::Pdf
                && record.source_kind == AlbumAssetSourceKind::File
            {
                let (mime_type, display_name, canonical_path) = engine
                    .runtime
                    .block_on(core_providers::resolve_safe_asset_file_path(&pool, aid))
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                let payload = json!({
                    "mime_type": mime_type,
                    "display_name": display_name,
                    "file_path": canonical_path.to_string_lossy(),
                    "data_base64": serde_json::Value::Null,
                });
                return Ok(string_to_c_char(&serde_json::to_string(&payload)?));
            }

            let file_path_opt = if record.source_kind == AlbumAssetSourceKind::File {
                let (_, _, canonical_path) = engine
                    .runtime
                    .block_on(core_providers::resolve_safe_asset_file_path(&pool, aid))
                    .map_err(|e| anyhow::anyhow!(e.to_string()))?;
                Some(canonical_path.to_string_lossy().to_string())
            } else {
                None
            };

            let (mime_type, display_name, bytes) = engine
                .runtime
                .block_on(core_providers::read_album_asset_bytes(&pool, aid))
                .map_err(|e| anyhow::anyhow!(e.to_string()))?;
            let data_base64 = BASE64_STANDARD.encode(&bytes);

            let payload = json!({
                "mime_type": mime_type,
                "display_name": display_name,
                "file_path": file_path_opt,
                "data_base64": data_base64,
            });
            Ok(string_to_c_char(&serde_json::to_string(&payload)?))
        },
    )
}
