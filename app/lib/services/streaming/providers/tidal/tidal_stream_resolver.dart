part of '../tidal_provider.dart';

extension _TidalStreamResolver on TidalProvider {
  Future<StreamSourceSpec> _resolveImpl(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    return _resolveTiers<StreamSourceSpec>(
      rawTrackId: key.trackId,
      maxQuality: _maxQualityForQualityKey(key.qualityKey),
      cancel: cancelToken,
      onTierFailed: (_, _) {},
      onDashManifest: ({
        required tier,
        required mpdXml,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        // Direct MPD XML handoff to Rust native DASH streaming (zero FfmpegAudioProxy).
        return SegmentedManifestSpec(
          key: key,
          manifestUrlOrXml: mpdXml,
          format: ManifestFormat.dash,
          mimeType: isFlac ? 'audio/flac' : 'audio/mp4',
          expireAt: _extractDashMpdExpireAt(mpdXml),
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: AudioFormat(
            codec: isFlac ? AudioCodec.flac : AudioCodec.aac,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
            bitrateKbps: _tidalLossyBitrateKbps(audioQuality, isFlac: isFlac),
          ),
        );
      },
      onBtsStream: ({
        required tier,
        required streamUrl,
        required manifestMime,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        return DirectRangeSpec(
          key: key,
          url: streamUrl,
          mimeType: manifestMime.isNotEmpty
              ? manifestMime
              : (isFlac ? 'audio/flac' : 'audio/mp4'),
          hintExtension: isFlac ? 'flac' : 'm4a',
          expireAt: _extractUrlExpireAt(streamUrl),
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: AudioFormat(
            codec: isFlac ? AudioCodec.flac : AudioCodec.aac,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
            bitrateKbps: _tidalLossyBitrateKbps(audioQuality, isFlac: isFlac),
          ),
        );
      },
    );
  }

  Future<ResolvedStreamResult> _resolveStreamImpl(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    String maxQuality = 'HI_RES_LOSSLESS',
  }) async {
    final trackId = BaseStreamingProvider.stripTrackPrefix(track.id, 'tidal');
    final effectiveRequestId = playRequestId ?? (--_fallbackRequestCounter);
    final ytDlp = _ytDlpService ?? YtDlpService.instance;
    void abortResolve() => ytDlp.cancelRequest(effectiveRequestId);
    cancel?.addListener(abortResolve);
    try {
      return await _resolveTiers<ResolvedStreamResult>(
        rawTrackId: track.id,
        maxQuality: maxQuality,
        cancel: cancel,
        timeout: timeout,
        onTierFailed: (_, _) {},
        onDashManifest: ({
          required tier,
          required mpdXml,
          required isFlac,
          required audioQuality,
          required sampleRate,
          required bitDepth,
          loudness,
          albumLoudness,
        }) async {
          final String proxyUrl;
          try {
            proxyUrl = await ytDlp.openDashMpdUrl(
              mpdXml: mpdXml,
              playRequestId: effectiveRequestId,
              copyFlac: isFlac,
            );
        } catch (e) {
          if (e is StreamingException && e.isCancelled) rethrow;
          if (e is YtDlpException && e.isCancelled) {
            throw const StreamingException('操作已取消', isCancelled: true);
          }
          final msg = e is YtDlpException ? e.message : e.toString();
          debugPrint(
            '[Tidal Play] track=$trackId tier=$tier failed ($msg); trying next tier',
          );
          return null;
        }
        cancel?.throwIfCancelled();

        final engineRoute = isFlac
            ? 'Tidal DASH FLAC ($audioQuality, ffmpeg remux)'
            : 'Tidal DASH PCM ($audioQuality, ffmpeg)';
        debugPrint(
          '[Tidal Play] track=$trackId requested=$tier actual=$audioQuality mime=application/dash+xml codec=${isFlac ? 'FLAC' : 'AAC'} ${sampleRate}Hz/${bitDepth}bit route=$engineRoute',
        );

        return ResolvedStreamResult(
          url: proxyUrl,
          hintExtension: isFlac ? 'flac' : 'wav',
          format: AudioFormat(
            codec: isFlac ? AudioCodec.flac : AudioCodec.aac,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
            bitrateKbps: _tidalLossyBitrateKbps(audioQuality, isFlac: isFlac),
          ),
          engineRoute: engineRoute,
        );
      },
      onBtsStream: ({
        required tier,
        required streamUrl,
        required manifestMime,
        required isFlac,
        required audioQuality,
        required sampleRate,
        required bitDepth,
        loudness,
        albumLoudness,
      }) async {
        final codec = isFlac ? AudioCodec.flac : AudioCodec.aac;
        final engineRoute = isFlac
            ? 'Tidal Direct FLAC ($audioQuality)'
            : 'Tidal Direct AAC ($audioQuality)';
        debugPrint(
          '[Tidal Play] track=$trackId requested=$tier actual=$audioQuality mime=application/vnd.tidal.bts codec=${isFlac ? 'FLAC' : 'AAC'} ${sampleRate}Hz/${bitDepth}bit route=$engineRoute',
        );

        return ResolvedStreamResult(
          url: streamUrl,
          hintExtension: isFlac ? 'flac' : 'm4a',
          format: AudioFormat(
            codec: codec,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            channels: 2,
            bitrateKbps: _tidalLossyBitrateKbps(audioQuality, isFlac: isFlac),
          ),
          engineRoute: engineRoute,
        );
      },
    );
    } finally {
      cancel?.removeListener(abortResolve);
    }
  }
}
