part of '../youtube_music_provider.dart';

String? _extractPodcastDescription(dynamic node) {
  if (node == null) return null;
  final direct = _extractInnerTubeText(node)?.trim();
  if (direct != null && direct.isNotEmpty) return direct;
  if (node is Map) {
    final descShelf = node['musicDescriptionShelfRenderer'] ??
        _findFirstMapByKey(node, 'musicDescriptionShelfRenderer');
    if (descShelf is Map) {
      final nested =
          _extractInnerTubeText(descShelf['description'])?.trim();
      if (nested != null && nested.isNotEmpty) return nested;
    }
    if (node['description'] != null) {
      final inner = _extractInnerTubeText(node['description'])?.trim();
      if (inner != null && inner.isNotEmpty) return inner;
    }
  }
  return null;
}

String? _extractPodcastEpisodeContinuationToken(
  Map<String, dynamic> root,
) {
  for (final shelfKey in const <String>[
    'musicShelfRenderer',
    'musicShelfContinuation',
    'musicPlaylistShelfRenderer',
    'sectionListRenderer',
    'sectionListContinuation',
  ]) {
    for (final shelf in _collectMapsByKey(root, shelfKey)) {
      final conts = shelf['continuations'];
      if (conts != null) {
        final nextData = _findFirstMapByKey(conts, 'nextContinuationData');
        final tok1 = nextData?['continuation']?.toString().trim();
        if (tok1 != null && tok1.isNotEmpty) return tok1;
        final cmd = _findFirstMapByKey(conts, 'continuationCommand');
        final tok2 = cmd?['token']?.toString().trim();
        if (tok2 != null && tok2.isNotEmpty) return tok2;
      }
    }
  }
  return _extractContinuationToken(root);
}

extension _YtmPodcastShowParser on YouTubeMusicProvider {
  List<PodcastShow> _parsePodcastShowsFromJson(
    Map<String, dynamic> root, {
    bool allowAllShowItems = false,
  }) {
    final shows = <PodcastShow>[];
    final seen = <String>{};

    bool isPodcastShowIdOrPage(
      String? browseId,
      String? pageType, {
      required bool allowFallback,
    }) {
      if (browseId == null || browseId.isEmpty) return false;
      if (pageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
          browseId.startsWith('MPSP')) {
        return true;
      }
      if (!allowFallback) return false;
      if (browseId.startsWith('MPED') ||
          browseId.startsWith('MPRE') ||
          browseId.startsWith('MPTC') ||
          browseId.startsWith('UC') ||
          browseId.startsWith('FE')) {
        return false;
      }
      if (pageType != null &&
          pageType.isNotEmpty &&
          pageType != 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' &&
          pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') {
        return false;
      }
      return true;
    }

    // 1. musicTwoRowItemRenderer (grid cards on Explore / Library / Shelves)
    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      var browseId = _extractBrowseId(item['navigationEndpoint'])?.trim();
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) {
        final watchPl =
            _findFirstMapByKey(item, 'watchPlaylistEndpoint')?['playlistId']
                ?.toString()
                .trim();
        if (watchPl != null && watchPl.startsWith('PL')) {
          browseId = 'MPSP$watchPl';
        }
      }
      if (!isPodcastShowIdOrPage(
        browseId,
        pageType,
        allowFallback: allowAllShowItems,
      )) {
        continue;
      }
      final normalizedId =
          (browseId!.startsWith('PL') && !browseId.startsWith('MPSP'))
              ? 'MPSP$browseId'
              : browseId;
      if (!seen.add(normalizedId)) continue;

      final title =
          (_extractInnerTubeText(item['title']) ?? '未命名 Podcast').trim();
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      var author = '';
      String? episodeCountLabel;
      for (final p in parts) {
        final lower = p.toLowerCase();
        if (lower == 'podcast' || p == '播客' || p == '節目') continue;
        if (RegExp(r'\d+\s*(集|episodes?)', caseSensitive: false).hasMatch(p)) {
          episodeCountLabel ??= p;
        } else if (author.isEmpty) {
          author = p;
        }
      }
      final artworkUrl = _extractThumbnailUrl(item['thumbnailRenderer']) ??
          _extractThumbnailUrl(item['thumbnail']);

      shows.add(
        PodcastShow(
          id: normalizedId,
          title: title,
          author: author,
          artworkUrl: artworkUrl,
          episodeCountLabel: episodeCountLabel,
        ),
      );
    }

    // 2. musicResponsiveListItemRenderer (search / library rows)
    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final hasPlaylistVideoId = item['playlistItemData'] is Map &&
          (item['playlistItemData']['videoId']?.toString().trim().isNotEmpty ==
              true);
      final col0Runs = _extractFlexColumnRuns(item['flexColumns'], 0);
      final col0HasEpisodePage = col0Runs.any((r) {
        final pt = _extractPageType(r);
        final bid = _extractBrowseId(r['navigationEndpoint']) ?? '';
        return pt == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE' ||
            bid.startsWith('MPED');
      });
      if (hasPlaylistVideoId || col0HasEpisodePage) {
        continue;
      }

      var browseId = _extractBrowseId(item['navigationEndpoint'])?.trim();
      var pageType = _extractPageType(item['navigationEndpoint']);

      if (browseId == null || browseId.isEmpty) {
        for (final r in col0Runs) {
          final bid = _extractBrowseId(r['navigationEndpoint'])?.trim();
          if (bid != null && bid.isNotEmpty) {
            browseId = bid;
            pageType ??= _extractPageType(r);
            break;
          }
        }
      }
      if (browseId == null || browseId.isEmpty) {
        final watchPl =
            _findFirstMapByKey(item, 'watchPlaylistEndpoint')?['playlistId']
                ?.toString()
                .trim();
        if (watchPl != null && watchPl.startsWith('PL')) {
          browseId = 'MPSP$watchPl';
        }
      }

      if (!isPodcastShowIdOrPage(
        browseId,
        pageType,
        allowFallback: allowAllShowItems,
      )) {
        continue;
      }
      final normalizedId =
          (browseId!.startsWith('PL') && !browseId.startsWith('MPSP'))
              ? 'MPSP$browseId'
              : browseId;
      if (!seen.add(normalizedId)) continue;

      final title =
          (_extractFlexColumnText(item['flexColumns'], 0) ?? '未命名 Podcast')
              .trim();
      final subRuns = _extractFlexColumnRuns(item['flexColumns'], 1);
      var author = '';
      String? episodeCountLabel;
      String? latestEpisodeTitle;

      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final lower = text.toLowerCase();
        if (lower == 'podcast' || text == '播客' || text == '節目') continue;
        final rt = _extractPageType(run);
        if (rt == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
            rt == 'MUSIC_PAGE_TYPE_ARTIST') {
          author = text;
        } else if (RegExp(
          r'\d+\s*(集|episodes?)',
          caseSensitive: false,
        ).hasMatch(text)) {
          episodeCountLabel ??= text;
        } else if (author.isEmpty) {
          author = text;
        } else {
          latestEpisodeTitle ??= text;
        }
      }

      final artworkUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']);

      shows.add(
        PodcastShow(
          id: normalizedId,
          title: title,
          author: author,
          artworkUrl: artworkUrl,
          episodeCountLabel: episodeCountLabel,
          latestEpisodeTitle: latestEpisodeTitle,
        ),
      );
    }

    return shows;
  }
}
