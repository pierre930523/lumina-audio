import 'audio_format.dart';
import 'playback_state.dart';

/// Four-tier dynamic audio quality classification.
///
/// Priority order (high -> low): [hiRes] > [lossless] > [hqLossy] > [standard].
enum AudioQualityTier {
  hiRes,
  lossless,
  hqLossy,
  standard;

  String get code => switch (this) {
    AudioQualityTier.hiRes => 'HI_RES',
    AudioQualityTier.lossless => 'LOSSLESS',
    AudioQualityTier.hqLossy => 'HQ_LOSSY',
    AudioQualityTier.standard => 'STANDARD',
  };

  String get badgeLabel => switch (this) {
    AudioQualityTier.hiRes => 'Hi-Res',
    AudioQualityTier.lossless => 'LOSSLESS',
    AudioQualityTier.hqLossy => 'HQ',
    AudioQualityTier.standard => 'SD',
  };

  String get displayName => switch (this) {
    AudioQualityTier.hiRes => 'Hi-Res 高解析無損',
    AudioQualityTier.lossless => 'CD 無損音質',
    AudioQualityTier.hqLossy => '高音質有損 (HQ)',
    AudioQualityTier.standard => '標準／省流量 (SD)',
  };

  bool get isLossless =>
      this == AudioQualityTier.hiRes || this == AudioQualityTier.lossless;
}

/// Normalized metadata snapshot used by [getAudioQualityTier] and
/// [classifyAudioQuality].
///
/// [sampleRate] accepts either Hz (e.g. `44100`, `96000`, `2822400`) or kHz
/// (e.g. `44.1`, `48`, `96`): values `<= 1000` are treated as kHz and
/// converted to Hz via `* 1000`.
class AudioQualityMetadata {
  final String? format;
  final String? codec;
  final num? bitrateKbps;
  final num? sampleRate;
  final int? bitDepth;
  final bool isDsd;
  final String? providerName;
  final bool isHighQualityStream;

  const AudioQualityMetadata({
    this.format,
    this.codec,
    this.bitrateKbps,
    this.sampleRate,
    this.bitDepth,
    this.isDsd = false,
    this.providerName,
    this.isHighQualityStream = false,
  });

  factory AudioQualityMetadata.fromTrackInfo(
    TrackInfo track, {
    num? bitrateKbps,
  }) {
    return AudioQualityMetadata(
      format: track.format.codec.name,
      codec: track.format.codec.name,
      bitrateKbps: bitrateKbps ?? track.format.bitrateKbps,
      sampleRate: track.format.sampleRateHz,
      bitDepth: track.format.bitDepth,
      isDsd: track.format.isDsd,
      providerName: track.providerName,
    );
  }
}

const Set<String> _dsdFormats = {'dsd', 'dsf', 'dff', 'dsdiff'};

const Set<String> _losslessFormats = {
  'flac',
  'alac',
  'wav',
  'wave',
  'aiff',
  'aif',
  'pcm',
  'lpcm',
};

const Set<String> _lossyFormats = {
  'mp3',
  'mpeg',
  'aac',
  'm4a',
  'mp4a',
  'opus',
  'ogg',
  'vorbis',
  'wma',
  'webm',
};

const List<String> _streamingProviderTokens = [
  'youtube',
  'yt music',
  'spotify',
  'apple',
  'qobuz',
  'tidal',
  'deezer',
  'streaming',
];

String? _normalizeToken(String? raw) {
  if (raw == null) return null;
  var value = raw.trim().toLowerCase();
  if (value.isEmpty) return null;
  if (value.startsWith('audio/')) {
    value = value.substring(6).trim();
  }
  final semi = value.indexOf(';');
  if (semi >= 0) {
    value = value.substring(0, semi).trim();
  }
  if (value.startsWith('mp4a')) return 'aac';
  if (value.startsWith('pcm')) return 'pcm';
  if (value.startsWith('lpcm')) return 'lpcm';
  return value.isEmpty ? null : value;
}

bool _isDsdToken(String? token) {
  if (token == null) return false;
  return _dsdFormats.contains(token) || token.startsWith('dsd');
}

bool _isLosslessToken(String? token) =>
    token != null && _losslessFormats.contains(token);

bool _isLossyToken(String? token) =>
    token != null && _lossyFormats.contains(token);

bool _isStreamingProvider(String? providerName) {
  if (providerName == null) return false;
  final lower = providerName.trim().toLowerCase();
  if (lower.isEmpty) return false;
  return _streamingProviderTokens.any(lower.contains);
}

int _normalizeSampleRateHz(num? sampleRate) {
  if (sampleRate == null || sampleRate.isNaN || !sampleRate.isFinite) {
    return 0;
  }
  if (sampleRate <= 0) return 0;
  final hz = sampleRate <= 1000 ? sampleRate * 1000 : sampleRate;
  return hz.round();
}

num? _asNum(Object? value) {
  if (value is num) {
    return (value.isNaN || !value.isFinite) ? null : value;
  }
  if (value is String) {
    final parsed = num.tryParse(value.trim());
    return (parsed == null || parsed.isNaN || !parsed.isFinite) ? null : parsed;
  }
  return null;
}

int? _asInt(Object? value) => _asNum(value)?.round();

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.trim().toLowerCase();
    return lower == 'true' || lower == '1';
  }
  return false;
}

String? _asCodecOrFormatString(Object? value) {
  if (value is AudioCodec) return value.name;
  if (value is String) return value;
  return null;
}

/// Pure classifier accepting [TrackInfo], [AudioQualityMetadata], [AudioFormat],
/// a metadata [Map], or `null`.
AudioQualityTier getAudioQualityTier(Object? trackInfo) {
  if (trackInfo == null) return AudioQualityTier.standard;

  if (trackInfo is TrackInfo) {
    return classifyAudioQuality(
      format: trackInfo.format.codec.name,
      codec: trackInfo.format.codec.name,
      bitrateKbps: trackInfo.format.bitrateKbps,
      sampleRate: trackInfo.format.sampleRateHz,
      bitDepth: trackInfo.format.bitDepth,
      isDsd: trackInfo.format.isDsd,
      providerName: trackInfo.providerName,
    );
  }

  if (trackInfo is AudioQualityMetadata) {
    return classifyAudioQuality(
      format: trackInfo.format,
      codec: trackInfo.codec,
      bitrateKbps: trackInfo.bitrateKbps,
      sampleRate: trackInfo.sampleRate,
      bitDepth: trackInfo.bitDepth,
      isDsd: trackInfo.isDsd,
      providerName: trackInfo.providerName,
      isHighQualityStream: trackInfo.isHighQualityStream,
    );
  }

  if (trackInfo is AudioFormat) {
    return classifyAudioQuality(
      format: trackInfo.codec.name,
      codec: trackInfo.codec.name,
      bitrateKbps: trackInfo.bitrateKbps,
      sampleRate: trackInfo.sampleRateHz,
      bitDepth: trackInfo.bitDepth,
      isDsd: trackInfo.isDsd,
    );
  }

  if (trackInfo is Map) {
    final rawFormat = trackInfo['format'];
    final embeddedFormat = rawFormat is AudioFormat ? rawFormat : null;
    final rawBitrateKbps =
        _asNum(trackInfo['bitrateKbps']) ??
        _asNum(trackInfo['bitrate']) ??
        _asNum(trackInfo['bitrate_kbps']);
    final rawBitrateBps =
        _asNum(trackInfo['bitrateBps']) ?? _asNum(trackInfo['bitrate_bps']);
    final bitrateKbps =
        rawBitrateKbps ??
        (rawBitrateBps != null && rawBitrateBps > 0
            ? rawBitrateBps / 1000.0
            : embeddedFormat?.bitrateKbps);

    return classifyAudioQuality(
      format: _asCodecOrFormatString(rawFormat) ?? embeddedFormat?.codec.name,
      codec:
          _asCodecOrFormatString(trackInfo['codec']) ??
          embeddedFormat?.codec.name,
      bitrateKbps: bitrateKbps,
      sampleRate:
          _asNum(trackInfo['sampleRate']) ??
          _asNum(trackInfo['sampleRateHz']) ??
          _asNum(trackInfo['sample_rate_hz']) ??
          _asNum(trackInfo['sample_rate']) ??
          embeddedFormat?.sampleRateHz,
      bitDepth:
          _asInt(trackInfo['bitDepth']) ??
          _asInt(trackInfo['bit_depth']) ??
          embeddedFormat?.bitDepth,
      isDsd:
          _asBool(trackInfo['isDsd']) ||
          _asBool(trackInfo['is_dsd']) ||
          (embeddedFormat?.isDsd ?? false),
      providerName:
          (trackInfo['providerName'] ??
                  trackInfo['provider_name'] ??
                  trackInfo['provider'])
              ?.toString(),
      isHighQualityStream:
          _asBool(trackInfo['isHighQualityStream']) ||
          _asBool(trackInfo['is_high_quality_stream']),
    );
  }

  return AudioQualityTier.standard;
}

/// Classifies audio quality strictly following:
/// `HI_RES` > `LOSSLESS` > `HQ_LOSSY` > `STANDARD`.
AudioQualityTier classifyAudioQuality({
  String? format,
  String? codec,
  num? bitrateKbps,
  num? sampleRate,
  int? bitDepth,
  bool isDsd = false,
  String? providerName,
  bool isHighQualityStream = false,
}) {
  final codecToken = _normalizeToken(codec);
  final formatToken = _normalizeToken(format);

  // 1. HI_RES: DSD always qualifies first.
  if (isDsd || _isDsdToken(codecToken) || _isDsdToken(formatToken)) {
    return AudioQualityTier.hiRes;
  }

  // Prefer explicit codec over container format when both are supplied
  // (e.g. format: 'm4a', codec: 'alac' -> lossless ALAC).
  final effectiveToken =
      (_isLosslessToken(codecToken) || _isLossyToken(codecToken))
          ? codecToken
          : formatToken ?? codecToken;

  final sampleRateHz = _normalizeSampleRateHz(sampleRate);
  final effectiveBitDepth = (bitDepth != null && bitDepth > 0) ? bitDepth : 0;

  // 2. Lossless formats -> HI_RES vs LOSSLESS vs incomplete metadata fallback.
  if (_isLosslessToken(effectiveToken)) {
    if (effectiveBitDepth >= 24 || sampleRateHz > 44100) {
      return AudioQualityTier.hiRes;
    }
    if ((effectiveBitDepth > 0 || sampleRateHz > 0) &&
        effectiveBitDepth <= 16 &&
        sampleRateHz <= 44100) {
      return AudioQualityTier.lossless;
    }
    if (effectiveBitDepth > 16 &&
        effectiveBitDepth < 24 &&
        sampleRateHz <= 44100) {
      return AudioQualityTier.lossless;
    }
    return AudioQualityTier.standard;
  }

  // 3. Lossy formats -> explicit bitrate takes strict precedence over fallbacks.
  if (_isLossyToken(effectiveToken)) {
    final validBitrate =
        bitrateKbps != null &&
        !bitrateKbps.isNaN &&
        bitrateKbps.isFinite &&
        bitrateKbps > 0;
    if (validBitrate) {
      return bitrateKbps >= 256
          ? AudioQualityTier.hqLossy
          : AudioQualityTier.standard;
    }

    // Fallback ONLY when explicit bitrate is absent or <= 0.
    if (isHighQualityStream) {
      return AudioQualityTier.hqLossy;
    }
    if (effectiveToken == 'opus' && sampleRateHz >= 48000) {
      return AudioQualityTier.hqLossy;
    }
    if (_isStreamingProvider(providerName) &&
        (effectiveToken == 'opus' ||
            effectiveToken == 'aac' ||
            effectiveToken == 'm4a' ||
            effectiveToken == 'webm') &&
        sampleRateHz >= 48000) {
      return AudioQualityTier.hqLossy;
    }
    return AudioQualityTier.standard;
  }

  // 4. Incomplete or unknown metadata fallback.
  return AudioQualityTier.standard;
}

int _dsdMultiplier(int sampleRateHz) {
  if (sampleRateHz <= 0) return 64;
  if (sampleRateHz % 48000 == 0 && sampleRateHz % 44100 != 0) {
    final mult48 = sampleRateHz ~/ 48000;
    return mult48 > 0 ? mult48 : 64;
  }
  final mult44 = (sampleRateHz / 44100.0).round();
  return mult44 > 0 ? mult44 : 64;
}

bool _isDsdFormat(AudioFormat format) =>
    format.isDsd ||
    format.codec == AudioCodec.dsf ||
    format.codec == AudioCodec.dsdiff;

String _formatWithCommas(int value) {
  final raw = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final remaining = raw.length - i;
    if (i > 0 && remaining % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(raw[i]);
  }
  return buffer.toString();
}

/// Formats the codec name for Audio Info Popover / Now Playing (e.g. `FLAC`,
/// `Opus`, `AAC`, `DSD64`).
String formatAudioCodecName(AudioFormat format) {
  if (_isDsdFormat(format)) {
    return 'DSD${_dsdMultiplier(format.sampleRateHz)}';
  }
  return format.codec.displayName;
}

/// Formats sample rate and bit depth (e.g. `24-bit / 96 kHz`,
/// `16-bit / 44.1 kHz`, `1-bit / 2.8 MHz (DSD64)`).
String formatAudioSampleSpec(AudioFormat format) {
  if (_isDsdFormat(format)) {
    final dsdName = 'DSD${_dsdMultiplier(format.sampleRateHz)}';
    if (format.sampleRateHz > 0) {
      final mhz = (format.sampleRateHz / 1000000.0).toStringAsFixed(1);
      return '1-bit / $mhz MHz ($dsdName)';
    }
    return '1-bit ($dsdName)';
  }

  final hasBitDepth = format.bitDepth > 0;
  final hasSampleRate = format.sampleRateHz > 0;
  if (hasBitDepth && hasSampleRate) {
    return '${format.bitDepth}-bit / ${AudioFormat.formatSampleRateKhz(format.sampleRateHz)}';
  }
  if (hasSampleRate) {
    return AudioFormat.formatSampleRateKhz(format.sampleRateHz);
  }
  if (hasBitDepth) {
    return '${format.bitDepth}-bit';
  }
  return '未知';
}

/// Formats the bitrate readout for [track] with thousand separators.
///
/// Uses [overrideBitrateKbps] or `track.format.bitrateKbps` when available.
/// Falls back honestly to exact PCM/DSD calculation, clearly marked estimates
/// (`約 ... kbps`) for VBR lossless or high-quality streaming without explicit
/// bitrate, or `'未知'` when bitrate cannot be determined reliably.
String formatAudioBitrateLabel(TrackInfo track, {int? overrideBitrateKbps}) {
  final explicit = overrideBitrateKbps ?? track.format.bitrateKbps;
  if (explicit != null && explicit > 0) {
    return '${_formatWithCommas(explicit)} kbps';
  }

  final fmt = track.format;
  final channels = fmt.channels > 0 ? fmt.channels : 2;

  if (_isDsdFormat(fmt) && fmt.sampleRateHz > 0) {
    final dsdKbps = ((fmt.sampleRateHz * channels) / 1000.0).round();
    if (dsdKbps > 0) {
      return '${_formatWithCommas(dsdKbps)} kbps';
    }
  }

  if ((fmt.codec == AudioCodec.wav || fmt.codec == AudioCodec.aiff) &&
      fmt.sampleRateHz > 0 &&
      fmt.bitDepth > 0) {
    final pcmKbps = ((fmt.sampleRateHz * fmt.bitDepth * channels) / 1000.0)
        .round();
    if (pcmKbps > 0) {
      return '${_formatWithCommas(pcmKbps)} kbps';
    }
  }

  if ((fmt.codec == AudioCodec.flac || fmt.codec == AudioCodec.alac) &&
      fmt.sampleRateHz > 0 &&
      fmt.bitDepth > 0) {
    // Compressed lossless averages ~62% of raw PCM bitrate.
    final estKbps =
        ((fmt.sampleRateHz * fmt.bitDepth * channels * 0.62) / 1000.0).round();
    if (estKbps > 0) {
      return '約 ${_formatWithCommas(estKbps)} kbps';
    }
  }

  if (!fmt.codec.isLossless &&
      _isStreamingProvider(track.providerName) &&
      (fmt.codec == AudioCodec.opus || fmt.codec == AudioCodec.aac) &&
      fmt.sampleRateHz >= 48000) {
    return '約 256 kbps';
  }

  return '未知';
}
