import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/streaming_models.dart';
import 'l1_stream_cache.dart';
import 'single_flight_resolver.dart';
import 'streaming_provider.dart';

typedef ProviderLookup = StreamingProvider? Function(String providerId);
typedef ProviderAuthRequiredCallback = void Function(
  String providerId,
  String reason,
);

/// Coordinates per-provider Single-Flight silent token/session refresh and the
/// provider-level `AuthRequired` circuit breaker for strict HTTP 401 handling.
///
/// Strictly separated from HTTP 403/410 CDN expiry: only genuine HTTP 401 /
/// `isTokenExpired` errors ever route through [handleUnauthorized] or trip
/// [tripAuthRequired].
class AuthManager {
  final ProviderLookup providerLookup;
  final L1StreamCache l1Cache;
  final SingleFlightResolver singleFlightResolver;
  final VoidCallback? onStateChanged;

  final Map<String, Future<bool>> _inFlightRefresh = <String, Future<bool>>{};
  final Map<String, String> _authRequiredReasons = <String, String>{};
  final List<ProviderAuthRequiredCallback> _authRequiredListeners =
      <ProviderAuthRequiredCallback>[];

  AuthManager({
    required this.providerLookup,
    required this.l1Cache,
    required this.singleFlightResolver,
    this.onStateChanged,
  });

  /// Returns `true` strictly for authentication/session expiry failures (HTTP
  /// 401 or `isTokenExpired == true`). HTTP 403 and 410 ALWAYS return `false`.
  static bool isUnauthorizedError(Object error) {
    if (error is! StreamingException) return false;
    if (error.isCancelled) return false;
    return error.statusCode == 401 || error.isTokenExpired;
  }

  /// Registers a listener notified whenever any provider trips `AuthRequired`
  /// (e.g. coordinator cancelling pending prefetches or FFI cancelling active
  /// downloads for that provider).
  void addAuthRequiredListener(ProviderAuthRequiredCallback listener) {
    if (!_authRequiredListeners.contains(listener)) {
      _authRequiredListeners.add(listener);
    }
  }

  void removeAuthRequiredListener(ProviderAuthRequiredCallback listener) {
    _authRequiredListeners.remove(listener);
  }

  /// Returns `true` when [providerId] natively supports Guest (unauthenticated)
  /// stream playback (e.g. YouTube Music / YouTube Podcasts).
  bool isGuestPlaybackCapable(String providerId) =>
      providerLookup(providerId)?.supportsGuestMode == true;

  bool _isGuestUnauthenticated(StreamingProvider? provider) =>
      provider != null &&
      provider.supportsGuestMode &&
      (provider.authState != StreamingAuthState.connected ||
          provider.accountInfo == null);

  /// Returns `true` when stream playback, prefetch, L1/L2 caching, and 403
  /// refresh are blocked by `AuthRequired` for [providerId].
  ///
  /// Providers supporting Guest playback (`youtube_music`, YouTube Podcasts)
  /// are NEVER blocked from stream playback/prefetch/cache by account auth.
  bool isPlaybackAuthBlocked(String providerId) {
    if (isGuestPlaybackCapable(providerId)) return false;
    return isAuthRequired(providerId);
  }

  bool isAuthRequired(String providerId) {
    final provider = providerLookup(providerId);
    if (_isGuestUnauthenticated(provider)) return false;
    if (_authRequiredReasons.containsKey(providerId)) return true;
    return provider?.authState == StreamingAuthState.authRequired;
  }

  String? authErrorFor(String providerId) {
    final provider = providerLookup(providerId);
    if (_isGuestUnauthenticated(provider)) return null;
    final recorded = _authRequiredReasons[providerId];
    if (recorded != null && recorded.isNotEmpty) return recorded;
    if (provider?.authState == StreamingAuthState.authRequired) {
      return provider?.lastError;
    }
    return null;
  }

  bool isRefreshInFlight(String providerId) =>
      _inFlightRefresh.containsKey(providerId);

  /// Executes at most one concurrent silent refresh per [providerId].
  ///
  /// Concurrent 401 callers join the exact same in-flight `Future<bool>` so
  /// OAuth refresh tokens (e.g. Tidal / YTM OAuth) or Deezer ARL tokens are
  /// never stampeded.
  Future<bool> refreshTokenSingleFlight(String providerId) {
    final provider = providerLookup(providerId);
    if (provider is! AuthAwareStreamingProvider ||
        !provider.supportsSilentRefresh) {
      return Future<bool>.value(false);
    }

    final existing = _inFlightRefresh[providerId];
    if (existing != null) return existing;

    final future = _doSingleFlightRefresh(providerId, provider);
    _inFlightRefresh[providerId] = future;
    return future.whenComplete(() {
      if (identical(_inFlightRefresh[providerId], future)) {
        _inFlightRefresh.remove(providerId);
      }
    });
  }

  Future<bool> _doSingleFlightRefresh(
    String providerId,
    AuthAwareStreamingProvider provider,
  ) async {
    try {
      await provider.forceRefreshSession();
      _authRequiredReasons.remove(providerId);
      provider.clearAuthRequired();
      onStateChanged?.call();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Handles a genuine HTTP 401 / token-expired error for [providerId].
  ///
  /// - If [alreadyRetried] is `false` and the provider supports silent refresh,
  ///   attempts [refreshTokenSingleFlight]. Returns `true` when refreshed so
  ///   the caller may retry its request exactly once.
  /// - Otherwise trips [tripAuthRequired] and returns `false` so callers stop
  ///   retrying immediately.
  Future<bool> handleUnauthorized(
    String providerId,
    String reason, {
    bool alreadyRetried = false,
  }) async {
    final provider = providerLookup(providerId);
    if (_isGuestUnauthenticated(provider)) {
      // Guest/unauthenticated state is completely valid for YouTube Music &
      // YouTube Podcasts; NEVER classify it as AuthRequired or trip breaker.
      return false;
    }
    if (!alreadyRetried) {
      if (provider is AuthAwareStreamingProvider &&
          provider.supportsSilentRefresh) {
        final refreshed = await refreshTokenSingleFlight(providerId);
        if (refreshed) return true;
      }
    }
    tripAuthRequired(providerId, reason);
    return false;
  }

  /// Opens the provider-level circuit breaker: transitions the provider into
  /// [StreamingAuthState.authRequired], cancels all in-flight resolves for
  /// [providerId], evicts its L1 cache entries, and notifies subscribers/UI.
  ///
  /// For Guest-capable providers (YouTube Music / Podcasts):
  /// - Unauthenticated/Guest state is NEVER classified as `AuthRequired`.
  /// - Even when a logged-in account's library sync hits 401, playback,
  ///   prefetch, L1/L2 cache, and active Rust streams are NEVER cancelled or
  ///   blocked (account sync is decoupled from stream playback).
  void tripAuthRequired(String providerId, String reason) {
    final provider = providerLookup(providerId);
    if (provider != null && provider.supportsGuestMode) {
      if (_isGuestUnauthenticated(provider)) {
        return;
      }
      final normalized = reason.trim().isNotEmpty
          ? reason.trim()
          : '${provider.meta.name} 帳號同步授權已失效，請重新登入以同步歌單';
      final wasAlreadyRecorded = _authRequiredReasons[providerId] == normalized;
      _authRequiredReasons[providerId] = normalized;
      if (!wasAlreadyRecorded) {
        onStateChanged?.call();
      }
      return;
    }

    final normalized = reason.trim().isNotEmpty
        ? reason.trim()
        : '${provider?.meta.name ?? providerId} 授權已失效，請重新登入';

    final wasAlreadyTripped =
        _authRequiredReasons[providerId] == normalized &&
        (provider == null ||
            provider.authState == StreamingAuthState.authRequired);

    _authRequiredReasons[providerId] = normalized;
    if (provider is AuthAwareStreamingProvider) {
      provider.markAuthRequired(normalized);
    }

    singleFlightResolver.cancelProvider(providerId);
    l1Cache.clearProvider(providerId);

    if (!wasAlreadyTripped) {
      final snapshot = List<ProviderAuthRequiredCallback>.of(
        _authRequiredListeners,
      );
      for (final listener in snapshot) {
        try {
          listener(providerId, normalized);
        } catch (_) {}
      }
      onStateChanged?.call();
    }
  }

  /// Resets the circuit breaker after successful re-login or logout.
  void clearAuthRequired(String providerId) {
    final removed = _authRequiredReasons.remove(providerId) != null;
    final provider = providerLookup(providerId);
    final wasAuthRequired =
        provider?.authState == StreamingAuthState.authRequired;
    if (provider is AuthAwareStreamingProvider) {
      provider.clearAuthRequired();
    }
    if (removed || wasAuthRequired) {
      onStateChanged?.call();
    }
  }
}
