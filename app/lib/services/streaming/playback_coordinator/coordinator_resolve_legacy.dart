part of '../streaming_playback_coordinator.dart';

extension _CoordinatorResolveLegacyExt on StreamingPlaybackCoordinator {
  Future<void> _executeResolveAndPlayLegacy(
    TrackInfo track,
    int requestId,
    CancellationToken cancel,
  ) async {
    bool isStale() =>
        _disposed || requestId != _epoch || cancel.isCancelled;

    if (isStale()) return;

    _backendCancelSentForBurst = false;
    _finalizeDeferredAutoplaySkip(track);

    if (_isLocalTrack(track)) {
      await audioService.play(track: track);
      return;
    }

    final resolveGen = ++_resolvingGeneration;
    _resolvingRequestId = requestId;
    try {
      final cached = getCachedStream(track.id);
      final ResolvedStreamResult result;
      if (cached != null) {
        result = cached;
      } else {
        result = await _resolveWithCancellationAndTimeout(
          track,
          requestId,
          cancel,
        );
        if (!isStale()) {
          _storeCache(track, result);
        }
      }

      if (isStale()) return;

      if (result.isPreviewOnly || result.drmNotice != null) {
        onNotice?.call(track, result);
      }

      final resolvedTrack = track.copyWith(format: result.format);
      if (_isYouTubeMusicTrack(track)) {
        final isProxy = _isFfmpegProxyUrl(result.url);
        final videoId = _resolveYtmVideoIdForTrack(track, result: result);
        final engineLabel = _formatEngineLabel(result, isFfmpegProxy: isProxy);
        _activeYtmAttempt = _YtmPlaybackAttempt(
          requestId: requestId,
          track: resolvedTrack,
          videoId: videoId,
          cancel: cancel,
          stage: isProxy
              ? _YtmPlaybackStage.ffmpegFallback
              : _YtmPlaybackStage.directInitial,
          activeUrl: result.url,
          activeHeaders: result.headers,
          hintExtension: result.hintExtension,
          format: result.format,
        );
        _activeTidalDashAttempt = null;
        _logRoute('[YTM Play] videoId=$videoId -> Engine: $engineLabel');
      } else {
        _activeYtmAttempt = null;
        _activeTidalDashAttempt =
            (_isTidalTrack(track) && _isFfmpegProxyUrl(result.url))
                ? _TidalDashPlaybackAttempt(
                    requestId: requestId,
                    track: resolvedTrack,
                    cancel: cancel,
                    remainingTiers:
                        _remainingTidalTiersForRoute(result.engineRoute),
                  )
                : null;
      }

      await audioService.playStreamUrlAsync(
        track: resolvedTrack,
        streamUrl: result.url,
        headers: result.headers,
        hintExtension: result.hintExtension,
        requestId: requestId,
      );
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      _cache.remove(track.id);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, e.isDrmRestricted);
    } on TimeoutException {
      if (isStale()) return;
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      ytDlpService.cancelPlaybackProcesses();
      _cache.remove(track.id);
      const msg = '串流解析逾時，請稍後再試';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } catch (e) {
      if (isStale()) return;
      _activeYtmAttempt = null;
      _activeTidalDashAttempt = null;
      _cache.remove(track.id);
      final msg = '串流播放失敗：$e';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } finally {
      if (_resolvingGeneration == resolveGen &&
          _resolvingRequestId == requestId) {
        _resolvingRequestId = null;
      }
    }
  }

  Future<T> _awaitWithCancellationAndTimeout<T>(
    Future<T> Function() invoke,
    CancellationToken cancel,
  ) {
    cancel.throwIfCancelled();

    final completer = Completer<T>();

    void onCancel() {
      ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancel.addListener(onCancel);

    Future<T>.sync(invoke).then(
      (res) {
        if (!completer.isCompleted) {
          completer.complete(res);
        }
      },
      onError: (Object err, StackTrace st) {
        if (!completer.isCompleted) {
          completer.completeError(err, st);
        }
      },
    );

    return completer.future.timeout(resolveTimeout).whenComplete(() {
      cancel.removeListener(onCancel);
    });
  }

  Future<ResolvedStreamResult> _resolveWithCancellationAndTimeout(
    TrackInfo track,
    int requestId,
    CancellationToken cancel, {
    bool bypassCache = false,
  }) {
    return _awaitWithCancellationAndTimeout<ResolvedStreamResult>(
      () => streamingManager.resolveStreamForTrack(
        track,
        cancel: cancel,
        timeout: resolveTimeout,
        playRequestId: requestId,
        bypassCache: bypassCache,
      ),
      cancel,
    );
  }
}
