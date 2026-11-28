part of '../youtube_music_provider.dart';

class _InnerTubeAudioCandidate {
  final ResolvedStreamResult result;
  final bool requiresFfmpegTranscode;

  const _InnerTubeAudioCandidate({
    required this.result,
    required this.requiresFfmpegTranscode,
  });
}

extension _YtmStreamResolver on YouTubeMusicProvider {
  Future<StreamSourceSpec> _resolveImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      try {
        await refreshSessionIfNeeded();
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
        // Playback is decoupled from library auth: if silent refresh fails,
        // still proceed so resident ANDROID_VR / Guest / JS fallback can play.
        debugPrint(
          '[YouTubeMusic] Non-fatal session refresh error before playback: '
          '${_redactSecrets(e.message)}',
        );
      } catch (e) {
        debugPrint(
          '[YouTubeMusic] Non-fatal session refresh error before playback: '
          '${_redactSecrets(e.toString())}',
        );
      }
      cancelToken?.throwIfCancelled();
    }
    try {
      return await _residentResolver.resolve(key, cancelToken: cancelToken);
    } on StreamingException catch (e) {
      if (!e.isCancelled &&
          (e.statusCode == 401 || e.isTokenExpired) &&
          supportsSilentRefresh) {
        await refreshSessionIfNeeded(force: true);
        cancelToken?.throwIfCancelled();
        return _residentResolver.resolve(key, cancelToken: cancelToken);
      }
      if (e.kind == StreamingErrorKind.unknown) {
        final classified = StreamingException.classifyKind(
          statusCode: e.statusCode,
          message: e.message,
          isDrmRestricted: e.isDrmRestricted,
        );
        if (classified != null) {
          throw StreamingException(
            e.message,
            statusCode: e.statusCode,
            isTokenExpired: e.isTokenExpired,
            isDrmRestricted: e.isDrmRestricted,
            kind: classified,
          );
        }
      }
      rethrow;
    }
  }

  void _clearStreamCacheImpl([String? videoIdOrTrackId]) {
    if (videoIdOrTrackId == null) {
      _ytDlpService.clearCache();
      return;
    }
    final raw = videoIdOrTrackId.trim();
    if (raw.isEmpty) return;
    _ytDlpService.clearCache(raw);
    final clean = _ytmTryExtractCleanVideoId(raw);
    if (clean != null && clean != raw) {
      _ytDlpService.clearCache(clean);
    }
  }

  Future<void> _preloadTrackImpl(TrackInfo track) async {
    String videoId;
    try {
      videoId = _extractVideoId(track);
    } catch (_) {
      return;
    }
    await _ytDlpService.preloadVideo(videoId);
  }

  Future<ResolvedStreamResult> _resolveStreamImpl(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    bool bypassCache = false,
  }) async {
    cancel?.throwIfCancelled();

    final videoId = _extractVideoId(track);
    final effectiveRequestId = playRequestId ?? (--_fallbackRequestCounter);
    if (bypassCache) {
      _ytDlpService.clearCache(videoId);
    }

    void abortResolve() => _ytDlpService.cancelRequest(effectiveRequestId);
    cancel?.addListener(abortResolve);
    try {
      // Guest Mode (unauthenticated): direct bundled YtDlpService resolution.
      if (authState != StreamingAuthState.connected) {
        final diagnostics = <String>[];
        try {
          final result = await _resolveViaYtDlp(
            videoId: videoId,
            playRequestId: effectiveRequestId,
            cancel: cancel,
            bypassCache: bypassCache,
            diagnostics: diagnostics,
            layerLabel: 'Guest/YtDlp',
          );
          debugPrint(
            '[YouTubeMusic] Resolved $videoId via Guest/YtDlp '
            '(${result.format.label}, hint=${result.hintExtension}, '
            'route=${result.engineRoute})',
          );
          return result;
        } on StreamingException catch (e) {
          if (e.isCancelled) rethrow;
          debugPrint(
            '[YouTubeMusic] Guest resolution failed for $videoId: '
            '${_redactSecrets(e.message)}',
          );
          rethrow;
        }
      }

      // Authenticated Mode: bundled YtDlpService is PRIMARY; InnerTube clients
      // (WEB_REMIX -> ANDROID_VR, never IOS) serve strictly as secondary
      // fallbacks.
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();

    final diagnostics = <String>[];

    // Layer 1a: Cookie-assisted YtDlpService when logged-in cookies exist
    // (skipping temp file write when a valid cached entry is already warm).
    final rawCookie = _cookie?.trim();
    if (_authMode == 'cookie' && rawCookie != null && rawCookie.isNotEmpty) {
      if (!bypassCache && _ytDlpService.getCachedStream(videoId) != null) {
        try {
          final cachedResult = await _resolveViaYtDlp(
            videoId: videoId,
            playRequestId: effectiveRequestId,
            cancel: cancel,
            bypassCache: false,
            diagnostics: diagnostics,
            layerLabel: 'Primary/YtDlp(cache)',
          );
          debugPrint(
            '[YouTubeMusic] Resolved $videoId via Primary/YtDlp(cache) '
            '(${cachedResult.format.label}, hint=${cachedResult.hintExtension}, '
            'route=${cachedResult.engineRoute})',
          );
          return cachedResult;
        } on StreamingException catch (e) {
          if (e.isCancelled) rethrow;
          diagnostics.add('Primary/YtDlp(cache) ${_redactSecrets(e.message)}');
        } catch (e) {
          diagnostics.add(
            'Primary/YtDlp(cache) ${_redactSecrets(e.toString())}',
          );
        }
      }

      final netscapeContent = _ytmBuildNetscapeCookiesContent(
        rawCookie,
        now: clock(),
      );
      if (netscapeContent.contains('\t')) {
        cancel?.throwIfCancelled();
        File? tempCookieFile;
        try {
          tempCookieFile = await _writeTempNetscapeCookiesFile(netscapeContent);
          final result = await _resolveViaYtDlp(
            videoId: videoId,
            playRequestId: effectiveRequestId,
            cancel: cancel,
            cookiesFilePath: tempCookieFile.path,
            bypassCache: bypassCache,
            diagnostics: diagnostics,
            layerLabel: 'Primary/YtDlp(cookies)',
          );
          debugPrint(
            '[YouTubeMusic] Resolved $videoId via Primary/YtDlp(cookies) '
            '(${result.format.label}, hint=${result.hintExtension}, '
            'route=${result.engineRoute})',
          );
          return result;
        } on StreamingException catch (e) {
          if (e.isCancelled) rethrow;
          diagnostics.add(
            'Primary/YtDlp(cookies) ${_redactSecrets(e.message)}',
          );
        } catch (e) {
          diagnostics.add(
            'Primary/YtDlp(cookies) ${_redactSecrets(e.toString())}',
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

    // Layer 1b: Clean YtDlpService (OAuth mode, no-cookie accounts, or cookie fallback).
    cancel?.throwIfCancelled();
    try {
      final result = await _resolveViaYtDlp(
        videoId: videoId,
        playRequestId: effectiveRequestId,
        cancel: cancel,
        bypassCache: bypassCache || diagnostics.isNotEmpty,
        diagnostics: diagnostics,
        layerLabel: 'Primary/YtDlp(clean)',
      );
      debugPrint(
        '[YouTubeMusic] Resolved $videoId via Primary/YtDlp(clean) '
        '(${result.format.label}, hint=${result.hintExtension}, '
        'route=${result.engineRoute})',
      );
      return result;
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
      diagnostics.add('Primary/YtDlp(clean) ${_redactSecrets(e.message)}');
    } catch (e) {
      diagnostics.add('Primary/YtDlp(clean) ${_redactSecrets(e.toString())}');
    }

    // Layer 2: Authenticated WEB_REMIX /youtubei/v1/player fallback.
    try {
      await _ensureVisitorData(cancel: cancel, timeout: timeout);
      cancel?.throwIfCancelled();

      final playerUri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/youtubei/v1/player',
        const <String, String>{'prettyPrint': 'false'},
      );
      final res = await http.sendJsonRaw(
        method: 'POST',
        uri: playerUri,
        headers: _buildWebRemixHeaders(authenticated: true),
        jsonBody: <String, dynamic>{
          'context': _buildWebRemixContext(),
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
        cancel: cancel,
        timeout: timeout,
      );
      cancel?.throwIfCancelled();

      if (res.statusCode >= 200 && res.statusCode < 300) {
        _captureVisitorData(res.json);
        final candidate = _tryExtractBestAudioStream(res.json);
        if (candidate != null) {
          final finalized = await _finalizeInnerTubeStream(
            candidate,
            videoId: videoId,
            clientName: 'WEB_REMIX',
            playRequestId: effectiveRequestId,
            cancel: cancel,
            diagnostics: diagnostics,
            layerLabel: 'Layer2 WEB_REMIX',
          );
          if (finalized != null) {
            debugPrint(
              '[YouTubeMusic] Resolved $videoId via Layer2 WEB_REMIX '
              '(${finalized.format.label}, hint=${finalized.hintExtension})',
            );
            return finalized;
          }
        } else {
          final playability = res.json['playabilityStatus'];
          final status =
              playability is Map ? playability['status']?.toString() : null;
          final reason =
              playability is Map ? playability['reason']?.toString() : null;
          diagnostics.add(
            'Layer2 WEB_REMIX HTTP ${res.statusCode}: '
            'status=${status ?? 'OK'}'
            '${reason != null && reason.isNotEmpty ? ' ($reason)' : ' (no direct audio URL)'}',
          );
        }
      } else {
        final apiErr = StreamingHttpClient.extractApiErrorMessage(
          res.json,
          res.rawBody,
          res.statusCode,
        );
        diagnostics.add('Layer2 WEB_REMIX ${_redactSecrets(apiErr)}');
      }
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
      diagnostics.add('Layer2 WEB_REMIX ${_redactSecrets(e.message)}');
    } catch (e) {
      diagnostics.add('Layer2 WEB_REMIX ${_redactSecrets(e.toString())}');
    }

    // Layer 3: Clean unauthenticated InnerTube fallback client (ANDROID_VR —
    // ZERO cookies/SAPISIDHASH/Client-Name 67, no IOS).
    final cleanBaseUrl = baseUrl == YouTubeMusicProvider._ytMusicOrigin
        ? YouTubeMusicProvider._ytWebOrigin
        : baseUrl;
    final cleanPlayerUri = BaseStreamingProvider.buildUri(
      cleanBaseUrl,
      '/youtubei/v1/player',
      const <String, String>{'prettyPrint': 'false'},
    );

    for (final profile in _cleanFallbackProfiles) {
      cancel?.throwIfCancelled();
      final label = 'Layer3 ${profile.clientName}';
      try {
        final res = await http.sendJsonRaw(
          method: 'POST',
          uri: cleanPlayerUri,
          headers: _buildCleanClientHeaders(profile),
          jsonBody: <String, dynamic>{
            'context': profile.context,
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
          },
          cancel: cancel,
          timeout: timeout,
        );
        cancel?.throwIfCancelled();

        if (res.statusCode >= 200 && res.statusCode < 300) {
          final candidate = _tryExtractBestAudioStream(res.json);
          if (candidate != null) {
            final finalized = await _finalizeInnerTubeStream(
              candidate,
              videoId: videoId,
              clientName: profile.clientName,
              playRequestId: effectiveRequestId,
              cancel: cancel,
              diagnostics: diagnostics,
              layerLabel: label,
            );
            if (finalized != null) {
              debugPrint(
                '[YouTubeMusic] Resolved $videoId via $label '
                '(${finalized.format.label}, hint=${finalized.hintExtension}); '
                'prior: ${diagnostics.join(" | ")}',
              );
              return finalized;
            }
          } else {
            final playability = res.json['playabilityStatus'];
            final status =
                playability is Map ? playability['status']?.toString() : null;
            final reason =
                playability is Map ? playability['reason']?.toString() : null;
            diagnostics.add(
              '$label HTTP ${res.statusCode}: status=${status ?? 'OK'}'
              '${reason != null && reason.isNotEmpty ? ' ($reason)' : ' (no direct audio URL)'}',
            );
          }
        } else {
          final apiErr = StreamingHttpClient.extractApiErrorMessage(
            res.json,
            res.rawBody,
            res.statusCode,
          );
          diagnostics.add('$label ${_redactSecrets(apiErr)}');
        }
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
        diagnostics.add('$label ${_redactSecrets(e.message)}');
      } catch (e) {
        diagnostics.add('$label ${_redactSecrets(e.toString())}');
      }
    }

    final summary = _redactSecrets(diagnostics.join(' | '));
    debugPrint('[YouTubeMusic] All layers failed for $videoId: $summary');
    final classified = StreamingException.classifyKind(message: summary);
    if (classified == StreamingErrorKind.regionRestricted) {
      throw StreamingException(
        'YouTube Music 此曲目受地區限制無法在目前區域播放',
        kind: StreamingErrorKind.regionRestricted,
      );
    }
    if (classified == StreamingErrorKind.trackUnavailable ||
        summary.contains('status=UNPLAYABLE') ||
        summary.contains('status=ERROR')) {
      throw StreamingException(
        'YouTube Music 此曲目已下架、設為私人或目前無法播放',
        kind: StreamingErrorKind.trackUnavailable,
      );
    }
      throw const StreamingException(
        'YouTube Music 未能解析可播放的音訊串流（所有 yt-dlp 與 InnerTube 解析途徑皆已失敗）',
      );
    } finally {
      cancel?.removeListener(abortResolve);
    }
  }
}
