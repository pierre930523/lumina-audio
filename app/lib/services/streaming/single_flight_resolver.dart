import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import 'auth_manager.dart';
import 'l1_stream_cache.dart';
import 'stream_resolver.dart';

/// Result of [SingleFlightResolver.refreshAfter403] CAS recovery.
@immutable
sealed class RefreshAfter403Result {
  const RefreshAfter403Result();
}

/// Refreshed URL/manifest has a compatible format and byte length and may
/// seamlessly resume the active stream.
final class RefreshAfter403Updated extends RefreshAfter403Result {
  final StreamSourceSpec spec;
  final bool reusedFromCache;

  const RefreshAfter403Updated({
    required this.spec,
    this.reusedFromCache = false,
  });
}

/// Refreshed URL/manifest changed format, container layout, cipher, or
/// `contentLength`; caller must NOT splice bytes into the active decoder.
final class RefreshAfter403FormatChanged extends RefreshAfter403Result {
  static const String code = 'STREAM_FORMAT_CHANGED';

  final StreamSourceSpec spec;
  final String reason;

  const RefreshAfter403FormatChanged({
    required this.spec,
    required this.reason,
  });
}

/// Re-resolution encountered HTTP 401 and silent refresh failed or is
/// unavailable; provider circuit breaker is now in `AuthRequired` state.
final class RefreshAfter403AuthRequired extends RefreshAfter403Result {
  final String providerId;
  final String message;

  const RefreshAfter403AuthRequired({
    required this.providerId,
    required this.message,
  });
}

/// Re-resolution failed for a non-auth error (network, 403/404, DRM, cancel).
final class RefreshAfter403Failed extends RefreshAfter403Result {
  final String message;
  final int? statusCode;
  final bool isCancelled;

  const RefreshAfter403Failed({
    required this.message,
    this.statusCode,
    this.isCancelled = false,
  });
}

/// Composite Single-Flight deduplication key:
/// `(provider_id, track_id, quality_key, network_epoch)`.
@immutable
class SingleFlightKey {
  final String providerId;
  final String trackId;
  final String qualityKey;
  final int networkEpoch;

  const SingleFlightKey({
    required this.providerId,
    required this.trackId,
    required this.qualityKey,
    required this.networkEpoch,
  });

  factory SingleFlightKey.fromStreamKey(StreamKey key, int networkEpoch) {
    return SingleFlightKey(
      providerId: key.providerId,
      trackId: key.trackId,
      qualityKey: key.qualityKey,
      networkEpoch: networkEpoch,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is SingleFlightKey &&
            other.providerId == providerId &&
            other.trackId == trackId &&
            other.qualityKey == qualityKey &&
            other.networkEpoch == networkEpoch);
  }

  @override
  int get hashCode =>
      Object.hash(providerId, trackId, qualityKey, networkEpoch);

  @override
  String toString() =>
      'SingleFlightKey($providerId:$trackId@$qualityKey#e$networkEpoch)';
}

class _FlightWaiter {
  final Completer<StreamSourceSpec> completer = Completer<StreamSourceSpec>();
  final CancellationToken? cancelToken;
  VoidCallback? cancelListener;

  _FlightWaiter(this.cancelToken);

  void detachCancelListener() {
    final listener = cancelListener;
    if (listener != null) {
      cancelToken?.removeListener(listener);
      cancelListener = null;
    }
  }
}

class _InFlightResolution {
  final SingleFlightKey flightKey;
  final CancellationToken taskCancel = CancellationToken();
  final List<_FlightWaiter> waiters = <_FlightWaiter>[];
  bool completed = false;

  _InFlightResolution(this.flightKey);
}

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
  ///
  /// - Only evicts the L1 entry if `cached.url == failedUrl` (CAS); if another
  ///   caller already refreshed the URL, reuses the fresh cached spec.
  /// - Strictly separates HTTP 401 (routes to [AuthManager.handleUnauthorized]
  ///   for at most one silent refresh retry before tripping `AuthRequired`)
  ///   from HTTP 403/410 (never trips `AuthRequired`).
  /// - Compares refreshed format/content_length against the active stream
  ///   baseline and returns [RefreshAfter403FormatChanged] (`STREAM_FORMAT_CHANGED`)
  ///   when unsafe to splice bytes.
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
  }) async {
    if (cancelToken?.isCancelled == true) {
      return const RefreshAfter403Failed(
        message: '操作已取消',
        isCancelled: true,
      );
    }

    final auth = _authManager;
    if (auth != null && auth.isPlaybackAuthBlocked(key.providerId)) {
      return RefreshAfter403AuthRequired(
        providerId: key.providerId,
        message: auth.authErrorFor(key.providerId) ?? '授權已失效，請重新登入',
      );
    }

    final resolver = registry.resolverFor(key.providerId);
    if (resolver == null) {
      return RefreshAfter403Failed(message: '未註冊的串流解析器：${key.providerId}');
    }
    final caps = resolver.capabilities;

    // Capture baseline metadata before CAS invalidation.
    final previousSpec = caps.supportsL1UrlCache ? l1Cache.peek(key, caps) : null;
    final baseContentLength =
        expectedContentLength ?? _extractContentLength(previousSpec);
    final baseMime =
        _normalizeMime(expectedMimeType ?? _extractMimeType(previousSpec));
    final baseKind = expectedStreamKind ?? previousSpec?.kind;
    final baseAudioFormat = expectedAudioFormat ?? previousSpec?.audioFormat;
    final baseInitRangeEnd = expectedInitRangeEnd ??
        (previousSpec is DirectRangeSpec ? previousSpec.initRangeEnd : null);
    final baseCipher =
        previousSpec is EncryptedRangeSpec ? previousSpec.cipher : null;

    // CAS conditional invalidation: if another caller already refreshed this
    // key to a different URL, preserve and reuse that fresh spec immediately.
    if (caps.supportsL1UrlCache) {
      final cas = l1Cache.compareAndEvict(key, caps, failedUrl);
      if (!cas.evicted && cas.currentSpec != null) {
        return _evaluateRefreshedSpec(
          freshSpec: cas.currentSpec!,
          reusedFromCache: true,
          allowFormatChange: allowFormatChange,
          baseContentLength: baseContentLength,
          baseMime: baseMime,
          baseKind: baseKind,
          baseAudioFormat: baseAudioFormat,
          baseInitRangeEnd: baseInitRangeEnd,
          baseCipher: baseCipher,
        );
      }
    }

    var retriedAuth = false;
    while (true) {
      try {
        final freshSpec = await resolve(
          key,
          cancelToken: cancelToken,
          bypassCache: false,
          legacyTrack: legacyTrack,
          customInvoker: customInvoker,
        );
        return _evaluateRefreshedSpec(
          freshSpec: freshSpec,
          reusedFromCache: false,
          allowFormatChange: allowFormatChange,
          baseContentLength: baseContentLength,
          baseMime: baseMime,
          baseKind: baseKind,
          baseAudioFormat: baseAudioFormat,
          baseInitRangeEnd: baseInitRangeEnd,
          baseCipher: baseCipher,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled) {
          return RefreshAfter403Failed(
            message: e.message,
            statusCode: e.statusCode,
            isCancelled: true,
          );
        }
        if (AuthManager.isUnauthorizedError(e)) {
          if (auth != null && auth.isGuestPlaybackCapable(key.providerId)) {
            return RefreshAfter403Failed(
              message: e.message,
              statusCode: e.statusCode,
            );
          }
          if (auth != null) {
            final refreshed = await auth.handleUnauthorized(
              key.providerId,
              e.message,
              alreadyRetried: retriedAuth,
            );
            if (refreshed && !retriedAuth) {
              retriedAuth = true;
              continue;
            }
            return RefreshAfter403AuthRequired(
              providerId: key.providerId,
              message: auth.authErrorFor(key.providerId) ?? e.message,
            );
          }
          return RefreshAfter403AuthRequired(
            providerId: key.providerId,
            message: e.message,
          );
        }
        return RefreshAfter403Failed(
          message: e.message,
          statusCode: e.statusCode,
        );
      } catch (e) {
        return RefreshAfter403Failed(message: e.toString());
      }
    }
  }

  static RefreshAfter403Result _evaluateRefreshedSpec({
    required StreamSourceSpec freshSpec,
    required bool reusedFromCache,
    required bool allowFormatChange,
    required int? baseContentLength,
    required String? baseMime,
    required String? baseKind,
    required AudioFormat? baseAudioFormat,
    required int? baseInitRangeEnd,
    required StreamCipher? baseCipher,
  }) {
    if (allowFormatChange) {
      return RefreshAfter403Updated(
        spec: freshSpec,
        reusedFromCache: reusedFromCache,
      );
    }
    final diffReason = _detectFormatDrift(
      freshSpec: freshSpec,
      baseContentLength: baseContentLength,
      baseMime: baseMime,
      baseKind: baseKind,
      baseAudioFormat: baseAudioFormat,
      baseInitRangeEnd: baseInitRangeEnd,
      baseCipher: baseCipher,
    );
    if (diffReason != null) {
      return RefreshAfter403FormatChanged(
        spec: freshSpec,
        reason: diffReason,
      );
    }
    return RefreshAfter403Updated(
      spec: freshSpec,
      reusedFromCache: reusedFromCache,
    );
  }

  static String? _detectFormatDrift({
    required StreamSourceSpec freshSpec,
    required int? baseContentLength,
    required String? baseMime,
    required String? baseKind,
    required AudioFormat? baseAudioFormat,
    required int? baseInitRangeEnd,
    required StreamCipher? baseCipher,
  }) {
    if (baseKind != null && freshSpec.kind != baseKind) {
      return 'stream kind changed: $baseKind -> ${freshSpec.kind}';
    }

    final freshLen = _extractContentLength(freshSpec);
    if (baseContentLength != null &&
        freshLen != null &&
        baseContentLength != freshLen) {
      return 'content_length changed: $baseContentLength -> $freshLen';
    }

    final freshMime = _normalizeMime(_extractMimeType(freshSpec));
    if (baseMime != null && freshMime != null && baseMime != freshMime) {
      return 'mime_type changed: $baseMime -> $freshMime';
    }

    final freshFmt = freshSpec.audioFormat;
    if (baseAudioFormat != null && freshFmt != null) {
      if (baseAudioFormat.codec != freshFmt.codec ||
          baseAudioFormat.sampleRateHz != freshFmt.sampleRateHz ||
          baseAudioFormat.bitDepth != freshFmt.bitDepth ||
          baseAudioFormat.channels != freshFmt.channels) {
        return 'audio_format changed: ${baseAudioFormat.label} -> ${freshFmt.label}';
      }
    }

    if (baseInitRangeEnd != null && freshSpec is DirectRangeSpec) {
      final freshInit = freshSpec.initRangeEnd;
      if (freshInit != null && freshInit != baseInitRangeEnd) {
        return 'init_range_end changed: $baseInitRangeEnd -> $freshInit';
      }
    }

    if (baseCipher != null &&
        freshSpec is EncryptedRangeSpec &&
        freshSpec.cipher != baseCipher) {
      return 'stream cipher changed';
    }

    return null;
  }

  static int? _extractContentLength(StreamSourceSpec? spec) {
    return switch (spec) {
      DirectRangeSpec() => spec.contentLength,
      EncryptedRangeSpec() => spec.contentLength,
      _ => null,
    };
  }

  static String? _extractMimeType(StreamSourceSpec? spec) {
    return switch (spec) {
      DirectRangeSpec() => spec.mimeType,
      SegmentedManifestSpec() => spec.mimeType,
      EncryptedRangeSpec() => spec.mimeType,
      _ => null,
    };
  }

  static String? _normalizeMime(String? raw) {
    final trimmed = raw?.trim().toLowerCase();
    if (trimmed == null || trimmed.isEmpty) return null;
    final semi = trimmed.indexOf(';');
    final base = semi >= 0 ? trimmed.substring(0, semi).trim() : trimmed;
    return base.isEmpty ? null : base;
  }

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
        // Every waiter already cancelled while in flight.
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
