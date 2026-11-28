part of '../apple_music_provider.dart';

({String? previewUrl, String? webUrl}) _extractPreviewAndWebUrl(
  Map<String, dynamic> songMap,
) {
  final attrs = songMap['attributes'] is Map
      ? songMap['attributes'] as Map
      : null;
  if (attrs == null) return (previewUrl: null, webUrl: null);
  final previews = attrs['previews'];
  String? previewUrl;
  if (previews is List && previews.isNotEmpty && previews.first is Map) {
    previewUrl = (previews.first as Map)['url']?.toString().trim();
  }
  final webUrl = attrs['url']?.toString().trim();
  return (previewUrl: previewUrl, webUrl: webUrl);
}

String? _expandArtworkUrl(dynamic artwork) {
  final String? raw;
  if (artwork is String) {
    raw = artwork.trim();
  } else if (artwork is Map) {
    raw = artwork['url']?.toString().trim();
  } else {
    return null;
  }
  if (raw == null || raw.isEmpty) return null;
  final expanded = raw
      .replaceAll('{w}', '600')
      .replaceAll('{h}', '600')
      .replaceAll('{f}', 'jpg');
  return BaseStreamingProvider.normalizeCoverUrl(expanded);
}

extension _AppleMusicParsers on AppleMusicProvider {
  List<TrackInfo> _parseSongs(
    dynamic rawData, {
    String? fallbackCoverUrl,
    String? fallbackAlbumTitle,
  }) {
    if (rawData is! List) return const [];
    final normalizedFallbackCover = _expandArtworkUrl(fallbackCoverUrl);
    final list = <TrackInfo>[];
    for (final entry in rawData) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final rawId = map['id']?.toString() ?? '';
      if (rawId.isEmpty) continue;

      final attrs = map['attributes'] is Map
          ? Map<String, dynamic>.from(map['attributes'] as Map)
          : const <String, dynamic>{};
      final playParams = attrs['playParams'] is Map
          ? Map<String, dynamic>.from(attrs['playParams'] as Map)
          : const <String, dynamic>{};

      final catalogId = playParams['catalogId']?.toString().trim();
      if (catalogId != null && catalogId.isNotEmpty) {
        _catalogIdByTrackId[rawId] = catalogId;
      }

      final extracted = _extractPreviewAndWebUrl(map);
      if (extracted.previewUrl != null && extracted.previewUrl!.isNotEmpty) {
        _previewUrlByTrackId[rawId] = extracted.previewUrl!;
      }
      if (extracted.webUrl != null && extracted.webUrl!.isNotEmpty) {
        _externalWebUrlByTrackId[rawId] = extracted.webUrl!;
      }

      final coverUrl =
          _expandArtworkUrl(attrs['artwork']) ?? normalizedFallbackCover;
      final rawAlbTitle = attrs['albumName']?.toString().trim();
      final fbAlbTitle = fallbackAlbumTitle?.trim();
      final albumTitle = (rawAlbTitle != null && rawAlbTitle.isNotEmpty)
          ? rawAlbTitle
          : ((fbAlbTitle != null && fbAlbTitle.isNotEmpty)
                ? fbAlbTitle
                : 'Apple Music');
      final durationMs = (attrs['durationInMillis'] as num?)?.toInt() ?? 0;
      final rawIsrc = attrs['isrc']?.toString().trim();
      final isrc = (rawIsrc != null && rawIsrc.isNotEmpty) ? rawIsrc : null;

      list.add(
        TrackInfo(
          id: 'apple:$rawId',
          title: attrs['name']?.toString() ?? '未命名曲目',
          artist: attrs['artistName']?.toString() ?? '未知藝術家',
          album: albumTitle,
          duration: Duration(milliseconds: durationMs),
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          trackNumber: (attrs['trackNumber'] as num?)?.toInt(),
          discNumber: (attrs['discNumber'] as num?)?.toInt(),
          format: const AudioFormat(
            codec: AudioCodec.aac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'Apple Music',
          isrc: isrc,
        ),
      );
    }
    return list;
  }

  List<StreamingAlbum> _parseAlbums(dynamic rawData) {
    if (rawData is! List) return const [];
    final list = <StreamingAlbum>[];
    for (final entry in rawData) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final attrs = map['attributes'] is Map
          ? Map<String, dynamic>.from(map['attributes'] as Map)
          : const <String, dynamic>{};
      final releaseDate = attrs['releaseDate']?.toString() ?? '';
      final year = releaseDate.length >= 4
          ? int.tryParse(releaseDate.substring(0, 4))
          : null;
      list.add(
        StreamingAlbum(
          id: id,
          title: attrs['name']?.toString() ?? '未命名專輯',
          artist: attrs['artistName']?.toString() ?? '未知藝術家',
          year: year,
          coverUrl: _expandArtworkUrl(attrs['artwork']),
          providerKind: kind,
          trackCount: (attrs['trackCount'] as num?)?.toInt(),
          qualityLabel: 'AAC / FairPlay DRM',
        ),
      );
    }
    return list;
  }

  List<StreamingPlaylist> _parsePlaylists(dynamic rawData) {
    if (rawData is! List) return const [];
    final list = <StreamingPlaylist>[];
    for (final entry in rawData) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final attrs = map['attributes'] is Map
          ? Map<String, dynamic>.from(map['attributes'] as Map)
          : const <String, dynamic>{};
      final descObj = attrs['description'];
      final description = descObj is Map
          ? descObj['standard']?.toString()
          : descObj?.toString();
      list.add(
        StreamingPlaylist(
          id: id,
          title: attrs['name']?.toString() ?? '未命名歌單',
          description: description,
          coverUrl: _expandArtworkUrl(attrs['artwork']),
          providerKind: kind,
        ),
      );
    }
    return list;
  }
}
