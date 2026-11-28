part of '../server_audio_service.dart';

/// Implements Library Step 4 Tri-State Preferences, Bookmarks, Smart Playlists,
/// Listen Later, and Unified Queue API (`playQueue` / `enqueueTracks`) over REST.
mixin _ServerStep4Mixin on _ServerAudioServiceBase {
  bool _parseDeleteResult(int code, dynamic data) {
    if (code != 200 && code != 204) return false;
    if (data is Map && data.containsKey('deleted')) {
      return data['deleted'] == true;
    }
    return true;
  }

  void _syncLocalTrackPreference(String trackId, int preference) {
    var changed = false;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id == trackId) {
        _queue[i] = _queue[i].copyWith(preference: preference);
        changed = true;
      }
    }
    if (_state.track?.id == trackId) {
      _state = _state.copyWith(
        track: _state.track!.copyWith(preference: preference),
      );
      if (!_disposed && !_stateController.isClosed) {
        _stateController.add(_state);
      }
    }
    if (changed && !_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
  }

  @override
  Future<SetEntityPreferenceResponse?> setEntityPreference(
    String entityType,
    String entityId,
    int preference,
  ) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/preferences',
      body: <String, dynamic>{
        'entity_type': entityType,
        'entity_id': entityId,
        'preference': preference,
      },
    );
    if (code == 200 && data is Map) {
      final res = SetEntityPreferenceResponse.fromJson(
        Map<String, dynamic>.from(data),
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
    final (code, data) = await _requestJson('GET', '/api/v1/library/bookmarks');
    if (code == 200 && data is List) {
      return data
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
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/bookmarks',
      body: <String, dynamic>{
        'name': name,
        'target_route': targetRoute,
        'focus_query_json': ?focusQueryJson,
        'view_state_json': ?viewStateJson,
      },
    );
    if ((code == 200 || code == 201) && data is Map) {
      return BookmarkItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<BookmarkItem?> updateBookmark(
    String id, {
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/bookmarks/${Uri.encodeComponent(id)}',
      body: <String, dynamic>{
        'id': id,
        'name': ?name,
        'target_route': ?targetRoute,
        'focus_query_json': ?focusQueryJson,
        'view_state_json': ?viewStateJson,
      },
    );
    if (code == 200 && data is Map) {
      return BookmarkItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> deleteBookmark(String id) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/bookmarks/${Uri.encodeComponent(id)}',
    );
    return _parseDeleteResult(code, data);
  }

  @override
  Future<bool> reorderBookmarks(List<String> orderedIds) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/library/bookmarks/reorder',
      body: <String, dynamic>{'ordered_ids': orderedIds},
    );
    return code == 200 || code == 204;
  }

  @override
  Future<List<SmartPlaylistItem>> listSmartPlaylists() async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/smart-playlists',
    );
    if (code == 200 && data is List) {
      return data
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
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/smart-playlists',
      body: <String, dynamic>{
        'name': name,
        'description': description,
        'focus_query_json': focusQueryJson,
        'exclude_banned': excludeBanned,
        'limit_count': ?limitCount,
        'is_pinned': isPinned,
      },
    );
    if ((code == 200 || code == 201) && data is Map) {
      return SmartPlaylistItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
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
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/smart-playlists/${Uri.encodeComponent(id)}',
      body: <String, dynamic>{
        'id': id,
        'name': ?name,
        'description': ?description,
        'focus_query_json': ?focusQueryJson,
        'exclude_banned': ?excludeBanned,
        'limit_count': ?limitCount,
        if (clearLimitCount) 'clear_limit': true,
        'is_pinned': ?isPinned,
        'sort_order': ?sortOrder,
      },
    );
    if (code == 200 && data is Map) {
      return SmartPlaylistItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> deleteSmartPlaylist(String id) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/smart-playlists/${Uri.encodeComponent(id)}',
    );
    return _parseDeleteResult(code, data);
  }

  @override
  Future<SmartPlaylistItem?> duplicateSmartPlaylist(String id) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/smart-playlists/${Uri.encodeComponent(id)}/duplicate',
    );
    if ((code == 200 || code == 201) && data is Map) {
      return SmartPlaylistItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<SmartPlaylistEvaluation?> evaluateSmartPlaylist(String id) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/smart-playlists/${Uri.encodeComponent(id)}/evaluate',
    );
    if (code == 200 && data is Map) {
      return SmartPlaylistEvaluation.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<ListenLaterItem?> addToListenLater({
    required String sourceKind,
    required String entityType,
    String? entityId,
    String? providerId,
    String? externalId,
    required String title,
    String artistName = '',
    String albumTitle = '',
    String? coverUrl,
    int? trackCount,
    String? metadataJson,
    String note = '',
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/listen-later',
      body: <String, dynamic>{
        'source_kind': sourceKind,
        'entity_type': entityType,
        'entity_id': ?entityId,
        'provider_id': ?providerId,
        'external_id': ?externalId,
        'title': title,
        'artist_name': artistName,
        'album_title': albumTitle,
        'cover_url': ?coverUrl,
        'track_count': ?trackCount,
        'metadata_json': ?metadataJson,
        'note': note,
      },
    );
    if ((code == 200 || code == 201) && data is Map) {
      return ListenLaterItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<List<ListenLaterItem>> listListenLater({String? status}) async {
    final trimmed = status?.trim() ?? '';
    final path = trimmed.isEmpty
        ? '/api/v1/library/listen-later'
        : '/api/v1/library/listen-later?status=${Uri.encodeQueryComponent(trimmed)}';
    final (code, data) = await _requestJson('GET', path);
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => ListenLaterItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <ListenLaterItem>[];
  }

  @override
  Future<ListenLaterItem?> markListenLaterStatus(
    String id,
    String status,
  ) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/listen-later/${Uri.encodeComponent(id)}/status',
      body: <String, dynamic>{'id': id, 'status': status},
    );
    if (code == 200 && data is Map) {
      return ListenLaterItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<ListenLaterItem?> updateListenLaterNote(String id, String note) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/listen-later/${Uri.encodeComponent(id)}/note',
      body: <String, dynamic>{'id': id, 'note': note},
    );
    if (code == 200 && data is Map) {
      return ListenLaterItem.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> removeListenLater(String id) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/listen-later/${Uri.encodeComponent(id)}',
    );
    return _parseDeleteResult(code, data);
  }

  @override
  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) async {
    if (ingestBatch == null) {
      throw ArgumentError(
        'ingestBatch is required to promote an external Listen Later item via server REST',
      );
    }
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/listen-later/${Uri.encodeComponent(id)}/promote',
      body: <String, dynamic>{'ingest_batch': ingestBatch.toJson()},
      timeout: const Duration(seconds: 30),
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return PromoteListenLaterResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<void> playQueue(
    List<TrackInfo> tracks, {
    int startIndex = 0,
    bool excludeBanned = true,
    TrackInfo? explicitTrack,
  }) async {
    final filtered = filterQueueTracksForPlayback(
      tracks,
      startIndex: startIndex,
      excludeBanned: excludeBanned,
      explicitTrack: explicitTrack,
    );
    if (filtered.tracks.isEmpty || filtered.startIndex < 0) return;

    _queue = List<TrackInfo>.from(filtered.tracks);
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }

    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/queue/load',
      body: <String, dynamic>{
        'items': filtered.tracks
            .map((t) => ProtocolTrackMetadata.fromTrackInfo(t).toJson())
            .toList(growable: false),
        'start_index': filtered.startIndex,
        'auto_play': true,
      },
    );
    if (code == 200 && data is Map) {
      final map = JsonReader.asMapOrNull(data);
      if (map != null) {
        _queueState = QueueState.fromJson(map);
        if (!_disposed && !_queueStateController.isClosed) {
          _queueStateController.add(_queueState);
        }
      }
      return;
    }
    await play(track: filtered.tracks[filtered.startIndex]);
  }

  @override
  Future<int> enqueueTracks(
    List<TrackInfo> tracks, {
    bool excludeBanned = true,
    bool playNext = false,
  }) async {
    final toAdd = excludeBanned
        ? tracks.where((t) => t.preference != -1).toList(growable: false)
        : List<TrackInfo>.from(tracks, growable: false);
    if (toAdd.isEmpty) return 0;

    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/queue/enqueue',
      body: <String, dynamic>{
        'items': toAdd
            .map((t) => ProtocolTrackMetadata.fromTrackInfo(t).toJson())
            .toList(growable: false),
        'play_next': playNext,
      },
    );
    if (playNext) {
      final cur = _state.track;
      final activeIdx = cur != null
          ? PlaybackPersistenceService.findTrackIndex(_queue, cur)
          : -1;
      final insertAt =
          (activeIdx >= 0 ? activeIdx + 1 : 0).clamp(0, _queue.length);
      _queue = List<TrackInfo>.of(_queue)..insertAll(insertAt, toAdd);
    } else {
      _queue = <TrackInfo>[..._queue, ...toAdd];
    }
    if (code == 200 && data is Map) {
      final map = JsonReader.asMapOrNull(data);
      if (map != null) {
        _queueState = QueueState.fromJson(map);
        if (!_disposed && !_queueStateController.isClosed) {
          _queueStateController.add(_queueState);
        }
      }
    }
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
    return toAdd.length;
  }

  @override
  Future<int> clearUpcomingQueue() async {
    final cur = _state.track;
    var activeIdx = cur != null
        ? PlaybackPersistenceService.findTrackIndex(_queue, cur)
        : -1;
    if (activeIdx < 0 &&
        cur != null &&
        _queueState.currentIndex != null &&
        _queueState.currentIndex! >= 0 &&
        _queueState.currentIndex! < _queue.length) {
      activeIdx = _queueState.currentIndex!;
    }
    final keepCount = activeIdx >= 0 ? activeIdx + 1 : 0;
    final removed = _queue.length - keepCount;
    final prevLen = _queue.isNotEmpty ? _queue.length : _queueState.items.length;

    final (code, data) = await _requestJson('POST', '/api/v1/queue/clear-upcoming');
    _queue = keepCount > 0 ? _queue.sublist(0, keepCount) : <TrackInfo>[];
    var syncedRemoved = removed;
    if (code == 200 && data is Map) {
      final map = JsonReader.asMapOrNull(data);
      if (map != null) {
        _queueState = QueueState.fromJson(map);
        _queue = _queueState.toTrackInfoList().toList();
        if (prevLen >= _queue.length) {
          syncedRemoved = prevLen - _queue.length;
        }
        if (!_disposed && !_queueStateController.isClosed) {
          _queueStateController.add(_queueState);
        }
      }
    }
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
    return syncedRemoved;
  }
}
