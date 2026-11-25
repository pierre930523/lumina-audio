import 'package:flutter/foundation.dart';

import 'audio_format.dart';

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

/// Static capability profile declared by a [StreamResolver] provider.
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

/// Adaptive manifest container format for [SegmentedManifestSpec].
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

/// Declarative playback source specification matching Rust `core-types` 1:1.
@immutable
sealed class StreamSourceSpec {
  final StreamKey key;

  /// Optional Dart-side resolved format metadata (omitted from wire JSON).
  final AudioFormat? audioFormat;

  const StreamSourceSpec({required this.key, this.audioFormat});

  String get kind;

  NormalizedLoudness? get loudness => null;

  NormalizedLoudness? get albumLoudness => null;

  Map<String, dynamic> toJson();

  static Map<String, String> _readHeaders(dynamic raw) {
    if (raw is! Map) return const <String, String>{};
    final out = <String, String>{};
    raw.forEach((k, v) {
      final keyStr = k?.toString();
      if (keyStr != null && keyStr.isNotEmpty && v != null) {
        out[keyStr] = v.toString();
      }
    });
    return Map<String, String>.unmodifiable(out);
  }

  static NormalizedLoudness? _readLoudness(dynamic raw) {
    if (raw is! Map) return null;
    return NormalizedLoudness.fromJson(Map<String, dynamic>.from(raw));
  }

  static StreamSourceSpec fromJson(Map<String, dynamic> json) {
    final kind = json['kind']?.toString() ?? '';
    final rawKey = json['key'];
    final key = rawKey is Map
        ? StreamKey.fromJson(Map<String, dynamic>.from(rawKey))
        : const StreamKey('', '', 'default');
    final loudness = _readLoudness(json['loudness']);
    final albumLoudness = _readLoudness(json['album_loudness']);

    return switch (kind) {
      'direct_range' => DirectRangeSpec(
        key: key,
        url: json['url']?.toString() ?? '',
        headers: _readHeaders(json['headers']),
        contentLength: (json['content_length'] as num?)?.toInt(),
        bitrateBps: (json['bitrate_bps'] as num?)?.toInt(),
        mimeType: json['mime_type']?.toString(),
        hintExtension: json['hint_extension']?.toString(),
        expireAt: (json['expire_at'] as num?)?.toInt(),
        initRangeEnd: (json['init_range_end'] as num?)?.toInt(),
        indexRangeStart: (json['index_range_start'] as num?)?.toInt(),
        indexRangeEnd: (json['index_range_end'] as num?)?.toInt(),
        loudness: loudness,
        albumLoudness: albumLoudness,
      ),
      'segmented_manifest' => SegmentedManifestSpec(
        key: key,
        manifestUrlOrXml: json['manifest_url_or_xml']?.toString() ?? '',
        format: ManifestFormat.fromWireValue(
          json['format']?.toString() ?? 'dash',
        ),
        headers: _readHeaders(json['headers']),
        bitrateBps: (json['bitrate_bps'] as num?)?.toInt(),
        mimeType: json['mime_type']?.toString(),
        expireAt: (json['expire_at'] as num?)?.toInt(),
        loudness: loudness,
        albumLoudness: albumLoudness,
      ),
      'encrypted_range' => EncryptedRangeSpec(
        key: key,
        url: json['url']?.toString() ?? '',
        headers: _readHeaders(json['headers']),
        contentLength: (json['content_length'] as num?)?.toInt(),
        bitrateBps: (json['bitrate_bps'] as num?)?.toInt(),
        mimeType: json['mime_type']?.toString(),
        hintExtension: json['hint_extension']?.toString(),
        cipher: StreamCipher.fromJson(
          Map<String, dynamic>.from(json['cipher'] as Map),
        ),
        expireAt: (json['expire_at'] as num?)?.toInt(),
        loudness: loudness,
        albumLoudness: albumLoudness,
      ),
      'local_file' => LocalFileSpec(
        key: key,
        path: json['path']?.toString() ?? '',
        loudness: loudness,
        albumLoudness: albumLoudness,
      ),
      'external_backend' => ExternalBackendSpec(
        key: key,
        providerId: json['provider_id']?.toString() ?? key.providerId,
        trackUri: json['track_uri']?.toString() ?? '',
        externalWebUrl: json['external_web_url']?.toString(),
        previewUrl: json['preview_url']?.toString(),
        notice: json['notice']?.toString(),
      ),
      _ => throw FormatException('Unsupported StreamSourceSpec kind: $kind'),
    };
  }
}

/// Direct HTTP Range-seekable stream (YTM Opus/AAC, Qobuz FLAC/MP3, Tidal BTS, Deezer preview).
@immutable
final class DirectRangeSpec extends StreamSourceSpec {
  final String url;
  final Map<String, String> headers;
  final int? contentLength;
  final int? bitrateBps;
  final String? mimeType;
  final String? hintExtension;
  final int? expireAt;
  final int? initRangeEnd;
  final int? indexRangeStart;
  final int? indexRangeEnd;
  @override
  final NormalizedLoudness? loudness;
  @override
  final NormalizedLoudness? albumLoudness;

  /// Optional Dart-only metadata for preview/DRM notices (not serialized).
  final bool isPreviewOnly;
  final String? notice;
  final String? externalWebUrl;

  const DirectRangeSpec({
    required super.key,
    required this.url,
    this.headers = const <String, String>{},
    this.contentLength,
    this.bitrateBps,
    this.mimeType,
    this.hintExtension,
    this.expireAt,
    this.initRangeEnd,
    this.indexRangeStart,
    this.indexRangeEnd,
    this.loudness,
    this.albumLoudness,
    super.audioFormat,
    this.isPreviewOnly = false,
    this.notice,
    this.externalWebUrl,
  });

  @override
  String get kind => 'direct_range';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key.toJson(),
    'url': url,
    'headers': headers,
    if (contentLength != null) 'content_length': contentLength,
    if (bitrateBps != null) 'bitrate_bps': bitrateBps,
    if (mimeType != null) 'mime_type': mimeType,
    if (hintExtension != null) 'hint_extension': hintExtension,
    if (expireAt != null) 'expire_at': expireAt,
    if (initRangeEnd != null) 'init_range_end': initRangeEnd,
    if (indexRangeStart != null) 'index_range_start': indexRangeStart,
    if (indexRangeEnd != null) 'index_range_end': indexRangeEnd,
    if (loudness != null) 'loudness': loudness!.toJson(),
    if (albumLoudness != null) 'album_loudness': albumLoudness!.toJson(),
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is DirectRangeSpec &&
            other.key == key &&
            other.url == url &&
            mapEquals(other.headers, headers) &&
            other.contentLength == contentLength &&
            other.bitrateBps == bitrateBps &&
            other.mimeType == mimeType &&
            other.hintExtension == hintExtension &&
            other.expireAt == expireAt &&
            other.initRangeEnd == initRangeEnd &&
            other.indexRangeStart == indexRangeStart &&
            other.indexRangeEnd == indexRangeEnd &&
            other.loudness == loudness &&
            other.albumLoudness == albumLoudness);
  }

  @override
  int get hashCode => Object.hash(
    key,
    url,
    Object.hashAllUnordered(
      headers.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    contentLength,
    bitrateBps,
    mimeType,
    hintExtension,
    expireAt,
    initRangeEnd,
    indexRangeStart,
    indexRangeEnd,
    loudness,
    albumLoudness,
  );
}

/// DASH/HLS segmented manifest passed directly to Rust (e.g. unencrypted Tidal DASH MPD XML).
@immutable
final class SegmentedManifestSpec extends StreamSourceSpec {
  final String manifestUrlOrXml;
  final ManifestFormat format;
  final Map<String, String> headers;
  final int? bitrateBps;
  final String? mimeType;
  final int? expireAt;
  @override
  final NormalizedLoudness? loudness;
  @override
  final NormalizedLoudness? albumLoudness;

  const SegmentedManifestSpec({
    required super.key,
    required this.manifestUrlOrXml,
    required this.format,
    this.headers = const <String, String>{},
    this.bitrateBps,
    this.mimeType,
    this.expireAt,
    this.loudness,
    this.albumLoudness,
    super.audioFormat,
  });

  @override
  String get kind => 'segmented_manifest';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key.toJson(),
    'manifest_url_or_xml': manifestUrlOrXml,
    'format': format.wireValue,
    'headers': headers,
    if (bitrateBps != null) 'bitrate_bps': bitrateBps,
    if (mimeType != null) 'mime_type': mimeType,
    if (expireAt != null) 'expire_at': expireAt,
    if (loudness != null) 'loudness': loudness!.toJson(),
    if (albumLoudness != null) 'album_loudness': albumLoudness!.toJson(),
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is SegmentedManifestSpec &&
            other.key == key &&
            other.manifestUrlOrXml == manifestUrlOrXml &&
            other.format == format &&
            mapEquals(other.headers, headers) &&
            other.bitrateBps == bitrateBps &&
            other.mimeType == mimeType &&
            other.expireAt == expireAt &&
            other.loudness == loudness &&
            other.albumLoudness == albumLoudness);
  }

  @override
  int get hashCode => Object.hash(
    key,
    manifestUrlOrXml,
    format,
    Object.hashAllUnordered(
      headers.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    bitrateBps,
    mimeType,
    expireAt,
    loudness,
    albumLoudness,
  );
}

/// Encrypted HTTP Range stream decrypted natively in Rust (e.g. Deezer BF_CBC_STRIPE).
@immutable
final class EncryptedRangeSpec extends StreamSourceSpec {
  final String url;
  final Map<String, String> headers;
  final int? contentLength;
  final int? bitrateBps;
  final String? mimeType;
  final String? hintExtension;
  final StreamCipher cipher;
  final int? expireAt;
  @override
  final NormalizedLoudness? loudness;
  @override
  final NormalizedLoudness? albumLoudness;

  const EncryptedRangeSpec({
    required super.key,
    required this.url,
    this.headers = const <String, String>{},
    this.contentLength,
    this.bitrateBps,
    this.mimeType,
    this.hintExtension,
    required this.cipher,
    this.expireAt,
    this.loudness,
    this.albumLoudness,
    super.audioFormat,
  });

  @override
  String get kind => 'encrypted_range';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key.toJson(),
    'url': url,
    'headers': headers,
    if (contentLength != null) 'content_length': contentLength,
    if (bitrateBps != null) 'bitrate_bps': bitrateBps,
    if (mimeType != null) 'mime_type': mimeType,
    if (hintExtension != null) 'hint_extension': hintExtension,
    'cipher': cipher.toJson(),
    if (expireAt != null) 'expire_at': expireAt,
    if (loudness != null) 'loudness': loudness!.toJson(),
    if (albumLoudness != null) 'album_loudness': albumLoudness!.toJson(),
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is EncryptedRangeSpec &&
            other.key == key &&
            other.url == url &&
            mapEquals(other.headers, headers) &&
            other.contentLength == contentLength &&
            other.bitrateBps == bitrateBps &&
            other.mimeType == mimeType &&
            other.hintExtension == hintExtension &&
            other.cipher == cipher &&
            other.expireAt == expireAt &&
            other.loudness == loudness &&
            other.albumLoudness == albumLoudness);
  }

  @override
  int get hashCode => Object.hash(
    key,
    url,
    Object.hashAllUnordered(
      headers.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    contentLength,
    bitrateBps,
    mimeType,
    hintExtension,
    cipher,
    expireAt,
    loudness,
    albumLoudness,
  );
}

/// Local filesystem track handled directly by the native audio engine.
@immutable
final class LocalFileSpec extends StreamSourceSpec {
  final String path;
  @override
  final NormalizedLoudness? loudness;
  @override
  final NormalizedLoudness? albumLoudness;

  const LocalFileSpec({
    required super.key,
    required this.path,
    this.loudness,
    this.albumLoudness,
    super.audioFormat,
  });

  @override
  String get kind => 'local_file';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key.toJson(),
    'path': path,
    if (loudness != null) 'loudness': loudness!.toJson(),
    if (albumLoudness != null) 'album_loudness': albumLoudness!.toJson(),
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is LocalFileSpec &&
            other.key == key &&
            other.path == path &&
            other.loudness == loudness &&
            other.albumLoudness == albumLoudness);
  }

  @override
  int get hashCode => Object.hash(key, path, loudness, albumLoudness);
}

/// External DRM playback target handled completely outside Rust `ByteStreamSource`.
@immutable
final class ExternalBackendSpec extends StreamSourceSpec {
  final String providerId;
  final String trackUri;
  final String? externalWebUrl;
  final String? previewUrl;
  final String? notice;

  const ExternalBackendSpec({
    required super.key,
    required this.providerId,
    required this.trackUri,
    this.externalWebUrl,
    this.previewUrl,
    this.notice,
    super.audioFormat,
  });

  @override
  String get kind => 'external_backend';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'key': key.toJson(),
    'provider_id': providerId,
    'track_uri': trackUri,
    if (externalWebUrl != null) 'external_web_url': externalWebUrl,
    if (previewUrl != null) 'preview_url': previewUrl,
    if (notice != null) 'notice': notice,
  };

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is ExternalBackendSpec &&
            other.key == key &&
            other.providerId == providerId &&
            other.trackUri == trackUri &&
            other.externalWebUrl == externalWebUrl &&
            other.previewUrl == previewUrl &&
            other.notice == notice);
  }

  @override
  int get hashCode => Object.hash(
    key,
    providerId,
    trackUri,
    externalWebUrl,
    previewUrl,
    notice,
  );
}
