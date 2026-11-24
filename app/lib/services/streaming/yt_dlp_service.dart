import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../models/streaming_models.dart';
import 'ffmpeg_audio_proxy.dart';

export 'ffmpeg_audio_proxy.dart' show FfmpegAudioProxy, YtDlpProcessStarter;

/// Three-tier resolution source for bundled/user/system runtime binaries.
enum YtDlpBinarySource {
  userUpdated('使用者更新版'),
  bundled('內建版'),
  systemPath('系統 PATH'),
  missing('未安裝');

  const YtDlpBinarySource(this.label);

  /// Localized UI label in Traditional Chinese.
  final String label;
}

/// Immutable status snapshot describing detected `yt-dlp`, `deno`, and `ffmpeg`
/// binaries, update progress, and third-party license file location.
class YtDlpEnvironmentStatus {
  final String? ytDlpPath;
  final YtDlpBinarySource ytDlpSource;
  final String? ytDlpVersion;

  final String? denoPath;
  final YtDlpBinarySource denoSource;
  final String? denoVersion;

  final String? ffmpegPath;
  final YtDlpBinarySource ffmpegSource;
  final String? ffmpegVersion;
  final String? ffmpegDir;

  final bool isUpdating;
  final String? lastUpdateMessage;
  final String? licenseFilePath;

  const YtDlpEnvironmentStatus({
    this.ytDlpPath,
    this.ytDlpSource = YtDlpBinarySource.missing,
    this.ytDlpVersion,
    this.denoPath,
    this.denoSource = YtDlpBinarySource.missing,
    this.denoVersion,
    this.ffmpegPath,
    this.ffmpegSource = YtDlpBinarySource.missing,
    this.ffmpegVersion,
    this.ffmpegDir,
    this.isUpdating = false,
    this.lastUpdateMessage,
    this.licenseFilePath,
  });

  bool get isYtDlpAvailable =>
      ytDlpPath != null && ytDlpSource != YtDlpBinarySource.missing;

  bool get isDenoAvailable =>
      denoPath != null && denoSource != YtDlpBinarySource.missing;

  bool get isFfmpegAvailable =>
      ffmpegPath != null && ffmpegSource != YtDlpBinarySource.missing;

  YtDlpEnvironmentStatus copyWith({
    String? ytDlpPath,
    bool clearYtDlpPath = false,
    YtDlpBinarySource? ytDlpSource,
    String? ytDlpVersion,
    bool clearYtDlpVersion = false,
    String? denoPath,
    bool clearDenoPath = false,
    YtDlpBinarySource? denoSource,
    String? denoVersion,
    bool clearDenoVersion = false,
    String? ffmpegPath,
    bool clearFfmpegPath = false,
    YtDlpBinarySource? ffmpegSource,
    String? ffmpegVersion,
    bool clearFfmpegVersion = false,
    String? ffmpegDir,
    bool clearFfmpegDir = false,
    bool? isUpdating,
    String? lastUpdateMessage,
    bool clearLastUpdateMessage = false,
    String? licenseFilePath,
    bool clearLicenseFilePath = false,
  }) {
    return YtDlpEnvironmentStatus(
      ytDlpPath: clearYtDlpPath ? null : (ytDlpPath ?? this.ytDlpPath),
      ytDlpSource: ytDlpSource ?? this.ytDlpSource,
      ytDlpVersion: clearYtDlpVersion
          ? null
          : (ytDlpVersion ?? this.ytDlpVersion),
      denoPath: clearDenoPath ? null : (denoPath ?? this.denoPath),
      denoSource: denoSource ?? this.denoSource,
      denoVersion: clearDenoVersion ? null : (denoVersion ?? this.denoVersion),
      ffmpegPath: clearFfmpegPath ? null : (ffmpegPath ?? this.ffmpegPath),
      ffmpegSource: ffmpegSource ?? this.ffmpegSource,
      ffmpegVersion: clearFfmpegVersion
          ? null
          : (ffmpegVersion ?? this.ffmpegVersion),
      ffmpegDir: clearFfmpegDir ? null : (ffmpegDir ?? this.ffmpegDir),
      isUpdating: isUpdating ?? this.isUpdating,
      lastUpdateMessage: clearLastUpdateMessage
          ? null
          : (lastUpdateMessage ?? this.lastUpdateMessage),
      licenseFilePath: clearLicenseFilePath
          ? null
          : (licenseFilePath ?? this.licenseFilePath),
    );
  }
}

/// Outcome of [YtDlpService.checkAndUpdateYtDlp].
enum YtDlpUpdateOutcome { updated, upToDate, failed }

/// Result returned by [YtDlpService.checkAndUpdateYtDlp].
class YtDlpUpdateResult {
  final YtDlpUpdateOutcome outcome;
  final String? currentVersion;
  final String? latestVersion;
  final String message;

  const YtDlpUpdateResult._({
    required this.outcome,
    required this.message,
    this.currentVersion,
    this.latestVersion,
  });

  factory YtDlpUpdateResult.updated({
    String? previousVersion,
    required String newVersion,
    required String message,
  }) {
    return YtDlpUpdateResult._(
      outcome: YtDlpUpdateOutcome.updated,
      currentVersion: previousVersion,
      latestVersion: newVersion,
      message: message,
    );
  }

  factory YtDlpUpdateResult.upToDate({
    required String currentVersion,
    String? latestVersion,
    required String message,
  }) {
    return YtDlpUpdateResult._(
      outcome: YtDlpUpdateOutcome.upToDate,
      currentVersion: currentVersion,
      latestVersion: latestVersion ?? currentVersion,
      message: message,
    );
  }

  factory YtDlpUpdateResult.failed({
    String? currentVersion,
    String? latestVersion,
    required String message,
  }) {
    return YtDlpUpdateResult._(
      outcome: YtDlpUpdateOutcome.failed,
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      message: message,
    );
  }

  bool get isUpdated => outcome == YtDlpUpdateOutcome.updated;
  bool get isUpToDate => outcome == YtDlpUpdateOutcome.upToDate;
  bool get isFailed => outcome == YtDlpUpdateOutcome.failed;
}

/// Descriptive exception thrown by [YtDlpService] operations.
class YtDlpException implements Exception {
  final String message;
  final bool isCancelled;
  final bool isTimeout;
  final int? exitCode;

  const YtDlpException(
    this.message, {
    this.isCancelled = false,
    this.isTimeout = false,
    this.exitCode,
  });

  @override
  String toString() => 'YtDlpException: $message';
}

/// Resolved playable audio stream metadata returned by `yt-dlp -j`.
class YtDlpResolvedStream {
  static const Duration expirySafetyMargin = Duration(seconds: 60);

  final String videoId;
  final String url;
  final Map<String, String> httpHeaders;
  final String? acodec;
  final String? ext;
  final int? sampleRateHz;
  final double? bitrateKbps;
  final double? durationSeconds;
  final int? contentLength;
  final String? mimeType;
  final String? thumbnailUrl;
  final double? loudnessDb;
  final DateTime expiresAt;
  final DateTime? availableAt;

  const YtDlpResolvedStream({
    required this.videoId,
    required this.url,
    required this.httpHeaders,
    this.acodec,
    this.ext,
    this.sampleRateHz,
    this.bitrateKbps,
    this.durationSeconds,
    this.contentLength,
    this.mimeType,
    this.thumbnailUrl,
    this.loudnessDb,
    required this.expiresAt,
    this.availableAt,
  });

  /// Returns true when the stream URL has expired or is within the 60s safety margin.
  bool get isExpired => isExpiredAt(DateTime.now());

  /// Deterministic expiry check using a caller-provided timestamp.
  bool isExpiredAt(DateTime now) {
    final effectiveExpiry = expiresAt.subtract(expirySafetyMargin);
    return !now.isBefore(effectiveExpiry);
  }

  /// Human-readable quality label, e.g. `AAC 44.1 kHz`, `OPUS 48 kHz`, `MP3 44.1 kHz`.
  String get qualityLabel {
    final codec = _displayCodecName();
    final sr = sampleRateHz;
    if (sr != null && sr > 0) {
      final khz = sr / 1000.0;
      final formattedKhz = (khz - khz.roundToDouble()).abs() < 0.001
          ? '${khz.round()} kHz'
          : '${khz.toStringAsFixed(1)} kHz';
      return '$codec $formattedKhz';
    }
    final abr = bitrateKbps;
    if (abr != null && abr > 0) {
      return '$codec ${abr.round()} kbps';
    }
    return codec;
  }

  String _displayCodecName() {
    final codecRaw = acodec?.trim().toLowerCase() ?? '';
    final extRaw = ext?.trim().toLowerCase() ?? '';

    if (codecRaw.isNotEmpty && codecRaw != 'none') {
      if (codecRaw == 'mp4a.6b' ||
          codecRaw == 'mp4a.69' ||
          codecRaw.contains('mp3')) {
        return 'MP3';
      }
      if (codecRaw.startsWith('mp4a') || codecRaw == 'aac') {
        return 'AAC';
      }
      if (codecRaw.contains('opus')) return 'OPUS';
      if (codecRaw.contains('flac')) return 'FLAC';
      if (codecRaw.contains('alac')) return 'ALAC';
      if (codecRaw.contains('vorbis')) return 'VORBIS';
      if (codecRaw.contains('pcm')) return 'PCM';
      if (codecRaw.contains('eac3') || codecRaw.contains('ec-3')) return 'EAC3';
      if (codecRaw.contains('ac3') || codecRaw.contains('ac-3')) return 'AC3';
      return codecRaw.toUpperCase();
    }

    switch (extRaw) {
      case 'm4a':
      case 'aac':
        return 'AAC';
      case 'mp3':
        return 'MP3';
      case 'opus':
        return 'OPUS';
      case 'flac':
        return 'FLAC';
      case 'alac':
        return 'ALAC';
      case 'ogg':
      case 'oga':
        return 'VORBIS';
      case 'wav':
        return 'WAV';
      case 'aiff':
      case 'aif':
        return 'AIFF';
      case 'webm':
        return 'WEBM';
      default:
        return extRaw.isNotEmpty ? extRaw.toUpperCase() : 'AUDIO';
    }
  }

  /// Returns `false` for formats natively decoded by Lumina's Rust Symphonia
  /// pipeline (`m4a`/`mp4a`/`aac`, `mp3`, `flac`, `alac`, `vorbis`, `wav`,
  /// `aiff`, `pcm`) and `true` for formats requiring lossless WAV transcoding
  /// via [FfmpegAudioProxy] (`opus`, `webm`, `m3u8`/HLS, `dash`, `ac3`, `eac3`, etc.).
  bool get requiresFfmpegTranscode {
    final lowerCodec = acodec?.trim().toLowerCase() ?? '';
    final lowerExt = ext?.trim().toLowerCase() ?? '';
    final lowerUrl = url.trim().toLowerCase();

    // Manifest / segmented streaming formats always need FFmpeg proxy.
    if (lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('.mpd') ||
        lowerUrl.contains('/hls_playlist/') ||
        lowerUrl.contains('/dash/')) {
      return true;
    }

    const unsupportedExts = <String>{
      'opus',
      'webm',
      'm3u8',
      'm3u8_native',
      'hls',
      'mpd',
      'dash',
      'ac3',
      'eac3',
      'ts',
      'wma',
    };
    if (unsupportedExts.contains(lowerExt)) {
      return true;
    }

    // Explicitly unsupported codecs even inside otherwise supported containers.
    if (lowerCodec.isNotEmpty && lowerCodec != 'none') {
      if (lowerCodec.contains('opus') ||
          lowerCodec.contains('ec-3') ||
          lowerCodec.contains('eac3') ||
          lowerCodec.contains('ac-3') ||
          lowerCodec.contains('ac3') ||
          lowerCodec.contains('dts') ||
          lowerCodec.contains('wma') ||
          lowerCodec.contains('amr')) {
        return true;
      }

      if (lowerCodec.startsWith('mp4a') ||
          lowerCodec == 'aac' ||
          lowerCodec.contains('mp3') ||
          lowerCodec.contains('flac') ||
          lowerCodec.contains('alac') ||
          lowerCodec.contains('vorbis') ||
          lowerCodec.contains('wav') ||
          lowerCodec.contains('aiff') ||
          lowerCodec.contains('pcm')) {
        return false;
      }

      return true;
    }

    const supportedExts = <String>{
      'm4a',
      'mp4',
      'aac',
      'mp3',
      'flac',
      'alac',
      'ogg',
      'oga',
      'wav',
      'aiff',
      'aif',
      'pcm',
    };
    return !supportedExts.contains(lowerExt);
  }
}

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
       _injectedLicenseFilePath = licenseFilePath,
       _clock = clock ?? DateTime.now,
       _latestReleaseApiUri = latestReleaseApiUri ?? defaultLatestReleaseApiUri;

  /// Current detected environment and update status snapshot.
  YtDlpEnvironmentStatus get status => _status;

  /// Whether [initialize] has completed at least once.
  bool get isInitialized => _initialized;

  /// Cached `--version` probe results keyed by binary path.
  @visibleForTesting
  Map<String, String> get cachedBinaryVersions =>
      Map<String, String>.unmodifiable(_cachedVersions);

  /// Resolved user-writable hot-update directory (`%LOCALAPPDATA%\LuminaAudio\bin`).
  String get userBinDir => _resolveUserBinDir();

  /// Resolved bundled executable directory (`<executable_dir>\bin`).
  String get bundledBinDir => _resolveBundledBinDir();

  /// Lazily created loopback FFmpeg WAV transcoding proxy.
  FfmpegAudioProxy get ffmpegProxy => _ffmpegProxy ??= FfmpegAudioProxy(
    ffmpegPathProvider: () => _status.ffmpegPath,
    processStarter: _processStarter,
  );

  // ---------------------------------------------------------------------------
  // Version Comparison & Parsing Helpers
  // ---------------------------------------------------------------------------

  /// Compares two version strings (e.g. `2026.11.05` vs `2026.10.26`,
  /// `2026.10.26` vs `2026.10.9`, `v2.9.8` vs `2.10.0`).
  ///
  /// Returns positive if [a] > [b], negative if [a] < [b], and 0 if equal.
  static int compareVersionStrings(String a, String b) {
    final normA = _normalizeVersionString(a);
    final normB = _normalizeVersionString(b);
    if (normA == normB) return 0;
    if (normA.isEmpty) return -1;
    if (normB.isEmpty) return 1;

    final splitA = _splitVersionPrerelease(normA);
    final splitB = _splitVersionPrerelease(normB);

    final partsA = splitA.core.split('.');
    final partsB = splitB.core.split('.');
    final maxLen = partsA.length > partsB.length
        ? partsA.length
        : partsB.length;

    for (var i = 0; i < maxLen; i++) {
      final rawA = i < partsA.length ? partsA[i] : '';
      final rawB = i < partsB.length ? partsB[i] : '';

      final intA = rawA.isEmpty ? 0 : int.tryParse(rawA);
      final intB = rawB.isEmpty ? 0 : int.tryParse(rawB);

      if (intA != null && intB != null) {
        if (intA != intB) return intA.compareTo(intB);
        continue;
      }

      // Missing segment vs non-numeric extra segment (e.g. 2026.10.26 vs 2026.10.26.post1).
      if (rawA.isEmpty) return -1;
      if (rawB.isEmpty) return 1;

      final cmp = _compareAlphanumericSegment(rawA, rawB);
      if (cmp != 0) return cmp;
    }

    // Core numeric segments are equal; stable release > prerelease (e.g. 1.0.0 > 1.0.0-rc1).
    final preA = splitA.prerelease;
    final preB = splitB.prerelease;
    if (preA == preB) return 0;
    if (preA == null) return 1;
    if (preB == null) return -1;
    return _compareAlphanumericSegment(preA, preB);
  }

  static String _normalizeVersionString(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    // Strip build metadata (+...) if present.
    final plusIdx = s.indexOf('+');
    if (plusIdx >= 0) {
      s = s.substring(0, plusIdx);
    }
    if ((s.startsWith('v') || s.startsWith('V')) &&
        s.length > 1 &&
        RegExp(r'^[0-9]').hasMatch(s.substring(1))) {
      s = s.substring(1);
    }
    return s.trim();
  }

  static ({String core, String? prerelease}) _splitVersionPrerelease(String s) {
    final dashIdx = s.indexOf('-');
    if (dashIdx < 0) return (core: s, prerelease: null);
    return (
      core: s.substring(0, dashIdx),
      prerelease: s.substring(dashIdx + 1),
    );
  }

  static int _compareAlphanumericSegment(String a, String b) {
    final tokenPattern = RegExp(r'(\d+|[^\d]+)');
    final tokensA = tokenPattern
        .allMatches(a)
        .map((m) => m.group(0)!)
        .toList();
    final tokensB = tokenPattern
        .allMatches(b)
        .map((m) => m.group(0)!)
        .toList();

    final maxLen = tokensA.length > tokensB.length
        ? tokensA.length
        : tokensB.length;
    for (var i = 0; i < maxLen; i++) {
      if (i >= tokensA.length) return -1;
      if (i >= tokensB.length) return 1;
      final ta = tokensA[i];
      final tb = tokensB[i];
      final ia = int.tryParse(ta);
      final ib = int.tryParse(tb);
      if (ia != null && ib != null) {
        if (ia != ib) return ia.compareTo(ib);
      } else {
        final cmp = ta.toLowerCase().compareTo(tb.toLowerCase());
        if (cmp != 0) return cmp;
      }
    }
    return 0;
  }

  /// Extracts a single-line version from `yt-dlp --version`.
  static String? parseYtDlpVersionOutput(String output) {
    final first = _firstNonEmptyLine(output);
    if (first == null) return null;
    final token = first.split(RegExp(r'\s+')).first.trim();
    return token.isEmpty ? null : token;
  }

  /// Extracts a single-line version from `deno --version`
  /// (e.g. `deno 2.9.8 (stable, ...)` -> `2.9.8`).
  static String? parseDenoVersionOutput(String output) {
    final first = _firstNonEmptyLine(output);
    if (first == null) return null;
    final match = RegExp(
      r'deno\s+v?([0-9][^\s()]*)',
      caseSensitive: false,
    ).firstMatch(first);
    if (match != null) return match.group(1);
    return first;
  }

  /// Extracts a single-line version from `ffmpeg -version`
  /// (e.g. `ffmpeg version N-129219-g359c825152-20261122 Copyright ...`).
  static String? parseFfmpegVersionOutput(String output) {
    final first = _firstNonEmptyLine(output);
    if (first == null) return null;
    final match = RegExp(
      r'ffmpeg\s+version\s+([^\s]+)',
      caseSensitive: false,
    ).firstMatch(first);
    if (match != null) return match.group(1);
    return first;
  }

  static String? _firstNonEmptyLine(String text) {
    for (final line in LineSplitter.split(text)) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Builds exact isolated CLI arguments for `yt-dlp -j` audio stream resolution.
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

  // ---------------------------------------------------------------------------
  // Three-Tier Binary Detection & Anti-Regression Selection
  // ---------------------------------------------------------------------------

  /// Initializes binary discovery once; subsequent calls return cached status.
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

  /// Re-scans all three tiers (`userUpdated` -> `bundled` -> `systemPath`),
  /// runs anti-regression version comparison for `yt-dlp.exe`, and probes
  /// `deno.exe` and `ffmpeg.exe` versions asynchronously.
  Future<YtDlpEnvironmentStatus> refreshEnvironment() async {
    final ytDlpFuture = _locateAndProbeYtDlp();
    final denoFuture = _locateAndProbeAuxiliary(
      denoBinaryName,
      versionArg: '--version',
      parser: parseDenoVersionOutput,
    );
    final ffmpegFuture = _locateAndProbeAuxiliary(
      ffmpegBinaryName,
      versionArg: '-version',
      parser: parseFfmpegVersionOutput,
    );

    final ytDlpResult = await ytDlpFuture;
    final denoResult = await denoFuture;
    final ffmpegResult = await ffmpegFuture;

    final ffmpegPath = ffmpegResult.path;
    if (ffmpegPath != null && ffmpegPath.isNotEmpty) {
      debugPrint(
        '[YtDlpService] Located ffmpeg.exe: path=$ffmpegPath source=${ffmpegResult.source.name} version=${ffmpegResult.version ?? 'unknown'}',
      );
    } else {
      debugPrint(
        r'[YtDlpService] ffmpeg.exe not found (searched %LOCALAPPDATA%\LuminaAudio\bin, <exeDir>\bin, PATH)',
      );
    }
    final ffmpegDir = ffmpegPath != null ? File(ffmpegPath).parent.path : null;
    final licensePath = _resolveLicenseFilePath();

    _initialized = true;
    _status = _status.copyWith(
      ytDlpPath: ytDlpResult.path,
      clearYtDlpPath: ytDlpResult.path == null,
      ytDlpSource: ytDlpResult.source,
      ytDlpVersion: ytDlpResult.version,
      clearYtDlpVersion: ytDlpResult.version == null,
      denoPath: denoResult.path,
      clearDenoPath: denoResult.path == null,
      denoSource: denoResult.source,
      denoVersion: denoResult.version,
      clearDenoVersion: denoResult.version == null,
      ffmpegPath: ffmpegPath,
      clearFfmpegPath: ffmpegPath == null,
      ffmpegSource: ffmpegResult.source,
      ffmpegVersion: ffmpegResult.version,
      clearFfmpegVersion: ffmpegResult.version == null,
      ffmpegDir: ffmpegDir,
      clearFfmpegDir: ffmpegDir == null,
      licenseFilePath: licensePath,
      clearLicenseFilePath: licensePath == null,
    );

    _safeNotifyListeners();
    return _status;
  }

  Future<_DetectedBinary> _locateAndProbeYtDlp() async {
    final userPath = _joinPath(userBinDir, ytDlpBinaryName);
    final bundledPath = _joinPath(bundledBinDir, ytDlpBinaryName);

    final hasUser = File(userPath).existsSync();
    final hasBundled = File(bundledPath).existsSync();

    if (hasUser && hasBundled) {
      // Anti-regression comparison: probe BOTH in parallel and always pick the newer version.
      // When equal, prefer `bundled` so an upgraded installer isn't shadowed.
      final versions = await Future.wait<String?>(<Future<String?>>[
        _probeBinaryVersion(
          userPath,
          args: const <String>['--version'],
          parser: parseYtDlpVersionOutput,
        ),
        _probeBinaryVersion(
          bundledPath,
          args: const <String>['--version'],
          parser: parseYtDlpVersionOutput,
        ),
      ]);

      final userVersion = versions[0];
      final bundledVersion = versions[1];

      if (userVersion != null && bundledVersion != null) {
        if (compareVersionStrings(userVersion, bundledVersion) > 0) {
          return _DetectedBinary(
            path: userPath,
            source: YtDlpBinarySource.userUpdated,
            version: userVersion,
          );
        }
        return _DetectedBinary(
          path: bundledPath,
          source: YtDlpBinarySource.bundled,
          version: bundledVersion,
        );
      }

      if (bundledVersion != null) {
        return _DetectedBinary(
          path: bundledPath,
          source: YtDlpBinarySource.bundled,
          version: bundledVersion,
        );
      }
      if (userVersion != null) {
        return _DetectedBinary(
          path: userPath,
          source: YtDlpBinarySource.userUpdated,
          version: userVersion,
        );
      }
      return _DetectedBinary(
        path: bundledPath,
        source: YtDlpBinarySource.bundled,
        version: null,
      );
    }

    if (hasUser) {
      final version = await _probeBinaryVersion(
        userPath,
        args: const <String>['--version'],
        parser: parseYtDlpVersionOutput,
      );
      return _DetectedBinary(
        path: userPath,
        source: YtDlpBinarySource.userUpdated,
        version: version,
      );
    }

    if (hasBundled) {
      final version = await _probeBinaryVersion(
        bundledPath,
        args: const <String>['--version'],
        parser: parseYtDlpVersionOutput,
      );
      return _DetectedBinary(
        path: bundledPath,
        source: YtDlpBinarySource.bundled,
        version: version,
      );
    }

    final sysPath = _findInSystemPath(ytDlpBinaryName);
    if (sysPath != null) {
      final version = await _probeBinaryVersion(
        sysPath,
        args: const <String>['--version'],
        parser: parseYtDlpVersionOutput,
      );
      return _DetectedBinary(
        path: sysPath,
        source: YtDlpBinarySource.systemPath,
        version: version,
      );
    }

    return const _DetectedBinary(
      path: null,
      source: YtDlpBinarySource.missing,
      version: null,
    );
  }

  Future<_DetectedBinary> _locateAndProbeAuxiliary(
    String binaryName, {
    required String versionArg,
    required String? Function(String) parser,
  }) async {
    final userPath = _joinPath(userBinDir, binaryName);
    if (File(userPath).existsSync()) {
      final version = await _probeBinaryVersion(
        userPath,
        args: <String>[versionArg],
        parser: parser,
      );
      return _DetectedBinary(
        path: userPath,
        source: YtDlpBinarySource.userUpdated,
        version: version,
      );
    }

    final bundledPath = _joinPath(bundledBinDir, binaryName);
    if (File(bundledPath).existsSync()) {
      final version = await _probeBinaryVersion(
        bundledPath,
        args: <String>[versionArg],
        parser: parser,
      );
      return _DetectedBinary(
        path: bundledPath,
        source: YtDlpBinarySource.bundled,
        version: version,
      );
    }

    final sysPath = _findInSystemPath(binaryName);
    if (sysPath != null) {
      final version = await _probeBinaryVersion(
        sysPath,
        args: <String>[versionArg],
        parser: parser,
      );
      return _DetectedBinary(
        path: sysPath,
        source: YtDlpBinarySource.systemPath,
        version: version,
      );
    }

    return const _DetectedBinary(
      path: null,
      source: YtDlpBinarySource.missing,
      version: null,
    );
  }

  String? _findInSystemPath(String binaryName) {
    final rawPath = _injectedPathEnv ?? Platform.environment['PATH'] ?? '';
    if (rawPath.trim().isEmpty) return null;

    final separator = Platform.isWindows ? ';' : ':';
    final seen = <String>{};
    for (final segment in rawPath.split(separator)) {
      var dir = segment.trim();
      if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
        dir = dir.substring(1, dir.length - 1).trim();
      }
      if (dir.isEmpty) continue;
      final normalizedKey = Platform.isWindows ? dir.toLowerCase() : dir;
      if (!seen.add(normalizedKey)) continue;

      final candidate = _joinPath(dir, binaryName);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Future<String?> _probeBinaryVersion(
    String binaryPath, {
    required List<String> args,
    required String? Function(String) parser,
    Duration? timeout,
  }) async {
    try {
      final capture = await _runProcessCapture(
        executable: binaryPath,
        arguments: args,
        timeout: timeout ?? versionProbeTimeout,
      );
      if (capture.timedOut || capture.cancelled || capture.exitCode != 0) {
        return null;
      }
      final parsed = parser(capture.stdout);
      if (parsed != null && parsed.isNotEmpty) {
        _cachedVersions[binaryPath] = parsed;
      }
      return parsed;
    } catch (e) {
      debugPrint('[YtDlpService] Version probe failed for $binaryPath: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Missing-All-Tiers Fallback & Permission-Safe In-App Update
  // ---------------------------------------------------------------------------

  /// Fast synchronous path-only binary discovery for [ensureAvailable] when a
  /// single tier provides `yt-dlp.exe`. Avoids spawning 3 `--version`
  /// subprocesses on the first fallback resolve while leaving `_initialized`
  /// false so explicit [initialize] / [refreshEnvironment] calls still probe
  /// full version strings for UI display and anti-regression comparison.
  String? _tryLocateBinariesFastSync() {
    final userYtDlp = _joinPath(userBinDir, ytDlpBinaryName);
    final bundledYtDlp = _joinPath(bundledBinDir, ytDlpBinaryName);
    final hasUser = File(userYtDlp).existsSync();
    final hasBundled = File(bundledYtDlp).existsSync();

    // When both user and bundled copies exist, fall back to full initialize()
    // so version-based anti-regression comparison picks the newer binary.
    if (hasUser && hasBundled) {
      return null;
    }

    String? ytDlpPath;
    YtDlpBinarySource ytDlpSource = YtDlpBinarySource.missing;
    if (hasUser) {
      ytDlpPath = userYtDlp;
      ytDlpSource = YtDlpBinarySource.userUpdated;
    } else if (hasBundled) {
      ytDlpPath = bundledYtDlp;
      ytDlpSource = YtDlpBinarySource.bundled;
    } else {
      final sysYtDlp = _findInSystemPath(ytDlpBinaryName);
      if (sysYtDlp != null) {
        ytDlpPath = sysYtDlp;
        ytDlpSource = YtDlpBinarySource.systemPath;
      }
    }

    if (ytDlpPath == null) {
      return null;
    }

    ({String? path, YtDlpBinarySource source}) locateAuxSync(String name) {
      final userPath = _joinPath(userBinDir, name);
      if (File(userPath).existsSync()) {
        return (path: userPath, source: YtDlpBinarySource.userUpdated);
      }
      final bundledPath = _joinPath(bundledBinDir, name);
      if (File(bundledPath).existsSync()) {
        return (path: bundledPath, source: YtDlpBinarySource.bundled);
      }
      final sysPath = _findInSystemPath(name);
      if (sysPath != null) {
        return (path: sysPath, source: YtDlpBinarySource.systemPath);
      }
      return (path: null, source: YtDlpBinarySource.missing);
    }

    final deno = locateAuxSync(denoBinaryName);
    final ffmpeg = locateAuxSync(ffmpegBinaryName);
    final ffmpegDir = ffmpeg.path != null ? File(ffmpeg.path!).parent.path : null;
    final licensePath = _resolveLicenseFilePath();

    _status = _status.copyWith(
      ytDlpPath: ytDlpPath,
      ytDlpSource: ytDlpSource,
      denoPath: deno.path,
      clearDenoPath: deno.path == null,
      denoSource: deno.source,
      ffmpegPath: ffmpeg.path,
      clearFfmpegPath: ffmpeg.path == null,
      ffmpegSource: ffmpeg.source,
      ffmpegDir: ffmpegDir,
      clearFfmpegDir: ffmpegDir == null,
      licenseFilePath: licensePath,
      clearLicenseFilePath: licensePath == null,
    );
    _safeNotifyListeners();
    return ytDlpPath;
  }

  /// Ensures `yt-dlp.exe` is available, automatically downloading the official
  /// GitHub Release into `%LOCALAPPDATA%\LuminaAudio\bin\yt-dlp.exe` if missing
  /// from all three tiers.
  Future<String> ensureAvailable() async {
    final existing = _status.ytDlpPath;
    if (existing != null && File(existing).existsSync()) {
      return existing;
    }
    if (!_initialized) {
      final fastPath = _tryLocateBinariesFastSync();
      if (fastPath != null) {
        return fastPath;
      }
      await initialize();
    }
    final afterInit = _status.ytDlpPath;
    if (afterInit != null && File(afterInit).existsSync()) {
      return afterInit;
    }

    final inFlight = _ensureAvailableFuture;
    if (inFlight != null) return inFlight;

    final future = () async {
      final updateResult = await checkAndUpdateYtDlp();
      final resolved = _status.ytDlpPath;
      if (resolved != null && File(resolved).existsSync()) {
        return resolved;
      }
      throw YtDlpException(
        '無法自動取得 yt-dlp：${updateResult.message}',
      );
    }();

    _ensureAvailableFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_ensureAvailableFuture, future)) {
        _ensureAvailableFuture = null;
      }
    }
  }

  /// Queries official GitHub Releases for `yt-dlp/yt-dlp`, downloads to
  /// `%LOCALAPPDATA%\LuminaAudio\bin\yt-dlp.exe.tmp`, verifies SHA256 +
  /// `--version`, and atomically swaps into `%LOCALAPPDATA%\LuminaAudio\bin\yt-dlp.exe`.
  ///
  /// NEVER runs `yt-dlp -U` and NEVER mutates the bundled install directory.
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

  Future<YtDlpUpdateResult> _performCheckAndUpdate() async {
    if (!_initialized) {
      await initialize();
    }

    final previousVersion = _status.ytDlpVersion;
    _setUpdateState(
      isUpdating: true,
      message: '正在檢查 yt-dlp 最新版本...',
    );

    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 15);
    final tmpPath = _joinPath(userBinDir, '$ytDlpBinaryName.tmp');

    try {
      final release = await _fetchLatestReleaseInfo(client);
      final latestTag = release.tagName;

      if (_status.isYtDlpAvailable &&
          previousVersion != null &&
          previousVersion.isNotEmpty &&
          compareVersionStrings(latestTag, previousVersion) <= 0) {
        final msg = '已是最新版本 ($previousVersion)';
        _setUpdateState(isUpdating: false, message: msg);
        return YtDlpUpdateResult.upToDate(
          currentVersion: previousVersion,
          latestVersion: latestTag,
          message: msg,
        );
      }

      _setUpdateState(
        isUpdating: true,
        message: '正在下載 yt-dlp $latestTag...',
      );

      final targetDir = Directory(userBinDir);
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }

      // Remove any leftover stale temp file before downloading.
      await _safeDeleteFile(tmpPath);

      // Stream download to yt-dlp.exe.tmp.
      await _downloadFile(
        client,
        release.binaryDownloadUrl,
        tmpPath,
      );

      final tmpFile = File(tmpPath);
      if (!tmpFile.existsSync() || await tmpFile.length() <= 0) {
        throw const YtDlpException('下載的 yt-dlp.exe 檔案為空');
      }

      // Verify SHA256 if SHA2-256SUMS or asset digest is provided.
      String? expectedSha256;
      if (release.sha256SumsUrl != null) {
        _setUpdateState(
          isUpdating: true,
          message: '正在驗證 SHA256 校驗碼...',
        );
        final sumsBody = await _fetchText(client, release.sha256SumsUrl!);
        expectedSha256 = parseSha256ForAsset(sumsBody, ytDlpBinaryName);
      }
      expectedSha256 ??= release.assetSha256Digest;

      if (expectedSha256 != null) {
        final actualDigest = await sha256.bind(tmpFile.openRead()).first;
        final actualHex = actualDigest.toString().toLowerCase();
        if (actualHex != expectedSha256.toLowerCase()) {
          throw YtDlpException(
            'SHA256 校驗失敗（預期 ${expectedSha256.substring(0, 12)}...，實際 ${actualHex.substring(0, 12)}...）',
          );
        }
      }

      // Verify downloaded executable runs `--version` cleanly before activating.
      _setUpdateState(
        isUpdating: true,
        message: '正在驗證下載檔案可執行性...',
      );
      final verifyCapture = await _runProcessCapture(
        executable: tmpPath,
        arguments: const <String>['--version'],
        timeout: updateVerifyTimeout,
      );
      final verifiedVersion = parseYtDlpVersionOutput(verifyCapture.stdout);
      if (verifyCapture.timedOut ||
          verifyCapture.cancelled ||
          verifyCapture.exitCode != 0 ||
          verifiedVersion == null ||
          verifiedVersion.isEmpty) {
        throw YtDlpException(
          '下載的 yt-dlp.exe 驗證執行失敗（exit ${verifyCapture.exitCode}）',
          exitCode: verifyCapture.exitCode,
        );
      }

      // Atomically swap yt-dlp.exe.tmp -> yt-dlp.exe inside userBinDir with rollback.
      final targetPath = _joinPath(userBinDir, ytDlpBinaryName);
      await _atomicReplaceWindowsSafe(tmpPath: tmpPath, targetPath: targetPath);
      _cachedVersions.remove(targetPath);

      await refreshEnvironment();
      final activatedVersion = _status.ytDlpVersion ?? verifiedVersion;
      final successMsg = '已更新至 yt-dlp $activatedVersion';
      _setUpdateState(isUpdating: false, message: successMsg);
      return YtDlpUpdateResult.updated(
        previousVersion: previousVersion,
        newVersion: activatedVersion,
        message: successMsg,
      );
    } catch (e) {
      await _safeDeleteFile(tmpPath);
      final reason = e is YtDlpException ? e.message : '$e';
      final failMsg = '更新失敗：$reason';
      _setUpdateState(isUpdating: false, message: failMsg);
      return YtDlpUpdateResult.failed(
        currentVersion: previousVersion,
        message: failMsg,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<_ReleaseInfo> _fetchLatestReleaseInfo(HttpClient client) async {
    final text = await _fetchText(
      client,
      _latestReleaseApiUri,
      accept: 'application/vnd.github+json',
    );
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const YtDlpException('GitHub Release 回應格式不正確');
    }

    final tagName = (decoded['tag_name'] as String?)?.trim() ?? '';
    if (tagName.isEmpty) {
      throw const YtDlpException('GitHub Release 缺少 tag_name 欄位');
    }

    final assets = decoded['assets'];
    if (assets is! List) {
      throw const YtDlpException('GitHub Release 缺少 assets 清單');
    }

    Uri? binaryUrl;
    String? assetDigest;
    Uri? sumsUrl;

    for (final item in assets) {
      if (item is! Map) continue;
      final name = (item['name'] as String?)?.trim();
      final downloadRaw = (item['browser_download_url'] as String?)?.trim();
      if (name == null || downloadRaw == null || downloadRaw.isEmpty) continue;
      final uri = Uri.tryParse(downloadRaw);
      if (uri == null) continue;

      if (name == ytDlpBinaryName) {
        binaryUrl = uri;
        final rawDigest = (item['digest'] as String?)?.trim();
        if (rawDigest != null && rawDigest.toLowerCase().startsWith('sha256:')) {
          final hex = rawDigest.substring('sha256:'.length).trim();
          if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
            assetDigest = hex.toLowerCase();
          }
        }
      } else if (name == 'SHA2-256SUMS') {
        sumsUrl = uri;
      }
    }

    if (binaryUrl == null) {
      throw const YtDlpException('最新 Release 中找不到 yt-dlp.exe 檔案');
    }

    return _ReleaseInfo(
      tagName: tagName,
      binaryDownloadUrl: binaryUrl,
      sha256SumsUrl: sumsUrl,
      assetSha256Digest: assetDigest,
    );
  }

  Future<String> _fetchText(
    HttpClient client,
    Uri uri, {
    String accept = '*/*',
  }) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader, 'LuminaAudio');
    request.headers.set(HttpHeaders.acceptHeader, accept);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((_) {});
      throw YtDlpException(
        'HTTP ${response.statusCode} 讀取失敗（${uri.host}）',
      );
    }
    return utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 20));
  }

  Future<void> _downloadFile(
    HttpClient client,
    Uri uri,
    String destinationPath,
  ) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader, 'LuminaAudio');
    request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((_) {});
      throw YtDlpException('下載 yt-dlp.exe 失敗（HTTP ${response.statusCode}）');
    }

    final sink = File(destinationPath).openWrite();
    try {
      await response.pipe(sink).timeout(const Duration(seconds: 120));
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// Parses standard `SHA2-256SUMS` lines (`<64-hex>  <filename>`) for [assetName].
  static String? parseSha256ForAsset(String sumsContent, String assetName) {
    final lowerTarget = assetName.toLowerCase();
    final pattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');
    for (final rawLine in LineSplitter.split(sumsContent)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      final hash = match.group(1)!.toLowerCase();
      final name = match.group(2)!.trim().toLowerCase();
      if (name == lowerTarget ||
          name.endsWith('/$lowerTarget') ||
          name.endsWith('\\$lowerTarget')) {
        return hash;
      }
    }
    return null;
  }

  Future<void> _atomicReplaceWindowsSafe({
    required String tmpPath,
    required String targetPath,
  }) async {
    final bakPath = '$targetPath.bak';
    await _safeDeleteFile(bakPath);

    final targetFile = File(targetPath);
    final tmpFile = File(tmpPath);
    var movedToBackup = false;

    if (targetFile.existsSync()) {
      await targetFile.rename(bakPath);
      movedToBackup = true;
    }

    try {
      await tmpFile.rename(targetPath);
    } catch (_) {
      if (movedToBackup &&
          File(bakPath).existsSync() &&
          !File(targetPath).existsSync()) {
        try {
          await File(bakPath).rename(targetPath);
        } catch (rollbackErr) {
          debugPrint('[YtDlpService] Rollback rename failed: $rollbackErr');
        }
      }
      rethrow;
    }

    await _safeDeleteFile(bakPath);
  }

  Future<void> _safeDeleteFile(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }

  void _setUpdateState({required bool isUpdating, String? message}) {
    _status = _status.copyWith(
      isUpdating: isUpdating,
      lastUpdateMessage: message,
      clearLastUpdateMessage: message == null,
    );
    _safeNotifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Non-Blocking Stream Resolution, Instant Kill on Track Switch, Cache & Preload
  // ---------------------------------------------------------------------------

  /// Returns a valid, non-expired cached stream for [videoId], or `null`.
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

  /// Clears a single cached entry or the entire stream cache.
  ///
  /// Accepts either a raw 11-char `videoId` or a prefixed track ID such as
  /// `ytm:<id>` / `streaming:youtube_music:<id>`.
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

  /// Resolves a direct playable audio stream for YouTube/YouTube Music [videoId].
  ///
  /// - Checks memory cache first unless [bypassCache] is `true`.
  /// - Immediately kills any previously running foreground `yt-dlp.exe` bound
  ///   to an older [playRequestId] BEFORE starting the new process.
  /// - Enforces a hard 12-second timeout (configurable for tests).
  Future<YtDlpResolvedStream> resolveVideo(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) async {
    final trimmedId = videoId.trim();
    if (trimmedId.isEmpty) {
      throw const YtDlpException('無效的 YouTube 影片 ID');
    }

    // Immediately terminate any stale foreground process belonging to another request.
    _killForegroundProcess(exceptRequestId: playRequestId);
    final myEpoch = ++_foregroundEpoch;
    _activeForegroundRequestId = playRequestId;

    if (bypassCache) {
      _streamCache.remove(trimmedId);
    } else {
      final cached = getCachedStream(trimmedId);
      if (cached != null) {
        await _waitIfNotYetAvailable(
          cached,
          myEpoch: myEpoch,
          requestId: playRequestId,
        );
        return cached;
      }
    }

    final ytDlpPath = await ensureAvailable();
    if (_disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }

    final args = buildResolveArgs(
      videoId: trimmedId,
      denoPath: _status.denoPath,
      ffmpegDir: _status.ffmpegDir,
      cookiesFilePath: cookiesFilePath,
      formatSelector: formatSelector,
      extractorArgs: extractorArgs,
      remoteComponents: remoteComponents,
    );

    final capture = await _runProcessCapture(
      executable: ytDlpPath,
      arguments: args,
      timeout: resolveTimeout,
      requestId: playRequestId,
      onHandleCreated: (handle) {
        if (_disposed || myEpoch != _foregroundEpoch) {
          handle.cancel();
          return;
        }
        _foregroundHandle?.cancel();
        _foregroundHandle = handle;
      },
      onHandleFinished: (handle) {
        if (identical(_foregroundHandle, handle)) {
          _foregroundHandle = null;
        }
      },
    );

    if (capture.cancelled || _disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }

    if (capture.timedOut) {
      throw YtDlpException(
        'yt-dlp 串流解析逾時（超過 ${resolveTimeout.inSeconds} 秒）',
        isTimeout: true,
      );
    }

    if (capture.exitCode != 0) {
      final detail = _firstNonEmptyLine(capture.stderr) ?? '未知錯誤';
      throw YtDlpException(
        'yt-dlp 解析失敗（exit ${capture.exitCode}）：$detail',
        exitCode: capture.exitCode,
      );
    }

    final resolved = parseResolvedStreamJson(
      videoId: trimmedId,
      rawStdout: capture.stdout,
      now: _clock(),
    );
    await _waitIfNotYetAvailable(
      resolved,
      myEpoch: myEpoch,
      requestId: playRequestId,
    );
    _storeCache(resolved);
    return resolved;
  }

  Future<void> _waitIfNotYetAvailable(
    YtDlpResolvedStream stream, {
    required int myEpoch,
    required int requestId,
  }) async {
    final availableAt = stream.availableAt;
    if (availableAt == null) return;
    final delay = availableAt.toUtc().difference(_clock().toUtc());
    if (delay <= Duration.zero) return;
    final clamped = delay > maxAvailableAtWait ? maxAvailableAtWait : delay;
    await _waitForAvailability(
      clamped,
      myEpoch: myEpoch,
      requestId: requestId,
    );
  }

  Future<void> _waitForAvailability(
    Duration delay, {
    required int myEpoch,
    required int requestId,
  }) async {
    if (delay <= Duration.zero) return;
    if (_disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }

    final handle = _AvailabilityWaitHandle(requestId: requestId);
    _foregroundWaitHandle?.cancel();
    _foregroundWaitHandle = handle;

    final timerCompleter = Completer<void>();
    final timer = Timer(delay, () {
      if (!timerCompleter.isCompleted) {
        timerCompleter.complete();
      }
    });

    try {
      await Future.any<void>(<Future<void>>[
        timerCompleter.future,
        handle.abortFuture,
      ]);
    } finally {
      timer.cancel();
      if (identical(_foregroundWaitHandle, handle)) {
        _foregroundWaitHandle = null;
      }
    }

    if (handle.cancelled || _disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }
  }

  /// Low-priority background preload into the shared memory cache.
  ///
  /// - Skips if already cached or currently preloading the same [videoId].
  /// - Cancels any superseded preload process.
  /// - NEVER kills an active foreground resolution.
  /// - Swallows all errors cleanly with debug logging.
  Future<YtDlpResolvedStream?> preloadVideo(
    String videoId, {
    String? cookiesFilePath,
  }) async {
    final trimmedId = videoId.trim();
    if (trimmedId.isEmpty || _disposed) return null;

    final cached = getCachedStream(trimmedId);
    if (cached != null) return cached;

    if (_preloadingVideoId == trimmedId && _preloadFuture != null) {
      return _preloadFuture;
    }

    // Cancel any older preload process without touching foreground playback.
    _killPreloadProcess();
    final myPreloadEpoch = ++_preloadEpoch;
    _preloadingVideoId = trimmedId;

    final future = () async {
      try {
        if (!_initialized) {
          await initialize();
        }
        if (_disposed || myPreloadEpoch != _preloadEpoch) return null;
        final ytDlpPath = _status.ytDlpPath;
        if (ytDlpPath == null || !File(ytDlpPath).existsSync()) {
          return null;
        }

        final args = buildResolveArgs(
          videoId: trimmedId,
          denoPath: _status.denoPath,
          ffmpegDir: _status.ffmpegDir,
          cookiesFilePath: cookiesFilePath,
        );

        final capture = await _runProcessCapture(
          executable: ytDlpPath,
          arguments: args,
          timeout: resolveTimeout,
          onHandleCreated: (handle) {
            if (_disposed || myPreloadEpoch != _preloadEpoch) {
              handle.cancel();
              return;
            }
            _preloadHandle?.cancel();
            _preloadHandle = handle;
          },
          onHandleFinished: (handle) {
            if (identical(_preloadHandle, handle)) {
              _preloadHandle = null;
            }
          },
        );

        if (_disposed ||
            myPreloadEpoch != _preloadEpoch ||
            capture.cancelled ||
            capture.timedOut ||
            capture.exitCode != 0) {
          return null;
        }

        final resolved = parseResolvedStreamJson(
          videoId: trimmedId,
          rawStdout: capture.stdout,
          now: _clock(),
        );
        _storeCache(resolved);
        return resolved;
      } catch (e) {
        debugPrint('[YtDlpService] Preload skipped for $trimmedId: $e');
        return null;
      } finally {
        if (myPreloadEpoch == _preloadEpoch) {
          _preloadingVideoId = null;
          _preloadFuture = null;
        }
      }
    }();

    _preloadFuture = future;
    return future;
  }

  /// Parses `yt-dlp -j` JSON stdout into a [YtDlpResolvedStream].
  static YtDlpResolvedStream parseResolvedStreamJson({
    required String videoId,
    required String rawStdout,
    required DateTime now,
  }) {
    final trimmed = rawStdout.trim();
    if (trimmed.isEmpty) {
      throw const YtDlpException('yt-dlp 未回傳任何串流資訊');
    }

    Map<String, dynamic>? root;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        root = decoded;
      }
    } catch (_) {
      // Fallback: yt-dlp occasionally emits multiple JSON lines; find the first JSON object.
      for (final line in LineSplitter.split(trimmed)) {
        final candidate = line.trim();
        if (!candidate.startsWith('{')) continue;
        try {
          final decoded = jsonDecode(candidate);
          if (decoded is Map<String, dynamic>) {
            root = decoded;
            break;
          }
        } catch (_) {}
      }
    }

    if (root == null) {
      throw const YtDlpException('yt-dlp JSON 解析失敗');
    }

    Map<String, dynamic>? fallbackFormat;
    var url = _nonEmptyString(root['url']);
    if (url == null) {
      fallbackFormat =
          _pickAudioFormatFromList(root['requested_formats']) ??
          _pickAudioFormatFromList(root['formats']);
      url = _nonEmptyString(fallbackFormat?['url']);
    }

    if (url == null) {
      throw const YtDlpException('yt-dlp 回傳結果中缺少可播放的音訊串流網址');
    }

    final mergedHeaders = <String, String>{};
    _copyStringHeaders(root['http_headers'], mergedHeaders);
    _copyStringHeaders(fallbackFormat?['http_headers'], mergedHeaders);
    if (mergedHeaders.isEmpty && fallbackFormat == null) {
      final reqFallback = _pickAudioFormatFromList(root['requested_formats']);
      _copyStringHeaders(reqFallback?['http_headers'], mergedHeaders);
    }

    final acodec =
        _nonEmptyCodec(fallbackFormat?['acodec']) ??
        _nonEmptyCodec(root['acodec']);
    final ext =
        _nonEmptyString(fallbackFormat?['ext']) ?? _nonEmptyString(root['ext']);
    final asr =
        _parseInt(fallbackFormat?['asr']) ?? _parseInt(root['asr']);
    final abr =
        _parseDouble(fallbackFormat?['abr']) ??
        _parseDouble(root['abr']) ??
        _parseDouble(fallbackFormat?['tbr']) ??
        _parseDouble(root['tbr']);
    final duration =
        _parseDouble(root['duration']) ??
        _parseDouble(fallbackFormat?['duration']);
    final parsedUri = Uri.tryParse(url);
    final contentLength =
        _parseInt(fallbackFormat?['filesize']) ??
        _parseInt(root['filesize']) ??
        _parseInt(fallbackFormat?['filesize_approx']) ??
        _parseInt(root['filesize_approx']) ??
        _parseInt(parsedUri?.queryParameters['clen']);
    final mimeType = _inferMimeType(
      urlMimeParam: parsedUri?.queryParameters['mime'],
      acodec: acodec,
      ext: ext,
    );
    final rawThumbnail = _nonEmptyString(root['thumbnail']);
    final thumbnail = rawThumbnail == null
        ? null
        : (upgradeStreamingCoverUrl(rawThumbnail, targetSize: 1200) ??
            rawThumbnail);

    final rawLoudness =
        _parseDouble(fallbackFormat?['loudness']) ??
        _parseDouble(root['loudness']) ??
        _parseDouble(fallbackFormat?['loudnessDb']) ??
        _parseDouble(root['loudnessDb']) ??
        _parseDouble(root['loudness_db']);
    final loudnessDb =
        (rawLoudness != null && rawLoudness.isFinite) ? rawLoudness : null;

    final expiresAt = _parseStreamExpiry(url, now);
    final availableAt =
        _parseAvailableAt(fallbackFormat?['available_at']) ??
        _parseAvailableAt(root['available_at']);

    return YtDlpResolvedStream(
      videoId: videoId,
      url: url,
      httpHeaders: Map<String, String>.unmodifiable(mergedHeaders),
      acodec: acodec,
      ext: ext,
      sampleRateHz: asr,
      bitrateKbps: abr,
      durationSeconds: duration,
      contentLength: contentLength,
      mimeType: mimeType,
      thumbnailUrl: thumbnail,
      loudnessDb: loudnessDb,
      expiresAt: expiresAt,
      availableAt: availableAt,
    );
  }

  static String? _inferMimeType({
    String? urlMimeParam,
    String? acodec,
    String? ext,
  }) {
    final lowerCodec = acodec?.trim().toLowerCase() ?? '';
    final lowerExt = ext?.trim().toLowerCase() ?? '';
    final rawUrlMime = urlMimeParam?.trim().toLowerCase() ?? '';
    if (rawUrlMime.startsWith('audio/')) {
      if (lowerCodec.isNotEmpty &&
          lowerCodec != 'none' &&
          !rawUrlMime.contains('codecs=')) {
        return '$rawUrlMime; codecs="$lowerCodec"';
      }
      return rawUrlMime;
    }
    if (lowerExt == 'webm' || lowerCodec.contains('opus')) {
      return lowerExt == 'ogg' || lowerExt == 'oga'
          ? 'audio/ogg; codecs="opus"'
          : 'audio/webm; codecs="opus"';
    }
    if (lowerExt == 'm4a' ||
        lowerExt == 'mp4' ||
        lowerCodec.startsWith('mp4a')) {
      return lowerCodec.isNotEmpty && lowerCodec != 'none'
          ? 'audio/mp4; codecs="$lowerCodec"'
          : 'audio/mp4';
    }
    if (lowerExt == 'aac' || lowerCodec == 'aac') return 'audio/aac';
    if (lowerExt == 'mp3' || lowerCodec.contains('mp3')) return 'audio/mpeg';
    if (lowerExt == 'flac' || lowerCodec.contains('flac')) return 'audio/flac';
    if (lowerExt == 'ogg' || lowerExt == 'oga' || lowerCodec.contains('vorbis')) {
      return 'audio/ogg';
    }
    if (lowerExt == 'wav' || lowerCodec.contains('pcm')) return 'audio/wav';
    return null;
  }

  static DateTime? _parseAvailableAt(Object? raw) {
    final seconds = _parseDouble(raw);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (seconds * 1000).round(),
      isUtc: true,
    );
  }

  static Map<String, dynamic>? _pickAudioFormatFromList(Object? rawList) {
    if (rawList is! List) return null;
    Map<String, dynamic>? firstWithUrl;
    Map<String, dynamic>? bestAudio;
    double bestAbr = -1;

    for (final entry in rawList) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final url = _nonEmptyString(map['url']);
      if (url == null) continue;
      firstWithUrl ??= map;

      final acodec = _nonEmptyCodec(map['acodec']);
      if (acodec == null) continue;

      final vcodec = _nonEmptyString(map['vcodec'])?.toLowerCase();
      final isAudioOnly = vcodec == null || vcodec == 'none';
      final abr = _parseDouble(map['abr']) ?? _parseDouble(map['tbr']) ?? 0;

      if (bestAudio == null ||
          (isAudioOnly &&
              (_nonEmptyString(bestAudio['vcodec'])?.toLowerCase() != 'none')) ||
          (isAudioOnly ==
                  (_nonEmptyString(bestAudio['vcodec'])?.toLowerCase() ==
                      'none') &&
              abr > bestAbr)) {
        bestAudio = map;
        bestAbr = abr;
      }
    }

    return bestAudio ?? firstWithUrl;
  }

  static void _copyStringHeaders(Object? raw, Map<String, String> target) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final k = entry.key?.toString().trim() ?? '';
      final v = entry.value?.toString().trim() ?? '';
      if (k.isNotEmpty && v.isNotEmpty) {
        target[k] = v;
      }
    }
  }

  static DateTime _parseStreamExpiry(String url, DateTime now) {
    final uri = Uri.tryParse(url);
    final rawExpire = uri?.queryParameters['expire'];
    if (rawExpire != null) {
      final seconds = int.tryParse(rawExpire.trim());
      if (seconds != null && seconds > 0) {
        return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      }
    }
    return now.add(defaultStreamTtl);
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _nonEmptyCodec(Object? value) {
    final s = _nonEmptyString(value);
    if (s == null || s.toLowerCase() == 'none') return null;
    return s;
  }

  static int? _parseInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static double? _parseDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  // ---------------------------------------------------------------------------
  // FFmpeg WAV Fallback Proxy Integration
  // ---------------------------------------------------------------------------

  Future<void> _ensureFfmpegReady() async {
    if (!_initialized) {
      await initialize();
    }
    if (!_status.isFfmpegAvailable) {
      throw const YtDlpException(
        '未偵測到 ffmpeg.exe，無法轉碼此音訊格式',
      );
    }
  }

  /// Opens a local lossless 24-bit WAV streaming URL (`http://127.0.0.1:<port>/stream/<token>.wav`)
  /// backed by `ffmpeg.exe` for codecs not natively decoded by Symphonia.
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

  /// Opens a local DASH MPD loopback streaming URL (`http://127.0.0.1:<port>/stream/<token>.flac`
  /// or `.wav`) backed by `ffmpeg.exe` for DASH audio manifests.
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

  // ---------------------------------------------------------------------------
  // Process Cancellation & Cleanup
  // ---------------------------------------------------------------------------

  /// Immediately kills active foreground `yt-dlp.exe` AND active `ffmpeg.exe`
  /// transcoding processes whose request ID does not match [exceptRequestId].
  void cancelPlaybackProcesses({int? exceptRequestId}) {
    _killForegroundProcess(exceptRequestId: exceptRequestId);
    _ffmpegProxy?.cancel(exceptRequestId: exceptRequestId);
  }

  /// Stops any active FFmpeg WAV/FLAC transcoding proxy process whose request
  /// ID differs from [exceptRequestId] (or unconditionally when null), without
  /// creating a new loopback server or disturbing background preloads.
  void stopFfmpegProxy({int? exceptRequestId}) =>
      _ffmpegProxy?.cancel(exceptRequestId: exceptRequestId);

  /// Immediately cancels the active foreground `yt-dlp.exe` process or
  /// `available_at` wait bound to [playRequestId] without disturbing newer requests.
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

  /// Stops all active foreground, preload, and FFmpeg proxy child processes
  /// and waits briefly for OS process termination.
  Future<void> stopAll({Duration waitTimeout = const Duration(seconds: 2)}) async {
    _killForegroundProcess();
    _killPreloadProcess();

    final ffmpegStop = _ffmpegProxy?.stopAll(waitTimeout: waitTimeout);

    final remaining = List<Process>.from(_runningProcesses);
    for (final proc in remaining) {
      try {
        proc.kill();
      } catch (_) {}
    }

    if (remaining.isNotEmpty) {
      try {
        await Future.wait(
          remaining.map((p) => p.exitCode.catchError((_) => -1)),
        ).timeout(waitTimeout);
      } on TimeoutException {
        // Best-effort wait; kill signals already dispatched.
      }
    }

    if (ffmpegStop != null) {
      await ffmpegStop;
    }
  }

  Future<_ProcessCapture> _runProcessCapture({
    required String executable,
    required List<String> arguments,
    required Duration timeout,
    int? requestId,
    void Function(_ManagedProcessHandle handle)? onHandleCreated,
    void Function(_ManagedProcessHandle handle)? onHandleFinished,
  }) async {
    final process = await _processStarter(
      executable,
      arguments,
      runInShell: false,
    );

    _runningProcesses.add(process);
    unawaited(
      process.exitCode.then(
        (_) => _runningProcesses.remove(process),
        onError: (_) => _runningProcesses.remove(process),
      ),
    );

    final handle = _ManagedProcessHandle(process, requestId: requestId);
    onHandleCreated?.call(handle);

    const maxStdoutBytes = 64 * 1024 * 1024;
    const maxStderrBytes = 64 * 1024;

    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    final stdoutSub = process.stdout.listen(
      (chunk) {
        if (stdoutBytes.length < maxStdoutBytes) {
          final room = maxStdoutBytes - stdoutBytes.length;
          stdoutBytes.addAll(
            chunk.length <= room ? chunk : chunk.sublist(0, room),
          );
        }
      },
      onDone: () {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      onError: (_) {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      cancelOnError: true,
    );

    final stderrSub = process.stderr.listen(
      (chunk) {
        if (stderrBytes.length < maxStderrBytes) {
          final room = maxStderrBytes - stderrBytes.length;
          stderrBytes.addAll(
            chunk.length <= room ? chunk : chunk.sublist(0, room),
          );
        }
      },
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      onError: (_) {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      cancelOnError: true,
    );

    final timer = Timer(timeout, () {
      handle.markTimedOut();
    });

    try {
      if (handle.cancelled || handle.timedOut) {
        return _ProcessCapture(
          exitCode: -1,
          stdout: '',
          stderr: '',
          cancelled: handle.cancelled,
          timedOut: handle.timedOut,
        );
      }

      final exitCode = await Future.any<int>(<Future<int>>[
        process.exitCode.catchError((_) => -1),
        handle.abortFuture.then((_) => -1),
      ]);

      if (!handle.cancelled && !handle.timedOut) {
        try {
          await Future.wait(<Future<void>>[
            stdoutDone.future,
            stderrDone.future,
          ]).timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Proceed with collected output.
        }
      }

      return _ProcessCapture(
        exitCode: exitCode,
        stdout: utf8.decode(stdoutBytes, allowMalformed: true),
        stderr: utf8.decode(stderrBytes, allowMalformed: true),
        cancelled: handle.cancelled,
        timedOut: handle.timedOut,
      );
    } finally {
      timer.cancel();
      if (handle.cancelled || handle.timedOut) {
        unawaited(stdoutSub.cancel().catchError((_) {}));
        unawaited(stderrSub.cancel().catchError((_) {}));
      }
      onHandleFinished?.call(handle);
    }
  }

  // ---------------------------------------------------------------------------
  // Third-Party Licenses Reader
  // ---------------------------------------------------------------------------

  /// Reads bundled `THIRD_PARTY_LICENSES.txt` (from `<executable_dir>` or dev
  /// fallback `app/windows/vendor/bin/THIRD_PARTY_LICENSES.txt`), falling back
  /// to a concise license summary when the file has not yet been generated.
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

  String? _resolveLicenseFilePath() {
    final candidates = <String>[
      if (_injectedLicenseFilePath != null &&
          _injectedLicenseFilePath.trim().isNotEmpty)
        _injectedLicenseFilePath.trim(),
      _joinPath(File(Platform.resolvedExecutable).parent.path, licenseFileName),
      if (_injectedBundledBinDir != null &&
          _injectedBundledBinDir.trim().isNotEmpty) ...<String>[
        _joinPath(Directory(_injectedBundledBinDir.trim()).parent.path, licenseFileName),
        _joinPath(_injectedBundledBinDir.trim(), licenseFileName),
      ],
    ];

    // Dev-mode fallbacks relative to CWD (when running `flutter test` / `flutter run`).
    final cwd = Directory.current.path;
    candidates.addAll(<String>[
      _joinPath(cwd, 'windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin${Platform.pathSeparator}$licenseFileName'),
      _joinPath(cwd, 'app${Platform.pathSeparator}windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin${Platform.pathSeparator}$licenseFileName'),
    ]);

    for (final candidate in candidates) {
      try {
        if (File(candidate).existsSync()) {
          return candidate;
        }
      } catch (_) {}
    }
    return null;
  }

  static const String _fallbackLicenseSummary = '''
Lumina Audio — 第三方開源元件授權資訊

本應用程式於 Windows 發行版本中搭配以下開源命令列工具以提供串流解析與無損轉碼功能：

1. yt-dlp
   授權條款：The Unlicense（公眾領域）及 PyInstaller 內嵌第三方授權
   專案網址：https://github.com/yt-dlp/yt-dlp

2. Deno
   授權條款：MIT License
   專案網址：https://github.com/denoland/deno

3. FFmpeg (Windows x64 LGPL Build)
   授權條款：GNU Lesser General Public License (LGPL)
   專案網址：https://ffmpeg.org/

提示：尚未在本機安裝目錄找到完整的 THIRD_PARTY_LICENSES.txt。
於開發環境中可執行 scripts/prepare_release_deps.ps1 下載完整相依執行檔與授權全文。
''';

  // ---------------------------------------------------------------------------
  // Path Resolution Helpers
  // ---------------------------------------------------------------------------

  String _resolveUserBinDir() {
    if (_injectedUserBinDir != null && _injectedUserBinDir.trim().isNotEmpty) {
      return _injectedUserBinDir.trim();
    }
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData != null && localAppData.isNotEmpty) {
      return _joinPath(_joinPath(localAppData, 'LuminaAudio'), 'bin');
    }
    final userProfile = Platform.environment['USERPROFILE']?.trim();
    if (userProfile != null && userProfile.isNotEmpty) {
      return _joinPath(
        _joinPath(
          _joinPath(_joinPath(userProfile, 'AppData'), 'Local'),
          'LuminaAudio',
        ),
        'bin',
      );
    }
    return _joinPath(Directory.systemTemp.path, 'LuminaAudio_bin');
  }

  String _resolveBundledBinDir() {
    if (_injectedBundledBinDir != null &&
        _injectedBundledBinDir.trim().isNotEmpty) {
      return _injectedBundledBinDir.trim();
    }
    // Always anchored to Platform.resolvedExecutable — NEVER CWD.
    var dir = File(Platform.resolvedExecutable).parent;
    final exeBin = _joinPath(dir.path, 'bin');
    if (File(_joinPath(exeBin, ytDlpBinaryName)).existsSync() ||
        File(_joinPath(exeBin, ffmpegBinaryName)).existsSync()) {
      return exeBin;
    }
    // In local Debug/dev runner builds where `<exeDir>\bin` has not been
    // populated by CMake install, walk up ancestors from the executable only.
    for (var i = 0; i < 6; i++) {
      final vendorBin = _joinPath(
        dir.path,
        'windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin',
      );
      if (File(_joinPath(vendorBin, ytDlpBinaryName)).existsSync() ||
          File(_joinPath(vendorBin, ffmpegBinaryName)).existsSync()) {
        return vendorBin;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return exeBin;
  }

  static String _joinPath(String base, String child) {
    final sep = Platform.pathSeparator;
    final cleanBase = base.replaceAll(RegExp(r'[/\\]+$'), '');
    final cleanChild = child.replaceAll(RegExp(r'^[/\\]+'), '');
    if (cleanBase.isEmpty) return cleanChild;
    return '$cleanBase$sep$cleanChild';
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

class _DetectedBinary {
  final String? path;
  final YtDlpBinarySource source;
  final String? version;

  const _DetectedBinary({
    required this.path,
    required this.source,
    required this.version,
  });
}

class _ReleaseInfo {
  final String tagName;
  final Uri binaryDownloadUrl;
  final Uri? sha256SumsUrl;
  final String? assetSha256Digest;

  const _ReleaseInfo({
    required this.tagName,
    required this.binaryDownloadUrl,
    this.sha256SumsUrl,
    this.assetSha256Digest,
  });
}

class _ProcessCapture {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool cancelled;
  final bool timedOut;

  const _ProcessCapture({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.cancelled,
    required this.timedOut,
  });
}

class _ManagedProcessHandle {
  final Process process;
  final int? requestId;
  final Completer<void> _abortCompleter = Completer<void>();

  bool _cancelled = false;
  bool _timedOut = false;

  _ManagedProcessHandle(this.process, {this.requestId});

  bool get cancelled => _cancelled;
  bool get timedOut => _timedOut;
  Future<void> get abortFuture => _abortCompleter.future;

  void cancel() {
    if (_cancelled || _timedOut) return;
    _cancelled = true;
    _kill();
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
  }

  void markTimedOut() {
    if (_cancelled || _timedOut) return;
    _timedOut = true;
    _kill();
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
  }

  void _kill() {
    try {
      process.kill();
    } catch (_) {}
  }
}

class _AvailabilityWaitHandle {
  final int requestId;
  final Completer<void> _abortCompleter = Completer<void>();
  bool _cancelled = false;

  _AvailabilityWaitHandle({required this.requestId});

  bool get cancelled => _cancelled;
  Future<void> get abortFuture => _abortCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
  }
}
