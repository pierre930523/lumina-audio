part of '../ytm_resident_resolver.dart';

extension _YtmFormatSelectorExt on YtmResidentResolver {
  DirectRangeSpec? _extractPreferredDirectRangeSpec({
    required StreamKey key,
    required Map<String, dynamic> playerJson,
    required _ResidentClientProfile profile,
    PoToken? gvsToken,
  }) {
    final playability = playerJson['playabilityStatus'];
    if (playability is Map) {
      final status = playability['status']?.toString();
      if (status != null && status != 'OK') {
        return null;
      }
    }

    final streamingData = playerJson['streamingData'];
    if (streamingData is! Map) return null;

    final candidates = <Map<String, dynamic>>[];
    for (final listKey in const <String>['adaptiveFormats', 'formats']) {
      final rawList = streamingData[listKey];
      if (rawList is! List) continue;
      for (final item in rawList) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final mime = map['mimeType']?.toString().toLowerCase() ?? '';
        final url = map['url']?.toString().trim() ?? '';
        if (!mime.startsWith('audio/') || url.isEmpty) continue;
        final lowerUrl = url.toLowerCase();
        if (lowerUrl.contains('.m3u8') ||
            lowerUrl.contains('.mpd') ||
            lowerUrl.contains('/hls_playlist/') ||
            lowerUrl.contains('/dash/')) {
          continue;
        }
        // Reject undecrypted `n`-parameter URLs on WEB_REMIX so they never
        // cause CDN throttling or HTTP 403 and cleanly fall through to yt-dlp + deno.
        if (profile.isWebRemix && _hasQueryParam(url, 'n')) {
          continue;
        }
        candidates.add(map);
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final itagA = _parseInt(a['itag']) ?? -1;
      final itagB = _parseInt(b['itag']) ?? -1;
      final mimeA = a['mimeType']?.toString().toLowerCase() ?? '';
      final mimeB = b['mimeType']?.toString().toLowerCase() ?? '';
      final tierA = YtmResidentResolver.formatPreferenceTier(itagA, mimeA);
      final tierB = YtmResidentResolver.formatPreferenceTier(itagB, mimeB);
      if (tierA != tierB) return tierB.compareTo(tierA);

      final bitA = _parseInt(a['bitrate']) ?? _parseInt(a['averageBitrate']) ?? 0;
      final bitB = _parseInt(b['bitrate']) ?? _parseInt(b['averageBitrate']) ?? 0;
      return bitB.compareTo(bitA);
    });

    final best = candidates.first;
    final url = best['url']!.toString().trim();
    final itag = _parseInt(best['itag']) ?? -1;
    final rawMime = best['mimeType']?.toString().trim() ?? '';
    final lowerMime = rawMime.toLowerCase();

    final AudioCodec codec;
    final String hintExt;
    if (itag == 251 ||
        itag == 250 ||
        itag == 249 ||
        lowerMime.contains('opus') ||
        lowerMime.contains('webm')) {
      codec = AudioCodec.opus;
      hintExt = 'webm';
    } else if (lowerMime.contains('flac')) {
      codec = AudioCodec.flac;
      hintExt = 'flac';
    } else if (lowerMime.contains('mp3') || lowerMime.contains('mpeg')) {
      codec = AudioCodec.mp3;
      hintExt = 'mp3';
    } else if (lowerMime.contains('vorbis') || lowerMime.contains('ogg')) {
      codec = AudioCodec.opus;
      hintExt = 'ogg';
    } else if (lowerMime.contains('wav')) {
      codec = AudioCodec.wav;
      hintExt = 'wav';
    } else {
      codec = AudioCodec.aac;
      hintExt = 'm4a';
    }

    final contentLength = _parseInt(best['contentLength']);
    final bitrateBps =
        _parseInt(best['bitrate']) ?? _parseInt(best['averageBitrate']);
    final sampleRate = _parseInt(best['audioSampleRate']) ??
        (codec == AudioCodec.opus ? 48000 : 44100);
    final channels = _parseInt(best['audioChannels']) ?? 2;

    final initRange = best['initRange'];
    final indexRange = best['indexRange'];
    final initRangeEnd =
        initRange is Map ? _parseInt(initRange['end']) : null;
    final indexRangeStart =
        indexRange is Map ? _parseInt(indexRange['start']) : null;
    final indexRangeEnd =
        indexRange is Map ? _parseInt(indexRange['end']) : null;

    var finalUrl = url;
    final parsedUri = Uri.tryParse(url);
    if (gvsToken != null && gvsToken.token.isNotEmpty) {
      finalUrl = YtmResidentResolver.appendPotQueryParam(
        finalUrl,
        gvsToken.token,
      );
    }

    final urlExpire = _parseInt(parsedUri?.queryParameters['expire']);
    final expiresInSec = _parseInt(streamingData['expiresInSeconds']);
    final nowSec = _clock().millisecondsSinceEpoch ~/ 1000;
    final expireAt = urlExpire ??
        (expiresInSec != null && expiresInSec > 0 ? nowSec + expiresInSec : null);

    final playbackHeaders = <String, String>{
      'User-Agent': profile.userAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
      if (profile.isWebRemix) ...<String, String>{
        'Origin': YtmResidentResolver.defaultMusicOrigin,
        'Referer': '${YtmResidentResolver.defaultMusicOrigin}/',
      },
    };

    NormalizedLoudness? loudness;
    final playerConfig = playerJson['playerConfig'];
    if (playerConfig is Map) {
      final audioConfig = playerConfig['audioConfig'];
      if (audioConfig is Map) {
        final rawLoudness = audioConfig['loudnessDb'];
        final parsedLoudness = rawLoudness is num
            ? rawLoudness.toDouble()
            : (rawLoudness is String
                  ? double.tryParse(rawLoudness.trim())
                  : null);
        if (parsedLoudness != null && parsedLoudness.isFinite) {
          loudness = NormalizedLoudness.fromYtmLoudnessDb(parsedLoudness);
        }
      }
    }

    final resolvedMime = rawMime.isNotEmpty
        ? rawMime
        : switch (hintExt) {
            'webm' => 'audio/webm; codecs="opus"',
            'mp3' => 'audio/mpeg',
            'ogg' => 'audio/ogg',
            'flac' => 'audio/flac',
            'wav' => 'audio/wav',
            _ => 'audio/mp4',
          };

    return DirectRangeSpec(
      key: key,
      url: finalUrl,
      headers: playbackHeaders,
      contentLength: contentLength,
      bitrateBps: bitrateBps,
      mimeType: resolvedMime,
      hintExtension: hintExt,
      expireAt: expireAt,
      initRangeEnd: initRangeEnd,
      indexRangeStart: indexRangeStart,
      indexRangeEnd: indexRangeEnd,
      loudness: loudness,
      audioFormat: AudioFormat(
        codec: codec,
        sampleRateHz: sampleRate,
        bitDepth: 16,
        channels: channels,
      ),
    );
  }
}

int _formatPreferenceTier(int itag, String lowerMime) {
  if (itag == 251) return 100;
  if (itag == 140) return 90;
  if (itag == 141) return 80;
  if (itag == 250) return 75;
  if (itag == 249) return 70;
  if (lowerMime.contains('opus') || lowerMime.contains('webm')) return 65;
  if (itag == 139) return 60;
  if (lowerMime.contains('audio/mp4') ||
      lowerMime.contains('mp4a') ||
      lowerMime.contains('aac')) {
    return 55;
  }
  if (lowerMime.contains('flac') ||
      lowerMime.contains('mp3') ||
      lowerMime.contains('mpeg') ||
      lowerMime.contains('vorbis') ||
      lowerMime.contains('wav') ||
      lowerMime.contains('alac')) {
    return 40;
  }
  return 10;
}

String _appendPotQueryParam(String url, String potToken) {
  final trimmedUrl = url.trim();
  final trimmedPot = potToken.trim();
  if (trimmedUrl.isEmpty || trimmedPot.isEmpty) return trimmedUrl;
  final parsedUri = Uri.tryParse(trimmedUrl);
  if (parsedUri == null || parsedUri.queryParameters.containsKey('pot')) {
    return trimmedUrl;
  }
  final hashIdx = trimmedUrl.indexOf('#');
  final base = hashIdx >= 0 ? trimmedUrl.substring(0, hashIdx) : trimmedUrl;
  final fragment = hashIdx >= 0 ? trimmedUrl.substring(hashIdx) : '';
  final sep = base.contains('?')
      ? ((base.endsWith('?') || base.endsWith('&')) ? '' : '&')
      : '?';
  return '$base${sep}pot=${Uri.encodeQueryComponent(trimmedPot)}$fragment';
}

int? _parseInt(dynamic raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}
