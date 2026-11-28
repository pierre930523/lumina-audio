import 'package:flutter/foundation.dart';

/// Normalizes a remote streaming cover URL: trims whitespace, prepends `https:`
/// to protocol-relative `//` URLs, and validates `http://` or `https://` with
/// a non-empty host. Returns `null` for empty or invalid URLs.
String? normalizeStreamingCoverUrl(String? raw) {
  if (raw == null) return null;
  var trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('//')) {
    trimmed = 'https:$trimmed';
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || uri.host.trim().isEmpty) {
    return null;
  }
  return trimmed;
}

final RegExp _googleCoverHostRegex = RegExp(r'^lh\d+\.googleusercontent\.com$');
final RegExp _googleTrailingSizeRegex = RegExp(
  r'=(w\d+-h\d+|s\d+)[^\s?#]*(?=$|[?#])',
  caseSensitive: false,
);
final RegExp _ytLowResPathRegex = RegExp(
  r'^/(?:vi|vi_webp)/([^/?#]+)/((?:default|mqdefault|hqdefault|sddefault)\.(?:jpg|webp))$',
  caseSensitive: false,
);
final RegExp _ytMaxResPathRegex = RegExp(
  r'^/(?:vi|vi_webp)/([^/?#]+)/maxresdefault\.(?:jpg|webp)$',
  caseSensitive: false,
);

const int _maxCoverUpgradeLogCacheEntries = 256;
final Set<String> _coverUpgradeLogCache = <String>{};

/// Clears the deduplicated `[CoverUpgrade]` log cache for unit tests.
@visibleForTesting
void resetCoverUpgradeLogCache() {
  _coverUpgradeLogCache.clear();
}

void _logCoverUpgradeOnce({
  required String fromLabel,
  required String toLabel,
  required String beforeUrl,
  required String afterUrl,
}) {
  final key = '$beforeUrl->$afterUrl';
  if (_coverUpgradeLogCache.contains(key)) return;
  if (_coverUpgradeLogCache.length >= _maxCoverUpgradeLogCacheEntries) {
    _coverUpgradeLogCache.remove(_coverUpgradeLogCache.first);
  }
  _coverUpgradeLogCache.add(key);
  debugPrint('[CoverUpgrade] $fromLabel -> $toLabel | $beforeUrl -> $afterUrl');
}

/// Upgrades a streaming cover URL (YouTube Music / Google CDN or YouTube
/// thumbnail) to the requested [targetSize] (default `1200`) or `maxresdefault`.
String? upgradeStreamingCoverUrl(String? url, {int targetSize = 1200}) {
  final normalized = normalizeStreamingCoverUrl(url);
  if (normalized == null) return null;

  final size = targetSize > 0 ? targetSize : 1200;
  final uri = Uri.tryParse(normalized);
  if (uri == null) return normalized;

  final host = uri.host.toLowerCase();
  var upgraded = normalized;
  var fromLabel = '';
  var toLabel = '';

  if (_googleCoverHostRegex.hasMatch(host) ||
      host == 'yt3.ggpht.com' ||
      host == 'yt3.googleusercontent.com') {
    final sizeMatch = _googleTrailingSizeRegex.firstMatch(normalized);
    if (sizeMatch != null) {
      upgraded = normalized.replaceRange(
        sizeMatch.start,
        sizeMatch.end,
        '=w$size-h$size-l90-rj',
      );
      fromLabel = sizeMatch.group(1)!.toLowerCase();
      toLabel = 'w$size-h$size';
    } else if (!uri.path.contains('=') &&
        uri.query.isEmpty &&
        !normalized.contains('?') &&
        uri.fragment.isEmpty &&
        !normalized.contains('#') &&
        uri.path.isNotEmpty &&
        uri.path != '/' &&
        !uri.path.endsWith('/')) {
      upgraded = '$normalized=w$size-h$size-l90-rj';
      fromLabel = 'raw';
      toLabel = 'w$size-h$size';
    }
  } else if (host == 'i.ytimg.com' || host == 'img.youtube.com') {
    final lowMatch = _ytLowResPathRegex.firstMatch(uri.path);
    if (lowMatch != null) {
      final videoId = lowMatch.group(1)!;
      upgraded = 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg';
      fromLabel = lowMatch.group(2)!.toLowerCase();
      toLabel = 'maxresdefault.jpg';
    } else {
      final maxMatch = _ytMaxResPathRegex.firstMatch(uri.path);
      if (maxMatch != null &&
          (uri.query.isNotEmpty || normalized.contains('?'))) {
        final videoId = maxMatch.group(1)!;
        upgraded = 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg';
        fromLabel = uri.queryParameters.containsKey('sqp')
            ? 'maxresdefault.jpg?sqp'
            : 'maxresdefault.jpg?query';
        toLabel = 'maxresdefault.jpg';
      }
    }
  }

  if (upgraded != normalized) {
    _logCoverUpgradeOnce(
      fromLabel: fromLabel,
      toLabel: toLabel,
      beforeUrl: normalized,
      afterUrl: upgraded,
    );
  }
  return upgraded;
}

/// Returns a fallback cover URL when [failedUrl] fails to load (e.g., 404),
/// preferring [originalUrl] when distinct or downgrading `maxresdefault.jpg`
/// to `hqdefault.jpg`. Returns `null` if no fallback applies.
String? fallbackStreamingCoverUrl(String? failedUrl, {String? originalUrl}) {
  final failedNorm = normalizeStreamingCoverUrl(failedUrl);
  final origNorm = normalizeStreamingCoverUrl(originalUrl);
  if (origNorm != null && origNorm != failedNorm) {
    return origNorm;
  }
  if (failedNorm != null) {
    final uri = Uri.tryParse(failedNorm);
    if (uri != null) {
      final host = uri.host.toLowerCase();
      if (host == 'i.ytimg.com' || host == 'img.youtube.com') {
        final maxMatch = _ytMaxResPathRegex.firstMatch(uri.path);
        if (maxMatch != null) {
          return 'https://i.ytimg.com/vi/${maxMatch.group(1)!}/hqdefault.jpg';
        }
      }
    }
  }
  return null;
}
