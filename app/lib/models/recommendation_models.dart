import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'playback_state.dart';
import 'streaming_models.dart';

/// Converts full-width ASCII variants (`U+FF01..U+FF5E`) and full-width spaces
/// (`U+3000`, `U+00A0`) into standard ASCII while collapsing consecutive spaces.
String normalizeWidthPreserveCase(String input) {
  if (input.isEmpty) return '';
  final sb = StringBuffer();
  var prevSpace = true;
  for (final rune in input.runes) {
    final int mapped;
    if (rune == 0x3000 || rune == 0x00A0 || rune == 0x09 || rune == 0x0A || rune == 0x0D) {
      mapped = 0x20;
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      mapped = rune - 0xFEE0;
    } else {
      mapped = rune;
    }
    if (mapped == 0x20) {
      if (!prevSpace) {
        sb.writeCharCode(0x20);
        prevSpace = true;
      }
    } else {
      sb.writeCharCode(mapped);
      prevSpace = false;
    }
  }
  final result = sb.toString();
  if (result.endsWith(' ')) {
    return result.substring(0, result.length - 1);
  }
  return result;
}

final RegExp _featuringSuffixRegex = RegExp(
  r'(?:\s*[\(\[\{]\s*|\s+)(?:feat\.|ft\.|featuring|feat|ft)(?=[\s:\.\)\]\}]|$).*$',
  caseSensitive: false,
);

final RegExp _collabDelimiterRegex = RegExp(
  r'\s*(?:&|,|×|·|;|、|\s+[xX]\s+)\s*',
);

/// Extracts the primary artist in display casing by stripping featuring credits
/// first and then splitting on collaborative artist delimiters.
String extractPrimaryArtistDisplay(String artist) {
  final normalized = normalizeWidthPreserveCase(artist);
  if (normalized.isEmpty) return '';

  var candidate = normalized.replaceFirst(_featuringSuffixRegex, '').trim();
  if (candidate.isEmpty) {
    candidate = normalized;
  }

  final parts = candidate.split(_collabDelimiterRegex);
  if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
    return parts.first.trim();
  }
  return candidate;
}

/// Canonical cross-provider track representation for Autoplay, Track Radio,
/// Personalized Feeds, and Cross-Platform Track Matching.
@immutable
class TrackMetadata {
  final String providerId;
  final String trackId;
  final String title;
  final String artist;
  final String primaryArtist;
  final String album;
  final int durationMs;
  final String? isrc;
  final String? qualityLabel;
  final String? coverUrl;
  final AudioFormat format;
  final String? artistId;
  final String? filePath;
  final String providerName;

  const TrackMetadata({
    required this.providerId,
    required this.trackId,
    required this.title,
    required this.artist,
    String? primaryArtist,
    this.album = '',
    this.durationMs = 0,
    this.isrc,
    this.qualityLabel,
    this.coverUrl,
    this.format = const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    this.artistId,
    this.filePath,
    String? providerName,
  })  : primaryArtist = primaryArtist ?? artist,
        providerName = providerName ?? providerId;

  static const List<({String prefix, String providerId})> _knownIdPrefixes = [
    (prefix: 'streaming:youtube_music:', providerId: 'youtube_music'),
    (prefix: 'youtube_music:', providerId: 'youtube_music'),
    (prefix: 'ytm:', providerId: 'youtube_music'),
    (prefix: 'ytm_', providerId: 'youtube_music'),
    (prefix: 'streaming:tidal:', providerId: 'tidal'),
    (prefix: 'tidal:', providerId: 'tidal'),
    (prefix: 'streaming:qobuz:', providerId: 'qobuz'),
    (prefix: 'qobuz:', providerId: 'qobuz'),
    (prefix: 'streaming:deezer:', providerId: 'deezer'),
    (prefix: 'deezer:', providerId: 'deezer'),
    (prefix: 'streaming:apple_music:', providerId: 'apple_music'),
    (prefix: 'apple_music:', providerId: 'apple_music'),
    (prefix: 'apple:', providerId: 'apple_music'),
    (prefix: 'streaming:podcast_rss:', providerId: 'podcast_rss'),
    (prefix: 'podcast_rss:', providerId: 'podcast_rss'),
    (prefix: 'rss:', providerId: 'podcast_rss'),
    (prefix: 'local:', providerId: 'local'),
  ];

  static String _inferProviderFromName(String providerName) {
    final trimmed = providerName.trim();
    final lower = trimmed.toLowerCase();
    if (lower.contains('youtube') ||
        lower.contains('yt music') ||
        lower == 'ytm') {
      return 'youtube_music';
    }
    if (lower.contains('tidal')) return 'tidal';
    if (lower.contains('qobuz')) return 'qobuz';
    if (lower.contains('deezer')) return 'deezer';
    if (lower.contains('apple')) return 'apple_music';
    if (lower.contains('podcast')) return 'podcast_rss';
    if (lower.contains('local') || lower.contains('本機')) return 'local';
    return trimmed.isNotEmpty ? trimmed : 'local';
  }

  /// Builds a [TrackMetadata] from a [TrackInfo], inferring canonical [providerId]
  /// and clean [trackId] when [providerIdOverride] is omitted.
  factory TrackMetadata.fromTrackInfo(
    TrackInfo track, {
    String? providerIdOverride,
  }) {
    final rawId = track.id.trim();
    final lowerId = rawId.toLowerCase();
    final fp = track.filePath?.trim();
    final hasFilePath = fp != null && fp.isNotEmpty;

    String? matchedPrefix;
    String? prefixProviderId;
    for (final entry in _knownIdPrefixes) {
      if (lowerId.startsWith(entry.prefix)) {
        matchedPrefix = entry.prefix;
        prefixProviderId = entry.providerId;
        break;
      }
    }

    final String resolvedProviderId;
    if (providerIdOverride != null && providerIdOverride.trim().isNotEmpty) {
      resolvedProviderId = providerIdOverride.trim();
    } else if (hasFilePath) {
      resolvedProviderId = 'local';
    } else if (prefixProviderId != null) {
      resolvedProviderId = prefixProviderId;
    } else {
      resolvedProviderId = _inferProviderFromName(track.providerName);
    }

    String resolvedTrackId;
    if (matchedPrefix != null) {
      resolvedTrackId = rawId.substring(matchedPrefix.length).trim();
    } else {
      resolvedTrackId = rawId;
    }
    if (resolvedTrackId.isEmpty && hasFilePath) {
      resolvedTrackId = fp;
    }

    final primary = extractPrimaryArtistDisplay(track.artist);
    return TrackMetadata(
      providerId: resolvedProviderId,
      trackId: resolvedTrackId,
      title: track.title,
      artist: track.artist,
      primaryArtist: primary.isNotEmpty ? primary : track.artist,
      album: track.album,
      durationMs: track.duration.inMilliseconds < 0
          ? 0
          : track.duration.inMilliseconds,
      isrc: track.isrc,
      qualityLabel: track.qualityLabel,
      coverUrl: track.artworkUrl ?? track.coverUrl,
      format: track.format,
      artistId: track.artistId,
      filePath: track.filePath,
      providerName: track.providerName,
    );
  }

  String _toTrackInfoId() {
    if (providerId == 'local' || (filePath != null && filePath!.trim().isNotEmpty)) {
      if (trackId.isNotEmpty) return trackId;
      return filePath ?? '';
    }
    final prefix = switch (providerId) {
      'youtube_music' => 'ytm:',
      'apple_music' => 'apple:',
      'tidal' => 'tidal:',
      'qobuz' => 'qobuz:',
      'deezer' => 'deezer:',
      'podcast_rss' => 'podcast_rss:',
      _ => null,
    };
    if (prefix == null) return trackId;
    final lower = trackId.toLowerCase();
    for (final entry in _knownIdPrefixes) {
      if (entry.providerId == providerId && lower.startsWith(entry.prefix)) {
        return trackId;
      }
    }
    return '$prefix$trackId';
  }

  /// Converts back to a playable [TrackInfo] preserving all extended metadata.
  TrackInfo toTrackInfo() {
    return TrackInfo(
      id: _toTrackInfoId(),
      title: title,
      artist: artist,
      album: album,
      duration: Duration(milliseconds: durationMs < 0 ? 0 : durationMs),
      albumArtUrl: coverUrl,
      coverUrl: coverUrl,
      format: format,
      providerName: providerName,
      filePath: filePath,
      isrc: isrc,
      qualityLabel: qualityLabel,
      artistId: artistId,
    );
  }

  TrackMetadata copyWith({
    String? providerId,
    String? trackId,
    String? title,
    String? artist,
    String? primaryArtist,
    String? album,
    int? durationMs,
    String? isrc,
    String? qualityLabel,
    String? coverUrl,
    AudioFormat? format,
    String? artistId,
    String? filePath,
    String? providerName,
  }) {
    return TrackMetadata(
      providerId: providerId ?? this.providerId,
      trackId: trackId ?? this.trackId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      primaryArtist: primaryArtist ?? this.primaryArtist,
      album: album ?? this.album,
      durationMs: durationMs ?? this.durationMs,
      isrc: isrc ?? this.isrc,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      coverUrl: coverUrl ?? this.coverUrl,
      format: format ?? this.format,
      artistId: artistId ?? this.artistId,
      filePath: filePath ?? this.filePath,
      providerName: providerName ?? this.providerName,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is TrackMetadata &&
            other.providerId == providerId &&
            other.trackId == trackId &&
            other.title == title &&
            other.artist == artist &&
            other.primaryArtist == primaryArtist &&
            other.album == album &&
            other.durationMs == durationMs &&
            other.isrc == isrc &&
            other.qualityLabel == qualityLabel &&
            other.coverUrl == coverUrl &&
            other.format.codec == format.codec &&
            other.format.sampleRateHz == format.sampleRateHz &&
            other.format.bitDepth == format.bitDepth &&
            other.format.channels == format.channels &&
            other.format.isDsd == format.isDsd &&
            other.format.bitrateKbps == format.bitrateKbps &&
            other.artistId == artistId &&
            other.filePath == filePath &&
            other.providerName == providerName);
  }

  @override
  int get hashCode => Object.hashAll([
    providerId,
    trackId,
    title,
    artist,
    primaryArtist,
    album,
    durationMs,
    isrc,
    qualityLabel,
    coverUrl,
    format.codec,
    format.sampleRateHz,
    format.bitDepth,
    format.channels,
    format.isDsd,
    format.bitrateKbps,
    artistId,
    filePath,
    providerName,
  ]);

  @override
  String toString() =>
      'TrackMetadata($providerId:$trackId "$title" by $artist)';
}

/// Paginated track-radio response from a [RecommendationProvider].
@immutable
class RadioPage {
  final List<TrackMetadata> tracks;
  final String? nextCursor;
  final String? sourceLabel;

  const RadioPage({
    this.tracks = const <TrackMetadata>[],
    this.nextCursor,
    this.sourceLabel,
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is RadioPage &&
            listEquals(other.tracks, tracks) &&
            other.nextCursor == nextCursor &&
            other.sourceLabel == sourceLabel);
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(tracks),
    nextCursor,
    sourceLabel,
  );
}

/// Personalized home/discovery section returned by a [RecommendationProvider].
@immutable
class FeedSection {
  final String id;
  final String title;
  final String? subtitle;
  final String providerId;
  final List<TrackMetadata> tracks;
  final List<StreamingAlbum> albums;

  const FeedSection({
    required this.id,
    required this.title,
    this.subtitle,
    required this.providerId,
    this.tracks = const <TrackMetadata>[],
    this.albums = const <StreamingAlbum>[],
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is FeedSection &&
            other.id == id &&
            other.title == title &&
            other.subtitle == subtitle &&
            other.providerId == providerId &&
            listEquals(other.tracks, tracks) &&
            listEquals(other.albums, albums));
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    subtitle,
    providerId,
    Object.hashAll(tracks),
    Object.hashAll(albums),
  );
}

/// Query describing a track to match across providers by ISRC or metadata.
@immutable
class TrackMatchQuery {
  final String? isrc;
  final String title;
  final String artist;
  final int? durationMs;
  final String? album;

  const TrackMatchQuery({
    this.isrc,
    required this.title,
    required this.artist,
    this.durationMs,
    this.album,
  });

  factory TrackMatchQuery.fromTrackMetadata(TrackMetadata track) {
    return TrackMatchQuery(
      isrc: track.isrc,
      title: track.title,
      artist: track.artist,
      durationMs: track.durationMs > 0 ? track.durationMs : null,
      album: track.album.isNotEmpty ? track.album : null,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is TrackMatchQuery &&
            other.isrc == isrc &&
            other.title == title &&
            other.artist == artist &&
            other.durationMs == durationMs &&
            other.album == album);
  }

  @override
  int get hashCode => Object.hash(isrc, title, artist, durationMs, album);
}

/// Structured failure classification for recommendation and cross-platform
/// matching operations.
enum RecErrorKind {
  authRequired,
  unsupported,
  notFound,
  rateLimited,
  network,
  cancelled,
  unknown,
}

/// Exception thrown by [RecommendationProvider] and recommendation services.
class RecError implements Exception {
  final RecErrorKind kind;
  final String message;
  final int? statusCode;
  final String? providerId;

  const RecError({
    required this.kind,
    required this.message,
    this.statusCode,
    this.providerId,
  });

  @override
  String toString() {
    final parts = <String>[
      'RecError(${kind.name}',
      if (providerId != null) 'provider=$providerId',
      if (statusCode != null) 'status=$statusCode',
    ];
    return '${parts.join(', ')}): $message';
  }
}
