part of '../ffi_audio_service.dart';

typedef _FfiWorkerOpHandler = Object? Function(Map<String, Object?> args);

String? _ffiDecodeAndFreeRustString(
  ffi.Pointer<ffi.Uint8> ptr,
  _LuminaStringFreeDart? stringFreeFn,
) {
  if (ptr == ffi.nullptr) return null;
  try {
    var len = 0;
    while (ptr[len] != 0) {
      len++;
    }
    if (len == 0) return '';
    return utf8.decode(ptr.cast<ffi.Uint8>().asTypedList(len));
  } finally {
    stringFreeFn?.call(ptr);
  }
}

class _FfiWorkerNativeHelpers {
  final ffi.DynamicLibrary dylib;
  final _LuminaBytesAllocDart bytesAllocFn;
  final _LuminaBytesFreeDart bytesFreeFn;
  final _LuminaStringFreeDart stringFreeFn;

  _FfiWorkerNativeHelpers(this.dylib)
      : bytesAllocFn = dylib.lookupFunction<_LuminaBytesAllocNative,
            _LuminaBytesAllocDart>('lumina_bytes_alloc'),
        bytesFreeFn = dylib.lookupFunction<_LuminaBytesFreeNative,
            _LuminaBytesFreeDart>('lumina_bytes_free'),
        stringFreeFn = dylib.lookupFunction<_LuminaStringFreeNative,
            _LuminaStringFreeDart>('lumina_string_free');

  F? tryLookup<F>(F Function() lookup) {
    try {
      return lookup();
    } catch (_) {
      return null;
    }
  }

  R withUtf8<R>(String value, R Function(ffi.Pointer<ffi.Uint8>) fn) {
    final encoded = utf8.encode(value);
    final ptr = bytesAllocFn(encoded.length);
    try {
      final view = ptr.asTypedList(encoded.length + 1);
      view.setAll(0, encoded);
      view[encoded.length] = 0;
      return fn(ptr);
    } finally {
      bytesFreeFn(ptr, encoded.length);
    }
  }

  String? takeString(ffi.Pointer<ffi.Uint8> ptr) =>
      _ffiDecodeAndFreeRustString(ptr, stringFreeFn);
}

Map<String, _FfiWorkerOpHandler> _buildFfiReadHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final getTracksFn = h.tryLookup(() => dylib.lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>('lumina_library_get_tracks'));
  final getAlbumsFn = h.tryLookup(() => dylib.lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>('lumina_library_get_albums'));
  final getAlbumDetailFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_get_album_detail'));
  final getArtistDetailFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_get_artist_detail'));
  final searchFn = h.tryLookup(() => dylib.lookupFunction<_LuminaSearchNative, _LuminaSearchDart>('lumina_library_search'));
  final artworkGetFn = h.tryLookup(() => dylib.lookupFunction<_LuminaArtworkGetNative, _LuminaArtworkGetDart>('lumina_artwork_get'));
  final watchListFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_library_watch_list'));
  final getSkippedFilesFn = h.tryLookup(() => dylib.lookupFunction<_LuminaIntToPtrNative, _LuminaIntToPtrDart>('lumina_library_get_skipped_files'));
  final getOverridesFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>('lumina_library_get_metadata_overrides'));
  final lyricsGetFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_lyrics_get'));
  final profileListFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_profile_list'));
  final getDefaultMetaPolicyFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_settings_get_default_metadata_policy'));
  final previewCleanupFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_library_preview_cleanup'));

  return <String, _FfiWorkerOpHandler>{
    'get_tracks': (args) {
      final limit = (args['limit'] as int?) ?? 10000;
      return getTracksFn != null ? h.takeString(getTracksFn(limit)) : null;
    },
    'get_albums': (args) {
      final limit = (args['limit'] as int?) ?? 100;
      return getAlbumsFn != null ? h.takeString(getAlbumsFn(limit)) : null;
    },
    'get_album_detail': (args) {
      final albumId = args['albumId'] as String;
      return getAlbumDetailFn != null
          ? h.takeString(h.withUtf8(albumId, getAlbumDetailFn))
          : null;
    },
    'get_artist_detail': (args) {
      final artistId = args['artistId'] as String;
      return getArtistDetailFn != null
          ? h.takeString(h.withUtf8(artistId, getArtistDetailFn))
          : null;
    },
    'search': (args) {
      final query = args['query'] as String;
      final limit = (args['limit'] as int?) ?? 50;
      return searchFn != null
          ? h.takeString(h.withUtf8(query, (p) => searchFn(p, limit)))
          : null;
    },
    'artwork_get': (args) {
      final payload = args['payload'] as String;
      final maxDim = (args['maxDim'] as int?) ?? 512;
      return artworkGetFn != null
          ? h.takeString(h.withUtf8(payload, (p) => artworkGetFn(p, maxDim)))
          : null;
    },
    'watch_list': (_) => watchListFn != null ? h.takeString(watchListFn()) : null,
    'skipped_files': (args) {
      final includeDismissed = (args['includeDismissed'] as int?) ?? 0;
      return getSkippedFilesFn != null
          ? h.takeString(getSkippedFilesFn(includeDismissed))
          : null;
    },
    'get_metadata_overrides': (args) {
      final entityType = args['entityType'] as String;
      final entityId = args['entityId'] as String;
      return getOverridesFn != null
          ? h.takeString(
              h.withUtf8(
                entityType,
                (pType) => h.withUtf8(
                  entityId,
                  (pId) => getOverridesFn(pType, pId),
                ),
              ),
            )
          : null;
    },
    'get_lyrics': (args) {
      final payload = args['payload'] as String;
      return lyricsGetFn != null
          ? h.takeString(h.withUtf8(payload, lyricsGetFn))
          : null;
    },
    'list_profiles': (_) =>
        profileListFn != null ? h.takeString(profileListFn()) : null,
    'get_default_metadata_policy': (_) => getDefaultMetaPolicyFn != null
        ? h.takeString(getDefaultMetaPolicyFn())
        : null,
    'preview_library_cleanup': (_) =>
        previewCleanupFn != null ? h.takeString(previewCleanupFn()) : null,
    ..._buildFfiAlbumGroupingReadHandlers(h),
    ..._buildFfiFocusTagsFoldersReadHandlers(h),
    ..._buildFfiStep4ReadHandlers(h),
    ..._buildFfiStep5ReadHandlers(h),
  };
}

Map<String, _FfiWorkerOpHandler> _buildFfiWriteHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final libInitFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_library_init'));
  final l2CacheInitFn = h.tryLookup(() => dylib.lookupFunction<_LuminaL2CacheInitNative, _LuminaL2CacheInitDart>('lumina_l2_cache_init'));
  final scanDirFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_scan_dir'));
  final scanStartFn = h.tryLookup(() => dylib.lookupFunction<_LuminaLibraryRescanTagsNative, _LuminaLibraryRescanTagsDart>('lumina_library_scan_start'));
  final rescanStartFn = h.tryLookup(() => dylib.lookupFunction<_LuminaLibraryRescanTagsNative, _LuminaLibraryRescanTagsDart>('lumina_library_rescan_start'));
  final forceRebuildStartFn = h.tryLookup(() => dylib.lookupFunction<_LuminaLibraryRescanTagsNative, _LuminaLibraryRescanTagsDart>('lumina_library_force_rebuild_start'));
  final rescanTagsFn = h.tryLookup(() => dylib.lookupFunction<_LuminaLibraryRescanTagsNative, _LuminaLibraryRescanTagsDart>('lumina_library_rescan_tags'));
  final deduplicateFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_library_deduplicate'));
  final enrichCreditsFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_enrich_credits'));
  final providerSyncFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_provider_sync'));
  final lastErrorMsgFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_last_error_message'));
  final ingestExternalFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_ingest_external_catalog'));
  final watchAddFn = h.tryLookup(() => dylib.lookupFunction<_LuminaWatchAddNative, _LuminaWatchAddDart>('lumina_library_watch_add'));
  final watchRemoveFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_library_watch_remove'));
  final dismissSkippedFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_library_dismiss_skipped_file'));
  final retrySkippedFileFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_retry_skipped_file'));
  final setOverrideFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStr4IntNative, _LuminaStr4IntDart>('lumina_library_set_metadata_override'));
  final clearOverrideFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStr3IntNative, _LuminaStr3IntDart>('lumina_library_clear_metadata_override'));
  final setUserCoverFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_artwork_set_user_cover'));
  final clearUserCoverFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_artwork_clear_user_cover'));
  final setUserLyricsFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_lyrics_set_user_file'));
  final clearUserLyricsFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_lyrics_clear_user_file'));
  final profileCreateFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_profile_create'));
  final profileUpdateFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_profile_update'));
  final profileDeleteFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_profile_delete'));
  final profileSwitchFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_profile_switch'));
  final setDefaultMetaPolicyFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_settings_set_default_metadata_policy'));
  final setEntityMetaPolicyFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStr3IntNative, _LuminaStr3IntDart>('lumina_library_set_entity_meta_policy'));
  final setEntityUserEditsFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStr3IntNative, _LuminaStr3IntDart>('lumina_library_set_entity_user_edits'));
  final revertEntityToFileMetaFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_library_revert_entity_to_file_meta'));
  final rescanAllSkippedFn = h.tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_library_rescan_all_skipped_files'));
  final executeCleanupFn = h.tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_execute_cleanup'));

  String? callDirAndForce(
    _LuminaLibraryRescanTagsDart? fn,
    Map<String, Object?> args,
  ) {
    if (fn == null) return null;
    final dir = (args['directory'] as String?)?.trim() ?? '';
    final force = (args['force'] as bool?) == true ? 1 : 0;
    final ptr = dir.isNotEmpty
        ? h.withUtf8(dir, (p) => fn(p, force))
        : fn(ffi.nullptr, force);
    return h.takeString(ptr);
  }

  return <String, _FfiWorkerOpHandler>{
    'library_init': (args) {
      final dbPath = args['dbPath'] as String;
      return libInitFn != null ? h.withUtf8(dbPath, libInitFn) : -1;
    },
    'l2_cache_init': (args) {
      if (l2CacheInitFn == null) return 0;
      final dir = args['dir'] as String;
      final maxBytes = (args['maxBytes'] as int?) ?? (1024 * 1024 * 1024);
      final targetBytes = (args['targetBytes'] as int?) ?? (800 * 1024 * 1024);
      return h.withUtf8(dir, (p) => l2CacheInitFn(p, maxBytes, targetBytes));
    },
    'scan_dir': (args) {
      final path = args['path'] as String;
      return scanDirFn != null ? h.takeString(h.withUtf8(path, scanDirFn)) : null;
    },
    'scan_start': (args) {
      final path = args['path'] as String;
      final force = (args['force'] as bool?) == true ? 1 : 0;
      return scanStartFn != null
          ? h.takeString(h.withUtf8(path, (p) => scanStartFn(p, force)))
          : null;
    },
    'rescan_start': (args) => callDirAndForce(rescanStartFn, args),
    'force_rebuild_start': (args) => callDirAndForce(forceRebuildStartFn, args),
    'rescan_tags': (args) => callDirAndForce(rescanTagsFn, args),
    'deduplicate': (_) => deduplicateFn != null ? h.takeString(deduplicateFn()) : null,
    'enrich_credits': (args) {
      final payload = args['payload'] as String;
      return enrichCreditsFn != null
          ? h.takeString(h.withUtf8(payload, enrichCreditsFn))
          : null;
    },
    'provider_sync': (args) {
      final kind = args['kind'] as String;
      final raw = providerSyncFn != null
          ? h.takeString(h.withUtf8(kind, providerSyncFn))
          : null;
      final err = raw == null && lastErrorMsgFn != null
          ? h.takeString(lastErrorMsgFn())
          : null;
      return <String?>[raw, err];
    },
    'ingest_external_catalog': (args) {
      final payload = args['payload'] as String;
      return ingestExternalFn != null
          ? h.takeString(h.withUtf8(payload, ingestExternalFn))
          : null;
    },
    'watch_add': (args) {
      final rootPath = args['rootPath'] as String;
      final watchMode = args['watchMode'] as String;
      final pollSec = (args['pollIntervalSec'] as int?) ?? 300;
      return watchAddFn != null
          ? h.takeString(
              h.withUtf8(
                rootPath,
                (pRoot) => h.withUtf8(
                  watchMode,
                  (pMode) => watchAddFn(pRoot, pMode, pollSec),
                ),
              ),
            )
          : null;
    },
    'watch_remove': (args) {
      final rootPath = args['rootPath'] as String;
      return watchRemoveFn != null ? h.withUtf8(rootPath, watchRemoveFn) : -1;
    },
    'dismiss_skipped_file': (args) {
      final skippedId = args['skippedId'] as String;
      return dismissSkippedFn != null ? h.withUtf8(skippedId, dismissSkippedFn) : -1;
    },
    'retry_skipped_file': (args) {
      final skippedId = args['skippedId'] as String;
      return retrySkippedFileFn != null
          ? h.takeString(h.withUtf8(skippedId, retrySkippedFileFn))
          : null;
    },
    'set_metadata_override': (args) {
      if (setOverrideFn == null) return -1;
      final entityType = args['entityType'] as String;
      final entityId = args['entityId'] as String;
      final fieldName = args['fieldName'] as String;
      final valueJson = args['valueJson'] as String;
      return h.withUtf8(
        entityType,
        (pType) => h.withUtf8(
          entityId,
          (pId) => h.withUtf8(
            fieldName,
            (pField) => h.withUtf8(
              valueJson,
              (pVal) => setOverrideFn(pType, pId, pField, pVal),
            ),
          ),
        ),
      );
    },
    'clear_metadata_override': (args) {
      if (clearOverrideFn == null) return -1;
      final entityType = args['entityType'] as String;
      final entityId = args['entityId'] as String;
      final fieldName = args['fieldName'] as String;
      return h.withUtf8(
        entityType,
        (pType) => h.withUtf8(
          entityId,
          (pId) => h.withUtf8(
            fieldName,
            (pField) => clearOverrideFn(pType, pId, pField),
          ),
        ),
      );
    },
    'set_user_cover': (args) {
      if (setUserCoverFn == null) return -1;
      final payload = args['payload'] as String;
      final imagePath = args['imagePath'] as String;
      return h.withUtf8(
        payload,
        (pTarget) => h.withUtf8(
          imagePath,
          (pImage) => setUserCoverFn(pTarget, pImage),
        ),
      );
    },
    'clear_user_cover': (args) {
      final payload = args['payload'] as String;
      return clearUserCoverFn != null ? h.withUtf8(payload, clearUserCoverFn) : -1;
    },
    'set_user_lyrics': (args) {
      if (setUserLyricsFn == null) return -1;
      final payload = args['payload'] as String;
      final filePath = args['filePath'] as String;
      return h.withUtf8(
        payload,
        (pTarget) => h.withUtf8(
          filePath,
          (pFile) => setUserLyricsFn(pTarget, pFile),
        ),
      );
    },
    'clear_user_lyrics': (args) {
      final payload = args['payload'] as String;
      return clearUserLyricsFn != null ? h.withUtf8(payload, clearUserLyricsFn) : -1;
    },
    'create_profile': (args) {
      final payload = args['payload'] as String;
      return profileCreateFn != null
          ? h.takeString(h.withUtf8(payload, profileCreateFn))
          : null;
    },
    'update_profile': (args) {
      if (profileUpdateFn == null) return -1;
      final profileId = args['profileId'] as String;
      final payload = args['payload'] as String;
      return h.withUtf8(
        profileId,
        (pId) => h.withUtf8(payload, (pJson) => profileUpdateFn(pId, pJson)),
      );
    },
    'delete_profile': (args) {
      final profileId = args['profileId'] as String;
      return profileDeleteFn != null ? h.withUtf8(profileId, profileDeleteFn) : -1;
    },
    'switch_profile': (args) {
      final profileId = args['profileId'] as String;
      return profileSwitchFn != null ? h.withUtf8(profileId, profileSwitchFn) : -1;
    },
    'set_default_metadata_policy': (args) {
      final policy = args['policy'] as String;
      return setDefaultMetaPolicyFn != null
          ? h.withUtf8(policy, setDefaultMetaPolicyFn)
          : -1;
    },
    'set_entity_meta_policy': (args) {
      if (setEntityMetaPolicyFn == null) return -1;
      final et = args['entityType'] as String;
      final eid = args['entityId'] as String;
      final policy = args['policy'] as String;
      return h.withUtf8(
        et,
        (pType) => h.withUtf8(
          eid,
          (pId) => h.withUtf8(policy, (pPol) => setEntityMetaPolicyFn(pType, pId, pPol)),
        ),
      );
    },
    'set_entity_user_edits': (args) {
      if (setEntityUserEditsFn == null) return -1;
      final et = args['entityType'] as String;
      final eid = args['entityId'] as String;
      final editsJson = args['editsJson'] as String;
      return h.withUtf8(
        et,
        (pType) => h.withUtf8(
          eid,
          (pId) => h.withUtf8(editsJson, (pEdits) => setEntityUserEditsFn(pType, pId, pEdits)),
        ),
      );
    },
    'revert_entity_to_file_meta': (args) {
      if (revertEntityToFileMetaFn == null) return -1;
      final et = args['entityType'] as String;
      final eid = args['entityId'] as String;
      return h.withUtf8(
        et,
        (pType) => h.withUtf8(eid, (pId) => revertEntityToFileMetaFn(pType, pId)),
      );
    },
    'rescan_all_skipped_files': (_) =>
        rescanAllSkippedFn != null ? h.takeString(rescanAllSkippedFn()) : null,
    'execute_library_cleanup': (args) {
      final optionsJson = args['optionsJson'] as String;
      return executeCleanupFn != null
          ? h.takeString(h.withUtf8(optionsJson, executeCleanupFn))
          : null;
    },
    ..._buildFfiAlbumGroupingWriteHandlers(h),
    ..._buildFfiFocusTagsFoldersWriteHandlers(h),
    ..._buildFfiStep4WriteHandlers(h),
    ..._buildFfiStep5WriteHandlers(h),
  };
}
