part of '../home_screen.dart';

extension _HomeWindowTray on _HomeScreenState {
  bool _isTrayIdleState(PlaybackState state) =>
      state.track == null ||
      state.status == PlaybackStatus.stopped ||
      state.status == PlaybackStatus.uninitialized;

  String _trayTrackKeyFor(PlaybackState state) {
    final t = state.track;
    if (t == null) return 'none';
    return '${t.id}|${t.title}|${t.artist}|${t.album}|${t.artworkUrl ?? ''}|${t.duration.inMilliseconds}';
  }

  ({String tooltip, String nowPlayingLabel, bool isPlaying}) _trayInfoFor(
    PlaybackState state,
  ) {
    final track = state.track;
    final isPlaying = state.status == PlaybackStatus.playing;
    if (_isTrayIdleState(state) || track == null) {
      return (
        tooltip: 'Lumina Audio — 待機中',
        nowPlayingLabel: 'Lumina Audio — 待機中',
        isPlaying: false,
      );
    }
    return (
      tooltip: 'Lumina Audio — ${track.title} - ${track.artist}',
      nowPlayingLabel: '正在播放：${track.title} - ${track.artist}',
      isPlaying: isPlaying,
    );
  }

  void _syncTrayFromState(PlaybackState state) {
    final trackKey = _trayTrackKeyFor(state);
    final isPlaying = state.status == PlaybackStatus.playing;
    final isIdle = _isTrayIdleState(state);
    if (trackKey == _lastTrayTrackKey &&
        isPlaying == _lastTrayPlaying &&
        isIdle == _lastTrayIdle) {
      return;
    }
    _lastTrayTrackKey = trackKey;
    _lastTrayPlaying = isPlaying;
    _lastTrayIdle = isIdle;
    final info = _trayInfoFor(state);
    final track = state.track;
    unawaited(
      _windowController.updateSystemMediaControls(
        title: isIdle ? null : track?.title,
        artist: isIdle ? null : track?.artist,
        album: isIdle ? null : track?.album,
        artworkUrl: isIdle ? null : track?.artworkUrl,
        duration: isIdle ? null : track?.duration,
        position: isIdle ? null : state.position,
        isPlaying: info.isPlaying,
        tooltip: info.tooltip,
        nowPlayingLabel: info.nowPlayingLabel,
      ),
    );
  }

  void _onTrackChanged(TrackInfo track) {
    final cur = _effectiveAudioService.currentState;
    final effective = cur.track?.id == track.id
        ? cur
        : cur.copyWith(track: track, position: Duration.zero);
    _onPlaybackState(effective);
  }

  void _onPlaybackState(PlaybackState state) {
    _syncTrayFromState(state);
    if (_isStartupRestoring ||
        _playbackPersistenceService.isRestoring ||
        _isExiting) {
      return;
    }

    final isPlaying = state.status == PlaybackStatus.playing;
    final statusChanged = state.status != _lastPersistedStatus;
    final trackChanged = state.track?.id != _lastPersistedTrackId;
    _lastPersistedStatus = state.status;
    _lastPersistedTrackId = state.track?.id;

    if (isPlaying || state.status == PlaybackStatus.loading) {
      final snapshot = _playbackPersistenceService.buildSnapshot(
        state: state,
        queue: _effectiveAudioService.queue,
      );
      _playbackPersistenceService.saveThrottled(snapshot);
    } else if (statusChanged || trackChanged) {
      final snapshot = _playbackPersistenceService.buildSnapshot(
        state: state,
        queue: _effectiveAudioService.queue,
      );
      unawaited(_playbackPersistenceService.saveImmediate(snapshot));
    }
  }

  void _handleWindowClose() {
    if (_isExiting) return;
    if (_scaleController.minimizeToTrayOnClose) {
      final snap = _playbackPersistenceService.buildSnapshot(
        state: _effectiveAudioService.currentState,
        queue: _effectiveAudioService.queue,
      );
      unawaited(_playbackPersistenceService.saveImmediate(snap));
      if (mounted) {
        _refreshState(() {
          _isHiddenToTray = true;
        });
      } else {
        _isHiddenToTray = true;
      }
      _effectiveAudioService.setWindowMinimized(true);
      unawaited(_windowController.hide());
      return;
    }
    unawaited(_performCleanExit());
  }

  void _handleWindowMinimize() {
    if (_isExiting) return;
    // Never disable root TickerMode on taskbar minimize; only minimize audio/visualizer work.
    _effectiveAudioService.setWindowMinimized(true);
  }

  void _handleWindowRestoredOrFocused() {
    if (_isExiting) return;
    final stateChanged =
        _isHiddenToTray ||
        _windowController.isHiddenToTrayNotifier.value ||
        _windowController.isMinimizedNotifier.value;

    _isHiddenToTray = false;
    _windowController.isHiddenToTrayNotifier.value = false;
    _windowController.isMinimizedNotifier.value = false;
    _effectiveAudioService.setWindowMinimized(false);

    if (!mounted) return;
    if (stateChanged) {
      _refreshState();
    }
    WidgetsBinding.instance.scheduleForcedFrame();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _handleRestoreFromTray() {
    if (_isExiting) return;
    _handleWindowRestoredOrFocused();
    unawaited(() async {
      await _windowController.show();
      await _windowController.focus();
      if (mounted) {
        _refreshState();
      }
    }());
  }

  void _handleTrayMenuAction(String action) {
    switch (action) {
      case 'show':
        _handleRestoreFromTray();
      case 'toggle_play_pause':
        unawaited(_effectiveAudioService.togglePlayPause());
      case 'previous':
        unawaited(_effectiveAudioService.previous());
      case 'next':
        unawaited(_effectiveAudioService.next());
      case 'quit':
        unawaited(_performCleanExit());
    }
  }

  Future<void> _performCleanExit() async {
    if (_isExiting) return;
    _isExiting = true;
    try {
      final baseState = _effectiveAudioService.currentState;
      var effectiveState = baseState;
      try {
        final liveMap = await _effectiveAudioService.getPlaybackState();
        if (liveMap != null) {
          final livePosMs = (liveMap['position_ms'] as num?)?.toInt();
          final liveVol = (liveMap['volume'] as num?)?.toDouble();
          final liveCode = (liveMap['state_code'] as num?)?.toInt();
          effectiveState = baseState.copyWith(
            position: livePosMs != null && livePosMs >= 0
                ? Duration(milliseconds: livePosMs)
                : baseState.position,
            volume: liveVol != null && liveVol.isFinite
                ? liveVol.clamp(0.0, 1.0)
                : baseState.volume,
            status: liveCode != null
                ? PlaybackStatus.fromCode(liveCode)
                : baseState.status,
          );
        }
      } catch (_) {
        effectiveState = _effectiveAudioService.currentState;
      }

      final snapshot = _playbackPersistenceService.buildSnapshot(
        state: effectiveState,
        queue: _effectiveAudioService.queue,
      );
      await _playbackPersistenceService.saveAndFlushForExit(snapshot);

      await _playbackStateSub?.cancel();
      _playbackStateSub = null;
      await _trackChangedSub?.cancel();
      _trackChangedSub = null;
      await _playbackSession.disposeForCleanExit(
        beforeStreamingManagerDispose: () {
          _streamingManager.removeListener(_boundStreamingManagerChanged);
        },
      );
      await _windowController.destroyTray();
      await _windowController.destroy();
    } catch (_) {
      try {
        await _windowController.destroyTray();
      } catch (_) {}
      try {
        await _windowController.destroy();
      } catch (_) {}
    }
  }
}
