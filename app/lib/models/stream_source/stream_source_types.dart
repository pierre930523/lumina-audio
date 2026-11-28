import 'package:flutter/foundation.dart';

/// Composite identity key for stream resolution and caching across providers
/// and quality tiers.
@immutable
class StreamKey {
  final String providerId;
  final String trackId;
  final String qualityKey;

  const StreamKey(
    this.providerId,
    this.trackId, [
    this.qualityKey = 'default',
  ]);

  factory StreamKey.fromJson(Map<String, dynamic> json) {
    return StreamKey(
      json['provider_id']?.toString() ?? '',
      json['track_id']?.toString() ?? '',
      json['quality_key']?.toString() ?? 'default',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider_id': providerId,
    'track_id': trackId,
    'quality_key': qualityKey,
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is StreamKey &&
            other.providerId == providerId &&
            other.trackId == trackId &&
            other.qualityKey == qualityKey);
  }

  @override
  int get hashCode => Object.hash(providerId, trackId, qualityKey);

  @override
  String toString() => 'StreamKey($providerId:$trackId@$qualityKey)';
}

/// Static capability profile declared by a `StreamResolver` provider.
@immutable
class ProviderCapabilities {
  final bool supportsL1UrlCache;
  final bool supportsL2HeadCache;
  final bool requiresRangeChunking;
  final bool needsNetworkEpochReset;
  final int defaultL1SafetyMarginSec;
  final bool supportsTrackRadio;
  final bool supportsPersonalFeed;
  final bool supportsIsrcLookup;

  const ProviderCapabilities({
    this.supportsL1UrlCache = false,
    this.supportsL2HeadCache = false,
    this.requiresRangeChunking = false,
    this.needsNetworkEpochReset = false,
    this.defaultL1SafetyMarginSec = 0,
    this.supportsTrackRadio = false,
    this.supportsPersonalFeed = false,
    this.supportsIsrcLookup = false,
  });

  static const ProviderCapabilities youtubeMusic = ProviderCapabilities(
    supportsL1UrlCache: true,
    supportsL2HeadCache: true,
    requiresRangeChunking: true,
    needsNetworkEpochReset: true,
    defaultL1SafetyMarginSec: 1800,
    supportsTrackRadio: true,
    supportsPersonalFeed: true,
    supportsIsrcLookup: false,
  );

  static const ProviderCapabilities qobuz = ProviderCapabilities(
    supportsL1UrlCache: true,
    supportsL2HeadCache: true,
    requiresRangeChunking: true,
    needsNetworkEpochReset: false,
    defaultL1SafetyMarginSec: 60,
    supportsTrackRadio: true,
    supportsPersonalFeed: true,
    supportsIsrcLookup: true,
  );

  static const ProviderCapabilities tidal = ProviderCapabilities(
    supportsL1UrlCache: true,
    supportsL2HeadCache: true,
    requiresRangeChunking: true,
    needsNetworkEpochReset: false,
    defaultL1SafetyMarginSec: 60,
    supportsTrackRadio: true,
    supportsPersonalFeed: true,
    supportsIsrcLookup: true,
  );

  static const ProviderCapabilities deezer = ProviderCapabilities(
    supportsL1UrlCache: true,
    supportsL2HeadCache: true,
    requiresRangeChunking: true,
    needsNetworkEpochReset: false,
    defaultL1SafetyMarginSec: 120,
    supportsTrackRadio: true,
    supportsPersonalFeed: true,
    supportsIsrcLookup: true,
  );

  static const ProviderCapabilities appleMusic = ProviderCapabilities(
    supportsL1UrlCache: false,
    supportsL2HeadCache: false,
    requiresRangeChunking: false,
    needsNetworkEpochReset: false,
    defaultL1SafetyMarginSec: 0,
    supportsTrackRadio: true,
    supportsPersonalFeed: true,
    supportsIsrcLookup: true,
  );

  static const ProviderCapabilities local = ProviderCapabilities(
    supportsL1UrlCache: false,
    supportsL2HeadCache: false,
    requiresRangeChunking: false,
    needsNetworkEpochReset: false,
    defaultL1SafetyMarginSec: 0,
    supportsTrackRadio: false,
    supportsPersonalFeed: false,
    supportsIsrcLookup: false,
  );

  static const ProviderCapabilities podcastRss = ProviderCapabilities(
    supportsL1UrlCache: false,
    supportsL2HeadCache: false,
    requiresRangeChunking: true,
    needsNetworkEpochReset: false,
    defaultL1SafetyMarginSec: 0,
    supportsTrackRadio: false,
    supportsPersonalFeed: false,
    supportsIsrcLookup: false,
  );

  factory ProviderCapabilities.fromJson(Map<String, dynamic> json) {
    return ProviderCapabilities(
      supportsL1UrlCache: json['supports_l1_url_cache'] == true,
      supportsL2HeadCache: json['supports_l2_head_cache'] == true,
      requiresRangeChunking: json['requires_range_chunking'] == true,
      needsNetworkEpochReset: json['needs_network_epoch_reset'] == true,
      defaultL1SafetyMarginSec:
          (json['default_l1_safety_margin_sec'] as num?)?.toInt() ?? 0,
      supportsTrackRadio: json['supports_track_radio'] == true,
      supportsPersonalFeed: json['supports_personal_feed'] == true,
      supportsIsrcLookup: json['supports_isrc_lookup'] == true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'supports_l1_url_cache': supportsL1UrlCache,
    'supports_l2_head_cache': supportsL2HeadCache,
    'requires_range_chunking': requiresRangeChunking,
    'needs_network_epoch_reset': needsNetworkEpochReset,
    'default_l1_safety_margin_sec': defaultL1SafetyMarginSec,
    'supports_track_radio': supportsTrackRadio,
    'supports_personal_feed': supportsPersonalFeed,
    'supports_isrc_lookup': supportsIsrcLookup,
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is ProviderCapabilities &&
            other.supportsL1UrlCache == supportsL1UrlCache &&
            other.supportsL2HeadCache == supportsL2HeadCache &&
            other.requiresRangeChunking == requiresRangeChunking &&
            other.needsNetworkEpochReset == needsNetworkEpochReset &&
            other.defaultL1SafetyMarginSec == defaultL1SafetyMarginSec &&
            other.supportsTrackRadio == supportsTrackRadio &&
            other.supportsPersonalFeed == supportsPersonalFeed &&
            other.supportsIsrcLookup == supportsIsrcLookup);
  }

  @override
  int get hashCode => Object.hash(
    supportsL1UrlCache,
    supportsL2HeadCache,
    requiresRangeChunking,
    needsNetworkEpochReset,
    defaultL1SafetyMarginSec,
    supportsTrackRadio,
    supportsPersonalFeed,
    supportsIsrcLookup,
  );
}

/// Adaptive manifest container format for `SegmentedManifestSpec`.
enum ManifestFormat {
  dash,
  hls;

  String get wireValue => name;

  static ManifestFormat fromWireValue(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'dash' => ManifestFormat.dash,
      'hls' => ManifestFormat.hls,
      _ => throw FormatException('Unsupported manifest format: $raw'),
    };
  }
}

/// Stream decryption parameters sent to the Rust audio engine.
@immutable
sealed class StreamCipher {
  const StreamCipher();

  String get kind;

  Map<String, dynamic> toJson();

  static StreamCipher fromJson(Map<String, dynamic> json) {
    final kind = json['kind']?.toString() ?? '';
    return switch (kind) {
      'deezer_blowfish' => DeezerBlowfishCipher.fromJson(json),
      _ => throw FormatException('Unsupported stream cipher kind: $kind'),
    };
  }
}

/// Deezer Blowfish-CBC 2048-byte striped encryption parameters.
@immutable
final class DeezerBlowfishCipher extends StreamCipher {
  final String trackId;
  final int blockSize;
  final int stride;

  const DeezerBlowfishCipher({
    required this.trackId,
    this.blockSize = 2048,
    this.stride = 3,
  });

  @override
  String get kind => 'deezer_blowfish';

  factory DeezerBlowfishCipher.fromJson(Map<String, dynamic> json) {
    return DeezerBlowfishCipher(
      trackId: json['track_id']?.toString() ?? '',
      blockSize: (json['block_size'] as num?)?.toInt() ?? 2048,
      stride: (json['stride'] as num?)?.toInt() ?? 3,
    );
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'track_id': trackId,
    'block_size': blockSize,
    'stride': stride,
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is DeezerBlowfishCipher &&
            other.trackId == trackId &&
            other.blockSize == blockSize &&
            other.stride == stride);
  }

  @override
  int get hashCode => Object.hash(trackId, blockSize, stride);
}

/// Unified loudness normalization payload targeting a common -14.0 LUFS reference.
@immutable
class NormalizedLoudness {
  static const double targetLufs = -14.0;
  static const double minGainDb = -24.0;
  static const double maxPositiveGainDb = 6.0;

  final double gainDb;
  final double peak;

  const NormalizedLoudness({required this.gainDb, this.peak = 1.0});

  static NormalizedLoudness _sanitized(double gainDb, double peak) {
    final safeGain = gainDb.isFinite
        ? gainDb.clamp(minGainDb, maxPositiveGainDb).toDouble()
        : 0.0;
    final safePeak = peak.isFinite && peak > 0.0 ? peak : 1.0;
    return NormalizedLoudness(gainDb: safeGain, peak: safePeak);
  }

  /// Converts YouTube Music `loudnessDb` (positive = louder than -14 LUFS) to target gain.
  factory NormalizedLoudness.fromYtmLoudnessDb(double loudnessDb) {
    return _sanitized(-loudnessDb, 1.0);
  }

  /// Converts ReplayGain 2.0 (-18 LUFS reference) to -14 LUFS target gain.
  factory NormalizedLoudness.fromReplayGain(double gainDb, {double? peak}) {
    return _sanitized(gainDb + 4.0, peak ?? 1.0);
  }

  /// Converts Deezer `GAIN` (-15 LUFS reference) to -14 LUFS target gain.
  factory NormalizedLoudness.fromDeezerGain(double gainDb) {
    return _sanitized(gainDb + 1.0, 1.0);
  }

  factory NormalizedLoudness.fromJson(Map<String, dynamic> json) {
    final rawGain = (json['gain_db'] as num?)?.toDouble() ?? 0.0;
    final rawPeak = (json['peak'] as num?)?.toDouble() ?? 1.0;
    return _sanitized(rawGain, rawPeak);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'gain_db': gainDb,
    'peak': peak,
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is NormalizedLoudness &&
            other.gainDb == gainDb &&
            other.peak == peak);
  }

  @override
  int get hashCode => Object.hash(gainDb, peak);

  @override
  String toString() => 'NormalizedLoudness(gainDb: $gainDb, peak: $peak)';
}
