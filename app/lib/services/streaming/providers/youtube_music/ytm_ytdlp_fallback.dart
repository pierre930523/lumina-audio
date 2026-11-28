part of '../youtube_music_provider.dart';

String _buildYtDlpExtractorArgs({
  required PoToken? gvsToken,
  required PoToken? playerToken,
  required String? visitorData,
}) {
  final parts = <String>[YtDlpService.defaultExtractorArgs];
  final potEntries = <String>[];
  final gvs = gvsToken?.token.trim();
  if (gvs != null && gvs.isNotEmpty) {
    potEntries.add('web.gvs+$gvs');
    potEntries.add('mweb.gvs+$gvs');
  }
  final player = playerToken?.token.trim();
  if (player != null && player.isNotEmpty) {
    potEntries.add('web.player+$player');
    potEntries.add('mweb.player+$player');
  }
  if (potEntries.isNotEmpty) {
    parts.add('po_token=${potEntries.join(',')}');
  }
  final vd = visitorData?.trim();
  if (vd != null && vd.isNotEmpty) {
    parts.add('visitor_data=$vd');
  }
  return parts.join(';');
}

String _resolveMimeTypeForYtDlp(
  YtDlpResolvedStream resolved,
  String hintExt,
  AudioCodec codec,
) {
  final explicit = resolved.mimeType?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return switch (hintExt.toLowerCase()) {
    'webm' => 'audio/webm',
    'm4a' || 'mp4' || 'aac' => 'audio/mp4',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'mp3' => 'audio/mpeg',
    'flac' => 'audio/flac',
    'wav' => 'audio/wav',
    _ => codec == AudioCodec.opus ? 'audio/webm' : 'audio/mp4',
  };
}

int _resolveExpireAtForYtDlp(YtDlpResolvedStream resolved, String url) {
  final rawExpire = Uri.tryParse(url)?.queryParameters['expire'];
  if (rawExpire != null) {
    final parsed = int.tryParse(rawExpire);
    if (parsed != null && parsed > 0) return parsed;
  }
  return resolved.expiresAt.millisecondsSinceEpoch ~/ 1000;
}

AudioFormat _mapYtDlpAudioFormat(YtDlpResolvedStream stream) {
  final lowerCodec = stream.acodec?.trim().toLowerCase() ?? '';
  final lowerExt = stream.ext?.trim().toLowerCase() ?? '';

  final AudioCodec codec;
  if (lowerCodec == 'mp4a.6b' ||
      lowerCodec == 'mp4a.69' ||
      lowerCodec.contains('mp3') ||
      lowerExt == 'mp3') {
    codec = AudioCodec.mp3;
  } else if (lowerCodec.startsWith('mp4a') ||
      lowerCodec == 'aac' ||
      lowerExt == 'm4a' ||
      lowerExt == 'aac' ||
      lowerExt == 'mp4') {
    codec = AudioCodec.aac;
  } else if (lowerCodec.contains('opus') ||
      lowerExt == 'opus' ||
      lowerExt == 'webm' ||
      lowerCodec.contains('vorbis') ||
      lowerExt == 'ogg' ||
      lowerExt == 'oga') {
    codec = AudioCodec.opus;
  } else if (lowerCodec.contains('flac') || lowerExt == 'flac') {
    codec = AudioCodec.flac;
  } else if (lowerCodec.contains('alac') || lowerExt == 'alac') {
    codec = AudioCodec.alac;
  } else if (lowerCodec.contains('wav') ||
      lowerCodec.contains('pcm') ||
      lowerExt == 'wav') {
    codec = AudioCodec.wav;
  } else if (lowerCodec.contains('aiff') ||
      lowerExt == 'aiff' ||
      lowerExt == 'aif') {
    codec = AudioCodec.aiff;
  } else {
    codec = AudioCodec.aac;
  }

  final sampleRate = (stream.sampleRateHz != null && stream.sampleRateHz! > 0)
      ? stream.sampleRateHz!
      : (codec == AudioCodec.opus ? 48000 : 44100);

  return AudioFormat(
    codec: codec,
    sampleRateHz: sampleRate,
    bitDepth: 16,
    channels: 2,
    bitrateKbps:
        (stream.bitrateKbps != null && stream.bitrateKbps! > 0)
            ? stream.bitrateKbps!.round()
            : null,
  );
}

String _hintExtensionForYtDlp(
  YtDlpResolvedStream stream,
  AudioCodec codec,
) {
  final lowerExt = stream.ext?.trim().toLowerCase() ?? '';
  if (lowerExt.isNotEmpty) {
    if (lowerExt == 'mp4' && codec == AudioCodec.aac) return 'm4a';
    return lowerExt;
  }
  return switch (codec) {
    AudioCodec.aac => 'm4a',
    AudioCodec.mp3 => 'mp3',
    AudioCodec.flac => 'flac',
    AudioCodec.alac => 'm4a',
    AudioCodec.wav => 'wav',
    AudioCodec.aiff => 'aiff',
    AudioCodec.opus => 'webm',
    AudioCodec.dsf => 'dsf',
    AudioCodec.dsdiff => 'dff',
  };
}

extension _YtmYtDlpFallback on YouTubeMusicProvider {
  /// Mature JS Runtime fallback (`yt-dlp` + `deno` + EJS) invoked by
  /// [YtmResidentResolver] ONLY when direct InnerTube clients (`ANDROID_VR` /
  /// `WEB_REMIX`) fail or return `signatureCipher` / undecrypted `n`-param
  /// streams. Never uses fragile hand-rolled regex scraping of `base.js`.
  Future<DirectRangeSpec?> _resolveSpecViaYtDlpFallback({
    required StreamKey key,
    required String videoId,
    required YtmAuthCredentials? auth,
    required PoToken? gvsToken,
    required PoToken? playerToken,
    required String? visitorData,
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();

    // 1) If authenticated with browser cookies, try cookie-assisted yt-dlp
    //    first (useful for age/region-gated tracks). On any non-cancel failure,
    //    fall through cleanly to Guest yt-dlp so expired cookies never block
    //    playback.
    var triedCookies = false;
    final rawCookie = auth?.authMode == 'cookie' ? auth?.cookie?.trim() : null;
    if (rawCookie != null && rawCookie.isNotEmpty) {
      final netscapeContent = _ytmBuildNetscapeCookiesContent(
        rawCookie,
        now: clock(),
      );
      if (netscapeContent.contains('\t')) {
        triedCookies = true;
        File? tempCookieFile;
        try {
          tempCookieFile = await _writeTempNetscapeCookiesFile(netscapeContent);
          final resolved = await _runYtDlpForSpec(
            videoId: videoId,
            cookiesFilePath: tempCookieFile.path,
            bypassCache: false,
            extractorArgs: _buildYtDlpExtractorArgs(
              gvsToken: gvsToken,
              playerToken: playerToken,
              visitorData: null,
            ),
            cancelToken: cancelToken,
          );
          final spec = _directRangeSpecFromYtDlp(
            key,
            resolved,
            gvsToken: gvsToken,
          );
          if (spec != null) return spec;
        } on StreamingException catch (e) {
          if (e.isCancelled) rethrow;
          debugPrint(
            '[YouTubeMusic] Cookie yt-dlp fallback failed for $videoId, '
            'retrying Guest mode: ${_redactSecrets(e.message)}',
          );
        } catch (e) {
          debugPrint(
            '[YouTubeMusic] Cookie yt-dlp fallback error for $videoId, '
            'retrying Guest mode: ${_redactSecrets(e.toString())}',
          );
        } finally {
          if (tempCookieFile != null) {
            try {
              if (tempCookieFile.existsSync()) {
                await tempCookieFile.delete();
              }
            } catch (_) {}
          }
        }
      }
    }

    // 2) Clean unauthenticated Guest yt-dlp + Deno EJS fallback with guest
    //    visitorData and local 127.0.0.1 PO Token when available.
    cancelToken?.throwIfCancelled();
    final guestResolved = await _runYtDlpForSpec(
      videoId: videoId,
      bypassCache: triedCookies,
      extractorArgs: _buildYtDlpExtractorArgs(
        gvsToken: gvsToken,
        playerToken: playerToken,
        visitorData: visitorData,
      ),
      cancelToken: cancelToken,
    );
    return _directRangeSpecFromYtDlp(
      key,
      guestResolved,
      gvsToken: gvsToken,
    );
  }

  Future<YtDlpResolvedStream> _runYtDlpForSpec({
    required String videoId,
    String? cookiesFilePath,
    required bool bypassCache,
    required String extractorArgs,
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final requestId = --_fallbackRequestCounter;
    void onCancel() => _ytDlpService.cancelRequest(requestId);
    cancelToken?.addListener(onCancel);
    try {
      return await _ytDlpService.resolveVideo(
        videoId,
        playRequestId: requestId,
        cookiesFilePath: cookiesFilePath,
        bypassCache: bypassCache,
        formatSelector: YtDlpService.opusPreferredAudioFormatSelector,
        extractorArgs: extractorArgs,
        remoteComponents: YtDlpService.defaultRemoteComponents,
      );
    } on YtDlpException catch (e) {
      if (e.isCancelled) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      final safeMsg = _redactSecrets(e.message);
      throw StreamingException(
        safeMsg,
        kind: StreamingException.classifyKind(message: safeMsg),
      );
    } finally {
      cancelToken?.removeListener(onCancel);
    }
  }

  DirectRangeSpec? _directRangeSpecFromYtDlp(
    StreamKey key,
    YtDlpResolvedStream resolved, {
    PoToken? gvsToken,
  }) {
    final rawUrl = resolved.url.trim();
    if (rawUrl.isEmpty) return null;
    final lowerUrl = rawUrl.toLowerCase();
    final isManifest = lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('.mpd') ||
        lowerUrl.contains('/hls_playlist/') ||
        lowerUrl.contains('/dash/');
    if (isManifest) return null;

    var finalUrl = rawUrl;
    final gvs = gvsToken?.token.trim();
    if (gvs != null && gvs.isNotEmpty) {
      finalUrl = YtmResidentResolver.appendPotQueryParam(finalUrl, gvs);
    }

    final headers = <String, String>{};
    var hasUserAgent = false;
    var hasAccept = false;
    var hasOrigin = false;
    var hasReferer = false;
    for (final entry in resolved.httpHeaders.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      final lk = k.toLowerCase();
      // Never forward sensitive web auth/cookie headers or transport-owned
      // compression/range headers to CDN media fetches.
      if (lk == 'cookie' ||
          lk == 'authorization' ||
          lk == 'x-goog-authuser' ||
          lk == 'accept-encoding' ||
          lk == 'range') {
        continue;
      }
      headers[k] = v;
      if (lk == 'user-agent') hasUserAgent = true;
      if (lk == 'accept') hasAccept = true;
      if (lk == 'origin') hasOrigin = true;
      if (lk == 'referer') hasReferer = true;
    }
    if (!hasUserAgent) {
      headers['User-Agent'] = YouTubeMusicProvider._desktopChromeUserAgent;
    }
    if (!hasAccept) {
      headers['Accept'] = '*/*';
    }

    final urlClient =
        Uri.tryParse(finalUrl)?.queryParameters['c']?.trim().toUpperCase() ??
            '';
    if (urlClient == 'WEB_REMIX') {
      if (!hasOrigin) headers['Origin'] = YouTubeMusicProvider._ytMusicOrigin;
      if (!hasReferer) {
        headers['Referer'] = '${YouTubeMusicProvider._ytMusicOrigin}/';
      }
    } else if (urlClient == 'WEB' ||
        urlClient == 'MWEB' ||
        urlClient == 'WEB_SAFARI' ||
        urlClient.startsWith('WEB_')) {
      if (!hasOrigin) headers['Origin'] = YouTubeMusicProvider._ytWebOrigin;
      if (!hasReferer) {
        headers['Referer'] = '${YouTubeMusicProvider._ytWebOrigin}/';
      }
    }

    final format = _mapYtDlpAudioFormat(resolved);
    final hintExt = _hintExtensionForYtDlp(resolved, format.codec);
    final mimeType = _resolveMimeTypeForYtDlp(resolved, hintExt, format.codec);
    final expireAt = _resolveExpireAtForYtDlp(resolved, finalUrl);
    final bitrateBps = (resolved.bitrateKbps != null && resolved.bitrateKbps! > 0)
        ? (resolved.bitrateKbps! * 1000).round()
        : null;
    final loudness =
        (resolved.loudnessDb != null && resolved.loudnessDb!.isFinite)
        ? NormalizedLoudness.fromYtmLoudnessDb(resolved.loudnessDb!)
        : null;

    return DirectRangeSpec(
      key: key,
      url: finalUrl,
      headers: headers,
      contentLength: resolved.contentLength,
      bitrateBps: bitrateBps,
      mimeType: mimeType,
      hintExtension: hintExt,
      expireAt: expireAt,
      loudness: loudness,
      audioFormat: format,
    );
  }

  Future<ResolvedStreamResult> _resolveViaYtDlp({
    required String videoId,
    required int playRequestId,
    CancellationToken? cancel,
    String? cookiesFilePath,
    bool bypassCache = false,
    required List<String> diagnostics,
    required String layerLabel,
  }) async {
    cancel?.throwIfCancelled();
    final YtDlpResolvedStream resolved;
    void onCancel() => _ytDlpService.cancelRequest(playRequestId);
    cancel?.addListener(onCancel);
    try {
      resolved = await _ytDlpService.resolveVideo(
        videoId,
        playRequestId: playRequestId,
        cookiesFilePath: cookiesFilePath,
        bypassCache: bypassCache,
      );
    } on YtDlpException catch (e) {
      if (e.isCancelled) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      final safeMsg = _redactSecrets(e.message);
      throw StreamingException(
        safeMsg,
        kind: StreamingException.classifyKind(message: safeMsg),
      );
    } finally {
      cancel?.removeListener(onCancel);
    }

    cancel?.throwIfCancelled();
    final format = _mapYtDlpAudioFormat(resolved);

    if (resolved.requiresFfmpegTranscode) {
      try {
        final wavUrl = await _ytDlpService.openTranscodedWavUrl(
          sourceUrl: resolved.url,
          headers: resolved.httpHeaders,
          playRequestId: playRequestId,
        );
        cancel?.throwIfCancelled();
        return ResolvedStreamResult(
          url: wavUrl,
          headers: const <String, String>{},
          hintExtension: 'wav',
          format: format,
          engineRoute: 'bundled yt-dlp + ffmpeg fallback',
          videoId: videoId,
        );
      } on YtDlpException catch (e) {
        if (e.isCancelled) {
          throw const StreamingException('操作已取消', isCancelled: true);
        }
        diagnostics.add('$layerLabel FFmpeg proxy failed: ${e.message}');
        final safeMsg = _redactSecrets(e.message);
        throw StreamingException(
          safeMsg,
          kind: StreamingException.classifyKind(message: safeMsg),
        );
      } catch (e) {
        final safe = _redactSecrets(e.toString());
        diagnostics.add('$layerLabel FFmpeg proxy failed: $safe');
        throw StreamingException('FFmpeg 轉碼失敗：$safe');
      }
    }

    final hintExt = _hintExtensionForYtDlp(resolved, format.codec);
    return ResolvedStreamResult(
      url: resolved.url,
      headers: resolved.httpHeaders,
      hintExtension: hintExt,
      format: format,
      engineRoute: 'bundled yt-dlp (direct ${hintExt.toUpperCase()})',
      videoId: videoId,
    );
  }
}
