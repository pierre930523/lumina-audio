part of '../ffi_audio_service.dart';

Map<String, _FfiWorkerOpHandler> _buildFfiStep4ReadHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final listBookmarksFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
      'lumina_library_list_bookmarks',
    ),
  );
  final listSmartPlaylistsFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
      'lumina_library_list_smart_playlists',
    ),
  );
  final evaluateSmartPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_evaluate_smart_playlist',
    ),
  );
  final listListenLaterFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_list_listen_later',
    ),
  );

  return <String, _FfiWorkerOpHandler>{
    'list_bookmarks': (_) =>
        listBookmarksFn != null ? h.takeString(listBookmarksFn()) : null,
    'list_smart_playlists': (_) => listSmartPlaylistsFn != null
        ? h.takeString(listSmartPlaylistsFn())
        : null,
    'evaluate_smart_playlist': (args) {
      final id = args['id'] as String;
      return evaluateSmartPlaylistFn != null
          ? h.takeString(h.withUtf8(id, evaluateSmartPlaylistFn))
          : null;
    },
    'list_listen_later': (args) {
      if (listListenLaterFn == null) return null;
      final status = (args['status'] as String?)?.trim() ?? '';
      if (status.isEmpty) {
        return h.takeString(listListenLaterFn(ffi.nullptr));
      }
      return h.takeString(h.withUtf8(status, listListenLaterFn));
    },
  };
}

Map<String, _FfiWorkerOpHandler> _buildFfiStep4WriteHandlers(
  _FfiWorkerNativeHelpers h,
) {
  final dylib = h.dylib;
  final setEntityPreferenceFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_set_entity_preference',
    ),
  );
  final createBookmarkFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_create_bookmark',
    ),
  );
  final updateBookmarkFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_update_bookmark',
    ),
  );
  final deleteBookmarkFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_delete_bookmark',
    ),
  );
  final reorderBookmarksFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_reorder_bookmarks',
    ),
  );
  final createSmartPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_create_smart_playlist',
    ),
  );
  final updateSmartPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_update_smart_playlist',
    ),
  );
  final deleteSmartPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_delete_smart_playlist',
    ),
  );
  final duplicateSmartPlaylistFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_duplicate_smart_playlist',
    ),
  );
  final addListenLaterFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_add_listen_later',
    ),
  );
  final markListenLaterStatusFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_mark_listen_later_status',
    ),
  );
  final updateListenLaterNoteFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_update_listen_later_note',
    ),
  );
  final removeListenLaterFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
      'lumina_library_remove_listen_later',
    ),
  );
  final promoteListenLaterFn = h.tryLookup(
    () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
      'lumina_library_promote_listen_later',
    ),
  );

  String? callTwoStr(
    _LuminaStr2PtrDart? fn,
    String first,
    String second,
  ) {
    if (fn == null) return null;
    return h.takeString(
      h.withUtf8(first, (p1) => h.withUtf8(second, (p2) => fn(p1, p2))),
    );
  }

  return <String, _FfiWorkerOpHandler>{
    'set_entity_preference': (args) {
      final payloadJson = args['payloadJson'] as String;
      return setEntityPreferenceFn != null
          ? h.takeString(h.withUtf8(payloadJson, setEntityPreferenceFn))
          : null;
    },
    'create_bookmark': (args) {
      final payloadJson = args['payloadJson'] as String;
      return createBookmarkFn != null
          ? h.takeString(h.withUtf8(payloadJson, createBookmarkFn))
          : null;
    },
    'update_bookmark': (args) => callTwoStr(
      updateBookmarkFn,
      args['id'] as String,
      args['payloadJson'] as String,
    ),
    'delete_bookmark': (args) {
      final id = args['id'] as String;
      return deleteBookmarkFn != null
          ? h.takeString(h.withUtf8(id, deleteBookmarkFn))
          : null;
    },
    'reorder_bookmarks': (args) {
      final payloadJson = args['payloadJson'] as String;
      return reorderBookmarksFn != null
          ? h.takeString(h.withUtf8(payloadJson, reorderBookmarksFn))
          : null;
    },
    'create_smart_playlist': (args) {
      final payloadJson = args['payloadJson'] as String;
      return createSmartPlaylistFn != null
          ? h.takeString(h.withUtf8(payloadJson, createSmartPlaylistFn))
          : null;
    },
    'update_smart_playlist': (args) => callTwoStr(
      updateSmartPlaylistFn,
      args['id'] as String,
      args['payloadJson'] as String,
    ),
    'delete_smart_playlist': (args) {
      final id = args['id'] as String;
      return deleteSmartPlaylistFn != null
          ? h.takeString(h.withUtf8(id, deleteSmartPlaylistFn))
          : null;
    },
    'duplicate_smart_playlist': (args) {
      final id = args['id'] as String;
      return duplicateSmartPlaylistFn != null
          ? h.takeString(h.withUtf8(id, duplicateSmartPlaylistFn))
          : null;
    },
    'add_listen_later': (args) {
      final payloadJson = args['payloadJson'] as String;
      return addListenLaterFn != null
          ? h.takeString(h.withUtf8(payloadJson, addListenLaterFn))
          : null;
    },
    'mark_listen_later_status': (args) => callTwoStr(
      markListenLaterStatusFn,
      args['id'] as String,
      args['payloadJson'] as String,
    ),
    'update_listen_later_note': (args) => callTwoStr(
      updateListenLaterNoteFn,
      args['id'] as String,
      args['payloadJson'] as String,
    ),
    'remove_listen_later': (args) {
      final id = args['id'] as String;
      return removeListenLaterFn != null
          ? h.takeString(h.withUtf8(id, removeListenLaterFn))
          : null;
    },
    'promote_listen_later': (args) => callTwoStr(
      promoteListenLaterFn,
      args['id'] as String,
      args['payloadJson'] as String,
    ),
  };
}
