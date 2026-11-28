import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../models/streaming_models.dart';

/// Payload delivered to [LoopbackOAuthServer] via OAuth redirect or MusicKit POST.
class OAuthCallbackPayload {
  final String? code;
  final String? state;
  final String? musicUserToken;
  final Map<String, String> queryParams;

  const OAuthCallbackPayload({
    this.code,
    this.state,
    this.musicUserToken,
    this.queryParams = const {},
  });
}

/// Ephemeral loopback HTTP server on `127.0.0.1` for OAuth2 PKCE / MusicKit callbacks.
class LoopbackOAuthServer {
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Completer<OAuthCallbackPayload>? _completer;
  String? _musicKitHtml;
  String? _expectedState;

  int get port {
    final s = _server;
    if (s == null) {
      throw const StreamingException('LoopbackOAuthServer 尚未啟動');
    }
    return s.port;
  }

  bool get isRunning => _server != null;

  String callbackUrl([String path = '/callback']) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return 'http://127.0.0.1:$port$normalized';
  }

  void setMusicKitHtml(String html) {
    _musicKitHtml = html;
  }

  void setExpectedState(String? expectedState) {
    _expectedState = expectedState;
  }

  Future<void> start({
    int port = 0,
    String? musicKitHtml,
    String? expectedState,
  }) async {
    if (_server != null) return;
    if (musicKitHtml != null) {
      _musicKitHtml = musicKitHtml;
    }
    if (expectedState != null) {
      _expectedState = expectedState;
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final completer = Completer<OAuthCallbackPayload>();
    _server = server;
    _completer = completer;

    // Start serving routes immediately upon bind so browser redirects or
    // MusicKit HTML fetches cannot deadlock before waitForCallback() runs.
    _subscription = server.listen(
      (HttpRequest req) => _handleRequest(req, completer),
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(
            StreamingException('本機授權伺服器錯誤：$error'),
            stackTrace,
          );
        }
      },
    );
  }

  Future<void> _handleRequest(
    HttpRequest req,
    Completer<OAuthCallbackPayload> completer,
  ) async {
    final path = req.uri.path;
    if (path == '/favicon.ico') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }

    if (req.method == 'GET' && path == '/musickit-auth') {
      final html = _musicKitHtml;
      if (html == null) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.html;
      req.response.write(html);
      await req.response.close();
      return;
    }

    if (req.method == 'OPTIONS' && path == '/musickit-callback') {
      _applyCorsHeaders(req.response);
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      return;
    }

    if (req.method == 'POST' && path == '/musickit-callback') {
      _applyCorsHeaders(req.response);
      await _handleMusicKitPost(req, completer);
      return;
    }

    if (req.method == 'GET' && path == '/callback') {
      await _handleOAuthRedirect(req, completer);
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  Future<void> _handleMusicKitPost(
    HttpRequest req,
    Completer<OAuthCallbackPayload> completer,
  ) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'Invalid JSON payload',
          }),
        );
        await req.response.close();
        return;
      }
      final errorMsg = decoded['error']?.toString();
      final token = decoded['musicUserToken']?.toString().trim();
      if (errorMsg != null && errorMsg.isNotEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{'ok': false, 'error': errorMsg}),
        );
        await req.response.close();
        if (!completer.isCompleted) {
          completer.completeError(
            StreamingException('Apple MusicKit 授權失敗：$errorMsg'),
          );
        }
        return;
      }
      if (token == null || token.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'Missing musicUserToken',
          }),
        );
        await req.response.close();
        if (!completer.isCompleted) {
          completer.completeError(
            const StreamingException(
              'Apple MusicKit 未回傳有效的 musicUserToken',
            ),
          );
        }
        return;
      }

      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, dynamic>{'ok': true}));
      await req.response.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!completer.isCompleted) {
        completer.complete(
          OAuthCallbackPayload(musicUserToken: token),
        );
      }
    } catch (e) {
      req.response.statusCode = HttpStatus.badRequest;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': e.toString(),
        }),
      );
      await req.response.close();
      if (!completer.isCompleted) {
        completer.completeError(
          StreamingException('解析 MusicKit 回傳資料失敗：$e'),
        );
      }
    }
  }

  Future<void> _handleOAuthRedirect(
    HttpRequest req,
    Completer<OAuthCallbackPayload> completer,
  ) async {
    final params = req.uri.queryParameters;
    final oauthError = params['error'];
    if (oauthError != null && oauthError.isNotEmpty) {
      final desc = params['error_description'] ?? oauthError;
      await _writeHtmlPage(
        req.response,
        statusCode: HttpStatus.badRequest,
        title: 'Lumina Audio — 授權失敗',
        heading: '登入授權未完成',
        bodyText: '串流平台回傳錯誤：$desc。請關閉此分頁並回到 Lumina Audio 重試。',
        isError: true,
      );
      if (!completer.isCompleted) {
        completer.completeError(
          StreamingException('OAuth 授權失敗：$desc'),
        );
      }
      return;
    }

    final state = params['state'];
    final expectedState = _expectedState;
    if (expectedState != null &&
        expectedState.isNotEmpty &&
        state != expectedState) {
      await _writeHtmlPage(
        req.response,
        statusCode: HttpStatus.badRequest,
        title: 'Lumina Audio — 驗證錯誤',
        heading: '安全狀態碼（state）驗證失敗',
        bodyText: '為保護帳號安全，Lumina Audio 已拒絕此次無效的授權回傳。請關閉分頁並重新發起登入。',
        isError: true,
      );
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('OAuth state 驗證不符，已拒絕授權回應'),
        );
      }
      return;
    }

    final code = params['code']?.trim();
    if (code == null || code.isEmpty) {
      await _writeHtmlPage(
        req.response,
        statusCode: HttpStatus.badRequest,
        title: 'Lumina Audio — 缺少授權碼',
        heading: '未收到授權碼（code）',
        bodyText: '授權回傳缺少 code 參數，請關閉此分頁並重新登入。',
        isError: true,
      );
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('OAuth 回傳缺少 code 授權碼'),
        );
      }
      return;
    }

    await _writeHtmlPage(
      req.response,
      statusCode: HttpStatus.ok,
      title: 'Lumina Audio — 授權完成',
      heading: '登入授權成功',
      bodyText: 'Lumina Audio 已安全接收您的授權憑證，您現在可以關閉此分頁並返回播放器。',
      isError: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!completer.isCompleted) {
      completer.complete(
        OAuthCallbackPayload(
          code: code,
          state: state,
          queryParams: Map<String, String>.unmodifiable(params),
        ),
      );
    }
  }

  Future<OAuthCallbackPayload> waitForCallback({
    String? expectedState,
    Duration timeout = const Duration(minutes: 5),
    CancellationToken? cancel,
  }) async {
    final server = _server;
    final completer = _completer;
    if (server == null || completer == null) {
      throw const StreamingException('LoopbackOAuthServer 尚未啟動');
    }
    if (expectedState != null) {
      _expectedState = expectedState;
    }

    cancel?.throwIfCancelled();

    void cancelListener() {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('登入已取消', isCancelled: true),
        );
      }
    }

    cancel?.addListener(cancelListener);

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('等待瀏覽器授權回應逾時，請重新登入'),
        );
      }
    });

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      cancel?.removeListener(cancelListener);
      await close();
    }
  }

  Future<void> close() async {
    final s = _server;
    final sub = _subscription;
    _server = null;
    _subscription = null;
    _completer = null;
    if (s != null) {
      try {
        await s.close().timeout(const Duration(milliseconds: 500));
      } catch (_) {
        await s.close(force: true);
      }
    }
    if (sub != null) {
      await sub.cancel();
    }
  }

  static void _applyCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }

  static Future<void> _writeHtmlPage(
    HttpResponse response, {
    required int statusCode,
    required String title,
    required String heading,
    required String bodyText,
    required bool isError,
  }) async {
    final safeTitle = const HtmlEscape().convert(title);
    final safeHeading = const HtmlEscape().convert(heading);
    final safeBody = const HtmlEscape().convert(bodyText);
    final accent = isError ? '#EF4444' : '#38BDF8';
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.html;
    response.write('''<!DOCTYPE html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<title>$safeTitle</title>
<style>
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#0B0F17; color:#F8FAFC; display:flex; align-items:center; justify-content:center; min-height:100vh; }
  .card { max-width:460px; padding:32px; border-radius:16px; background:#111827; border:1px solid rgba(148,163,184,0.22); box-shadow:0 20px 50px rgba(0,0,0,0.45); }
  h1 { margin:0 0 12px; font-size:20px; color:$accent; }
  p { margin:0; font-size:14px; line-height:1.65; color:#CBD5E1; }
</style>
</head>
<body>
  <div class="card">
    <h1>$safeHeading</h1>
    <p>$safeBody</p>
  </div>
</body>
</html>''');
    await response.close();
  }
}
