import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/podcast_models.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../pot_provider.dart';
import '../recommendation_provider.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';
import '../yt_dlp_service.dart';
import '../ytm_resident_resolver.dart';

class _InnerTubeClientProfile {
  final String clientName;
  final String clientNameHeader;
  final String clientVersion;
  final String userAgent;
  final Map<String, dynamic> context;

  const _InnerTubeClientProfile({
    required this.clientName,
    required this.clientNameHeader,
    required this.clientVersion,
    required this.userAgent,
    required this.context,
  });
}

class _InnerTubeAudioCandidate {
  final ResolvedStreamResult result;
  final bool requiresFfmpegTranscode;

  const _InnerTubeAudioCandidate({
    required this.result,
    required this.requiresFfmpegTranscode,
  });
}

/// Real YouTube Music InnerTube + Google OAuth 2.0 Device Flow + yt-dlp provider.
class YouTubeMusicProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const String _ytMusicOrigin = 'https://music.youtube.com';
  static const String _ytWebOrigin = 'https://www.youtube.com';
  static const String _youtubeScope =
      'https://www.googleapis.com/auth/youtube.readonly';
  static const String _webRemixClientNameHeader = '67';
  static const String _webRemixClientVersion = '1.20241120.01.00';
  static const String _desktopChromeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static final RegExp _validVideoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final RegExp _visitorDataPattern = RegExp(r'^Cg[A-Za-z0-9_%=-]{8,}$');

  static const List<_InnerTubeClientProfile> _cleanFallbackProfiles =
      <_InnerTubeClientProfile>[
        _InnerTubeClientProfile(
          clientName: 'ANDROID_VR',
          clientNameHeader: '28',
          clientVersion: '1.60.19',
          userAgent:
              'com.google.android.apps.youtube.vr.oculus/1.60.19 '
              '(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
          context: <String, dynamic>{
            'client': <String, dynamic>{
              'clientName': 'ANDROID_VR',
              'clientVersion': '1.60.19',
              'deviceMake': 'Oculus',
              'deviceModel': 'Quest 3',
              'osName': 'Android',
              'osVersion': '12L',
              'androidSdkVersion': 32,
              'hl': 'zh-TW',
              'gl': 'TW',
            },
          },
        ),
      ];

  final String baseUrl;
  final String oauthBaseUrl;
  final Future<bool> Function(String url)? urlOpener;
  final YtDlpService _ytDlpService;
  late final YtmResidentResolver _residentResolver;
  final bool _ownsResidentResolver;

  String _authMode = 'cookie';
  String? _cookie;
  String? _clientId;
  String? _clientSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _visitorData;
  String? _nextHomeContinuation;
  String? _nextExploreContinuation;
  final List<String> _recentSeedVideoIds = <String>[];
  int _fallbackRequestCounter = 0;
  Future<void>? _inFlightRefresh;

  YouTubeMusicProvider({
    required super.credentialStore,
    HttpClient Function()? httpClientFactory,
    Duration requestTimeout = const Duration(seconds: 15),
    super.clock,
    this.baseUrl = _ytMusicOrigin,
    this.oauthBaseUrl = 'https://oauth2.googleapis.com',
    this.urlOpener,
    YtDlpService? ytDlpService,
    YtmResidentResolver? residentResolver,
    PotProvider? potProvider,
    bool ownsPotProvider = false,
    VoidCallback? onHttp2Warmup,
  }) : _ytDlpService = ytDlpService ?? YtDlpService.instance,
       _ownsResidentResolver = residentResolver == null,
       super(
         httpClientFactory: httpClientFactory,
         requestTimeout: requestTimeout,
       ) {
    _residentResolver = residentResolver ??
        YtmResidentResolver(
          httpClient: httpClientFactory?.call(),
          authProvider: _currentResidentAuth,
          potProvider: potProvider,
          ownsPotProvider: ownsPotProvider,
          onHttp2Warmup: onHttp2Warmup,
          fallbackResolver: _resolveSpecViaYtDlpFallback,
          webBaseUrl: baseUrl == _ytMusicOrigin
              ? YtmResidentResolver.defaultWebOrigin
              : baseUrl,
          musicBaseUrl: baseUrl,
          requestTimeout: requestTimeout,
          clock: clock,
        );
  }

  @override
  String get kind => 'youtube_music';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.youtubeMusic;

  @override
  bool get supportsSilentRefresh =>
      _authMode == 'oauth_device' &&
      (_refreshToken?.trim().isNotEmpty ?? false) &&
      (_clientId?.trim().isNotEmpty ?? false);

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

  @visibleForTesting
  YtmResidentResolver get residentResolver => _residentResolver;

  /// Async background warmup pre-warming InnerTube TLS/HTTP2 pools, session
  /// `visitorData`, and Session-level GVS PO Token via [YtmResidentResolver].
  Future<void> warmup({bool force = false}) =>
      _residentResolver.warmup(force: force);

  /// Resets the resident HTTP client and invalidates cached session `visitorData`
  /// & GVS PO Token after a network interface / IP transition.
  void handleNetworkEpochChanged() {
    _residentResolver.resetHttpClient();
    _residentResolver.invalidateSession();
  }

  /// Notifies the resident resolver that authentication state has been restored
  /// so any guest-mode session context or GVS PO Token is invalidated.
  void onAuthSessionRestored() {
    if (authState == StreamingAuthState.connected) {
      _residentResolver.invalidateSession();
    }
  }

  YtmAuthCredentials? _currentResidentAuth() {
    if (authState != StreamingAuthState.connected) return null;
    return YtmAuthCredentials(
      authMode: _authMode,
      cookie: _cookie,
      accessToken: _accessToken,
      visitorData: _visitorData,
    );
  }

  @override
  Future<StreamSourceSpec> resolve(
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
      final netscapeContent = buildNetscapeCookiesContent(
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

  static String _buildYtDlpExtractorArgs({
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
      headers['User-Agent'] = _desktopChromeUserAgent;
    }
    if (!hasAccept) {
      headers['Accept'] = '*/*';
    }

    final urlClient =
        Uri.tryParse(finalUrl)?.queryParameters['c']?.trim().toUpperCase() ??
            '';
    if (urlClient == 'WEB_REMIX') {
      if (!hasOrigin) headers['Origin'] = _ytMusicOrigin;
      if (!hasReferer) headers['Referer'] = '$_ytMusicOrigin/';
    } else if (urlClient == 'WEB' ||
        urlClient == 'MWEB' ||
        urlClient == 'WEB_SAFARI' ||
        urlClient.startsWith('WEB_')) {
      if (!hasOrigin) headers['Origin'] = _ytWebOrigin;
      if (!hasReferer) headers['Referer'] = '$_ytWebOrigin/';
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

  static String _resolveMimeTypeForYtDlp(
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

  Future<void> disposeAsync() async {
    if (_ownsResidentResolver) {
      await _residentResolver.disposeAsync();
    }
  }

  void dispose() {
    if (_ownsResidentResolver) {
      _residentResolver.dispose();
    }
  }

  @override
  bool get supportsGuestMode => true;

  @visibleForTesting
  String? get visitorData => _visitorData;

  /// Parses `SAPISID` / `__Secure-3PAPISID` / `__Secure-1PAPISID` from a browser
  /// Cookie header and computes the Google `SAPISIDHASH` Authorization value.
  static String? extractSapisidFromCookie(String cookieHeader) {
    final map = <String, String>{};
    for (final part in cookieHeader.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final name = part.substring(0, idx).trim();
      var value = part.substring(idx + 1).trim();
      if (value.length >= 2 &&
          value.startsWith('"') &&
          value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (name.isNotEmpty && value.isNotEmpty) {
        map[name] = value;
      }
    }
    return map['SAPISID'] ??
        map['__Secure-3PAPISID'] ??
        map['__Secure-1PAPISID'];
  }

  static String computeSapisidHash(
    String sapisid, {
    required int timestampSeconds,
    String origin = _ytMusicOrigin,
  }) {
    final digest = sha1
        .convert(utf8.encode('$timestampSeconds $sapisid $origin'))
        .toString();
    return 'SAPISIDHASH ${timestampSeconds}_$digest';
  }

  /// Non-throwing variant of [extractCleanVideoId] for background preloaders.
  static String? tryExtractCleanVideoId(String rawId, {String? filePath}) {
    try {
      return extractCleanVideoId(rawId, filePath: filePath);
    } catch (_) {
      return null;
    }
  }

  /// Strips internal prefixes (`ytm:`, `ytm_`, `streaming:youtube_music:`,
  /// `youtube_music:`), extracts the `v` param or `youtu.be/<id>` segment from
  /// YouTube URLs, and strictly validates a pure 11-char YouTube Video ID.
  ///
  /// Rejects `browseId` (`MPREb_`, `VL`, `FE`, `UC`) and `playlistId` (`PL`,
  /// `RD`, `OLAK`) values with a descriptive [StreamingException].
  @visibleForTesting
  static String extractCleanVideoId(String rawId, {String? filePath}) {
    var candidate = _extractCandidateVideoId(rawId);
    if (candidate == null || candidate.isEmpty) {
      if (filePath != null && filePath.trim().isNotEmpty) {
        candidate = _extractCandidateVideoId(filePath);
      }
    } else if (_classifyNonVideoId(candidate) == null &&
        !_validVideoIdPattern.hasMatch(candidate) &&
        filePath != null &&
        filePath.trim().isNotEmpty) {
      final fromFile = _extractCandidateVideoId(filePath);
      if (fromFile != null &&
          fromFile.isNotEmpty &&
          _classifyNonVideoId(fromFile) == null &&
          _validVideoIdPattern.hasMatch(fromFile)) {
        candidate = fromFile;
      }
    }

    if (candidate == null || candidate.isEmpty) {
      throw const StreamingException('曲目缺少有效的 YouTube videoId');
    }

    final nonVideoKind = _classifyNonVideoId(candidate);
    if (nonVideoKind != null) {
      throw StreamingException(
        '無效的 YouTube videoId：不支援 $nonVideoKind（$candidate）',
      );
    }

    if (!_validVideoIdPattern.hasMatch(candidate)) {
      throw StreamingException(
        '無效的 YouTube videoId（須為 11 碼英數字元）：$candidate',
      );
    }

    return candidate;
  }

  static String? _extractCandidateVideoId(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;

    // Repeatedly strip internal prefixes.
    var changed = true;
    while (changed && s.isNotEmpty) {
      changed = false;
      for (final prefix in const <String>[
        'streaming:youtube_music:',
        'youtube_music:',
        'ytm:',
      ]) {
        if (s.startsWith(prefix)) {
          s = s.substring(prefix.length).trim();
          changed = true;
        }
      }
      if (s.startsWith('ytm_') && s.length > 11) {
        s = s.substring(4).trim();
        changed = true;
      }
      if (s.startsWith('MPED') && s.length == 15) {
        s = s.substring(4).trim();
        changed = true;
      }
    }

    if (s.isEmpty) return null;

    // Extract videoId from YouTube / YouTube Music / youtu.be URLs.
    final lower = s.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.contains('youtube.com/') ||
        lower.contains('youtu.be/')) {
      final uri = Uri.tryParse(
        (lower.startsWith('http://') || lower.startsWith('https://'))
            ? s
            : 'https://$s',
      );
      if (uri != null) {
        final host = uri.host.toLowerCase();
        if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
          final segs = uri.pathSegments.where((seg) => seg.isNotEmpty).toList();
          if (segs.isNotEmpty) {
            return segs.first.trim();
          }
          return null;
        }
        if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
          final v = uri.queryParameters['v']?.trim();
          if (v != null && v.isNotEmpty) {
            return v;
          }
          final segs = uri.pathSegments.where((seg) => seg.isNotEmpty).toList();
          if (segs.length >= 2 &&
              (segs.first == 'embed' ||
                  segs.first == 'shorts' ||
                  segs.first == 'v')) {
            return segs[1].trim();
          }
          final listParam = uri.queryParameters['list']?.trim();
          if (listParam != null && listParam.isNotEmpty) {
            return listParam;
          }
          return null;
        }
      }
    }

    return s;
  }

  static String? _classifyNonVideoId(String value) {
    if (value.startsWith('MPREb_') ||
        value.startsWith('MPSP') ||
        value.startsWith('VL') ||
        value.startsWith('FE') ||
        value.startsWith('UC')) {
      return 'browseId';
    }
    if (value.startsWith('PL') ||
        value.startsWith('RD') ||
        value.startsWith('OLAK')) {
      return 'playlistId';
    }
    return null;
  }

  /// Converts a browser `Cookie` header into a valid Netscape HTTP Cookie File
  /// covering `.youtube.com` and `music.youtube.com` for `yt-dlp --cookies`.
  @visibleForTesting
  static String buildNetscapeCookiesContent(
    String cookieHeader, {
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final expiry =
        (effectiveNow.millisecondsSinceEpoch ~/ 1000) + (86400 * 30);
    final buf = StringBuffer()
      ..writeln('# Netscape HTTP Cookie File')
      ..writeln('# Temporary file generated by Lumina Audio');

    final seenPairs = <String>{};
    for (final rawPart in cookieHeader.split(';')) {
      final idx = rawPart.indexOf('=');
      if (idx <= 0) continue;
      final name = rawPart
          .substring(0, idx)
          .replaceAll(RegExp(r'[\r\n\t]'), '')
          .trim();
      var value = rawPart
          .substring(idx + 1)
          .replaceAll(RegExp(r'[\r\n\t]'), '')
          .trim();
      if (value.length >= 2 &&
          value.startsWith('"') &&
          value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (name.isEmpty || value.isEmpty) continue;
      if (!seenPairs.add(name)) continue;

      if (!name.startsWith('__Host-')) {
        buf.writeln('.youtube.com\tTRUE\t/\tTRUE\t$expiry\t$name\t$value');
      }
      buf.writeln('music.youtube.com\tFALSE\t/\tTRUE\t$expiry\t$name\t$value');
    }
    return buf.toString();
  }

  Map<String, dynamic> _buildWebRemixContext() {
    final vd = _visitorData?.trim();
    return <String, dynamic>{
      'client': <String, dynamic>{
        'clientName': 'WEB_REMIX',
        'clientVersion': _webRemixClientVersion,
        'hl': 'zh-TW',
        'gl': 'TW',
        if (vd != null && vd.isNotEmpty) 'visitorData': vd,
      },
    };
  }

  Map<String, String> _buildWebRemixHeaders({bool authenticated = true}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Origin': _ytMusicOrigin,
      'X-Origin': _ytMusicOrigin,
      'Referer': '$_ytMusicOrigin/',
      'X-Youtube-Client-Name': _webRemixClientNameHeader,
      'X-Youtube-Client-Version': _webRemixClientVersion,
      'User-Agent': _desktopChromeUserAgent,
    };

    final vd = _visitorData?.trim();
    if (vd != null && vd.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = vd;
    }

    if (authenticated) {
      if (_authMode == 'cookie' && _cookie != null && _cookie!.isNotEmpty) {
        final sapisid = extractSapisidFromCookie(_cookie!);
        if (sapisid == null || sapisid.isEmpty) {
          throw const StreamingException(
            'Cookie 缺少 SAPISID 或 __Secure-3PAPISID，無法產生授權簽章',
            statusCode: 401,
          );
        }
        final ts = clock().millisecondsSinceEpoch ~/ 1000;
        headers['X-Goog-AuthUser'] = '0';
        headers['Cookie'] = _cookie!;
        headers['Authorization'] = computeSapisidHash(
          sapisid,
          timestampSeconds: ts,
        );
      } else if (_accessToken != null && _accessToken!.isNotEmpty) {
        headers['Authorization'] = 'Bearer $_accessToken';
      }
    }
    return headers;
  }

  /// Builds strictly isolated headers for unauthenticated fallback
  /// InnerTube clients (`ANDROID_VR`) with ZERO Web Cookie / SAPISIDHASH /
  /// Bearer / Client-Name 67 / Origin / X-Origin / Referer / X-Goog-AuthUser
  /// leakage.
  Map<String, String> _buildCleanClientHeaders(_InnerTubeClientProfile profile) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': profile.userAgent,
      'X-Youtube-Client-Name': profile.clientNameHeader,
      'X-Youtube-Client-Version': profile.clientVersion,
    };
    const forbidden = <String>{
      'cookie',
      'authorization',
      'origin',
      'x-origin',
      'referer',
      'x-goog-authuser',
    };
    assert(
      headers.keys.every((k) => !forbidden.contains(k.toLowerCase())),
      'Clean InnerTube client must never include web auth headers',
    );
    return headers;
  }

  void _captureVisitorData(Map<String, dynamic> json) {
    final rc = json['responseContext'];
    if (rc is Map) {
      final vd = rc['visitorData']?.toString().trim();
      if (vd != null && vd.isNotEmpty) {
        _visitorData = vd;
      }
    }
  }

  static String? _extractVisitorDataFromSwJsData(String rawBody) {
    var trimmed = rawBody.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith(")]}'")) {
      final newlineIdx = trimmed.indexOf('\n');
      trimmed = newlineIdx >= 0
          ? trimmed.substring(newlineIdx + 1).trim()
          : trimmed.substring(4).trim();
    }
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final direct = decoded['visitorData']?.toString().trim();
        if (direct != null && direct.isNotEmpty) return direct;
        final rc = decoded['responseContext'];
        if (rc is Map) {
          final nested = rc['visitorData']?.toString().trim();
          if (nested != null && nested.isNotEmpty) return nested;
        }
      }
      return _findVisitorDataInDynamic(decoded);
    } catch (_) {
      return null;
    }
  }

  static String? _findVisitorDataInDynamic(dynamic node) {
    if (node is String) {
      final trimmed = node.trim();
      if (_visitorDataPattern.hasMatch(trimmed)) {
        return trimmed;
      }
      return null;
    }
    if (node is List) {
      for (final item in node) {
        final found = _findVisitorDataInDynamic(item);
        if (found != null) return found;
      }
    } else if (node is Map) {
      final direct = node['visitorData'];
      if (direct is String && direct.trim().isNotEmpty) {
        return direct.trim();
      }
      for (final val in node.values) {
        final found = _findVisitorDataInDynamic(val);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<void> _ensureVisitorData({
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    if (_visitorData != null && _visitorData!.trim().isNotEmpty) return;
    cancel?.throwIfCancelled();

    final effectiveTimeout =
        (timeout != null && timeout < const Duration(seconds: 4))
            ? timeout
            : const Duration(seconds: 4);

    // 1. Lightweight GET /sw.js_data (no auth cookies).
    try {
      final swUri = BaseStreamingProvider.buildUri(baseUrl, '/sw.js_data');
      final resp = await http.send(
        method: 'GET',
        uri: swUri,
        headers: const <String, String>{
          'User-Agent': _desktopChromeUserAgent,
        },
        cancel: cancel,
        timeout: effectiveTimeout,
      );
      if (resp.isSuccess) {
        final extracted = _extractVisitorDataFromSwJsData(resp.body);
        if (extracted != null && extracted.isNotEmpty) {
          _visitorData = extracted;
          return;
        }
      }
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
    } catch (_) {}

    cancel?.throwIfCancelled();
    if (_visitorData != null && _visitorData!.trim().isNotEmpty) return;

    // 2. Fallback: unauthenticated WEB_REMIX /youtubei/v1/browse.
    try {
      final browseUri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/youtubei/v1/browse',
        const <String, String>{'prettyPrint': 'false'},
      );
      final res = await http.sendJsonRaw(
        method: 'POST',
        uri: browseUri,
        headers: _buildWebRemixHeaders(authenticated: false),
        jsonBody: <String, dynamic>{
          'context': _buildWebRemixContext(),
          'browseId': 'FEmusic_home',
        },
        cancel: cancel,
        timeout: effectiveTimeout,
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _captureVisitorData(res.json);
      }
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
    } catch (_) {}
  }

  String _redactSecrets(String input) {
    var out = input;
    final cookie = _cookie;
    if (cookie != null && cookie.isNotEmpty) {
      out = out.replaceAll(cookie, '[REDACTED]');
      final sapisid = extractSapisidFromCookie(cookie);
      if (sapisid != null && sapisid.isNotEmpty) {
        out = out.replaceAll(sapisid, '[REDACTED]');
      }
    }
    final token = _accessToken;
    if (token != null && token.isNotEmpty) {
      out = out.replaceAll(token, '[REDACTED]');
    }
    return out;
  }

  @override
  Future<void> restoreFromStorage() async {
    try {
      final stored = await readCredentialsJson();
      if (stored == null) {
        resetState();
        return;
      }

      _authMode = stored['mode']?.toString() ?? 'cookie';
      _cookie = stored['cookie']?.toString();
      _clientId = stored['client_id']?.toString();
      _clientSecret = stored['client_secret']?.toString();
      _accessToken = stored['access_token']?.toString();
      _refreshToken = stored['refresh_token']?.toString();
      final expRaw = stored['expires_at']?.toString();
      _expiresAt = expRaw != null ? DateTime.tryParse(expRaw) : null;

      await refreshSessionIfNeeded();
      final account = await _verifyAccountLive();
      setConnected(account);
      _residentResolver.invalidateSession();
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    setAuthenticating();
    try {
      cancel?.throwIfCancelled();

      final requestedMode = params['mode']?.toString().trim();
      final cookieVal =
          (params['cookie'] ?? params['auth_cookie'])?.toString().trim();

      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (cookieVal != null && cookieVal.isNotEmpty
                ? 'cookie'
                : 'oauth_device');

      if (mode == 'cookie') {
        if (cookieVal == null || cookieVal.isEmpty) {
          throw const StreamingException('請輸入包含 SAPISID 的 YouTube Music Cookie');
        }
        final sapisid = extractSapisidFromCookie(cookieVal);
        if (sapisid == null || sapisid.isEmpty) {
          throw const StreamingException(
            'Cookie 缺少 SAPISID 或 __Secure-3PAPISID，無法驗證 YouTube Music 身分',
            statusCode: 401,
          );
        }

        _authMode = 'cookie';
        _cookie = cookieVal;
        _accessToken = null;
        _refreshToken = null;
        _expiresAt = null;

        onProgress?.call('正在向 YouTube Music 驗證 Cookie 工作階段...');
        final account = await _verifyAccountLive(cancel: cancel);
        setConnected(account);
        _residentResolver.invalidateSession();
        clearStreamCache();
        await _persistCredentials(account);
        return;
      }

      if (mode == 'oauth_device') {
        final clientId = params['client_id']?.toString().trim() ?? '';
        final clientSecret = params['client_secret']?.toString().trim() ?? '';
        if (clientId.isEmpty) {
          throw const StreamingException(
            'Google OAuth 裝置授權需要提供 client_id',
          );
        }

        _authMode = 'oauth_device';
        _clientId = clientId;
        _clientSecret = clientSecret;
        _cookie = null;

        onProgress?.call('正在向 Google OAuth 請求裝置授權碼...');
        final deviceUri =
            BaseStreamingProvider.buildUri(oauthBaseUrl, '/device/code');
        final deviceResp = await http.requestJson(
          method: 'POST',
          uri: deviceUri,
          formBody: BaseStreamingProvider.encodeForm(<String, String>{
            'client_id': clientId,
            'scope': _youtubeScope,
          }),
          cancel: cancel,
        );

        final deviceCode = deviceResp['device_code']?.toString() ?? '';
        final userCode = deviceResp['user_code']?.toString() ?? '';
        final verificationUrl =
            (deviceResp['verification_url'] ?? deviceResp['verification_uri'])
                ?.toString() ??
            'https://www.google.com/device';
        final expiresIn = (deviceResp['expires_in'] as num?)?.toInt() ?? 1800;
        final intervalSec = (deviceResp['interval'] as num?)?.toInt() ?? 5;

        if (deviceCode.isEmpty || userCode.isEmpty) {
          throw const StreamingException(
            'Google OAuth 未回傳有效的 device_code 或 user_code',
          );
        }

        onProgress?.call('請開啟 $verificationUrl 並輸入代碼：$userCode');
        try {
          await openSystemBrowser(verificationUrl, urlOpener: urlOpener);
        } catch (_) {
          // Non-fatal: user already received verification URL and code in progress callback.
        }

        final deadline = clock().add(Duration(seconds: expiresIn));
        var pollDelay = intervalSec <= 0
            ? const Duration(milliseconds: 25)
            : Duration(seconds: intervalSec);
        final tokenUri =
            BaseStreamingProvider.buildUri(oauthBaseUrl, '/token');

        while (true) {
          cancel?.throwIfCancelled();
          if (clock().isAfter(deadline)) {
            throw const StreamingException(
              'Google 裝置授權碼已過期，請重新登入',
              isTokenExpired: true,
            );
          }

          await BaseStreamingProvider.cancellableDelay(pollDelay, cancel);

          final tokenForm = <String, String>{
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'device_code': deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          };
          final res = await http.sendJsonRaw(
            method: 'POST',
            uri: tokenUri,
            formBody: BaseStreamingProvider.encodeForm(tokenForm),
            cancel: cancel,
          );

          if (res.statusCode >= 200 && res.statusCode < 300) {
            final access = res.json['access_token']?.toString().trim() ?? '';
            if (access.isEmpty) {
              throw const StreamingException('Google OAuth 未回傳 access_token');
            }
            _accessToken = access;
            final refresh = res.json['refresh_token']?.toString().trim();
            if (refresh != null && refresh.isNotEmpty) {
              _refreshToken = refresh;
            }
            final expSec = (res.json['expires_in'] as num?)?.toInt() ?? 3600;
            _expiresAt = clock().add(Duration(seconds: expSec));
            break;
          }

          final errCode = res.json['error']?.toString() ?? '';
          if (errCode == 'authorization_pending') {
            continue;
          }
          if (errCode == 'slow_down') {
            pollDelay += intervalSec <= 0
                ? const Duration(milliseconds: 25)
                : const Duration(seconds: 5);
            continue;
          }

          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              res.json,
              res.rawBody,
              res.statusCode,
            ),
            statusCode: res.statusCode,
            isTokenExpired: errCode == 'expired_token' || res.statusCode == 401,
          );
        }

        onProgress?.call('正在驗證 YouTube Music 帳號資訊...');
        final account = await _verifyAccountLive(cancel: cancel);
        setConnected(account);
        _residentResolver.invalidateSession();
        clearStreamCache();
        await _persistCredentials(account);
        return;
      }

      throw StreamingException('不支援的 YouTube Music 驗證模式：$mode');
    } catch (e) {
      throw failWithError(e);
    }
  }

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) {
    final existing = _inFlightRefresh;
    if (existing != null) return existing;

    if (_authMode != 'oauth_device') {
      if (force) {
        return Future<void>.error(
          const StreamingException(
            'YouTube Music Cookie 登入不支援靜默續期，請重新登入',
            statusCode: 401,
            isTokenExpired: true,
          ),
        );
      }
      return Future<void>.value();
    }

    if (!force) {
      final exp = _expiresAt;
      if (exp == null) return Future<void>.value();
      if (clock().isBefore(exp.subtract(const Duration(seconds: 60)))) {
        return Future<void>.value();
      }
    }

    final future = _doRefreshOAuthSession();
    _inFlightRefresh = future;
    return future.whenComplete(() {
      if (identical(_inFlightRefresh, future)) {
        _inFlightRefresh = null;
      }
    });
  }

  Future<void> _doRefreshOAuthSession() async {
    final refresh = _refreshToken;
    final clientId = _clientId;
    if (refresh == null ||
        refresh.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      throw failWithError(
        const StreamingException(
          'YouTube Music OAuth 權杖已過期且無法自動續期',
          statusCode: 401,
          isTokenExpired: true,
        ),
      );
    }

    try {
      final tokenUri = BaseStreamingProvider.buildUri(oauthBaseUrl, '/token');
      final res = await http.requestJson(
        method: 'POST',
        uri: tokenUri,
        formBody: BaseStreamingProvider.encodeForm(<String, String>{
          'client_id': clientId,
          if (_clientSecret != null && _clientSecret!.isNotEmpty)
            'client_secret': _clientSecret!,
          'refresh_token': refresh,
          'grant_type': 'refresh_token',
        }),
      );

      final nextAccess = res['access_token']?.toString().trim() ?? '';
      if (nextAccess.isEmpty) {
        throw const StreamingException(
          'Google OAuth 權杖更新失敗：未回傳新的 access_token',
          statusCode: 401,
          isTokenExpired: true,
        );
      }
      _accessToken = nextAccess;
      _residentResolver.invalidateSession();
      final nextRefresh = res['refresh_token']?.toString().trim();
      if (nextRefresh != null && nextRefresh.isNotEmpty) {
        _refreshToken = nextRefresh;
      }
      final expSec = (res['expires_in'] as num?)?.toInt() ?? 3600;
      _expiresAt = clock().add(Duration(seconds: expSec));

      if (accountInfo != null) {
        final updated = accountInfo!.copyWith(expiresAt: _expiresAt);
        setConnected(updated);
        await _persistCredentials(updated);
      }
    } catch (e) {
      throw failWithError(
        e is StreamingException
            ? e
            : StreamingException(
                'YouTube Music OAuth 權杖更新失敗：$e',
                statusCode: 401,
                isTokenExpired: true,
              ),
      );
    }
  }

  @override
  Future<void> logout() async {
    _cookie = null;
    _accessToken = null;
    _refreshToken = null;
    _clientId = null;
    _clientSecret = null;
    _expiresAt = null;
    _visitorData = null;
    _nextHomeContinuation = null;
    _nextExploreContinuation = null;
    _recentSeedVideoIds.clear();
    clearStreamCache();
    _residentResolver.invalidateSession();
    await clearCredentials();
    resetState();
  }

  Future<StreamingAccountInfo> _verifyAccountLive({
    CancellationToken? cancel,
  }) async {
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/account/account_menu',
      const <String, String>{'prettyPrint': 'false'},
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildWebRemixHeaders(authenticated: true),
      jsonBody: <String, dynamic>{'context': _buildWebRemixContext()},
      cancel: cancel,
    );
    _captureVisitorData(json);

    final header = _findFirstMapByKey(json, 'activeAccountHeaderRenderer');
    if (header == null) {
      throw const StreamingException(
        'YouTube Music 未回傳登入帳號資訊，Cookie 或授權權杖可能已失效',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final displayName = _extractInnerTubeText(header['accountName']);
    if (displayName == null || displayName.trim().isEmpty) {
      throw const StreamingException(
        'YouTube Music 回傳帳號名稱為空，拒絕假性登入狀態',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final email = _extractInnerTubeText(header['email']) ??
        _extractInnerTubeText(header['channelHandle']);

    return StreamingAccountInfo(
      displayName: displayName.trim(),
      email: email?.trim(),
      planTier: _detectPlanTier(json),
      expiresAt: _expiresAt,
    );
  }

  String? _detectPlanTier(Map<String, dynamic> accountMenuJson) {
    final raw = jsonEncode(accountMenuJson).toLowerCase();
    if (raw.contains('youtube music premium') || raw.contains('premium')) {
      return 'YouTube Music Premium';
    }
    return null;
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      'mode': _authMode,
      if (_cookie != null) 'cookie': _cookie,
      if (_clientId != null) 'client_id': _clientId,
      if (_clientSecret != null && _clientSecret!.isNotEmpty)
        'client_secret': _clientSecret,
      if (_accessToken != null) 'access_token': _accessToken,
      if (_refreshToken != null) 'refresh_token': _refreshToken,
      if (_expiresAt != null) 'expires_at': _expiresAt!.toUtc().toIso8601String(),
      'account': account.toJson(),
    });
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final tracksJson = await _browse('FEmusic_liked_videos', cancel: cancel);
    final playlistsJson =
        await _browse('FEmusic_liked_playlists', cancel: cancel);
    final albumsJson = await _browse('FEmusic_liked_albums', cancel: cancel);

    final tracks = _parseTracksFromJson(tracksJson);
    final playlists = _parsePlaylistsFromJson(playlistsJson);
    final albums = _parseAlbumsFromJson(albumsJson);

    final nextCatalog = StreamingCatalog(
      tracks: tracks,
      playlists: playlists,
      albums: albums,
      syncedAt: clock(),
    );
    setCatalog(nextCatalog);
    return nextCatalog;
  }

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async {
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }

    final albums = <StreamingAlbum>[];
    final tracks = <TrackInfo>[];
    final seenAlbumIds = <String>{};
    final seenTrackIds = <String>{};

    void mergePayload(Map<String, dynamic> payload) {
      for (final a in _parseAlbumsFromJson(payload)) {
        if (seenAlbumIds.add(a.id)) {
          albums.add(a);
        }
      }
      for (final t in _parseTracksFromJson(payload)) {
        if (seenTrackIds.add(t.id)) {
          tracks.add(t);
        }
      }
    }

    if (!forceRefresh && batchIndex == 0) {
      final homeJson = await _browse(
        'FEmusic_home',
        forceRefresh: false,
        cancel: cancel,
      );
      _nextHomeContinuation = _extractContinuationToken(homeJson);
      mergePayload(homeJson);

      if (albums.isEmpty && tracks.isEmpty) {
        final exploreJson = await _browse(
          'FEmusic_explore',
          forceRefresh: false,
          cancel: cancel,
        );
        _nextExploreContinuation = _extractContinuationToken(exploreJson);
        mergePayload(exploreJson);
      }
    } else {
      final useExplorePrimary = batchIndex % 2 == 1;
      if (useExplorePrimary) {
        final exploreCont = _nextExploreContinuation;
        try {
          final exploreJson = await _browse(
            'FEmusic_explore',
            continuation: exploreCont,
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          _nextExploreContinuation = _extractContinuationToken(exploreJson);
          mergePayload(exploreJson);
        } on StreamingException catch (e) {
          if (e.isTokenExpired ||
              e.isCancelled ||
              e.statusCode == 401 ||
              e.statusCode == 403 ||
              e.statusCode == null) {
            rethrow;
          }
        }
      }

      if (albums.isEmpty ||
          tracks.isEmpty ||
          albums.every((a) => excludeAlbumIds.contains(a.id))) {
        final homeCont = _nextHomeContinuation;
        try {
          final homeJson = await _browse(
            'FEmusic_home',
            continuation: homeCont,
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          _nextHomeContinuation = _extractContinuationToken(homeJson);
          mergePayload(homeJson);
        } on StreamingException catch (e) {
          if (homeCont == null ||
              e.isTokenExpired ||
              e.isCancelled ||
              e.statusCode == 401 ||
              e.statusCode == 403 ||
              e.statusCode == null) {
            rethrow;
          }
          // Continuation expired; retry root home page cleanly.
          _nextHomeContinuation = null;
          final homeJson = await _browse(
            'FEmusic_home',
            forceRefresh: forceRefresh,
            cancel: cancel,
          );
          _nextHomeContinuation = _extractContinuationToken(homeJson);
          mergePayload(homeJson);
        }
      }

      if (albums.isEmpty && tracks.isEmpty) {
        final homeJson = await _browse(
          'FEmusic_home',
          forceRefresh: forceRefresh,
          cancel: cancel,
        );
        _nextHomeContinuation = _extractContinuationToken(homeJson);
        mergePayload(homeJson);
      }

      if (tracks.isEmpty ||
          tracks.every((t) => excludeTrackIds.contains(t.id))) {
        final directSeeds = [...tracks, ...catalog.tracks]
            .map(_extractSeedVideoId)
            .where((id) => id.isNotEmpty)
            .toList(growable: false);
        final pool = directSeeds.isNotEmpty ? directSeeds : _recentSeedVideoIds;
        final seedVideoId = pool.isNotEmpty
            ? pool[batchIndex % pool.length]
            : '';
        if (seedVideoId.isNotEmpty) {
          try {
            final nextJson = await _fetchWatchNextRadio(
              seedVideoId,
              forceRefresh: forceRefresh,
              cancel: cancel,
            );
            mergePayload(nextJson);
            for (final t in _parsePlaylistPanelTracks(nextJson)) {
              if (seenTrackIds.add(t.id)) {
                tracks.add(t);
              }
            }
          } on StreamingException catch (e) {
            if (e.isTokenExpired ||
                e.isCancelled ||
                e.statusCode == 401 ||
                e.statusCode == 403 ||
                e.statusCode == null) {
              rethrow;
            }
          }
        }
      }
    }

    for (final t in tracks) {
      final vid = _extractSeedVideoId(t);
      if (vid.isNotEmpty && !_recentSeedVideoIds.contains(vid)) {
        _recentSeedVideoIds.add(vid);
        if (_recentSeedVideoIds.length > 20) {
          _recentSeedVideoIds.removeAt(0);
        }
      }
    }

    return StreamingRecommendations(
      providerKind: kind,
      albums: BaseStreamingProvider.selectFreshBatch<StreamingAlbum>(
        albums,
        idOf: (a) => a.id,
        excludeIds: excludeAlbumIds,
        batchIndex: batchIndex,
        maxCount: 16,
      ),
      tracks: BaseStreamingProvider.selectFreshBatch<TrackInfo>(
        tracks,
        idOf: (t) => t.id,
        excludeIds: excludeTrackIds,
        batchIndex: batchIndex,
        maxCount: 16,
      ),
      fetchedAt: clock(),
    );
  }

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async {
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }

    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      albumId,
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, 'ytm');
    if (cleanId.isEmpty) return null;

    final json = await _browse(cleanId, cancel: cancel);
    final header = _findFirstMapByKey(json, 'musicResponsiveHeaderRenderer') ??
        _findFirstMapByKey(json, 'musicDetailHeaderRenderer') ??
        (json['header'] is Map
            ? Map<String, dynamic>.from(json['header'] as Map)
            : <String, dynamic>{});

    final title = _extractInnerTubeText(header['title']) ??
        _extractInnerTubeText(json['title']) ??
        'YouTube Music Album';
    final artist = _extractInnerTubeText(header['straplineTextOne']) ??
        _extractInnerTubeText(header['subtitle']) ??
        _extractInnerTubeText(json['artist']) ??
        '未知藝術家';
    final bio = _extractInnerTubeText(header['description']) ??
        _extractInnerTubeText(json['description']);
    final coverUrl = _extractThumbnailUrl(header['thumbnail']) ??
        _extractThumbnailUrl(json['thumbnail']) ??
        BaseStreamingProvider.upgradeCoverUrl(
          json['cover_url']?.toString(),
          targetSize: 1200,
        );

    int? releaseYear = (json['year'] as num?)?.toInt();
    final subText = _extractInnerTubeText(header['subtitle']) ?? '';
    if (releaseYear == null && subText.isNotEmpty) {
      final match = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(subText);
      if (match != null) {
        releaseYear = int.tryParse(match.group(1)!);
      }
    }

    final parsedTracks = _parseTracksFromJson(
      json,
      fallbackCoverUrl: coverUrl,
    );
    final versionTracks = <AlbumVersionTrackInfo>[];
    for (var i = 0; i < parsedTracks.length; i++) {
      final t = parsedTracks[i];
      versionTracks.add(
        AlbumVersionTrackInfo(
          id: t.id,
          title: t.title,
          discNumber: t.discNumber ?? 1,
          trackNumber: t.trackNumber ?? (i + 1),
          durationMs: t.duration.inMilliseconds,
          codec: t.format.codec.name,
          sampleRateHz: t.format.sampleRateHz,
          bitDepth: t.format.bitDepth,
          externalTrackId: t.id,
        ),
      );
    }

    return CanonicalAlbumDetail(
      id: 'streaming:$kind:$cleanId',
      title: title,
      artistName: artist.split(RegExp(r'\s*[•·]\s*')).first.trim(),
      releaseYear: releaseYear,
      editorialBio: bio,
      coverUrl: coverUrl,
      versions: <AlbumVersionInfo>[
        AlbumVersionInfo(
          id: 'ver_ytm_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: 'YouTube Music',
          codec: 'opus',
          sampleRateHz: 48000,
          bitDepth: 16,
          tracks: versionTracks,
        ),
      ],
    );
  }

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async {
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }

    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'ytm');
    final json = await _browse(cleanId);
    return _parseTracksFromJson(json);
  }

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
    }
    cancel?.throwIfCancelled();

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return StreamingCatalog(syncedAt: clock());
    }

    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/search',
      const <String, String>{'prettyPrint': 'false'},
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildWebRemixHeaders(
        authenticated: authState == StreamingAuthState.connected,
      ),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'query': trimmed,
      },
      cancel: cancel,
    );
    _captureVisitorData(json);
    cancel?.throwIfCancelled();

    final tracks = _parseTracksFromJson(json);
    final albums = _parseAlbumsFromJson(json);
    final playlists = _parsePlaylistsFromJson(json);

    return StreamingCatalog(
      tracks: tracks,
      playlists: playlists,
      albums: albums,
      syncedAt: clock(),
    );
  }

  /// Clears cached stream URLs for [videoIdOrTrackId] (raw 11-char ID or
  /// prefixed track ID), or clears all cached YTM stream URLs when omitted.
  void clearStreamCache([String? videoIdOrTrackId]) {
    if (videoIdOrTrackId == null) {
      _ytDlpService.clearCache();
      return;
    }
    final raw = videoIdOrTrackId.trim();
    if (raw.isEmpty) return;
    _ytDlpService.clearCache(raw);
    final clean = tryExtractCleanVideoId(raw);
    if (clean != null && clean != raw) {
      _ytDlpService.clearCache(clean);
    }
  }

  /// Triggers low-priority background preloading for [track] via [YtDlpService]
  /// without interrupting foreground playback.
  Future<void> preloadTrack(TrackInfo track) async {
    String videoId;
    try {
      videoId = _extractVideoId(track);
    } catch (_) {
      return;
    }
    await _ytDlpService.preloadVideo(videoId);
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
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

      final netscapeContent = buildNetscapeCookiesContent(
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
    final cleanBaseUrl = baseUrl == _ytMusicOrigin ? _ytWebOrigin : baseUrl;
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
  }

  static int _tempCookieSeq = 0;

  Future<File> _writeTempNetscapeCookiesFile(String netscapeContent) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final seq = ++_tempCookieSeq;
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'lumina_ytm_cookies_${pid}_${stamp}_$seq.txt';
    final file = File(path);
    await file.writeAsString(netscapeContent, flush: true);
    return file;
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
      diagnostics.add('$layerLabel FFmpeg proxy failed: ${_redactSecrets(e.message)}');
      return null;
    } on YtDlpException catch (e) {
      if (e.isCancelled) {
        throw const StreamingException('操作已取消', isCancelled: true);
      }
      diagnostics.add('$layerLabel FFmpeg proxy failed: ${_redactSecrets(e.message)}');
      return null;
    } catch (e) {
      diagnostics.add(
        '$layerLabel FFmpeg proxy failed: ${_redactSecrets(e.toString())}',
      );
      return null;
    }
  }

  static AudioFormat _mapYtDlpAudioFormat(YtDlpResolvedStream stream) {
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

  static String _hintExtensionForYtDlp(
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

  static int _audioFormatTier(int itag, String lowerMime) {
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

  Future<Map<String, dynamic>> _browse(
    String browseId, {
    String? continuation,
    bool forceRefresh = false,
    CancellationToken? cancel,
  }) async {
    final qp = <String, String>{
      'prettyPrint': 'false',
      if (continuation != null && continuation.isNotEmpty) ...<String, String>{
        'ctoken': continuation,
        'continuation': continuation,
      },
    };
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/browse',
      qp,
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: BaseStreamingProvider.withNoCacheHeaders(
        _buildWebRemixHeaders(
          authenticated: authState == StreamingAuthState.connected,
        ),
        forceRefresh: forceRefresh,
      ),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'browseId': browseId,
        if (continuation != null && continuation.isNotEmpty)
          'continuation': continuation,
      },
      cancel: cancel,
    );
    _captureVisitorData(json);
    return json;
  }

  Future<Map<String, dynamic>> _fetchWatchNextRadio(
    String videoId, {
    String? continuation,
    bool forceRefresh = false,
    CancellationToken? cancel,
  }) async {
    final trimmedCont = continuation?.trim();
    final hasCont = trimmedCont != null && trimmedCont.isNotEmpty;
    final qp = <String, String>{
      'prettyPrint': 'false',
      if (hasCont) ...<String, String>{
        'ctoken': trimmedCont,
        'continuation': trimmedCont,
      },
    };
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/next',
      qp,
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: BaseStreamingProvider.withNoCacheHeaders(
        _buildWebRemixHeaders(
          authenticated: authState == StreamingAuthState.connected,
        ),
        forceRefresh: forceRefresh,
      ),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
        'isAudioOnly': true,
        if (hasCont) 'continuation': trimmedCont,
      },
      cancel: cancel,
    );
    _captureVisitorData(json);
    return json;
  }

  static String? _extractContinuationToken(Map<String, dynamic> root) {
    final nextData = _findFirstMapByKey(root, 'nextContinuationData') ??
        _findFirstMapByKey(root, 'nextRadioContinuationData');
    final tok1 = nextData?['continuation']?.toString().trim();
    if (tok1 != null && tok1.isNotEmpty) return tok1;
    final cmd = _findFirstMapByKey(root, 'continuationCommand');
    final tok2 = cmd?['token']?.toString().trim();
    if (tok2 != null && tok2.isNotEmpty) return tok2;
    return null;
  }

  static final RegExp _ytmYearSegmentRegex = RegExp(r'^\d{4}$');
  static final RegExp _ytmViewPlayCountRegex = RegExp(
    r'^(?:(?:no|\d[\d,.]*(?:\s*[KMBkmb萬億万억])?)\s*(?:views?|plays?|watching|listens?|次觀看|次播放|次观看|次收聽|回視聴|回再生)|(?:觀看次數|播放次數|观看次数|播放次数)\s*[:：]?\s*[\d,.]+\s*[KMBkmb萬億万억]?\s*(?:次)?)$',
    caseSensitive: false,
  );
  static final RegExp _ytmRelativeTimeRegex = RegExp(
    r'^(?:\d+\s+(?:second|minute|hour|day|week|month|year)s?\s+ago|\d+\s*(?:秒|分鐘|小時|天|週|個月|年)前)$',
    caseSensitive: false,
  );

  ({String artist, String album}) _parsePlaylistPanelByline(
    Map<String, dynamic> item,
  ) {
    final longObj = item['longBylineText'];
    final shortObj = item['shortBylineText'];
    final longRaw = _extractInnerTubeText(longObj)?.trim() ?? '';
    final primaryObj = longRaw.isNotEmpty ? longObj : shortObj;

    final segments = <({String text, bool isArtist, bool isAlbum})>[];
    if (primaryObj is Map && primaryObj['runs'] is List) {
      final buf = StringBuffer();
      var isArtist = false;
      var isAlbum = false;

      void flushSegment() {
        final text = buf.toString().trim();
        buf.clear();
        if (text.isNotEmpty) {
          segments.add((text: text, isArtist: isArtist, isAlbum: isAlbum));
        }
        isArtist = false;
        isAlbum = false;
      }

      for (final rawRun in primaryObj['runs'] as List) {
        if (rawRun is! Map) continue;
        final run = Map<String, dynamic>.from(rawRun);
        final rawText = run['text']?.toString() ?? '';
        if (rawText.isEmpty) continue;
        final pageType = _extractPageType(run);
        final browseId = _extractBrowseId(run['navigationEndpoint'])?.trim();
        final runIsArtist =
            pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
            pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL';
        final runIsAlbum =
            pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
            (browseId != null && browseId.startsWith('MPREb_'));

        if (rawText.contains('•') || rawText.contains('·')) {
          final parts = rawText.split(RegExp(r'[•·]'));
          for (var i = 0; i < parts.length; i++) {
            final part = parts[i];
            if (part.trim().isNotEmpty) {
              buf.write(part);
              if (parts.length == 1) {
                isArtist = isArtist || runIsArtist;
                isAlbum = isAlbum || runIsAlbum;
              }
            }
            if (i < parts.length - 1) {
              flushSegment();
            }
          }
        } else {
          buf.write(rawText);
          isArtist = isArtist || runIsArtist;
          isAlbum = isAlbum || runIsAlbum;
        }
      }
      flushSegment();
    } else {
      final rawText = _extractInnerTubeText(primaryObj)?.trim() ?? '';
      if (rawText.isNotEmpty) {
        for (final part in rawText.split(RegExp(r'\s*[•·]\s*'))) {
          final trimmed = part.trim();
          if (trimmed.isNotEmpty) {
            segments.add((text: trimmed, isArtist: false, isAlbum: false));
          }
        }
      }
    }

    if (segments.isEmpty) {
      return (artist: '未知藝術家', album: 'YouTube Music Radio');
    }

    var artistIndex = segments.indexWhere((s) => s.isArtist);
    if (artistIndex < 0) {
      artistIndex = 0;
    }
    final artist = segments[artistIndex].text;

    String? album;
    final taggedAlbumIndex = segments.indexWhere(
      (s) => s.isAlbum && !s.isArtist,
    );
    if (taggedAlbumIndex >= 0 && taggedAlbumIndex != artistIndex) {
      album = segments[taggedAlbumIndex].text;
    } else {
      bool isMetadataNoise(String text) {
        if (text.toLowerCase() == artist.toLowerCase()) return true;
        if (_looksLikeDuration(text)) return true;
        if (_ytmYearSegmentRegex.hasMatch(text)) return true;
        if (_ytmViewPlayCountRegex.hasMatch(text)) return true;
        if (_ytmRelativeTimeRegex.hasMatch(text)) return true;
        return false;
      }

      for (var i = artistIndex + 1; i < segments.length; i++) {
        final seg = segments[i];
        if (seg.isArtist) continue;
        if (!isMetadataNoise(seg.text)) {
          album = seg.text;
          break;
        }
      }
    }

    return (
      artist: artist.isNotEmpty ? artist : '未知藝術家',
      album: (album != null && album.isNotEmpty)
          ? album
          : 'YouTube Music Radio',
    );
  }

  List<TrackInfo> _parsePlaylistPanelTracks(
    Map<String, dynamic> root, {
    String? fallbackCoverUrl,
  }) {
    final resolvedFallback =
        BaseStreamingProvider.upgradeCoverUrl(
          fallbackCoverUrl,
          targetSize: 1200,
        ) ??
        _extractRootFallbackThumbnail(root);
    final items = _collectMapsByKey(root, 'playlistPanelVideoRenderer');
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};
    for (final item in items) {
      final videoId = item['videoId']?.toString().trim() ?? '';
      if (videoId.isEmpty) continue;
      final trackId = 'ytm:$videoId';
      if (!seenIds.add(trackId)) continue;
      final rawTitle = _extractInnerTubeText(item['title'])?.trim();
      final title = (rawTitle != null && rawTitle.isNotEmpty)
          ? rawTitle
          : '未命名曲目';
      final byline = _parsePlaylistPanelByline(item);
      final lengthText = _extractInnerTubeText(item['lengthText']) ?? '';
      final duration = _looksLikeDuration(lengthText)
          ? _parseDuration(lengthText)
          : Duration.zero;
      final coverUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallback ??
          upgradeStreamingCoverUrl(
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
            targetSize: 1200,
          );
      tracks.add(
        TrackInfo(
          id: trackId,
          title: title,
          artist: byline.artist,
          album: byline.album,
          duration: duration,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }
    return tracks;
  }

  String _extractVideoId(TrackInfo track) =>
      extractCleanVideoId(track.id, filePath: track.filePath);

  String _extractSeedVideoId(TrackInfo track) {
    final candidate = _extractCandidateVideoId(track.id) ??
        (track.filePath != null
            ? _extractCandidateVideoId(track.filePath!)
            : null);
    if (candidate == null || candidate.isEmpty) return '';
    if (_classifyNonVideoId(candidate) != null) return '';
    return candidate;
  }

  List<TrackInfo> _parseTracksFromJson(
    Map<String, dynamic> root, {
    String? fallbackCoverUrl,
  }) {
    final resolvedFallback =
        BaseStreamingProvider.upgradeCoverUrl(
          fallbackCoverUrl,
          targetSize: 1200,
        ) ??
        _extractRootFallbackThumbnail(root);
    final items = _collectMapsByKey(root, 'musicResponsiveListItemRenderer');
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};

    for (final item in items) {
      final videoId = _extractVideoIdFromRenderer(item);
      if (videoId == null || videoId.isEmpty) continue;
      final trackId = 'ytm:$videoId';
      if (!seenIds.add(trackId)) continue;

      final flexCols = item['flexColumns'];
      final title = _extractFlexColumnText(flexCols, 0) ?? '未命名曲目';
      final subRuns = _extractFlexColumnRuns(flexCols, 1);

      var artist = '未知藝術家';
      var album = 'YouTube Music';
      Duration duration = Duration.zero;

      final textParts = <String>[];
      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final pageType = _extractPageType(run);
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          artist = text;
        } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album = text;
        } else if (_looksLikeDuration(text)) {
          duration = _parseDuration(text);
        } else {
          textParts.add(text);
        }
      }

      if (artist == '未知藝術家' && textParts.isNotEmpty) {
        artist = textParts.first;
      }
      if (album == 'YouTube Music' && textParts.length >= 2) {
        album = textParts[1];
      }

      final fixedCols = item['fixedColumns'];
      final fixedDurText = _extractFixedColumnText(fixedCols, 0);
      if (duration == Duration.zero &&
          fixedDurText != null &&
          _looksLikeDuration(fixedDurText)) {
        duration = _parseDuration(fixedDurText);
      }

      final coverUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallback;

      tracks.add(
        TrackInfo(
          id: trackId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }

    return tracks;
  }

  List<StreamingPlaylist> _parsePlaylistsFromJson(Map<String, dynamic> root) {
    final playlists = <StreamingPlaylist>[];
    final seen = <String>{};

    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != null && pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') continue;
      if (!browseId.startsWith('VL') &&
          !browseId.startsWith('PL') &&
          !browseId.startsWith('RD') &&
          pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名歌單';
      final subtitle = _extractInnerTubeText(item['subtitle']);
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']);
      playlists.add(
        StreamingPlaylist(
          id: browseId,
          title: title,
          description: subtitle,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_PLAYLIST' && !browseId.startsWith('VL')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title =
          _extractFlexColumnText(item['flexColumns'], 0) ?? '未命名歌單';
      final coverUrl = _extractThumbnailUrl(item['thumbnail']);
      playlists.add(
        StreamingPlaylist(
          id: browseId,
          title: title,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    return playlists;
  }

  List<StreamingAlbum> _parseAlbumsFromJson(Map<String, dynamic> root) {
    final albums = <StreamingAlbum>[];
    final seen = <String>{};

    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && !browseId.startsWith('MPRE')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名專輯';
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .where((s) => s.isNotEmpty)
          .toList();
      final artist = parts.isNotEmpty ? parts.first : '未知藝術家';
      int? year;
      for (final p in parts) {
        final parsed = int.tryParse(p);
        if (parsed != null && parsed >= 1900 && parsed <= 2100) {
          year = parsed;
        }
      }
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']);
      albums.add(
        StreamingAlbum(
          id: browseId,
          title: title,
          artist: artist,
          year: year,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && !browseId.startsWith('MPRE')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title =
          _extractFlexColumnText(item['flexColumns'], 0) ?? '未命名專輯';
      final subRuns = _extractFlexColumnRuns(item['flexColumns'], 1);
      var artist = '未知藝術家';
      int? year;
      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·') continue;
        final rt = _extractPageType(run);
        if (rt == 'MUSIC_PAGE_TYPE_ARTIST') {
          artist = text;
        } else {
          final y = int.tryParse(text);
          if (y != null && y >= 1900 && y <= 2100) {
            year = y;
          } else if (artist == '未知藝術家' && text.toLowerCase() != 'album') {
            artist = text;
          }
        }
      }
      albums.add(
        StreamingAlbum(
          id: browseId,
          title: title,
          artist: artist,
          year: year,
          coverUrl: _extractThumbnailUrl(item['thumbnail']),
          providerKind: kind,
        ),
      );
    }

    return albums;
  }

  static Map<String, dynamic>? _findFirstMapByKey(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key) && node[key] is Map) {
        return Map<String, dynamic>.from(node[key] as Map);
      }
      for (final value in node.values) {
        final found = _findFirstMapByKey(value, key);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _findFirstMapByKey(item, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _collectMapsByKey(
    dynamic node,
    String key,
  ) {
    final results = <Map<String, dynamic>>[];
    void walk(dynamic current) {
      if (current is Map) {
        if (current.containsKey(key) && current[key] is Map) {
          results.add(Map<String, dynamic>.from(current[key] as Map));
        }
        for (final val in current.values) {
          walk(val);
        }
      } else if (current is List) {
        for (final item in current) {
          walk(item);
        }
      }
    }

    walk(node);
    return results;
  }

  static String? _extractInnerTubeText(dynamic obj) {
    if (obj == null) return null;
    if (obj is String) return obj;
    if (obj is Map) {
      final simple = obj['simpleText']?.toString();
      if (simple != null && simple.isNotEmpty) return simple;
      final runs = obj['runs'];
      if (runs is List) {
        final buf = StringBuffer();
        for (final r in runs) {
          if (r is Map && r['text'] != null) {
            buf.write(r['text'].toString());
          }
        }
        final text = buf.toString();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  static String? _extractVideoIdFromRenderer(Map<String, dynamic> item) {
    final playlistData = item['playlistItemData'];
    if (playlistData is Map && playlistData['videoId'] != null) {
      return playlistData['videoId'].toString();
    }
    final watch = _findFirstMapByKey(item, 'watchEndpoint');
    if (watch != null && watch['videoId'] != null) {
      return watch['videoId'].toString();
    }
    return null;
  }

  static String? _extractBrowseId(dynamic navEndpoint) {
    if (navEndpoint is! Map) return null;
    final browse = navEndpoint['browseEndpoint'];
    if (browse is Map) {
      return browse['browseId']?.toString();
    }
    return null;
  }

  static String? _extractPageType(dynamic node) {
    final cfg = _findFirstMapByKey(
      node,
      'browseEndpointContextMusicConfig',
    );
    return cfg?['pageType']?.toString();
  }

  static String? _extractFlexColumnText(dynamic flexCols, int index) {
    if (flexCols is! List || index >= flexCols.length) return null;
    final col = flexCols[index];
    if (col is! Map) return null;
    final renderer = col['musicResponsiveListItemFlexColumnRenderer'];
    if (renderer is! Map) return null;
    return _extractInnerTubeText(renderer['text']);
  }

  static List<Map<String, dynamic>> _extractFlexColumnRuns(
    dynamic flexCols,
    int index,
  ) {
    if (flexCols is! List || index >= flexCols.length) return const [];
    final col = flexCols[index];
    if (col is! Map) return const [];
    final renderer = col['musicResponsiveListItemFlexColumnRenderer'];
    if (renderer is! Map) return const [];
    final text = renderer['text'];
    if (text is! Map) return const [];
    final runs = text['runs'];
    if (runs is! List) return const [];
    return runs
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static String? _extractFixedColumnText(dynamic fixedCols, int index) {
    if (fixedCols is! List || index >= fixedCols.length) return null;
    final col = fixedCols[index];
    if (col is! Map) return null;
    final renderer = col['musicResponsiveListItemFixedColumnRenderer'];
    if (renderer is! Map) return null;
    return _extractInnerTubeText(renderer['text']);
  }

  static String? _extractRootFallbackThumbnail(Map<String, dynamic> root) {
    final header = root['header'];
    if (header is Map) {
      final direct = _extractThumbnailUrl(header['thumbnail']);
      if (direct != null) return direct;
      final respHeader =
          _findFirstMapByKey(header, 'musicResponsiveHeaderRenderer') ??
              _findFirstMapByKey(header, 'musicDetailHeaderRenderer');
      final nested = _extractThumbnailUrl(respHeader?['thumbnail']);
      if (nested != null) return nested;
    }
    return _extractThumbnailUrl(root['thumbnail']);
  }

  static String? _extractThumbnailUrl(dynamic node) {
    if (node == null) return null;
    dynamic list;
    if (node is List) {
      list = node;
    } else {
      final thumb = _findFirstMapByKey(node, 'musicThumbnailRenderer') ??
          _findFirstMapByKey(node, 'croppedSquareThumbnailRenderer') ??
          (node is Map && node['thumbnails'] is List
              ? Map<String, dynamic>.from(node)
              : (node is Map && node['thumbnail'] is Map
                    ? Map<String, dynamic>.from(node['thumbnail'] as Map)
                    : null));
      if (thumb == null) return null;
      list = thumb['thumbnails'] ??
          (thumb['thumbnail'] is Map ? thumb['thumbnail']['thumbnails'] : null);
    }
    if (list is! List || list.isEmpty) return null;

    String? bestByAreaUrl;
    var bestArea = -1;
    String? lastValidUrl;
    for (final entry in list) {
      if (entry is! Map) continue;
      final normalized = BaseStreamingProvider.normalizeCoverUrl(
        entry['url']?.toString(),
      );
      if (normalized == null) continue;
      lastValidUrl = normalized;
      final w = (entry['width'] as num?)?.toInt() ?? 0;
      final h = (entry['height'] as num?)?.toInt() ?? 0;
      final area = (w > 0 && h > 0) ? (w * h) : 0;
      if (area > 0 && area >= bestArea) {
        bestArea = area;
        bestByAreaUrl = normalized;
      }
    }
    final chosen = bestByAreaUrl ?? lastValidUrl;
    return upgradeStreamingCoverUrl(chosen, targetSize: 1200);
  }

  static bool _looksLikeDuration(String text) =>
      RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim());

  static Duration _parseDuration(String raw) {
    final parts = raw.trim().split(':').map(int.tryParse).toList();
    if (parts.any((e) => e == null)) return Duration.zero;
    if (parts.length == 2) {
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    }
    if (parts.length == 3) {
      return Duration(
        hours: parts[0]!,
        minutes: parts[1]!,
        seconds: parts[2]!,
      );
    }
    return Duration.zero;
  }

  // ─── Stage 4: YouTube Music Podcast InnerTube API & Parsers ────────────────

  /// Live-probed YouTube Music InnerTube `search` filter params for Podcast
  /// shows (`Podcast` chip) and episodes (`單集節目` chip).
  static const String podcastShowsSearchParams =
      'EgWKAQJQAWoSEBEQEBAFEAMQBBAKEAkQFRAO';
  static const String podcastEpisodesSearchParams =
      'EgWKAQJIAWoSEBEQEBAFEAMQBBAKEAkQFRAO';

  /// Fetches the user's personal subscribed Podcast shows and new episodes.
  ///
  /// When authenticated, queries `FEmusic_library_non_music_audio_list` (and
  /// `VLSE` / embedded shelves for latest episodes). When unauthenticated,
  /// returns an empty [PodcastLibraryResult] so the UI can merge local
  /// bookmarks and show a compact login card.
  Future<PodcastLibraryResult> fetchMyPodcasts({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState != StreamingAuthState.connected) {
      return const PodcastLibraryResult();
    }
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final shows = <PodcastShow>[];
    final episodes = <PodcastEpisode>[];
    final seenShowIds = <String>{};
    final seenVideoIds = <String>{};
    String? continuationToken;

    final libJson = await _browse(
      'FEmusic_library_non_music_audio_list',
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    for (final s in _parsePodcastShowsFromJson(
      libJson,
      allowAllShowItems: true,
    )) {
      if (seenShowIds.add(s.id)) {
        shows.add(s);
      }
    }
    for (final ep in _parsePodcastEpisodesFromJson(
      libJson,
      allowAllResponsiveItems: false,
    )) {
      if (seenVideoIds.add(ep.videoId)) {
        episodes.add(ep);
      }
    }
    continuationToken = _extractPodcastEpisodeContinuationToken(libJson);

    if (episodes.isEmpty) {
      try {
        final newEpsJson = await _browse('VLSE', cancel: cancel);
        for (final ep in _parsePodcastEpisodesFromJson(
          newEpsJson,
          allowAllResponsiveItems: true,
        )) {
          if (seenVideoIds.add(ep.videoId)) {
            episodes.add(ep);
          }
        }
        continuationToken ??=
            _extractPodcastEpisodeContinuationToken(newEpsJson);
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
      } catch (_) {}
    }

    return PodcastLibraryResult(
      shows: shows,
      episodes: episodes,
      continuationToken: continuationToken,
    );
  }

  /// Fetches the Podcast Explore & Latest Episodes feed.
  ///
  /// Works in BOTH Guest Mode and Logged-in Mode. Calls `FEmusic_podcasts`,
  /// falling back to `FEmusic_non_music_audio` and then a filtered Podcast
  /// search fallback when the user's locale returns 404 or sparse data.
  Future<PodcastExploreResult> fetchExplorePodcasts({
    String? continuation,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();
    }

    final shows = <PodcastShow>[];
    final episodes = <PodcastEpisode>[];
    final seenShowIds = <String>{};
    final seenVideoIds = <String>{};
    String? nextContinuation;

    void mergeFromJson(
      Map<String, dynamic> payload, {
      bool allowAllShows = false,
      bool allowAllEpisodes = false,
    }) {
      for (final s in _parsePodcastShowsFromJson(
        payload,
        allowAllShowItems: allowAllShows,
      )) {
        if (seenShowIds.add(s.id)) {
          shows.add(s);
        }
      }
      for (final ep in _parsePodcastEpisodesFromJson(
        payload,
        allowAllResponsiveItems: allowAllEpisodes,
      )) {
        if (seenVideoIds.add(ep.videoId)) {
          episodes.add(ep);
        }
      }
      nextContinuation ??= _extractPodcastEpisodeContinuationToken(payload);
    }

    if (continuation != null && continuation.trim().isNotEmpty) {
      final json = await _browse(
        'FEmusic_podcasts',
        continuation: continuation.trim(),
        cancel: cancel,
      );
      mergeFromJson(json, allowAllShows: true, allowAllEpisodes: true);
      return PodcastExploreResult(
        shows: shows,
        episodes: episodes,
        continuationToken: nextContinuation,
      );
    }

    // 1. Primary browse: FEmusic_podcasts
    try {
      final podcastsJson = await _browse('FEmusic_podcasts', cancel: cancel);
      mergeFromJson(podcastsJson, allowAllShows: true, allowAllEpisodes: true);
    } on StreamingException catch (e) {
      if (e.isCancelled || e.isTokenExpired || e.statusCode == 401) {
        rethrow;
      }
    }

    // 2. Secondary browse fallback: FEmusic_non_music_audio
    if (shows.isEmpty && episodes.isEmpty) {
      cancel?.throwIfCancelled();
      try {
        final nonMusicJson = await _browse(
          'FEmusic_non_music_audio',
          cancel: cancel,
        );
        mergeFromJson(
          nonMusicJson,
          allowAllShows: true,
          allowAllEpisodes: true,
        );
      } on StreamingException catch (e) {
        if (e.isCancelled || e.isTokenExpired || e.statusCode == 401) {
          rethrow;
        }
      }
    }

    // 3. Locale fallback (e.g. TW where FEmusic_podcasts returns 404):
    //    query real YouTube Music Podcast shows & episodes via /youtubei/v1/search.
    if (shows.isEmpty && episodes.isEmpty) {
      cancel?.throwIfCancelled();
      final searchFallback = await searchPodcasts('Podcast', cancel: cancel);
      for (final s in searchFallback.shows) {
        if (seenShowIds.add(s.id)) {
          shows.add(s);
        }
      }
      for (final ep in searchFallback.episodes) {
        if (seenVideoIds.add(ep.videoId)) {
          episodes.add(ep);
        }
      }
      nextContinuation ??= searchFallback.continuationToken;
    }

    return PodcastExploreResult(
      shows: shows,
      episodes: episodes,
      continuationToken: nextContinuation,
    );
  }

  /// Searches YouTube Music specifically for Podcast shows and episodes.
  Future<PodcastSearchResult> searchPodcasts(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();
    }

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const PodcastSearchResult();
    }

    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/search',
      const <String, String>{'prettyPrint': 'false'},
    );
    final isConnected = authState == StreamingAuthState.connected;

    final shows = <PodcastShow>[];
    final episodes = <PodcastEpisode>[];
    final seenShowIds = <String>{};
    final seenVideoIds = <String>{};
    String? continuationToken;

    // 1. Search with Podcast Shows filter (also captures any episodes if a
    //    combined shelf or test fixture is returned).
    final showsJson = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildWebRemixHeaders(authenticated: isConnected),
      jsonBody: <String, dynamic>{
        'context': _buildWebRemixContext(),
        'query': trimmed,
        'params': podcastShowsSearchParams,
      },
      cancel: cancel,
    );
    _captureVisitorData(showsJson);
    cancel?.throwIfCancelled();

    for (final s in _parsePodcastShowsFromJson(
      showsJson,
      allowAllShowItems: true,
    )) {
      if (seenShowIds.add(s.id)) {
        shows.add(s);
      }
    }
    for (final ep in _parsePodcastEpisodesFromJson(
      showsJson,
      allowAllResponsiveItems: false,
    )) {
      if (seenVideoIds.add(ep.videoId)) {
        episodes.add(ep);
      }
    }
    continuationToken = _extractPodcastEpisodeContinuationToken(showsJson);

    // 2. If no episodes were included in the show-filtered response, query
    //    with the Podcast Episodes filter to populate playable episodes.
    if (episodes.isEmpty) {
      try {
        final epsJson = await http.requestJson(
          method: 'POST',
          uri: uri,
          headers: _buildWebRemixHeaders(authenticated: isConnected),
          jsonBody: <String, dynamic>{
            'context': _buildWebRemixContext(),
            'query': trimmed,
            'params': podcastEpisodesSearchParams,
          },
          cancel: cancel,
        );
        _captureVisitorData(epsJson);
        for (final ep in _parsePodcastEpisodesFromJson(
          epsJson,
          allowAllResponsiveItems: true,
        )) {
          if (seenVideoIds.add(ep.videoId)) {
            episodes.add(ep);
          }
        }
        for (final s in _parsePodcastShowsFromJson(
          epsJson,
          allowAllShowItems: false,
        )) {
          if (seenShowIds.add(s.id)) {
            shows.add(s);
          }
        }
        continuationToken ??= _extractPodcastEpisodeContinuationToken(epsJson);
      } on StreamingException catch (e) {
        if (e.isCancelled) rethrow;
      } catch (_) {}
    }

    return PodcastSearchResult(
      shows: shows,
      episodes: episodes,
      continuationToken: continuationToken,
    );
  }

  /// Fetches full show metadata, ordered episodes, and continuation token for
  /// a YouTube Music Podcast show (`browseId` such as `MPSPPL...`).
  Future<PodcastShowDetail> fetchPodcastShowDetail(
    String showBrowseId, {
    String? continuation,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState == StreamingAuthState.connected) {
      await refreshSessionIfNeeded();
      cancel?.throwIfCancelled();
    }

    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      showBrowseId.trim(),
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, 'ytm');
    if (cleanId.startsWith('PL') && !cleanId.startsWith('MPSP')) {
      cleanId = 'MPSP$cleanId';
    }
    if (cleanId.isEmpty) {
      throw const StreamingException('Podcast 節目缺少有效的 browseId');
    }

    final json = await _browse(
      cleanId,
      continuation: continuation,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    final header = _findFirstMapByKey(json, 'musicResponsiveHeaderRenderer') ??
        _findFirstMapByKey(json, 'musicDetailHeaderRenderer') ??
        (json['header'] is Map
            ? Map<String, dynamic>.from(json['header'] as Map)
            : <String, dynamic>{});

    final title = (_extractInnerTubeText(header['title']) ??
            _extractInnerTubeText(json['title']) ??
            'Podcast 節目')
        .trim();
    final author = (_extractInnerTubeText(header['straplineTextOne']) ??
            _extractInnerTubeText(header['subtitle']) ??
            _extractInnerTubeText(json['author']) ??
            '')
        .trim();
    final description = _extractPodcastDescription(header['description']) ??
        _extractPodcastDescription(json['description']);
    final artworkUrl = _extractThumbnailUrl(header['thumbnail']) ??
        _extractRootFallbackThumbnail(json);
    final secondSub = _extractInnerTubeText(header['secondSubtitle'])?.trim();

    final episodes = _parsePodcastEpisodesFromJson(
      json,
      fallbackShowId: cleanId,
      fallbackShowTitle: title,
      fallbackAuthor: author,
      fallbackArtworkUrl: artworkUrl,
      allowAllResponsiveItems: true,
    );

    final nextContinuation = _extractPodcastEpisodeContinuationToken(json);

    final show = PodcastShow(
      id: cleanId,
      title: title,
      author: author,
      artworkUrl: artworkUrl,
      description: description,
      episodeCountLabel: secondSub != null && secondSub.isNotEmpty
          ? secondSub
          : (episodes.isNotEmpty ? '${episodes.length} 集' : null),
      latestEpisodeTitle:
          episodes.isNotEmpty ? episodes.first.title : null,
    );

    return PodcastShowDetail(
      show: show,
      episodes: episodes,
      continuationToken: nextContinuation,
    );
  }

  static String? _extractPodcastDescription(dynamic node) {
    if (node == null) return null;
    final direct = _extractInnerTubeText(node)?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    if (node is Map) {
      final descShelf = node['musicDescriptionShelfRenderer'] ??
          _findFirstMapByKey(node, 'musicDescriptionShelfRenderer');
      if (descShelf is Map) {
        final nested =
            _extractInnerTubeText(descShelf['description'])?.trim();
        if (nested != null && nested.isNotEmpty) return nested;
      }
      if (node['description'] != null) {
        final inner = _extractInnerTubeText(node['description'])?.trim();
        if (inner != null && inner.isNotEmpty) return inner;
      }
    }
    return null;
  }

  static String? _extractPodcastEpisodeContinuationToken(
    Map<String, dynamic> root,
  ) {
    for (final shelfKey in const <String>[
      'musicShelfRenderer',
      'musicShelfContinuation',
      'musicPlaylistShelfRenderer',
      'sectionListRenderer',
      'sectionListContinuation',
    ]) {
      for (final shelf in _collectMapsByKey(root, shelfKey)) {
        final conts = shelf['continuations'];
        if (conts != null) {
          final nextData = _findFirstMapByKey(conts, 'nextContinuationData');
          final tok1 = nextData?['continuation']?.toString().trim();
          if (tok1 != null && tok1.isNotEmpty) return tok1;
          final cmd = _findFirstMapByKey(conts, 'continuationCommand');
          final tok2 = cmd?['token']?.toString().trim();
          if (tok2 != null && tok2.isNotEmpty) return tok2;
        }
      }
    }
    return _extractContinuationToken(root);
  }

  List<PodcastShow> _parsePodcastShowsFromJson(
    Map<String, dynamic> root, {
    bool allowAllShowItems = false,
  }) {
    final shows = <PodcastShow>[];
    final seen = <String>{};

    bool isPodcastShowIdOrPage(
      String? browseId,
      String? pageType, {
      required bool allowFallback,
    }) {
      if (browseId == null || browseId.isEmpty) return false;
      if (pageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
          browseId.startsWith('MPSP')) {
        return true;
      }
      if (!allowFallback) return false;
      if (browseId.startsWith('MPED') ||
          browseId.startsWith('MPRE') ||
          browseId.startsWith('MPTC') ||
          browseId.startsWith('UC') ||
          browseId.startsWith('FE')) {
        return false;
      }
      if (pageType != null &&
          pageType.isNotEmpty &&
          pageType != 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' &&
          pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') {
        return false;
      }
      return true;
    }

    // 1. musicTwoRowItemRenderer (grid cards on Explore / Library / Shelves)
    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      var browseId = _extractBrowseId(item['navigationEndpoint'])?.trim();
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) {
        final watchPl =
            _findFirstMapByKey(item, 'watchPlaylistEndpoint')?['playlistId']
                ?.toString()
                .trim();
        if (watchPl != null && watchPl.startsWith('PL')) {
          browseId = 'MPSP$watchPl';
        }
      }
      if (!isPodcastShowIdOrPage(
        browseId,
        pageType,
        allowFallback: allowAllShowItems,
      )) {
        continue;
      }
      final normalizedId =
          (browseId!.startsWith('PL') && !browseId.startsWith('MPSP'))
              ? 'MPSP$browseId'
              : browseId;
      if (!seen.add(normalizedId)) continue;

      final title =
          (_extractInnerTubeText(item['title']) ?? '未命名 Podcast').trim();
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      var author = '';
      String? episodeCountLabel;
      for (final p in parts) {
        final lower = p.toLowerCase();
        if (lower == 'podcast' || p == '播客' || p == '節目') continue;
        if (RegExp(r'\d+\s*(集|episodes?)', caseSensitive: false).hasMatch(p)) {
          episodeCountLabel ??= p;
        } else if (author.isEmpty) {
          author = p;
        }
      }
      final artworkUrl = _extractThumbnailUrl(item['thumbnailRenderer']) ??
          _extractThumbnailUrl(item['thumbnail']);

      shows.add(
        PodcastShow(
          id: normalizedId,
          title: title,
          author: author,
          artworkUrl: artworkUrl,
          episodeCountLabel: episodeCountLabel,
        ),
      );
    }

    // 2. musicResponsiveListItemRenderer (search / library rows)
    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final hasPlaylistVideoId = item['playlistItemData'] is Map &&
          (item['playlistItemData']['videoId']?.toString().trim().isNotEmpty ==
              true);
      final col0Runs = _extractFlexColumnRuns(item['flexColumns'], 0);
      final col0HasEpisodePage = col0Runs.any((r) {
        final pt = _extractPageType(r);
        final bid = _extractBrowseId(r['navigationEndpoint']) ?? '';
        return pt == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE' ||
            bid.startsWith('MPED');
      });
      if (hasPlaylistVideoId || col0HasEpisodePage) {
        continue;
      }

      var browseId = _extractBrowseId(item['navigationEndpoint'])?.trim();
      var pageType = _extractPageType(item['navigationEndpoint']);

      if (browseId == null || browseId.isEmpty) {
        for (final r in col0Runs) {
          final bid = _extractBrowseId(r['navigationEndpoint'])?.trim();
          if (bid != null && bid.isNotEmpty) {
            browseId = bid;
            pageType ??= _extractPageType(r);
            break;
          }
        }
      }
      if (browseId == null || browseId.isEmpty) {
        final watchPl =
            _findFirstMapByKey(item, 'watchPlaylistEndpoint')?['playlistId']
                ?.toString()
                .trim();
        if (watchPl != null && watchPl.startsWith('PL')) {
          browseId = 'MPSP$watchPl';
        }
      }

      if (!isPodcastShowIdOrPage(
        browseId,
        pageType,
        allowFallback: allowAllShowItems,
      )) {
        continue;
      }
      final normalizedId =
          (browseId!.startsWith('PL') && !browseId.startsWith('MPSP'))
              ? 'MPSP$browseId'
              : browseId;
      if (!seen.add(normalizedId)) continue;

      final title =
          (_extractFlexColumnText(item['flexColumns'], 0) ?? '未命名 Podcast')
              .trim();
      final subRuns = _extractFlexColumnRuns(item['flexColumns'], 1);
      var author = '';
      String? episodeCountLabel;
      String? latestEpisodeTitle;

      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final lower = text.toLowerCase();
        if (lower == 'podcast' || text == '播客' || text == '節目') continue;
        final rt = _extractPageType(run);
        if (rt == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
            rt == 'MUSIC_PAGE_TYPE_ARTIST') {
          author = text;
        } else if (RegExp(
          r'\d+\s*(集|episodes?)',
          caseSensitive: false,
        ).hasMatch(text)) {
          episodeCountLabel ??= text;
        } else if (author.isEmpty) {
          author = text;
        } else {
          latestEpisodeTitle ??= text;
        }
      }

      final artworkUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']);

      shows.add(
        PodcastShow(
          id: normalizedId,
          title: title,
          author: author,
          artworkUrl: artworkUrl,
          episodeCountLabel: episodeCountLabel,
          latestEpisodeTitle: latestEpisodeTitle,
        ),
      );
    }

    return shows;
  }

  List<PodcastEpisode> _parsePodcastEpisodesFromJson(
    Map<String, dynamic> root, {
    String? fallbackShowId,
    String? fallbackShowTitle,
    String? fallbackAuthor,
    String? fallbackArtworkUrl,
    bool allowAllResponsiveItems = false,
  }) {
    final resolvedFallbackArt =
        BaseStreamingProvider.upgradeCoverUrl(
          fallbackArtworkUrl,
          targetSize: 1200,
        ) ??
        _extractRootFallbackThumbnail(root);
    final episodes = <PodcastEpisode>[];
    final seenVideoIds = <String>{};

    // 1. musicMultiRowListItemRenderer (primary renderer for show episodes & new episodes)
    for (final item
        in _collectMapsByKey(root, 'musicMultiRowListItemRenderer')) {
      final rawVid = _extractPodcastVideoIdFromItem(item);
      if (rawVid == null) continue;
      final cleanVid = tryExtractCleanVideoId(rawVid);
      if (cleanVid == null || !seenVideoIds.add(cleanVid)) continue;

      final title =
          (_extractInnerTubeText(item['title']) ?? '未命名單集').trim();
      final description = _extractPodcastDescription(item['description']);

      var showId = fallbackShowId ?? '';
      var showTitle = fallbackShowTitle ?? '';
      var author = fallbackAuthor ?? '';
      String? publishedLabel;
      var duration = Duration.zero;

      for (final run in <Map<String, dynamic>>[
        ..._extractRunsFromTextObject(item['subtitle']),
        ..._extractRunsFromTextObject(item['secondTitle']),
      ]) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final runBrowseId = _extractBrowseId(run['navigationEndpoint'])?.trim();
        final runPageType = _extractPageType(run);
        if (runPageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
            (runBrowseId != null && runBrowseId.startsWith('MPSP'))) {
          if (runBrowseId != null && runBrowseId.isNotEmpty) {
            showId = runBrowseId;
          }
          showTitle = text;
        } else if (runPageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
            runPageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          author = text;
        } else if (_looksLikePodcastDuration(text)) {
          duration = _parsePodcastDuration(text);
        } else if (!text.startsWith('觀看次數') &&
            !text.toLowerCase().contains('views')) {
          publishedLabel ??= text;
        }
      }

      if (duration == Duration.zero) {
        duration = _extractDurationFromPlaybackProgress(
          item['playbackProgress'],
        );
      }

      final artworkUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallbackArt;

      episodes.add(
        PodcastEpisode(
          videoId: cleanVid,
          showId: showId,
          showTitle: showTitle,
          title: title,
          author: author.isNotEmpty ? author : showTitle,
          artworkUrl: artworkUrl,
          publishedLabel: publishedLabel,
          duration: duration,
          description: description,
        ),
      );
    }

    // 2. musicResponsiveListItemRenderer (search episodes & compact shelves)
    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      if (!_isResponsiveItemPodcastEpisode(
        item,
        allowAll: allowAllResponsiveItems,
      )) {
        continue;
      }

      final rawVid = _extractPodcastVideoIdFromItem(item);
      if (rawVid == null) continue;
      final cleanVid = tryExtractCleanVideoId(rawVid);
      if (cleanVid == null || !seenVideoIds.add(cleanVid)) continue;

      final flexCols = item['flexColumns'];
      final title =
          (_extractFlexColumnText(flexCols, 0) ?? '未命名單集').trim();
      final subRuns = _extractFlexColumnRuns(flexCols, 1);

      var showId = fallbackShowId ?? '';
      var showTitle = fallbackShowTitle ?? '';
      var author = fallbackAuthor ?? '';
      String? publishedLabel;
      var duration = Duration.zero;
      final extraTexts = <String>[];

      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final lower = text.toLowerCase();
        if (lower == 'episode' || text == '單集節目' || text == '單集') {
          continue;
        }
        final runBrowseId = _extractBrowseId(run['navigationEndpoint'])?.trim();
        final runPageType = _extractPageType(run);
        if (runPageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
            (runBrowseId != null && runBrowseId.startsWith('MPSP'))) {
          if (runBrowseId != null && runBrowseId.isNotEmpty) {
            showId = runBrowseId;
          }
          showTitle = text;
        } else if (runPageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
            runPageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          author = text;
        } else if (_looksLikePodcastDuration(text)) {
          duration = _parsePodcastDuration(text);
        } else {
          extraTexts.add(text);
        }
      }

      if (extraTexts.isNotEmpty) {
        publishedLabel ??= extraTexts.first;
        if (showTitle.isEmpty && extraTexts.length >= 2) {
          showTitle = extraTexts[1];
        }
      }

      final fixedCols = item['fixedColumns'];
      final fixedDurText = _extractFixedColumnText(fixedCols, 0);
      if (duration == Duration.zero &&
          fixedDurText != null &&
          _looksLikePodcastDuration(fixedDurText)) {
        duration = _parsePodcastDuration(fixedDurText);
      }
      if (duration == Duration.zero) {
        duration = _extractDurationFromPlaybackProgress(
          item['playbackProgress'],
        );
      }

      final description = _extractPodcastDescription(item['description']) ??
          _extractFlexColumnText(flexCols, 2);

      final artworkUrl = _extractThumbnailUrl(item['thumbnail']) ??
          _extractThumbnailUrl(item['thumbnailRenderer']) ??
          resolvedFallbackArt;

      episodes.add(
        PodcastEpisode(
          videoId: cleanVid,
          showId: showId,
          showTitle: showTitle,
          title: title,
          author: author.isNotEmpty ? author : showTitle,
          artworkUrl: artworkUrl,
          publishedLabel: publishedLabel,
          duration: duration,
          description: description,
        ),
      );
    }

    return episodes;
  }

  static bool _isResponsiveItemPodcastEpisode(
    Map<String, dynamic> item, {
    required bool allowAll,
  }) {
    final navBrowseId = _extractBrowseId(item['navigationEndpoint']) ?? '';
    final navPageType = _extractPageType(item['navigationEndpoint']);
    if (navPageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
        navBrowseId.startsWith('MPSP')) {
      return false;
    }

    if (allowAll) return true;

    final watchCfg = _findFirstMapByKey(item, 'watchEndpointMusicConfig');
    final videoType = watchCfg?['musicVideoType']?.toString() ?? '';
    if (videoType == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE' ||
        videoType == 'MUSIC_VIDEO_TYPE_NON_MUSIC_AUDIO') {
      return true;
    }

    for (final colIdx in const <int>[0, 1]) {
      for (final run in _extractFlexColumnRuns(item['flexColumns'], colIdx)) {
        final pt = _extractPageType(run);
        final bid = _extractBrowseId(run['navigationEndpoint']) ?? '';
        if (pt == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE' ||
            pt == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
            bid.startsWith('MPED') ||
            bid.startsWith('MPSP')) {
          return true;
        }
      }
    }

    return false;
  }

  static String? _extractPodcastVideoIdFromItem(Map<String, dynamic> item) {
    final direct = _extractVideoIdFromRenderer(item);
    if (direct != null && direct.trim().isNotEmpty) {
      return direct.trim();
    }
    final onTapWatch = _findFirstMapByKey(item['onTap'], 'watchEndpoint');
    final onTapVid = onTapWatch?['videoId']?.toString().trim();
    if (onTapVid != null && onTapVid.isNotEmpty) {
      return onTapVid;
    }
    for (final browse in _collectMapsByKey(item, 'browseEndpoint')) {
      final bid = browse['browseId']?.toString().trim() ?? '';
      if (bid.startsWith('MPED') && bid.length == 15) {
        return bid.substring(4);
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _extractRunsFromTextObject(dynamic obj) {
    if (obj is! Map) return const <Map<String, dynamic>>[];
    final runs = obj['runs'];
    if (runs is! List) return const <Map<String, dynamic>>[];
    return runs
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static Duration _extractDurationFromPlaybackProgress(dynamic progressNode) {
    if (progressNode is! Map) return Duration.zero;
    final renderer = progressNode['musicPlaybackProgressRenderer'] is Map
        ? Map<String, dynamic>.from(
            progressNode['musicPlaybackProgressRenderer'] as Map,
          )
        : Map<String, dynamic>.from(progressNode);
    for (final key in const <String>['durationText', 'playbackProgressText']) {
      final field = renderer[key];
      for (final run in _extractRunsFromTextObject(field)) {
        final t = run['text']?.toString().trim() ?? '';
        if (_looksLikePodcastDuration(t)) {
          final d = _parsePodcastDuration(t);
          if (d > Duration.zero) return d;
        }
      }
      final combined = _extractInnerTubeText(field)?.trim() ?? '';
      if (_looksLikePodcastDuration(combined)) {
        final d = _parsePodcastDuration(combined);
        if (d > Duration.zero) return d;
      }
    }
    return Duration.zero;
  }

  static bool _looksLikePodcastDuration(String raw) {
    final trimmed = raw.replaceAll(RegExp(r'^[•·\s]+'), '').trim();
    if (trimmed.isEmpty) return false;
    if (_looksLikeDuration(trimmed)) return true;
    if (trimmed.contains('前') ||
        trimmed.contains('月') ||
        trimmed.contains('日')) {
      return false;
    }
    return RegExp(
      r'(\d+)\s*(?:小時|分鐘|分|秒鐘|秒|(?:hr|hrs|hour|hours|min|mins|minute|minutes|sec|secs)\b)',
      caseSensitive: false,
    ).hasMatch(trimmed);
  }

  static Duration _parsePodcastDuration(String raw) {
    final trimmed = raw.replaceAll(RegExp(r'^[•·\s]+'), '').trim();
    if (trimmed.isEmpty) return Duration.zero;
    if (_looksLikeDuration(trimmed)) {
      return _parseDuration(trimmed);
    }
    final colonMatch =
        RegExp(r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b').firstMatch(trimmed);
    if (colonMatch != null) {
      final parsed = _parseDuration(colonMatch.group(1)!);
      if (parsed > Duration.zero) return parsed;
    }

    final hrMatch = RegExp(
      r'(\d+)\s*(?:小時|hr|hrs|hour|hours)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    final minMatch = RegExp(
      r'(\d+)\s*(?:分鐘|分|min|mins|minute|minutes)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    final secMatch = RegExp(
      r'(\d+)\s*(?:秒鐘|秒|sec|secs|second|seconds)',
      caseSensitive: false,
    ).firstMatch(trimmed);

    final hours =
        hrMatch != null ? (int.tryParse(hrMatch.group(1)!) ?? 0) : 0;
    final mins =
        minMatch != null ? (int.tryParse(minMatch.group(1)!) ?? 0) : 0;
    final secs =
        secMatch != null ? (int.tryParse(secMatch.group(1)!) ?? 0) : 0;

    if (hours == 0 && mins == 0 && secs == 0) return Duration.zero;
    return Duration(hours: hours, minutes: mins, seconds: secs);
  }

  // ─── RecommendationProvider ────────────────────────────────────────────────

  @override
  String get recommendationProviderId => kind;

  RecError _mapRecError(Object e) {
    if (e is RecError) return e;
    if (e is StreamingException) {
      if (e.isCancelled) {
        return RecError(
          kind: RecErrorKind.cancelled,
          message: e.message,
          statusCode: e.statusCode,
          providerId: kind,
        );
      }
      if (e.statusCode == 401 || e.isTokenExpired) {
        return RecError(
          kind: RecErrorKind.authRequired,
          message: e.message,
          statusCode: 401,
          providerId: kind,
        );
      }
      if (e.statusCode == 429) {
        return RecError(
          kind: RecErrorKind.rateLimited,
          message: e.message,
          statusCode: 429,
          providerId: kind,
        );
      }
      if (e.statusCode == 404) {
        return RecError(
          kind: RecErrorKind.notFound,
          message: e.message,
          statusCode: 404,
          providerId: kind,
        );
      }
      return RecError(
        kind: RecErrorKind.network,
        message: e.message,
        statusCode: e.statusCode,
        providerId: kind,
      );
    }
    return RecError(
      kind: RecErrorKind.unknown,
      message: e.toString(),
      providerId: kind,
    );
  }

  Future<StreamingCatalog> _searchWithGuestFallback(
    String query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return StreamingCatalog(syncedAt: clock());

    Future<StreamingCatalog> postSearch({required bool authenticated}) async {
      final uri = BaseStreamingProvider.buildUri(
        baseUrl,
        '/youtubei/v1/search',
        const <String, String>{'prettyPrint': 'false'},
      );
      final json = await http.requestJson(
        method: 'POST',
        uri: uri,
        headers: _buildWebRemixHeaders(authenticated: authenticated),
        jsonBody: <String, dynamic>{
          'context': _buildWebRemixContext(),
          'query': trimmed,
        },
        cancel: cancel,
      );
      _captureVisitorData(json);
      return StreamingCatalog(
        tracks: _parseTracksFromJson(json),
        playlists: _parsePlaylistsFromJson(json),
        albums: _parseAlbumsFromJson(json),
        syncedAt: clock(),
      );
    }

    final isConnected = authState == StreamingAuthState.connected;
    if (!isConnected) {
      return postSearch(authenticated: false);
    }
    try {
      await refreshSessionIfNeeded();
      return await postSearch(authenticated: true);
    } on StreamingException catch (e) {
      if (e.isCancelled) rethrow;
      if (e.statusCode == 401 || e.isTokenExpired) {
        return postSearch(authenticated: false);
      }
      rethrow;
    }
  }

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    String? videoId;
    final rawTrackId = seed.trackId.trim();
    final lowerTrackId = rawTrackId.toLowerCase();
    final rawFilePath = seed.filePath?.trim();
    final lowerFilePath = rawFilePath?.toLowerCase() ?? '';
    final isExplicitYtmSeed = seed.providerId == kind ||
        seed.providerId.isEmpty ||
        lowerTrackId.startsWith('ytm:') ||
        lowerTrackId.startsWith('ytm_') ||
        lowerTrackId.startsWith('youtube_music:') ||
        lowerTrackId.startsWith('streaming:youtube_music:') ||
        lowerTrackId.contains('youtube.com') ||
        lowerTrackId.contains('youtu.be') ||
        lowerFilePath.contains('youtube.com') ||
        lowerFilePath.contains('youtu.be');

    if (isExplicitYtmSeed) {
      videoId = tryExtractCleanVideoId(rawTrackId, filePath: rawFilePath);
    }

    if (videoId == null || videoId.isEmpty) {
      final queryText = '${seed.artist.trim()} ${seed.title.trim()}'.trim();
      if (queryText.isNotEmpty) {
        try {
          final catalog = await _searchWithGuestFallback(
            queryText,
            cancel: cancel,
          );
          final candidates = catalog.tracks
              .where((t) => tryExtractCleanVideoId(t.id) != null)
              .map(
                (t) => TrackMetadata.fromTrackInfo(
                  t,
                  providerIdOverride: kind,
                ),
              )
              .toList(growable: false);
          if (candidates.isNotEmpty) {
            final best = TrackMatcher.selectBestMatch(
                  TrackMatchQuery.fromTrackMetadata(seed),
                  candidates,
                ) ??
                candidates.first;
            videoId = tryExtractCleanVideoId(
              best.trackId,
              filePath: best.filePath,
            );
          }
        } on StreamingException catch (e) {
          throw _mapRecError(e);
        }
      }
    }

    if (videoId == null || videoId.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'YouTube Music Radio',
      );
    }

    try {
      Map<String, dynamic> nextJson;
      try {
        nextJson = await _fetchWatchNextRadio(
          videoId,
          continuation: cursor,
          cancel: cancel,
        );
      } on StreamingException catch (e) {
        if (!e.isCancelled &&
            authState == StreamingAuthState.connected &&
            (e.statusCode == 401 || e.isTokenExpired)) {
          // Fallback to unauthenticated Guest request if session cookies expired.
          final trimmedCont = cursor?.trim();
          final hasCont = trimmedCont != null && trimmedCont.isNotEmpty;
          final uri = BaseStreamingProvider.buildUri(
            baseUrl,
            '/youtubei/v1/next',
            <String, String>{
              'prettyPrint': 'false',
              if (hasCont) ...<String, String>{
                'ctoken': trimmedCont,
                'continuation': trimmedCont,
              },
            },
          );
          nextJson = await http.requestJson(
            method: 'POST',
            uri: uri,
            headers: _buildWebRemixHeaders(authenticated: false),
            jsonBody: <String, dynamic>{
              'context': _buildWebRemixContext(),
              'videoId': videoId,
              'playlistId': 'RDAMVM$videoId',
              'isAudioOnly': true,
              if (hasCont) 'continuation': trimmedCont,
            },
            cancel: cancel,
          );
          _captureVisitorData(nextJson);
        } else {
          rethrow;
        }
      }

      final tracks = <TrackMetadata>[];
      final seenIds = <String>{};

      void addCandidateTracks(List<TrackInfo> parsed) {
        for (final t in parsed) {
          final clean = tryExtractCleanVideoId(t.id, filePath: t.filePath);
          if (clean == null || clean == videoId) continue;
          if (seenIds.add(clean)) {
            tracks.add(
              TrackMetadata.fromTrackInfo(t, providerIdOverride: kind),
            );
          }
        }
      }

      addCandidateTracks(_parsePlaylistPanelTracks(nextJson));
      addCandidateTracks(_parseTracksFromJson(nextJson));

      final effectiveLimit = limit > 0 ? limit : tracks.length;
      final limitedTracks = tracks.length > effectiveLimit
          ? tracks.take(effectiveLimit).toList(growable: false)
          : tracks;
      final nextCursor = _extractContinuationToken(nextJson);

      return RadioPage(
        tracks: limitedTracks,
        nextCursor: nextCursor,
        sourceLabel: 'YouTube Music Radio',
      );
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }

  List<TrackInfo> _parseTwoRowVideoTracks(Map<String, dynamic> root) {
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};
    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final nav = item['navigationEndpoint'];
      if (nav is! Map) continue;
      final watch = nav['watchEndpoint'];
      if (watch is! Map) continue;
      final rawVid = watch['videoId']?.toString().trim() ?? '';
      final videoId = tryExtractCleanVideoId(rawVid);
      if (videoId == null || !seenIds.add(videoId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名曲目';
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      final artist = parts.isNotEmpty ? parts.first : '未知藝術家';
      final album = (parts.length >= 2 &&
              !parts[1].toLowerCase().contains('play') &&
              !parts[1].toLowerCase().contains('view'))
          ? parts[1]
          : 'YouTube Music';
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']) ??
          _extractThumbnailUrl(item['thumbnail']);

      tracks.add(
        TrackInfo(
          id: 'ytm:$videoId',
          title: title,
          artist: artist,
          album: album,
          duration: Duration.zero,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }
    return tracks;
  }

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (authState != StreamingAuthState.connected) {
      return const <FeedSection>[];
    }

    try {
      await refreshSessionIfNeeded();
      final homeJson = await _browse('FEmusic_home', cancel: cancel);

      final sections = <FeedSection>[];
      var idx = 0;

      void collectShelf(Map<String, dynamic> shelf, {required bool isCarousel}) {
        String? title;
        String? subtitle;
        if (isCarousel) {
          final header = shelf['header'];
          final basicHeader = header is Map
              ? (header['musicCarouselShelfBasicHeaderRenderer'] is Map
                    ? header['musicCarouselShelfBasicHeaderRenderer'] as Map
                    : header)
              : null;
          title = _extractInnerTubeText(basicHeader?['title']);
          subtitle = _extractInnerTubeText(basicHeader?['strapline']);
        } else {
          title = _extractInnerTubeText(shelf['title']);
          subtitle = _extractInnerTubeText(shelf['subtitle']);
        }

        final mergedTracks = <TrackMetadata>[];
        final seenTrackIds = <String>{};
        for (final t in <TrackInfo>[
          ..._parseTracksFromJson(shelf),
          ..._parseTwoRowVideoTracks(shelf),
        ]) {
          final meta = TrackMetadata.fromTrackInfo(
            t,
            providerIdOverride: kind,
          );
          if (seenTrackIds.add(meta.trackId)) {
            mergedTracks.add(meta);
          }
        }
        final albums = _parseAlbumsFromJson(shelf);
        if (mergedTracks.isNotEmpty || albums.isNotEmpty) {
          sections.add(
            FeedSection(
              id: 'ytm_home_${idx++}',
              title: (title != null && title.trim().isNotEmpty)
                  ? title.trim()
                  : 'YouTube Music',
              subtitle: (subtitle != null && subtitle.trim().isNotEmpty)
                  ? subtitle.trim()
                  : null,
              providerId: kind,
              tracks: mergedTracks,
              albums: albums,
            ),
          );
        }
      }

      for (final carousel
          in _collectMapsByKey(homeJson, 'musicCarouselShelfRenderer')) {
        collectShelf(carousel, isCarousel: true);
      }
      for (final shelf in _collectMapsByKey(homeJson, 'musicShelfRenderer')) {
        collectShelf(shelf, isCarousel: false);
      }

      if (sections.isEmpty) {
        final mergedTracks = <TrackMetadata>[];
        final seenTrackIds = <String>{};
        for (final t in <TrackInfo>[
          ..._parseTracksFromJson(homeJson),
          ..._parseTwoRowVideoTracks(homeJson),
        ]) {
          final meta = TrackMetadata.fromTrackInfo(
            t,
            providerIdOverride: kind,
          );
          if (seenTrackIds.add(meta.trackId)) {
            mergedTracks.add(meta);
          }
        }
        final albums = _parseAlbumsFromJson(homeJson);
        if (mergedTracks.isNotEmpty || albums.isNotEmpty) {
          sections.add(
            FeedSection(
              id: 'ytm_home_0',
              title: 'YouTube Music Home',
              providerId: kind,
              tracks: mergedTracks,
              albums: albums,
            ),
          );
        }
      }

      return List<FeedSection>.unmodifiable(sections);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final searchText = '${query.artist.trim()} ${query.title.trim()}'.trim();
    if (searchText.isEmpty) return null;

    try {
      final catalog = await _searchWithGuestFallback(
        searchText,
        cancel: cancel,
      );
      final candidates = catalog.tracks
          .map((t) => TrackMetadata.fromTrackInfo(t, providerIdOverride: kind))
          .toList(growable: false);
      return TrackMatcher.selectBestMatch(query, candidates);
    } on StreamingException catch (e) {
      throw _mapRecError(e);
    }
  }
}
