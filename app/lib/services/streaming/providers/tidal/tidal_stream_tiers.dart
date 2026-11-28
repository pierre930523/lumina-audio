part of '../tidal_provider.dart';

bool _isDashMpdDrmProtected(String mpdXml) {
  return RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?ContentProtection\b',
    caseSensitive: false,
  ).hasMatch(mpdXml);
}

bool _hasDashMediaSegments(String mpdXml) {
  final hasMpd = RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?MPD\b',
    caseSensitive: false,
  ).hasMatch(mpdXml);
  if (!hasMpd) return false;
  return RegExp(
    r'<(?:[A-Za-z0-9_.-]+:)?(?:SegmentTemplate|SegmentList|SegmentBase|BaseURL)\b',
    caseSensitive: false,
  ).hasMatch(mpdXml);
}

String _decodeBase64Utf8(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'\s+'), '');
  return utf8.decode(base64Decode(base64.normalize(cleaned)));
}

String _maxQualityForQualityKey(String qualityKey) {
  final normalized = qualityKey.trim().toUpperCase();
  return switch (normalized) {
    '' || 'DEFAULT' => 'HI_RES_LOSSLESS',
    'HI_RES_LOSSLESS' || 'LOSSLESS' || 'HIGH' || 'LOW' => normalized,
    'HI_RES' => 'HI_RES_LOSSLESS',
    'CD' => 'LOSSLESS',
    _ => normalized,
  };
}

int? _extractUrlExpireAt(String rawUrl) {
  final cleaned = rawUrl.trim().replaceAll('&amp;', '&');
  if (cleaned.isEmpty) return null;
  final uri = Uri.tryParse(cleaned);
  if (uri == null || uri.queryParameters.isEmpty) return null;

  for (final entry in uri.queryParameters.entries) {
    final keyLower = entry.key.trim().toLowerCase();
    if (keyLower == 'expires' || keyLower == 'expire' || keyLower == 'exp') {
      final parsed = int.tryParse(entry.value.trim());
      if (parsed == null) continue;
      if (parsed >= 1000000000000) {
        return parsed ~/ 1000;
      }
      if (parsed >= 1000000000) {
        return parsed;
      }
    }
  }
  return null;
}

int? _extractDashMpdExpireAt(String mpdXml) {
  if (mpdXml.trim().isEmpty) return null;
  int? earliest;

  void inspectCandidate(String raw) {
    final exp = _extractUrlExpireAt(raw);
    if (exp == null) return;
    if (earliest == null || exp < earliest!) {
      earliest = exp;
    }
  }

  final baseUrlRe = RegExp(
    r'<BaseURL[^>]*>([^<]+)</BaseURL>',
    caseSensitive: false,
  );
  for (final m in baseUrlRe.allMatches(mpdXml)) {
    final val = m.group(1);
    if (val != null) inspectCandidate(val);
  }

  final attrRe = RegExp(
    r'''(?:initialization|media)\s*=\s*(?:"([^"]+)"|'([^']+)')''',
    caseSensitive: false,
  );
  for (final m in attrRe.allMatches(mpdXml)) {
    final val = m.group(1) ?? m.group(2);
    if (val != null) inspectCandidate(val);
  }

  if (earliest == null) {
    final urlRe = RegExp(r'''https?://[^\s"'<>]+''');
    for (final m in urlRe.allMatches(mpdXml)) {
      final val = m.group(0);
      if (val != null) inspectCandidate(val);
    }
  }

  return earliest;
}

extension _TidalStreamTiers on TidalProvider {
  Future<T> _resolveTiers<T>({
    required String rawTrackId,
    required String maxQuality,
    required Future<T?> Function({
      required String tier,
      required String mpdXml,
      required bool isFlac,
      required String audioQuality,
      required int sampleRate,
      required int bitDepth,
      NormalizedLoudness? loudness,
      NormalizedLoudness? albumLoudness,
    }) onDashManifest,
    required Future<T?> Function({
      required String tier,
      required String streamUrl,
      required String manifestMime,
      required bool isFlac,
      required String audioQuality,
      required int sampleRate,
      required int bitDepth,
      NormalizedLoudness? loudness,
      NormalizedLoudness? albumLoudness,
    }) onBtsStream,
    required void Function(String tier, String message) onTierFailed,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final trackId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'tidal');
    const qualityChain = <String>['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH'];
    final normalizedMax = maxQuality.trim().toUpperCase();
    final startIndex = qualityChain.indexOf(normalizedMax);
    final tiers =
        startIndex >= 0 ? qualityChain.sublist(startIndex) : qualityChain;

    String? lastError;
    int? lastStatusCode;
    var sawDrm = false;
    var retriedAuth = false;

    void failTier(String tier, String message, {int? statusCode}) {
      lastError = message;
      if (statusCode != null) {
        lastStatusCode = statusCode;
      }
      onTierFailed(tier, message);
      debugPrint(
        '[Tidal Play] track=$trackId tier=$tier failed ($message); trying next tier',
      );
    }

    for (final tier in tiers) {
      cancel?.throwIfCancelled();

      final uri = BaseStreamingProvider.buildUri(
        apiBaseUrl,
        '/tracks/$trackId/playbackinfopostpaywall',
        <String, String>{
          'audioquality': tier,
          'playbackmode': 'STREAM',
          'assetpresentation': 'FULL',
          'countryCode': _countryCode,
        },
      );

      late final Map<String, dynamic> json;
      try {
        json = await http.requestJson(
          method: 'GET',
          uri: uri,
          headers: _authHeaders,
          cancel: cancel,
          timeout: timeout,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled || e.statusCode == null) {
          rethrow;
        }
        if (e.isTokenExpired || e.statusCode == 401) {
          if (!retriedAuth && supportsSilentRefresh) {
            retriedAuth = true;
            await refreshSessionIfNeeded(force: true);
            cancel?.throwIfCancelled();
            json = await http.requestJson(
              method: 'GET',
              uri: uri,
              headers: _authHeaders,
              cancel: cancel,
              timeout: timeout,
            );
          } else {
            rethrow;
          }
        } else {
          final classified = StreamingException.classifyKind(
            statusCode: e.statusCode,
            message: e.message,
            isDrmRestricted: e.isDrmRestricted,
          );
          if (e.statusCode == 451 ||
              classified == StreamingErrorKind.regionRestricted) {
            throw StreamingException(
              e.message,
              statusCode: e.statusCode,
              kind: StreamingErrorKind.regionRestricted,
            );
          }
          failTier(tier, e.message, statusCode: e.statusCode);
          continue;
        }
      }

      final trackGain = (json['trackReplayGain'] as num?)?.toDouble();
      final trackPeak = (json['trackPeakAmplitude'] as num?)?.toDouble();
      final albumGain = (json['albumReplayGain'] as num?)?.toDouble();
      final albumPeak = (json['albumPeakAmplitude'] as num?)?.toDouble();
      final loudness = trackGain != null
          ? NormalizedLoudness.fromReplayGain(trackGain, peak: trackPeak)
          : null;
      final albumLoudness = albumGain != null
          ? NormalizedLoudness.fromReplayGain(albumGain, peak: albumPeak)
          : null;

      final mimeType =
          json['manifestMimeType']?.toString().trim().toLowerCase() ?? '';
      final manifestB64 = json['manifest']?.toString().trim() ?? '';
      final rawAudioQuality =
          json['audioQuality']?.toString().trim().toUpperCase() ?? '';
      final audioQuality = rawAudioQuality.isNotEmpty ? rawAudioQuality : tier;

      if (manifestB64.isEmpty) {
        if (mimeType.contains('drm')) sawDrm = true;
        failTier(tier, 'Tidal 串流清單為空（$tier）');
        continue;
      }

      if (mimeType == 'application/dash+xml') {
        final String mpdXml;
        try {
          mpdXml = _decodeBase64Utf8(manifestB64);
        } catch (e) {
          failTier(tier, '解析 Tidal DASH manifest 失敗：$e');
          continue;
        }

        if (_isDashMpdDrmProtected(mpdXml)) {
          sawDrm = true;
          failTier(tier, 'Tidal 此曲目使用受保護的 DASH DRM 封裝格式（$tier）');
          continue;
        }
        if (!_hasDashMediaSegments(mpdXml)) {
          failTier(tier, 'Tidal DASH MPD 缺少有效的媒體片段資訊（$tier）');
          continue;
        }

        final codecsMatch = RegExp(
          r'''codecs\s*=\s*["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(mpdXml);
        final mpdCodecs = codecsMatch?.group(1)?.trim().toLowerCase() ?? '';

        final sampleRateMatch = RegExp(
          r'''audioSamplingRate\s*=\s*["'](\d+)["']''',
          caseSensitive: false,
        ).firstMatch(mpdXml);
        final mpdSampleRate =
            int.tryParse(sampleRateMatch?.group(1) ?? '');

        final isFlac = mpdCodecs.contains('flac') ||
            (!mpdCodecs.contains('mp4a') &&
                !mpdCodecs.contains('aac') &&
                (audioQuality.contains('LOSSLESS') ||
                    audioQuality.contains('HI_RES')));
        final jsonSr = (json['sampleRate'] as num?)?.toInt();
        final sampleRate = (jsonSr != null && jsonSr > 0)
            ? jsonSr
            : ((mpdSampleRate != null && mpdSampleRate > 0)
                  ? mpdSampleRate
                  : (audioQuality.contains('HI_RES') ? 96000 : 44100));
        final jsonBd = (json['bitDepth'] as num?)?.toInt();
        final bitDepth = (jsonBd != null && jsonBd > 0)
            ? jsonBd
            : (audioQuality.contains('HI_RES') ? 24 : 16);

        final handled = await onDashManifest(
          tier: tier,
          mpdXml: mpdXml,
          isFlac: isFlac,
          audioQuality: audioQuality,
          sampleRate: sampleRate,
          bitDepth: bitDepth,
          loudness: loudness,
          albumLoudness: albumLoudness,
        );
        if (handled != null) return handled;
        lastError ??= 'Tidal DASH 解析失敗（$tier）';
        continue;
      }

      if (mimeType == 'application/vnd.tidal.bts') {
        final Map<String, dynamic> decodedManifest;
        try {
          final rawManifest = _decodeBase64Utf8(manifestB64);
          final parsed = jsonDecode(rawManifest);
          if (parsed is Map<String, dynamic>) {
            decodedManifest = parsed;
          } else if (parsed is Map) {
            decodedManifest = Map<String, dynamic>.from(parsed);
          } else {
            throw const FormatException('Manifest is not a JSON object');
          }
        } catch (e) {
          failTier(tier, '解析 Tidal Base64 manifest 失敗：$e');
          continue;
        }

        final encType =
            decodedManifest['encryptionType']?.toString().trim() ?? '';
        if (encType.isNotEmpty && encType.toUpperCase() != 'NONE') {
          sawDrm = true;
          failTier(
            tier,
            'Tidal 音訊串流受加密保護（$encType），拒絕輸出加密雜訊至 DAC',
          );
          continue;
        }

        final urls = decodedManifest['urls'];
        final streamUrl = (urls is List && urls.isNotEmpty)
            ? urls.first?.toString().trim() ?? ''
            : '';
        if (streamUrl.isEmpty) {
          failTier(tier, 'Tidal manifest 未包含任何可用的串流 URL（$tier）');
          continue;
        }

        final manifestMime =
            decodedManifest['mimeType']?.toString().toLowerCase() ?? '';
        final codecs =
            decodedManifest['codecs']?.toString().toLowerCase() ?? '';
        final isFlac = manifestMime.contains('flac') || codecs.contains('flac');

        final bitDepth = (decodedManifest['bitDepth'] as num?)?.toInt() ??
            (json['bitDepth'] as num?)?.toInt() ??
            (audioQuality.contains('HI_RES') ? 24 : 16);
        final sampleRate = (decodedManifest['sampleRate'] as num?)?.toInt() ??
            (json['sampleRate'] as num?)?.toInt() ??
            (audioQuality.contains('HI_RES') ? 96000 : 44100);

        final handled = await onBtsStream(
          tier: tier,
          streamUrl: streamUrl,
          manifestMime: manifestMime,
          isFlac: isFlac,
          audioQuality: audioQuality,
          sampleRate: sampleRate,
          bitDepth: bitDepth,
          loudness: loudness,
          albumLoudness: albumLoudness,
        );
        if (handled != null) return handled;
        continue;
      }

      if (mimeType.contains('drm')) {
        sawDrm = true;
      }
      failTier(tier, '不支援的 Tidal 串流清單格式：$mimeType');
    }

    final finalMessage = lastError ?? 'Tidal 此曲目所有音質層級皆受保護或無法播放';
    final classified = StreamingException.classifyKind(
      statusCode: lastStatusCode,
      message: finalMessage,
      isDrmRestricted: sawDrm,
    );
    throw StreamingException(
      finalMessage,
      statusCode: lastStatusCode,
      isDrmRestricted: sawDrm,
      kind: classified,
    );
  }
}
