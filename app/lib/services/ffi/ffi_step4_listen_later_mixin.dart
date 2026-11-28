part of '../ffi_audio_service.dart';

/// Implements Library Step 4 Listen Later CRUD/promotion and Unified Queue API
/// (`playQueue` / `enqueueTracks`) over FFI.
mixin _FfiStep4ListenLaterMixin
    on _FfiAudioServiceBase, _FfiStep4BindingsMixin, _FfiStep4Mixin {
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
    if (_useRemoteStep4Client) {
      return _remoteClient!.addToListenLater(
        sourceKind: sourceKind,
        entityType: entityType,
        entityId: entityId,
        providerId: providerId,
        externalId: externalId,
        title: title,
        artistName: artistName,
        albumTitle: albumTitle,
        coverUrl: coverUrl,
        trackCount: trackCount,
        metadataJson: metadataJson,
        note: note,
      );
    }
    if (!isNativeBound || _libAddListenLaterFn == null) {
      return _delegate.addToListenLater(
        sourceKind: sourceKind,
        entityType: entityType,
        entityId: entityId,
        providerId: providerId,
        externalId: externalId,
        title: title,
        artistName: artistName,
        albumTitle: albumTitle,
        coverUrl: coverUrl,
        trackCount: trackCount,
        metadataJson: metadataJson,
        note: note,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
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
    });
    final raw = await _callWriteWorker<String>('add_listen_later', {
      'payloadJson': payload,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? ListenLaterItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<List<ListenLaterItem>> listListenLater({String? status}) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.listListenLater(status: status);
    }
    if (!isNativeBound || _libListListenLaterFn == null) {
      return _delegate.listListenLater(status: status);
    }
    final raw = await _callReadWorker<String>('list_listen_later', {
      'status': status,
    });
    if (_disposed || raw == null || raw.isEmpty) {
      return const <ListenLaterItem>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
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
    if (_useRemoteStep4Client) {
      return _remoteClient!.markListenLaterStatus(id, status);
    }
    if (!isNativeBound || _libMarkListenLaterStatusFn == null) {
      return _delegate.markListenLaterStatus(id, status);
    }
    final raw = await _callWriteWorker<String>('mark_listen_later_status', {
      'id': id,
      'payloadJson': jsonEncode(<String, dynamic>{'id': id, 'status': status}),
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? ListenLaterItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<ListenLaterItem?> updateListenLaterNote(String id, String note) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.updateListenLaterNote(id, note);
    }
    if (!isNativeBound || _libUpdateListenLaterNoteFn == null) {
      return _delegate.updateListenLaterNote(id, note);
    }
    final raw = await _callWriteWorker<String>('update_listen_later_note', {
      'id': id,
      'payloadJson': jsonEncode(<String, dynamic>{'id': id, 'note': note}),
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map
        ? ListenLaterItem.fromJson(Map<String, dynamic>.from(decoded))
        : null;
  }

  @override
  Future<bool> removeListenLater(String id) async {
    if (_useRemoteStep4Client) return _remoteClient!.removeListenLater(id);
    if (!isNativeBound || _libRemoveListenLaterFn == null) {
      return _delegate.removeListenLater(id);
    }
    final raw = await _callWriteWorker<String>('remove_listen_later', {
      'id': id,
    });
    return _parseStep4DeletedFlag(raw);
  }

  @override
  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) async {
    if (_useRemoteStep4Client) {
      return _remoteClient!.promoteExternalToLibrary(
        id,
        ingestBatch: ingestBatch,
      );
    }
    if (!isNativeBound || _libPromoteListenLaterFn == null) {
      return _delegate.promoteExternalToLibrary(id, ingestBatch: ingestBatch);
    }
    if (ingestBatch == null) {
      throw ArgumentError(
        'ingestBatch is required to promote an external Listen Later item via FFI',
      );
    }
    final raw = await _callWriteWorker<String>('promote_listen_later', {
      'id': id,
      'payloadJson': jsonEncode(<String, dynamic>{
        'ingest_batch': ingestBatch.toJson(),
      }),
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final result = PromoteListenLaterResult.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      unawaited(_reloadTracksFromNativeAsync());
      return result;
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
    if (_isRemoteActive) {
      return _remoteClient!.playQueue(
        tracks,
        startIndex: startIndex,
        excludeBanned: excludeBanned,
        explicitTrack: explicitTrack,
      );
    }
    if (!isNativeBound) {
      await _delegate.playQueue(
        tracks,
        startIndex: startIndex,
        excludeBanned: excludeBanned,
        explicitTrack: explicitTrack,
      );
      _queue = List<TrackInfo>.from(_delegate.queue);
      return;
    }
    final filtered = filterQueueTracksForPlayback(
      tracks,
      startIndex: startIndex,
      excludeBanned: excludeBanned,
      explicitTrack: explicitTrack,
    );
    if (filtered.tracks.isEmpty || filtered.startIndex < 0) return;
    _queue = List<TrackInfo>.from(filtered.tracks);
    _currentIndex = filtered.startIndex;
    _needsLoadOnResume = false;
    _pendingResumePosition = null;
    _queueEpoch++;
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
    await skipToTrack(
      _queue[_currentIndex],
      queueContext: List<TrackInfo>.unmodifiable(_queue),
    );
  }

  @override
  Future<int> enqueueTracks(
    List<TrackInfo> tracks, {
    bool excludeBanned = true,
    bool playNext = false,
  }) async {
    if (_isRemoteActive) {
      return _remoteClient!.enqueueTracks(
        tracks,
        excludeBanned: excludeBanned,
        playNext: playNext,
      );
    }
    if (!isNativeBound) {
      final count = await _delegate.enqueueTracks(
        tracks,
        excludeBanned: excludeBanned,
        playNext: playNext,
      );
      _queue = List<TrackInfo>.from(_delegate.queue);
      return count;
    }
    final toAdd = excludeBanned
        ? tracks.where((t) => t.preference != -1).toList(growable: false)
        : List<TrackInfo>.from(tracks, growable: false);
    if (toAdd.isEmpty) return 0;
    if (playNext) {
      final cur = _state.track;
      final activeIdx = cur != null
          ? PlaybackPersistenceService.findTrackIndex(_queue, cur)
          : -1;
      final insertAt =
          (activeIdx >= 0 ? activeIdx + 1 : 0).clamp(0, _queue.length);
      final updated = List<TrackInfo>.of(_queue)..insertAll(insertAt, toAdd);
      _queue = updated;
    } else {
      _queue = <TrackInfo>[..._queue, ...toAdd];
    }
    _queueEpoch++;
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
    return toAdd.length;
  }

  @override
  Future<int> clearUpcomingQueue() async {
    if (_isRemoteActive) {
      return _remoteClient!.clearUpcomingQueue();
    }
    if (!isNativeBound) {
      final cleared = await _delegate.clearUpcomingQueue();
      _queue = List<TrackInfo>.from(_delegate.queue);
      return cleared;
    }
    final cur = _state.track;
    final activeIdx = cur != null
        ? PlaybackPersistenceService.findTrackIndex(_queue, cur)
        : -1;
    final keepCount = activeIdx >= 0 ? activeIdx + 1 : 0;
    final removed = _queue.length - keepCount;
    if (removed > 0) {
      _queue = _queue.sublist(0, keepCount);
    }
    if (_queue.isEmpty) {
      _currentIndex = 0;
    } else if (activeIdx >= 0) {
      _currentIndex = activeIdx;
    }
    _pendingStandbyTrack = null;
    _standbyTracksById.clear();
    _queueEpoch++;
    if (_playbackDispatchCommandFn != null) {
      final cmdJson = jsonEncode(const ClearUpcomingQueueCommand().toJson());
      _withNativeUtf8(cmdJson, (ptr) => _playbackDispatchCommandFn!(ptr));
    }
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
    return removed;
  }
}
