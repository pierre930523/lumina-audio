part of '../ytm_resident_resolver.dart';

/// Optional authenticated YouTube Music credentials supplied to
/// [YtmResidentResolver] for its final `WEB_REMIX` fallback leg.
@immutable
class YtmAuthCredentials {
  final String authMode;
  final String? cookie;
  final String? accessToken;
  final String? visitorData;

  const YtmAuthCredentials({
    this.authMode = 'cookie',
    this.cookie,
    this.accessToken,
    this.visitorData,
  });

  bool get hasUsableWebRemixAuth {
    if (authMode == 'oauth' || authMode == 'oauth_device') {
      return accessToken != null && accessToken!.trim().isNotEmpty;
    }
    final rawCookie = cookie?.trim() ?? '';
    if (rawCookie.isEmpty) return false;
    return YtmResidentResolver.extractSapisidFromCookie(rawCookie) != null;
  }

  /// Stable non-secret session binding key for Session-level GVS PO Tokens.
  String? get sessionBindingKey {
    if (authMode == 'oauth' || authMode == 'oauth_device') {
      final tok = accessToken?.trim();
      if (tok != null && tok.isNotEmpty) {
        return 'oauth:${sha256.convert(utf8.encode(tok)).toString().substring(0, 24)}';
      }
    }
    final rawCookie = cookie?.trim();
    if (rawCookie != null && rawCookie.isNotEmpty) {
      final sapisid = YtmResidentResolver.extractSapisidFromCookie(rawCookie);
      if (sapisid != null && sapisid.isNotEmpty) {
        return 'cookie:${sha256.convert(utf8.encode(sapisid)).toString().substring(0, 24)}';
      }
    }
    final vd = visitorData?.trim();
    if (vd != null && vd.isNotEmpty) {
      return vd;
    }
    return null;
  }
}

/// Raw HTTP response returned by an injected InnerTube transport handler.
@immutable
class YtmPlayerHttpResponse {
  final int statusCode;
  final String body;

  const YtmPlayerHttpResponse({
    required this.statusCode,
    required this.body,
  });
}

typedef YtmPlayerRequestHandler = Future<YtmPlayerHttpResponse> Function({
  required Uri uri,
  required Map<String, String> headers,
  required Map<String, dynamic> body,
  CancellationToken? cancelToken,
});

/// Pluggable fallback resolver invoked only when resident InnerTube clients
/// fail or return cipher-protected (`signatureCipher` / `n`-parameter) formats.
///
/// Backed by bundled `yt-dlp` + `deno` JS Runtime in production (never fragile
/// hand-rolled regex scraping of `base.js`).
typedef YtmFallbackStreamResolver = Future<DirectRangeSpec?> Function({
  required StreamKey key,
  required String videoId,
  required YtmAuthCredentials? auth,
  required PoToken? gvsToken,
  required PoToken? playerToken,
  required String? visitorData,
  CancellationToken? cancelToken,
});

class _ResidentClientProfile {
  final String clientName;
  final String clientNameHeader;
  final String clientVersion;
  final String userAgent;
  final bool isWebRemix;
  final bool isAuthenticated;
  final bool supportsPlayerPoToken;
  final Map<String, dynamic> context;

  const _ResidentClientProfile({
    required this.clientName,
    required this.clientNameHeader,
    required this.clientVersion,
    required this.userAgent,
    this.isWebRemix = false,
    this.isAuthenticated = false,
    this.supportsPlayerPoToken = false,
    required this.context,
  });
}
