part of '../streaming_playback_coordinator.dart';

extension _CoordinatorLegacyRecoveryExt on StreamingPlaybackCoordinator {
  void _clearAllYtmCaches(TrackInfo track, String videoId) {
    _cache.remove(track.id);
    streamingManager.clearStreamCache(track);
    ytDlpService.clearCache(videoId);
    if (track.id != videoId) {
      ytDlpService.clearCache(track.id);
    }
  }

  bool _canAttempt403Recovery(
    _YtmPlaybackAttempt attempt,
    TrackInfo errTrack,
    String errMessage,
  ) {
    if (_disposed || attempt.recovering || attempt.cancel.isCancelled) {
      return false;
    }
    if (attempt.requestId != _epoch) return false;
    if (attempt.track.id != errTrack.id) return false;
    if (attempt.stage == _YtmPlaybackStage.ffmpegFallback) return false;
    if (_isFfmpegProxyUrl(attempt.activeUrl)) return false;
    final uri = Uri.tryParse(attempt.activeUrl.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    return _isHttp403Error(errMessage);
  }

  Future<void> _recoverFromYtm403(_YtmPlaybackAttempt attempt) {
    final future = _runYtm403Recovery(attempt);
    _recoveryFuture = future;
    future.whenComplete(() {
      if (identical(_recoveryFuture, future)) {
        _recoveryFuture = null;
      }
    });
    return future;
  }

  Future<void> _runYtm403Recovery(_YtmPlaybackAttempt attempt) async {
    bool isStale() =>
        _disposed ||
        attempt.requestId != _epoch ||
        attempt.cancel.isCancelled ||
        !identical(_activeYtmAttempt, attempt);

    if (isStale()) return;

    final track = attempt.track;
    final videoId = attempt.videoId;
    final requestId = attempt.requestId;

    try {
      if (attempt.stage == _YtmPlaybackStage.directInitial) {
        _clearAllYtmCaches(track, videoId);
        _logRoute(
          '[YTM Play] videoId=$videoId -> HTTP 403 detected; clearing cache and retrying fresh yt-dlp',
        );
        audioService.beginOptimisticTrackLoad(track);

        final freshResult = await _resolveWithCancellationAndTimeout(
          track,
          requestId,
          attempt.cancel,
          bypassCache: true,
        );
        if (isStale()) {
          ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
          return;
        }

        _storeCache(track, freshResult);
        final resolvedTrack = track.copyWith(format: freshResult.format);
        final isProxy = _isFfmpegProxyUrl(freshResult.url);
        final engineLabel = _formatEngineLabel(
          freshResult,
          isFfmpegProxy: isProxy,
        );

        attempt.stage = isProxy
            ? _YtmPlaybackStage.ffmpegFallback
            : _YtmPlaybackStage.directFreshRetry;
        attempt.activeUrl = freshResult.url;
        attempt.activeHeaders = freshResult.headers;
        attempt.hintExtension = freshResult.hintExtension;
        attempt.format = freshResult.format;
        attempt.recovering = false;

        _logRoute('[YTM Play] videoId=$videoId -> Engine: $engineLabel');
        await audioService.playStreamUrlAsync(
          track: resolvedTrack,
          streamUrl: freshResult.url,
          headers: freshResult.headers,
          hintExtension: freshResult.hintExtension,
          requestId: requestId,
        );
        return;
      }

      if (attempt.stage == _YtmPlaybackStage.directFreshRetry) {
        _clearAllYtmCaches(track, videoId);
        _logRoute(
          '[YTM Play] videoId=$videoId -> HTTP 403 persisted after fresh retry; switching to bundled ffmpeg fallback',
        );
        audioService.beginOptimisticTrackLoad(track);

        final wavUrl = await ytDlpService.openTranscodedWavUrl(
          sourceUrl: attempt.activeUrl,
          headers: attempt.activeHeaders,
          playRequestId: requestId,
        );
        if (isStale()) {
          ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
          return;
        }

        attempt.stage = _YtmPlaybackStage.ffmpegFallback;
        attempt.activeUrl = wavUrl;
        attempt.activeHeaders = const <String, String>{};
        attempt.hintExtension = 'wav';
        attempt.recovering = false;

        _logRoute(
          '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp + ffmpeg fallback',
        );
        await audioService.playStreamUrlAsync(
          track: track.copyWith(format: attempt.format),
          streamUrl: wavUrl,
          headers: const <String, String>{},
          hintExtension: 'wav',
          requestId: requestId,
        );
      }
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      _activeYtmAttempt = null;
      _clearAllYtmCaches(track, videoId);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, e.isDrmRestricted);
    } on YtDlpException catch (e) {
      if (e.isCancelled || isStale()) return;
      _activeYtmAttempt = null;
      _clearAllYtmCaches(track, videoId);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, false);
    } on TimeoutException {
      if (isStale()) return;
      _activeYtmAttempt = null;
      ytDlpService.cancelPlaybackProcesses(exceptRequestId: _epoch);
      _clearAllYtmCaches(track, videoId);
      const msg = '串流解析逾時，請稍後再試';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } catch (e) {
      if (isStale()) return;
      _activeYtmAttempt = null;
      ytDlpService.stopFfmpegProxy();
      _clearAllYtmCaches(track, videoId);
      final msg = '串流播放失敗：$e';
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    }
  }

  Future<void> _recoverTidalDashPlayback(
    _TidalDashPlaybackAttempt attempt, {
    required String runtimeError,
  }) {
    final future = _runTidalDashRecovery(attempt, runtimeError: runtimeError);
    _recoveryFuture = future;
    future.whenComplete(() {
      if (identical(_recoveryFuture, future)) {
        _recoveryFuture = null;
      }
    });
    return future;
  }

  Future<void> _runTidalDashRecovery(
    _TidalDashPlaybackAttempt attempt, {
    required String runtimeError,
  }) async {
    bool isStale() =>
        _disposed ||
        attempt.requestId != _epoch ||
        attempt.cancel.isCancelled ||
        !identical(_activeTidalDashAttempt, attempt);

    if (isStale() || attempt.remainingTiers.isEmpty) return;

    final track = attempt.track;
    final requestId = attempt.requestId;
    attempt.initialError ??= runtimeError;
    final nextTier = attempt.remainingTiers.removeAt(0);

    String formatFailure(String detail) {
      final init = attempt.initialError?.trim();
      if (init == null || init.isEmpty || detail.contains(init)) return detail;
      return '$detail（原始錯誤：$init）';
    }

    void notifyFailure(String msg, {bool isDrmRestricted = false}) {
      _activeTidalDashAttempt = null;
      _cache.remove(track.id);
      _notifiedErrorForEpoch = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, isDrmRestricted);
    }

    final resolveGen = ++_resolvingGeneration;
    _resolvingRequestId = requestId;
    try {
      final provider = streamingManager.resolveProviderForTrack(track);
      if (provider is! TidalProvider) {
        throw const StreamingException('找不到 Tidal 串流提供者');
      }

      _logRoute(
        '[Tidal Play] track=${track.id} -> runtime error ($runtimeError); auto-downgrading to $nextTier (DASH enabled)',
      );
      audioService.beginOptimisticTrackLoad(track);

      final fallback = await _awaitWithCancellationAndTimeout<ResolvedStreamResult>(
        () => provider.resolveStream(
          track,
          cancel: attempt.cancel,
          timeout: resolveTimeout,
          playRequestId: requestId,
          maxQuality: nextTier,
        ),
        attempt.cancel,
      );
      if (isStale()) return;

      _storeCache(track, fallback);
      final resolvedTrack = track.copyWith(format: fallback.format);
      if (_isFfmpegProxyUrl(fallback.url)) {
        final route = (fallback.engineRoute ?? '').toUpperCase();
        if (route.isNotEmpty &&
            !route.contains('LOSSLESS') &&
            !route.contains('HI_RES_LOSSLESS')) {
          attempt.remainingTiers.clear();
        } else if (!route.contains('HI_RES_LOSSLESS')) {
          attempt.remainingTiers.remove('LOSSLESS');
        }
        attempt.recovering = false;
        _activeTidalDashAttempt = attempt;
      } else {
        _activeTidalDashAttempt = null;
      }

      await audioService.playStreamUrlAsync(
        track: resolvedTrack,
        streamUrl: fallback.url,
        headers: fallback.headers,
        hintExtension: fallback.hintExtension,
        requestId: requestId,
      );
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      notifyFailure(
        formatFailure(e.message),
        isDrmRestricted: e.isDrmRestricted,
      );
    } on TimeoutException {
      if (isStale()) return;
      notifyFailure(formatFailure('串流解析逾時，請稍後再試'));
    } catch (e) {
      if (isStale()) return;
      notifyFailure(formatFailure('串流播放失敗：$e'));
    } finally {
      if (_resolvingGeneration == resolveGen &&
          _resolvingRequestId == requestId) {
        _resolvingRequestId = null;
      }
    }
  }
}
