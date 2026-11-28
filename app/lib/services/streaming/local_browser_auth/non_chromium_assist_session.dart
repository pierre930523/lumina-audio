part of '../local_browser_auth_service.dart';

class _NonChromiumAssistSession {
  final WebViewAuthRequest request;
  final DetectedDefaultBrowser detectedBrowser;
  final void Function(String message) logSink;

  final Completer<WebViewAuthResult> completer = Completer<WebViewAuthResult>();
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Timer? _timeoutTimer;

  _NonChromiumAssistSession({
    required this.request,
    required this.detectedBrowser,
    required this.logSink,
  });

  String get helperUrl {
    final srv = _server;
    if (srv == null) return '';
    return 'http://127.0.0.1:${srv.port}/';
  }

  Future<void> start() async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = srv;
    logSink(
      '[BrowserAuth] Started non-Chromium assisted loopback helper at http://127.0.0.1:${srv.port}/ '
      'for ${detectedBrowser.displayName}',
    );
    _subscription = srv.listen((req) async {
      await _handleHttpRequest(req);
    });
  }

  void startTimeoutTimer(Duration timeout) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(
          WebViewAuthResult(
            captured: false,
            cancelled: false,
            isNonChromiumDefault: true,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            error: '等待系統預設瀏覽器（${detectedBrowser.displayName}）輔助提交逾時',
          ),
        );
      }
    });
  }

  void requestCancel() {
    if (!completer.isCompleted) {
      completer.complete(
        WebViewAuthResult(
          captured: false,
          cancelled: true,
          isNonChromiumDefault: true,
          detectedBrowserName: detectedBrowser.displayName,
          detectedBrowserPath: detectedBrowser.executablePath,
        ),
      );
    }
  }

  Future<void> _handleHttpRequest(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'GET' && path == '/') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.html;
      final safeTitle = const HtmlEscape().convert(request.title);
      final safeBrowser =
          const HtmlEscape().convert(detectedBrowser.displayName);
      req.response.write('''<!DOCTYPE html>
<html lang="zh-Hant">
<head><meta charset="utf-8"><title>Lumina Audio — $safeTitle</title></head>
<body style="font-family:sans-serif;background:#0b0f17;color:#f8fafc;padding:32px;">
  <h2>$safeTitle（$safeBrowser 輔助授權）</h2>
  <p>偵測到您的預設瀏覽器為 $safeBrowser（非 Chromium 核心），請貼上登入憑證送出：</p>
  <form method="POST" action="/submit">
    <input name="token" placeholder="Token / Cookie / ARL" style="width:360px;padding:8px;" />
    <input name="app_id" placeholder="App ID / Developer Token (選填)" style="width:240px;padding:8px;" />
    <button type="submit" style="padding:8px 16px;">完成登入</button>
  </form>
</body>
</html>''');
      await req.response.close();
      return;
    }

    if (req.method == 'POST' && path == '/submit') {
      final rawBody = await utf8.decoder.bind(req).join();
      final fields = <String, String>{};
      if (rawBody.trim().startsWith('{')) {
        try {
          final parsed = jsonDecode(rawBody);
          if (parsed is Map) {
            for (final e in parsed.entries) {
              final k = e.key?.toString().trim() ?? '';
              final v = e.value?.toString().trim() ?? '';
              if (k.isNotEmpty && v.isNotEmpty) fields[k] = v;
            }
          }
        } catch (_) {}
      } else {
        fields.addAll(Uri.splitQueryString(rawBody));
      }

      final token = (fields['token'] ??
              fields['cookie'] ??
              fields['arl'] ??
              fields['access_token'] ??
              fields['user_auth_token'] ??
              fields['music_user_token'] ??
              '')
          .trim();
      final appId = (fields['app_id'] ?? '').trim();
      final devToken = (fields['developer_token'] ?? '').trim();

      if (token.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': false, 'error': 'Missing token'}));
        await req.response.close();
        return;
      }

      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ok': true}));
      await req.response.close();

      if (!completer.isCompleted) {
        final cookies = <String, String>{};
        final headers = <String, String>{};
        final queryParams = <String, String>{};
        var cookieHeader = '';
        switch (request.providerKind) {
          case 'youtube_music':
            cookieHeader = token;
            break;
          case 'deezer':
            cookies['arl'] = token;
            break;
          case 'tidal':
            headers['authorization'] =
                token.toLowerCase().startsWith('bearer ')
                    ? token
                    : 'Bearer $token';
            break;
          case 'qobuz':
            headers['x-user-auth-token'] = token;
            if (appId.isNotEmpty) queryParams['app_id'] = appId;
            break;
          case 'apple_music':
            headers['media-user-token'] = token;
            if (devToken.isNotEmpty) {
              headers['authorization'] =
                  devToken.toLowerCase().startsWith('bearer ')
                      ? devToken
                      : 'Bearer $devToken';
            }
            break;
        }
        logSink(
          '[BrowserAuth] Captured ${request.providerKind} assisted token '
          '(${maskSecretForLog(token)}) via ${detectedBrowser.displayName} loopback helper',
        );
        completer.complete(
          WebViewAuthResult(
            captured: true,
            cancelled: false,
            isNonChromiumDefault: true,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            cookieHeader: cookieHeader,
            cookies: Map<String, String>.unmodifiable(cookies),
            headers: Map<String, String>.unmodifiable(headers),
            queryParams: Map<String, String>.unmodifiable(queryParams),
            capturedUrl: request.initialUrl,
          ),
        );
      }
      return;
    }

    if ((req.method == 'POST' || req.method == 'GET') &&
        (path == '/close' || path == '/cancel')) {
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      if (!completer.isCompleted) {
        completer.complete(
          WebViewAuthResult(
            captured: false,
            cancelled: false,
            isNonChromiumDefault: true,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            error:
                '已於 ${detectedBrowser.displayName} 開啟登入頁；請於下方貼上憑證完成驗證。',
          ),
        );
      }
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  Future<void> close() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final sub = _subscription;
    final srv = _server;
    _subscription = null;
    _server = null;
    try {
      await srv?.close(force: true);
    } catch (_) {}
    try {
      await sub?.cancel();
    } catch (_) {}
  }
}
