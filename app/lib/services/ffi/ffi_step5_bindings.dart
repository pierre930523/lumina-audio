part of '../ffi_audio_service.dart';

/// Looks up all 22 Library Step 5 native C-ABI symbols (global engine singleton).
mixin _FfiStep5BindingsMixin on _FfiAudioServiceBase {
  _LuminaVoidPtrDart? _libListStaticPlaylistsFn;
  _LuminaStrPtrDart? _libCreateStaticPlaylistFn;
  _LuminaStrPtrDart? _libGetStaticPlaylistDetailFn;
  _LuminaStrIntDart? _libDeleteStaticPlaylistFn;
  _LuminaStr2PtrDart? _libAddTracksToStaticPlaylistFn;
  _LuminaStrPtrDart? _libAnalyzePlaylistImprovementsFn;
  _LuminaStr2PtrDart? _libApplyPlaylistImprovementsFn;
  _LuminaStrPtrDart? _libListPlaylistSnapshotsFn;
  _LuminaStrPtrDart? _libRevertPlaylistSnapshotFn;
  _LuminaStrPtrDart? _libGetBulkEditSummaryFn;
  _LuminaStrPtrDart? _libApplyBulkEditFn;
  _LuminaStrPtrDart? _libGetAlbumAssetsFn;
  _LuminaStrPtrDart? _libReadAlbumAssetContentFn;
  _LuminaVoidPtrDart? _libGetBackupSettingsFn;
  _LuminaStrPtrDart? _libUpdateBackupSettingsFn;
  _LuminaLimitPtrDart? _libListBackupHistoryFn;
  _LuminaStrPtrDart? _libCreateBackupFn;
  _LuminaStrPtrDart? _libRestoreBackupFn;
  _LuminaStrPtrDart? _libExportCatalogFn;
  _LuminaStrPtrDart? _libStartAudioExportFn;
  _LuminaStrPtrDart? _libGetAudioExportProgressFn;
  _LuminaStrIntDart? _libCancelAudioExportFn;

  @override
  void _bindStep5Symbols(ffi.DynamicLibrary dylib) {
    F? tryLookup<F>(F Function() lookup) {
      try {
        return lookup();
      } catch (_) {
        return null;
      }
    }

    _libListStaticPlaylistsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_list_static_playlists',
      ),
    );
    _libCreateStaticPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_create_static_playlist',
      ),
    );
    _libGetStaticPlaylistDetailFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_static_playlist_detail',
      ),
    );
    _libDeleteStaticPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_delete_static_playlist',
      ),
    );
    _libAddTracksToStaticPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_add_tracks_to_static_playlist',
      ),
    );
    _libAnalyzePlaylistImprovementsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_analyze_playlist_improvements',
      ),
    );
    _libApplyPlaylistImprovementsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_apply_playlist_improvements',
      ),
    );
    _libListPlaylistSnapshotsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_list_playlist_snapshots',
      ),
    );
    _libRevertPlaylistSnapshotFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_revert_playlist_snapshot',
      ),
    );
    _libGetBulkEditSummaryFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_bulk_edit_summary',
      ),
    );
    _libApplyBulkEditFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_apply_bulk_edit',
      ),
    );
    _libGetAlbumAssetsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_album_assets',
      ),
    );
    _libReadAlbumAssetContentFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_read_album_asset_content',
      ),
    );
    _libGetBackupSettingsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_get_backup_settings',
      ),
    );
    _libUpdateBackupSettingsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_update_backup_settings',
      ),
    );
    _libListBackupHistoryFn = tryLookup(
      () => dylib.lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>(
        'lumina_library_list_backup_history',
      ),
    );
    _libCreateBackupFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_create_backup',
      ),
    );
    _libRestoreBackupFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_restore_backup',
      ),
    );
    _libExportCatalogFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_export_catalog',
      ),
    );
    _libStartAudioExportFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_start_audio_export',
      ),
    );
    _libGetAudioExportProgressFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_audio_export_progress',
      ),
    );
    _libCancelAudioExportFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_cancel_audio_export',
      ),
    );
  }
}
