part of '../streaming_playback_coordinator.dart';

extension _CoordinatorStandbyExt on StreamingPlaybackCoordinator {
  void _prepareExternalHandoffForNext(
    TrackInfo nextTrack, {
    required int expectedEpoch,
  }) {
    if (_preparedExternalHandoffTrackId == nextTrack.id &&
        _preparedExternalHandoffEpoch == expectedEpoch) {
      return;
    }
    _preparedExternalHandoffTrackId = nextTrack.id;
    _preparedExternalHandoffEpoch = expectedEpoch;
    _preparedStandbyTrackId = null;
    _preparedStandbyEpoch = -1;
    _preparedStandbySpec = null;
    if (_externalBackend is AppleMusicPlaybackBackend) {
      unawaited(
        _externalBackend.prepareExternalHandoff(
          nextTrack,
          epoch: expectedEpoch,
        ),
      );
    }
  }

  void _prepareNativeStandbyForNext(
    TrackInfo nextTrack, {
    required int expectedEpoch,
  }) {
    if (_preparedStandbyTrackId == nextTrack.id &&
        _nativeBackend.isStandbyReady) {
      return;
    }
    if (_attemptedStandbyTrackId == nextTrack.id &&
        _attemptedStandbyEpoch == expectedEpoch) {
      return;
    }

    final fp = nextTrack.filePath?.trim();
    if (fp != null && fp.isNotEmpty) {
      _attemptedStandbyTrackId = nextTrack.id;
      _attemptedStandbyEpoch = expectedEpoch;
      final key = _tryDeriveKey(nextTrack) ?? StreamKey('local', fp, 'default');
      final localSpec = LocalFileSpec(key: key, path: fp);
      _preparedStandbyTrackId = nextTrack.id;
      _preparedStandbyEpoch = expectedEpoch;
      _preparedStandbySpec = localSpec;
      unawaited(_prepareNativeBackendStandby(localSpec, nextTrack, expectedEpoch));
      return;
    }

    final nextKey = _tryDeriveKey(nextTrack);
    if (nextKey == null) return;
    if (streamingManager.isPlaybackAuthBlocked(nextKey.providerId)) {
      if (autoplayController != null &&
          autoplayController!.isAutoTrack(nextTrack.id)) {
        _attemptedStandbyTrackId = nextTrack.id;
        _attemptedStandbyEpoch = expectedEpoch;
        _handleStandbyAutoTrackFailure(
          nextTrack,
          expectedEpoch,
          StreamingException(
            '授權已失效（${nextKey.providerId}）',
            statusCode: 401,
            isTokenExpired: true,
          ),
        );
      }
      return;
    }
    final resolver = _resolverRegistry.resolverFor(nextKey.providerId);
    if (resolver == null) return;

    _attemptedStandbyTrackId = nextTrack.id;
    _attemptedStandbyEpoch = expectedEpoch;
    unawaited(_runNativeStandbyPreDecode(nextTrack, nextKey, expectedEpoch));
  }

  Future<void> _runNativeStandbyPreDecode(
    TrackInfo nextTrack,
    StreamKey nextKey,
    int expectedEpoch,
  ) async {
    if (_disposed || expectedEpoch != _epoch) return;

    final cachedSpec = _peekCachedSpec(nextKey);
    if (cachedSpec != null) {
      if (cachedSpec is ExternalBackendSpec) {
        _prepareExternalHandoffForNext(nextTrack, expectedEpoch: expectedEpoch);
        return;
      }
      final resolvedTrack = cachedSpec.audioFormat != null
          ? nextTrack.copyWith(format: cachedSpec.audioFormat)
          : nextTrack;
      _preparedStandbyTrackId = nextTrack.id;
      _preparedStandbyEpoch = expectedEpoch;
      _preparedStandbySpec = cachedSpec;
      await _prepareNativeBackendStandby(cachedSpec, resolvedTrack, expectedEpoch);
      return;
    }

    if (_inFlightPreResolves.contains(nextTrack.id)) return;

    final useLegacySpecCache = _usesLegacyCoordinatorSpecCache(nextKey);
    final cancel = CancellationToken();
    Timer? timeoutTimer;
    if (resolveTimeout > Duration.zero) {
      timeoutTimer = Timer(resolveTimeout, cancel.cancel);
    }

    _inFlightPreResolves.add(nextTrack.id);
    _preResolveCancelTokens[nextTrack.id] = (
      providerId: nextKey.providerId,
      token: cancel,
    );

    try {
      final StreamSourceSpec spec;
      if (_useCustomResolverRegistry) {
        spec = await _singleFlight.resolve(
          nextKey,
          cancelToken: cancel,
          bypassCache: useLegacySpecCache,
          legacyTrack: nextTrack,
        );
      } else {
        spec = await streamingManager.resolveSourceSpec(
          nextKey,
          cancelToken: cancel,
          bypassCache: useLegacySpecCache,
          legacyTrack: nextTrack,
        );
      }

      if (_disposed || cancel.isCancelled || expectedEpoch != _epoch) {
        return;
      }
      if (spec is ExternalBackendSpec) {
        _prepareExternalHandoffForNext(nextTrack, expectedEpoch: expectedEpoch);
        return;
      }
      if (useLegacySpecCache) {
        _storeSpecCache(nextTrack, spec);
      }
      final resolvedTrack = spec.audioFormat != null
          ? nextTrack.copyWith(format: spec.audioFormat)
          : nextTrack;
      _preparedStandbyTrackId = nextTrack.id;
      _preparedStandbyEpoch = expectedEpoch;
      _preparedStandbySpec = spec;
      await _prepareNativeBackendStandby(spec, resolvedTrack, expectedEpoch);
    } catch (e) {
      if (_disposed || cancel.isCancelled || expectedEpoch != _epoch) {
        return;
      }
      if (e is StreamingException && e.isCancelled) {
        return;
      }
      _handleStandbyAutoTrackFailure(nextTrack, expectedEpoch, e);
    } finally {
      timeoutTimer?.cancel();
      _inFlightPreResolves.remove(nextTrack.id);
      final current = _preResolveCancelTokens[nextTrack.id];
      if (current != null && identical(current.token, cancel)) {
        _preResolveCancelTokens.remove(nextTrack.id);
      }
    }
  }

  void _handleStandbyAutoTrackFailure(
    TrackInfo failedTrack,
    int expectedEpoch,
    Object error,
  ) {
    final ap = autoplayController;
    if (ap == null || !ap.isAutoTrack(failedTrack.id)) return;
    _evictSpecCacheForTrack(failedTrack);
    final res = ap.handleAutoTrackUnplayable(failedTrack, '$error');
    if (res.reachedFailureLimit) {
      _notifiedErrorForEpoch = expectedEpoch;
      onError?.call(
        failedTrack,
        '連續 ${AutoplayController.maxConsecutiveAutoFailures} 首自動推薦曲目無法播放，已停止自動推薦',
        false,
      );
      return;
    }
    final replacement = res.nextTrack;
    if (replacement != null &&
        !_disposed &&
        expectedEpoch == _epoch &&
        replacement.id != failedTrack.id) {
      if (_isExternalTrack(replacement)) {
        _prepareExternalHandoffForNext(
          replacement,
          expectedEpoch: expectedEpoch,
        );
      } else {
        _prepareNativeStandbyForNext(
          replacement,
          expectedEpoch: expectedEpoch,
        );
      }
    }
  }

  Future<void> _prepareNativeBackendStandby(
    StreamSourceSpec spec,
    TrackInfo track,
    int expectedEpoch,
  ) async {
    if (_disposed || expectedEpoch != _epoch) return;
    try {
      await _nativeBackend.prepareStandby(spec, track, epoch: expectedEpoch);
    } catch (e) {
      if (_preparedStandbyTrackId == track.id &&
          _preparedStandbyEpoch == expectedEpoch) {
        _preparedStandbyTrackId = null;
        _preparedStandbyEpoch = -1;
        _preparedStandbySpec = null;
      }
      if (!_disposed && expectedEpoch == _epoch) {
        _handleStandbyAutoTrackFailure(track, expectedEpoch, e);
      }
    }
  }

  void _maybePreResolveNext(PlaybackState state, Duration position) {
    if (_disposed) return;
    if (state.status != PlaybackStatus.playing) return;
    final currentTrack = state.track;
    if (currentTrack == null) return;
    if (position < Duration.zero) return;

    final TrackInfo nextTrack;
    final ap = autoplayController;
    if (ap != null && ap.enabled) {
      final peeked = ap.peekNextTrack();
      if (peeked == null || peeked.id == currentTrack.id) return;
      nextTrack = peeked;
    } else {
      final activeQueue = queue;
      if (activeQueue.length <= 1) return;

      int idx = -1;
      if (_sharedQueue.isNotEmpty &&
          _sharedQueueIndex >= 0 &&
          _sharedQueueIndex < activeQueue.length &&
          activeQueue[_sharedQueueIndex].id == currentTrack.id) {
        idx = _sharedQueueIndex;
      }
      if (idx < 0) {
        idx = PlaybackPersistenceService.findTrackIndex(
          activeQueue,
          currentTrack,
        );
      }
      if (idx < 0) return;

      final nextIdx = _findNextPlayableQueueIndex(activeQueue, idx, 1);
      if (nextIdx < 0 || activeQueue[nextIdx].id == currentTrack.id) return;
      nextTrack = activeQueue[nextIdx];
    }
    if (nextTrack.preference == -1) return;
    final withinEndWindow = StreamingPlaybackCoordinator.shouldTriggerPreDecode(
      position,
      currentTrack.duration,
    );

    if (_useResolverPipeline) {
      if (!withinEndWindow) return;
      if (_isExternalTrack(nextTrack)) {
        _prepareExternalHandoffForNext(nextTrack, expectedEpoch: _epoch);
        return;
      }
      _prepareNativeStandbyForNext(nextTrack, expectedEpoch: _epoch);
      return;
    }

    if (!StreamingPlaybackCoordinator.isStreamingTrack(nextTrack)) return;
    final nextProvider = streamingManager.resolveProviderForTrack(nextTrack);
    if (nextProvider != null &&
        streamingManager.isPlaybackAuthBlocked(nextProvider.kind)) {
      return;
    }

    if (_isYouTubeMusicTrack(nextTrack)) {
      final stablyPlaying =
          position >= StreamingPlaybackCoordinator._ytmStablePlayPreloadPosition;
      if (!withinEndWindow && !stablyPlaying) return;

      final videoId = _tryExtractYtmVideoId(nextTrack);
      if (videoId == null) return;
      if (ytDlpService.getCachedStream(videoId) != null) return;
      if (getCachedStream(nextTrack.id) != null) return;
      if (_inFlightPreResolves.contains(nextTrack.id)) return;

      final transitionKey = '${currentTrack.id}->${nextTrack.id}';
      if (!_preloadedTransitionKeys.add(transitionKey)) return;
      if (_preloadedTransitionKeys.length >
          StreamingPlaybackCoordinator._maxCacheEntries) {
        _preloadedTransitionKeys.remove(_preloadedTransitionKeys.first);
      }

      _inFlightPreResolves.add(nextTrack.id);
      unawaited(_preloadYtmTrackSilently(nextTrack, videoId));
      return;
    }

    if (_isTidalTrack(nextTrack)) return;

    if (!withinEndWindow) return;
    if (getCachedStream(nextTrack.id) != null) return;
    if (_inFlightPreResolves.contains(nextTrack.id)) return;

    _inFlightPreResolves.add(nextTrack.id);
    unawaited(_preResolveTrackSilently(nextTrack));
  }

  Future<void> _preloadYtmTrackSilently(TrackInfo track, String videoId) async {
    try {
      await ytDlpService.preloadVideo(videoId);
    } catch (_) {
    } finally {
      _inFlightPreResolves.remove(track.id);
    }
  }

  Future<void> _preResolveTrackSilently(TrackInfo track) async {
    try {
      final result = await streamingManager
          .resolveStreamForTrack(track, timeout: resolveTimeout)
          .timeout(resolveTimeout);
      if (!_disposed) {
        _storeCache(track, result);
      }
    } catch (_) {
    } finally {
      _inFlightPreResolves.remove(track.id);
    }
  }
}
