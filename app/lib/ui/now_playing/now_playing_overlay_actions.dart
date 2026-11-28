part of 'now_playing_overlay.dart';

extension _NowPlayingOverlayActions on NowPlayingOverlayState {
  void _onQueueScroll() {
    if (!_queueScrollController.hasClients) return;
    _controller.saveQueueScrollOffset(_queueScrollController.offset);
  }

  void _onQueueDrawerAnimStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      _mutateState(() {});
    }
  }

  bool _handleQueueEscape() {
    if (!_controller.queueDrawerOpen || !widget.isVisible) {
      EscapeDismissRegistry.instance.unregister(_queueEscapeHandler);
      return false;
    }
    _controller.setQueueDrawerOpen(false);
    return true;
  }

  void _syncQueueEscapeRegistration() {
    if (widget.isVisible && _controller.queueDrawerOpen) {
      EscapeDismissRegistry.instance.register(_queueEscapeHandler);
    } else {
      EscapeDismissRegistry.instance.unregister(_queueEscapeHandler);
    }
  }

  String _computeStructuralSignature(
    PlaybackState state,
    List<LyricLine> lyrics,
  ) {
    final first = lyrics.isNotEmpty ? lyrics.first : null;
    final last = lyrics.isNotEmpty ? lyrics.last : null;
    return '${NowPlayingOverlayState._trackIdentityKey(state.track)}|'
        '${state.status.index}|'
        '${state.track?.duration.inMilliseconds ?? -1}|'
        '${lyrics.length}|'
        '${first?.text ?? ''}|${first?.words.length ?? 0}|'
        '${last?.text ?? ''}|${last?.words.length ?? 0}';
  }

  bool get _needsLivePositionUpdates {
    if (!widget.isVisible || !widget.isTransitionSettled) return false;
    if (!widget.hasHostControls) return true;
    return _controller.mode != NowPlayingViewMode.cover ||
        !_modeAnimController.isDismissed;
  }

  void _syncFromAudioService() {
    final state = widget.audioService.currentState;
    final lyrics = List<LyricLine>.from(widget.audioService.currentLyrics);
    _structuralState = state;
    _structuralLyrics = lyrics;
    _structuralSignature = _computeStructuralSignature(state, lyrics);
    if (_positionNotifier.value != state.position) {
      _positionNotifier.value = state.position;
    }
    final nextKey = NowPlayingOverlayState._trackIdentityKey(state.track);
    if (nextKey != _resolvedArtworkTrackKey) {
      _resolvedArtworkTrackKey = nextKey;
      _resolvedCoverPath = null;
      _resolvedCoverUrl = null;
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    var needsSetState = false;
    if (_controller.mode != _lastMode) {
      _lastMode = _controller.mode;
      if (_controller.mode == NowPlayingViewMode.cover) {
        if (widget.isVisible) {
          _modeAnimController.reverse();
        } else {
          _modeAnimController.value = 0.0;
        }
      } else if (_controller.mode == NowPlayingViewMode.split) {
        if (widget.isVisible) {
          _modeAnimController.forward();
        } else {
          _modeAnimController.value = 1.0;
        }
      }
      if (_controller.mode != NowPlayingViewMode.cover) {
        final livePos = widget.audioService.currentState.position;
        if (_positionNotifier.value != livePos) {
          _positionNotifier.value = livePos;
        }
      }
      needsSetState = true;
    }
    if (_controller.queueDrawerOpen != _lastQueueDrawerOpen) {
      _lastQueueDrawerOpen = _controller.queueDrawerOpen;
      if (_lastQueueDrawerOpen) {
        _queueDrawerAnimController.forward();
      } else if (widget.isVisible) {
        _queueDrawerAnimController.reverse();
      } else {
        _queueDrawerAnimController.value = 0.0;
      }
      _syncQueueEscapeRegistration();
      needsSetState = true;
    }
    if (needsSetState) {
      _mutateState(() {});
    }
  }

  void _toggleCoverSplitMode() {
    final isHeadingToSplit =
        _modeAnimController.status == AnimationStatus.forward ||
        (_modeAnimController.value > 0.5 &&
            _modeAnimController.status != AnimationStatus.reverse);
    if (isHeadingToSplit) {
      _modeAnimController.reverse();
      _controller.setMode(NowPlayingViewMode.cover);
    } else {
      final livePos = widget.audioService.currentState.position;
      if (_positionNotifier.value != livePos) {
        _positionNotifier.value = livePos;
      }
      _modeAnimController.forward();
      _controller.setMode(NowPlayingViewMode.split);
    }
  }

  void _onTrackChanged(TrackInfo track) {
    if (!mounted) return;
    final cur = widget.audioService.currentState;
    _onPlaybackState(
      cur.track?.id == track.id
          ? cur
          : cur.copyWith(track: track, position: Duration.zero),
    );
  }

  void _onPlaybackState(PlaybackState state) {
    final nextKey = NowPlayingOverlayState._trackIdentityKey(state.track);
    final trackArtworkChanged = nextKey != _resolvedArtworkTrackKey;
    final liveLyrics = widget.audioService.currentLyrics;
    final nextSig = _computeStructuralSignature(state, liveLyrics);
    final structuralChanged = nextSig != _structuralSignature;

    if ((_needsLivePositionUpdates ||
            structuralChanged ||
            trackArtworkChanged) &&
        _positionNotifier.value != state.position) {
      _positionNotifier.value = state.position;
    }

    if (!structuralChanged && !trackArtworkChanged) {
      return;
    }

    if (mounted) {
      _mutateState(() {
        _structuralState = state;
        _structuralLyrics = List<LyricLine>.from(liveLyrics);
        _structuralSignature = nextSig;
        if (trackArtworkChanged) {
          _resolvedArtworkTrackKey = nextKey;
          _resolvedCoverPath = null;
          _resolvedCoverUrl = null;
        }
      });
    } else {
      _structuralState = state;
      _structuralLyrics = List<LyricLine>.from(liveLyrics);
      _structuralSignature = nextSig;
      if (trackArtworkChanged) {
        _resolvedArtworkTrackKey = nextKey;
        _resolvedCoverPath = null;
        _resolvedCoverUrl = null;
      }
    }
  }

  void _handleArtworkResolved(
    TrackInfo? track,
    String? cachePath,
    String? coverUrl,
  ) {
    if (!mounted) return;
    if (NowPlayingOverlayState._trackIdentityKey(track) !=
        _resolvedArtworkTrackKey) {
      return;
    }
    final nextPath =
        (cachePath != null && cachePath.isNotEmpty) ? cachePath : null;
    final nextUrl =
        (coverUrl != null && coverUrl.isNotEmpty) ? coverUrl : null;
    if (nextPath == _resolvedCoverPath && nextUrl == _resolvedCoverUrl) {
      return;
    }
    // Avoid a redundant frame-2 full-overlay rebuild when AmbientDynamicBackground
    // already resolves the exact same artwork path synchronously via LibraryIndexCache.
    final cache = widget.libraryCache;
    if (cache != null && nextPath != null && track != null) {
      final cachedTrackPath =
          track.id.isNotEmpty ? cache.getArtworkPathSync(track.id) : null;
      final albumId = cache.resolveAlbumIdForTrack(track);
      final cachedAlbumPath =
          (albumId != null && albumId.isNotEmpty)
              ? cache.getArtworkPathSync(albumId)
              : null;
      if (cachedTrackPath == nextPath || cachedAlbumPath == nextPath) {
        _resolvedCoverPath = nextPath;
        _resolvedCoverUrl = nextUrl;
        return;
      }
    }
    _mutateState(() {
      _resolvedCoverPath = nextPath;
      _resolvedCoverUrl = nextUrl;
    });
  }

  void _toggleShuffle() {
    unawaited(widget.audioService.setShuffle(!_isShuffleEnabled));
    if (mounted) {
      _mutateState(() {});
    }
  }

  void _cycleRepeat() {
    final nextMode = widget.audioService.repeatMode.nextCycle;
    unawaited(widget.audioService.setRepeatMode(nextMode));
    if (mounted) {
      _mutateState(() {});
    }
  }

  void _handlePrevious() {
    unawaited(widget.audioService.previous());
  }

  Future<void> _handleNext() async {
    if (_repeatMode == LuminaRepeatMode.one) {
      await widget.audioService.seek(Duration.zero);
      if (widget.audioService.currentState.status != PlaybackStatus.playing) {
        await widget.audioService.play();
      }
      return;
    }
    final queue = widget.audioService.queue;
    if (_isShuffleEnabled && queue.length > 1) {
      final currentId = widget.audioService.currentState.track?.id;
      final candidates = queue
          .where((t) => t.id != currentId && t.preference != -1)
          .toList();
      if (candidates.isNotEmpty) {
        final chosen = candidates[_random.nextInt(candidates.length)];
        unawaited(widget.audioService.skipToTrack(chosen, queueContext: queue));
        return;
      }
    }
    unawaited(widget.audioService.next());
  }
}
