part of '../tidal_provider.dart';

String _resolveEffectiveTidalQuality(Map<String, dynamic> map) {
  final rawQuality =
      map['audioQuality']?.toString().trim().toUpperCase() ?? '';
  if (rawQuality == 'HI_RES_LOSSLESS' || rawQuality == 'HI_RES') {
    return rawQuality;
  }
  final mediaMeta = map['mediaMetadata'];
  if (mediaMeta is Map) {
    final tags = mediaMeta['tags'];
    if (tags is List) {
      var hasLossless = false;
      for (final tag in tags) {
        final upperTag = tag?.toString().trim().toUpperCase() ?? '';
        if (upperTag == 'HIRES_LOSSLESS' || upperTag == 'HI_RES_LOSSLESS') {
          return 'HI_RES_LOSSLESS';
        }
        if (upperTag == 'LOSSLESS') {
          hasLossless = true;
        }
      }
      if (rawQuality.isEmpty && hasLossless) {
        return 'LOSSLESS';
      }
    }
  }
  return rawQuality;
}

int? _tidalLossyBitrateKbps(String quality, {bool isFlac = false}) {
  if (isFlac) return null;
  return switch (quality.toUpperCase()) {
    'HIGH' => 320,
    'LOW' => 96,
    _ => null,
  };
}

AudioFormat _formatForTidalQuality(String quality) {
  if (quality == 'HI_RES_LOSSLESS' || quality == 'HI_RES') {
    return const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 96000,
      bitDepth: 24,
      channels: 2,
    );
  }
  if (quality == 'LOSSLESS') {
    return const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    );
  }
  return AudioFormat(
    codec: AudioCodec.aac,
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
    bitrateKbps: _tidalLossyBitrateKbps(quality),
  );
}

String? _extractTidalCoverFromMap(
  Map<dynamic, dynamic> map, {
  int size = 640,
}) {
  for (final key in const <String>[
    'cover',
    'imageCover',
    'imageId',
    'squareImage',
    'image',
    'images',
  ]) {
    final candidate = _extractTidalCoverFromValue(map[key], size: size);
    if (candidate != null) return candidate;
  }
  final album = map['album'];
  if (album is Map) {
    return _extractTidalCoverFromMap(album, size: size);
  }
  return null;
}

String? _extractTidalCoverFromValue(dynamic value, {int size = 640}) {
  if (value == null) return null;
  if (value is String) {
    return _tidalCoverUrl(value, size: size);
  }
  if (value is Map) {
    final directUrl = _tidalCoverUrl(value['url']?.toString(), size: size);
    if (directUrl != null) return directUrl;

    final preferredKeys = size >= 1000
        ? const <String>[
            '1280x1280',
            'EXTRALARGE',
            'XLARGE',
            'LARGE',
            'large',
            '640x640',
            'MEDIUM',
            'medium',
            'SMALL',
            'small',
            'default',
            'thumbnail',
          ]
        : const <String>[
            'LARGE',
            'large',
            '640x640',
            'EXTRALARGE',
            '1280x1280',
            'MEDIUM',
            'medium',
            '320x320',
            'SMALL',
            'small',
            'default',
            'thumbnail',
          ];
    for (final key in preferredKeys) {
      if (value.containsKey(key)) {
        final candidate = _extractTidalCoverFromValue(value[key], size: size);
        if (candidate != null) return candidate;
      }
    }
    for (final entryVal in value.values) {
      final candidate = _extractTidalCoverFromValue(entryVal, size: size);
      if (candidate != null) return candidate;
    }
    return null;
  }
  if (value is List) {
    String? bestUrl;
    var bestWidth = -1;
    for (final item in value) {
      String? candidateUrl;
      var width = 0;
      if (item is Map) {
        candidateUrl = _tidalCoverUrl(item['url']?.toString(), size: size);
        width = (item['width'] as num?)?.toInt() ?? 0;
      } else if (item is String) {
        candidateUrl = _tidalCoverUrl(item, size: size);
      }
      if (candidateUrl == null) continue;
      if (width <= 0) {
        bestUrl ??= candidateUrl;
        continue;
      }
      if (bestUrl == null ||
          bestWidth <= 0 ||
          (size >= 1000 && width > bestWidth) ||
          (size < 1000 &&
              ((bestWidth < size && width > bestWidth) ||
                  (width >= size &&
                      (bestWidth < size || width < bestWidth))))) {
        bestUrl = candidateUrl;
        bestWidth = width;
      }
    }
    return bestUrl;
  }
  return null;
}

String? _tidalCoverUrl(String? rawCover, {int size = 640}) {
  if (rawCover == null) return null;
  final trimmed = rawCover.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('http://') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('//')) {
    return BaseStreamingProvider.normalizeCoverUrl(trimmed);
  }
  if (!RegExp(r'^[A-Za-z0-9_/-]+$').hasMatch(trimmed)) {
    return null;
  }
  return BaseStreamingProvider.normalizeCoverUrl(
    'https://resources.tidal.com/images/${trimmed.replaceAll('-', '/')}/${size}x$size.jpg',
  );
}

extension _TidalParsers on TidalProvider {
  List<TrackInfo> _parseTrackList(
    dynamic rawItems, {
    String? fallbackCoverUrl,
    String? fallbackAlbumTitle,
    int coverSize = 640,
  }) {
    if (rawItems is! List) return const [];
    final normalizedFallbackCover = _tidalCoverUrl(
      fallbackCoverUrl,
      size: coverSize,
    );
    final tracks = <TrackInfo>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final wrapperType = entry['type']?.toString().trim().toUpperCase() ?? '';
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : (entry['data'] is Map
                ? Map<String, dynamic>.from(entry['data'] as Map)
                : Map<String, dynamic>.from(entry));
      final itemType = map['type']?.toString().trim().toUpperCase() ?? '';
      final effectiveType = itemType.isNotEmpty ? itemType : wrapperType;
      if (_isExcludedRecommendationType(effectiveType)) continue;

      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] is Map
          ? map['artist'] as Map
          : (map['artists'] is List && (map['artists'] as List).isNotEmpty
                ? (map['artists'] as List).first as Map?
                : null);
      final albumObj = map['album'] is Map
          ? Map<String, dynamic>.from(map['album'] as Map)
          : null;
      final coverUrl = (albumObj != null
              ? _extractTidalCoverFromMap(albumObj, size: coverSize)
              : null) ??
          _extractTidalCoverFromMap(map, size: coverSize) ??
          normalizedFallbackCover;
      final rawAlbTitle = albumObj?['title']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Tidal');
      final durationSec = (map['duration'] as num?)?.toInt() ?? 0;
      final quality = _resolveEffectiveTidalQuality(map);
      final rawIsrc = map['isrc']?.toString().trim();
      final isrc = (rawIsrc != null && rawIsrc.isNotEmpty) ? rawIsrc : null;
      final rawArtistId = artistObj?['id']?.toString().trim();
      final artistId =
          (rawArtistId != null && rawArtistId.isNotEmpty) ? rawArtistId : null;

      tracks.add(
        TrackInfo(
          id: 'tidal:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          album: albumTitle,
          duration: Duration(seconds: durationSec),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (map['trackNumber'] as num?)?.toInt(),
          discNumber: (map['volumeNumber'] as num?)?.toInt(),
          format: _formatForTidalQuality(quality),
          providerName: 'Tidal',
          isrc: isrc,
          qualityLabel: quality.isNotEmpty ? quality : null,
          artistId: artistId,
        ),
      );
    }
    return tracks;
  }

  List<StreamingAlbum> _parseAlbumList(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final albums = <StreamingAlbum>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final wrapperType = entry['type']?.toString().trim().toUpperCase() ?? '';
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : (entry['data'] is Map
                ? Map<String, dynamic>.from(entry['data'] as Map)
                : Map<String, dynamic>.from(entry));
      final itemType = map['type']?.toString().trim().toUpperCase() ?? '';
      final effectiveType = itemType.isNotEmpty ? itemType : wrapperType;
      if (_isExcludedRecommendationType(effectiveType)) continue;

      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] is Map
          ? map['artist'] as Map
          : (map['artists'] is List && (map['artists'] as List).isNotEmpty
                ? (map['artists'] as List).first as Map?
                : null);
      final releaseDate = map['releaseDate']?.toString() ?? '';
      final year = releaseDate.length >= 4
          ? int.tryParse(releaseDate.substring(0, 4))
          : null;
      final effectiveQuality = _resolveEffectiveTidalQuality(map);

      albums.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _extractTidalCoverFromMap(map),
          providerKind: kind,
          trackCount: (map['numberOfTracks'] as num?)?.toInt(),
          qualityLabel: effectiveQuality.isNotEmpty ? effectiveQuality : null,
        ),
      );
    }
    return albums;
  }

  List<StreamingPlaylist> _parsePlaylistList(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final playlists = <StreamingPlaylist>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final map = entry['item'] is Map
          ? Map<String, dynamic>.from(entry['item'] as Map)
          : (entry['data'] is Map
                ? Map<String, dynamic>.from(entry['data'] as Map)
                : Map<String, dynamic>.from(entry));
      final id = map['uuid']?.toString() ?? map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      playlists.add(
        StreamingPlaylist(
          id: id,
          title: map['title']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['numberOfTracks'] as num?)?.toInt() ?? 0,
          coverUrl: _extractTidalCoverFromValue(map['squareImage']) ??
              _extractTidalCoverFromValue(map['image']) ??
              _extractTidalCoverFromValue(map['images']),
          providerKind: kind,
        ),
      );
    }
    return playlists;
  }
}
