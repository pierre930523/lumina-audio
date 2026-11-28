part of '../youtube_music_provider.dart';

final RegExp _validVideoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
int _tempCookieSeq = 0;

/// Parses `SAPISID` / `__Secure-3PAPISID` / `__Secure-1PAPISID` from a browser
/// Cookie header.
String? _ytmExtractSapisidFromCookie(String cookieHeader) {
  final map = <String, String>{};
  for (final part in cookieHeader.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final name = part.substring(0, idx).trim();
    var value = part.substring(idx + 1).trim();
    if (value.length >= 2 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (name.isNotEmpty && value.isNotEmpty) {
      map[name] = value;
    }
  }
  return map['SAPISID'] ??
      map['__Secure-3PAPISID'] ??
      map['__Secure-1PAPISID'];
}

String _ytmComputeSapisidHash(
  String sapisid, {
  required int timestampSeconds,
  String origin = YouTubeMusicProvider._ytMusicOrigin,
}) {
  final digest = sha1
      .convert(utf8.encode('$timestampSeconds $sapisid $origin'))
      .toString();
  return 'SAPISIDHASH ${timestampSeconds}_$digest';
}

/// Non-throwing variant of [_ytmExtractCleanVideoId] for background preloaders.
String? _ytmTryExtractCleanVideoId(String rawId, {String? filePath}) {
  try {
    return _ytmExtractCleanVideoId(rawId, filePath: filePath);
  } catch (_) {
    return null;
  }
}

/// Strips internal prefixes (`ytm:`, `ytm_`, `streaming:youtube_music:`,
/// `youtube_music:`), extracts the `v` param or `youtu.be/<id>` segment from
/// YouTube URLs, and strictly validates a pure 11-char YouTube Video ID.
///
/// Rejects `browseId` (`MPREb_`, `VL`, `FE`, `UC`) and `playlistId` (`PL`,
/// `RD`, `OLAK`) values with a descriptive [StreamingException].
String _ytmExtractCleanVideoId(String rawId, {String? filePath}) {
  var candidate = _extractCandidateVideoId(rawId);
  if (candidate == null || candidate.isEmpty) {
    if (filePath != null && filePath.trim().isNotEmpty) {
      candidate = _extractCandidateVideoId(filePath);
    }
  } else if (_classifyNonVideoId(candidate) == null &&
      !_validVideoIdPattern.hasMatch(candidate) &&
      filePath != null &&
      filePath.trim().isNotEmpty) {
    final fromFile = _extractCandidateVideoId(filePath);
    if (fromFile != null &&
        fromFile.isNotEmpty &&
        _classifyNonVideoId(fromFile) == null &&
        _validVideoIdPattern.hasMatch(fromFile)) {
      candidate = fromFile;
    }
  }

  if (candidate == null || candidate.isEmpty) {
    throw const StreamingException('曲目缺少有效的 YouTube videoId');
  }

  final nonVideoKind = _classifyNonVideoId(candidate);
  if (nonVideoKind != null) {
    throw StreamingException(
      '無效的 YouTube videoId：不支援 $nonVideoKind（$candidate）',
    );
  }

  if (!_validVideoIdPattern.hasMatch(candidate)) {
    throw StreamingException(
      '無效的 YouTube videoId（須為 11 碼英數字元）：$candidate',
    );
  }

  return candidate;
}

String? _extractCandidateVideoId(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  // Repeatedly strip internal prefixes.
  var changed = true;
  while (changed && s.isNotEmpty) {
    changed = false;
    for (final prefix in const <String>[
      'streaming:youtube_music:',
      'youtube_music:',
      'ytm:',
    ]) {
      if (s.startsWith(prefix)) {
        s = s.substring(prefix.length).trim();
        changed = true;
      }
    }
    if (s.startsWith('ytm_') && s.length > 11) {
      s = s.substring(4).trim();
      changed = true;
    }
    if (s.startsWith('MPED') && s.length == 15) {
      s = s.substring(4).trim();
      changed = true;
    }
  }

  if (s.isEmpty) return null;

  // Extract videoId from YouTube / YouTube Music / youtu.be URLs.
  final lower = s.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.contains('youtube.com/') ||
      lower.contains('youtu.be/')) {
    final uri = Uri.tryParse(
      (lower.startsWith('http://') || lower.startsWith('https://'))
          ? s
          : 'https://$s',
    );
    if (uri != null) {
      final host = uri.host.toLowerCase();
      if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
        final segs = uri.pathSegments.where((seg) => seg.isNotEmpty).toList();
        if (segs.isNotEmpty) {
          return segs.first.trim();
        }
        return null;
      }
      if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
        final v = uri.queryParameters['v']?.trim();
        if (v != null && v.isNotEmpty) {
          return v;
        }
        final segs = uri.pathSegments.where((seg) => seg.isNotEmpty).toList();
        if (segs.length >= 2 &&
            (segs.first == 'embed' ||
                segs.first == 'shorts' ||
                segs.first == 'v')) {
          return segs[1].trim();
        }
        final listParam = uri.queryParameters['list']?.trim();
        if (listParam != null && listParam.isNotEmpty) {
          return listParam;
        }
        return null;
      }
    }
  }

  return s;
}

String? _classifyNonVideoId(String value) {
  if (value.startsWith('MPREb_') ||
      value.startsWith('MPSP') ||
      value.startsWith('VL') ||
      value.startsWith('FE') ||
      value.startsWith('UC')) {
    return 'browseId';
  }
  if (value.startsWith('PL') ||
      value.startsWith('RD') ||
      value.startsWith('OLAK')) {
    return 'playlistId';
  }
  return null;
}

/// Converts a browser `Cookie` header into a valid Netscape HTTP Cookie File
/// covering `.youtube.com` and `music.youtube.com` for `yt-dlp --cookies`.
String _ytmBuildNetscapeCookiesContent(
  String cookieHeader, {
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final expiry =
      (effectiveNow.millisecondsSinceEpoch ~/ 1000) + (86400 * 30);
  final buf = StringBuffer()
    ..writeln('# Netscape HTTP Cookie File')
    ..writeln('# Temporary file generated by Lumina Audio');

  final seenPairs = <String>{};
  for (final rawPart in cookieHeader.split(';')) {
    final idx = rawPart.indexOf('=');
    if (idx <= 0) continue;
    final name = rawPart
        .substring(0, idx)
        .replaceAll(RegExp(r'[\r\n\t]'), '')
        .trim();
    var value = rawPart
        .substring(idx + 1)
        .replaceAll(RegExp(r'[\r\n\t]'), '')
        .trim();
    if (value.length >= 2 &&
        value.startsWith('"') &&
        value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (name.isEmpty || value.isEmpty) continue;
    if (!seenPairs.add(name)) continue;

    if (!name.startsWith('__Host-')) {
      buf.writeln('.youtube.com\tTRUE\t/\tTRUE\t$expiry\t$name\t$value');
    }
    buf.writeln('music.youtube.com\tFALSE\t/\tTRUE\t$expiry\t$name\t$value');
  }
  return buf.toString();
}

extension _YtmSecurity on YouTubeMusicProvider {
  Future<File> _writeTempNetscapeCookiesFile(String netscapeContent) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final seq = ++_tempCookieSeq;
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'lumina_ytm_cookies_${pid}_${stamp}_$seq.txt';
    final file = File(path);
    await file.writeAsString(netscapeContent, flush: true);
    return file;
  }

  String _redactSecrets(String input) {
    var out = input;
    final cookie = _cookie;
    if (cookie != null && cookie.isNotEmpty) {
      out = out.replaceAll(cookie, '[REDACTED]');
      final sapisid = _ytmExtractSapisidFromCookie(cookie);
      if (sapisid != null && sapisid.isNotEmpty) {
        out = out.replaceAll(sapisid, '[REDACTED]');
      }
    }
    final token = _accessToken;
    if (token != null && token.isNotEmpty) {
      out = out.replaceAll(token, '[REDACTED]');
    }
    return out;
  }
}
