part of '../single_flight_resolver.dart';

extension _SingleFlightRefreshExt on SingleFlightResolver {
  Future<RefreshAfter403Result> _refreshAfter403Impl(
    StreamKey key, {
    required String failedUrl,
    int? expectedContentLength,
    String? expectedMimeType,
    String? expectedStreamKind,
    AudioFormat? expectedAudioFormat,
    int? expectedInitRangeEnd,
    bool allowFormatChange = false,
    CancellationToken? cancelToken,
    TrackInfo? legacyTrack,
    Future<StreamSourceSpec> Function(CancellationToken taskCancel)?
        customInvoker,
  }) async {
    if (cancelToken?.isCancelled == true) {
      return const RefreshAfter403Failed(
        message: '操作已取消',
        isCancelled: true,
      );
    }

    final auth = _authManager;
    if (auth != null && auth.isPlaybackAuthBlocked(key.providerId)) {
      return RefreshAfter403AuthRequired(
        providerId: key.providerId,
        message: auth.authErrorFor(key.providerId) ?? '授權已失效，請重新登入',
      );
    }

    final resolver = registry.resolverFor(key.providerId);
    if (resolver == null) {
      return RefreshAfter403Failed(message: '未註冊的串流解析器：${key.providerId}');
    }
    final caps = resolver.capabilities;

    // Capture baseline metadata before CAS invalidation.
    final previousSpec = caps.supportsL1UrlCache ? l1Cache.peek(key, caps) : null;
    final baseContentLength =
        expectedContentLength ?? _extractContentLength(previousSpec);
    final baseMime =
        _normalizeMime(expectedMimeType ?? _extractMimeType(previousSpec));
    final baseKind = expectedStreamKind ?? previousSpec?.kind;
    final baseAudioFormat = expectedAudioFormat ?? previousSpec?.audioFormat;
    final baseInitRangeEnd = expectedInitRangeEnd ??
        (previousSpec is DirectRangeSpec ? previousSpec.initRangeEnd : null);
    final baseCipher =
        previousSpec is EncryptedRangeSpec ? previousSpec.cipher : null;

    // CAS conditional invalidation: if another caller already refreshed this
    // key to a different URL, preserve and reuse that fresh spec immediately.
    if (caps.supportsL1UrlCache) {
      final cas = l1Cache.compareAndEvict(key, caps, failedUrl);
      if (!cas.evicted && cas.currentSpec != null) {
        return _evaluateRefreshedSpec(
          freshSpec: cas.currentSpec!,
          reusedFromCache: true,
          allowFormatChange: allowFormatChange,
          baseContentLength: baseContentLength,
          baseMime: baseMime,
          baseKind: baseKind,
          baseAudioFormat: baseAudioFormat,
          baseInitRangeEnd: baseInitRangeEnd,
          baseCipher: baseCipher,
        );
      }
    }

    var retriedAuth = false;
    while (true) {
      try {
        final freshSpec = await resolve(
          key,
          cancelToken: cancelToken,
          bypassCache: false,
          legacyTrack: legacyTrack,
          customInvoker: customInvoker,
        );
        return _evaluateRefreshedSpec(
          freshSpec: freshSpec,
          reusedFromCache: false,
          allowFormatChange: allowFormatChange,
          baseContentLength: baseContentLength,
          baseMime: baseMime,
          baseKind: baseKind,
          baseAudioFormat: baseAudioFormat,
          baseInitRangeEnd: baseInitRangeEnd,
          baseCipher: baseCipher,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled) {
          return RefreshAfter403Failed(
            message: e.message,
            statusCode: e.statusCode,
            isCancelled: true,
            errorKind: e.kind,
          );
        }
        if (e.isRegionRestricted || e.isUnavailable) {
          // Geo-blocked / taken-down tracks are permanent per-track failures:
          // never trigger token refresh or trip the provider auth breaker.
          return RefreshAfter403Failed(
            message: e.message,
            statusCode: e.statusCode,
            errorKind: e.kind,
          );
        }
        if (AuthManager.isUnauthorizedError(e)) {
          if (auth != null && auth.isGuestPlaybackCapable(key.providerId)) {
            return RefreshAfter403Failed(
              message: e.message,
              statusCode: e.statusCode,
              errorKind: e.kind,
            );
          }
          if (auth != null) {
            final refreshed = await auth.handleUnauthorized(
              key.providerId,
              e.message,
              alreadyRetried: retriedAuth,
            );
            if (refreshed && !retriedAuth) {
              retriedAuth = true;
              continue;
            }
            return RefreshAfter403AuthRequired(
              providerId: key.providerId,
              message: auth.authErrorFor(key.providerId) ?? e.message,
            );
          }
          return RefreshAfter403AuthRequired(
            providerId: key.providerId,
            message: e.message,
          );
        }
        return RefreshAfter403Failed(
          message: e.message,
          statusCode: e.statusCode,
          errorKind: e.kind,
        );
      } catch (e) {
        return RefreshAfter403Failed(message: e.toString());
      }
    }
  }

  static RefreshAfter403Result _evaluateRefreshedSpec({
    required StreamSourceSpec freshSpec,
    required bool reusedFromCache,
    required bool allowFormatChange,
    required int? baseContentLength,
    required String? baseMime,
    required String? baseKind,
    required AudioFormat? baseAudioFormat,
    required int? baseInitRangeEnd,
    required StreamCipher? baseCipher,
  }) {
    if (allowFormatChange) {
      return RefreshAfter403Updated(
        spec: freshSpec,
        reusedFromCache: reusedFromCache,
      );
    }
    final diffReason = _detectFormatDrift(
      freshSpec: freshSpec,
      baseContentLength: baseContentLength,
      baseMime: baseMime,
      baseKind: baseKind,
      baseAudioFormat: baseAudioFormat,
      baseInitRangeEnd: baseInitRangeEnd,
      baseCipher: baseCipher,
    );
    if (diffReason != null) {
      return RefreshAfter403FormatChanged(
        spec: freshSpec,
        reason: diffReason,
      );
    }
    return RefreshAfter403Updated(
      spec: freshSpec,
      reusedFromCache: reusedFromCache,
    );
  }

  static String? _detectFormatDrift({
    required StreamSourceSpec freshSpec,
    required int? baseContentLength,
    required String? baseMime,
    required String? baseKind,
    required AudioFormat? baseAudioFormat,
    required int? baseInitRangeEnd,
    required StreamCipher? baseCipher,
  }) {
    if (baseKind != null && freshSpec.kind != baseKind) {
      return 'stream kind changed: $baseKind -> ${freshSpec.kind}';
    }

    final freshLen = _extractContentLength(freshSpec);
    if (baseContentLength != null &&
        freshLen != null &&
        baseContentLength != freshLen) {
      return 'content_length changed: $baseContentLength -> $freshLen';
    }

    final freshMime = _normalizeMime(_extractMimeType(freshSpec));
    if (baseMime != null && freshMime != null && baseMime != freshMime) {
      return 'mime_type changed: $baseMime -> $freshMime';
    }

    final freshFmt = freshSpec.audioFormat;
    if (baseAudioFormat != null && freshFmt != null) {
      if (baseAudioFormat.codec != freshFmt.codec ||
          baseAudioFormat.sampleRateHz != freshFmt.sampleRateHz ||
          baseAudioFormat.bitDepth != freshFmt.bitDepth ||
          baseAudioFormat.channels != freshFmt.channels) {
        return 'audio_format changed: ${baseAudioFormat.label} -> ${freshFmt.label}';
      }
    }

    if (baseInitRangeEnd != null && freshSpec is DirectRangeSpec) {
      final freshInit = freshSpec.initRangeEnd;
      if (freshInit != null && freshInit != baseInitRangeEnd) {
        return 'init_range_end changed: $baseInitRangeEnd -> $freshInit';
      }
    }

    if (baseCipher != null &&
        freshSpec is EncryptedRangeSpec &&
        freshSpec.cipher != baseCipher) {
      return 'stream cipher changed';
    }

    return null;
  }

  static int? _extractContentLength(StreamSourceSpec? spec) {
    return switch (spec) {
      DirectRangeSpec() => spec.contentLength,
      EncryptedRangeSpec() => spec.contentLength,
      _ => null,
    };
  }

  static String? _extractMimeType(StreamSourceSpec? spec) {
    return switch (spec) {
      DirectRangeSpec() => spec.mimeType,
      SegmentedManifestSpec() => spec.mimeType,
      EncryptedRangeSpec() => spec.mimeType,
      _ => null,
    };
  }

  static String? _normalizeMime(String? raw) {
    final trimmed = raw?.trim().toLowerCase();
    if (trimmed == null || trimmed.isEmpty) return null;
    final semi = trimmed.indexOf(';');
    final base = semi >= 0 ? trimmed.substring(0, semi).trim() : trimmed;
    return base.isEmpty ? null : base;
  }
}
