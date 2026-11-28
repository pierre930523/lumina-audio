part of '../apple_music_provider.dart';

extension _AppleMusicStream on AppleMusicProvider {
  Future<({String rawId, String? catalogId, String previewUrl, String webUrl})>
  _lookupTrackPlaybackInfo({
    required String rawTrackId,
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();

    final rawId = BaseStreamingProvider.stripTrackPrefix(rawTrackId, 'apple');
    if (rawId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 Apple Music ID');
    }

    var previewUrl = _previewUrlByTrackId[rawId] ?? '';
    var webUrl = _externalWebUrlByTrackId[rawId];
    var catalogId = _catalogIdByTrackId[rawId];

    if (previewUrl.isEmpty) {
      if (catalogId == null || catalogId.isEmpty) {
        if (rawId.startsWith('i.')) {
          final catRes = await http.sendJsonRaw(
            method: 'GET',
            uri: BaseStreamingProvider.buildUri(
              apiBaseUrl,
              '/v1/me/library/songs/$rawId/catalog',
            ),
            headers: _authHeaders,
            cancel: cancel,
            timeout: timeout,
          );
          if (catRes.statusCode == 401 || catRes.statusCode == 403) {
            final msg = StreamingHttpClient.extractApiErrorMessage(
              catRes.json,
              catRes.rawBody,
              catRes.statusCode,
            );
            throw StreamingException(
              msg,
              statusCode: catRes.statusCode,
              isTokenExpired: catRes.statusCode == 401,
              kind: catRes.statusCode == 401
                  ? StreamingErrorKind.authExpired
                  : StreamingException.classifyKind(
                      statusCode: catRes.statusCode,
                      message: msg,
                    ),
            );
          }
          if (catRes.statusCode == 451) {
            final msg = StreamingHttpClient.extractApiErrorMessage(
              catRes.json,
              catRes.rawBody,
              451,
            );
            throw StreamingException(
              msg,
              statusCode: 451,
              kind: StreamingErrorKind.regionRestricted,
            );
          }
          if (catRes.statusCode >= 200 && catRes.statusCode < 300) {
            final data = catRes.json['data'];
            if (data is List && data.isNotEmpty && data.first is Map) {
              final songMap = Map<String, dynamic>.from(data.first as Map);
              catalogId = songMap['id']?.toString();
              final extracted = _extractPreviewAndWebUrl(songMap);
              previewUrl = extracted.previewUrl ?? '';
              webUrl ??= extracted.webUrl;
            }
          }
        } else {
          catalogId = rawId;
        }
      }

      if (previewUrl.isEmpty && catalogId != null && catalogId.isNotEmpty) {
        final songRes = await http.sendJsonRaw(
          method: 'GET',
          uri: BaseStreamingProvider.buildUri(
            apiBaseUrl,
            '/v1/catalog/$_storefront/songs/$catalogId',
          ),
          headers: _authHeaders,
          cancel: cancel,
          timeout: timeout,
        );
        if (songRes.statusCode == 401 || songRes.statusCode == 403) {
          final msg = StreamingHttpClient.extractApiErrorMessage(
            songRes.json,
            songRes.rawBody,
            songRes.statusCode,
          );
          throw StreamingException(
            msg,
            statusCode: songRes.statusCode,
            isTokenExpired: songRes.statusCode == 401,
            kind: songRes.statusCode == 401
                ? StreamingErrorKind.authExpired
                : StreamingException.classifyKind(
                    statusCode: songRes.statusCode,
                    message: msg,
                  ),
          );
        }
        if (songRes.statusCode == 451 ||
            songRes.statusCode == 404 ||
            songRes.statusCode == 410) {
          final msg = StreamingHttpClient.extractApiErrorMessage(
            songRes.json,
            songRes.rawBody,
            songRes.statusCode,
          );
          throw StreamingException(
            msg,
            statusCode: songRes.statusCode,
            kind: StreamingException.classifyKind(
              statusCode: songRes.statusCode,
              message: msg,
            ),
          );
        }
        if (songRes.statusCode >= 200 && songRes.statusCode < 300) {
          final data = songRes.json['data'];
          if (data is List && data.isNotEmpty && data.first is Map) {
            final songMap = Map<String, dynamic>.from(data.first as Map);
            final extracted = _extractPreviewAndWebUrl(songMap);
            previewUrl = extracted.previewUrl ?? '';
            webUrl ??= extracted.webUrl;
          }
        }
      }
    }

    if (previewUrl.isNotEmpty) {
      _previewUrlByTrackId[rawId] = previewUrl;
    }
    if (catalogId != null && catalogId.isNotEmpty) {
      _catalogIdByTrackId[rawId] = catalogId;
    }
    final resolvedWebUrl = webUrl ??
        (catalogId != null && catalogId.isNotEmpty
            ? 'https://music.apple.com/$_storefront/song/$catalogId'
            : 'https://music.apple.com/$_storefront');
    if (webUrl != null) {
      _externalWebUrlByTrackId[rawId] = webUrl;
    }

    return (
      rawId: rawId,
      catalogId: catalogId,
      previewUrl: previewUrl,
      webUrl: resolvedWebUrl,
    );
  }

  Future<StreamSourceSpec> _resolveImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    final info = await _lookupTrackPlaybackInfo(
      rawTrackId: key.trackId,
      cancel: cancelToken,
    );
    final effectiveSongId =
        (info.catalogId != null && info.catalogId!.isNotEmpty)
            ? info.catalogId!
            : info.rawId;

    return ExternalBackendSpec(
      key: key,
      providerId: providerId,
      trackUri: 'apple:$effectiveSongId',
      externalWebUrl: info.webUrl,
      previewUrl: info.previewUrl.isNotEmpty ? info.previewUrl : null,
      notice: AppleMusicProvider.windowsFairPlayDrmNotice,
      audioFormat: const AudioFormat(
        codec: AudioCodec.aac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
    );
  }

  Future<ResolvedStreamResult> _resolveStreamImpl(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final info = await _lookupTrackPlaybackInfo(
      rawTrackId: track.id,
      cancel: cancel,
      timeout: timeout,
    );

    if (info.previewUrl.isEmpty) {
      throw const StreamingException(
        '此 Apple Music 曲目無官方試聽片段，且 Windows 受 Apple FairPlay DRM 保護無法直接擷取完整無損 ALAC 串流，請改用 Apple Music 網頁播放器開啟。',
        isDrmRestricted: true,
      );
    }

    return ResolvedStreamResult(
      url: info.previewUrl,
      hintExtension: 'm4a',
      format: const AudioFormat(
        codec: AudioCodec.aac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      isPreviewOnly: true,
      drmNotice: AppleMusicProvider.windowsFairPlayDrmNotice,
      externalWebUrl: info.webUrl,
    );
  }
}
