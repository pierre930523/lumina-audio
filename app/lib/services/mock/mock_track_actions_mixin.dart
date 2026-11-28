part of '../mock_audio_service.dart';

/// In-memory MockAudioService implementation for single-track options,
/// file info, analysis, re-identify, rescan, visibility, deletion, and reveal.
mixin _MockTrackActionsMixin
    on
        _MockAudioServiceBase,
        _MockAlbumGroupingMixin,
        _MockFocusTagsFoldersMixin,
        _MockStep4Mixin,
        _MockStep5Mixin {
  final Set<String> _hiddenTrackIds = <String>{};
  final Map<String, TrackDeleteMode> _deletedTrackModes =
      <String, TrackDeleteMode>{};
  final Map<String, TrackAnalysisResult> _mockTrackAnalysis =
      <String, TrackAnalysisResult>{};
  final Map<String, int> _mockRescanCounts = <String, int>{};
  final Map<String, int> _mockReidentifyCounts = <String, int>{};
  final List<String> _revealedTrackPaths = <String>[];

  Set<String> get mockHiddenTrackIds => Set<String>.unmodifiable(_hiddenTrackIds);
  Map<String, TrackDeleteMode> get mockDeletedTrackModes =>
      Map<String, TrackDeleteMode>.unmodifiable(_deletedTrackModes);
  Map<String, int> get mockRescanCounts =>
      Map<String, int>.unmodifiable(_mockRescanCounts);
  Map<String, int> get mockReidentifyCounts =>
      Map<String, int>.unmodifiable(_mockReidentifyCounts);
  List<String> get mockRevealedTrackPaths =>
      List<String>.unmodifiable(_revealedTrackPaths);

  void _emitMockLibraryReloaded() {
    if (!_disposed && !_libraryReloadedController.isClosed) {
      _libraryReloadedController.add(null);
    }
  }

  TrackInfo? _findTrackOrDetailEntry(String trackId) {
    final qMatch = _queue.where((t) => t.id == trackId).firstOrNull;
    if (qMatch != null) return qMatch;
    for (final g in _ensureAlbumGroups()) {
      for (final v in g.versions) {
        final vMatch = v.tracks.where((t) => t.id == trackId).firstOrNull;
        if (vMatch != null) {
          return TrackInfo(
            id: vMatch.id,
            title: vMatch.title,
            artist: g.artistName,
            album: g.title,
            duration: Duration(milliseconds: vMatch.durationMs),
            format: AudioFormat(
              codec: AudioCodec.fromString(vMatch.codec),
              sampleRateHz: vMatch.sampleRateHz > 0 ? vMatch.sampleRateHz : 44100,
              bitDepth: vMatch.bitDepth > 0 ? vMatch.bitDepth : 16,
              channels: 2,
              isDsd: vMatch.isDsd,
            ),
            trackNumber: vMatch.trackNumber,
            discNumber: vMatch.discNumber,
            year: g.releaseYear,
            preference: vMatch.preference,
            albumGroupId: g.id,
          );
        }
      }
    }
    return null;
  }

  TrackMetadataLayerModel _buildMockEffectiveLayer(
    TrackInfo? track,
    MetadataPolicy effectivePolicy,
    Map<String, dynamic>? fileMap,
    Map<String, dynamic>? cloudMap,
    Map<String, dynamic>? userMap,
  ) {
    String? pickStr(String key, String? fallback) {
      final u = userMap?[key]?.toString().trim();
      if (u != null && u.isNotEmpty) return u;
      final primary = (effectivePolicy == MetadataPolicy.cloud)
          ? (cloudMap?[key]?.toString().trim())
          : (fileMap?[key]?.toString().trim());
      if (primary != null && primary.isNotEmpty) return primary;
      final secondary = (effectivePolicy == MetadataPolicy.cloud)
          ? (fileMap?[key]?.toString().trim())
          : (cloudMap?[key]?.toString().trim());
      if (secondary != null && secondary.isNotEmpty) return secondary;
      return fallback;
    }

    int? pickInt(String key, int? fallback) {
      int? asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
      final u = asInt(userMap?[key]);
      if (u != null) return u;
      final primary = (effectivePolicy == MetadataPolicy.cloud)
          ? asInt(cloudMap?[key])
          : asInt(fileMap?[key]);
      if (primary != null) return primary;
      final secondary = (effectivePolicy == MetadataPolicy.cloud)
          ? asInt(fileMap?[key])
          : asInt(cloudMap?[key]);
      return secondary ?? fallback;
    }

    return TrackMetadataLayerModel(
      title: pickStr('title', track?.title),
      artistName: pickStr('artist_name', track?.artist),
      albumArtist: pickStr('album_artist', track?.albumArtist ?? track?.artist),
      albumTitle: pickStr('album_title', track?.album),
      discNumber: pickInt('disc_number', track?.discNumber ?? 1),
      trackNumber: pickInt('track_number', track?.trackNumber ?? 1),
      releaseYear: pickInt('release_year', track?.year),
      genre: pickStr('genre', track?.genre),
      composer: pickStr('composer', track?.composer),
      isrc: pickStr('isrc', null),
      lyrics: pickStr('lyrics', null),
    );
  }

  Map<String, dynamic> _defaultFileMetaMap(TrackInfo track) =>
      <String, dynamic>{
        'title': track.title,
        'artist_name': track.artist,
        'album_artist': track.albumArtist ?? track.artist,
        'album_title': track.album,
        'disc_number': track.discNumber ?? 1,
        'track_number': track.trackNumber ?? 1,
        if (track.year != null) 'release_year': track.year,
        if (track.genre != null) 'genre': track.genre,
        if (track.composer != null) 'composer': track.composer,
      };

  TrackFileInfo _buildMockTrackFileInfo(TrackInfo track) {
    final key = 'track:${track.id}';
    final userMap = _entityUserEdits[key];
    final fileMap = _entityFileMeta[key] ?? _defaultFileMetaMap(track);
    final cloudMap = _entityCloudMeta[key];
    final policy = _entityMetaPolicies[key] ?? MetadataPolicy.inherit;
    final effectivePolicy = policy == MetadataPolicy.inherit
        ? _defaultMetadataPolicy
        : policy;
    final effectiveLayer = _buildMockEffectiveLayer(
      track,
      effectivePolicy,
      fileMap,
      cloudMap,
      userMap,
    );
    final analysis = _mockTrackAnalysis[track.id];
    final path = (track.filePath != null && track.filePath!.trim().isNotEmpty)
        ? track.filePath!
        : 'D:\\Music\\${track.artist}\\${track.album}\\${track.title}.${track.format.codec.name}';
    final isLocal = !AudioService.isStreamingTrackId(track.id);
    return TrackFileInfo(
      trackId: track.id,
      versionId: 'ver-mock',
      albumGroupId: track.albumGroupId ?? 'alb-dsotm',
      providerId: isLocal ? 'local' : 'streaming',
      filePath: path,
      isLocalFile: isLocal,
      containerFormat: track.format.codec.displayName,
      format: track.format,
      durationMs: track.duration.inMilliseconds,
      bitrateKbps: track.format.bitrateKbps ?? analysis?.bitrateKbps ?? 1411,
      fileSizeBytes: isLocal ? 42_500_000 : null,
      fileMtime: 1_730_000_000,
      isHidden: _hiddenTrackIds.contains(track.id),
      preference: track.preference,
      corruptionStatus:
          analysis?.corruptionStatus ?? TrackCorruptionStatus.unchecked,
      analysisError: analysis?.analysisError,
      integratedLufs: analysis?.integratedLufs,
      truePeakDb: analysis?.truePeakDb,
      replayGainTrackDb: analysis?.replayGainTrackDb,
      replayGainTrackPeak: analysis?.replayGainTrackPeak,
      waveformPeaks: analysis?.waveformPeaks ?? const <double>[],
      analyzedAt: analysis?.analyzedAt,
      metaPolicy: policy,
      effectivePolicy: effectivePolicy,
      hasUserEdits: userMap != null && userMap.isNotEmpty,
      fileLayer: TrackMetadataLayerModel.fromJson(fileMap),
      cloudLayer: cloudMap != null
          ? TrackMetadataLayerModel.fromJson(cloudMap)
          : null,
      userEditsLayer: userMap != null && userMap.isNotEmpty
          ? TrackMetadataLayerModel.fromJson(userMap)
          : null,
      effectiveLayer: effectiveLayer,
      resolvedLyricsSource: userMap?['lyrics'] != null
          ? 'user_edit'
          : (fileMap['lyrics'] != null ? 'embedded' : null),
    );
  }

  @override
  Future<TrackFileInfo?> getTrackFileInfo(String trackId) async {
    final track = _findTrackOrDetailEntry(trackId);
    if (track == null) return null;
    return _buildMockTrackFileInfo(track);
  }

  @override
  Future<TrackVisibilityResult?> setTrackHidden(
    String trackId,
    bool isHidden,
  ) async {
    if (isHidden) {
      _hiddenTrackIds.add(trackId);
    } else {
      _hiddenTrackIds.remove(trackId);
    }
    _emitMockLibraryReloaded();
    return TrackVisibilityResult(
      trackId: trackId,
      isHidden: isHidden,
      affectedAlbumIds: const <String>['alb-dsotm'],
    );
  }

  @override
  Future<TrackFileInfo?> rescanTrack(String trackId) async {
    _mockRescanCounts[trackId] = (_mockRescanCounts[trackId] ?? 0) + 1;
    final track = _findTrackOrDetailEntry(trackId);
    if (track == null) return null;
    _emitMockLibraryReloaded();
    return _buildMockTrackFileInfo(track);
  }

  @override
  Future<ReidentifyTrackResult?> reidentifyTrack(String trackId) async {
    _mockReidentifyCounts[trackId] = (_mockReidentifyCounts[trackId] ?? 0) + 1;
    final track = _findTrackOrDetailEntry(trackId);
    if (track == null) {
      return ReidentifyTrackResult(
        trackId: trackId,
        matched: false,
        message: 'Track not found',
      );
    }
    final cloud = _entityCloudMeta.putIfAbsent(
      'track:$trackId',
      () => <String, dynamic>{},
    );
    cloud['title'] ??= track.title;
    cloud['artist_name'] ??= track.artist;
    cloud['release_year'] ??= track.year ?? 1973;
    final info = _buildMockTrackFileInfo(track);
    _emitMockLibraryReloaded();
    return ReidentifyTrackResult(
      trackId: trackId,
      matched: true,
      source: 'MusicBrainz',
      musicbrainzRecordingId: 'mb-rec-$trackId',
      fileInfo: info,
    );
  }

  @override
  Future<TrackAnalysisResult?> reanalyzeTrack(String trackId) async {
    final peaks = List<double>.generate(
      64,
      (i) => 0.15 + ((i * 7 % 17) / 20.0),
      growable: false,
    );
    final res = TrackAnalysisResult(
      trackId: trackId,
      corruptionStatus: TrackCorruptionStatus.ok,
      integratedLufs: -12.4,
      truePeakDb: -0.6,
      replayGainTrackDb: -5.6,
      replayGainTrackPeak: 0.93,
      waveformPeaks: peaks,
      bitrateKbps: 1411,
      analyzedAt: _nowIso(),
    );
    _mockTrackAnalysis[trackId] = res;
    _emitMockLibraryReloaded();
    return res;
  }

  @override
  Future<DeleteTrackResult?> deleteTrack(
    String trackId, {
    TrackDeleteMode mode = TrackDeleteMode.libraryOnly,
  }) async {
    _deletedTrackModes[trackId] = mode;
    _queue.removeWhere((t) => t.id == trackId);
    _hiddenTrackIds.remove(trackId);
    for (final g in _ensureAlbumGroups()) {
      for (var i = 0; i < g.versions.length; i++) {
        final v = g.versions[i];
        if (v.tracks.any((t) => t.id == trackId)) {
          final remaining = v.tracks
              .where((t) => t.id != trackId)
              .toList(growable: false);
          g.versions[i] = v.copyWith(
            tracks: remaining,
            trackCount: remaining.length,
          );
        }
      }
    }
    _emitMockLibraryReloaded();
    return DeleteTrackResult(
      trackId: trackId,
      mode: mode,
      deletedFromLibrary: true,
      movedToTrash: mode == TrackDeleteMode.moveToTrash,
    );
  }

  @override
  Future<List<TrackInfo>> getLibraryTracksFiltered({
    int limit = 200,
    bool includeHidden = false,
  }) async {
    final items = _queue
        .where(
          (t) =>
              !_deletedTrackModes.containsKey(t.id) &&
              (includeHidden || !_hiddenTrackIds.contains(t.id)),
        )
        .take(limit)
        .map((t) {
          final eff = _buildMockTrackFileInfo(t).effectiveLayer;
          return t.copyWith(
            title: eff.title ?? t.title,
            artist: eff.artistName ?? t.artist,
            album: eff.albumTitle ?? t.album,
            year: eff.releaseYear ?? t.year,
            genre: eff.genre ?? t.genre,
            composer: eff.composer ?? t.composer,
          );
        })
        .toList(growable: false);
    return items;
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetailFiltered(
    String albumId, {
    bool includeHidden = false,
  }) async {
    final base = await getAlbumDetail(albumId);
    if (base == null) return null;
    if (includeHidden || _hiddenTrackIds.isEmpty || base.versions.isEmpty) {
      return base;
    }
    final nextVersions = <AlbumVersionInfo>[];
    for (final v in base.versions) {
      final kept = v.tracks
          .where((t) => !_hiddenTrackIds.contains(t.id))
          .toList(growable: false);
      if (kept.isNotEmpty) {
        nextVersions.add(v.copyWith(tracks: kept, trackCount: kept.length));
      }
    }
    if (nextVersions.isEmpty) return null;
    return base.copyWith(versions: nextVersions);
  }

  @override
  Future<bool> revealTrackFolder(String filePath) async {
    if (filePath.trim().isEmpty) return false;
    _revealedTrackPaths.add(filePath);
    return true;
  }
}
