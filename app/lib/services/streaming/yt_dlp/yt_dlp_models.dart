part of '../yt_dlp_service.dart';

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
