part of '../streaming_manager.dart';

bool _hasAnyTrackCover(StreamingRecommendations rec) {
  if (rec.tracks.isEmpty) return true;
  return rec.tracks.any(
    (t) =>
        (t.coverUrl != null && t.coverUrl!.trim().isNotEmpty) ||
        (t.albumArtUrl != null && t.albumArtUrl!.trim().isNotEmpty),
  );
}

extension _StreamingManagerRecommendationsExt on StreamingManager {
  Future<List<FeedSection>> _fetchPersonalizedFeedsImpl({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final orderedKinds = <String>[
      ...StreamingManager.providerOrder,
      ..._providers.keys.where((k) => !StreamingManager.providerOrder.contains(k)),
    ];
    final targets = <RecommendationProvider>[];
    for (final kind in orderedKinds) {
      final provider = _providers[kind];
      if (provider == null) continue;
      if (provider.authState != StreamingAuthState.connected) continue;
      if (authManager.isAuthRequired(kind)) continue;
      if (provider is RecommendationProvider) {
        final rec = provider as RecommendationProvider;
        if (rec.capabilities.supportsPersonalFeed) {
          targets.add(rec);
        }
      }
    }
    if (targets.isEmpty) return const <FeedSection>[];

    final perProviderSections = await Future.wait(
      targets.map((rec) async {
        try {
          return await rec.getPersonalizedFeed(cancel: cancel);
        } on RecError catch (e) {
          if (e.kind == RecErrorKind.cancelled) rethrow;
          return const <FeedSection>[];
        } on StreamingException catch (e) {
          if (e.isCancelled) rethrow;
          return const <FeedSection>[];
        } catch (_) {
          return const <FeedSection>[];
        }
      }),
    );

    return List<FeedSection>.unmodifiable(
      perProviderSections.expand((sections) => sections),
    );
  }

  List<StreamingAlbum> _allRecommendedAlbumsImpl({String? filterKind}) {
    if (filterKind != null &&
        filterKind.isNotEmpty &&
        filterKind != 'all') {
      return List<StreamingAlbum>.unmodifiable(
        _recommendations[filterKind]?.albums ?? const <StreamingAlbum>[],
      );
    }
    final lists = <List<StreamingAlbum>>[];
    for (final kind in StreamingManager.providerOrder) {
      final p = _providers[kind];
      if (!_isBrowsable(p)) continue;
      final albums = _recommendations[kind]?.albums;
      if (albums != null && albums.isNotEmpty) {
        lists.add(albums);
      }
    }
    if (lists.isEmpty) return const <StreamingAlbum>[];
    final interleaved = <StreamingAlbum>[];
    var index = 0;
    while (true) {
      var added = false;
      for (final list in lists) {
        if (index < list.length) {
          interleaved.add(list[index]);
          added = true;
        }
      }
      if (!added) break;
      index++;
    }
    return interleaved;
  }

  List<TrackInfo> _allRecommendedTracksImpl({String? filterKind}) {
    if (filterKind != null &&
        filterKind.isNotEmpty &&
        filterKind != 'all') {
      return List<TrackInfo>.unmodifiable(
        _recommendations[filterKind]?.tracks ?? const <TrackInfo>[],
      );
    }
    final lists = <List<TrackInfo>>[];
    for (final kind in StreamingManager.providerOrder) {
      final p = _providers[kind];
      if (!_isBrowsable(p)) continue;
      final tracks = _recommendations[kind]?.tracks;
      if (tracks != null && tracks.isNotEmpty) {
        lists.add(tracks);
      }
    }
    if (lists.isEmpty) return const <TrackInfo>[];
    final interleaved = <TrackInfo>[];
    var index = 0;
    while (true) {
      var added = false;
      for (final list in lists) {
        if (index < list.length) {
          interleaved.add(list[index]);
          added = true;
        }
      }
      if (!added) break;
      index++;
    }
    return interleaved;
  }

  bool _isRecommendationCacheFresh(StreamingRecommendations? rec) {
    if (rec == null || rec.isEmpty || rec.hasError) return false;
    if (!_hasAnyTrackCover(rec)) return false;
    final age = _clock().difference(rec.fetchedAt);
    return !age.isNegative && age < recommendationsCacheTtl;
  }

  void _hydrateRecommendationsCacheSync() {
    final file = recommendationsCacheFile;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final providersMap = decoded['providers'] is Map
          ? Map<String, dynamic>.from(decoded['providers'] as Map)
          : Map<String, dynamic>.from(decoded);
      for (final kind in StreamingManager.providerOrder) {
        final provider = _providers[kind];
        if (!_isBrowsable(provider)) continue;
        final entry = providersMap[kind];
        if (entry is Map) {
          final rec = StreamingRecommendations.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (_isRecommendationCacheFresh(rec)) {
            _recommendations[kind] = rec;
          }
        }
      }
    } catch (_) {
      // Ignore corrupted cache file and refresh from live API.
    }
  }

  void _persistRecommendationsCacheSync() {
    final file = recommendationsCacheFile;
    if (file == null) return;
    try {
      final providersJson = <String, dynamic>{};
      for (final entry in _recommendations.entries) {
        final p = _providers[entry.key];
        if (_isBrowsable(p) &&
            !entry.value.isEmpty &&
            !entry.value.hasError) {
          providersJson[entry.key] = entry.value.toJson();
        }
      }
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      file.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'updated_at': _clock().toUtc().toIso8601String(),
          'providers': providersJson,
        }),
      );
    } catch (_) {}
  }

  void _recordSeenIds(
    Map<String, List<String>> store,
    String kind,
    Iterable<String> ids,
  ) {
    final list = store.putIfAbsent(kind, () => <String>[]);
    for (final raw in ids) {
      final id = raw.trim();
      if (id.isEmpty) continue;
      list.remove(id);
      list.add(id);
    }
    if (list.length > StreamingManager._maxSeenRecommendationIds) {
      list.removeRange(
        0,
        list.length - StreamingManager._maxSeenRecommendationIds,
      );
    }
  }

  Future<StreamingRecommendations> _refreshRecommendationsForImpl(
    String kind, {
    bool force = false,
  }) async {
    final provider = _providers[kind];
    if (provider == null || !_isBrowsable(provider)) {
      return StreamingRecommendations.empty(kind);
    }
    if (!force && authManager.isAuthRequired(kind)) {
      return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
    }

    if (!force && _isRecommendationCacheFresh(_recommendations[kind])) {
      return _recommendations[kind]!;
    }

    if (force) {
      final previous = _recommendations.remove(kind);
      if (previous != null) {
        _recordSeenIds(
          _seenRecommendationAlbumIds,
          kind,
          previous.albums.map((a) => a.id),
        );
        _recordSeenIds(
          _seenRecommendationTrackIds,
          kind,
          previous.tracks.map((t) => t.id),
        );
      }
      _recommendationBatchIndex[kind] =
          (_recommendationBatchIndex[kind] ?? 0) + 1;
      _persistRecommendationsCacheSync();
    }

    _recommendationCancellations[kind]?.cancel();
    final token = CancellationToken();
    _recommendationCancellations[kind] = token;
    _loadingRecommendations.add(kind);
    _recommendationErrors.remove(kind);
    _recommendationTokenExpired.remove(kind);
    _safeNotify();

    final batchIndex = _recommendationBatchIndex[kind] ?? 0;
    final excludeAlbumIds = Set<String>.unmodifiable(
      _seenRecommendationAlbumIds[kind] ?? const <String>[],
    );
    final excludeTrackIds = Set<String>.unmodifiable(
      _seenRecommendationTrackIds[kind] ?? const <String>[],
    );

    try {
      StreamingRecommendations rec;
      try {
        rec = await provider.fetchRecommendations(
          cancel: token,
          forceRefresh: force,
          batchIndex: batchIndex,
          excludeAlbumIds: excludeAlbumIds,
          excludeTrackIds: excludeTrackIds,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            AuthManager.isUnauthorizedError(e) &&
            await authManager.refreshTokenSingleFlight(kind)) {
          if (_disposed || token.isCancelled) {
            return _recommendations[kind] ??
                StreamingRecommendations.empty(kind);
          }
          rec = await provider.fetchRecommendations(
            cancel: token,
            forceRefresh: force,
            batchIndex: batchIndex,
            excludeAlbumIds: excludeAlbumIds,
            excludeTrackIds: excludeTrackIds,
          );
        } else {
          rethrow;
        }
      }
      if (_disposed || token.isCancelled) {
        return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
      }
      final freshRec = StreamingRecommendations(
        providerKind: kind,
        albums: List<StreamingAlbum>.of(rec.albums),
        tracks: List<TrackInfo>.of(rec.tracks),
        fetchedAt: _clock(),
        errorMessage: rec.errorMessage,
        isTokenExpired: rec.isTokenExpired,
      );
      _recommendations[kind] = freshRec;
      _recommendationErrors.remove(kind);
      _recommendationTokenExpired[kind] = false;
      _persistRecommendationsCacheSync();
      return freshRec;
    } on StreamingException catch (e) {
      if (e.isCancelled) {
        return _recommendations[kind] ?? StreamingRecommendations.empty(kind);
      }
      final expired = e.isTokenExpired || e.statusCode == 401;
      _recommendationErrors[kind] = e.message;
      _recommendationTokenExpired[kind] = expired;
      final prev = _recommendations[kind];
      _recommendations[kind] =
          (prev ?? StreamingRecommendations.empty(kind)).copyWith(
            errorMessage: e.message,
            isTokenExpired: expired,
          );
      return _recommendations[kind]!;
    } catch (e) {
      final msg = e.toString();
      _recommendationErrors[kind] = msg;
      final prev = _recommendations[kind];
      _recommendations[kind] =
          (prev ?? StreamingRecommendations.empty(kind)).copyWith(
            errorMessage: msg,
          );
      return _recommendations[kind]!;
    } finally {
      if (identical(_recommendationCancellations[kind], token)) {
        _recommendationCancellations.remove(kind);
        _loadingRecommendations.remove(kind);
      }
      _safeNotify();
    }
  }
}
