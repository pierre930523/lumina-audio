part of '../ffi_audio_service.dart';

/// Implements Library Step 4 Tri-State Preferences, Bookmarks, and Smart
/// Playlists over FFI. Listen Later & Unified Queue ops live in
/// [_FfiStep4ListenLaterMixin].
mixin _FfiStep4Mixin on _FfiAudioServiceBase, _FfiStep4BindingsMixin {
  bool get _useRemoteStep4Client =>
      _remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac;

  bool _parseStep4DeletedFlag(String? raw) {
    if (_disposed || raw == null || raw.isEmpty) return false;
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      if (decoded.containsKey('deleted')) return decoded['deleted'] == true;
      if (decoded.containsKey('ok')) return decoded['ok'] == true;
    }
    return true;
  }

  void _syncLocalTrackPreference(String trackId, int preference) {
    var queueChanged = false;
    if (_libraryTracks.isNotEmpty) {
      _libraryTracks = List<TrackInfo>.unmodifiable(
        _libraryTracks.map(
          (t) => t.id == trackId ? t.copyWith(preference: preference) : t,
        ),
      );
    }
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) {
        _queue[i] = _queue[i].copyWith(preference: preference);
        queueChanged = true;
      }
    }
    if (_state.track?.id == trackId) {
      _emitState(
        _state.copyWith(track: _state.track!.copyWith(preference: preference)),
      );
    }
    if (queueChanged && !_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
  }

  @override
  Future<SetEntityPreferenceResponse?> setEntityPreference(
    String entityType,
    String entityId,
    int preference,
  ) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.setEntityPreference(
        entityType,
        entityId,
        preference,
      );
    }
    if (!isNativeBound || _libSetEntityPreferenceFn == null) {
      return _delegate.setEntityPreference(entityType, entityId, preference);
    }
    final payload = jsonEncode(<String, dynamic>{
      'entity_type': entityType,
      'entity_id': entityId,
      'preference': preference,
    });
    final raw = await _callWriteWorker<String>('set_entity_preference', {
      'payloadJson': payload,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final res = SetEntityPreferenceResponse.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      if (res.entityType == 'track') {
        _syncLocalTrackPreference(res.entityId, res.preference);
      }
      return res;
    }
    return null;
  }

  @override
  Future<List<BookmarkItem>> listBookmarks() async {
    if (_useRemoteStep4Client) return _remoteClient!.listBookmarks();
    if (!isNativeBound || _libListBookmarksFn == null) {
      return _delegate.listBookmarks();
    }
    final raw = await _callReadWorker<String>('list_bookmarks');
    if (_disposed || raw == null || raw.isEmpty) return const <BookmarkItem>[];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => BookmarkItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <BookmarkItem>[];
  }

  @override
  Future<BookmarkItem?> createBookmark({
    required String name,
    required String targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.createBookmark(
        name: name,
        targetRoute: targetRoute,
        focusQueryJson: focusQueryJson,
        viewStateJson: viewStateJson,
      );
    }
    if (!isNativeBound || _libCreateBookmarkFn == null) {
      return _delegate.createBookmark(
        name: name,
        targetRoute: targetRoute,
        focusQueryJson: focusQueryJson,
        viewStateJson: viewStateJson,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
      'name': name,
      'target_route': targetRoute,
      'focus_query_json': ?focusQueryJson,
      'view_state_json': ?viewStateJson,
    });
    final raw = await _callWriteWorker<String>('create_bookmark', {
      'payloadJson': payload,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? BookmarkItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<BookmarkItem?> updateBookmark(
    String id, {
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.updateBookmark(
        id,
        name: name,
        targetRoute: targetRoute,
        focusQueryJson: focusQueryJson,
        viewStateJson: viewStateJson,
      );
    }
    if (!isNativeBound || _libUpdateBookmarkFn == null) {
      return _delegate.updateBookmark(
        id,
        name: name,
        targetRoute: targetRoute,
        focusQueryJson: focusQueryJson,
        viewStateJson: viewStateJson,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
      'id': id,
      'name': ?name,
      'target_route': ?targetRoute,
      'focus_query_json': ?focusQueryJson,
      'view_state_json': ?viewStateJson,
    });
    final raw = await _callWriteWorker<String>('update_bookmark', {
      'id': id,
      'payloadJson': payload,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? BookmarkItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<bool> deleteBookmark(String id) async {
    if (_useRemoteStep4Client) return _remoteClient!.deleteBookmark(id);
    if (!isNativeBound || _libDeleteBookmarkFn == null) {
      return _delegate.deleteBookmark(id);
    }
    final raw = await _callWriteWorker<String>('delete_bookmark', {'id': id});
    return _parseStep4DeletedFlag(raw);
  }

  @override
  Future<bool> reorderBookmarks(List<String> orderedIds) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.reorderBookmarks(orderedIds);
    }
    if (!isNativeBound || _libReorderBookmarksFn == null) {
      return _delegate.reorderBookmarks(orderedIds);
    }
    final raw = await _callWriteWorker<String>('reorder_bookmarks', {
      'payloadJson': jsonEncode(<String, dynamic>{'ordered_ids': orderedIds}),
    });
    return _parseStep4DeletedFlag(raw);
  }

  @override
  Future<List<SmartPlaylistItem>> listSmartPlaylists() async {
    if (_useRemoteStep4Client) return _remoteClient!.listSmartPlaylists();
    if (!isNativeBound || _libListSmartPlaylistsFn == null) {
      return _delegate.listSmartPlaylists();
    }
    final raw = await _callReadWorker<String>('list_smart_playlists');
    if (_disposed || raw == null || raw.isEmpty) {
      return const <SmartPlaylistItem>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => SmartPlaylistItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <SmartPlaylistItem>[];
  }

  @override
  Future<SmartPlaylistItem?> createSmartPlaylist({
    required String name,
    String description = '',
    required String focusQueryJson,
    bool excludeBanned = true,
    int? limitCount,
    bool isPinned = true,
  }) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.createSmartPlaylist(
        name: name,
        description: description,
        focusQueryJson: focusQueryJson,
        excludeBanned: excludeBanned,
        limitCount: limitCount,
        isPinned: isPinned,
      );
    }
    if (!isNativeBound || _libCreateSmartPlaylistFn == null) {
      return _delegate.createSmartPlaylist(
        name: name,
        description: description,
        focusQueryJson: focusQueryJson,
        excludeBanned: excludeBanned,
        limitCount: limitCount,
        isPinned: isPinned,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
      'name': name,
      'description': description,
      'focus_query_json': focusQueryJson,
      'exclude_banned': excludeBanned,
      'limit_count': ?limitCount,
      'is_pinned': isPinned,
    });
    final raw = await _callWriteWorker<String>('create_smart_playlist', {
      'payloadJson': payload,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? SmartPlaylistItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<SmartPlaylistItem?> updateSmartPlaylist(
    String id, {
    String? name,
    String? description,
    String? focusQueryJson,
    bool? excludeBanned,
    int? limitCount,
    bool clearLimitCount = false,
    bool? isPinned,
    int? sortOrder,
  }) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.updateSmartPlaylist(
        id,
        name: name,
        description: description,
        focusQueryJson: focusQueryJson,
        excludeBanned: excludeBanned,
        limitCount: limitCount,
        clearLimitCount: clearLimitCount,
        isPinned: isPinned,
        sortOrder: sortOrder,
      );
    }
    if (!isNativeBound || _libUpdateSmartPlaylistFn == null) {
      return _delegate.updateSmartPlaylist(
        id,
        name: name,
        description: description,
        focusQueryJson: focusQueryJson,
        excludeBanned: excludeBanned,
        limitCount: limitCount,
        clearLimitCount: clearLimitCount,
        isPinned: isPinned,
        sortOrder: sortOrder,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
      'id': id,
      'name': ?name,
      'description': ?description,
      'focus_query_json': ?focusQueryJson,
      'exclude_banned': ?excludeBanned,
      'limit_count': ?limitCount,
      if (clearLimitCount) 'clear_limit': true,
      'is_pinned': ?isPinned,
      'sort_order': ?sortOrder,
    });
    final raw = await _callWriteWorker<String>('update_smart_playlist', {
      'id': id,
      'payloadJson': payload,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? SmartPlaylistItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<bool> deleteSmartPlaylist(String id) async {
    if (_useRemoteStep4Client) return _remoteClient!.deleteSmartPlaylist(id);
    if (!isNativeBound || _libDeleteSmartPlaylistFn == null) {
      return _delegate.deleteSmartPlaylist(id);
    }
    final raw = await _callWriteWorker<String>('delete_smart_playlist', {
      'id': id,
    });
    return _parseStep4DeletedFlag(raw);
  }

  @override
  Future<SmartPlaylistItem?> duplicateSmartPlaylist(String id) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.duplicateSmartPlaylist(id);
    }
    if (!isNativeBound || _libDuplicateSmartPlaylistFn == null) {
      return _delegate.duplicateSmartPlaylist(id);
    }
    final raw = await _callWriteWorker<String>('duplicate_smart_playlist', {
      'id': id,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? SmartPlaylistItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<SmartPlaylistEvaluation?> evaluateSmartPlaylist(String id) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.evaluateSmartPlaylist(id);
    }
    if (!isNativeBound || _libEvaluateSmartPlaylistFn == null) {
      return _delegate.evaluateSmartPlaylist(id);
    }
    final raw = await _callReadWorker<String>('evaluate_smart_playlist', {
      'id': id,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? SmartPlaylistEvaluation.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }
}
