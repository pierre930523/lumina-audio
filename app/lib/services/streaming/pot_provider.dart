import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/streaming_models.dart';
import 'pot_sidecar_manager.dart';

/// Distinguishes Session-level GVS PO Tokens (bound to login session or
/// `visitorData`) from per-track Player PO Tokens (bound to `video_id`).
enum PoTokenScope { gvs, player }

/// Immutable PO Token value with mint and expiry timestamps for <15% proactive
/// background refresh calculation.
@immutable
class PoToken {
  final String token;
  final PoTokenScope scope;
  final String bindingKey;
  final DateTime mintedAt;
  final DateTime expiresAt;

  const PoToken({
    required this.token,
    required this.scope,
    required this.bindingKey,
    required this.mintedAt,
    required this.expiresAt,
  });

  Duration get totalLifetime => expiresAt.difference(mintedAt);

  Duration remainingAt(DateTime now) => expiresAt.difference(now);

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  /// True when the token is still usable (> 0s left) but its remaining
  /// lifetime has fallen strictly below 15% of its original TTL.
  bool needsProactiveRefreshAt(DateTime now) {
    final totalMs = totalLifetime.inMilliseconds;
    if (totalMs <= 0) return false;
    final remMs = remainingAt(now).inMilliseconds;
    return remMs > 0 && remMs < (totalMs * 0.15);
  }
}

/// Abstract PO Token provider consumed by [YtmResidentResolver].
abstract interface class PotProvider {
  /// Returns the Session-level GVS PO Token bound to [sessionBinding]
  /// (login session identity or `visitorData`), or `null` if unavailable.
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  });

  /// Returns a dynamically minted per-track Player PO Token bound to
  /// [videoId], or `null` if unavailable.
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  });

  /// Clears cached Session-level GVS tokens (called on auth/account changes).
  void invalidateSession();

  Future<void> dispose();
}

/// No-op provider returning `null` immediately when PO Token service is disabled.
class NoopPotProvider implements PotProvider {
  const NoopPotProvider();

  @override
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  }) async => null;

  @override
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  }) async => null;

  @override
  void invalidateSession() {}

  @override
  Future<void> dispose() async {}
}

typedef PotHttpRequester = Future<({int statusCode, String body})> Function({
  required Uri uri,
  required Map<String, dynamic> body,
  required Duration timeout,
});

/// Persistent HTTP PO Token provider backed by a local `127.0.0.1` sidecar
/// (e.g. `bgutil-ytdlp-pot-provider` `/get_pot`).
///
/// - **Session GVS Token**: cached per `sessionBinding`; automatically triggers
///   a deduplicated background refresh when remaining lifetime < 15% while
///   returning the still-valid cached token with 0ms wait.
/// - **Per-track Player Token**: dynamically fetched per `video_id`, with
///   in-flight deduplication and graceful `null` fallback on any outage.
class HttpPotProvider implements PotProvider {
  final PotSidecarManager? _sidecarManager;
  final bool _ownsSidecarManager;
  final Uri? _staticEndpointUri;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  final PotHttpRequester? _requester;
  final Duration requestTimeout;
  final Duration defaultGvsTtl;
  final Duration defaultPlayerTtl;
  final DateTime Function() _clock;

  PoToken? _cachedGvsToken;
  Future<PoToken?>? _gvsRefreshFuture;
  String? _gvsRefreshBinding;
  final Map<String, ({Future<PoToken?> future, CancellationToken taskCancel, Set<Object> waiters})>
      _inFlightPlayerTokens =
      <String, ({Future<PoToken?> future, CancellationToken taskCancel, Set<Object> waiters})>{};
  bool _disposed = false;

  HttpPotProvider({
    PotSidecarManager? sidecarManager,
    bool ownsSidecarManager = true,
    Uri? endpointUri,
    HttpClient? httpClient,
    this._requester,
    this.requestTimeout = const Duration(milliseconds: 2500),
    this.defaultGvsTtl = const Duration(hours: 6),
    this.defaultPlayerTtl = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : _sidecarManager = sidecarManager,
       _ownsSidecarManager = sidecarManager != null && ownsSidecarManager,
       _staticEndpointUri = endpointUri,
       _httpClient = httpClient ?? _createClient(),
       _ownsHttpClient = httpClient == null,
       _clock = clock ?? DateTime.now {
    if (endpointUri != null) {
      PotSidecarManager.assertLoopbackUri(endpointUri);
    }
  }

  static HttpClient _createClient() {
    final c = HttpClient();
    c.idleTimeout = const Duration(seconds: 60);
    c.maxConnectionsPerHost = 4;
    c.connectionTimeout = const Duration(seconds: 2);
    return c;
  }

  @visibleForTesting
  PoToken? get cachedGvsToken => _cachedGvsToken;

  @visibleForTesting
  bool get isGvsRefreshInFlight => _gvsRefreshFuture != null;

  @override
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  }) async {
    if (_disposed) return null;
    if (cancelToken?.isCancelled == true) return null;

    final binding = sessionBinding.trim();
    if (binding.isEmpty) return null;

    final now = _clock();
    final cached = _cachedGvsToken;
    if (cached != null &&
        cached.bindingKey == binding &&
        !cached.isExpiredAt(now)) {
      if (cached.needsProactiveRefreshAt(now)) {
        // Return valid token immediately (0ms wait) and refresh in background.
        unawaited(_refreshGvsToken(binding));
      }
      return cached;
    }

    return _awaitWithOptionalCancel(_refreshGvsToken(binding), cancelToken);
  }

  Future<PoToken?> _refreshGvsToken(String binding) {
    final existing = _gvsRefreshFuture;
    if (existing != null && _gvsRefreshBinding == binding) {
      return existing;
    }

    final future = _mintToken(
      scope: PoTokenScope.gvs,
      bindingKey: binding,
      fallbackTtl: defaultGvsTtl,
    ).then((token) {
      if (!_disposed && token != null) {
        _cachedGvsToken = token;
      }
      return token;
    });

    _gvsRefreshBinding = binding;
    _gvsRefreshFuture = future;
    future.whenComplete(() {
      if (identical(_gvsRefreshFuture, future)) {
        _gvsRefreshFuture = null;
        _gvsRefreshBinding = null;
      }
    });
    return future;
  }

  @override
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  }) async {
    if (_disposed) return null;
    if (cancelToken?.isCancelled == true) return null;

    final vid = videoId.trim();
    if (vid.isEmpty) return null;

    var flight = _inFlightPlayerTokens[vid];
    if (flight == null) {
      final taskCancel = CancellationToken();
      final waiters = <Object>{};
      final future = _mintToken(
        scope: PoTokenScope.player,
        bindingKey: vid,
        fallbackTtl: defaultPlayerTtl,
        cancelToken: taskCancel,
      );
      flight = (future: future, taskCancel: taskCancel, waiters: waiters);
      _inFlightPlayerTokens[vid] = flight;
      final capturedFlight = flight;
      future.whenComplete(() {
        if (identical(_inFlightPlayerTokens[vid], capturedFlight)) {
          _inFlightPlayerTokens.remove(vid);
        }
      });
    }

    final waiterToken = Object();
    flight.waiters.add(waiterToken);
    final activeFlight = flight;
    return _awaitWithOptionalCancel(
      activeFlight.future,
      cancelToken,
      onWaiterCancelled: () {
        activeFlight.waiters.remove(waiterToken);
        if (activeFlight.waiters.isEmpty) {
          activeFlight.taskCancel.cancel();
          if (identical(_inFlightPlayerTokens[vid], activeFlight)) {
            _inFlightPlayerTokens.remove(vid);
          }
        }
      },
    ).whenComplete(() {
      activeFlight.waiters.remove(waiterToken);
    });
  }

  Future<PoToken?> _mintToken({
    required PoTokenScope scope,
    required String bindingKey,
    required Duration fallbackTtl,
    CancellationToken? cancelToken,
  }) async {
    if (_disposed || cancelToken?.isCancelled == true) return null;
    final baseUri = await _resolveBaseUri();
    if (baseUri == null || _disposed || cancelToken?.isCancelled == true) {
      return null;
    }
    PotSidecarManager.assertLoopbackUri(baseUri);

    final uri = baseUri.resolve('/get_pot');
    final payload = <String, dynamic>{
      'content_binding': bindingKey,
      'context': scope.name,
      'disable_innertube': false,
    };

    try {
      final resp = _requester != null
          ? await _requester(uri: uri, body: payload, timeout: requestTimeout)
          : await _postLoopbackJson(
              uri: uri,
              body: payload,
              cancelToken: cancelToken,
            );
      if (_disposed || cancelToken?.isCancelled == true) return null;

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;

      final tokenStr =
          (decoded['poToken'] ?? decoded['po_token'] ?? decoded['token'])
              ?.toString()
              .trim() ??
          '';
      if (tokenStr.isEmpty) return null;

      final now = _clock();
      final DateTime expiresAt;
      final rawExpiresAt = decoded['expiresAt'] ?? decoded['expires_at'];
      final rawExpiresIn =
          decoded['expiresInSeconds'] ??
          decoded['expires_in_seconds'] ??
          decoded['expiresIn'] ??
          decoded['expires_in'];

      if (rawExpiresAt is num && rawExpiresAt.toInt() > 0) {
        final ts = rawExpiresAt.toInt();
        expiresAt = DateTime.fromMillisecondsSinceEpoch(
          ts > 1000000000000 ? ts : ts * 1000,
        );
      } else if (rawExpiresAt is String && rawExpiresAt.trim().isNotEmpty) {
        final asInt = int.tryParse(rawExpiresAt.trim());
        if (asInt != null && asInt > 0) {
          expiresAt = DateTime.fromMillisecondsSinceEpoch(
            asInt > 1000000000000 ? asInt : asInt * 1000,
          );
        } else {
          expiresAt = DateTime.tryParse(rawExpiresAt.trim()) ??
              now.add(fallbackTtl);
        }
      } else if (rawExpiresIn is num && rawExpiresIn.toInt() > 0) {
        expiresAt = now.add(Duration(seconds: rawExpiresIn.toInt()));
      } else {
        expiresAt = now.add(fallbackTtl);
      }

      return PoToken(
        token: tokenStr,
        scope: scope,
        bindingKey: bindingKey,
        mintedAt: now,
        expiresAt: expiresAt,
      );
    } catch (_) {
      // Graceful fallback: never block or fail stream resolution if sidecar is down.
      return null;
    }
  }

  Future<Uri?> _resolveBaseUri() async {
    if (_staticEndpointUri != null) return _staticEndpointUri;
    final mgr = _sidecarManager;
    if (mgr == null) return null;
    return mgr.ensureRunning();
  }

  Future<({int statusCode, String body})> _postLoopbackJson({
    required Uri uri,
    required Map<String, dynamic> body,
    CancellationToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const StreamingException('操作已取消', isCancelled: true);
    }
    final encoded = utf8.encode(jsonEncode(body));
    HttpClientRequest? activeReq;
    StreamSubscription<String>? bodySub;
    var aborted = false;
    final completer = Completer<({int statusCode, String body})>();

    void onCancel() {
      aborted = true;
      try {
        activeReq?.abort();
      } catch (_) {}
      unawaited(bodySub?.cancel().catchError((_) {}));
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken?.addListener(onCancel);
    try {
      () async {
        try {
          final req =
              await _httpClient.openUrl('POST', uri).timeout(requestTimeout);
          if (aborted || _disposed) {
            try {
              req.abort();
            } catch (_) {}
            return;
          }
          activeReq = req;
          req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
          req.headers.set(HttpHeaders.acceptHeader, 'application/json');
          req.contentLength = encoded.length;
          req.add(encoded);
          final resp = await req.close().timeout(requestTimeout);
          if (aborted || _disposed) {
            unawaited(resp.drain<void>().catchError((_) {}));
            return;
          }
          final buf = StringBuffer();
          final bodyDone = Completer<String>();
          bodySub = utf8.decoder.bind(resp).listen(
            buf.write,
            onDone: () {
              if (!bodyDone.isCompleted) bodyDone.complete(buf.toString());
            },
            onError: (Object err, StackTrace st) {
              if (!bodyDone.isCompleted) bodyDone.completeError(err, st);
            },
            cancelOnError: true,
          );
          final respBody = await bodyDone.future.timeout(requestTimeout);
          if (!aborted && !_disposed && !completer.isCompleted) {
            completer.complete((statusCode: resp.statusCode, body: respBody));
          }
        } catch (err, st) {
          if (!completer.isCompleted) {
            completer.completeError(err, st);
          }
        }
      }();
      return await completer.future;
    } finally {
      cancelToken?.removeListener(onCancel);
      if (aborted) {
        unawaited(bodySub?.cancel().catchError((_) {}));
      }
    }
  }

  Future<PoToken?> _awaitWithOptionalCancel(
    Future<PoToken?> future,
    CancellationToken? cancelToken, {
    VoidCallback? onWaiterCancelled,
  }) {
    if (cancelToken == null) return future;
    if (cancelToken.isCancelled) {
      onWaiterCancelled?.call();
      return Future<PoToken?>.value(null);
    }

    final completer = Completer<PoToken?>();
    void onCancel() {
      onWaiterCancelled?.call();
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }

    cancelToken.addListener(onCancel);
    future.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    return completer.future.whenComplete(() {
      cancelToken.removeListener(onCancel);
    });
  }

  @override
  void invalidateSession() {
    _cachedGvsToken = null;
    _gvsRefreshFuture = null;
    _gvsRefreshBinding = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    invalidateSession();
    for (final flight in _inFlightPlayerTokens.values) {
      flight.taskCancel.cancel();
    }
    _inFlightPlayerTokens.clear();
    if (_ownsSidecarManager) {
      await _sidecarManager?.dispose();
    }
    if (_ownsHttpClient) {
      try {
        _httpClient.close(force: true);
      } catch (_) {}
    }
  }
}
