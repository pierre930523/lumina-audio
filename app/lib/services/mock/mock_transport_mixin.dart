part of '../mock_audio_service.dart';

mixin _MockTransportMixin on _MockAudioServiceBase {
  @override
  Future<void> pause() async {
    _playbackInterruptHandler?.call();
    _emitState(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> resume() async {
    if (_needsLoadOnResume && _state.track != null) {
      await play(track: null);
      return;
    }
    _emitState(_state.copyWith(status: PlaybackStatus.playing));
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
    _emitState(_state.copyWith(deviceLost: false));
  }

  @override
  Future<void> stop() async {
    _playbackInterruptHandler?.call();
    _clearStandby();
    _emitState(
      _state.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    final trackDur = _state.track?.duration;
    final maxDur = (trackDur != null && trackDur > Duration.zero)
        ? trackDur
        : const Duration(hours: 24);
    final clamped = position < Duration.zero
        ? Duration.zero
        : (position > maxDur ? maxDur : position);
    _emitState(_state.copyWith(position: clamped));
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _savedNormalVolume = clamped;
    if (_strictBitPerfect) {
      _emitState(_state.copyWith(volume: 1.0, isMuted: false));
      return;
    }
    _emitState(
      _state.copyWith(
        volume: clamped,
        isMuted: clamped == 0.0,
      ),
    );
  }

  @override
  Future<void> toggleMute() async {
    if (_strictBitPerfect) return;
    _emitState(_state.copyWith(isMuted: !_state.isMuted));
  }

  int _findNextNonBannedIndex(int delta) {
    if (_queue.isEmpty) return -1;
    final len = _queue.length;
    final step = delta >= 0 ? 1 : -1;
    for (var checked = 1; checked <= len; checked++) {
      final candidate = (_currentIndex + checked * step + len * 2) % len;
      if (_queue[candidate].preference != -1) {
        return candidate;
      }
    }
    return -1;
  }

  @override
  Future<void> next() async {
    final nextIdx = _findNextNonBannedIndex(1);
    if (nextIdx < 0) return;
    _currentIndex = nextIdx;
    final target = _queue[_currentIndex];
    if (_streamingTrackHandler != null &&
        AudioService.isStreamingTrackId(target.id)) {
      await _streamingTrackHandler!(
        target,
        queueContext: null,
        debounce: true,
      );
      return;
    }
    _playbackInterruptHandler?.call();
    _emitState(
      _state.copyWith(
        track: target,
        position: Duration.zero,
      ),
    );
    _emitSignalPath();
  }

  @override
  Future<void> previous() async {
    final prevIdx = _findNextNonBannedIndex(-1);
    if (prevIdx < 0) return;
    _currentIndex = prevIdx;
    final target = _queue[_currentIndex];
    if (_streamingTrackHandler != null &&
        AudioService.isStreamingTrackId(target.id)) {
      await _streamingTrackHandler!(
        target,
        queueContext: null,
        debounce: true,
      );
      return;
    }
    _playbackInterruptHandler?.call();
    _emitState(
      _state.copyWith(
        track: target,
        position: Duration.zero,
      ),
    );
    _emitSignalPath();
  }
}
