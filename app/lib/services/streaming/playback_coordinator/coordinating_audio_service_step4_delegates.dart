part of '../streaming_playback_coordinator.dart';

/// Forwards all Library Step 4 Tri-State Preference, Bookmarks, Unified Smart
/// Playlists, Listen Later, and Unified Queue API methods on
/// [CoordinatingAudioService].
mixin _CoordinatingAudioServiceStep4DelegatesMixin implements AudioService {
  AudioService get inner;
  StreamingPlaybackCoordinator get coordinator;

  @override
  Future<SetEntityPreferenceResponse?> setEntityPreference(
    String entityType,
    String entityId,
    int preference,
  ) async {
    final res = await inner.setEntityPreference(
      entityType,
      entityId,
      preference,
    );
    if (res != null) {
      if (entityType == 'track') {
        coordinator.syncTrackPreference(entityId, res.preference);
      } else if (entityType == 'artist') {
        coordinator.syncArtistPreference(entityId, res.preference);
      }
    }
    return res;
  }

  @override
  Future<List<BookmarkItem>> listBookmarks() => inner.listBookmarks();

  @override
  Future<BookmarkItem?> createBookmark({
    required String name,
    required String targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) => inner.createBookmark(
    name: name,
    targetRoute: targetRoute,
    focusQueryJson: focusQueryJson,
    viewStateJson: viewStateJson,
  );

  @override
  Future<BookmarkItem?> updateBookmark(
    String id, {
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) => inner.updateBookmark(
    id, name: name, targetRoute: targetRoute,
    focusQueryJson: focusQueryJson, viewStateJson: viewStateJson,
  );

  @override
  Future<bool> deleteBookmark(String id) => inner.deleteBookmark(id);

  @override
  Future<bool> reorderBookmarks(List<String> orderedIds) =>
      inner.reorderBookmarks(orderedIds);

  @override
  Future<List<SmartPlaylistItem>> listSmartPlaylists() =>
      inner.listSmartPlaylists();

  @override
  Future<SmartPlaylistItem?> createSmartPlaylist({
    required String name,
    String description = '',
    required String focusQueryJson,
    bool excludeBanned = true,
    int? limitCount,
    bool isPinned = true,
  }) => inner.createSmartPlaylist(
    name: name, description: description, focusQueryJson: focusQueryJson,
    excludeBanned: excludeBanned, limitCount: limitCount, isPinned: isPinned,
  );

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
  }) => inner.updateSmartPlaylist(
    id, name: name, description: description, focusQueryJson: focusQueryJson,
    excludeBanned: excludeBanned, limitCount: limitCount,
    clearLimitCount: clearLimitCount, isPinned: isPinned, sortOrder: sortOrder,
  );

  @override
  Future<bool> deleteSmartPlaylist(String id) => inner.deleteSmartPlaylist(id);

  @override
  Future<SmartPlaylistItem?> duplicateSmartPlaylist(String id) =>
      inner.duplicateSmartPlaylist(id);

  @override
  Future<SmartPlaylistEvaluation?> evaluateSmartPlaylist(String id) =>
      inner.evaluateSmartPlaylist(id);

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
  }) => inner.addToListenLater(
    sourceKind: sourceKind, entityType: entityType, entityId: entityId,
    providerId: providerId, externalId: externalId, title: title,
    artistName: artistName, albumTitle: albumTitle, coverUrl: coverUrl,
    trackCount: trackCount, metadataJson: metadataJson, note: note,
  );

  @override
  Future<List<ListenLaterItem>> listListenLater({String? status}) =>
      inner.listListenLater(status: status);

  @override
  Future<ListenLaterItem?> markListenLaterStatus(String id, String status) =>
      inner.markListenLaterStatus(id, status);

  @override
  Future<ListenLaterItem?> updateListenLaterNote(String id, String note) =>
      inner.updateListenLaterNote(id, note);

  @override
  Future<bool> removeListenLater(String id) => inner.removeListenLater(id);

  @override
  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) async {
    if (ingestBatch != null) {
      return inner.promoteExternalToLibrary(id, ingestBatch: ingestBatch);
    }
    final items = await inner.listListenLater();
    final target = items.cast<ListenLaterItem?>().firstWhere(
      (item) => item?.id == id,
      orElse: () => null,
    );
    if (target == null) throw StateError('Listen Later item not found: $id');
    if (!target.isExternal) {
      throw StateError('Listen Later item "$id" is not an external item');
    }
    final providerId = (target.providerId ?? '').trim().toLowerCase();
    final rawExternalId = (target.externalId ?? '').trim();
    if (providerId.isEmpty || rawExternalId.isEmpty) {
      throw StateError(
        'External Listen Later item "$id" is missing provider_id/external_id',
      );
    }
    final batch = await _buildPromoteIngestBatch(
      target,
      providerId: providerId,
      rawExternalId: rawExternalId,
    );
    return inner.promoteExternalToLibrary(id, ingestBatch: batch);
  }

  Future<ExternalCatalogIngestBatch> _buildPromoteIngestBatch(
    ListenLaterItem item, {
    required String providerId,
    required String rawExternalId,
  }) async {
    final cleanExternalId = _stripProviderPrefix(rawExternalId, providerId);
    final meta = item.parseMetadata() ?? const <String, dynamic>{};
    final effectiveArtist = _nonEmptyMetaString(item.artistName) ??
        _nonEmptyMetaString(meta['artist_name']) ??
        'Unknown Artist';
    final normalizedCover = normalizeStreamingCoverUrl(
      item.coverUrl ?? _nonEmptyMetaString(meta['cover_url']),
    );
    if (item.isAlbum) {
      return _buildPromoteAlbumBatch(
        item,
        meta: meta,
        providerId: providerId,
        rawExternalId: rawExternalId,
        cleanExternalId: cleanExternalId,
        effectiveArtist: effectiveArtist,
        normalizedCover: normalizedCover,
      );
    }
    final albumTitle = _nonEmptyMetaString(item.albumTitle) ??
        _nonEmptyMetaString(item.title) ??
        'Unknown Album';
    final rawAlbumId = _nonEmptyMetaString(meta['external_album_id']) ??
        _nonEmptyMetaString(meta['album_id']) ??
        '';
    final cleanAlbumId = rawAlbumId.isNotEmpty
        ? _stripProviderPrefix(rawAlbumId, providerId)
        : '$providerId:synth:${albumTitle.toLowerCase()}::${effectiveArtist.toLowerCase()}';
    final discNum = ((meta['disc_number'] as num?)?.toInt() ?? 1).clamp(1, 999);
    final trackNum = ((meta['track_number'] as num?)?.toInt() ?? 1).clamp(1, 9999);
    final durMs = ((meta['duration_ms'] as num?)?.toInt() ?? 0).clamp(0, 1 << 50);
    return ExternalCatalogIngestBatch(
      provider: providerId,
      albums: <ExternalAlbumIngest>[
        ExternalAlbumIngest(
          externalAlbumId: cleanAlbumId,
          title: albumTitle,
          artistName: effectiveArtist,
          albumArtist: effectiveArtist,
          releaseYear: (meta['release_year'] as num?)?.toInt() ??
              (meta['year'] as num?)?.toInt(),
          coverUrl: normalizedCover,
          discCount: discNum,
          tracks: <ExternalTrackIngest>[
            ExternalTrackIngest(
              externalTrackId: cleanExternalId,
              title: _nonEmptyMetaString(item.title) ?? cleanExternalId,
              artistName: effectiveArtist,
              discNumber: discNum,
              trackNumber: trackNum,
              durationMs: durMs,
              isrc: _nonEmptyMetaString(meta['isrc']),
              genre: _nonEmptyMetaString(meta['genre']),
              composer: _nonEmptyMetaString(meta['composer']),
              codec: _nonEmptyMetaString(meta['codec']),
              sampleRateHz: (meta['sample_rate_hz'] as num?)?.toInt(),
              bitDepth: (meta['bit_depth'] as num?)?.toInt(),
              bitrateKbps: (meta['bitrate_kbps'] as num?)?.toInt(),
            ),
          ],
        ),
      ],
    );
  }

  Future<ExternalCatalogIngestBatch> _buildPromoteAlbumBatch(
    ListenLaterItem item, {
    required Map<String, dynamic> meta,
    required String providerId,
    required String rawExternalId,
    required String cleanExternalId,
    required String effectiveArtist,
    required String? normalizedCover,
  }) async {
    var tracks = _extractEmbeddedTracks(
      meta['tracks'],
      providerId: providerId,
      fallbackArtist: effectiveArtist,
    );
    var releaseYear = (meta['release_year'] as num?)?.toInt() ??
        (meta['year'] as num?)?.toInt();
    var albumTitle = _nonEmptyMetaString(item.title) ??
        _nonEmptyMetaString(item.albumTitle) ??
        'Unknown Album';
    var artistName = effectiveArtist;
    var coverUrl = normalizedCover;
    String? fetchFailure;
    if (tracks.isEmpty) {
      final provider = coordinator.streamingManager.providerFor(providerId);
      CanonicalAlbumDetail? detail;
      if (provider != null) {
        try {
          detail = await provider.fetchAlbumDetail(cleanExternalId);
          if (detail == null && rawExternalId != cleanExternalId) {
            detail = await provider.fetchAlbumDetail(rawExternalId);
          }
        } catch (err) {
          fetchFailure = err.toString();
        }
      }
      if (detail != null) {
        albumTitle = _nonEmptyMetaString(detail.title) ?? albumTitle;
        artistName = _nonEmptyMetaString(detail.artistName) ?? artistName;
        releaseYear ??= detail.releaseYear;
        coverUrl ??= normalizeStreamingCoverUrl(detail.coverUrl);
        tracks = _extractAlbumDetailTracks(
          detail,
          providerId: providerId,
          fallbackArtist: artistName,
        );
      }
    }
    if (tracks.isEmpty) {
      final detailSuffix =
          fetchFailure != null ? ' ($fetchFailure)' : '';
      throw StateError(
        'Could not fetch tracks for external album "$albumTitle" '
        '($providerId:$cleanExternalId) from streaming provider$detailSuffix.',
      );
    }
    final maxDisc = tracks.fold<int>(1, (m, t) => t.discNumber > m ? t.discNumber : m);
    return ExternalCatalogIngestBatch(
      provider: providerId,
      albums: <ExternalAlbumIngest>[
        ExternalAlbumIngest(
          externalAlbumId: cleanExternalId,
          title: albumTitle,
          artistName: artistName,
          albumArtist: artistName,
          releaseYear: releaseYear,
          coverUrl: coverUrl,
          discCount: maxDisc,
          tracks: tracks,
        ),
      ],
    );
  }

  static String _stripProviderPrefix(String rawId, String providerId) {
    var trimmed = rawId.trim();
    if (trimmed.isEmpty) return '';
    final prefixes = <String>[
      '$providerId:',
      if (providerId == 'apple_music') 'apple:',
      if (providerId == 'youtube_music') ...['ytm:', 'ytm_'],
    ];
    for (final prefix in prefixes) {
      if (trimmed.toLowerCase().startsWith(prefix)) {
        trimmed = trimmed.substring(prefix.length).trim();
        break;
      }
    }
    return trimmed;
  }

  static String? _nonEmptyMetaString(dynamic raw) {
    final s = raw?.toString().trim();
    return (s != null && s.isNotEmpty) ? s : null;
  }

  static List<ExternalTrackIngest> _extractEmbeddedTracks(
    dynamic rawTracks, {
    required String providerId,
    required String fallbackArtist,
  }) {
    if (rawTracks is! List || rawTracks.isEmpty) {
      return const <ExternalTrackIngest>[];
    }
    final seen = <String>{};
    final out = <ExternalTrackIngest>[];
    for (var i = 0; i < rawTracks.length; i++) {
      final raw = rawTracks[i];
      if (raw is! Map) continue;
      final m = Map<String, dynamic>.from(raw);
      final rawId =
          _nonEmptyMetaString(m['external_track_id']) ??
          _nonEmptyMetaString(m['id']) ??
          '';
      final cleanId = _stripProviderPrefix(rawId, providerId);
      if (cleanId.isEmpty || !seen.add(cleanId)) continue;
      final discNum = (m['disc_number'] as num?)?.toInt() ?? 1;
      final trackNum = (m['track_number'] as num?)?.toInt() ?? (i + 1);
      final durMs = (m['duration_ms'] as num?)?.toInt() ?? 0;
      out.add(
        ExternalTrackIngest(
          externalTrackId: cleanId,
          title: _nonEmptyMetaString(m['title']) ?? cleanId,
          artistName: _nonEmptyMetaString(m['artist_name']) ??
              _nonEmptyMetaString(m['artist']) ??
              fallbackArtist,
          discNumber: discNum.clamp(1, 999),
          trackNumber: trackNum.clamp(1, 9999),
          durationMs: durMs.clamp(0, 1 << 50),
          isrc: _nonEmptyMetaString(m['isrc']),
          genre: _nonEmptyMetaString(m['genre']),
          composer: _nonEmptyMetaString(m['composer']),
          codec: _nonEmptyMetaString(m['codec']),
          sampleRateHz: (m['sample_rate_hz'] as num?)?.toInt(),
          bitDepth: (m['bit_depth'] as num?)?.toInt(),
          bitrateKbps: (m['bitrate_kbps'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  static List<ExternalTrackIngest> _extractAlbumDetailTracks(
    CanonicalAlbumDetail detail, {
    required String providerId,
    required String fallbackArtist,
  }) {
    if (detail.versions.isEmpty) return const <ExternalTrackIngest>[];
    final version = detail.versions.firstWhere(
      (v) => v.tracks.isNotEmpty,
      orElse: () => detail.versions.first,
    );
    final seen = <String>{};
    final out = <ExternalTrackIngest>[];
    for (var i = 0; i < version.tracks.length; i++) {
      final t = version.tracks[i];
      final rawId = t.externalTrackId.trim().isNotEmpty
          ? t.externalTrackId.trim()
          : t.id.trim();
      final cleanId = _stripProviderPrefix(rawId, providerId);
      if (cleanId.isEmpty || !seen.add(cleanId)) continue;
      out.add(
        ExternalTrackIngest(
          externalTrackId: cleanId,
          title: t.title.trim().isNotEmpty ? t.title.trim() : cleanId,
          artistName: fallbackArtist,
          discNumber: t.discNumber > 0 ? t.discNumber : 1,
          trackNumber: t.trackNumber > 0 ? t.trackNumber : (i + 1),
          durationMs: t.durationMs > 0 ? t.durationMs : 0,
          codec: t.codec.trim().isNotEmpty ? t.codec.trim() : null,
          sampleRateHz: t.sampleRateHz > 0 ? t.sampleRateHz : null,
          bitDepth: t.bitDepth > 0 ? t.bitDepth : null,
        ),
      );
    }
    return out;
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
    final target = filtered.tracks[filtered.startIndex];
    coordinator.setQueueContext(
      filtered.tracks,
      currentTrack: target,
      queueIndex: filtered.startIndex,
    );
    if (!coordinator.shouldInterceptTrack(target) && !_isLocalTrack(target)) {
      await coordinator.stopExternalIfActive();
      return inner.playQueue(
        filtered.tracks,
        startIndex: filtered.startIndex,
        excludeBanned: false,
        explicitTrack: explicitTrack,
      );
    }
    await coordinator.playTrack(
      target,
      queueContext: filtered.tracks,
      queueIndex: filtered.startIndex,
    );
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
    if (filtered.isEmpty) return 0;
    return coordinator._enqueueTracksImpl(filtered, playNext: playNext);
  }

  @override
  Future<int> clearUpcomingQueue() => coordinator._clearUpcomingQueueImpl();
}
