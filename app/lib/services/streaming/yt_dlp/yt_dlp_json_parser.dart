part of '../yt_dlp_service.dart';

YtDlpResolvedStream _parseResolvedStreamJsonImpl({
  required String videoId,
  required String rawStdout,
  required DateTime now,
}) {
  final trimmed = rawStdout.trim();
  if (trimmed.isEmpty) {
    throw const YtDlpException('yt-dlp 未回傳任何串流資訊');
  }

  Map<String, dynamic>? root;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      root = decoded;
    }
  } catch (_) {
    // Fallback: yt-dlp occasionally emits multiple JSON lines; find the first JSON object.
    for (final line in LineSplitter.split(trimmed)) {
      final candidate = line.trim();
      if (!candidate.startsWith('{')) continue;
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map<String, dynamic>) {
          root = decoded;
          break;
        }
      } catch (_) {}
    }
  }

  if (root == null) {
    throw const YtDlpException('yt-dlp JSON 解析失敗');
  }

  Map<String, dynamic>? fallbackFormat;
  var url = _nonEmptyString(root['url']);
  if (url == null) {
    fallbackFormat =
        _pickAudioFormatFromList(root['requested_formats']) ??
        _pickAudioFormatFromList(root['formats']);
    url = _nonEmptyString(fallbackFormat?['url']);
  }

  if (url == null) {
    throw const YtDlpException('yt-dlp 回傳結果中缺少可播放的音訊串流網址');
  }

  final mergedHeaders = <String, String>{};
  _copyStringHeaders(root['http_headers'], mergedHeaders);
  _copyStringHeaders(fallbackFormat?['http_headers'], mergedHeaders);
  if (mergedHeaders.isEmpty && fallbackFormat == null) {
    final reqFallback = _pickAudioFormatFromList(root['requested_formats']);
    _copyStringHeaders(reqFallback?['http_headers'], mergedHeaders);
  }

  final acodec =
      _nonEmptyCodec(fallbackFormat?['acodec']) ??
      _nonEmptyCodec(root['acodec']);
  final ext =
      _nonEmptyString(fallbackFormat?['ext']) ?? _nonEmptyString(root['ext']);
  final asr =
      _parseInt(fallbackFormat?['asr']) ?? _parseInt(root['asr']);
  final abr =
      _parseDouble(fallbackFormat?['abr']) ??
      _parseDouble(root['abr']) ??
      _parseDouble(fallbackFormat?['tbr']) ??
      _parseDouble(root['tbr']);
  final duration =
      _parseDouble(root['duration']) ??
      _parseDouble(fallbackFormat?['duration']);
  final parsedUri = Uri.tryParse(url);
  final contentLength =
      _parseInt(fallbackFormat?['filesize']) ??
      _parseInt(root['filesize']) ??
      _parseInt(fallbackFormat?['filesize_approx']) ??
      _parseInt(root['filesize_approx']) ??
      _parseInt(parsedUri?.queryParameters['clen']);
  final mimeType = _inferMimeType(
    urlMimeParam: parsedUri?.queryParameters['mime'],
    acodec: acodec,
    ext: ext,
  );
  final rawThumbnail = _nonEmptyString(root['thumbnail']);
  final thumbnail = rawThumbnail == null
      ? null
      : (upgradeStreamingCoverUrl(rawThumbnail, targetSize: 1200) ??
          rawThumbnail);

  final rawLoudness =
      _parseDouble(fallbackFormat?['loudness']) ??
      _parseDouble(root['loudness']) ??
      _parseDouble(fallbackFormat?['loudnessDb']) ??
      _parseDouble(root['loudnessDb']) ??
      _parseDouble(root['loudness_db']);
  final loudnessDb =
      (rawLoudness != null && rawLoudness.isFinite) ? rawLoudness : null;

  final expiresAt = _parseStreamExpiry(url, now);
  final availableAt =
      _parseAvailableAt(fallbackFormat?['available_at']) ??
      _parseAvailableAt(root['available_at']);

  return YtDlpResolvedStream(
    videoId: videoId,
    url: url,
    httpHeaders: Map<String, String>.unmodifiable(mergedHeaders),
    acodec: acodec,
    ext: ext,
    sampleRateHz: asr,
    bitrateKbps: abr,
    durationSeconds: duration,
    contentLength: contentLength,
    mimeType: mimeType,
    thumbnailUrl: thumbnail,
    loudnessDb: loudnessDb,
    expiresAt: expiresAt,
    availableAt: availableAt,
  );
}

String? _inferMimeType({
  String? urlMimeParam,
  String? acodec,
  String? ext,
}) {
  final lowerCodec = acodec?.trim().toLowerCase() ?? '';
  final lowerExt = ext?.trim().toLowerCase() ?? '';
  final rawUrlMime = urlMimeParam?.trim().toLowerCase() ?? '';
  if (rawUrlMime.startsWith('audio/')) {
    if (lowerCodec.isNotEmpty &&
        lowerCodec != 'none' &&
        !rawUrlMime.contains('codecs=')) {
      return '$rawUrlMime; codecs="$lowerCodec"';
    }
    return rawUrlMime;
  }
  if (lowerExt == 'webm' || lowerCodec.contains('opus')) {
    return lowerExt == 'ogg' || lowerExt == 'oga'
        ? 'audio/ogg; codecs="opus"'
        : 'audio/webm; codecs="opus"';
  }
  if (lowerExt == 'm4a' ||
      lowerExt == 'mp4' ||
      lowerCodec.startsWith('mp4a')) {
    return lowerCodec.isNotEmpty && lowerCodec != 'none'
        ? 'audio/mp4; codecs="$lowerCodec"'
        : 'audio/mp4';
  }
  if (lowerExt == 'aac' || lowerCodec == 'aac') return 'audio/aac';
  if (lowerExt == 'mp3' || lowerCodec.contains('mp3')) return 'audio/mpeg';
  if (lowerExt == 'flac' || lowerCodec.contains('flac')) return 'audio/flac';
  if (lowerExt == 'ogg' || lowerExt == 'oga' || lowerCodec.contains('vorbis')) {
    return 'audio/ogg';
  }
  if (lowerExt == 'wav' || lowerCodec.contains('pcm')) return 'audio/wav';
  return null;
}

DateTime? _parseAvailableAt(Object? raw) {
  final seconds = _parseDouble(raw);
  if (seconds == null || seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).round(),
    isUtc: true,
  );
}

Map<String, dynamic>? _pickAudioFormatFromList(Object? rawList) {
  if (rawList is! List) return null;
  Map<String, dynamic>? firstWithUrl;
  Map<String, dynamic>? bestAudio;
  double bestAbr = -1;

  for (final entry in rawList) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    final url = _nonEmptyString(map['url']);
    if (url == null) continue;
    firstWithUrl ??= map;

    final acodec = _nonEmptyCodec(map['acodec']);
    if (acodec == null) continue;

    final vcodec = _nonEmptyString(map['vcodec'])?.toLowerCase();
    final isAudioOnly = vcodec == null || vcodec == 'none';
    final abr = _parseDouble(map['abr']) ?? _parseDouble(map['tbr']) ?? 0;

    if (bestAudio == null ||
        (isAudioOnly &&
            (_nonEmptyString(bestAudio['vcodec'])?.toLowerCase() != 'none')) ||
        (isAudioOnly ==
                (_nonEmptyString(bestAudio['vcodec'])?.toLowerCase() ==
                    'none') &&
            abr > bestAbr)) {
      bestAudio = map;
      bestAbr = abr;
    }
  }

  return bestAudio ?? firstWithUrl;
}

void _copyStringHeaders(Object? raw, Map<String, String> target) {
  if (raw is! Map) return;
  for (final entry in raw.entries) {
    final k = entry.key?.toString().trim() ?? '';
    final v = entry.value?.toString().trim() ?? '';
    if (k.isNotEmpty && v.isNotEmpty) {
      target[k] = v;
    }
  }
}

DateTime _parseStreamExpiry(String url, DateTime now) {
  final uri = Uri.tryParse(url);
  final rawExpire = uri?.queryParameters['expire'];
  if (rawExpire != null) {
    final seconds = int.tryParse(rawExpire.trim());
    if (seconds != null && seconds > 0) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
  }
  return now.add(YtDlpService.defaultStreamTtl);
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _nonEmptyCodec(Object? value) {
  final s = _nonEmptyString(value);
  if (s == null || s.toLowerCase() == 'none') return null;
  return s;
}

int? _parseInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _parseDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}
