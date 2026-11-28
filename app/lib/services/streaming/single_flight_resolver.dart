import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import 'auth_manager.dart';
import 'l1_stream_cache.dart';
import 'stream_resolver.dart';

part 'single_flight/refresh_after_403_result.dart';
part 'single_flight/single_flight_refresh_ext.dart';

/// Cross-platform Single-Flight stream resolution coordinator paired with
/// [L1StreamCache].
///
/// Deduplicates concurrent resolutions keyed by
/// `(provider_id, track_id, quality_key, network_epoch)`. The underlying
/// resolution executes in a detached task and broadcasts its result/error to
/// all attached waiters so cancelling a single prefetch waiter NEVER cancels
/// an active playback waiter for the same track.
class SingleFlightResolver {
  final StreamResolverRegistry registry;
  final L1StreamCache l1Cache;
  AuthManager? _authManager;

  final Map<SingleFlightKey, _InFlightResolution> _inFlight =
      <SingleFlightKey, _InFlightResolution>{};

  SingleFlightResolver({
    required this.registry,
    required this.l1Cache,
    AuthManager? authManager,
  }) {
    _authManager = authManager;
  }

  void attachAuthManager(AuthManager authManager) {
    _authManager = authManager;
  }

  int get inFlightCount => _inFlight.length;

  /// Cancels all in-flight detached resolutions belonging to [providerId].
  void cancelProvider(String providerId) {
    final matching = _inFlight.values
        .where((f) => f.flightKey.providerId == providerId && !f.completed)
        .toList(growable: false);
    for (final flight in matching) {
      _abortFlight(
        flight,
        StreamingException(
          '串流解析已因授權失效而取消（$providerId）',
          statusCode: 401,
          isTokenExpired: true,
          isCancelled: true,
        ),
      );
    }
  }

  /// Cancels every active in-flight detached resolution (used on shutdown).
  void cancelAll() {
    final active = _inFlight.values
        .where((f) => !f.completed)
        .toList(growable: false);
    for (final flight in active) {
      _abortFlight(
        flight,
        const StreamingException('操作已取消', isCancelled: true),
      );
    }
  }

  void _abortFlight(_InFlightResolution flight, StreamingException error) {
    if (flight.completed) return;
    flight.completed = true;
    if (identical(_inFlight[flight.flightKey], flight)) {
      _inFlight.remove(flight.flightKey);
    }
    flight.taskCancel.cancel();
    final activeWaiters = List<_FlightWaiter>.from(flight.waiters);
    flight.waiters.clear();
    for (final waiter in activeWaiters) {
      waiter.detachCancelListener();
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
    }
  }

  /// Non-blocking O(1) lookup against the in-memory [L1StreamCache].
  StreamSourceSpec? peekCached(StreamKey key) {
    final caps = registry.capabilitiesFor(key.providerId);
    if (caps == null) return null;
    return l1Cache.peek(key, caps);
  }

  /// Resolves [key] via L1 cache → Single-Flight deduplication → underlying
  /// [StreamResolver].
  ///
  /// When [bypassCache] is `true`, skips and evicts any existing L1 entry for
  /// [key] before starting/joining resolution.
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
    bool bypassCache = false,
    TrackInfo? legacyTrack,
    Future<StreamSourceSpec> Function(CancellationToken taskCancel)?
        customInvoker,
  }) {
    cancelToken?.throwIfCancelled();

    final resolver = registry.resolverFor(key.providerId);
    if (resolver == null) {
      return Future<StreamSourceSpec>.error(
        StreamingException('未註冊的串流解析器：${key.providerId}'),
      );
    }

    final caps = resolver.capabilities;
    if (bypassCache) {
      if (caps.supportsL1UrlCache) {
        l1Cache.evict(key);
      }
    } else if (caps.supportsL1UrlCache) {
      final cached = l1Cache.get(key, caps);
      if (cached != null) {
        return Future<StreamSourceSpec>.value(cached);
      }
    }

    final effectiveEpoch =
        caps.needsNetworkEpochReset ? l1Cache.networkEpoch : 0;
    final flightKey = SingleFlightKey.fromStreamKey(key, effectiveEpoch);
    var flight = _inFlight[flightKey];
    if (flight == null || flight.completed) {
      flight = _InFlightResolution(flightKey);
      _inFlight[flightKey] = flight;
      unawaited(
        _runDetached(
          flight: flight,
          resolver: resolver,
          key: key,
          capabilities: caps,
          legacyTrack: legacyTrack,
          customInvoker: customInvoker,
        ),
      );
    }

    return _attachWaiter(flight, cancelToken);
  }

  /// Background prefetch helper restricted strictly to platforms declaring
  /// `capabilities.supportsL1UrlCache == true` (automatically skips Apple Music
  /// and Local tracks).
  Future<StreamSourceSpec?> prefetch(
    StreamKey key, {
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
  }) async {
    if (cancelToken?.isCancelled == true) return null;
    final resolver = registry.resolverFor(key.providerId);
    if (resolver == null || !resolver.capabilities.supportsL1UrlCache) {
      return null;
    }
    final cached = l1Cache.get(key, resolver.capabilities);
    if (cached != null) return cached;

    return resolve(
      key,
      cancelToken: cancelToken,
      legacyTrack: legacyTrack,
    );
  }

  /// Phase 3 HTTP 403/410 mid-stream URL recovery with CAS conditional L1
  /// invalidation and format/content-length drift detection.
  Future<RefreshAfter403Result> refreshAfter403(
    StreamKey key, {
    required String failedUrl,
    int? expectedContentLength,
    String? expectedMimeType,
    String? expectedStreamKind,
    AudioFormat? expectedAudioFormat,
    int? expectedInitRangeEnd,
    bool allowFormatChange = false,
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
    Future<StreamSourceSpec> Function(CancellationToken taskCancel)?
        customInvoker,
  }) =>
      _refreshAfter403Impl(
        key,
        failedUrl: failedUrl,
        expectedContentLength: expectedContentLength,
        expectedMimeType: expectedMimeType,
        expectedStreamKind: expectedStreamKind,
        expectedAudioFormat: expectedAudioFormat,
        expectedInitRangeEnd: expectedInitRangeEnd,
        allowFormatChange: allowFormatChange,
        cancelToken: cancelToken,
        legacyTrack: legacyTrack,
        customInvoker: customInvoker,
      );

  Future<StreamSourceSpec> _attachWaiter(
    _InFlightResolution flight,
    CancellationToken? cancelToken,
  ) {
    final waiter = _FlightWaiter(cancelToken);
    flight.waiters.add(waiter);

    if (cancelToken != null) {
      void onWaiterCancel() {
        if (flight.completed || waiter.completer.isCompleted) return;
        flight.waiters.remove(waiter);
        waiter.detachCancelListener();
        waiter.completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
        // Only abort the detached underlying resolution if ZERO waiters remain.
        if (flight.waiters.isEmpty && !flight.completed) {
          flight.completed = true;
          if (identical(_inFlight[flight.flightKey], flight)) {
            _inFlight.remove(flight.flightKey);
          }
          flight.taskCancel.cancel();
        }
      }

      waiter.cancelListener = onWaiterCancel;
      cancelToken.addListener(onWaiterCancel);
    }

    return waiter.completer.future;
  }

  Future<void> _runDetached({
    required _InFlightResolution flight,
    required StreamResolver resolver,
    required StreamKey key,
    required ProviderCapabilities capabilities,
    TrackInfo? legacyTrack,
    Future<StreamSourceSpec> Function(CancellationToken taskCancel)?
        customInvoker,
  }) async {
    try {
      final StreamSourceSpec spec;
      if (customInvoker != null) {
        spec = await customInvoker(flight.taskCancel);
      } else if (resolver is LegacyStreamingProviderResolver &&
          legacyTrack != null) {
        spec = await resolver.resolveWithTrack(
          key,
          legacyTrack,
          cancelToken: flight.taskCancel,
        );
      } else {
        spec = await resolver.resolve(key, cancelToken: flight.taskCancel);
      }

      if (flight.completed) {
        return;
      }

      if (capabilities.supportsL1UrlCache) {
        l1Cache.put(spec, capabilities);
      }

      flight.completed = true;
      if (identical(_inFlight[flight.flightKey], flight)) {
        _inFlight.remove(flight.flightKey);
      }

      final activeWaiters = List<_FlightWaiter>.from(flight.waiters);
      flight.waiters.clear();
      for (final waiter in activeWaiters) {
        waiter.detachCancelListener();
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(spec);
        }
      }
    } catch (err, st) {
      if (flight.completed) {
        return;
      }
      flight.completed = true;
      if (identical(_inFlight[flight.flightKey], flight)) {
        _inFlight.remove(flight.flightKey);
      }

      final activeWaiters = List<_FlightWaiter>.from(flight.waiters);
      flight.waiters.clear();
      for (final waiter in activeWaiters) {
        waiter.detachCancelListener();
        if (!waiter.completer.isCompleted) {
          waiter.completer.completeError(err, st);
        }
      }
    }
  }
}
