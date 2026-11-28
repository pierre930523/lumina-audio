part of '../ffi_audio_service.dart';

mixin _FfiMediaAndLibraryMixin on _FfiAudioServiceBase {
  @override
  Future<int> scanDirectory(String path) async {
    if (!isNativeBound) {
      return _delegate.scanDirectory(path);
    }
    final raw = await _callWriteWorker<String>('scan_dir', {'path': path});
    if (_disposed) return _queue.length;
    String? scanId;
    Map<String, dynamic>? decoded;
    if (raw != null && raw.isNotEmpty) {
      try {
        final obj = jsonDecode(raw);
        if (obj is Map<String, dynamic>) {
          decoded = obj;
          scanId = obj['scan_id']?.toString();
        }
      } catch (_) {}
    }
    await _reloadTracksFromNativeAsync(scanId: scanId);
    if (_disposed) return _queue.length;
    _emitState(_state);
    if (decoded != null) {
      return (decoded['tracks_count'] as num?)?.toInt() ?? _queue.length;
    }
    return _queue.length;
  }

  @override
  Future<List<TrackInfo>> getLibraryTracks({int limit = 10000}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getLibraryTracks(limit: limit);
    }
    if (!isNativeBound) {
      return _delegate.getLibraryTracks(limit: limit);
    }
    final effectiveLimit = limit > 0 ? limit : _FfiAudioServiceBase._libraryTracksReloadLimit;
    String? raw;
    if (_readWorker != null) {
      raw = await _callReadWorker<String>('get_tracks', {'limit': effectiveLimit});
    } else if (_libGetTracksFn != null) {
      raw = _takeRustString(_libGetTracksFn!(effectiveLimit));
    }
    if (_disposed) return const [];
    final parsed = _ffiParseTrackListJson(raw);
    _libraryTracks = List<TrackInfo>.unmodifiable(parsed);
    _hasLoadedLibraryTracks = true;
    return parsed;
  }

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    if (!isNativeBound) {
      return _delegate.searchLibrary(query);
    }
    final q = query.trim();
    if (q.isEmpty) {
      return List<TrackInfo>.from(libraryTracks);
    }
    final raw = await _callReadWorker<String>('search', {'query': q, 'limit': 50});
    if (_disposed) return const [];
    final parsed = _ffiParseTrackListJson(raw);
    if (parsed.isNotEmpty || _queue.any((t) => t.filePath != null)) {
      return parsed;
    }
    return _delegate.searchLibrary(q);
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    if (!isNativeBound) {
      return _delegate.getPlaybackState();
    }
    if (_playbackGetStateJsonFn != null) {
      final raw = _takeRustString(_playbackGetStateJsonFn!());
      if (raw != null) {
        try {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          _updateDualDeckSnapshotFromJson(map);
          return map;
        } catch (_) {}
      }
    }
    return {
      'state_code': _state.status.code,
      'state_name': _state.status.name,
      'position_ms': _state.position.inMilliseconds,
      'duration_ms': _state.track?.duration.inMilliseconds ?? 0,
      'clock_source': _state.clockSource,
      'seek_epoch': _state.seekEpoch,
      'is_seeking': _state.isSeeking,
      'dsp_bypassed': _signalPath.dspBypassed,
      'strict_bit_perfect': _strictBitPerfect,
      'volume': _state.volume,
      'last_error': _state.lastError,
      'device_lost': _state.deviceLost,
      'current_track_id': _state.track?.id,
      'swap_generation': _state.swapGeneration,
      'swapGeneration': _state.swapGeneration,
      'playback_epoch': _state.playbackEpoch,
      'playbackEpoch': _state.playbackEpoch,
      'epoch': _state.playbackEpoch,
    };
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    if (!isNativeBound) {
      return _delegate.getArtwork(trackId, path: path, maxDim: maxDim);
    }
    if (_artworkGetFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final raw = await _callReadWorker<String>('artwork_get', {
        'payload': targetPayload,
        'maxDim': maxDim,
      });
      if (_disposed) return null;
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return _delegate.getArtwork(trackId, path: path, maxDim: maxDim);
  }

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    if (!isNativeBound) {
      return _delegate.setUserCover(trackId, imagePath, path: path);
    }
    if (_artworkSetUserCoverFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = await _callWriteWorker<int>('set_user_cover', {
        'payload': targetPayload,
        'imagePath': imagePath,
      });
      return !_disposed && rc == 0;
    }
    return _delegate.setUserCover(trackId, imagePath, path: path);
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    if (!isNativeBound) {
      return _delegate.clearUserCover(trackId, path: path);
    }
    if (_artworkClearUserCoverFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = await _callWriteWorker<int>('clear_user_cover', {
        'payload': targetPayload,
      });
      return !_disposed && rc == 0;
    }
    return _delegate.clearUserCover(trackId, path: path);
  }

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) async {
    if (!isNativeBound) {
      return _delegate.rescanTags(directory: directory, force: force);
    }
    if (_libraryRescanTagsFn != null) {
      final raw = await _callWriteWorker<String>('rescan_tags', {
        'directory': directory,
        'force': force,
      });
      if (_disposed) return null;
      await _reloadTracksFromNativeAsync();
      if (_disposed) return null;
      _emitState(_state);
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return _delegate.rescanTags(directory: directory, force: force);
  }

  @override
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  }) async {
    if (!isNativeBound) {
      return _delegate.getLyrics(trackId, path: path);
    }
    if (_lyricsGetFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final raw = await _callReadWorker<String>('get_lyrics', {
        'payload': targetPayload,
      });
      if (_disposed) return null;
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return _delegate.getLyrics(trackId, path: path);
  }

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) async {
    if (!isNativeBound) {
      return _delegate.setUserLyrics(trackId, filePath, path: path);
    }
    if (_lyricsSetUserFileFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = await _callWriteWorker<int>('set_user_lyrics', {
        'payload': targetPayload,
        'filePath': filePath,
      });
      if (!_disposed && rc == 0 && _state.track?.id == trackId) {
        await _loadLyricsForTrackAsync(_state.track!);
      }
      return !_disposed && rc == 0;
    }
    return _delegate.setUserLyrics(trackId, filePath, path: path);
  }

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) async {
    if (!isNativeBound) {
      return _delegate.clearUserLyrics(trackId, path: path);
    }
    if (_lyricsClearUserFileFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = await _callWriteWorker<int>('clear_user_lyrics', {
        'payload': targetPayload,
      });
      if (!_disposed && rc == 0 && _state.track?.id == trackId) {
        _currentLyrics = const [];
      }
      return !_disposed && rc == 0;
    }
    return _delegate.clearUserLyrics(trackId, path: path);
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getAlbumDetail(albumId);
    }
    if (!isNativeBound || _getAlbumDetailFn == null) {
      return _delegate.getAlbumDetail(albumId);
    }
    final raw = await _callReadWorker<String>('get_album_detail', {
      'albumId': albumId,
    });
    if (_disposed || raw == null || raw == 'null') return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final detail = CanonicalAlbumDetail.fromJson(decoded);
      final nonEmptyVersions = detail.versions
          .where((v) => v.tracks.isNotEmpty)
          .toList(growable: false);
      if (nonEmptyVersions.isEmpty) {
        return null;
      }
      if (nonEmptyVersions.length == detail.versions.length) {
        return detail;
      }
      return detail.copyWith(versions: nonEmptyVersions);
    }
    return null;
  }

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getArtistDetail(artistId);
    }
    if (!isNativeBound || _getArtistDetailFn == null) {
      return _delegate.getArtistDetail(artistId);
    }
    final raw = await _callReadWorker<String>('get_artist_detail', {
      'artistId': artistId,
    });
    if (_disposed || raw == null || raw == 'null') return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return ArtistDetailInfo.fromJson(decoded);
    }
    return null;
  }

  @override
  Future<int> deduplicateLibrary() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.deduplicateLibrary();
    }
    if (!isNativeBound || _deduplicateFn == null) {
      return _delegate.deduplicateLibrary();
    }
    final raw = await _callWriteWorker<String>('deduplicate');
    if (_disposed || raw == null) return 0;
    final decoded = jsonDecode(raw);
    return (decoded is Map ? (decoded['merged_albums'] as num?)?.toInt() : null) ??
        0;
  }

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.enrichLibraryCredits(
        musicBrainzBaseUrl: musicBrainzBaseUrl,
        discogsBaseUrl: discogsBaseUrl,
      );
    }
    if (!isNativeBound || _enrichCreditsFn == null) {
      return _delegate.enrichLibraryCredits(
        musicBrainzBaseUrl: musicBrainzBaseUrl,
        discogsBaseUrl: discogsBaseUrl,
      );
    }
    final payload = jsonEncode({
      'musicbrainz_base_url': ?musicBrainzBaseUrl,
      'discogs_base_url': ?discogsBaseUrl,
    });
    final raw = await _callWriteWorker<String>('enrich_credits', {
      'payload': payload,
    });
    if (_disposed || raw == null) return const {};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  Future<DspPipelineConfigModel> getDspConfig() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getDspConfig();
    }
    if (!isNativeBound || _dspGetConfigFn == null) {
      return _delegate.getDspConfig();
    }
    final raw = _takeRustString(_dspGetConfigFn!());
    if (raw == null) return const DspPipelineConfigModel();
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return DspPipelineConfigModel.fromJson(decoded);
    }
    return const DspPipelineConfigModel();
  }

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.setDspConfig(config);
      return;
    }
    if (!isNativeBound || _dspSetConfigFn == null) {
      await _delegate.setDspConfig(config);
      return;
    }
    _withNativeUtf8(jsonEncode(config.toJson()), (p) => _dspSetConfigFn!(p));
    _refreshSignalPath();
  }

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.importAutoEqProfile(autoEqTxt);
    }
    if (!isNativeBound || _dspImportAutoeqFn == null) {
      return _delegate.importAutoEqProfile(autoEqTxt);
    }
    final raw = _withNativeUtf8(
      autoEqTxt,
      (p) => _takeRustString(_dspImportAutoeqFn!(p)),
    );
    _refreshSignalPath();
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PeqBandModel.fromJson)
          .toList();
    }
    return const [];
  }
}
