part of '../youtube_music_provider.dart';

Map<String, dynamic>? _findFirstMapByKey(dynamic node, String key) {
  if (node is Map) {
    if (node.containsKey(key) && node[key] is Map) {
      return Map<String, dynamic>.from(node[key] as Map);
    }
    for (final value in node.values) {
      final found = _findFirstMapByKey(value, key);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final item in node) {
      final found = _findFirstMapByKey(item, key);
      if (found != null) return found;
    }
  }
  return null;
}

List<Map<String, dynamic>> _collectMapsByKey(
  dynamic node,
  String key,
) {
  final results = <Map<String, dynamic>>[];
  void walk(dynamic current) {
    if (current is Map) {
      if (current.containsKey(key) && current[key] is Map) {
        results.add(Map<String, dynamic>.from(current[key] as Map));
      }
      for (final val in current.values) {
        walk(val);
      }
    } else if (current is List) {
      for (final item in current) {
        walk(item);
      }
    }
  }

  walk(node);
  return results;
}

String? _extractInnerTubeText(dynamic obj) {
  if (obj == null) return null;
  if (obj is String) return obj;
  if (obj is Map) {
    final simple = obj['simpleText']?.toString();
    if (simple != null && simple.isNotEmpty) return simple;
    final runs = obj['runs'];
    if (runs is List) {
      final buf = StringBuffer();
      for (final r in runs) {
        if (r is Map && r['text'] != null) {
          buf.write(r['text'].toString());
        }
      }
      final text = buf.toString();
      if (text.isNotEmpty) return text;
    }
  }
  return null;
}

String? _extractVideoIdFromRenderer(Map<String, dynamic> item) {
  final playlistData = item['playlistItemData'];
  if (playlistData is Map && playlistData['videoId'] != null) {
    return playlistData['videoId'].toString();
  }
  final watch = _findFirstMapByKey(item, 'watchEndpoint');
  if (watch != null && watch['videoId'] != null) {
    return watch['videoId'].toString();
  }
  return null;
}

String? _extractBrowseId(dynamic navEndpoint) {
  if (navEndpoint is! Map) return null;
  final browse = navEndpoint['browseEndpoint'];
  if (browse is Map) {
    return browse['browseId']?.toString();
  }
  return null;
}

String? _extractPageType(dynamic node) {
  final cfg = _findFirstMapByKey(
    node,
    'browseEndpointContextMusicConfig',
  );
  return cfg?['pageType']?.toString();
}

String? _extractFlexColumnText(dynamic flexCols, int index) {
  if (flexCols is! List || index >= flexCols.length) return null;
  final col = flexCols[index];
  if (col is! Map) return null;
  final renderer = col['musicResponsiveListItemFlexColumnRenderer'];
  if (renderer is! Map) return null;
  return _extractInnerTubeText(renderer['text']);
}

List<Map<String, dynamic>> _extractFlexColumnRuns(
  dynamic flexCols,
  int index,
) {
  if (flexCols is! List || index >= flexCols.length) return const [];
  final col = flexCols[index];
  if (col is! Map) return const [];
  final renderer = col['musicResponsiveListItemFlexColumnRenderer'];
  if (renderer is! Map) return const [];
  final text = renderer['text'];
  if (text is! Map) return const [];
  final runs = text['runs'];
  if (runs is! List) return const [];
  return runs
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

String? _extractFixedColumnText(dynamic fixedCols, int index) {
  if (fixedCols is! List || index >= fixedCols.length) return null;
  final col = fixedCols[index];
  if (col is! Map) return null;
  final renderer = col['musicResponsiveListItemFixedColumnRenderer'];
  if (renderer is! Map) return null;
  return _extractInnerTubeText(renderer['text']);
}

String? _extractRootFallbackThumbnail(Map<String, dynamic> root) {
  final header = root['header'];
  if (header is Map) {
    final direct = _extractThumbnailUrl(header['thumbnail']);
    if (direct != null) return direct;
    final respHeader =
        _findFirstMapByKey(header, 'musicResponsiveHeaderRenderer') ??
            _findFirstMapByKey(header, 'musicDetailHeaderRenderer');
    final nested = _extractThumbnailUrl(respHeader?['thumbnail']);
    if (nested != null) return nested;
  }
  return _extractThumbnailUrl(root['thumbnail']);
}

String? _extractThumbnailUrl(dynamic node) {
  if (node == null) return null;
  dynamic list;
  if (node is List) {
    list = node;
  } else {
    final thumb = _findFirstMapByKey(node, 'musicThumbnailRenderer') ??
        _findFirstMapByKey(node, 'croppedSquareThumbnailRenderer') ??
        (node is Map && node['thumbnails'] is List
            ? Map<String, dynamic>.from(node)
            : (node is Map && node['thumbnail'] is Map
                  ? Map<String, dynamic>.from(node['thumbnail'] as Map)
                  : null));
    if (thumb == null) return null;
    list = thumb['thumbnails'] ??
        (thumb['thumbnail'] is Map ? thumb['thumbnail']['thumbnails'] : null);
  }
  if (list is! List || list.isEmpty) return null;

  String? bestByAreaUrl;
  var bestArea = -1;
  String? lastValidUrl;
  for (final entry in list) {
    if (entry is! Map) continue;
    final normalized = BaseStreamingProvider.normalizeCoverUrl(
      entry['url']?.toString(),
    );
    if (normalized == null) continue;
    lastValidUrl = normalized;
    final w = (entry['width'] as num?)?.toInt() ?? 0;
    final h = (entry['height'] as num?)?.toInt() ?? 0;
    final area = (w > 0 && h > 0) ? (w * h) : 0;
    if (area > 0 && area >= bestArea) {
      bestArea = area;
      bestByAreaUrl = normalized;
    }
  }
  final chosen = bestByAreaUrl ?? lastValidUrl;
  return upgradeStreamingCoverUrl(chosen, targetSize: 1200);
}

bool _looksLikeDuration(String text) =>
    RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim());

Duration _parseDuration(String raw) {
  final parts = raw.trim().split(':').map(int.tryParse).toList();
  if (parts.any((e) => e == null)) return Duration.zero;
  if (parts.length == 2) {
    return Duration(minutes: parts[0]!, seconds: parts[1]!);
  }
  if (parts.length == 3) {
    return Duration(
      hours: parts[0]!,
      minutes: parts[1]!,
      seconds: parts[2]!,
    );
  }
  return Duration.zero;
}

List<Map<String, dynamic>> _extractRunsFromTextObject(dynamic obj) {
  if (obj is! Map) return const <Map<String, dynamic>>[];
  final runs = obj['runs'];
  if (runs is! List) return const <Map<String, dynamic>>[];
  return runs
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}
