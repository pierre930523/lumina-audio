import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../models/streaming_models.dart';

/// RFC 7636 PKCE verifier and S256 challenge pair.
class PkcePair {
  final String verifier;
  final String challenge;

  const PkcePair({
    required this.verifier,
    required this.challenge,
  });
}

/// Generates a cryptographically random PKCE verifier and S256 challenge.
PkcePair generatePkcePair({int byteLength = 48}) {
  final rng = Random.secure();
  final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
  final verifier = base64UrlEncode(bytes).replaceAll('=', '');
  final digest = sha256.convert(ascii.encode(verifier));
  final challenge = base64UrlEncode(digest.bytes).replaceAll('=', '');
  return PkcePair(verifier: verifier, challenge: challenge);
}

/// Generates an opaque CSRF state token for OAuth authorization URLs.
String generateOAuthState({int byteLength = 24}) {
  final rng = Random.secure();
  final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// Opens an `http://` or `https://` URL in the user's default system browser.
///
/// Prefers the native `lumina/window` `openUrl` MethodChannel (backed by
/// Win32 `ShellExecuteW`), falling back on Windows to `cmd /c start`.
/// Strictly rejects non-HTTP(S) schemes.
Future<bool> openSystemBrowser(
  String url, {
  MethodChannel? channel,
  Future<bool> Function(String url)? urlOpener,
}) async {
  final trimmed = url.trim();
  if (trimmed.contains('\r') ||
      trimmed.contains('\n') ||
      trimmed.contains('\x00')) {
    throw const StreamingException('不合法的瀏覽器網址字元');
  }
  final uri = Uri.tryParse(trimmed);
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty) {
    throw StreamingException('僅允許開啟 http:// 或 https:// 網址：$url');
  }

  if (urlOpener != null) {
    return urlOpener(trimmed);
  }

  final ch = channel ?? const MethodChannel('lumina/window');
  try {
    await ch.invokeMethod<dynamic>('openUrl', trimmed);
    return true;
  } on MissingPluginException {
    // Fall back below on desktop OSes when MethodChannel is unavailable.
  } on PlatformException catch (e) {
    throw StreamingException('無法透過原生視窗開啟瀏覽器：${e.message ?? e.code}');
  }

  if (Platform.isWindows) {
    await Process.start('cmd', <String>['/c', 'start', '', trimmed]);
    return true;
  }
  if (Platform.isMacOS) {
    await Process.start('open', <String>[trimmed]);
    return true;
  }
  if (Platform.isLinux) {
    await Process.start('xdg-open', <String>[trimmed]);
    return true;
  }
  return false;
}

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
      return;
    }

    if (req.method == 'GET' && path == '/callback') {
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
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
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

/// Safely encodes a Dart string for embedding inside an HTML `<script>` block.
String _safeJsString(String value) =>
    jsonEncode(value).replaceAll('</', r'<\/').replaceAll('<!--', r'<\!--');

/// Builds an HTML page using Apple MusicKit JS v3 to authorize a real
/// `musicUserToken` and POST it back to [callbackUrl].
String buildMusicKitAuthHtml(String developerToken, String callbackUrl) {
  final devTokenJson = _safeJsString(developerToken);
  final callbackJson = _safeJsString(callbackUrl);

  return '''<!DOCTYPE html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Lumina Audio — Apple Music 授權</title>
  <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js" async></script>
  <style>
    body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:#0B0F17; color:#F8FAFC; display:flex; align-items:center; justify-content:center; min-height:100vh; }
    .card { max-width:480px; padding:32px; border-radius:16px; background:#111827; border:1px solid rgba(250,36,60,0.35); box-shadow:0 20px 50px rgba(0,0,0,0.5); }
    h1 { margin:0 0 10px; font-size:20px; color:#FA243C; }
    p { margin:0 0 18px; font-size:14px; line-height:1.6; color:#CBD5E1; }
    button { appearance:none; border:0; border-radius:10px; padding:10px 18px; background:#FA243C; color:#FFFFFF; font-size:14px; font-weight:600; cursor:pointer; }
    button:disabled { opacity:0.55; cursor:wait; }
    .status { margin-top:14px; font-size:13px; color:#94A3B8; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Apple Music 帳號授權</h1>
    <p>請透過 Apple MusicKit 完成登入授權，Lumina Audio 將透過本機回傳通道接收您的 Music-User-Token。</p>
    <button id="authBtn" type="button">使用 Apple 帳號登入</button>
    <div id="status" class="status">正在載入 Apple MusicKit JS...</div>
  </div>
  <script>
    (function () {
      const developerToken = $devTokenJson;
      const callbackUrl = $callbackJson;
      const statusEl = document.getElementById('status');
      const authBtn = document.getElementById('authBtn');
      let configured = false;

      async function configureMusicKit() {
        if (configured || !window.MusicKit) return;
        await window.MusicKit.configure({
          developerToken: developerToken,
          app: { name: 'Lumina Audio', build: '0.2.1' }
        });
        configured = true;
        statusEl.textContent = 'MusicKit 已就緒，正在開啟 Apple 登入視窗...';
      }

      async function runAuthorize() {
        authBtn.disabled = true;
        try {
          await configureMusicKit();
          const music = window.MusicKit.getInstance();
          const musicUserToken = await music.authorize();
          if (!musicUserToken) {
            throw new Error('未取得有效的 Music-User-Token');
          }
          statusEl.textContent = '授權成功，正在傳送憑證至 Lumina Audio...';
          const resp = await fetch(callbackUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ musicUserToken: musicUserToken })
          });
          if (!resp.ok) {
            throw new Error('回傳至 Lumina Audio 失敗（HTTP ' + resp.status + '）');
          }
          statusEl.textContent = '已完成授權！您可以關閉此瀏覽器分頁並返回 Lumina Audio。';
        } catch (err) {
          const msg = (err && err.message) ? err.message : String(err);
          statusEl.textContent = '授權失敗：' + msg;
          authBtn.disabled = false;
          try {
            await fetch(callbackUrl, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ error: msg })
            });
          } catch (_) {}
        }
      }

      authBtn.addEventListener('click', runAuthorize);
      if (window.MusicKit) {
        runAuthorize();
      } else {
        document.addEventListener('musickitloaded', runAuthorize, { once: true });
      }
    })();
  </script>
</body>
</html>''';
}
