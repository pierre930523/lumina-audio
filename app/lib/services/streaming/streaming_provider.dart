import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import 'secure_credential_store.dart';

/// Unified interface implemented by every real streaming service backend.
abstract class StreamingProvider {
  String get kind;
  StreamingProviderMeta get meta;
  StreamingAuthState get authState;
  StreamingAccountInfo? get accountInfo;
  String? get lastError;
  StreamingCatalog get catalog;

  Future<void> restoreFromStorage();
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  });
  Future<void> refreshSessionIfNeeded();
  Future<void> logout();
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel});
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
  });
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  });
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId);
  Future<StreamingCatalog> search(String query);
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  });
}

/// Raw HTTP response wrapper returned by [StreamingHttpClient].
class StreamingHttpResponse {
  final int statusCode;
  final String body;
  final HttpHeaders headers;

  const StreamingHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Shared `dart:io` HTTP client wrapper with timeouts, cancellation, and strict
/// JSON / HTTP status validation across all streaming providers.
class StreamingHttpClient {
  final HttpClient Function() _clientFactory;
  final Duration timeout;

  StreamingHttpClient({
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  static Future<T> _withRootTimeout<T>(
    Future<T> future,
    Duration timeout,
  ) {
    final completer = Completer<T>();
    final timer = Zone.root.createTimer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('HTTP timeout', timeout));
      }
    });
    future.then(
      (value) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.complete(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    return completer.future;
  }

  Future<StreamingHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    String? body,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();

    final effectiveTimeout = timeout ?? this.timeout;
    final client = _clientFactory();

    void onCancel() {
      try {
        client.close(force: true);
      } catch (_) {}
    }

    cancel?.addListener(onCancel);
    try {
      final req = await _withRootTimeout(
        client.openUrl(method.toUpperCase(), uri),
        effectiveTimeout,
      );
      headers.forEach((k, v) => req.headers.set(k, v));
      if (body != null) {
        final bytes = utf8.encode(body);
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final resp = await _withRootTimeout(req.close(), effectiveTimeout);
      final respBody = await _withRootTimeout(
        utf8.decoder.bind(resp).join(),
        effectiveTimeout,
      );
      cancel?.throwIfCancelled();
      return StreamingHttpResponse(
        statusCode: resp.statusCode,
        body: respBody,
        headers: resp.headers,
      );
    } on StreamingException {
      rethrow;
    } on TimeoutException {
      throw StreamingException(
        '連線逾時（${uri.host} 未在 ${effectiveTimeout.inSeconds} 秒內回應）',
      );
    } on SocketException catch (e) {
      if (cancel?.isCancelled == true) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      throw StreamingException('網路連線失敗：${e.message}');
    } on HttpException catch (e) {
      if (cancel?.isCancelled == true) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      throw StreamingException('HTTP 通訊協定錯誤：${e.message}');
    } catch (e) {
      if (cancel?.isCancelled == true) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      throw StreamingException('網路請求失敗：$e');
    } finally {
      cancel?.removeListener(onCancel);
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  /// Sends a request and decodes JSON without throwing on non-2xx responses.
  Future<({int statusCode, Map<String, dynamic> json, String rawBody})>
      sendJsonRaw({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    Object? jsonBody,
    String? formBody,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final effectiveHeaders = Map<String, String>.from(headers);
    String? encodedBody = formBody;
    if (jsonBody != null) {
      effectiveHeaders.putIfAbsent('Content-Type', () => 'application/json');
      encodedBody = jsonEncode(jsonBody);
    } else if (formBody != null) {
      effectiveHeaders.putIfAbsent(
        'Content-Type',
        () => 'application/x-www-form-urlencoded',
      );
    }

    final resp = await send(
      method: method,
      uri: uri,
      headers: effectiveHeaders,
      body: encodedBody,
      cancel: cancel,
      timeout: timeout,
    );

    Map<String, dynamic> decoded = <String, dynamic>{};
    if (resp.body.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(resp.body);
        if (parsed is Map<String, dynamic>) {
          decoded = parsed;
        } else if (parsed is Map) {
          decoded = Map<String, dynamic>.from(parsed);
        } else {
          throw StreamingException(
            '伺服器回傳非預期的 JSON 格式（HTTP ${resp.statusCode}）',
            statusCode: resp.statusCode,
          );
        }
      } on StreamingException {
        rethrow;
      } on FormatException catch (e) {
        throw StreamingException(
          '無效的 JSON 回應（HTTP ${resp.statusCode}）：${e.message}',
          statusCode: resp.statusCode,
        );
      }
    }
    return (statusCode: resp.statusCode, json: decoded, rawBody: resp.body);
  }

  /// Sends a request and requires a 2xx JSON object response.
  Future<Map<String, dynamic>> requestJson({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    Object? jsonBody,
    String? formBody,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    final res = await sendJsonRaw(
      method: method,
      uri: uri,
      headers: headers,
      jsonBody: jsonBody,
      formBody: formBody,
      cancel: cancel,
      timeout: timeout,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StreamingException(
        extractApiErrorMessage(res.json, res.rawBody, res.statusCode),
        statusCode: res.statusCode,
        isTokenExpired: res.statusCode == 401,
      );
    }
    return res.json;
  }

  static String extractApiErrorMessage(
    Map<String, dynamic> json,
    String rawBody,
    int statusCode,
  ) {
    final errObj = json['error'];
    if (errObj is Map) {
      final msg = errObj['message']?.toString() ?? errObj['type']?.toString();
      if (msg != null && msg.trim().isNotEmpty) {
        return 'HTTP $statusCode：$msg';
      }
    } else if (errObj is String && errObj.trim().isNotEmpty) {
      final desc = json['error_description']?.toString();
      return desc != null && desc.trim().isNotEmpty
          ? 'HTTP $statusCode：$errObj ($desc)'
          : 'HTTP $statusCode：$errObj';
    }
    for (final key in const [
      'userMessage',
      'message',
      'error_description',
      'detail',
      'reason',
    ]) {
      final val = json[key]?.toString();
      if (val != null && val.trim().isNotEmpty) {
        return 'HTTP $statusCode：$val';
      }
    }
    final errorsList = json['errors'];
    if (errorsList is List && errorsList.isNotEmpty) {
      final first = errorsList.first;
      if (first is Map) {
        final detail = first['detail']?.toString() ?? first['title']?.toString();
        if (detail != null && detail.trim().isNotEmpty) {
          return 'HTTP $statusCode：$detail';
        }
      }
    }
    final snippet = rawBody.trim();
    if (snippet.isNotEmpty && snippet.length <= 200) {
      return 'HTTP $statusCode：$snippet';
    }
    return 'API 驗證或請求失敗（HTTP $statusCode）';
  }
}

/// Shared stateful scaffolding for [StreamingProvider] implementations.
abstract class BaseStreamingProvider implements StreamingProvider {
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
    if (_authState != StreamingAuthState.connected) {
      throw StreamingException('${meta.name} 尚未登入或授權已失效');
    }
  }

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    return StreamingRecommendations(
      providerKind: kind,
      albums: _catalog.albums,
      tracks: _catalog.tracks,
      fetchedAt: clock(),
    );
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
