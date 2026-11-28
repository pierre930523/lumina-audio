part of '../ffi_audio_service.dart';

Map<String, _FfiWorkerOpHandler> _buildFfiAlbumGroupingReadHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final getAlbumsWithOptionsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_albums_with_options',
    ),
  );
  return <String, _FfiWorkerOpHandler>{
    'get_albums_with_options': (args) {
      final optionsJson = args['optionsJson'] as String;
      return getAlbumsWithOptionsFn != null
          ? h.takeString(h.withUtf8(optionsJson, getAlbumsWithOptionsFn))
          : null;
    },
  };
}

Map<String, _FfiWorkerOpHandler> _buildFfiAlbumGroupingWriteHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final setPrimaryFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_set_primary_version',
    ),
  );
  final resetPrimaryFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_reset_primary_version',
    ),
  );
  final mergeVersionsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_merge_album_versions',
    ),
  );
  final splitVersionFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_split_album_version',
    ),
  );
  final groupVersionsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_group_alternate_versions',
    ),
  );
  final ungroupVersionFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_ungroup_version',
    ),
  );
  final setVersionHiddenFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrI32PtrNative, _LuminaStrI32PtrDart>(
      'lumina_library_set_version_hidden',
    ),
  );
  final resetGroupingFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_reset_album_grouping',
    ),
  );

  return <String, _FfiWorkerOpHandler>{
    'set_primary_version': (args) {
      if (setPrimaryFn == null) return null;
      final groupId = args['groupId'] as String;
      final versionId = args['versionId'] as String;
      return h.takeString(
        h.withUtf8(
          groupId,
          (pGroup) => h.withUtf8(
            versionId,
            (pVer) => setPrimaryFn(pGroup, pVer),
          ),
        ),
      );
    },
    'reset_primary_version': (args) {
      final groupId = args['groupId'] as String;
      return resetPrimaryFn != null
          ? h.takeString(h.withUtf8(groupId, resetPrimaryFn))
          : null;
    },
    'merge_album_versions': (args) {
      final payloadJson = args['payloadJson'] as String;
      return mergeVersionsFn != null
          ? h.takeString(h.withUtf8(payloadJson, mergeVersionsFn))
          : null;
    },
    'split_album_version': (args) {
      final payloadJson = args['payloadJson'] as String;
      return splitVersionFn != null
          ? h.takeString(h.withUtf8(payloadJson, splitVersionFn))
          : null;
    },
    'group_alternate_versions': (args) {
      final payloadJson = args['payloadJson'] as String;
      return groupVersionsFn != null
          ? h.takeString(h.withUtf8(payloadJson, groupVersionsFn))
          : null;
    },
    'ungroup_version': (args) {
      final versionId = args['versionId'] as String;
      return ungroupVersionFn != null
          ? h.takeString(h.withUtf8(versionId, ungroupVersionFn))
          : null;
    },
    'set_version_hidden': (args) {
      if (setVersionHiddenFn == null) return null;
      final versionId = args['versionId'] as String;
      final isHidden = (args['isHidden'] as bool?) == true ? 1 : 0;
      return h.takeString(
        h.withUtf8(versionId, (pVer) => setVersionHiddenFn(pVer, isHidden)),
      );
    },
    'reset_album_grouping': (args) {
      final versionId = args['versionId'] as String;
      return resetGroupingFn != null
          ? h.takeString(h.withUtf8(versionId, resetGroupingFn))
          : null;
    },
  };
}
