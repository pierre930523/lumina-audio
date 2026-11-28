part of '../mock_audio_service.dart';

bool _mockMatchPreferenceValue(int preference, FocusValue value) {
  final int? target = switch (value) {
    FocusIntValue(:final value) => value,
    FocusStringValue(:final value) => FocusFacetBucket.preferenceIntForBucket(
      value,
    ),
    _ => null,
  };
  return target != null && preference == target;
}

bool _mockMatchTrackFormatValue(TrackInfo t, String strVal) {
  final codec = t.format.codec.name.toLowerCase();
  return switch (strVal) {
    'lossless' =>
      t.format.isDsd ||
          const <String>{
            'flac',
            'alac',
            'wav',
            'aiff',
            'ape',
            'wv',
            'wavpack',
            'dsf',
            'dff',
            'dsd',
          }.contains(codec),
    'lossy' => const <String>{
      'mp3',
      'aac',
      'm4a',
      'ogg',
      'opus',
      'vorbis',
    }.contains(codec),
    'dsd' => t.format.isDsd || codec == 'dsf' || codec == 'dff' || codec == 'dsd',
    _ => codec == strVal,
  };
}

List<SmartPlaylistItem> _createDefaultMockSmartPlaylists() {
  const now = '2026-01-01T00:00:00Z';
  return <SmartPlaylistItem>[
    const SmartPlaylistItem(
      id: 'sp-hires',
      name: 'Hi-Res 高解析精選',
      description: '自動收錄 ≥ 96 kHz 無損高解析母帶曲目',
      focusQueryJson:
          '{"entity":"tracks","predicates":[{"facet":"format","value":{"kind":"string","value":"lossless"},"mode":"include"},{"facet":"sample_rate","value":{"kind":"int_range","min":96000},"mode":"include"}]}',
      excludeBanned: true,
      isPinned: true,
      sortOrder: 0,
      isSystemSeed: true,
      createdAt: now,
      updatedAt: now,
    ),
    const SmartPlaylistItem(
      id: 'sp-lossless',
      name: '無損母帶純享',
      description: '收錄所有 FLAC / ALAC / WAV / DSD 無損曲目',
      focusQueryJson:
          '{"entity":"tracks","predicates":[{"facet":"format","value":{"kind":"string","value":"lossless"},"mode":"include"}]}',
      excludeBanned: true,
      isPinned: true,
      sortOrder: 1,
      isSystemSeed: true,
      createdAt: now,
      updatedAt: now,
    ),
    const SmartPlaylistItem(
      id: 'sp-dsd',
      name: 'DSD 原生軌典藏',
      description: '自動過濾 DSD64 / DSD128 / DSD256 原生直出軌',
      focusQueryJson:
          '{"entity":"tracks","predicates":[{"facet":"format","value":{"kind":"string","value":"dsd"},"mode":"include"}]}',
      excludeBanned: true,
      isPinned: true,
      sortOrder: 2,
      isSystemSeed: true,
      createdAt: now,
      updatedAt: now,
    ),
    const SmartPlaylistItem(
      id: 'sp-all',
      name: '工作室全曲庫',
      description: '全部已掃描的本地與串流曲目',
      focusQueryJson: '{"entity":"tracks","predicates":[]}',
      excludeBanned: true,
      isPinned: true,
      sortOrder: 3,
      isSystemSeed: true,
      createdAt: now,
      updatedAt: now,
    ),
  ];
}

mixin _MockStep4Mixin
    on _MockAudioServiceBase, _MockAlbumGroupingMixin, _MockFocusTagsFoldersMixin {
  final List<BookmarkItem> _mockBookmarks = <BookmarkItem>[];
  List<SmartPlaylistItem>? _mockSmartPlaylists;
  int _mockStep4Seq = 0;

  List<SmartPlaylistItem> _ensureSmartPlaylists() =>
      _mockSmartPlaylists ??= _createDefaultMockSmartPlaylists();

  String _nextStep4Id(String prefix) => '$prefix-${++_mockStep4Seq}';

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  // ---------------------------------------------------------------------------
  // Tri-state Preferences (-1 / 0 / 1)
  // ---------------------------------------------------------------------------

  @override
  Future<SetEntityPreferenceResponse?> setEntityPreference(
    String entityType,
    String entityId,
    int preference,
  ) async {
    final normType = entityType.trim().toLowerCase();
    if (normType != 'track' &&
        normType != 'album_group' &&
        normType != 'artist') {
      return null;
    }
    if (preference != -1 && preference != 0 && preference != 1) {
      return null;
    }

    if (normType == 'track') {
      for (var i = 0; i < _queue.length; i++) {
        if (_queue[i].id == entityId) {
          _queue[i] = _queue[i].copyWith(preference: preference);
        }
      }
      if (_state.track?.id == entityId) {
        _state = _state.copyWith(
          track: _state.track!.copyWith(preference: preference),
        );
      }
      for (final g in _ensureAlbumGroups()) {
        g.versions = g.versions
            .map(
              (v) => v.copyWith(
                tracks: v.tracks
                    .map(
                      (t) => t.id == entityId
                          ? t.copyWith(preference: preference)
                          : t,
                    )
                    .toList(),
              ),
            )
            .toList();
      }
    } else if (normType == 'album_group') {
      for (final g in _ensureAlbumGroups()) {
        if (g.id == entityId) {
          g.preference = preference;
        }
      }
    } else if (normType == 'artist') {
      _mockArtistPreferences[entityId] = preference;
    }

    return SetEntityPreferenceResponse(
      entityType: normType,
      entityId: entityId,
      preference: preference,
    );
  }

  // ---------------------------------------------------------------------------
  // Dynamic Bookmarks
  // ---------------------------------------------------------------------------

  @override
  Future<List<BookmarkItem>> listBookmarks() async {
    final sorted = List<BookmarkItem>.from(_mockBookmarks)
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
    return List<BookmarkItem>.unmodifiable(sorted);
  }

  @override
  Future<BookmarkItem?> createBookmark({
    required String name,
    required String targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return null;
    final now = _nowIso();
    final item = BookmarkItem(
      id: _nextStep4Id('bm'),
      name: trimmedName,
      targetRoute: targetRoute.trim(),
      focusQueryJson: focusQueryJson,
      viewStateJson: viewStateJson,
      sortOrder: _mockBookmarks.length,
      createdAt: now,
      updatedAt: now,
    );
    _mockBookmarks.add(item);
    return item;
  }

  @override
  Future<BookmarkItem?> updateBookmark(
    String id, {
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    final idx = _mockBookmarks.indexWhere((b) => b.id == id);
    if (idx < 0) return null;
    final updated = _mockBookmarks[idx].copyWith(
      name: name?.trim(),
      targetRoute: targetRoute?.trim(),
      focusQueryJson: focusQueryJson,
      viewStateJson: viewStateJson,
      updatedAt: _nowIso(),
    );
    _mockBookmarks[idx] = updated;
    return updated;
  }

  @override
  Future<bool> deleteBookmark(String id) async {
    final before = _mockBookmarks.length;
    _mockBookmarks.removeWhere((b) => b.id == id);
    return _mockBookmarks.length != before;
  }

  @override
  Future<bool> reorderBookmarks(List<String> orderedIds) async {
    final orderMap = <String, int>{
      for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    var fallbackOrder = orderedIds.length;
    for (var i = 0; i < _mockBookmarks.length; i++) {
      final b = _mockBookmarks[i];
      final nextOrder = orderMap[b.id] ?? fallbackOrder++;
      _mockBookmarks[i] = b.copyWith(sortOrder: nextOrder);
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Unified FocusQuery-backed Smart Playlists
  // ---------------------------------------------------------------------------

  @override
  Future<List<SmartPlaylistItem>> listSmartPlaylists() async {
    final list = List<SmartPlaylistItem>.from(_ensureSmartPlaylists())
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
    return List<SmartPlaylistItem>.unmodifiable(list);
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
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final list = _ensureSmartPlaylists();
    final now = _nowIso();
    final item = SmartPlaylistItem(
      id: _nextStep4Id('sp'),
      name: trimmed,
      description: description.trim(),
      focusQueryJson: focusQueryJson,
      excludeBanned: excludeBanned,
      limitCount: limitCount,
      isPinned: isPinned,
      sortOrder: list.length,
      isSystemSeed: false,
      createdAt: now,
      updatedAt: now,
    );
    list.add(item);
    return item;
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
    final list = _ensureSmartPlaylists();
    final idx = list.indexWhere((p) => p.id == id);
    if (idx < 0) return null;
    final updated = list[idx].copyWith(
      name: name?.trim(),
      description: description?.trim(),
      focusQueryJson: focusQueryJson,
      excludeBanned: excludeBanned,
      limitCount: limitCount,
      clearLimitCount: clearLimitCount,
      isPinned: isPinned,
      sortOrder: sortOrder,
      updatedAt: _nowIso(),
    );
    list[idx] = updated;
    return updated;
  }

  @override
  Future<bool> deleteSmartPlaylist(String id) async {
    final list = _ensureSmartPlaylists();
    final before = list.length;
    list.removeWhere((p) => p.id == id);
    return list.length != before;
  }

  @override
  Future<SmartPlaylistItem?> duplicateSmartPlaylist(String id) async {
    final list = _ensureSmartPlaylists();
    final orig = list.where((p) => p.id == id).firstOrNull;
    if (orig == null) return null;
    final now = _nowIso();
    final copy = orig.copyWith(
      id: _nextStep4Id('sp'),
      name: '${orig.name} (副本)',
      sortOrder: list.length,
      isSystemSeed: false,
      createdAt: now,
      updatedAt: now,
    );
    list.add(copy);
    return copy;
  }

  @override
  Future<SmartPlaylistEvaluation?> evaluateSmartPlaylist(String id) async {
    final sp = _ensureSmartPlaylists().where((p) => p.id == id).firstOrNull;
    if (sp == null) return null;
    final parsed =
        sp.parseFocusQuery() ?? const FocusQuery(entity: FocusEntity.tracks);
    final hasExplicitBannedInclude = parsed.predicates.any(
      (p) =>
          p.facet == FocusFacet.preference &&
          p.mode == FocusPredicateMode.include &&
          _mockMatchPreferenceValue(-1, p.value),
    );
    var matched = _queue.where((t) {
      if (sp.excludeBanned && !hasExplicitBannedInclude && t.preference == -1) {
        return false;
      }
      return _mockMatchesFocusPredicates(
        t,
        parsed.predicates,
        _matchTrackPredicate,
      );
    }).toList();
    matched = _mockSortTracks(matched, parsed.sort);
    final total = matched.length;
    if (sp.limitCount != null &&
        sp.limitCount! > 0 &&
        matched.length > sp.limitCount!) {
      matched = matched.take(sp.limitCount!).toList(growable: false);
    }
    return SmartPlaylistEvaluation(
      playlist: sp,
      totalMatched: total,
      tracks: List<TrackInfo>.unmodifiable(matched),
    );
  }

  // ---------------------------------------------------------------------------
  // Unified Queue API
  // ---------------------------------------------------------------------------

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
    if (filtered.tracks.isEmpty || filtered.startIndex < 0) {
      return;
    }
    _queue
      ..clear()
      ..addAll(filtered.tracks);
    _currentIndex = filtered.startIndex;
    _queueEpoch++;
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }
    await play(track: _queue[_currentIndex]);
  }

  @override
  Future<int> enqueueTracks(
    List<TrackInfo> tracks, {
    bool excludeBanned = true,
    bool playNext = false,
  }) async {
    final filtered = excludeBanned
        ? tracks.where((t) => t.preference != -1).toList(growable: false)
        : List<TrackInfo>.from(tracks, growable: false);
    var added = 0;
    if (playNext) {
      final cur = _state.track;
      final activeIdx = cur != null
          ? PlaybackPersistenceService.findTrackIndex(_queue, cur)
          : -1;
      var insertAt =
          (activeIdx >= 0 ? activeIdx + 1 : 0).clamp(0, _queue.length);
      for (final t in filtered) {
        if (!_queue.any((e) => e.id == t.id)) {
          _queue.insert(insertAt, t);
          insertAt++;
          added++;
        }
      }
    } else {
      for (final t in filtered) {
        if (!_queue.any((e) => e.id == t.id)) {
          _queue.add(t);
          added++;
        }
      }
    }
    if (added > 0) {
      _queueEpoch++;
      if (!_disposed && !_queueUpdatedController.isClosed) {
        _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
      }
      if (!_disposed && !_queueStateController.isClosed) {
        _queueStateController.add(currentQueueState);
      }
    }
    return added;
  }

  @override
  Future<int> clearUpcomingQueue() async {
    _clearStandby();
    final cur = _state.track;
    final activeIdx = cur != null
        ? PlaybackPersistenceService.findTrackIndex(_queue, cur)
        : -1;
    final keepCount = activeIdx >= 0 ? activeIdx + 1 : 0;
    final removed = _queue.length - keepCount;
    if (removed > 0) {
      _queue.length = keepCount;
      _queueEpoch++;
    }
    if (_queue.isEmpty) {
      _currentIndex = 0;
    } else if (activeIdx >= 0) {
      _currentIndex = activeIdx;
    }
    if (removed > 0) {
      if (!_disposed && !_queueUpdatedController.isClosed) {
        _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
      }
      if (!_disposed && !_queueStateController.isClosed) {
        _queueStateController.add(currentQueueState);
      }
    }
    return removed;
  }
}
