part of '../single_flight_resolver.dart';

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

/// Re-resolution failed for a non-auth error (network, 403/404/451, DRM, cancel).
final class RefreshAfter403Failed extends RefreshAfter403Result {
  final String message;
  final int? statusCode;
  final bool isCancelled;
  final StreamingErrorKind? errorKind;

  const RefreshAfter403Failed({
    required this.message,
    this.statusCode,
    this.isCancelled = false,
    this.errorKind,
  });

  bool get isRegionRestricted =>
      errorKind == StreamingErrorKind.regionRestricted;

  bool get isUnavailable => errorKind == StreamingErrorKind.trackUnavailable;
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
