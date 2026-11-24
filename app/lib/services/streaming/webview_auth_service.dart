import 'dart:io';

import 'package:flutter/services.dart';

import '../../models/streaming_models.dart';

/// Declarative capture configuration passed to the native Win32 WebView2
/// authentication window (Plan A).
class WebViewAuthRequest {
  final String providerKind;
  final String title;
  final String initialUrl;
  final String? cookieDomain;
  final List<String> cookieDomainSubstrings;
  final String? requiredHostSubstring;
  final List<String> excludedUrlSubstrings;
  final List<String> requiredAnyCookies;
  final List<String> requiredAllCookies;
  final List<String> headerUrlSubstrings;
  final List<String> responseBodyUrlSubstrings;
  final List<String> captureHeaderNames;
  final List<String> captureQueryParams;
  final List<String> requiredHeaders;
  final List<List<String>> requiredGroups;
  final bool inspectWebStorage;
  final bool clearSession;

  const WebViewAuthRequest({
    required this.providerKind,
    required this.title,
    required this.initialUrl,
    this.cookieDomain,
    this.cookieDomainSubstrings = const [],
    this.requiredHostSubstring,
    this.excludedUrlSubstrings = const [],
    this.requiredAnyCookies = const [],
    this.requiredAllCookies = const [],
    this.headerUrlSubstrings = const [],
    this.responseBodyUrlSubstrings = const [],
    this.captureHeaderNames = const [],
    this.captureQueryParams = const [],
    this.requiredHeaders = const [],
    this.requiredGroups = const [],
    this.inspectWebStorage = false,
    this.clearSession = false,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
        'providerKind': providerKind,
        'title': title,
        'initialUrl': initialUrl,
        if (cookieDomain != null) 'cookieDomain': cookieDomain,
        'cookieDomainSubstrings': cookieDomainSubstrings,
        if (requiredHostSubstring != null)
          'requiredHostSubstring': requiredHostSubstring,
        'excludedUrlSubstrings': excludedUrlSubstrings,
        'requiredAnyCookies': requiredAnyCookies,
        'requiredAllCookies': requiredAllCookies,
        'headerUrlSubstrings': headerUrlSubstrings,
        'responseBodyUrlSubstrings': responseBodyUrlSubstrings,
        'captureHeaderNames': captureHeaderNames,
        'captureQueryParams': captureQueryParams,
        'requiredHeaders': requiredHeaders,
        'requiredGroups': requiredGroups,
        'inspectWebStorage': inspectWebStorage,
        'clearSession': clearSession,
      };

  static WebViewAuthRequest presetFor(
    String kind, {
    bool clearSession = false,
  }) {
    return switch (kind) {
      'youtube_music' => WebViewAuthRequest(
          providerKind: kind,
          title: '登入 YouTube Music',
          initialUrl: 'https://music.youtube.com',
          cookieDomain: 'https://music.youtube.com',
          cookieDomainSubstrings: const ['.youtube.com', 'youtube.com'],
          requiredHostSubstring: 'music.youtube.com',
          excludedUrlSubstrings: const [
            'accounts.google.com',
            'ServiceLogin',
          ],
          requiredAnyCookies: const [
            'SAPISID',
            '__Secure-3PAPISID',
            '__Secure-1PAPISID',
          ],
          requiredGroups: const [
            ['cookie:SAPISID', 'cookie:__Secure-3PAPISID', 'cookie:__Secure-1PAPISID'],
          ],
          clearSession: clearSession,
        ),
      'deezer' => WebViewAuthRequest(
          providerKind: kind,
          title: '登入 Deezer',
          initialUrl: 'https://www.deezer.com/login',
          cookieDomain: 'https://www.deezer.com',
          cookieDomainSubstrings: const ['.deezer.com', 'deezer.com'],
          requiredHostSubstring: 'deezer.com',
          excludedUrlSubstrings: const ['/login', '/signup'],
          requiredAllCookies: const ['arl'],
          requiredGroups: const [
            ['cookie:arl'],
          ],
          clearSession: clearSession,
        ),
      'tidal' => WebViewAuthRequest(
          providerKind: kind,
          title: '登入 TIDAL',
          initialUrl: 'https://listen.tidal.com',
          cookieDomain: 'https://listen.tidal.com',
          cookieDomainSubstrings: const ['.tidal.com', 'tidal.com'],
          requiredHostSubstring: 'tidal.com',
          excludedUrlSubstrings: const ['login.tidal.com', 'auth.tidal.com'],
          headerUrlSubstrings: const [
            'api.tidal.com',
            'openapi.tidal.com',
            'listen.tidal.com',
          ],
          captureHeaderNames: const ['Authorization', 'x-tidal-token'],
          inspectWebStorage: true,
          requiredGroups: const [
            [
              'header:authorization',
              'header:x-tidal-token',
              'storage:access_token',
              'storage:oAuthAccessToken',
              'storage:token',
              'storage:authorization',
              'cookie:access_token',
            ],
          ],
          clearSession: clearSession,
        ),
      'qobuz' => WebViewAuthRequest(
          providerKind: kind,
          title: '登入 Qobuz',
          initialUrl: 'https://play.qobuz.com/login',
          cookieDomain: 'https://play.qobuz.com',
          cookieDomainSubstrings: const ['.qobuz.com', 'qobuz.com'],
          requiredHostSubstring: 'qobuz.com',
          excludedUrlSubstrings: const ['/login', '/signin', '/signup'],
          headerUrlSubstrings: const ['qobuz.com/api.json', 'play.qobuz.com'],
          responseBodyUrlSubstrings: const ['qobuz.com/api.json', '/user/login'],
          captureHeaderNames: const ['X-User-Auth-Token', 'X-App-Id'],
          captureQueryParams: const ['app_id', 'user_auth_token'],
          inspectWebStorage: true,
          requiredGroups: const [
            [
              'header:x-user-auth-token',
              'query:user_auth_token',
              'cookie:user_auth_token',
              'response:user_auth_token',
              'storage:user_auth_token',
            ],
            [
              'header:x-app-id',
              'query:app_id',
              'cookie:app_id',
              'response:app_id',
              'storage:app_id',
            ],
          ],
          clearSession: clearSession,
        ),
      'apple_music' => WebViewAuthRequest(
          providerKind: kind,
          title: '登入 Apple Music',
          initialUrl: 'https://music.apple.com',
          cookieDomain: 'https://music.apple.com',
          cookieDomainSubstrings: const [
            '.apple.com',
            'apple.com',
            'music.apple.com',
          ],
          requiredHostSubstring: 'music.apple.com',
          excludedUrlSubstrings: const ['idmsa.apple.com', '/auth/'],
          headerUrlSubstrings: const [
            'music.apple.com',
            'amp-api.music.apple.com',
          ],
          captureHeaderNames: const [
            'Media-User-Token',
            'Music-User-Token',
            'Authorization',
          ],
          inspectWebStorage: true,
          requiredGroups: const [
            [
              'header:authorization',
              'storage:developer_token',
              'storage:developerToken',
              'storage:authorization',
            ],
            [
              'header:media-user-token',
              'header:music-user-token',
              'cookie:media-user-token',
              'cookie:music-user-token',
              'storage:media-user-token',
              'storage:music-user-token',
            ],
          ],
          clearSession: clearSession,
        ),
      _ => throw StreamingException('不支援的網頁登入服務：$kind'),
    };
  }
}

/// Captured cookies/headers/query parameters returned by [WebViewAuthService].
class WebViewAuthResult {
  final bool captured;
  final bool cancelled;
  final bool isBlockedByPlatform;
  final bool isNonChromiumDefault;
  final String? detectedBrowserName;
  final String? detectedBrowserPath;
  final String cookieHeader;
  final Map<String, String> cookies;
  final Map<String, String> headers;
  final Map<String, String> queryParams;
  final Map<String, String> storage;
  final Map<String, String> responseValues;
  final String capturedUrl;
  final String? error;

  const WebViewAuthResult({
    required this.captured,
    required this.cancelled,
    this.isBlockedByPlatform = false,
    this.isNonChromiumDefault = false,
    this.detectedBrowserName,
    this.detectedBrowserPath,
    this.cookieHeader = '',
    this.cookies = const {},
    this.headers = const {},
    this.queryParams = const {},
    this.storage = const {},
    this.responseValues = const {},
    this.capturedUrl = '',
    this.error,
  });

  String? header(String name) => _lookupCaseInsensitive(headers, name);

  String? cookie(String name) {
    final direct = cookies[name];
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    return _lookupCaseInsensitive(cookies, name);
  }

  String? queryParam(String name) => _lookupCaseInsensitive(queryParams, name);

  String? storageValue(String name) => _lookupCaseInsensitive(storage, name);

  String? responseValue(String name) =>
      _lookupCaseInsensitive(responseValues, name);

  static String? _lookupCaseInsensitive(Map<String, String> map, String name) {
    final direct = map[name];
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final lower = name.toLowerCase();
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == lower && entry.value.trim().isNotEmpty) {
        return entry.value.trim();
      }
    }
    return null;
  }

  factory WebViewAuthResult.fromMap(Map<Object?, Object?> raw) {
    Map<String, String> readStringMap(Object? val) {
      if (val is! Map) return const {};
      final out = <String, String>{};
      for (final entry in val.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && k.isNotEmpty && v != null && v.isNotEmpty) {
          out[k] = v;
        }
      }
      return out;
    }

    return WebViewAuthResult(
      captured: raw['captured'] == true,
      cancelled: raw['cancelled'] == true,
      isBlockedByPlatform: raw['isBlockedByPlatform'] == true,
      isNonChromiumDefault: raw['isNonChromiumDefault'] == true,
      detectedBrowserName: raw['detectedBrowserName']?.toString(),
      detectedBrowserPath: raw['detectedBrowserPath']?.toString(),
      cookieHeader: raw['cookieHeader']?.toString() ?? '',
      cookies: readStringMap(raw['cookies']),
      headers: readStringMap(raw['headers']),
      queryParams: readStringMap(raw['queryParams']),
      storage: readStringMap(raw['storage']),
      responseValues: readStringMap(raw['responseValues']),
      capturedUrl: raw['capturedUrl']?.toString() ?? '',
      error: raw['error']?.toString(),
    );
  }
}

abstract class WebViewAuthService {
  Future<bool> isWebView2Available();
  Future<WebViewAuthResult> openAuthWindow(WebViewAuthRequest request);
  Future<void> closeAuthWindow();
}

/// Converts a captured [WebViewAuthResult] into the parameter payload expected
/// by the corresponding `StreamingProvider.authenticate(...)`.
Map<String, dynamic> buildAuthParamsFromWebViewResult(
  String kind,
  WebViewAuthResult res,
) {
  switch (kind) {
    case 'youtube_music':
      var cookieStr = res.cookieHeader.trim();
      if (cookieStr.isEmpty && res.cookies.isNotEmpty) {
        cookieStr = res.cookies.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
      }
      if (cookieStr.isEmpty) {
        throw const StreamingException('未擷取到 YouTube Music 工作階段 Cookie');
      }
      return <String, dynamic>{
        'mode': 'cookie',
        'cookie': cookieStr,
      };
    case 'deezer':
      final arl = res.cookie('arl') ?? res.storageValue('arl') ?? '';
      if (arl.isEmpty) {
        throw const StreamingException('未擷取到 Deezer arl Cookie');
      }
      return <String, dynamic>{
        'mode': 'arl',
        'arl': arl,
      };
    case 'tidal':
      final authHeader = res.header('authorization') ?? '';
      final token = _stripBearerPrefix(authHeader);
      final tidalToken = _stripBearerPrefix(res.header('x-tidal-token') ?? '');
      final storageToken = _stripBearerPrefix(
        res.storageValue('access_token') ??
            res.storageValue('oAuthAccessToken') ??
            res.storageValue('token') ??
            res.storageValue('authorization') ??
            res.responseValue('access_token') ??
            res.cookie('access_token') ??
            '',
      );
      final effectiveToken = token.isNotEmpty
          ? token
          : (tidalToken.isNotEmpty ? tidalToken : storageToken);
      if (effectiveToken.isEmpty) {
        throw const StreamingException('未擷取到 Tidal Bearer 授權權杖');
      }
      return <String, dynamic>{
        'mode': 'access_token',
        'access_token': effectiveToken,
      };
    case 'qobuz':
      final userToken = res.header('x-user-auth-token') ??
          res.queryParam('user_auth_token') ??
          res.cookie('user_auth_token') ??
          res.responseValue('user_auth_token') ??
          res.storageValue('user_auth_token') ??
          res.storageValue('userAuthToken') ??
          '';
      final appId = res.header('x-app-id') ??
          res.queryParam('app_id') ??
          res.cookie('app_id') ??
          res.responseValue('app_id') ??
          res.storageValue('app_id') ??
          res.storageValue('appId') ??
          '';
      if (userToken.isEmpty || appId.isEmpty) {
        throw const StreamingException(
          '未擷取到完整的 Qobuz user_auth_token 與 app_id',
        );
      }
      return <String, dynamic>{
        'mode': 'token',
        'user_auth_token': userToken,
        'app_id': appId,
      };
    case 'apple_music':
      final devToken = _stripBearerPrefix(
        res.header('authorization') ??
            res.storageValue('developer_token') ??
            res.storageValue('developerToken') ??
            res.storageValue('authorization') ??
            res.responseValue('developer_token') ??
            '',
      );
      final userToken = res.header('media-user-token') ??
          res.header('music-user-token') ??
          res.cookie('media-user-token') ??
          res.cookie('music-user-token') ??
          res.storageValue('media-user-token') ??
          res.storageValue('music-user-token') ??
          res.storageValue('musicUserToken') ??
          res.responseValue('media-user-token') ??
          '';
      if (devToken.isEmpty || userToken.isEmpty) {
        throw const StreamingException(
          '未擷取到完整的 Apple Music Developer Token 與 Media-User-Token',
        );
      }
      return <String, dynamic>{
        'mode': 'musickit_tokens',
        'developer_token': devToken,
        'music_user_token': userToken,
      };
    default:
      throw StreamingException('不支援的串流服務：$kind');
  }
}

String _stripBearerPrefix(String raw) {
  final trimmed = raw.trim();
  if (trimmed.toLowerCase().startsWith('bearer ')) {
    return trimmed.substring(7).trim();
  }
  return trimmed;
}

/// Production Windows WebView2 implementation backed by `lumina/window`.
class DesktopWebViewAuthService implements WebViewAuthService {
  static const MethodChannel _channel = MethodChannel('lumina/window');

  @override
  Future<bool> isWebView2Available() async {
    if (!Platform.isWindows) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isWebView2Available');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<WebViewAuthResult> openAuthWindow(WebViewAuthRequest request) async {
    if (!Platform.isWindows) {
      return const WebViewAuthResult(
        captured: false,
        cancelled: false,
        error: 'Embedded WebView2 auth is only available on Windows',
      );
    }
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'openWebViewAuth',
        request.toMap(),
      );
      if (raw is Map<Object?, Object?>) {
        return WebViewAuthResult.fromMap(raw);
      }
      return const WebViewAuthResult(
        captured: false,
        cancelled: false,
        error: 'WebView2 回傳無效結果',
      );
    } on MissingPluginException {
      return const WebViewAuthResult(
        captured: false,
        cancelled: false,
        error: 'WebView2 平台通道未就緒',
      );
    } on PlatformException catch (e) {
      return WebViewAuthResult(
        captured: false,
        cancelled: false,
        error: e.message ?? e.code,
      );
    }
  }

  @override
  Future<void> closeAuthWindow() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('closeWebViewAuth');
    } catch (_) {}
  }
}
