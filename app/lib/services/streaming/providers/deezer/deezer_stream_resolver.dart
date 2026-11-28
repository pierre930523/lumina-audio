part of '../deezer_provider.dart';

double? _parseFiniteDouble(dynamic raw) {
  final value = raw is num
      ? raw.toDouble()
      : (raw is String ? double.tryParse(raw.trim()) : null);
  if (value == null || !value.isFinite) return null;
  return value;
}

extension _DeezerStreamResolver on DeezerProvider {
  List<Map<String, String>> _requestedFormatsForQuality(String qualityKey) {
    final q = qualityKey.trim().toUpperCase();
    final allFormats = <Map<String, String>>[
      if (_webLossless)
        const <String, String>{
          'cipher': 'BF_CBC_STRIPE',
          'format': 'FLAC',
        },
      const <String, String>{
        'cipher': 'BF_CBC_STRIPE',
        'format': 'MP3_320',
      },
      const <String, String>{
        'cipher': 'BF_CBC_STRIPE',
        'format': 'MP3_128',
      },
    ];
    if (q == 'MP3_320') {
      return allFormats.where((f) => f['format'] != 'FLAC').toList();
    }
    if (q == 'MP3_128') {
      return allFormats.where((f) => f['format'] == 'MP3_128').toList();
    }
    return allFormats;
  }

  Future<
    ({
      String cleanTrackId,
      String url,
      String mediaFormat,
      bool isEncryptedFull,
      bool isPreviewOnly,
      String? mimeType,
      String hintExtension,
      int? bitrateBps,
      int? expireAt,
      AudioFormat format,
      NormalizedLoudness? loudness,
    })
  > _resolveMediaInternal({
    required String rawTrackId,
    String qualityKey = 'default',
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    final trackId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'deezer');
    if (trackId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 Deezer trackId');
    }

    NormalizedLoudness? loudness;
    var retriedAuth = false;

    while (true) {
      final canRequestFullStream = _authMode == 'arl' &&
          _arl != null &&
          _arl!.isNotEmpty &&
          _licenseToken != null &&
          _licenseToken!.isNotEmpty &&
          (_webLossless || _webHq);

      if (!canRequestFullStream) break;

      final Map<String, dynamic> songJson;
      try {
        final songUri = BaseStreamingProvider.buildUri(
          gwUrl,
          '',
          <String, String>{
            'method': 'song.getData',
            'input': '3',
            'api_version': '1.0',
            'api_token': _apiToken ?? '',
          },
        );
        songJson = await http.requestJson(
          method: 'POST',
          uri: songUri,
          headers: <String, String>{
            'Cookie': 'arl=${_arl!}',
            'Accept': 'application/json',
          },
          jsonBody: <String, dynamic>{'sng_id': trackId},
          cancel: cancel,
          timeout: timeout,
        );
        _throwIfGatewayError(songJson);
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            (e.statusCode == 401 || e.isTokenExpired) &&
            !retriedAuth &&
            supportsSilentRefresh) {
          retriedAuth = true;
          await refreshSessionIfNeeded(force: true);
          cancel?.throwIfCancelled();
          continue;
        }
        rethrow;
      }

      final results = songJson['results'];
      final trackToken = results is Map
          ? results['TRACK_TOKEN']?.toString().trim() ?? ''
          : '';
      if (results is Map) {
        final gainDb = _parseFiniteDouble(results['GAIN']);
        if (gainDb != null) {
          loudness = NormalizedLoudness.fromDeezerGain(gainDb);
        }
      }

      if (trackToken.isNotEmpty) {
        final requestedFormats = _requestedFormatsForQuality(qualityKey);

        final mediaRes = await http.sendJsonRaw(
          method: 'POST',
          uri: Uri.parse(mediaBaseUrl),
          headers: const <String, String>{'Accept': 'application/json'},
          jsonBody: <String, dynamic>{
            'license_token': _licenseToken,
            'media': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'FULL',
                'formats': requestedFormats,
              },
            ],
            'track_tokens': <String>[trackToken],
          },
          cancel: cancel,
          timeout: timeout,
        );

        if (mediaRes.statusCode == 401) {
          if (!retriedAuth && supportsSilentRefresh) {
            retriedAuth = true;
            await refreshSessionIfNeeded(force: true);
            cancel?.throwIfCancelled();
            continue;
          }
          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              mediaRes.json,
              mediaRes.rawBody,
              401,
            ),
            statusCode: 401,
            isTokenExpired: true,
          );
        }

        if (mediaRes.statusCode == 451) {
          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              mediaRes.json,
              mediaRes.rawBody,
              451,
            ),
            statusCode: 451,
            kind: StreamingErrorKind.regionRestricted,
          );
        }

        if (mediaRes.statusCode == 403) {
          final msg = StreamingHttpClient.extractApiErrorMessage(
            mediaRes.json,
            mediaRes.rawBody,
            403,
          );
          throw StreamingException(
            msg,
            statusCode: 403,
            isTokenExpired: false,
            kind: StreamingException.classifyKind(
              statusCode: 403,
              message: msg,
            ),
          );
        }

        if (mediaRes.statusCode >= 200 && mediaRes.statusCode < 300) {
          final extracted = _extractMediaUrl(mediaRes.json);
          if (extracted != null) {
            final upperFmt = extracted.format.toUpperCase();
            final isFlac = upperFmt == 'FLAC';
            final bitrate = isFlac
                ? null
                : (upperFmt == 'MP3_320' ? 320000 : 128000);
            return (
              cleanTrackId: trackId,
              url: extracted.url,
              mediaFormat: upperFmt,
              isEncryptedFull: true,
              isPreviewOnly: false,
              mimeType: isFlac ? 'audio/flac' : 'audio/mpeg',
              hintExtension: isFlac ? 'flac' : 'mp3',
              bitrateBps: bitrate,
              expireAt: extracted.expireAt,
              format: AudioFormat(
                codec: isFlac ? AudioCodec.flac : AudioCodec.mp3,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
                bitrateKbps: bitrate != null ? bitrate ~/ 1000 : null,
              ),
              loudness: loudness,
            );
          }
          final mediaErr = _extractMediaError(mediaRes.json);
          if (mediaErr != null) {
            final mediaErrKind = StreamingException.classifyKind(
              message: mediaErr,
            );
            if (mediaErrKind == StreamingErrorKind.regionRestricted) {
              throw StreamingException(
                'Deezer 曲目受地區限制：$mediaErr',
                kind: StreamingErrorKind.regionRestricted,
              );
            }
          }
        }
      }
      break;
    }

    // Honest fallback to Deezer official 30s MP3 preview when full stream is unavailable.
    var previewUrl = _previewUrlCache[trackId] ?? '';
    if (previewUrl.isEmpty) {
      final trackJson = await _callPublicApi(
        '/track/$trackId',
        cancel: cancel,
        timeout: timeout,
      );
      previewUrl = trackJson['preview']?.toString().trim() ?? '';
      if (loudness == null) {
        final gainDb = _parseFiniteDouble(trackJson['gain']);
        if (gainDb != null) {
          loudness = NormalizedLoudness.fromDeezerGain(gainDb);
        }
      }
      if (previewUrl.isNotEmpty) {
        _previewUrlCache[trackId] = previewUrl;
      }
    }

    if (previewUrl.isEmpty) {
      throw const StreamingException(
        'Deezer 無法取得完整串流網址，且此曲目亦無官方試聽連結',
        kind: StreamingErrorKind.trackUnavailable,
      );
    }

    return (
      cleanTrackId: trackId,
      url: previewUrl,
      mediaFormat: 'PREVIEW_MP3',
      isEncryptedFull: false,
      isPreviewOnly: true,
      mimeType: 'audio/mpeg',
      hintExtension: 'mp3',
      bitrateBps: 128000,
      expireAt: null,
      format: const AudioFormat(
        codec: AudioCodec.mp3,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
        bitrateKbps: 128,
      ),
      loudness: loudness,
    );
  }

  Future<StreamSourceSpec> _resolveImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final resolved = await _resolveMediaInternal(
      rawTrackId: key.trackId,
      qualityKey: key.qualityKey,
      cancel: cancelToken,
    );
    if (resolved.isEncryptedFull) {
      return EncryptedRangeSpec(
        key: key,
        url: resolved.url,
        bitrateBps: resolved.bitrateBps,
        mimeType: resolved.mimeType,
        hintExtension: resolved.hintExtension,
        cipher: DeezerBlowfishCipher(
          trackId: resolved.cleanTrackId,
          blockSize: 2048,
          stride: 3,
        ),
        expireAt: resolved.expireAt,
        loudness: resolved.loudness,
        audioFormat: resolved.format,
      );
    }
    return DirectRangeSpec(
      key: key,
      url: resolved.url,
      bitrateBps: resolved.bitrateBps,
      mimeType: resolved.mimeType,
      hintExtension: resolved.hintExtension,
      expireAt: resolved.expireAt,
      loudness: resolved.loudness,
      audioFormat: resolved.format,
      isPreviewOnly: true,
      notice: DeezerProvider._previewNotice,
      externalWebUrl: 'https://www.deezer.com/track/${resolved.cleanTrackId}',
    );
  }

  Future<ResolvedStreamResult> _resolveStreamImpl(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final resolved = await _resolveMediaInternal(
      rawTrackId: track.id,
      cancel: cancel,
      timeout: timeout,
    );
    return ResolvedStreamResult(
      url: resolved.url,
      hintExtension: resolved.hintExtension,
      format: resolved.format,
      isPreviewOnly: resolved.isPreviewOnly,
      drmNotice: resolved.isPreviewOnly ? DeezerProvider._previewNotice : null,
      externalWebUrl: resolved.isPreviewOnly
          ? 'https://www.deezer.com/track/${resolved.cleanTrackId}'
          : null,
    );
  }
}
