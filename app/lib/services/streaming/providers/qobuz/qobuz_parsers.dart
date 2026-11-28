part of '../qobuz_provider.dart';

String? _extractCoverUrl(dynamic imageObj) {
  if (imageObj is String) {
    return BaseStreamingProvider.normalizeCoverUrl(imageObj);
  }
  if (imageObj is! Map) return null;
  for (final key in const [
    'mega',
    'extralarge',
    'large',
    'medium',
    'small',
    'thumbnail',
    'back',
  ]) {
    final url = BaseStreamingProvider.normalizeCoverUrl(
      imageObj[key]?.toString(),
    );
    if (url != null) return url;
  }
  return null;
}

extension _QobuzParsers on QobuzProvider {
  List<TrackInfo> _parseTracks(
    dynamic rawItems, {
    String? fallbackAlbumTitle,
    String? fallbackArtistName,
    String? fallbackCoverUrl,
  }) {
    if (rawItems is! List) return const [];
    final normalizedFallbackCover =
        BaseStreamingProvider.normalizeCoverUrl(fallbackCoverUrl);
    final list = <TrackInfo>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final performer = map['performer'] as Map?;
      final albumObj = map['album'] as Map?;
      final albumArtist = albumObj?['artist'] as Map?;
      final performerName = performer?['name']?.toString().trim();
      final albArtistName = albumArtist?['name']?.toString().trim();
      final fbArtistName = fallbackArtistName?.trim();
      final artistName =
          (performerName != null && performerName.isNotEmpty)
              ? performerName
              : ((albArtistName != null && albArtistName.isNotEmpty)
                    ? albArtistName
                    : ((fbArtistName != null && fbArtistName.isNotEmpty)
                          ? fbArtistName
                          : '未知藝術家'));
      final rawAlbTitle = albumObj?['title']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Qobuz');
      final coverUrl = _extractCoverUrl(albumObj?['image']) ??
          _extractCoverUrl(map['image']) ??
          normalizedFallbackCover;

      final rawSr = map['maximum_sampling_rate'];
      final srHz = rawSr is num
          ? (rawSr <= 1000 ? (rawSr.toDouble() * 1000).round() : rawSr.round())
          : 44100;
      final bitDepth = (map['maximum_bit_depth'] as num?)?.toInt() ?? 16;
      final rawIsrc = map['isrc']?.toString().trim();
      final isrc = (rawIsrc != null && rawIsrc.isNotEmpty) ? rawIsrc : null;
      final rawArtistId =
          (performer?['id'] ?? albumArtist?['id'])?.toString().trim();
      final artistId =
          (rawArtistId != null && rawArtistId.isNotEmpty) ? rawArtistId : null;
      final qualityLabel =
          (bitDepth > 16 || srHz > 48000) ? 'HI_RES' : 'LOSSLESS';

      list.add(
        TrackInfo(
          id: 'qobuz:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistName,
          album: albumTitle,
          duration: Duration(seconds: (map['duration'] as num?)?.toInt() ?? 0),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (map['track_number'] as num?)?.toInt(),
          discNumber: (map['media_number'] as num?)?.toInt(),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: srHz,
            bitDepth: bitDepth,
            channels: 2,
          ),
          providerName: 'Qobuz',
          isrc: isrc,
          qualityLabel: qualityLabel,
          artistId: artistId,
        ),
      );
    }
    return list;
  }

  List<StreamingAlbum> _parseAlbums(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final list = <StreamingAlbum>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final artistObj = map['artist'] as Map?;
      final rawSr = map['maximum_sampling_rate'];
      final bitDepth = (map['maximum_bit_depth'] as num?)?.toInt();
      String? qualityLabel;
      if (rawSr is num && bitDepth != null) {
        final srHz = rawSr <= 1000 ? (rawSr * 1000).round() : rawSr.round();
        qualityLabel = AudioFormat.formatLabel(
          codec: 'flac',
          sampleRateHz: srHz,
          bitDepth: bitDepth,
        );
      }
      final origDate = map['release_date_original']?.toString() ?? '';
      final year = origDate.length >= 4
          ? int.tryParse(origDate.substring(0, 4))
          : null;

      list.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _extractCoverUrl(map['image']),
          providerKind: kind,
          trackCount: (map['tracks_count'] as num?)?.toInt(),
          qualityLabel: qualityLabel,
        ),
      );
    }
    return list;
  }

  List<StreamingPlaylist> _parsePlaylists(dynamic rawItems) {
    if (rawItems is! List) return const [];
    final list = <StreamingPlaylist>[];
    for (final item in rawItems) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final images = map['images300'] ?? map['images150'] ?? map['images'];
      final coverUrl = BaseStreamingProvider.normalizeCoverUrl(
        (images is List && images.isNotEmpty) ? images.first?.toString() : null,
      );
      list.add(
        StreamingPlaylist(
          id: id,
          title: map['name']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['tracks_count'] as num?)?.toInt() ?? 0,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }
    return list;
  }
}
