part of '../server_audio_service.dart';

mixin _ServerTransportAndMediaMixin on _ServerAudioServiceBase {
  @override
  Future<void> pause() async {
    _playbackInterruptHandler?.call();
    _abortActivePlayRequest();
    final opEpoch = _activeEpoch;
    if (_state.status == PlaybackStatus.loading) {
      _needsLoadOnResume = true;
    }
    await _requestJson('POST', '/api/v1/playback/pause');
    if (_disposed || opEpoch != _activeEpoch) return;
    _state = _state.copyWith(status: PlaybackStatus.paused);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> resume() async {
    if (_needsLoadOnResume && _state.track != null) {
      await play(track: null);
      return;
    }
    await _requestJson('POST', '/api/v1/playback/resume');
    _state = _state.copyWith(status: PlaybackStatus.playing);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> togglePlayPause() async {
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else if (_state.status == PlaybackStatus.paused) {
      if (_needsLoadOnResume && _state.track != null) {
        await play(track: null);
      } else {
        await resume();
      }
    } else {
      await play();
    }
  }

  @override
  Future<void> reconnectDevice() async {
    await _requestJson('POST', '/api/v1/playback/reconnect');
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    final (code, data) = await _requestJson('GET', '/api/v1/playback/state');
    if (code == 200 && data is Map<String, dynamic>) {
      return data;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/artwork/${Uri.encodeComponent(trackId)}?max_dim=$maxDim',
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/library/artwork/${Uri.encodeComponent(trackId)}/override',
      body: {'image_path': imagePath, 'file_path': ?path},
    );
    return code == 200;
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/library/artwork/${Uri.encodeComponent(trackId)}/override',
    );
    return code == 200;
  }

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/rescan',
      body: {'directory': directory, 'force': force},
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/lyrics/${Uri.encodeComponent(trackId)}',
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/lyrics/${Uri.encodeComponent(trackId)}/override',
      body: {'file_path': filePath, 'path': ?path},
    );
    if (code == 200) {
      unawaited(_fetchLyrics(trackId, path: path));
      return true;
    }
    return false;
  }

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/lyrics/${Uri.encodeComponent(trackId)}/override',
    );
    if (code == 200) {
      _currentLyrics = const [];
      return true;
    }
    return false;
  }

  @override
  Future<void> stop() async {
    _playbackInterruptHandler?.call();
    _abortActivePlayRequest();
    if (_activeEpoch > 0 && _activeEpoch != _lastCancelledEpoch) {
      _activeEpoch++;
    }
    _lastCancelledEpoch = 0;
    final stopEpoch = _activeEpoch;
    await _requestJson('POST', '/api/v1/playback/stop');
    if (_disposed || stopEpoch != _activeEpoch) return;
    _state = _state.copyWith(
      status: PlaybackStatus.stopped,
      position: Duration.zero,
      playbackEpoch: _activeEpoch,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    final opEpoch = _activeEpoch;
    await _requestJson(
      'POST',
      '/api/v1/playback/seek',
      body: {'position_ms': position.inMilliseconds},
    );
    if (_disposed || opEpoch != _activeEpoch) return;
    _state = _state.copyWith(position: position);
    if (!_stateController.isClosed) _stateController.add(_state);
    if (!_positionController.isClosed) _positionController.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await _requestJson(
      'POST',
      '/api/v1/playback/volume',
      body: {'volume': clamped},
    );
    _state = _state.copyWith(volume: clamped, isMuted: clamped == 0.0);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> toggleMute() async {
    final nextMuted = !_state.isMuted;
    await setVolume(nextMuted ? 0.0 : _state.volume);
    _state = _state.copyWith(isMuted: nextMuted);
  }

  @override
  Future<void> next() async {
    await _requestJson('POST', '/api/v1/playback/next');
  }

  @override
  Future<void> previous() async {
    await _requestJson('POST', '/api/v1/playback/previous');
  }

  @override
  Future<void> toggleDspBypass() async {
    final cfg = await getDspConfig();
    await setDspConfig(cfg.copyWith(bypass: !cfg.bypass));
  }

  @override
  void setSimulatedQuality(SignalQuality quality) {}
}
