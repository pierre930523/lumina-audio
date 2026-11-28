part of '../ffi_audio_service.dart';

/// Looks up all 18 Library Step 4 native C-ABI symbols (global engine singleton).
mixin _FfiStep4BindingsMixin on _FfiAudioServiceBase {
  _LuminaStrPtrDart? _libSetEntityPreferenceFn;
  _LuminaVoidPtrDart? _libListBookmarksFn;
  _LuminaStrPtrDart? _libCreateBookmarkFn;
  _LuminaStr2PtrDart? _libUpdateBookmarkFn;
  _LuminaStrPtrDart? _libDeleteBookmarkFn;
  _LuminaStrPtrDart? _libReorderBookmarksFn;
  _LuminaVoidPtrDart? _libListSmartPlaylistsFn;
  _LuminaStrPtrDart? _libCreateSmartPlaylistFn;
  _LuminaStr2PtrDart? _libUpdateSmartPlaylistFn;
  _LuminaStrPtrDart? _libDeleteSmartPlaylistFn;
  _LuminaStrPtrDart? _libDuplicateSmartPlaylistFn;
  _LuminaStrPtrDart? _libEvaluateSmartPlaylistFn;
  _LuminaStrPtrDart? _libListListenLaterFn;
  _LuminaStrPtrDart? _libAddListenLaterFn;
  _LuminaStr2PtrDart? _libMarkListenLaterStatusFn;
  _LuminaStr2PtrDart? _libUpdateListenLaterNoteFn;
  _LuminaStrPtrDart? _libRemoveListenLaterFn;
  _LuminaStr2PtrDart? _libPromoteListenLaterFn;

  @override
  void _bindStep4Symbols(ffi.DynamicLibrary dylib) {
    F? tryLookup<F>(F Function() lookup) {
      try {
        return lookup();
      } catch (_) {
        return null;
      }
    }

    _libSetEntityPreferenceFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_set_entity_preference',
      ),
    );
    _libListBookmarksFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_list_bookmarks',
      ),
    );
    _libCreateBookmarkFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_create_bookmark',
      ),
    );
    _libUpdateBookmarkFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_update_bookmark',
      ),
    );
    _libDeleteBookmarkFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_delete_bookmark',
      ),
    );
    _libReorderBookmarksFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_reorder_bookmarks',
      ),
    );
    _libListSmartPlaylistsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_list_smart_playlists',
      ),
    );
    _libCreateSmartPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_create_smart_playlist',
      ),
    );
    _libUpdateSmartPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_update_smart_playlist',
      ),
    );
    _libDeleteSmartPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_delete_smart_playlist',
      ),
    );
    _libDuplicateSmartPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_duplicate_smart_playlist',
      ),
    );
    _libEvaluateSmartPlaylistFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_evaluate_smart_playlist',
      ),
    );
    _libListListenLaterFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_list_listen_later',
      ),
    );
    _libAddListenLaterFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_add_listen_later',
      ),
    );
    _libMarkListenLaterStatusFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_mark_listen_later_status',
      ),
    );
    _libUpdateListenLaterNoteFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_update_listen_later_note',
      ),
    );
    _libRemoveListenLaterFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_remove_listen_later',
      ),
    );
    _libPromoteListenLaterFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_promote_listen_later',
      ),
    );
  }
}
