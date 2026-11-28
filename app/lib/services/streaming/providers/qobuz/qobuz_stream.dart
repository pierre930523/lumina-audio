part of '../qobuz_provider.dart';

List<int> _qobuzFormatIdsForQualityKey(String qualityKey) {
  final normalized = qualityKey.trim().toLowerCase();
  return switch (normalized) {
    '27' || 'hi_res_192' || '24_192' => const <int>[27, 7, 6, 5],
    '7' || 'hi_res_96' || '24_96' => const <int>[7, 6, 5],
    '6' || 'lossless' || 'flac' => const <int>[6, 5],
    '5' || 'mp3_320' || 'mp3' => const <int>[5],
    _ => QobuzProvider._preferredFormatIds,
  };
}

({int sampleRateHz, int bitDepth}) _qobuzFormatDefaults(int formatId) =>
    switch (formatId) {
      27 => (sampleRateHz: 192000, bitDepth: 24),
      7 => (sampleRateHz: 96000, bitDepth: 24),
      6 => (sampleRateHz: 44100, bitDepth: 16),
      _ => (sampleRateHz: 44100, bitDepth: 16),
    };

extension _QobuzStream on QobuzProvider {
  Future<
    ({
      String url,
      Map<String, String> headers,
      String mimeType,
      String hintExtension,
      AudioFormat format,
      int? bitrateBps,
      int? expireAt,
    })
  > _resolveSignedFileUrl({
    required String rawTrackId,
    required List<int> formatIds,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();

    final secret = _appSecret?.trim() ?? '';
    if (secret.isEmpty) {
      throw const StreamingException(
        'Qobuz 串流需要提供 app_secret 以計算 MD5 request_sig 簽章',
      );
    }

    final trackId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'qobuz');
    if (trackId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 Qobuz track_id');
    }

    StreamingException? lastFailure;
    for (final fmtId in formatIds) {
      cancel?.throwIfCancelled();
      final ts = (clock().millisecondsSinceEpoch ~/ 1000).toString();
      final sig = QobuzProvider.computeRequestSignature(
        formatId: fmtId,
        trackId: trackId,
        timestampSec: ts,
        appSecret: secret,
      );

      final uri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/track/getFileUrl',
        <String, String>{
          'track_id': trackId,
          'format_id': fmtId.toString(),
          'intent': 'stream',
          'request_ts': ts,
          'request_sig': sig,
        },
      );

      final res = await http.sendJsonRaw(
        method: 'GET',
        uri: uri,
        headers: _authHeaders(),
        cancel: cancel,
        timeout: timeout,
      );

      if (res.statusCode == 401 || res.statusCode == 403) {
        final msg = StreamingHttpClient.extractApiErrorMessage(
          res.json,
          res.rawBody,
          res.statusCode,
        );
        throw StreamingException(
          msg,
          statusCode: res.statusCode,
          isTokenExpired: res.statusCode == 401,
          kind: res.statusCode == 401
              ? StreamingErrorKind.authExpired
              : StreamingException.classifyKind(
                  statusCode: res.statusCode,
                  message: msg,
                ),
        );
      }

      if (res.statusCode == 451) {
        final msg = StreamingHttpClient.extractApiErrorMessage(
          res.json,
          res.rawBody,
          res.statusCode,
        );
        throw StreamingException(
          msg,
          statusCode: res.statusCode,
          kind: StreamingErrorKind.regionRestricted,
        );
      }

      if (res.statusCode < 200 || res.statusCode >= 300) {
        final msg = StreamingHttpClient.extractApiErrorMessage(
          res.json,
          res.rawBody,
          res.statusCode,
        );
        final classified = StreamingException.classifyKind(
          statusCode: res.statusCode,
          message: msg,
        );
        final err = StreamingException(
          msg,
          statusCode: res.statusCode,
          kind: classified,
        );
        if (err.isRegionRestricted) {
          throw err;
        }
        lastFailure = err;
        continue;
      }

      if (res.json['status'] == 'error') {
        final msg = res.json['message']?.toString() ?? 'Qobuz 無法取得串流網址';
        final code = (res.json['code'] as num?)?.toInt();
        final lower = msg.toLowerCase();
        if (code == 401 ||
            lower.contains('authentication is required') ||
            lower.contains('invalid user_auth_token')) {
          throw StreamingException(
            msg,
            statusCode: 401,
            isTokenExpired: true,
          );
        }
        final classified = StreamingException.classifyKind(
          statusCode: code,
          message: msg,
        );
        final err = StreamingException(msg, statusCode: code, kind: classified);
        if (err.isRegionRestricted || err.isUnavailable) {
          throw err;
        }
        lastFailure = err;
        continue;
      }

      final restrictions = res.json['restrictions'];
      if (restrictions is List && restrictions.isNotEmpty) {
        final restrictionSummary = restrictions.map((r) => '$r').join(', ');
        final classified = StreamingException.classifyKind(
          message: restrictionSummary,
          isDrmRestricted: true,
        );
        final err = StreamingException(
          'Qobuz 曲目受權限限制：${restrictions.first}',
          isDrmRestricted: classified == StreamingErrorKind.drmRestricted,
          kind: classified ?? StreamingErrorKind.drmRestricted,
        );
        if (err.isRegionRestricted || err.isUnavailable) {
          throw err;
        }
        lastFailure = err;
        continue;
      }

      final streamUrl = res.json['url']?.toString().trim() ?? '';
      if (streamUrl.isEmpty) {
        lastFailure = const StreamingException('Qobuz track/getFileUrl 回傳空白 URL');
        continue;
      }

      final effectiveFormatId =
          (res.json['format_id'] as num?)?.toInt() ?? fmtId;
      final defaultSpec = _qobuzFormatDefaults(effectiveFormatId);

      final rawRate = res.json['sampling_rate'];
      final int sampleRateHz;
      if (rawRate is num) {
        sampleRateHz = rawRate <= 1000
            ? (rawRate.toDouble() * 1000).round()
            : rawRate.round();
      } else {
        sampleRateHz = defaultSpec.sampleRateHz;
      }

      final bitDepth =
          (res.json['bit_depth'] as num?)?.toInt() ?? defaultSpec.bitDepth;
      final rawMime = res.json['mime_type']?.toString().trim() ?? '';
      final mime = rawMime.toLowerCase();
      final codec = mime.contains('mpeg') || effectiveFormatId == 5
          ? AudioCodec.mp3
          : AudioCodec.flac;

      final uriExp = Uri.tryParse(streamUrl)?.queryParameters;
      final expireAt =
          int.tryParse(uriExp?['exp'] ?? uriExp?['expire'] ?? uriExp?['expires'] ?? '');
      final rawBitrate = (res.json['bitrate'] as num?)?.toInt();
      final bitrateBps = rawBitrate != null && rawBitrate > 0
          ? (rawBitrate < 10000 ? rawBitrate * 1000 : rawBitrate)
          : (codec == AudioCodec.mp3 ? 320000 : null);

      return (
        url: streamUrl,
        headers: _authHeaders(),
        mimeType: rawMime.isNotEmpty
            ? rawMime
            : (codec == AudioCodec.mp3 ? 'audio/mpeg' : 'audio/flac'),
        hintExtension: codec == AudioCodec.mp3 ? 'mp3' : 'flac',
        format: AudioFormat(
          codec: codec,
          sampleRateHz: sampleRateHz,
          bitDepth: bitDepth,
          channels: 2,
          bitrateKbps:
              bitrateBps != null && bitrateBps > 0
                  ? (bitrateBps / 1000.0).round()
                  : null,
        ),
        bitrateBps: bitrateBps,
        expireAt: expireAt,
      );
    }

    throw lastFailure ??
        const StreamingException('Qobuz 無法解析任何可用音質的串流網址');
  }

  Future<StreamSourceSpec> _resolveImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final resolved = await _resolveSignedFileUrl(
      rawTrackId: key.trackId,
      formatIds: _qobuzFormatIdsForQualityKey(key.qualityKey),
      cancel: cancelToken,
    );
    return DirectRangeSpec(
      key: key,
      url: resolved.url,
      headers: resolved.headers,
      bitrateBps: resolved.bitrateBps,
      mimeType: resolved.mimeType,
      hintExtension: resolved.hintExtension,
      expireAt: resolved.expireAt,
      audioFormat: resolved.format,
    );
  }

  Future<ResolvedStreamResult> _resolveStreamImpl(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final resolved = await _resolveSignedFileUrl(
      rawTrackId: track.id,
      formatIds: QobuzProvider._preferredFormatIds,
      cancel: cancel,
      timeout: timeout,
    );
    return ResolvedStreamResult(
      url: resolved.url,
      headers: resolved.headers,
      hintExtension: resolved.hintExtension,
      format: resolved.format,
    );
  }
}
