part of '../local_browser_auth_service.dart';

const String _webStorageExtractJs = '''
(function(){
  try {
    var out = {};
    function readStore(store, prefix) {
      if (!store) return;
      for (var i = 0; i < store.length; i++) {
        var k = store.key(i);
        if (!k) continue;
        var v = store.getItem(k);
        if (v !== null && v !== undefined) {
          var s = String(v);
          if (s.length > 0 && s.length <= 16384) {
            out[prefix + k] = s;
          }
        }
      }
    }
    readStore(window.localStorage, 'local:');
    readStore(window.sessionStorage, 'session:');
    return JSON.stringify(out);
  } catch (e) {
    return '{}';
  }
})()
''';

List<dynamic>? _extractCookieList(Map<String, dynamic>? resp) {
  if (resp == null) return null;
  if (resp['error'] != null) return null;
  final result = resp['result'];
  if (result is! Map) return null;
  final cookies = result['cookies'];
  return cookies is List ? cookies : null;
}

bool _cookieDomainMatches(String domain, List<String> filters) {
  final rawLower = domain.trim().toLowerCase();
  final normDomain = rawLower.startsWith('.') ? rawLower.substring(1) : rawLower;
  if (normDomain.isEmpty) return false;
  for (final f in filters) {
    final fLower = f.trim().toLowerCase();
    if (fLower.isEmpty) continue;
    final normFilter = fLower.startsWith('.') ? fLower.substring(1) : fLower;
    if (normDomain == normFilter || normDomain.endsWith('.$normFilter')) {
      return true;
    }
  }
  return false;
}

void _extractAuthFieldsIntoMap(
  Map<dynamic, dynamic> node,
  Map<String, String> out, {
  required bool includeRawScalarKeys,
  int depth = 0,
}) {
  if (depth > 5) return;
  for (final entry in node.entries) {
    final key = entry.key?.toString().trim() ?? '';
    final val = entry.value;
    if (key.isEmpty || val == null) continue;
    if (val is Map) {
      _extractAuthFieldsIntoMap(
        val,
        out,
        includeRawScalarKeys: false,
        depth: depth + 1,
      );
    } else if (val is String || val is num) {
      final strVal = val.toString().trim();
      if (strVal.isEmpty || strVal == 'null' || strVal == 'undefined') {
        continue;
      }
      _storeNormalizedAuthKeyValue(
        key,
        strVal,
        out,
        includeRawScalarKey: includeRawScalarKeys,
      );
    }
  }
}

void _storeNormalizedAuthKeyValue(
  String rawKey,
  String val,
  Map<String, String> out, {
  required bool includeRawScalarKey,
}) {
  final lower = rawKey.trim().toLowerCase();
  switch (lower) {
    case 'user_auth_token':
    case 'userauthtoken':
    case 'auth_token':
      out['user_auth_token'] = val;
      break;
    case 'app_id':
    case 'appid':
      out['app_id'] = val;
      break;
    case 'access_token':
    case 'oauthaccesstoken':
    case 'oauth_access_token':
    case 'tidal_access_token':
      out['access_token'] = val;
      break;
    case 'media-user-token':
    case 'media_user_token':
    case 'music-user-token':
    case 'music_user_token':
    case 'musicusertoken':
      out['media-user-token'] = val;
      out['music-user-token'] = val;
      break;
    case 'developer_token':
    case 'developertoken':
      out['developer_token'] = val;
      break;
    case 'authorization':
      out['authorization'] = val;
      break;
    case 'token':
      out['token'] = val;
      break;
    case 'arl':
      out['arl'] = val;
      break;
  }
  if (includeRawScalarKey) {
    out[rawKey] = val;
  }
}

bool _matchesAnySubstring(String url, List<String> needles) {
  if (needles.isEmpty) return false;
  final lower = url.toLowerCase();
  for (final needle in needles) {
    final n = needle.trim().toLowerCase();
    if (n.isNotEmpty && lower.contains(n)) {
      return true;
    }
  }
  return false;
}

bool _hasCookie(Map<String, String> cookies, String name) {
  final direct = cookies[name];
  if (direct != null && direct.trim().isNotEmpty) return true;
  final lower = name.toLowerCase();
  for (final entry in cookies.entries) {
    if (entry.key.toLowerCase() == lower && entry.value.trim().isNotEmpty) {
      return true;
    }
  }
  return false;
}

bool _hasValue(Map<String, String> map, String lowerKey) {
  final direct = map[lowerKey];
  if (direct != null && direct.trim().isNotEmpty) return true;
  for (final entry in map.entries) {
    if (entry.key.toLowerCase() == lowerKey && entry.value.trim().isNotEmpty) {
      return true;
    }
  }
  return false;
}

extension _LocalBrowserCaptureExt on LocalBrowserAuthService {
  Future<void> _pollCookiesForTarget(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) async {
    // 1. Primary: Storage.getCookies (full-domain cookies including HttpOnly)
    var rawCookies = _extractCookieList(
      await target.sendCommandSafe(
        'Storage.getCookies',
        params: const <String, dynamic>{},
        timeout: const Duration(milliseconds: 900),
      ),
    );
    if (session.isDone || session.cleaningUp) return;

    // 2. Fallback: Network.getAllCookies
    if (rawCookies == null || rawCookies.isEmpty) {
      rawCookies = _extractCookieList(
        await target.sendCommandSafe(
          'Network.getAllCookies',
          params: const <String, dynamic>{},
          timeout: const Duration(milliseconds: 900),
        ),
      );
      if (session.isDone || session.cleaningUp) return;
    }

    // 3. Fallback: Network.getCookies scoped to targetDomain
    if (rawCookies == null || rawCookies.isEmpty) {
      final targetDomain =
          session.request.cookieDomain ?? session.request.initialUrl;
      rawCookies = _extractCookieList(
        await target.sendCommandSafe(
          'Network.getCookies',
          params: <String, dynamic>{
            'urls': <String>[targetDomain],
          },
          timeout: const Duration(milliseconds: 900),
        ),
      );
      if (session.isDone || session.cleaningUp) return;
    }

    if (rawCookies == null) return;

    final domainFilters = session.request.cookieDomainSubstrings;
    final nextCookies = <String, String>{};
    final cookieParts = <String>[];
    for (final item in rawCookies) {
      if (item is Map) {
        final name = item['name']?.toString().trim() ?? '';
        final value = item['value']?.toString() ?? '';
        if (name.isEmpty || value.isEmpty) continue;
        final domain = item['domain']?.toString().trim() ?? '';
        if (domain.isNotEmpty &&
            domainFilters.isNotEmpty &&
            !_cookieDomainMatches(domain, domainFilters)) {
          continue;
        }
        nextCookies[name] = value;
        cookieParts.add('$name=$value');
      }
    }
    if (nextCookies.isNotEmpty) {
      session.capturedCookies
        ..clear()
        ..addAll(nextCookies);
      session.cookieHeader = cookieParts.join('; ');
    }
  }

  Future<void> _pollWebStorageForTarget(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) async {
    final resp = await target.sendCommandSafe(
      'Runtime.evaluate',
      params: <String, dynamic>{
        'expression': _webStorageExtractJs,
        'returnByValue': true,
      },
      timeout: const Duration(milliseconds: 900),
    );
    if (resp == null || session.isDone || session.cleaningUp) return;
    final result = resp['result'];
    if (result is! Map) return;
    final inner = result['result'];
    final rawVal = inner is Map ? inner['value']?.toString() : null;
    if (rawVal == null) return;
    final trimmed = rawVal.trim();
    if (!trimmed.startsWith('{')) return;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        var key = entry.key?.toString().trim() ?? '';
        final val = entry.value?.toString().trim() ?? '';
        if (key.isEmpty || val.isEmpty || val == 'null' || val == 'undefined') {
          continue;
        }
        if (key.startsWith('local:')) {
          key = key.substring(6);
        } else if (key.startsWith('session:')) {
          key = key.substring(8);
        }
        if (key.isEmpty) continue;
        if (val.startsWith('{')) {
          try {
            final nested = jsonDecode(val);
            if (nested is Map) {
              _extractAuthFieldsIntoMap(
                nested,
                session.capturedStorage,
                includeRawScalarKeys: false,
              );
              continue;
            }
          } catch (_) {}
        }
        _storeNormalizedAuthKeyValue(
          key,
          val,
          session.capturedStorage,
          includeRawScalarKey: true,
        );
      }
    } catch (_) {
      // Ignore malformed storage JSON.
    }
  }

  void _captureHeadersFromMap(_BrowserAuthSession session, dynamic rawHeaders) {
    if (rawHeaders is! Map || session.request.captureHeaderNames.isEmpty) {
      return;
    }
    final wanted =
        session.request.captureHeaderNames.map((e) => e.toLowerCase()).toSet();
    for (final entry in rawHeaders.entries) {
      final k = entry.key?.toString().trim() ?? '';
      final v = entry.value?.toString().trim() ?? '';
      if (k.isEmpty || v.isEmpty) continue;
      final lower = k.toLowerCase();
      if (wanted.contains(lower)) {
        session.capturedHeaders[lower] = v;
      }
    }
  }

  void _captureQueryParamsFromUrl(_BrowserAuthSession session, String rawUrl) {
    if (session.request.captureQueryParams.isEmpty) return;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.queryParameters.isEmpty) return;
    final wanted =
        session.request.captureQueryParams.map((e) => e.toLowerCase()).toSet();
    for (final entry in uri.queryParameters.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      final lower = k.toLowerCase();
      if (wanted.contains(lower)) {
        session.capturedQueryParams[lower] = v;
      }
    }
  }

  void _capturePostDataParams(_BrowserAuthSession session, dynamic rawPostData) {
    if (session.request.captureQueryParams.isEmpty) return;
    final postData = rawPostData?.toString().trim() ?? '';
    if (postData.isEmpty) return;
    final wanted =
        session.request.captureQueryParams.map((e) => e.toLowerCase()).toSet();
    if (postData.startsWith('{')) {
      try {
        final parsed = jsonDecode(postData);
        if (parsed is Map) {
          for (final entry in parsed.entries) {
            final k = entry.key?.toString().trim() ?? '';
            final v = entry.value?.toString().trim() ?? '';
            final lower = k.toLowerCase();
            if (k.isNotEmpty && v.isNotEmpty && wanted.contains(lower)) {
              session.capturedQueryParams[lower] = v;
            }
          }
        }
      } catch (_) {}
      return;
    }
    try {
      final parsedForm = Uri.splitQueryString(postData);
      for (final entry in parsedForm.entries) {
        final k = entry.key.trim();
        final v = entry.value.trim();
        final lower = k.toLowerCase();
        if (k.isNotEmpty && v.isNotEmpty && wanted.contains(lower)) {
          session.capturedQueryParams[lower] = v;
        }
      }
    } catch (_) {}
  }

  void _evaluateAllTargets(_BrowserAuthSession session) {
    if (session.isDone || session.cleaningUp) return;
    final satisfied = LocalBrowserAuthService.isCaptureSatisfied(
      request: session.request,
      cookies: session.capturedCookies,
      headers: session.capturedHeaders,
      queryParams: session.capturedQueryParams,
      responseValues: session.capturedResponseValues,
      storage: session.capturedStorage,
    );
    if (!satisfied) return;

    for (final target in session.attachedTargets.values) {
      final url = target.currentUrl;
      if (LocalBrowserAuthService.matchesUrlGuard(url, session.request)) {
        session.completeCaptured(url);
        return;
      }
    }

    // If a matched 200 API response already delivered complete tokens while the
    // tab is still on the host, accept capture cleanly.
    if (session.capturedResponseValues.isNotEmpty) {
      final requiredHost =
          session.request.requiredHostSubstring?.trim().toLowerCase() ?? '';
      for (final target in session.attachedTargets.values) {
        final url = target.currentUrl.trim();
        if (url.isNotEmpty &&
            (requiredHost.isEmpty ||
                url.toLowerCase().contains(requiredHost))) {
          session.completeCaptured(url);
          return;
        }
      }
    }
  }
}
