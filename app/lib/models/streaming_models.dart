import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'playback_state.dart';

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

/// Authentication lifecycle state for a real streaming music provider.
enum StreamingAuthState {
  disconnected,
  authenticating,
  connected,
  authRequired,
  error,
}

/// Authenticated account profile and subscription metadata returned by a provider API.
class StreamingAccountInfo {
  final String displayName;
  final String? planTier;
  final String? userId;
  final String? email;
  final String? countryCode;
  final DateTime? expiresAt;
  final String? drmNotice;

  const StreamingAccountInfo({
    required this.displayName,
    this.planTier,
    this.userId,
    this.email,
    this.countryCode,
    this.expiresAt,
    this.drmNotice,
  });

  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp);
  }

  StreamingAccountInfo copyWith({
    String? displayName,
    String? planTier,
    String? userId,
    String? email,
    String? countryCode,
    DateTime? expiresAt,
    String? drmNotice,
  }) {
    return StreamingAccountInfo(
      displayName: displayName ?? this.displayName,
      planTier: planTier ?? this.planTier,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      countryCode: countryCode ?? this.countryCode,
      expiresAt: expiresAt ?? this.expiresAt,
      drmNotice: drmNotice ?? this.drmNotice,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'display_name': displayName,
    if (planTier != null) 'plan_tier': planTier,
    if (userId != null) 'user_id': userId,
    if (email != null) 'email': email,
    if (countryCode != null) 'country_code': countryCode,
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    if (drmNotice != null) 'drm_notice': drmNotice,
  };

  factory StreamingAccountInfo.fromJson(Map<String, dynamic> json) {
    final rawExpiry = json['expires_at']?.toString();
    return StreamingAccountInfo(
      displayName: json['display_name']?.toString() ?? '已登入帳號',
      planTier: json['plan_tier']?.toString(),
      userId: json['user_id']?.toString(),
      email: json['email']?.toString(),
      countryCode: json['country_code']?.toString(),
      expiresAt: rawExpiry != null && rawExpiry.isNotEmpty
          ? DateTime.tryParse(rawExpiry)
          : null,
      drmNotice: json['drm_notice']?.toString(),
    );
  }
}

/// Playlist fetched from a streaming service API.
class StreamingPlaylist {
  final String id;
  final String title;
  final String? description;
  final int trackCount;
  final String? coverUrl;
  final String providerKind;
  final List<TrackInfo> tracks;

  const StreamingPlaylist({
    required this.id,
    required this.title,
    this.description,
    this.trackCount = 0,
    this.coverUrl,
    required this.providerKind,
    this.tracks = const [],
  });

  StreamingPlaylist copyWith({
    String? id,
    String? title,
    String? description,
    int? trackCount,
    String? coverUrl,
    String? providerKind,
    List<TrackInfo>? tracks,
  }) {
    return StreamingPlaylist(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      trackCount: trackCount ?? this.trackCount,
      coverUrl: coverUrl ?? this.coverUrl,
      providerKind: providerKind ?? this.providerKind,
      tracks: tracks ?? this.tracks,
    );
  }
}

/// Album fetched from a streaming service API.
class StreamingAlbum {
  final String id;
  final String title;
  final String artist;
  final int? year;
  final String? coverUrl;
  final String providerKind;
  final int? trackCount;
  final String? qualityLabel;

  const StreamingAlbum({
    required this.id,
    required this.title,
    required this.artist,
    this.year,
    this.coverUrl,
    required this.providerKind,
    this.trackCount,
    this.qualityLabel,
  });

  Map<String, dynamic> toJson() {
    final normCover = normalizeStreamingCoverUrl(coverUrl);
    return <String, dynamic>{
      'id': id,
      'title': title,
      'artist': artist,
      if (year != null) 'year': year,
      'cover_url': ?normCover,
      'provider_kind': providerKind,
      if (trackCount != null) 'track_count': trackCount,
      if (qualityLabel != null) 'quality_label': qualityLabel,
    };
  }

  factory StreamingAlbum.fromJson(Map<String, dynamic> json) {
    return StreamingAlbum(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名專輯',
      artist: json['artist']?.toString() ?? '未知藝術家',
      year: (json['year'] as num?)?.toInt(),
      coverUrl: upgradeStreamingCoverUrl(json['cover_url']?.toString()),
      providerKind: json['provider_kind']?.toString() ?? 'tidal',
      trackCount: (json['track_count'] as num?)?.toInt(),
      qualityLabel: json['quality_label']?.toString(),
    );
  }
}

/// Personalized recommendation snapshot fetched from a streaming provider's real API.
class StreamingRecommendations {
  final String providerKind;
  final List<StreamingAlbum> albums;
  final List<TrackInfo> tracks;
  final DateTime fetchedAt;
  final String? errorMessage;
  final bool isTokenExpired;

  StreamingRecommendations({
    required this.providerKind,
    this.albums = const [],
    this.tracks = const [],
    DateTime? fetchedAt,
    this.errorMessage,
    this.isTokenExpired = false,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  factory StreamingRecommendations.empty(String providerKind) =>
      StreamingRecommendations(
        providerKind: providerKind,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  bool get isEmpty => albums.isEmpty && tracks.isEmpty;

  bool get hasError =>
      errorMessage != null && errorMessage!.trim().isNotEmpty;

  StreamingRecommendations copyWith({
    String? providerKind,
    List<StreamingAlbum>? albums,
    List<TrackInfo>? tracks,
    DateTime? fetchedAt,
    String? errorMessage,
    bool clearError = false,
    bool? isTokenExpired,
  }) {
    return StreamingRecommendations(
      providerKind: providerKind ?? this.providerKind,
      albums: albums ?? this.albums,
      tracks: tracks ?? this.tracks,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isTokenExpired: isTokenExpired ?? this.isTokenExpired,
    );
  }

  static Map<String, dynamic> trackToJson(TrackInfo t) {
    final normAlbumArt = normalizeStreamingCoverUrl(t.albumArtUrl);
    final normCover = normalizeStreamingCoverUrl(t.coverUrl);
    return <String, dynamic>{
      'id': t.id,
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'duration_ms': t.duration.inMilliseconds,
      'album_art_url': ?normAlbumArt,
      'cover_url': ?normCover,
      'provider_name': t.providerName,
      if (t.albumArtist != null) 'album_artist': t.albumArtist,
      if (t.year != null) 'year': t.year,
      if (t.trackNumber != null) 'track_number': t.trackNumber,
      if (t.discNumber != null) 'disc_number': t.discNumber,
      'format': <String, dynamic>{
        'codec': t.format.codec.name,
        'sample_rate_hz': t.format.sampleRateHz,
        'bit_depth': t.format.bitDepth,
        'channels': t.format.channels,
        'is_dsd': t.format.isDsd,
        if (t.format.bitrateKbps != null) 'bitrate_kbps': t.format.bitrateKbps,
      },
    };
  }

  static TrackInfo trackFromJson(Map<String, dynamic> json) {
    final fmtMap = json['format'] is Map
        ? Map<String, dynamic>.from(json['format'] as Map)
        : const <String, dynamic>{};
    final cover = upgradeStreamingCoverUrl(json['cover_url']?.toString()) ??
        upgradeStreamingCoverUrl(json['album_art_url']?.toString());
    final albumArt =
        upgradeStreamingCoverUrl(json['album_art_url']?.toString()) ?? cover;
    return TrackInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名曲目',
      artist: json['artist']?.toString() ?? '未知藝術家',
      album: json['album']?.toString() ?? '',
      duration: Duration(
        milliseconds: (json['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      albumArtUrl: albumArt,
      coverUrl: cover,
      providerName: json['provider_name']?.toString() ?? 'Streaming',
      albumArtist: json['album_artist']?.toString(),
      year: (json['year'] as num?)?.toInt(),
      trackNumber: (json['track_number'] as num?)?.toInt(),
      discNumber: (json['disc_number'] as num?)?.toInt(),
      format: AudioFormat(
        codec: AudioCodec.fromString(fmtMap['codec']?.toString()),
        sampleRateHz: (fmtMap['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (fmtMap['bit_depth'] as num?)?.toInt() ?? 16,
        channels: (fmtMap['channels'] as num?)?.toInt() ?? 2,
        isDsd: fmtMap['is_dsd'] == true,
        bitrateKbps:
            (fmtMap['bitrate_kbps'] as num?)?.toInt() ??
            (fmtMap['bitrateKbps'] as num?)?.toInt(),
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider_kind': providerKind,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'albums': albums.map((a) => a.toJson()).toList(),
    'tracks': tracks.map(trackToJson).toList(),
  };

  factory StreamingRecommendations.fromJson(Map<String, dynamic> json) {
    final rawAlbums = json['albums'] as List<dynamic>? ?? const [];
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    final rawFetched = json['fetched_at']?.toString();
    return StreamingRecommendations(
      providerKind: json['provider_kind']?.toString() ?? 'tidal',
      fetchedAt: (rawFetched != null && rawFetched.isNotEmpty)
          ? (DateTime.tryParse(rawFetched)?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0))
          : DateTime.fromMillisecondsSinceEpoch(0),
      albums: rawAlbums
          .whereType<Map>()
          .map((e) => StreamingAlbum.fromJson(Map<String, dynamic>.from(e)))
          .where((a) => a.id.isNotEmpty)
          .toList(),
      tracks: rawTracks
          .whereType<Map>()
          .map((e) => trackFromJson(Map<String, dynamic>.from(e)))
          .where((t) => t.id.isNotEmpty)
          .toList(),
    );
  }
}

/// Synchronized or search-returned catalog snapshot from a streaming service.
class StreamingCatalog {
  final List<TrackInfo> tracks;
  final List<StreamingPlaylist> playlists;
  final List<StreamingAlbum> albums;
  final DateTime syncedAt;

  StreamingCatalog({
    this.tracks = const [],
    this.playlists = const [],
    this.albums = const [],
    DateTime? syncedAt,
  }) : syncedAt = syncedAt ?? DateTime.now();

  factory StreamingCatalog.empty() => StreamingCatalog(
    syncedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  bool get isEmpty => tracks.isEmpty && playlists.isEmpty && albums.isEmpty;
}

/// Direct playable HTTP stream metadata resolved from a provider API.
class ResolvedStreamResult {
  final String url;
  final Map<String, String> headers;
  final String? hintExtension;
  final AudioFormat format;
  final bool isPreviewOnly;
  final String? drmNotice;
  final String? externalWebUrl;
  final String? engineRoute;
  final String? videoId;

  const ResolvedStreamResult({
    required this.url,
    this.headers = const {},
    this.hintExtension,
    required this.format,
    this.isPreviewOnly = false,
    this.drmNotice,
    this.externalWebUrl,
    this.engineRoute,
    this.videoId,
  });
}

/// Cooperative cancellation token for multi-step OAuth / polling / sync flows.
class CancellationToken {
  bool _cancelled = false;
  final List<VoidCallback> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final snapshot = List<VoidCallback>.from(_listeners);
    _listeners.clear();
    for (final cb in snapshot) {
      try {
        cb();
      } catch (_) {}
    }
  }

  void addListener(VoidCallback cb) {
    if (_cancelled) {
      cb();
      return;
    }
    _listeners.add(cb);
  }

  void removeListener(VoidCallback cb) {
    _listeners.remove(cb);
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const StreamingException('操作已取消', isCancelled: true);
    }
  }
}

/// Structured error classification for streaming authentication, catalog sync,
/// and lazy stream URL resolution failures.
enum StreamingErrorKind {
  unknown,
  network,
  authExpired,
  drmRestricted,
  regionRestricted,
  trackUnavailable,
  rateLimited,
  cancelled,
  webViewUnavailable,
}

/// Structured exception thrown when real streaming API authentication, sync,
/// or stream resolution fails.
class StreamingException implements Exception {
  final String message;
  final int? statusCode;
  final bool isTokenExpired;
  final bool isDrmRestricted;
  final bool isCancelled;
  final bool isWebViewUnavailable;
  final StreamingErrorKind? _explicitKind;

  const StreamingException(
    this.message, {
    this.statusCode,
    this.isTokenExpired = false,
    this.isDrmRestricted = false,
    this.isCancelled = false,
    this.isWebViewUnavailable = false,
    StreamingErrorKind? kind,
  }) : _explicitKind = kind;

  /// Effective error classification, inferred from existing flags/statusCode
  /// when [kind] was not explicitly supplied.
  StreamingErrorKind get kind {
    final explicit = _explicitKind;
    if (explicit != null) return explicit;
    if (isCancelled) return StreamingErrorKind.cancelled;
    if (isWebViewUnavailable) return StreamingErrorKind.webViewUnavailable;
    if (isTokenExpired || statusCode == 401) {
      return StreamingErrorKind.authExpired;
    }
    if (statusCode == 451) return StreamingErrorKind.regionRestricted;
    if (statusCode == 429) return StreamingErrorKind.rateLimited;
    if (isDrmRestricted) return StreamingErrorKind.drmRestricted;
    if (statusCode == 404 || statusCode == 410) {
      return StreamingErrorKind.trackUnavailable;
    }
    return StreamingErrorKind.unknown;
  }

  bool get isRegionRestricted => kind == StreamingErrorKind.regionRestricted;

  bool get isUnavailable => kind == StreamingErrorKind.trackUnavailable;

  static final RegExp _regionPattern = RegExp(
    r'(geo[\s_-]?block|geo[\s_-]?restrict|region[\s_-]?restrict|'
    r'not\s+(?:made\s+this\s+video\s+)?available\s+in\s+your\s+(?:country|region|territory|location)|'
    r'unavailable\s+in\s+your\s+(?:country|region|territory|location)|'
    r'country[\s_-]?block|country[\s_-]?restrict|notavailableincountry|'
    r'territory[\s_-]?restrict|not\s+available\s+in\s+this\s+storefront|'
    r'blocked\s+in\s+your\s+country|地區限制|區域限制)',
    caseSensitive: false,
  );

  static final RegExp _unavailablePattern = RegExp(
    r'(takedown|taken\s+down|copyright\s+(?:claim|strike|removal)|'
    r'video\s+unavailable|track\s+unavailable|song\s+unavailable|'
    r'track\s+not\s+found|no\s+longer\s+available|has\s+been\s+removed|'
    r'removed\s+by\s+the\s+uploader|private\s+video|account\s+associated\s+with\s+this\s+video\s+has\s+been\s+terminated|'
    r'deleted\s+track|asset\s+not\s+ready\s+for\s+playback|not\s+streamable|'
    r'streamnotallowed|trackrestrictedbyrightholders|rights_error|data_error|no\s+data|'
    r'已下架|無法播放此曲目)',
    caseSensitive: false,
  );

  /// Classifies HTTP status codes and API error strings into a structured
  /// [StreamingErrorKind] for region-blocking, takedowns, and rate limits.
  static StreamingErrorKind? classifyKind({
    int? statusCode,
    String? message,
    bool isDrmRestricted = false,
  }) {
    if (statusCode == 451) return StreamingErrorKind.regionRestricted;
    final text = message?.trim() ?? '';
    if (text.isNotEmpty && _regionPattern.hasMatch(text)) {
      return StreamingErrorKind.regionRestricted;
    }
    if (statusCode == 404 || statusCode == 410) {
      return StreamingErrorKind.trackUnavailable;
    }
    if (text.isNotEmpty && _unavailablePattern.hasMatch(text)) {
      return StreamingErrorKind.trackUnavailable;
    }
    if (statusCode == 429) return StreamingErrorKind.rateLimited;
    if (isDrmRestricted) return StreamingErrorKind.drmRestricted;
    return null;
  }

  @override
  String toString() => statusCode != null
      ? 'StreamingException($statusCode): $message'
      : 'StreamingException: $message';
}
