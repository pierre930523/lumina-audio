part of '../ffi_audio_service.dart';

Map<String, _FfiWorkerOpHandler> _buildFfiStep5ReadHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final listStaticPlaylistsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
      'lumina_library_list_static_playlists',
    ),
  );
  final getStaticPlaylistDetailFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_static_playlist_detail',
    ),
  );
  final analyzeImprovementsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_analyze_playlist_improvements',
    ),
  );
  final listSnapshotsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_list_playlist_snapshots',
    ),
  );
  final getBulkEditSummaryFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_bulk_edit_summary',
    ),
  );
  final getAlbumAssetsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_album_assets',
    ),
  );
  final readAssetContentFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_read_album_asset_content',
    ),
  );
  final getBackupSettingsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
      'lumina_library_get_backup_settings',
    ),
  );
  final listBackupHistoryFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>(
      'lumina_library_list_backup_history',
    ),
  );
  final getAudioExportProgressFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_audio_export_progress',
    ),
  );

  String? callOneStr(_LuminaStrPtrDart? fn, String value) =>
      fn != null ? h.takeString(h.withUtf8(value, fn)) : null;

  return <String, _FfiWorkerOpHandler>{
    'list_static_playlists': (_) => listStaticPlaylistsFn != null
        ? h.takeString(listStaticPlaylistsFn())
        : null,
    'get_static_playlist_detail': (args) =>
        callOneStr(getStaticPlaylistDetailFn, args['playlistId'] as String),
    'analyze_playlist_improvements': (args) =>
        callOneStr(analyzeImprovementsFn, args['playlistId'] as String),
    'list_playlist_snapshots': (args) =>
        callOneStr(listSnapshotsFn, args['playlistId'] as String),
    'get_bulk_edit_summary': (args) =>
        callOneStr(getBulkEditSummaryFn, args['payloadJson'] as String),
    'get_album_assets': (args) =>
        callOneStr(getAlbumAssetsFn, args['albumId'] as String),
    'read_album_asset_content': (args) =>
        callOneStr(readAssetContentFn, args['assetId'] as String),
    'get_backup_settings': (_) => getBackupSettingsFn != null
        ? h.takeString(getBackupSettingsFn())
        : null,
    'list_backup_history': (args) {
      final limit = (args['limit'] as int?) ?? 50;
      return listBackupHistoryFn != null
          ? h.takeString(listBackupHistoryFn(limit))
          : null;
    },
    'get_audio_export_progress': (args) =>
        callOneStr(getAudioExportProgressFn, args['jobId'] as String),
  };
}

Map<String, _FfiWorkerOpHandler> _buildFfiStep5WriteHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final createStaticPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_create_static_playlist',
    ),
  );
  final deleteStaticPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
      'lumina_library_delete_static_playlist',
    ),
  );
  final addTracksStaticPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_add_tracks_to_static_playlist',
    ),
  );
  final applyImprovementsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_apply_playlist_improvements',
    ),
  );
  final revertSnapshotFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_revert_playlist_snapshot',
    ),
  );
  final applyBulkEditFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_apply_bulk_edit',
    ),
  );
  final updateBackupSettingsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_update_backup_settings',
    ),
  );
  final createBackupFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_create_backup',
    ),
  );
  final restoreBackupFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_restore_backup',
    ),
  );
  final exportCatalogFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_export_catalog',
    ),
  );
  final startAudioExportFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_start_audio_export',
    ),
  );
  final cancelAudioExportFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
      'lumina_library_cancel_audio_export',
    ),
  );

  String? callOneStr(_LuminaStrPtrDart? fn, String value) =>
      fn != null ? h.takeString(h.withUtf8(value, fn)) : null;

  String? callTwoStr(_LuminaStr2PtrDart? fn, String first, String second) =>
      fn != null
      ? h.takeString(
          h.withUtf8(first, (p1) => h.withUtf8(second, (p2) => fn(p1, p2))),
        )
      : null;

  return <String, _FfiWorkerOpHandler>{
    'create_static_playlist': (args) =>
        callOneStr(createStaticPlaylistFn, args['payloadJson'] as String),
    'delete_static_playlist': (args) {
      final playlistId = args['playlistId'] as String;
      return deleteStaticPlaylistFn != null
          ? h.withUtf8(playlistId, deleteStaticPlaylistFn)
          : -1;
    },
    'add_tracks_to_static_playlist': (args) => callTwoStr(
      addTracksStaticPlaylistFn,
      args['playlistId'] as String,
      args['payloadJson'] as String,
    ),
    'apply_playlist_improvements': (args) => callTwoStr(
      applyImprovementsFn,
      args['playlistId'] as String,
      args['payloadJson'] as String,
    ),
    'revert_playlist_snapshot': (args) =>
        callOneStr(revertSnapshotFn, args['snapshotId'] as String),
    'apply_bulk_edit': (args) =>
        callOneStr(applyBulkEditFn, args['payloadJson'] as String),
    'update_backup_settings': (args) =>
        callOneStr(updateBackupSettingsFn, args['payloadJson'] as String),
    'create_library_backup': (args) =>
        callOneStr(createBackupFn, args['payloadJson'] as String),
    'restore_library_backup': (args) =>
        callOneStr(restoreBackupFn, args['payloadJson'] as String),
    'export_catalog': (args) =>
        callOneStr(exportCatalogFn, args['payloadJson'] as String),
    'start_audio_export': (args) =>
        callOneStr(startAudioExportFn, args['payloadJson'] as String),
    'cancel_audio_export': (args) {
      final jobId = args['jobId'] as String;
      return cancelAudioExportFn != null
          ? h.withUtf8(jobId, cancelAudioExportFn)
          : -1;
    },
  };
}
