part of '../server_audio_service.dart';

mixin _ServerPlaybackMixin on _ServerAudioServiceBase {
  @override
  Future<int> scanDirectory(String path) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/scan',
      body: {'path': path},
    );
    await syncInitialState();
    if (code == 200 && data is Map) {
      return (data['tracks_count'] as num?)?.toInt() ?? _queue.length;
    }
    return _queue.length;
  }

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    final q = query.trim();
    if (q.isEmpty) return List<TrackInfo>.from(_queue);
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/search?q=${Uri.encodeQueryComponent(q)}',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => TrackInfo(
              id: e['id']?.toString() ?? '',
              title: e['title']?.toString() ?? '',
              artist: e['artist']?.toString() ?? '',
              album: 'Search Hit',
              duration: Duration.zero,
              format: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
              ),
              providerName: 'Remote Core',
              preference: (e['preference'] as num?)?.toInt() ?? 0,
              albumGroupId: _serverNonEmptyString(e['album_group_id']),
              externalAlbumId: _serverNonEmptyString(e['external_album_id']),
            ),
          )
          .toList();
    }
    return const [];
  }

  @override
  void setStreamingTrackHandler(StreamingTrackHandler? handler) {
    _streamingTrackHandler = handler;
  }

  @override
  void setPlaybackInterruptHandler(void Function()? handler) {
    _playbackInterruptHandler = handler;
  }

  @override
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {
    if (queue != null && queue.isNotEmpty) {
      _queue = List<TrackInfo>.from(queue);
    } else if (PlaybackPersistenceService.findTrackIndex(_queue, track) < 0) {
      _queue = [track, ..._queue];
    }
    _needsLoadOnResume = false;
    _lastError = null;
    _state = _state.copyWith(
      status: PlaybackStatus.loading,
      track: track,
      position: Duration.zero,
      playbackEpoch: _activeEpoch,
      clearLastError: true,
    );
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    _tracker.updateActiveDeviceState(_state, queueIndex: idx >= 0 ? idx : 0);
    if (!_stateController.isClosed) _stateController.add(_state);
    if (!_positionController.isClosed) _positionController.add(Duration.zero);
  }

  @override
  void beginOptimisticTrackLoadAtEpoch(
    TrackInfo track, {
    List<TrackInfo>? queue,
    required int epoch,
  }) {
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
      _abortActivePlayRequest();
    }
    beginOptimisticTrackLoad(track, queue: queue);
  }

  @override
  void failOptimisticTrackLoad(TrackInfo track, String message) {
    _lastError = message;
    _state = _state.copyWith(
      status: PlaybackStatus.error,
      track: track,
      position: Duration.zero,
      playbackEpoch: _activeEpoch,
      lastError: message,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> cancelPendingPlayback({int epoch = 0}) async {
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
    }
    if (epoch > 0) {
      _lastCancelledEpoch = _activeEpoch;
    }
    _abortActivePlayRequest();
    if (_state.status == PlaybackStatus.loading) {
      _state = _state.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
    }
  }

  @override
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) =>
      cancelPendingPlayback(epoch: epoch);

  @override
  Future<void> skipToTrack(TrackInfo track, {List<TrackInfo>? queueContext}) =>
      play(track: track);

  @override
  Future<void> play({TrackInfo? track}) async {
    if (_streamingTrackHandler != null) {
      final candidate =
          track ?? _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
      final needsFreshLoad = track != null ||
          _needsLoadOnResume ||
          _state.status == PlaybackStatus.stopped ||
          _state.status == PlaybackStatus.error ||
          _state.status == PlaybackStatus.ended;
      if (candidate != null &&
          needsFreshLoad &&
          AudioService.isStreamingTrackId(candidate.id)) {
        await _streamingTrackHandler!(
          candidate,
          queueContext: null,
          debounce: false,
        );
        return;
      }
    }
    final opEpoch = ++_activeEpoch;
    _lastCancelledEpoch = 0;
    _needsLoadOnResume = false;
    _currentLyrics = const [];
    final body = <String, dynamic>{
      'playback_epoch': opEpoch,
      'epoch': opEpoch,
    };
    if (track != null) {
      if (!AudioService.isStreamingTrackId(track.id)) {
        _playbackInterruptHandler?.call();
      }
      body['track_id'] = track.id;
      if (track.filePath != null) body['file_path'] = track.filePath;
      _needsLoadOnResume = false;
      _state = _state.copyWith(
        track: track,
        playbackEpoch: opEpoch,
        clearLastError: true,
      );
    }
    final dynamic responseBody;
    try {
      final (_, data) = await _requestJson(
        'POST',
        '/api/v1/playback/play',
        body: body,
        trackAsPlayRequest: true,
      );
      responseBody = data;
    } catch (_) {
      if (_disposed || opEpoch != _activeEpoch) return;
      rethrow;
    }
    _applyPlayResponse(responseBody, opEpoch: opEpoch, track: track);
  }

  void _applyPlayResponse(
    dynamic responseBody, {
    required int opEpoch,
    TrackInfo? track,
  }) {
    if (_disposed || opEpoch != _activeEpoch) return;
    final rawStatus = responseBody is Map
        ? responseBody['status']?.toString().toLowerCase().trim()
        : null;
    if (rawStatus == 'ignored') {
      return;
    }
    _lastError = null;
    if (rawStatus == 'loading' || rawStatus == 'buffering') {
      final nextStatus = rawStatus == 'buffering'
          ? PlaybackStatus.buffering
          : PlaybackStatus.loading;
      _state = _state.copyWith(
        status: nextStatus,
        playbackEpoch: opEpoch,
        clearLastError: true,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
      return;
    }
    if (track != null) {
      unawaited(_fetchLyrics(track.id, path: track.filePath));
    }
    _state = _state.copyWith(
      status: PlaybackStatus.playing,
      playbackEpoch: opEpoch,
      clearLastError: true,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) =>
      _playStreamUrlInternal(
        track: track,
        streamUrl: streamUrl,
        headers: headers,
        hintExtension: hintExtension,
        epoch: _activeEpoch + 1,
      );

  Future<void> _playStreamUrlInternal({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int epoch,
    bool debounced = false,
  }) async {
    if (epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    _lastCancelledEpoch = 0;
    _currentLyrics = const [];
    final body = <String, dynamic>{
      'track_id': track.id,
      'stream_url': streamUrl,
      'playback_epoch': epoch,
      'epoch': epoch,
      if (debounced) 'debounced': true,
      if (track.filePath != null) 'file_path': track.filePath,
      if (headers.isNotEmpty) 'headers': headers,
      if (hintExtension != null && hintExtension.isNotEmpty)
        'hint_extension': hintExtension,
      'source': track.providerName,
    };
    _needsLoadOnResume = false;
    _emitServerLoadingState(track, epoch);
    final dynamic responseBody;
    try {
      final (_, data) = await _requestJson(
        'POST',
        '/api/v1/playback/play',
        body: body,
        trackAsPlayRequest: true,
      );
      responseBody = data;
    } catch (_) {
      if (_disposed || epoch != _activeEpoch) return;
      rethrow;
    }
    _applyPlayResponse(responseBody, opEpoch: epoch, track: track);
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) {
    if (requestId > 0 && requestId < _activeEpoch) {
      return Future<void>.value();
    }
    return _playStreamUrlInternal(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      epoch: requestId > 0 ? requestId : (_activeEpoch + 1),
    );
  }

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) =>
      playStreamSpecWithOptions(track, spec, epoch: epoch, debounced: false);

  @override
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) async {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter ServerAudioService',
      );
    }
    if (epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    _lastCancelledEpoch = 0;
    _currentLyrics = const [];

    final body = <String, dynamic>{
      'track_id': track.id,
      'playback_epoch': epoch,
      'epoch': epoch,
      if (debounced) 'debounced': true,
      'source_spec': spec.toJson(),
      'source': track.providerName,
    };
    switch (spec) {
      case DirectRangeSpec():
        body['stream_url'] = spec.url;
        if (spec.headers.isNotEmpty) body['headers'] = spec.headers;
        if (spec.hintExtension != null && spec.hintExtension!.isNotEmpty) {
          body['hint_extension'] = spec.hintExtension;
        }
      case EncryptedRangeSpec():
        body['stream_url'] = spec.url;
        if (spec.headers.isNotEmpty) body['headers'] = spec.headers;
        if (spec.hintExtension != null && spec.hintExtension!.isNotEmpty) {
          body['hint_extension'] = spec.hintExtension;
        }
      case SegmentedManifestSpec():
        if (spec.headers.isNotEmpty) body['headers'] = spec.headers;
      case LocalFileSpec():
        body['file_path'] = spec.path;
      case ExternalBackendSpec():
        throw StateError(
          'ExternalBackendSpec (${spec.providerId}) cannot enter ServerAudioService',
        );
    }

    _needsLoadOnResume = false;
    _emitServerLoadingState(track, epoch);
    final dynamic responseBody;
    try {
      final (_, data) = await _requestJson(
        'POST',
        '/api/v1/playback/play',
        body: body,
        trackAsPlayRequest: true,
      );
      responseBody = data;
    } catch (_) {
      if (_disposed || epoch != _activeEpoch) return;
      rethrow;
    }
    _applyPlayResponse(responseBody, opEpoch: epoch, track: track);
  }

  void _emitServerLoadingState(TrackInfo track, int epoch) {
    final alreadyLoadingSame = _state.status == PlaybackStatus.loading &&
        _state.track?.id == track.id &&
        _state.playbackEpoch == epoch &&
        _state.position == Duration.zero;
    _state = _state.copyWith(
      status: PlaybackStatus.loading,
      track: track,
      position: Duration.zero,
      playbackEpoch: epoch,
      clearLastError: true,
    );
    if (!alreadyLoadingSame) {
      if (!_stateController.isClosed) _stateController.add(_state);
      if (!_positionController.isClosed) _positionController.add(Duration.zero);
    }
  }

  @override
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  }) async {
    if (queue != null && queue.isNotEmpty) {
      _queue = List<TrackInfo>.from(queue);
    } else if (PlaybackPersistenceService.findTrackIndex(_queue, track) < 0) {
      _queue = [track, ..._queue];
    }
    final maxDur = track.duration > Duration.zero
        ? track.duration
        : const Duration(hours: 24);
    final clampedPos = position < Duration.zero
        ? Duration.zero
        : (position > maxDur ? maxDur : position);
    final effVol = (volume ?? _state.volume).clamp(0.0, 1.0);
    final muted = isMuted ?? (effVol == 0.0);
    _needsLoadOnResume = true;
    _state = PlaybackState(
      status: PlaybackStatus.paused,
      track: track,
      position: clampedPos,
      volume: effVol,
      isMuted: muted,
      seekEpoch: _state.seekEpoch,
      isSeeking: false,
      lastError: null,
      deviceLost: _state.deviceLost,
      clockSource: _state.clockSource,
    );
    _tracker.updateActiveDeviceState(_state, queueIndex: queueIndex);
    if (!_stateController.isClosed) _stateController.add(_state);
    if (!_positionController.isClosed) _positionController.add(_state.position);
  }
}
