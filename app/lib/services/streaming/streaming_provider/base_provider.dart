part of '../streaming_provider.dart';

/// Shared stateful scaffolding for [StreamingProvider] implementations.
abstract class BaseStreamingProvider
    implements StreamingProvider, AuthAwareStreamingProvider {
  static const Map<String, String> defaultImageHttpHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  };

  static String? normalizeCoverUrl(String? raw) =>
      normalizeStreamingCoverUrl(raw);

  static String? upgradeCoverUrl(String? raw, {int targetSize = 1200}) =>
      upgradeStreamingCoverUrl(raw, targetSize: targetSize);

  final SecureCredentialStore credentialStore;
  final StreamingHttpClient http;
  final DateTime Function() clock;

  StreamingAuthState _authState = StreamingAuthState.disconnected;
  StreamingAccountInfo? _accountInfo;
  String? _lastError;
  StreamingCatalog _catalog = StreamingCatalog.empty();

  BaseStreamingProvider({
    required this.credentialStore,
    HttpClient Function()? httpClientFactory,
    Duration requestTimeout = const Duration(seconds: 15),
    DateTime Function()? clock,
  })  : http = StreamingHttpClient(
          clientFactory: httpClientFactory,
          timeout: requestTimeout,
        ),
        clock = clock ?? DateTime.now;

  String get credentialStorageKey => 'streaming:$kind';

  @override
  StreamingProviderMeta get meta => StreamingProviderMeta.byKind(kind)!;

  @override
  StreamingAuthState get authState => _authState;

  @override
  StreamingAccountInfo? get accountInfo => _accountInfo;

  @override
  String? get lastError => _lastError;

  @override
  StreamingCatalog get catalog => _catalog;

  @override
  bool get supportsGuestMode => false;

  @override
  bool get supportsSilentRefresh => false;

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded();

  @override
  void markAuthRequired(String reason) {
    _authState = StreamingAuthState.authRequired;
    _lastError = reason.trim().isNotEmpty
        ? reason.trim()
        : '${meta.name} 授權已失效，請重新登入';
  }

  @override
  void clearAuthRequired() {
    if (_authState == StreamingAuthState.authRequired) {
      _lastError = null;
      _authState = _accountInfo != null
          ? StreamingAuthState.connected
          : StreamingAuthState.disconnected;
    }
  }

  void setAuthenticating() {
    _authState = StreamingAuthState.authenticating;
    _lastError = null;
  }

  void setConnected(StreamingAccountInfo info) {
    _accountInfo = info;
    _authState = StreamingAuthState.connected;
    _lastError = null;
  }

  void setCatalog(StreamingCatalog catalog) {
    _catalog = catalog;
  }

  void resetState() {
    _authState = StreamingAuthState.disconnected;
    _accountInfo = null;
    _lastError = null;
    _catalog = StreamingCatalog.empty();
  }

  StreamingException failWithError(
    Object error, {
    int? statusCode,
    bool isTokenExpired = false,
    bool isDrmRestricted = false,
  }) {
    if (error is StreamingException) {
      if (error.isCancelled) {
        _authState = StreamingAuthState.disconnected;
        _lastError = error.message;
      } else {
        _authState = StreamingAuthState.error;
        _lastError = error.message;
      }
      return error;
    }
    final ex = StreamingException(
      error.toString(),
      statusCode: statusCode,
      isTokenExpired: isTokenExpired,
      isDrmRestricted: isDrmRestricted,
    );
    _authState = StreamingAuthState.error;
    _lastError = ex.message;
    return ex;
  }

  Future<void> saveCredentialsJson(Map<String, dynamic> payload) {
    return credentialStore.write(credentialStorageKey, jsonEncode(payload));
  }

  Future<Map<String, dynamic>?> readCredentialsJson() async {
    final raw = await credentialStore.read(credentialStorageKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (e) {
      throw StreamingException('已儲存的 $kind 憑證格式損毀：$e');
    }
  }

  Future<void> clearCredentials() async {
    await credentialStore.delete(credentialStorageKey);
  }

  void ensureAuthenticated() {
    if (_authState == StreamingAuthState.authRequired) {
      throw StreamingException(
        _lastError ?? '${meta.name} 授權已失效，請重新登入',
        statusCode: 401,
        isTokenExpired: true,
      );
    }
    if (_authState != StreamingAuthState.connected) {
      throw StreamingException('${meta.name} 尚未登入或授權已失效');
    }
  }

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    ensureAuthenticated();
    return StreamingRecommendations(
      providerKind: kind,
      albums: selectFreshBatch<StreamingAlbum>(
        _catalog.albums,
        idOf: (a) => a.id,
        excludeIds: excludeAlbumIds,
        batchIndex: batchIndex,
      ),
      tracks: selectFreshBatch<TrackInfo>(
        _catalog.tracks,
        idOf: (t) => t.id,
        excludeIds: excludeTrackIds,
        batchIndex: batchIndex,
      ),
      fetchedAt: clock(),
    );
  }

  /// Adds HTTP cache-busting headers when [forceRefresh] is true.
  static Map<String, String> withNoCacheHeaders(
    Map<String, String> headers, {
    required bool forceRefresh,
  }) {
    if (!forceRefresh) return headers;
    return <String, String>{
      ...headers,
      'Cache-Control': 'no-cache, no-store, max-age=0',
      'Pragma': 'no-cache',
    };
  }

  /// Deduplicates [candidates], prioritizes items not in [excludeIds], and
  /// applies a deterministic circular shift by [batchIndex] so consecutive
  /// refreshes visibly rotate items even if an endpoint pool repeats.
  static List<T> selectFreshBatch<T>(
    List<T> candidates, {
    required String Function(T item) idOf,
    Set<String> excludeIds = const <String>{},
    int batchIndex = 0,
    int? maxCount,
  }) {
    final deduped = <T>[];
    final seen = <String>{};
    for (final item in candidates) {
      final id = idOf(item);
      if (seen.add(id)) {
        deduped.add(item);
      }
    }
    if (deduped.isEmpty) return const [];

    final fresh = <T>[];
    final repeated = <T>[];
    for (final item in deduped) {
      if (excludeIds.contains(idOf(item))) {
        repeated.add(item);
      } else {
        fresh.add(item);
      }
    }

    List<T> rotate(List<T> list, int offset) {
      if (list.length <= 1 || offset <= 0) return list;
      final shift = offset % list.length;
      if (shift == 0) return list;
      return <T>[...list.sublist(shift), ...list.sublist(0, shift)];
    }

    final ordered = fresh.isNotEmpty
        ? <T>[...rotate(fresh, batchIndex), ...rotate(repeated, batchIndex)]
        : rotate(repeated, batchIndex);

    if (maxCount != null && ordered.length > maxCount) {
      return List<T>.unmodifiable(ordered.take(maxCount));
    }
    return List<T>.unmodifiable(ordered);
  }

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async {
    return null;
  }

  static String normalizeBaseUrl(String baseUrl) {
    return baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
  }

  static Uri buildUri(
    String baseUrl,
    String path, [
    Map<String, String>? queryParameters,
  ]) {
    final cleanBase = normalizeBaseUrl(baseUrl);
    final cleanPath =
        path.isEmpty ? '' : (path.startsWith('/') ? path : '/$path');
    final uri = Uri.parse('$cleanBase$cleanPath');
    if (queryParameters == null || queryParameters.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...queryParameters,
      },
    );
  }

  static String encodeForm(Map<String, String> fields) {
    return fields.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
  }

  static String stripTrackPrefix(String rawId, String prefix) {
    final fullPrefix = '$prefix:';
    if (rawId.startsWith(fullPrefix)) {
      return rawId.substring(fullPrefix.length);
    }
    return rawId;
  }

  /// Sleeps for [duration], returning immediately with cancellation error if
  /// [cancel] fires before the timer elapses.
  static Future<void> cancellableDelay(
    Duration duration,
    CancellationToken? cancel,
  ) async {
    cancel?.throwIfCancelled();
    if (duration <= Duration.zero) return;

    final completer = Completer<void>();
    late final Timer timer;

    void onCancel() {
      if (!completer.isCompleted) {
        timer.cancel();
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    timer = Timer(duration, () {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });

    cancel?.addListener(onCancel);
    try {
      await completer.future;
    } finally {
      timer.cancel();
      cancel?.removeListener(onCancel);
    }
  }
}
