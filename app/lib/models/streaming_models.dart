import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'playback_state.dart';

/// Authentication lifecycle state for a real streaming music provider.
enum StreamingAuthState {
  disconnected,
  authenticating,
  connected,
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

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'artist': artist,
    if (year != null) 'year': year,
    if (coverUrl != null) 'cover_url': coverUrl,
    'provider_kind': providerKind,
    if (trackCount != null) 'track_count': trackCount,
    if (qualityLabel != null) 'quality_label': qualityLabel,
  };

  factory StreamingAlbum.fromJson(Map<String, dynamic> json) {
    return StreamingAlbum(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名專輯',
      artist: json['artist']?.toString() ?? '未知藝術家',
      year: (json['year'] as num?)?.toInt(),
      coverUrl: json['cover_url']?.toString(),
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

  static Map<String, dynamic> trackToJson(TrackInfo t) => <String, dynamic>{
    'id': t.id,
    'title': t.title,
    'artist': t.artist,
    'album': t.album,
    'duration_ms': t.duration.inMilliseconds,
    if (t.albumArtUrl != null) 'album_art_url': t.albumArtUrl,
    if (t.coverUrl != null) 'cover_url': t.coverUrl,
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
    },
  };

  static TrackInfo trackFromJson(Map<String, dynamic> json) {
    final fmtMap = json['format'] is Map
        ? Map<String, dynamic>.from(json['format'] as Map)
        : const <String, dynamic>{};
    final cover =
        json['cover_url']?.toString() ?? json['album_art_url']?.toString();
    return TrackInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名曲目',
      artist: json['artist']?.toString() ?? '未知藝術家',
      album: json['album']?.toString() ?? '',
      duration: Duration(
        milliseconds: (json['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      albumArtUrl: cover,
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

  const ResolvedStreamResult({
    required this.url,
    this.headers = const {},
    this.hintExtension,
    required this.format,
    this.isPreviewOnly = false,
    this.drmNotice,
    this.externalWebUrl,
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

/// Structured exception thrown when real streaming API authentication, sync,
/// or stream resolution fails.
class StreamingException implements Exception {
  final String message;
  final int? statusCode;
  final bool isTokenExpired;
  final bool isDrmRestricted;
  final bool isCancelled;
  final bool isWebViewUnavailable;

  const StreamingException(
    this.message, {
    this.statusCode,
    this.isTokenExpired = false,
    this.isDrmRestricted = false,
    this.isCancelled = false,
    this.isWebViewUnavailable = false,
  });

  @override
  String toString() => statusCode != null
      ? 'StreamingException($statusCode): $message'
      : 'StreamingException: $message';
}
