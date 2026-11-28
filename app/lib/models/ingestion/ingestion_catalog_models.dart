import 'package:flutter/foundation.dart';

import '../audio_format.dart';
import '../playback_state.dart';
import '../streaming_models.dart';

/// Lightweight streaming track metadata for canonical library ingestion.
/// Intentionally contains NO stream URL field (URLs are resolved lazily).
@immutable
class ExternalTrackIngest {
  final String externalTrackId;
  final String title;
  final String artistName;
  final int discNumber;
  final int trackNumber;
  final int durationMs;
  final String? isrc;
  final String? genre;
  final String? composer;
  final String? codec;
  final int? sampleRateHz;
  final int? bitDepth;
  final int? bitrateKbps;

  const ExternalTrackIngest({
    required this.externalTrackId,
    required this.title,
    required this.artistName,
    this.discNumber = 1,
    this.trackNumber = 1,
    this.durationMs = 0,
    this.isrc,
    this.genre,
    this.composer,
    this.codec,
    this.sampleRateHz,
    this.bitDepth,
    this.bitrateKbps,
  });

  factory ExternalTrackIngest.fromJson(Map<String, dynamic> json) =>
      ExternalTrackIngest(
        externalTrackId: json['external_track_id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artistName: json['artist_name']?.toString() ?? '',
        discNumber: (json['disc_number'] as num?)?.toInt() ?? 1,
        trackNumber: (json['track_number'] as num?)?.toInt() ?? 1,
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        isrc: json['isrc']?.toString(),
        genre: json['genre']?.toString(),
        composer: json['composer']?.toString(),
        codec: json['codec']?.toString(),
        sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt(),
        bitDepth: (json['bit_depth'] as num?)?.toInt(),
        bitrateKbps: (json['bitrate_kbps'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'external_track_id': externalTrackId,
    'title': title,
    'artist_name': artistName,
    'disc_number': discNumber,
    'track_number': trackNumber,
    'duration_ms': durationMs,
    if (isrc != null && isrc!.trim().isNotEmpty) 'isrc': isrc,
    if (genre != null && genre!.trim().isNotEmpty) 'genre': genre,
    if (composer != null && composer!.trim().isNotEmpty) 'composer': composer,
    if (codec != null && codec!.trim().isNotEmpty) 'codec': codec,
    if (sampleRateHz != null) 'sample_rate_hz': sampleRateHz,
    if (bitDepth != null) 'bit_depth': bitDepth,
    if (bitrateKbps != null) 'bitrate_kbps': bitrateKbps,
  };
}

/// Lightweight streaming album metadata for canonical library ingestion.
/// Intentionally contains NO expiring audio stream URLs.
@immutable
class ExternalAlbumIngest {
  final String externalAlbumId;
  final String title;
  final String artistName;
  final String? albumArtist;
  final int? releaseYear;
  final String? upc;
  final String? coverUrl;
  final String? editionLabel;
  final int? discCount;
  final List<ExternalTrackIngest> tracks;

  const ExternalAlbumIngest({
    required this.externalAlbumId,
    required this.title,
    required this.artistName,
    this.albumArtist,
    this.releaseYear,
    this.upc,
    this.coverUrl,
    this.editionLabel,
    this.discCount,
    this.tracks = const [],
  });

  factory ExternalAlbumIngest.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    return ExternalAlbumIngest(
      externalAlbumId: json['external_album_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artistName: json['artist_name']?.toString() ?? '',
      albumArtist: json['album_artist']?.toString(),
      releaseYear: (json['release_year'] as num?)?.toInt(),
      upc: json['upc']?.toString(),
      coverUrl: json['cover_url']?.toString(),
      editionLabel: json['edition_label']?.toString(),
      discCount: (json['disc_count'] as num?)?.toInt(),
      tracks: rawTracks
          .whereType<Map>()
          .map(
            (e) => ExternalTrackIngest.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'external_album_id': externalAlbumId,
    'title': title,
    'artist_name': artistName,
    if (albumArtist != null && albumArtist!.trim().isNotEmpty)
      'album_artist': albumArtist,
    if (releaseYear != null) 'release_year': releaseYear,
    if (upc != null && upc!.trim().isNotEmpty) 'upc': upc,
    if (coverUrl != null && coverUrl!.trim().isNotEmpty) 'cover_url': coverUrl,
    if (editionLabel != null && editionLabel!.trim().isNotEmpty)
      'edition_label': editionLabel,
    if (discCount != null) 'disc_count': discCount,
    'tracks': tracks.map((t) => t.toJson()).toList(growable: false),
  };
}

/// Batch payload handed off from Dart streaming catalog sync to Rust canonical DB.
/// Strictly lightweight metadata + platform IDs (zero expiring stream URLs).
@immutable
class ExternalCatalogIngestBatch {
  final String provider;
  final List<ExternalAlbumIngest> albums;

  const ExternalCatalogIngestBatch({
    required this.provider,
    this.albums = const [],
  });

  factory ExternalCatalogIngestBatch.fromJson(Map<String, dynamic> json) {
    final rawAlbums = json['albums'] as List<dynamic>? ?? const [];
    return ExternalCatalogIngestBatch(
      provider: json['provider']?.toString() ?? '',
      albums: rawAlbums
          .whereType<Map>()
          .map(
            (e) => ExternalAlbumIngest.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'albums': albums.map((a) => a.toJson()).toList(growable: false),
  };

  /// Converts an in-memory [StreamingCatalog] into a canonical ingest batch
  /// without ever carrying audio stream URLs or local file paths.
  factory ExternalCatalogIngestBatch.fromStreamingCatalog(
    String providerId,
    StreamingCatalog catalog,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final albumBuilders = <String, _MutableAlbumIngest>{};
    final keyByTitleArtist = <String, String>{};

    for (final album in catalog.albums) {
      final cleanAlbumId = _stripProviderPrefix(album.id, normalizedProvider);
      if (cleanAlbumId.isEmpty) continue;
      final normTitle = album.title.trim();
      final normArtist = album.artist.trim();
      final builder = _MutableAlbumIngest(
        externalAlbumId: cleanAlbumId,
        title: normTitle.isNotEmpty ? normTitle : 'Unknown Album',
        artistName: normArtist.isNotEmpty ? normArtist : 'Unknown Artist',
        albumArtist: normArtist.isNotEmpty ? normArtist : null,
        releaseYear: album.year,
        coverUrl: normalizeStreamingCoverUrl(album.coverUrl),
      );
      albumBuilders[cleanAlbumId] = builder;
      final lookupKey = _albumLookupKey(builder.title, builder.artistName);
      keyByTitleArtist.putIfAbsent(lookupKey, () => cleanAlbumId);
    }

    final seenTrackIds = <String>{};
    final allTracks = <TrackInfo>[
      ...catalog.tracks,
      for (final pl in catalog.playlists) ...pl.tracks,
    ];

    for (final track in allTracks) {
      final cleanTrackId = _stripProviderPrefix(track.id, normalizedProvider);
      if (cleanTrackId.isEmpty || !seenTrackIds.add(cleanTrackId)) continue;

      final albumTitle = track.album.trim().isNotEmpty
          ? track.album.trim()
          : track.title.trim();
      final albumArtist = track.effectiveAlbumArtist.trim().isNotEmpty
          ? track.effectiveAlbumArtist.trim()
          : 'Unknown Artist';
      final lookupKey = _albumLookupKey(albumTitle, albumArtist);

      var targetAlbumId = keyByTitleArtist[lookupKey];
      if (targetAlbumId == null) {
        targetAlbumId = '$normalizedProvider:synth:$lookupKey';
        keyByTitleArtist[lookupKey] = targetAlbumId;
        albumBuilders[targetAlbumId] = _MutableAlbumIngest(
          externalAlbumId: targetAlbumId,
          title: albumTitle.isNotEmpty ? albumTitle : 'Unknown Album',
          artistName: albumArtist,
          albumArtist: track.albumArtist?.trim().isNotEmpty == true
              ? track.albumArtist!.trim()
              : albumArtist,
          releaseYear: track.year,
          coverUrl: normalizeStreamingCoverUrl(track.artworkUrl),
        );
      } else {
        final existing = albumBuilders[targetAlbumId]!;
        existing.coverUrl ??= normalizeStreamingCoverUrl(track.artworkUrl);
        existing.releaseYear ??= track.year;
      }

      final discNum = (track.discNumber != null && track.discNumber! > 0)
          ? track.discNumber!
          : 1;
      final bucket = albumBuilders[targetAlbumId]!;
      final trackNum = (track.trackNumber != null && track.trackNumber! > 0)
          ? track.trackNumber!
          : bucket.tracks.length + 1;
      if (discNum > bucket.maxDiscNumber) {
        bucket.maxDiscNumber = discNum;
      }

      bucket.tracks.add(
        ExternalTrackIngest(
          externalTrackId: cleanTrackId,
          title: track.title.trim().isNotEmpty ? track.title.trim() : cleanTrackId,
          artistName: track.artist.trim().isNotEmpty
              ? track.artist.trim()
              : albumArtist,
          discNumber: discNum,
          trackNumber: trackNum,
          durationMs: track.duration.inMilliseconds.clamp(0, 1 << 50),
          isrc: track.isrc?.trim().isNotEmpty == true ? track.isrc!.trim() : null,
          genre: track.genre?.trim().isNotEmpty == true ? track.genre!.trim() : null,
          composer: track.composer?.trim().isNotEmpty == true
              ? track.composer!.trim()
              : null,
          codec: _codecToSnakeCase(track.format.codec),
          sampleRateHz: track.format.sampleRateHz > 0
              ? track.format.sampleRateHz
              : null,
          bitDepth: track.format.bitDepth > 0 ? track.format.bitDepth : null,
          bitrateKbps:
              (track.format.bitrateKbps != null && track.format.bitrateKbps! > 0)
              ? track.format.bitrateKbps
              : null,
        ),
      );
    }

    return ExternalCatalogIngestBatch(
      provider: normalizedProvider,
      albums: albumBuilders.values
          .map((b) => b.build())
          .toList(growable: false),
    );
  }

  static String _stripProviderPrefix(String rawId, String providerId) {
    var trimmed = rawId.trim();
    if (trimmed.isEmpty) return '';
    final prefixes = <String>[
      '$providerId:',
      if (providerId == 'apple_music') 'apple:',
      if (providerId == 'youtube_music') ...['ytm:', 'ytm_'],
    ];
    for (final prefix in prefixes) {
      if (trimmed.toLowerCase().startsWith(prefix)) {
        trimmed = trimmed.substring(prefix.length).trim();
        break;
      }
    }
    return trimmed;
  }

  static String _albumLookupKey(String title, String artist) =>
      '${title.trim().toLowerCase()}::${artist.trim().toLowerCase()}';

  static String _codecToSnakeCase(AudioCodec codec) => codec.name;
}

class _MutableAlbumIngest {
  final String externalAlbumId;
  final String title;
  final String artistName;
  final String? albumArtist;
  int? releaseYear;
  String? coverUrl;
  int maxDiscNumber = 1;
  final List<ExternalTrackIngest> tracks = <ExternalTrackIngest>[];

  _MutableAlbumIngest({
    required this.externalAlbumId,
    required this.title,
    required this.artistName,
    this.albumArtist,
    this.releaseYear,
    this.coverUrl,
  });

  ExternalAlbumIngest build() => ExternalAlbumIngest(
    externalAlbumId: externalAlbumId,
    title: title,
    artistName: artistName,
    albumArtist: albumArtist,
    releaseYear: releaseYear,
    coverUrl: coverUrl,
    discCount: tracks.isEmpty ? null : maxDiscNumber,
    tracks: List<ExternalTrackIngest>.unmodifiable(tracks),
  );
}
