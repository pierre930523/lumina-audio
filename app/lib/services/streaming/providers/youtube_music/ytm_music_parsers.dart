part of '../youtube_music_provider.dart';

final RegExp _ytmYearSegmentRegex = RegExp(r'^\d{4}$');
final RegExp _ytmViewPlayCountRegex = RegExp(
  r'^(?:(?:no|\d[\d,.]*(?:\s*[KMBkmb萬億万억])?)\s*(?:views?|plays?|watching|listens?|次觀看|次播放|次观看|次收聽|回視聴|回再生)|(?:觀看次數|播放次數|观看次数|播放次数)\s*[:：]?\s*[\d,.]+\s*[KMBkmb萬億万억]?\s*(?:次)?)$',
  caseSensitive: false,
);
final RegExp _ytmRelativeTimeRegex = RegExp(
  r'^(?:\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago|\d+\s*(?:秒|分鐘|小時|天|週|個月|年)前)$',
  caseSensitive: false,
);

extension _YtmMusicParsers on YouTubeMusicProvider {
  ({String artist, String album}) _parsePlaylistPanelByline(
    Map<String, dynamic> item,
  ) {
    final longObj = item['longBylineText'];
    final shortObj = item['shortBylineText'];
    final longRaw = _extractInnerTubeText(longObj)?.trim() ?? '';
    final primaryObj = longRaw.isNotEmpty ? longObj : shortObj;

    final segments = <({String text, bool isArtist, bool isAlbum})>[];
    if (primaryObj is Map && primaryObj['runs'] is List) {
      final buf = StringBuffer();
      var isArtist = false;
      var isAlbum = false;

      void flushSegment() {
        final text = buf.toString().trim();
        buf.clear();
        if (text.isNotEmpty) {
          segments.add((text: text, isArtist: isArtist, isAlbum: isAlbum));
        }
        isArtist = false;
        isAlbum = false;
      }

      for (final rawRun in primaryObj['runs'] as List) {
        if (rawRun is! Map) continue;
        final run = Map<String, dynamic>.from(rawRun);
        final rawText = run['text']?.toString() ?? '';
        if (rawText.isEmpty) continue;
        final pageType = _extractPageType(run);
        final browseId = _extractBrowseId(run['navigationEndpoint'])?.trim();
        final runIsArtist =
            pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
            pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL';
        final runIsAlbum =
            pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
            (browseId != null && browseId.startsWith('MPREb_'));

        if (rawText.contains('•') || rawText.contains('·')) {
          final parts = rawText.split(RegExp(r'[•·]'));
          for (var i = 0; i < parts.length; i++) {
            final part = parts[i];
            if (part.trim().isNotEmpty) {
              buf.write(part);
              if (parts.length == 1) {
                isArtist = isArtist || runIsArtist;
                isAlbum = isAlbum || runIsAlbum;
              }
            }
            if (i < parts.length - 1) {
              flushSegment();
            }
          }
        } else {
          buf.write(rawText);
          isArtist = isArtist || runIsArtist;
          isAlbum = isAlbum || runIsAlbum;
        }
      }
      flushSegment();
    } else {
      final rawText = _extractInnerTubeText(primaryObj)?.trim() ?? '';
      if (rawText.isNotEmpty) {
        for (final part in rawText.split(RegExp(r'\s*[•·]\s*'))) {
          final trimmed = part.trim();
          if (trimmed.isNotEmpty) {
            segments.add((text: trimmed, isArtist: false, isAlbum: false));
          }
        }
      }
    }

    if (segments.isEmpty) {
      return (artist: '未知藝術家', album: 'YouTube Music Radio');
    }

    var artistIndex = segments.indexWhere((s) => s.isArtist);
    if (artistIndex < 0) {
      artistIndex = 0;
    }
    final artist = segments[artistIndex].text;

    String? album;
    final taggedAlbumIndex = segments.indexWhere(
      (s) => s.isAlbum && !s.isArtist,
    );
    if (taggedAlbumIndex >= 0 && taggedAlbumIndex != artistIndex) {
      album = segments[taggedAlbumIndex].text;
    } else {
      bool isMetadataNoise(String text) {
        if (text.toLowerCase() == artist.toLowerCase()) return true;
        if (_looksLikeDuration(text)) return true;
        if (_ytmYearSegmentRegex.hasMatch(text)) return true;
        if (_ytmViewPlayCountRegex.hasMatch(text)) return true;
        if (_ytmRelativeTimeRegex.hasMatch(text)) return true;
        return false;
      }

      for (var i = artistIndex + 1; i < segments.length; i++) {
        final seg = segments[i];
        if (seg.isArtist) continue;
        if (!isMetadataNoise(seg.text)) {
          album = seg.text;
          break;
        }
      }
    }

    return (
      artist: artist.isNotEmpty ? artist : '未知藝術家',
      album: (album != null && album.isNotEmpty)
          ? album
          : 'YouTube Music Radio',
    );
  }

  List<TrackInfo> _parsePlaylistPanelTracks(
    Map<String, dynamic> root, {
    String? fallbackCoverUrl,
  }) {
    final resolvedFallback =
        BaseStreamingProvider.upgradeCoverUrl(
          fallbackCoverUrl,
          targetSize: 1200,
        ) ??
        _extractRootFallbackThumbnail(root);
    final items = _collectMapsByKey(root, 'playlistPanelVideoRenderer');
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};
    for (final item in items) {
      final videoId = item['videoId']?.toString().trim() ?? '';
      if (videoId.isEmpty) continue;
      final trackId = 'ytm:$videoId';
      if (!seenIds.add(trackId)) continue;
      final rawTitle = _extractInnerTubeText(item['title'])?.trim();
      final title = (rawTitle != null && rawTitle.isNotEmpty)
          ? rawTitle
          : '未命名曲目';
      final byline = _parsePlaylistPanelByline(item);
      final lengthText = _extractInnerTubeText(item['lengthText']) ?? '';
      final duration = _looksLikeDuration(lengthText)
          ? _parseDuration(lengthText)
          : Duration.zero;
      final coverUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallback ??
          upgradeStreamingCoverUrl(
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
            targetSize: 1200,
          );
      tracks.add(
        TrackInfo(
          id: trackId,
          title: title,
          artist: byline.artist,
          album: byline.album,
          duration: duration,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }
    return tracks;
  }

  String _extractVideoId(TrackInfo track) =>
      _ytmExtractCleanVideoId(track.id, filePath: track.filePath);

  String _extractSeedVideoId(TrackInfo track) {
    final candidate = _extractCandidateVideoId(track.id) ??
        (track.filePath != null
            ? _extractCandidateVideoId(track.filePath!)
            : null);
    if (candidate == null || candidate.isEmpty) return '';
    if (_classifyNonVideoId(candidate) != null) return '';
    return candidate;
  }

  List<TrackInfo> _parseTracksFromJson(
    Map<String, dynamic> root, {
    String? fallbackCoverUrl,
  }) {
    final resolvedFallback =
        BaseStreamingProvider.upgradeCoverUrl(
          fallbackCoverUrl,
          targetSize: 1200,
        ) ??
        _extractRootFallbackThumbnail(root);
    final items = _collectMapsByKey(root, 'musicResponsiveListItemRenderer');
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};

    for (final item in items) {
      final videoId = _extractVideoIdFromRenderer(item);
      if (videoId == null || videoId.isEmpty) continue;
      final trackId = 'ytm:$videoId';
      if (!seenIds.add(trackId)) continue;

      final flexCols = item['flexColumns'];
      final title = _extractFlexColumnText(flexCols, 0) ?? '未命名曲目';
      final subRuns = _extractFlexColumnRuns(flexCols, 1);

      var artist = '未知藝術家';
      var album = 'YouTube Music';
      Duration duration = Duration.zero;

      final textParts = <String>[];
      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final pageType = _extractPageType(run);
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          artist = text;
        } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album = text;
        } else if (_looksLikeDuration(text)) {
          duration = _parseDuration(text);
        } else {
          textParts.add(text);
        }
      }

      if (artist == '未知藝術家' && textParts.isNotEmpty) {
        artist = textParts.first;
      }
      if (album == 'YouTube Music' && textParts.length >= 2) {
        album = textParts[1];
      }

      final fixedCols = item['fixedColumns'];
      final fixedDurText = _extractFixedColumnText(fixedCols, 0);
      if (duration == Duration.zero &&
          fixedDurText != null &&
          _looksLikeDuration(fixedDurText)) {
        duration = _parseDuration(fixedDurText);
      }

      final coverUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallback;

      tracks.add(
        TrackInfo(
          id: trackId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }

    return tracks;
  }

  List<StreamingPlaylist> _parsePlaylistsFromJson(Map<String, dynamic> root) {
    final playlists = <StreamingPlaylist>[];
    final seen = <String>{};

    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != null && pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') continue;
      if (!browseId.startsWith('VL') &&
          !browseId.startsWith('PL') &&
          !browseId.startsWith('RD') &&
          pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名歌單';
      final subtitle = _extractInnerTubeText(item['subtitle']);
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']);
      playlists.add(
        StreamingPlaylist(
          id: browseId,
          title: title,
          description: subtitle,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_PLAYLIST' && !browseId.startsWith('VL')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title =
          _extractFlexColumnText(item['flexColumns'], 0) ?? '未命名歌單';
      final coverUrl = _extractThumbnailUrl(item['thumbnail']);
      playlists.add(
        StreamingPlaylist(
          id: browseId,
          title: title,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    return playlists;
  }

  List<StreamingAlbum> _parseAlbumsFromJson(Map<String, dynamic> root) {
    final albums = <StreamingAlbum>[];
    final seen = <String>{};

    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && !browseId.startsWith('MPRE')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名專輯';
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .where((s) => s.isNotEmpty)
          .toList();
      final artist = parts.isNotEmpty ? parts.first : '未知藝術家';
      int? year;
      for (final p in parts) {
        final parsed = int.tryParse(p);
        if (parsed != null && parsed >= 1900 && parsed <= 2100) {
          year = parsed;
        }
      }
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']);
      albums.add(
        StreamingAlbum(
          id: browseId,
          title: title,
          artist: artist,
          year: year,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && !browseId.startsWith('MPRE')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title =
          _extractFlexColumnText(item['flexColumns'], 0) ?? '未命名專輯';
      final subRuns = _extractFlexColumnRuns(item['flexColumns'], 1);
      var artist = '未知藝術家';
      int? year;
      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·') continue;
        final rt = _extractPageType(run);
        if (rt == 'MUSIC_PAGE_TYPE_ARTIST') {
          artist = text;
        } else {
          final y = int.tryParse(text);
          if (y != null && y >= 1900 && y <= 2100) {
            year = y;
          } else if (artist == '未知藝術家' && text.toLowerCase() != 'album') {
            artist = text;
          }
        }
      }
      albums.add(
        StreamingAlbum(
          id: browseId,
          title: title,
          artist: artist,
          year: year,
          coverUrl: _extractThumbnailUrl(item['thumbnail']),
          providerKind: kind,
        ),
      );
    }

    return albums;
  }
}
