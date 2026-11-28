part of '../ffi_audio_service.dart';

Map<String, _FfiWorkerOpHandler> _buildFfiFocusTagsFoldersReadHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final focusQueryFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_focus_query',
    ),
  );
  final focusFacetsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_focus_facets',
    ),
  );
  final listTagsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
      'lumina_library_list_tags',
    ),
  );
  final getEntityTagsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_get_entity_tags',
    ),
  );
  final getFolderRootsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
      'lumina_library_get_folder_roots',
    ),
  );
  final getFolderContentsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_folder_contents',
    ),
  );
  final getFolderTrackIdsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_get_folder_recursive_track_ids',
    ),
  );

  return <String, _FfiWorkerOpHandler>{
    'focus_query': (args) {
      final requestJson = args['requestJson'] as String;
      return focusQueryFn != null
          ? h.takeString(h.withUtf8(requestJson, focusQueryFn))
          : null;
    },
    'focus_facets': (args) {
      final queryJson = args['queryJson'] as String;
      return focusFacetsFn != null
          ? h.takeString(h.withUtf8(queryJson, focusFacetsFn))
          : null;
    },
    'list_tags': (_) => listTagsFn != null ? h.takeString(listTagsFn()) : null,
    'get_entity_tags': (args) {
      if (getEntityTagsFn == null) return null;
      final entityType = args['entityType'] as String;
      final entityId = args['entityId'] as String;
      return h.takeString(
        h.withUtf8(
          entityType,
          (pType) => h.withUtf8(entityId, (pId) => getEntityTagsFn(pType, pId)),
        ),
      );
    },
    'get_folder_roots': (_) =>
        getFolderRootsFn != null ? h.takeString(getFolderRootsFn()) : null,
    'get_folder_contents': (args) {
      final folderId = args['folderId'] as String;
      return getFolderContentsFn != null
          ? h.takeString(h.withUtf8(folderId, getFolderContentsFn))
          : null;
    },
    'get_folder_recursive_track_ids': (args) {
      final folderId = args['folderId'] as String;
      return getFolderTrackIdsFn != null
          ? h.takeString(h.withUtf8(folderId, getFolderTrackIdsFn))
          : null;
    },
  };
}

Map<String, _FfiWorkerOpHandler> _buildFfiFocusTagsFoldersWriteHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final createTagFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_create_tag',
    ),
  );
  final updateTagFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_update_tag',
    ),
  );
  final deleteTagFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
      'lumina_library_delete_tag',
    ),
  );
  final linkTagParentFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
      'lumina_library_link_tag_parent',
    ),
  );
  final unlinkTagParentFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
      'lumina_library_unlink_tag_parent',
    ),
  );
  final batchTagItemsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_batch_tag_items',
    ),
  );

  return <String, _FfiWorkerOpHandler>{
    'create_tag': (args) {
      final payloadJson = args['payloadJson'] as String;
      return createTagFn != null
          ? h.takeString(h.withUtf8(payloadJson, createTagFn))
          : null;
    },
    'update_tag': (args) {
      final payloadJson = args['payloadJson'] as String;
      return updateTagFn != null
          ? h.takeString(h.withUtf8(payloadJson, updateTagFn))
          : null;
    },
    'delete_tag': (args) {
      final tagId = args['tagId'] as String;
      return deleteTagFn != null ? h.withUtf8(tagId, deleteTagFn) : -1;
    },
    'link_tag_parent': (args) {
      final payloadJson = args['payloadJson'] as String;
      return linkTagParentFn != null
          ? h.withUtf8(payloadJson, linkTagParentFn)
          : -1;
    },
    'unlink_tag_parent': (args) {
      final payloadJson = args['payloadJson'] as String;
      return unlinkTagParentFn != null
          ? h.withUtf8(payloadJson, unlinkTagParentFn)
          : -1;
    },
    'batch_tag_items': (args) {
      final payloadJson = args['payloadJson'] as String;
      return batchTagItemsFn != null
          ? h.takeString(h.withUtf8(payloadJson, batchTagItemsFn))
          : null;
    },
  };
}
