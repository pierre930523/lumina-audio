import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../audio_service.dart';
import '../playback_persistence_service.dart';
import 'streaming_manager.dart';

class _CachedResolvedStream {
  final ResolvedStreamResult result;
  final DateTime expiresAt;

  const _CachedResolvedStream({
    required this.result,
    required this.expiresAt,
  });
}

/// Coordinates optimistic UI updates, cancellation, debounced rapid skipping,
/// TTL-bounded URL caching, and end-of-track silent pre-resolution across
/// streaming services and the FFI/AudioService playback layer.
class StreamingPlaybackCoordinator {
  static const int _maxCacheEntries = 64;
  static const Duration _preResolveThreshold = Duration(seconds: 15);

  final AudioService audioService;
  final StreamingManager streamingManager;
  final Duration resolveTimeout;
  final Duration debounceDelay;
  final DateTime Function() _clock;
  final void Function(TrackInfo track, ResolvedStreamResult result)? onNotice;
  final void Function(TrackInfo track, String message, bool isDrmRestricted)?
      onError;

  final Map<String, _CachedResolvedStream> _cache = {};
  final Set<String> _inFlightPreResolves = {};

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlaybackState>? _stateSub;

  int _playRequestId = 0;
  int _notifiedErrorForRequestId = -1;
  CancellationToken? _activeCancelToken;
  Timer? _debounceTimer;
  Completer<void>? _pendingDebounceCompleter;
  Future<void>? _activeTaskFuture;
  bool _disposed = false;

  StreamingPlaybackCoordinator({
    required this.audioService,
    required this.streamingManager,
    this.resolveTimeout = const Duration(seconds: 9),
    this.debounceDelay = const Duration(milliseconds: 120),
    DateTime Function()? clock,
    this.onNotice,
    this.onError,
  }) : _clock = clock ?? DateTime.now {
    audioService.setStreamingTrackHandler(handleAudioServiceTrack);
    _positionSub = audioService.positionStream.listen(_handlePositionTick);
    _stateSub = audioService.stateStream.listen(_handleStateUpdate);
  }

  int get activeRequestId => _playRequestId;

  @visibleForTesting
  Future<void>? get activeTaskFuture => _activeTaskFuture;

  @visibleForTesting
  int get cacheLength => _cache.length;

  static bool isStreamingTrack(TrackInfo track) =>
      AudioService.isStreamingTrackId(track.id);

  @visibleForTesting
  static Duration computeCacheTtl(
    TrackInfo track,
    String resolvedUrl,
    DateTime now,
  ) {
    final id = track.id;
    if (id.startsWith('ytm:')) {
      final uri = Uri.tryParse(resolvedUrl);
      final expireRaw = uri?.queryParameters['expire'];
      final expireSec = expireRaw != null ? int.tryParse(expireRaw) : null;
      if (expireSec != null && expireSec > 0) {
        final expireAt =
            DateTime.fromMillisecondsSinceEpoch(expireSec * 1000);
        final usableFor =
            expireAt.difference(now) - const Duration(seconds: 60);
        if (usableFor > const Duration(seconds: 5)) {
          return usableFor;
        }
        return Duration.zero;
      }
      return const Duration(minutes: 15);
    }
    if (id.startsWith('apple:')) {
      return const Duration(minutes: 30);
    }
    return const Duration(minutes: 10);
  }

  ResolvedStreamResult? getCachedStream(String trackId) {
    final entry = _cache[trackId];
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) {
      _cache.remove(trackId);
      return null;
    }
    return entry.result;
  }

  void _storeCache(TrackInfo track, ResolvedStreamResult result) {
    final now = _clock();
    final ttl = computeCacheTtl(track, result.url, now);
    if (ttl <= Duration.zero) return;

    if (!_cache.containsKey(track.id) && _cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[track.id] = _CachedResolvedStream(
      result: result,
      expiresAt: now.add(ttl),
    );
  }

  Future<void> handleAudioServiceTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
  }) {
    return playTrack(
      track,
      queueContext: queueContext,
      debounce: debounce,
    );
  }

  Future<void> playTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
    bool debounce = false,
  }) {
    if (_disposed) return Future.value();

    final requestId = ++_playRequestId;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounceCompleter != null &&
        !_pendingDebounceCompleter!.isCompleted) {
      _pendingDebounceCompleter!.complete();
    }
    _pendingDebounceCompleter = null;

    _activeCancelToken?.cancel();
    final cancel = CancellationToken();
    _activeCancelToken = cancel;

    unawaited(audioService.cancelPendingPlayback());
    audioService.beginOptimisticTrackLoad(track, queue: queueContext);

    if (debounce && debounceDelay > Duration.zero) {
      final completer = Completer<void>();
      _pendingDebounceCompleter = completer;
      _debounceTimer = Timer(debounceDelay, () {
        _debounceTimer = null;
        if (identical(_pendingDebounceCompleter, completer)) {
          _pendingDebounceCompleter = null;
        }
        if (_disposed || requestId != _playRequestId || cancel.isCancelled) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        final fut = _executeResolveAndPlay(track, requestId, cancel);
        _activeTaskFuture = fut;
        fut.whenComplete(() {
          if (!completer.isCompleted) completer.complete();
        });
      });
      _activeTaskFuture = completer.future;
      return completer.future;
    }

    final fut = _executeResolveAndPlay(track, requestId, cancel);
    _activeTaskFuture = fut;
    return fut;
  }

  Future<void> next() => audioService.next();

  Future<void> previous() => audioService.previous();

  Future<void> _executeResolveAndPlay(
    TrackInfo track,
    int requestId,
    CancellationToken cancel,
  ) async {
    bool isStale() =>
        _disposed || requestId != _playRequestId || cancel.isCancelled;

    if (isStale()) return;

    try {
      final cached = getCachedStream(track.id);
      final ResolvedStreamResult result;
      if (cached != null) {
        result = cached;
      } else {
        result = await _resolveWithCancellationAndTimeout(track, cancel);
        if (!isStale()) {
          _storeCache(track, result);
        }
      }

      if (isStale()) return;

      if (result.isPreviewOnly || result.drmNotice != null) {
        onNotice?.call(track, result);
      }

      await audioService.playStreamUrlAsync(
        track: track.copyWith(format: result.format),
        streamUrl: result.url,
        headers: result.headers,
        hintExtension: result.hintExtension,
        requestId: requestId,
      );
    } on StreamingException catch (e) {
      if (e.isCancelled || isStale()) return;
      _cache.remove(track.id);
      _notifiedErrorForRequestId = requestId;
      audioService.failOptimisticTrackLoad(track, e.message);
      onError?.call(track, e.message, e.isDrmRestricted);
    } on TimeoutException {
      if (isStale()) return;
      _cache.remove(track.id);
      const msg = '串流解析逾時，請稍後再試';
      _notifiedErrorForRequestId = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    } catch (e) {
      if (isStale()) return;
      _cache.remove(track.id);
      final msg = '串流播放失敗：$e';
      _notifiedErrorForRequestId = requestId;
      audioService.failOptimisticTrackLoad(track, msg);
      onError?.call(track, msg, false);
    }
  }

  Future<ResolvedStreamResult> _resolveWithCancellationAndTimeout(
    TrackInfo track,
    CancellationToken cancel,
  ) {
    cancel.throwIfCancelled();

    final completer = Completer<ResolvedStreamResult>();

    void onCancel() {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancel.addListener(onCancel);

    final rawFuture = streamingManager.resolveStreamForTrack(
      track,
      cancel: cancel,
      timeout: resolveTimeout,
    );
    rawFuture.then(
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

  void _handleStateUpdate(PlaybackState state) {
    if (_disposed) return;
    if (state.status == PlaybackStatus.error) {
      final errTrack = state.track;
      if (errTrack != null && isStreamingTrack(errTrack)) {
        _cache.remove(errTrack.id);
        if (_playRequestId > 0 &&
            _notifiedErrorForRequestId != _playRequestId) {
          _notifiedErrorForRequestId = _playRequestId;
          final rawErr = state.lastError?.trim();
          final svcErr = audioService.lastError?.trim();
          final msg = (rawErr != null && rawErr.isNotEmpty)
              ? rawErr
              : ((svcErr != null && svcErr.isNotEmpty)
                  ? svcErr
                  : '串流播放失敗，請重試');
          onError?.call(errTrack, msg, false);
        }
      }
    }
    _maybePreResolveNext(state, state.position);
  }

  void _handlePositionTick(Duration position) {
    _maybePreResolveNext(audioService.currentState, position);
  }

  void _maybePreResolveNext(PlaybackState state, Duration position) {
    if (_disposed) return;
    if (state.status != PlaybackStatus.playing) return;
    final currentTrack = state.track;
    if (currentTrack == null) return;
    final duration = currentTrack.duration;
    if (duration <= Duration.zero || position < Duration.zero) return;

    final remaining = duration - position;
    if (remaining > _preResolveThreshold || remaining < Duration.zero) {
      return;
    }

    final queue = audioService.queue;
    if (queue.length <= 1) return;

    final idx = PlaybackPersistenceService.findTrackIndex(queue, currentTrack);
    if (idx < 0) return;

    final nextTrack = queue[(idx + 1) % queue.length];
    if (!isStreamingTrack(nextTrack)) return;
    if (getCachedStream(nextTrack.id) != null) return;
    if (_inFlightPreResolves.contains(nextTrack.id)) return;

    _inFlightPreResolves.add(nextTrack.id);
    unawaited(_preResolveTrackSilently(nextTrack));
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
      // Pre-resolution failures are silent; foreground playback will retry with UI feedback.
    } finally {
      _inFlightPreResolves.remove(track.id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounceCompleter != null &&
        !_pendingDebounceCompleter!.isCompleted) {
      _pendingDebounceCompleter!.complete();
    }
    _pendingDebounceCompleter = null;
    _activeCancelToken?.cancel();
    _activeCancelToken = null;
    _positionSub?.cancel();
    _positionSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    audioService.setStreamingTrackHandler(null);
    _cache.clear();
    _inFlightPreResolves.clear();
  }
}
