part of '../youtube_music_provider.dart';

bool _isResponsiveItemPodcastEpisode(
  Map<String, dynamic> item, {
  required bool allowAll,
}) {
  final navBrowseId = _extractBrowseId(item['navigationEndpoint']) ?? '';
  final navPageType = _extractPageType(item['navigationEndpoint']);
  if (navPageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
      navBrowseId.startsWith('MPSP')) {
    return false;
  }

  if (allowAll) return true;

  final watchCfg = _findFirstMapByKey(item, 'watchEndpointMusicConfig');
  final videoType = watchCfg?['musicVideoType']?.toString() ?? '';
  if (videoType == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE' ||
      videoType == 'MUSIC_VIDEO_TYPE_NON_MUSIC_AUDIO') {
    return true;
  }

  for (final colIdx in const <int>[0, 1]) {
    for (final run in _extractFlexColumnRuns(item['flexColumns'], colIdx)) {
      final pt = _extractPageType(run);
      final bid = _extractBrowseId(run['navigationEndpoint']) ?? '';
      if (pt == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE' ||
          pt == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
          bid.startsWith('MPED') ||
          bid.startsWith('MPSP')) {
        return true;
      }
    }
  }

  return false;
}

String? _extractPodcastVideoIdFromItem(Map<String, dynamic> item) {
  final direct = _extractVideoIdFromRenderer(item);
  if (direct != null && direct.trim().isNotEmpty) {
    return direct.trim();
  }
  final onTapWatch = _findFirstMapByKey(item['onTap'], 'watchEndpoint');
  final onTapVid = onTapWatch?['videoId']?.toString().trim();
  if (onTapVid != null && onTapVid.isNotEmpty) {
    return onTapVid;
  }
  for (final browse in _collectMapsByKey(item, 'browseEndpoint')) {
    final bid = browse['browseId']?.toString().trim() ?? '';
    if (bid.startsWith('MPED') && bid.length == 15) {
      return bid.substring(4);
    }
  }
  return null;
}

Duration _extractDurationFromPlaybackProgress(dynamic progressNode) {
  if (progressNode is! Map) return Duration.zero;
  final renderer = progressNode['musicPlaybackProgressRenderer'] is Map
      ? Map<String, dynamic>.from(
          progressNode['musicPlaybackProgressRenderer'] as Map,
        )
      : Map<String, dynamic>.from(progressNode);
  for (final key in const <String>['durationText', 'playbackProgressText']) {
    final field = renderer[key];
    for (final run in _extractRunsFromTextObject(field)) {
      final t = run['text']?.toString().trim() ?? '';
      if (_looksLikePodcastDuration(t)) {
        final d = _parsePodcastDuration(t);
        if (d > Duration.zero) return d;
      }
    }
    final combined = _extractInnerTubeText(field)?.trim() ?? '';
    if (_looksLikePodcastDuration(combined)) {
      final d = _parsePodcastDuration(combined);
      if (d > Duration.zero) return d;
    }
  }
  return Duration.zero;
}

bool _looksLikePodcastDuration(String raw) {
  final trimmed = raw.replaceAll(RegExp(r'^[•·\s]+'), '').trim();
  if (trimmed.isEmpty) return false;
  if (_looksLikeDuration(trimmed)) return true;
  if (trimmed.contains('前') ||
      trimmed.contains('月') ||
      trimmed.contains('日')) {
    return false;
  }
  return RegExp(
    r'(\d+)\s*(?:小時|分鐘|分|秒鐘|秒|(?:hr|hrs|hour|hours|min|mins|minute|minutes|sec|secs)\b)',
    caseSensitive: false,
  ).hasMatch(trimmed);
}

Duration _parsePodcastDuration(String raw) {
  final trimmed = raw.replaceAll(RegExp(r'^[•·\s]+'), '').trim();
  if (trimmed.isEmpty) return Duration.zero;
  if (_looksLikeDuration(trimmed)) {
    return _parseDuration(trimmed);
  }
  final colonMatch =
      RegExp(r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b').firstMatch(trimmed);
  if (colonMatch != null) {
    final parsed = _parseDuration(colonMatch.group(1)!);
    if (parsed > Duration.zero) return parsed;
  }

  final hrMatch = RegExp(
    r'(\d+)\s*(?:小時|hr|hrs|hour|hours)',
    caseSensitive: false,
  ).firstMatch(trimmed);
  final minMatch = RegExp(
    r'(\d+)\s*(?:分鐘|分|min|mins|minute|minutes)',
    caseSensitive: false,
  ).firstMatch(trimmed);
  final secMatch = RegExp(
    r'(\d+)\s*(?:秒鐘|秒|sec|secs|second|seconds)',
    caseSensitive: false,
  ).firstMatch(trimmed);

  final hours = hrMatch != null ? (int.tryParse(hrMatch.group(1)!) ?? 0) : 0;
  final mins = minMatch != null ? (int.tryParse(minMatch.group(1)!) ?? 0) : 0;
  final secs = secMatch != null ? (int.tryParse(secMatch.group(1)!) ?? 0) : 0;

  if (hours == 0 && mins == 0 && secs == 0) return Duration.zero;
  return Duration(hours: hours, minutes: mins, seconds: secs);
}

extension _YtmPodcastEpisodeParser on YouTubeMusicProvider {
  List<PodcastEpisode> _parsePodcastEpisodesFromJson(
    Map<String, dynamic> root, {
    String? fallbackShowId,
    String? fallbackShowTitle,
    String? fallbackAuthor,
    String? fallbackArtworkUrl,
    bool allowAllResponsiveItems = false,
  }) {
    final resolvedFallbackArt =
        BaseStreamingProvider.upgradeCoverUrl(
          fallbackArtworkUrl,
          targetSize: 1200,
        ) ??
        _extractRootFallbackThumbnail(root);
    final episodes = <PodcastEpisode>[];
    final seenVideoIds = <String>{};

    // 1. musicMultiRowListItemRenderer (primary renderer for show episodes & new episodes)
    for (final item
        in _collectMapsByKey(root, 'musicMultiRowListItemRenderer')) {
      final rawVid = _extractPodcastVideoIdFromItem(item);
      if (rawVid == null) continue;
      final cleanVid = _ytmTryExtractCleanVideoId(rawVid);
      if (cleanVid == null || !seenVideoIds.add(cleanVid)) continue;

      final title =
          (_extractInnerTubeText(item['title']) ?? '未命名單集').trim();
      final description = _extractPodcastDescription(item['description']);

      var showId = fallbackShowId ?? '';
      var showTitle = fallbackShowTitle ?? '';
      var author = fallbackAuthor ?? '';
      String? publishedLabel;
      var duration = Duration.zero;

      for (final run in <Map<String, dynamic>>[
        ..._extractRunsFromTextObject(item['subtitle']),
        ..._extractRunsFromTextObject(item['secondTitle']),
      ]) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final runBrowseId = _extractBrowseId(run['navigationEndpoint'])?.trim();
        final runPageType = _extractPageType(run);
        if (runPageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
            (runBrowseId != null && runBrowseId.startsWith('MPSP'))) {
          if (runBrowseId != null && runBrowseId.isNotEmpty) {
            showId = runBrowseId;
          }
          showTitle = text;
        } else if (runPageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
            runPageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          author = text;
        } else if (_looksLikePodcastDuration(text)) {
          duration = _parsePodcastDuration(text);
        } else if (!text.startsWith('觀看次數') &&
            !text.toLowerCase().contains('views')) {
          publishedLabel ??= text;
        }
      }

      if (duration == Duration.zero) {
        duration = _extractDurationFromPlaybackProgress(
          item['playbackProgress'],
        );
      }

      final artworkUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallbackArt;

      episodes.add(
        PodcastEpisode(
          videoId: cleanVid,
          showId: showId,
          showTitle: showTitle,
          title: title,
          author: author.isNotEmpty ? author : showTitle,
          artworkUrl: artworkUrl,
          publishedLabel: publishedLabel,
          duration: duration,
          description: description,
        ),
      );
    }

    // 2. musicResponsiveListItemRenderer (search episodes & compact shelves)
    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      if (!_isResponsiveItemPodcastEpisode(
        item,
        allowAll: allowAllResponsiveItems,
      )) {
        continue;
      }

      final rawVid = _extractPodcastVideoIdFromItem(item);
      if (rawVid == null) continue;
      final cleanVid = _ytmTryExtractCleanVideoId(rawVid);
      if (cleanVid == null || !seenVideoIds.add(cleanVid)) continue;

      final flexCols = item['flexColumns'];
      final title =
          (_extractFlexColumnText(flexCols, 0) ?? '未命名單集').trim();
      final subRuns = _extractFlexColumnRuns(flexCols, 1);

      var showId = fallbackShowId ?? '';
      var showTitle = fallbackShowTitle ?? '';
      var author = fallbackAuthor ?? '';
      String? publishedLabel;
      var duration = Duration.zero;
      final extraTexts = <String>[];

      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final lower = text.toLowerCase();
        if (lower == 'episode' || text == '單集節目' || text == '單集') {
          continue;
        }
        final runBrowseId = _extractBrowseId(run['navigationEndpoint'])?.trim();
        final runPageType = _extractPageType(run);
        if (runPageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
            (runBrowseId != null && runBrowseId.startsWith('MPSP'))) {
          if (runBrowseId != null && runBrowseId.isNotEmpty) {
            showId = runBrowseId;
          }
          showTitle = text;
        } else if (runPageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
            runPageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          author = text;
        } else if (_looksLikePodcastDuration(text)) {
          duration = _parsePodcastDuration(text);
        } else {
          extraTexts.add(text);
        }
      }

      if (extraTexts.isNotEmpty) {
        publishedLabel ??= extraTexts.first;
        if (showTitle.isEmpty && extraTexts.length >= 2) {
          showTitle = extraTexts[1];
        }
      }

      final fixedCols = item['fixedColumns'];
      final fixedDurText = _extractFixedColumnText(fixedCols, 0);
      if (duration == Duration.zero &&
          fixedDurText != null &&
          _looksLikePodcastDuration(fixedDurText)) {
        duration = _parsePodcastDuration(fixedDurText);
      }
      if (duration == Duration.zero) {
        duration = _extractDurationFromPlaybackProgress(
          item['playbackProgress'],
        );
      }

      final description = _extractPodcastDescription(item['description']) ??
          _extractFlexColumnText(flexCols, 2);

      final artworkUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallbackArt;

      episodes.add(
        PodcastEpisode(
          videoId: cleanVid,
          showId: showId,
          showTitle: showTitle,
          title: title,
          author: author.isNotEmpty ? author : showTitle,
          artworkUrl: artworkUrl,
          publishedLabel: publishedLabel,
          duration: duration,
          description: description,
        ),
      );
    }

    return episodes;
  }
}
