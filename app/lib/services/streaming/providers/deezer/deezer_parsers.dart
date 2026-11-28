part of '../deezer_provider.dart';

String? _extractMediaError(Map<String, dynamic> json) {
  final data = json['data'];
  if (data is! List || data.isEmpty) return null;
  final first = data.first;
  if (first is! Map) return null;
  final errors = first['errors'];
  if (errors is! List || errors.isEmpty) return null;
  final parts = <String>[];
  for (final e in errors) {
    if (e is Map) {
      final code = e['code']?.toString();
      final msg = e['message']?.toString();
      if (msg != null && msg.isNotEmpty) {
        parts.add(code != null ? '$code: $msg' : msg);
      } else if (code != null) {
        parts.add(code);
      }
    } else if (e != null) {
      parts.add(e.toString());
    }
  }
  return parts.isEmpty ? null : parts.join('; ');
}

({String url, String format, int? expireAt})? _extractMediaUrl(
  Map<String, dynamic> json,
) {
  final data = json['data'];
  if (data is! List || data.isEmpty) return null;
  final first = data.first;
  if (first is! Map) return null;
  final media = first['media'];
  if (media is! List || media.isEmpty) return null;
  for (final item in media) {
    if (item is! Map) continue;
    final fmt = item['format']?.toString() ?? 'MP3_128';
    final expRaw = item['exp'] ?? first['exp'];
    final itemExp = (expRaw is num)
        ? expRaw.toInt()
        : int.tryParse(expRaw?.toString() ?? '');
    final sources = item['sources'];
    if (sources is List && sources.isNotEmpty) {
      for (final src in sources) {
        if (src is Map) {
          final url = src['url']?.toString().trim() ?? '';
          if (url.isNotEmpty) {
            final uriExp = int.tryParse(
              Uri.tryParse(url)?.queryParameters['exp'] ?? '',
            );
            return (url: url, format: fmt, expireAt: itemExp ?? uriExp);
          }
        }
      }
    }
  }
  return null;
}

String? _extractDeezerCover(
  Map? obj, {
  Map? trackMap,
  int md5FallbackSize = 500,
}) {
  const keys = <String>[
    'cover_xl',
    'cover_big',
    'cover_medium',
    'cover',
    'cover_small',
    'picture_xl',
    'picture_big',
    'picture_medium',
    'picture',
  ];
  for (final source in <Map?>[obj, trackMap]) {
    if (source == null) continue;
    for (final key in keys) {
      final url = BaseStreamingProvider.normalizeCoverUrl(
        source[key]?.toString(),
      );
      if (url != null) return url;
    }
  }
  for (final source in <Map?>[obj, trackMap]) {
    if (source == null) continue;
    final rawPic = source['ALB_PICTURE']?.toString().trim();
    final picUrl = BaseStreamingProvider.normalizeCoverUrl(rawPic);
    if (picUrl != null) return picUrl;
    final md5 =
        (source['md5_image'] ?? source['ALB_PICTURE'])?.toString().trim();
    if (md5 != null &&
        md5.isNotEmpty &&
        RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(md5)) {
      return BaseStreamingProvider.normalizeCoverUrl(
        'https://e-cdns-images.dzcdn.net/images/cover/$md5/${md5FallbackSize}x$md5FallbackSize-000000-80-0-0.jpg',
      );
    }
  }
  return null;
}

extension _DeezerParsers on DeezerProvider {
  List<TrackInfo> _parseTracks(
    dynamic rawData, {
    String? fallbackCoverUrl,
    String? fallbackAlbumTitle,
    int md5FallbackSize = 500,
  }) {
    if (rawData is! List) return const [];
    final normalizedFallbackCover =
        BaseStreamingProvider.normalizeCoverUrl(fallbackCoverUrl);
    final tracks = <TrackInfo>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final artistObj = map['artist'] as Map?;
      final albumObj = map['album'] as Map?;
      final coverUrl = _extractDeezerCover(
            albumObj,
            trackMap: map,
            md5FallbackSize: md5FallbackSize,
          ) ??
          normalizedFallbackCover;
      final rawAlbTitle = albumObj?['title']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Deezer');
      final preview = map['preview']?.toString().trim();
      if (preview != null && preview.isNotEmpty) {
        _previewUrlCache[id] = preview;
      }
      final rawIsrc = map['isrc']?.toString().trim();
      final isrc = (rawIsrc != null && rawIsrc.isNotEmpty) ? rawIsrc : null;
      final rawArtistId = artistObj?['id']?.toString().trim();
      final artistId =
          (rawArtistId != null && rawArtistId.isNotEmpty) ? rawArtistId : null;

      tracks.add(
        TrackInfo(
          id: 'deezer:$id',
          title: map['title']?.toString() ?? '未命名曲目',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          album: albumTitle,
          duration: Duration(seconds: (map['duration'] as num?)?.toInt() ?? 0),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (map['track_position'] as num?)?.toInt(),
          discNumber: (map['disk_number'] as num?)?.toInt(),
          format: _catalogTrackFormat,
          providerName: 'Deezer',
          isrc: isrc,
          artistId: artistId,
        ),
      );
    }
    return tracks;
  }

  List<StreamingAlbum> _parseAlbums(dynamic rawData) {
    if (rawData is! List) return const [];
    final albums = <StreamingAlbum>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final artistObj = map['artist'] as Map?;
      final releaseDate = map['release_date']?.toString() ?? '';
      final year = releaseDate.length >= 4
          ? int.tryParse(releaseDate.substring(0, 4))
          : null;
      albums.add(
        StreamingAlbum(
          id: id,
          title: map['title']?.toString() ?? '未命名專輯',
          artist: artistObj?['name']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _extractDeezerCover(map),
          providerKind: kind,
          trackCount: (map['nb_tracks'] as num?)?.toInt(),
          qualityLabel: _webLossless ? 'FLAC 16-bit / 44.1 kHz' : null,
        ),
      );
    }
    return albums;
  }

  List<StreamingPlaylist> _parsePlaylists(dynamic rawData) {
    if (rawData is! List) return const [];
    final playlists = <StreamingPlaylist>[];
    for (final item in rawData) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      playlists.add(
        StreamingPlaylist(
          id: id,
          title: map['title']?.toString() ?? '未命名歌單',
          description: map['description']?.toString(),
          trackCount: (map['nb_tracks'] as num?)?.toInt() ?? 0,
          coverUrl: _extractDeezerCover(map),
          providerKind: kind,
        ),
      );
    }
    return playlists;
  }
}
