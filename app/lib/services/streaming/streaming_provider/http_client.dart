part of '../streaming_provider.dart';

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

/// Resolves [host] to an IPv4 [InternetAddress] when available so Dart HTTP
/// resolvers and Rust streaming downloaders share the same egress IP family
/// (preventing YouTube CDN IP-bound HTTP 403s on dual-stack networks).
///
/// If [host] is already an IP literal, returns the parsed address directly.
/// Returns `null` if IPv4 DNS lookup yields no record (allowing fallback to
/// default OS resolution).
Future<InternetAddress?> resolvePreferredIpv4Address(
  String host, {
  Future<List<InternetAddress>> Function(String host)? ipv4Lookup,
}) async {
  final parsed = InternetAddress.tryParse(host);
  if (parsed != null) {
    return parsed;
  }
  final lookup =
      ipv4Lookup ??
      ((String h) => InternetAddress.lookup(h, type: InternetAddressType.IPv4));
  try {
    final addrs = await lookup(host);
    for (final addr in addrs) {
      if (addr.type == InternetAddressType.IPv4) {
        return addr;
      }
    }
  } catch (_) {
    // Fall back to default OS resolution on IPv6-only hosts or test fixtures.
  }
  return null;
}

/// Creates a `dart:io` [HttpClient] that prefers IPv4 connections via
/// [HttpClient.connectionFactory] while preserving full TLS SNI and
/// certificate verification for HTTPS hosts.
HttpClient createIpv4HttpClient({
  Duration? idleTimeout,
  int? maxConnectionsPerHost,
  Duration? connectionTimeout,
  Future<List<InternetAddress>> Function(String host)? ipv4Lookup,
}) {
  final client = HttpClient();
  if (idleTimeout != null) client.idleTimeout = idleTimeout;
  if (maxConnectionsPerHost != null) {
    client.maxConnectionsPerHost = maxConnectionsPerHost;
  }
  if (connectionTimeout != null) client.connectionTimeout = connectionTimeout;

  try {
    client.connectionFactory =
        (Uri uri, String? proxyHost, int? proxyPort) async {
          final targetHost = proxyHost ?? uri.host;
          final targetPort =
              proxyPort ??
              (uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80));
          final ipv4Addr = await resolvePreferredIpv4Address(
            targetHost,
            ipv4Lookup: ipv4Lookup,
          );
          final Object connectTarget = ipv4Addr ?? targetHost;
          final rawTask = await Socket.startConnect(connectTarget, targetPort);

          if (proxyHost == null && uri.scheme == 'https') {
            var cancelled = false;
            Socket? connectedRaw;
            final tlsFuture = rawTask.socket.then<Socket>((
              Socket rawSocket,
            ) async {
              connectedRaw = rawSocket;
              if (cancelled) {
                rawSocket.destroy();
                throw const SocketException('Connection cancelled');
              }
              try {
                final secure = await SecureSocket.secure(
                  rawSocket,
                  host: uri.host,
                );
                if (cancelled) {
                  secure.destroy();
                  throw const SocketException('Connection cancelled');
                }
                return secure;
              } catch (_) {
                rawSocket.destroy();
                rethrow;
              }
            });
            return ConnectionTask.fromSocket<Socket>(tlsFuture, () {
              cancelled = true;
              rawTask.cancel();
              connectedRaw?.destroy();
            });
          }
          return rawTask;
        };
  } catch (_) {
    // Flutter test harnesses may inject a mock HttpClient whose
    // connectionFactory setter is unimplemented.
  }
  return client;
}

/// Shared `dart:io` HTTP client wrapper with timeouts, cancellation, and strict
/// JSON / HTTP status validation across all streaming providers.
class StreamingHttpClient {
  final HttpClient Function() _clientFactory;
  final Duration timeout;

  StreamingHttpClient({
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? (() => createIpv4HttpClient());

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
