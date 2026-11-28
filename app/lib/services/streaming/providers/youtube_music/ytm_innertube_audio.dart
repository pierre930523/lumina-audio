part of '../youtube_music_provider.dart';

int _audioFormatTier(int itag, String lowerMime) {
  final isUnsupportedCodec = lowerMime.contains('opus') ||
      lowerMime.contains('webm') ||
      lowerMime.contains('ec-3') ||
      lowerMime.contains('eac3') ||
      lowerMime.contains('ac-3') ||
      lowerMime.contains('ac3') ||
      lowerMime.contains('dts');

  if (!isUnsupportedCodec) {
    if (itag == 141) return 6;
    if (itag == 140) return 5;
    if (lowerMime.contains('audio/mp4') ||
        lowerMime.contains('mp4a') ||
        lowerMime.contains('aac')) {
      return 4;
    }
    if (lowerMime.contains('flac') ||
        lowerMime.contains('mp3') ||
        lowerMime.contains('mpeg') ||
        lowerMime.contains('vorbis') ||
        lowerMime.contains('wav') ||
        lowerMime.contains('alac') ||
        lowerMime.contains('aiff') ||
        lowerMime.contains('pcm')) {
      return 3;
    }
  }

  if (lowerMime.contains('opus') ||
      lowerMime.contains('webm') ||
      itag == 251 ||
      itag == 250 ||
      itag == 249) {
    return 2;
  }
  return 1;
}

extension _YtmInnerTubeAudio on YouTubeMusicProvider {
  Future<ResolvedStreamResult?> _finalizeInnerTubeStream(
    _InnerTubeAudioCandidate candidate, {
    required String videoId,
    required String clientName,
    required int playRequestId,
    CancellationToken? cancel,
    required List<String> diagnostics,
    required String layerLabel,
  }) async {
    if (!candidate.requiresFfmpegTranscode) {
      final hintExt = (candidate.result.hintExtension ?? 'm4a').toUpperCase();
      return ResolvedStreamResult(
        url: candidate.result.url,
        headers: candidate.result.headers,
        hintExtension: candidate.result.hintExtension,
        format: candidate.result.format,
        isPreviewOnly: candidate.result.isPreviewOnly,
        drmNotice: candidate.result.drmNotice,
        externalWebUrl: candidate.result.externalWebUrl,
        engineRoute: 'InnerTube $clientName (direct $hintExt)',
        videoId: videoId,
      );
    }
    try {
      final wavUrl = await _ytDlpService.openTranscodedWavUrl(
        sourceUrl: candidate.result.url,
        headers: candidate.result.headers,
        playRequestId: playRequestId,
      );
      cancel?.throwIfCancelled();
      return ResolvedStreamResult(
        url: wavUrl,
        headers: const <String, String>{},
        hintExtension: 'wav',
        format: candidate.result.format,
        engineRoute: 'InnerTube $clientName + ffmpeg fallback',
        videoId: videoId,
      );
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
      diagnostics.add(
        '$layerLabel FFmpeg proxy failed: ${_redactSecrets(e.message)}',
      );
      return null;
    } on YtDlpException catch (e) {
      if (e.isCancelled) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      diagnostics.add(
        '$layerLabel FFmpeg proxy failed: ${_redactSecrets(e.message)}',
      );
      return null;
    } catch (e) {
      diagnostics.add(
        '$layerLabel FFmpeg proxy failed: ${_redactSecrets(e.toString())}',
      );
      return null;
    }
  }

  _InnerTubeAudioCandidate? _tryExtractBestAudioStream(
    Map<String, dynamic> json,
  ) {
    final playability = json['playabilityStatus'];
    if (playability is Map) {
      final status = playability['status']?.toString();
      if (status != null && status != 'OK') {
        return null;
      }
    }

    final streamingData = json['streamingData'];
    if (streamingData is! Map) return null;

    final candidates = <Map<String, dynamic>>[];
    for (final listKey in const ['adaptiveFormats', 'formats']) {
      final raw = streamingData[listKey];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final mime = map['mimeType']?.toString().toLowerCase() ?? '';
            final url = map['url']?.toString().trim() ?? '';
            if (mime.startsWith('audio/') && url.isNotEmpty) {
              candidates.add(map);
            }
          }
        }
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final itagA = (a['itag'] as num?)?.toInt() ??
          int.tryParse(a['itag']?.toString() ?? '') ??
          -1;
      final itagB = (b['itag'] as num?)?.toInt() ??
          int.tryParse(b['itag']?.toString() ?? '') ??
          -1;
      final mimeA = a['mimeType']?.toString().toLowerCase() ?? '';
      final mimeB = b['mimeType']?.toString().toLowerCase() ?? '';
      final tierA = _audioFormatTier(itagA, mimeA);
      final tierB = _audioFormatTier(itagB, mimeB);
      if (tierA != tierB) return tierB.compareTo(tierA);

      final ba = (a['bitrate'] as num?)?.toInt() ??
          (a['averageBitrate'] as num?)?.toInt() ??
          0;
      final bb = (b['bitrate'] as num?)?.toInt() ??
          (b['averageBitrate'] as num?)?.toInt() ??
          0;
      return bb.compareTo(ba);
    });

    final best = candidates.first;
    final url = best['url']!.toString().trim();
    final lowerUrl = url.toLowerCase();
    final mime = best['mimeType']?.toString().toLowerCase() ?? '';
    final itag = (best['itag'] as num?)?.toInt() ??
        int.tryParse(best['itag']?.toString() ?? '') ??
        -1;
    final tier = _audioFormatTier(itag, mime);
    final isManifest = lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('.mpd') ||
        lowerUrl.contains('/hls_playlist/') ||
        lowerUrl.contains('/dash/');
    final requiresTranscode = tier <= 2 || isManifest;

    final AudioCodec codec;
    final String hintExt;
    if (mime.contains('opus') || mime.contains('webm')) {
      codec = AudioCodec.opus;
      hintExt = 'webm';
    } else if (mime.contains('flac')) {
      codec = AudioCodec.flac;
      hintExt = 'flac';
    } else if (mime.contains('mp3') || mime.contains('mpeg')) {
      codec = AudioCodec.mp3;
      hintExt = 'mp3';
    } else if (mime.contains('vorbis') || mime.contains('ogg')) {
      codec = AudioCodec.opus;
      hintExt = 'ogg';
    } else if (mime.contains('wav')) {
      codec = AudioCodec.wav;
      hintExt = 'wav';
    } else {
      codec = AudioCodec.aac;
      hintExt = 'm4a';
    }

    final sampleRateRaw = best['audioSampleRate'];
    final sampleRate = sampleRateRaw is num
        ? sampleRateRaw.toInt()
        : int.tryParse(sampleRateRaw?.toString() ?? '') ??
            (codec == AudioCodec.opus ? 48000 : 44100);
    final channels = (best['audioChannels'] as num?)?.toInt() ?? 2;
    final bitrateBps =
        (best['averageBitrate'] as num?)?.toInt() ??
        (best['bitrate'] as num?)?.toInt();
    final bitrateKbps =
        (bitrateBps != null && bitrateBps > 0)
            ? (bitrateBps / 1000.0).round()
            : null;

    return _InnerTubeAudioCandidate(
      requiresFfmpegTranscode: requiresTranscode,
      result: ResolvedStreamResult(
        url: url,
        hintExtension: hintExt,
        format: AudioFormat(
          codec: codec,
          sampleRateHz: sampleRate,
          bitDepth: 16,
          channels: channels,
          bitrateKbps: bitrateKbps,
        ),
      ),
    );
  }
}
