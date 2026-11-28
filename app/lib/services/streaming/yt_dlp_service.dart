import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/streaming_models.dart';
import 'ffmpeg_audio_proxy.dart';

export 'ffmpeg_audio_proxy.dart' show FfmpegAudioProxy, YtDlpProcessStarter;

part 'yt_dlp/yt_dlp_discovery_ext.dart';
part 'yt_dlp/yt_dlp_json_parser.dart';
part 'yt_dlp/yt_dlp_models.dart';
part 'yt_dlp/yt_dlp_process_handles.dart';
part 'yt_dlp/yt_dlp_resolver_ext.dart';
part 'yt_dlp/yt_dlp_updater_ext.dart';
part 'yt_dlp/yt_dlp_version_helpers.dart';

/// Manages bundled & user-updated `yt-dlp`, `deno`, and `ffmpeg` binaries,
/// permission-safe atomic in-app updates, non-blocking YouTube stream resolution
/// with instant cancellation on track switches, TTL caching, background preload,
/// and lossless WAV fallback transcoding via [FfmpegAudioProxy].
class YtDlpService extends ChangeNotifier {
  static final YtDlpService instance = YtDlpService();

  static const String ytDlpBinaryName = 'yt-dlp.exe';
  static const String denoBinaryName = 'deno.exe';
  static const String ffmpegBinaryName = 'ffmpeg.exe';
  static const String licenseFileName = 'THIRD_PARTY_LICENSES.txt';

  static const String defaultAudioFormatSelector =
      'bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio[acodec=aac]/bestaudio';
  /// Native Symphonia + mousiki Opus-preferred HTTPS format selector aligned
  /// with Rust `core-audio` (`itag 251` WebM/Opus -> `itag 140` M4A/AAC).
  static const String opusPreferredAudioFormatSelector =
      '251/140/bestaudio[protocol=https][ext=webm][acodec=opus]/'
      'bestaudio[protocol=https][ext=m4a]/bestaudio[protocol=https]/bestaudio';
  static const String defaultExtractorArgs =
      'youtube:player_client=default,-tv_samsung';
  static const String defaultRemoteComponents = 'ejs:github';
  static const Duration maxAvailableAtWait = Duration(seconds: 12);

  static final Uri defaultLatestReleaseApiUri = Uri.parse(
    'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest',
  );

  static const Duration defaultStreamTtl = Duration(minutes: 45);
  static const int _maxCacheEntries = 128;

  final String? _injectedUserBinDir;
  final String? _injectedBundledBinDir;
  final String? _injectedPathEnv;
  final HttpClient Function() _httpClientFactory;
  final YtDlpProcessStarter _processStarter;
  final bool _useSystemProcessStarter;
  final String? _injectedLicenseFilePath;
  final DateTime Function() _clock;
  final Uri _latestReleaseApiUri;
  final Duration resolveTimeout;
  final Duration versionProbeTimeout;
  final Duration updateVerifyTimeout;

  FfmpegAudioProxy? _ffmpegProxy;

  YtDlpEnvironmentStatus _status = const YtDlpEnvironmentStatus();
  bool _initialized = false;
  bool _disposed = false;
  Future<YtDlpEnvironmentStatus>? _initFuture;
  Future<YtDlpUpdateResult>? _updateFuture;
  Future<String>? _ensureAvailableFuture;

  final Map<String, String> _cachedVersions = <String, String>{};
  final Map<String, YtDlpResolvedStream> _streamCache =
      <String, YtDlpResolvedStream>{};

  int _foregroundEpoch = 0;
  int? _activeForegroundRequestId;
  _ManagedProcessHandle? _foregroundHandle;
  _AvailabilityWaitHandle? _foregroundWaitHandle;

  int _preloadEpoch = 0;
  String? _preloadingVideoId;
  Future<YtDlpResolvedStream?>? _preloadFuture;
  _ManagedProcessHandle? _preloadHandle;

  final Set<Process> _runningProcesses = <Process>{};

  YtDlpService({
    String? userBinDir,
    String? bundledBinDir,
    String? pathEnv,
    HttpClient Function()? httpClientFactory,
    YtDlpProcessStarter? processStarter,
    String? licenseFilePath,
    DateTime Function()? clock,
    Uri? latestReleaseApiUri,
    this.resolveTimeout = const Duration(seconds: 12),
    this.versionProbeTimeout = const Duration(seconds: 5),
    this.updateVerifyTimeout = const Duration(seconds: 10),
    this._ffmpegProxy,
  }) : _injectedUserBinDir = userBinDir,
       _injectedBundledBinDir = bundledBinDir,
       _injectedPathEnv = pathEnv,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _processStarter = processStarter ?? Process.start,
       _useSystemProcessStarter = processStarter == null,
       _injectedLicenseFilePath = licenseFilePath,
       _clock = clock ?? DateTime.now,
       _latestReleaseApiUri = latestReleaseApiUri ?? defaultLatestReleaseApiUri;

  YtDlpEnvironmentStatus get status => _status;
  bool get isInitialized => _initialized;

  @visibleForTesting
  Map<String, String> get cachedBinaryVersions =>
      Map<String, String>.unmodifiable(_cachedVersions);

  String get userBinDir => _resolveUserBinDir();
  String get bundledBinDir => _resolveBundledBinDir();

  FfmpegAudioProxy get ffmpegProxy => _ffmpegProxy ??= FfmpegAudioProxy(
    ffmpegPathProvider: () => _status.ffmpegPath,
    processStarter: _processStarter,
  );

  static int compareVersionStrings(String a, String b) =>
      _compareVersionStringsImpl(a, b);

  static String? parseYtDlpVersionOutput(String output) =>
      _parseYtDlpVersionOutputImpl(output);

  static String? parseDenoVersionOutput(String output) =>
      _parseDenoVersionOutputImpl(output);

  static String? parseFfmpegVersionOutput(String output) =>
      _parseFfmpegVersionOutputImpl(output);

  static String? parseSha256ForAsset(String sumsContent, String assetName) =>
      _parseSha256ForAssetImpl(sumsContent, assetName);

  static List<String> buildResolveArgs({
    required String videoId,
    String? denoPath,
    String? ffmpegDir,
    String? cookiesFilePath,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) {
    final args = <String>['--no-config', '--force-ipv4'];
    if (denoPath != null && denoPath.trim().isNotEmpty) {
      args.addAll(<String>['--js-runtimes', 'deno:${denoPath.trim()}']);
    }
    if (remoteComponents != null && remoteComponents.trim().isNotEmpty) {
      args.addAll(<String>['--remote-components', remoteComponents.trim()]);
    }
    if (ffmpegDir != null && ffmpegDir.trim().isNotEmpty) {
      args.addAll(<String>['--ffmpeg-location', ffmpegDir.trim()]);
    }
    final effectiveExtractorArgs =
        (extractorArgs != null && extractorArgs.trim().isNotEmpty)
            ? extractorArgs.trim()
            : defaultExtractorArgs;
    final effectiveFormat =
        (formatSelector != null && formatSelector.trim().isNotEmpty)
            ? formatSelector.trim()
            : defaultAudioFormatSelector;
    args.addAll(<String>[
      '--extractor-args',
      effectiveExtractorArgs,
      '--no-playlist',
      '--skip-download',
      '--no-warnings',
      '-f',
      effectiveFormat,
    ]);
    if (cookiesFilePath != null && cookiesFilePath.trim().isNotEmpty) {
      args.addAll(<String>['--cookies', cookiesFilePath.trim()]);
    }
    args.addAll(<String>['-j', 'https://music.youtube.com/watch?v=$videoId']);
    return args;
  }

  static YtDlpResolvedStream parseResolvedStreamJson({
    required String videoId,
    required String rawStdout,
    required DateTime now,
  }) => _parseResolvedStreamJsonImpl(
    videoId: videoId,
    rawStdout: rawStdout,
    now: now,
  );

  Future<YtDlpEnvironmentStatus> initialize() {
    if (_initialized) return Future<YtDlpEnvironmentStatus>.value(_status);
    final existing = _initFuture;
    if (existing != null) return existing;

    final future = refreshEnvironment();
    _initFuture = future;
    return future.whenComplete(() {
      if (identical(_initFuture, future)) {
        _initFuture = null;
      }
    });
  }

  Future<YtDlpEnvironmentStatus> refreshEnvironment() =>
      _refreshEnvironmentImpl();

  Future<String> ensureAvailable() => _ensureAvailableImpl();

  Future<YtDlpUpdateResult> checkAndUpdateYtDlp() {
    final inFlight = _updateFuture;
    if (inFlight != null) return inFlight;

    final future = _performCheckAndUpdate();
    _updateFuture = future;
    return future.whenComplete(() {
      if (identical(_updateFuture, future)) {
        _updateFuture = null;
      }
    });
  }

  YtDlpResolvedStream? getCachedStream(String videoId) {
    final key = videoId.trim();
    if (key.isEmpty) return null;
    final entry = _streamCache[key];
    if (entry == null) return null;
    if (entry.isExpiredAt(_clock())) {
      _streamCache.remove(key);
      return null;
    }
    return entry;
  }

  void clearCache([String? videoId]) {
    if (videoId == null) {
      _streamCache.clear();
      return;
    }
    var key = videoId.trim();
    if (key.isEmpty) return;
    _streamCache.remove(key);

    var changed = true;
    while (changed && key.isNotEmpty) {
      changed = false;
      for (final prefix in const <String>[
        'streaming:youtube_music:',
        'youtube_music:',
        'ytm:',
        'ytm_',
      ]) {
        if (key.startsWith(prefix) && key.length > prefix.length) {
          key = key.substring(prefix.length).trim();
          _streamCache.remove(key);
          changed = true;
        }
      }
    }
  }

  void _storeCache(YtDlpResolvedStream stream) {
    if (stream.isExpiredAt(_clock())) return;
    if (!_streamCache.containsKey(stream.videoId) &&
        _streamCache.length >= _maxCacheEntries) {
      _streamCache.remove(_streamCache.keys.first);
    }
    _streamCache[stream.videoId] = stream;
  }

  Future<YtDlpResolvedStream> resolveVideo(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) => _resolveVideoImpl(
    videoId,
    playRequestId: playRequestId,
    cookiesFilePath: cookiesFilePath,
    bypassCache: bypassCache,
    formatSelector: formatSelector,
    extractorArgs: extractorArgs,
    remoteComponents: remoteComponents,
  );

  Future<YtDlpResolvedStream?> preloadVideo(
    String videoId, {
    String? cookiesFilePath,
  }) => _preloadVideoImpl(videoId, cookiesFilePath: cookiesFilePath);

  Future<void> _ensureFfmpegReady() async {
    if (!_initialized) {
      await initialize();
    }
    if (!_status.isFfmpegAvailable) {
      throw const YtDlpException('未偵測到 ffmpeg.exe，無法轉碼此音訊格式');
    }
  }

  Future<String> openTranscodedWavUrl({
    required String sourceUrl,
    Map<String, String> headers = const {},
    required int playRequestId,
  }) async {
    await _ensureFfmpegReady();
    return ffmpegProxy.openTranscodedWavUrl(
      sourceUrl: sourceUrl,
      headers: headers,
      playRequestId: playRequestId,
    );
  }

  Future<String> openDashMpdUrl({
    required String mpdXml,
    required int playRequestId,
    bool copyFlac = true,
  }) async {
    await _ensureFfmpegReady();
    return ffmpegProxy.openDashMpdUrl(
      mpdXml: mpdXml,
      playRequestId: playRequestId,
      copyFlac: copyFlac,
    );
  }

  void cancelPlaybackProcesses({int? exceptRequestId}) {
    _killForegroundProcess(exceptRequestId: exceptRequestId);
    if (exceptRequestId == null) {
      _killPreloadProcess();
    }
    _ffmpegProxy?.cancel(exceptRequestId: exceptRequestId);
  }

  void stopFfmpegProxy({int? exceptRequestId}) =>
      _ffmpegProxy?.cancel(exceptRequestId: exceptRequestId);

  void cancelRequest(int playRequestId) {
    if (_activeForegroundRequestId != playRequestId &&
        _foregroundHandle?.requestId != playRequestId &&
        _foregroundWaitHandle?.requestId != playRequestId) {
      return;
    }
    _foregroundEpoch++;
    if (_foregroundHandle?.requestId == playRequestId) {
      _foregroundHandle?.cancel();
      _foregroundHandle = null;
    }
    if (_foregroundWaitHandle?.requestId == playRequestId) {
      _foregroundWaitHandle?.cancel();
      _foregroundWaitHandle = null;
    }
  }

  void _killForegroundProcess({int? exceptRequestId}) {
    if (exceptRequestId == null ||
        _activeForegroundRequestId != exceptRequestId) {
      _foregroundEpoch++;
      final handle = _foregroundHandle;
      if (handle != null &&
          (exceptRequestId == null || handle.requestId != exceptRequestId)) {
        handle.cancel();
        _foregroundHandle = null;
      }
      final waitHandle = _foregroundWaitHandle;
      if (waitHandle != null &&
          (exceptRequestId == null || waitHandle.requestId != exceptRequestId)) {
        waitHandle.cancel();
        _foregroundWaitHandle = null;
      }
    }
  }

  void _killPreloadProcess() {
    _preloadEpoch++;
    _preloadingVideoId = null;
    _preloadFuture = null;
    final handle = _preloadHandle;
    if (handle != null) {
      handle.cancel();
      _preloadHandle = null;
    }
  }

  Future<void> stopAll({Duration waitTimeout = const Duration(seconds: 2)}) =>
      _stopAllImpl(waitTimeout: waitTimeout);

  Future<String> readThirdPartyLicenses() async {
    final path = _resolveLicenseFilePath();
    if (path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          return utf8.decode(bytes, allowMalformed: true);
        }
      } catch (e) {
        debugPrint('[YtDlpService] Failed reading license file $path: $e');
      }
    }
    return _fallbackLicenseSummary;
  }

  void _safeNotifyListeners() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(stopAll());
    final proxy = _ffmpegProxy;
    _ffmpegProxy = null;
    if (proxy != null) {
      unawaited(proxy.dispose());
    }
    super.dispose();
  }
}
