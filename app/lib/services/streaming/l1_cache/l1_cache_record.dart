import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../models/audio_format.dart';
import '../../../models/stream_source_spec.dart';

/// Wire-compatible persistent record matching Rust `core_db::L1StreamUrlRecord`
/// and the `l1_stream_urls` SQLite schema 1:1.
@immutable
class L1StreamCacheRecord {
  final String providerId;
  final String trackId;
  final String qualityKey;
  final String streamType;
  final String urlOrManifest;
  final String headersJson;
  final String? mimeType;
  final int? bitrateBps;
  final int? contentLength;
  final int? initRangeEnd;
  final int? indexRangeStart;
  final int? indexRangeEnd;
  final int expireAt;
  final int networkEpoch;
  final int updatedAt;
  final String? extraJson;

  const L1StreamCacheRecord({
    required this.providerId,
    required this.trackId,
    required this.qualityKey,
    required this.streamType,
    required this.urlOrManifest,
    this.headersJson = '{}',
    this.mimeType,
    this.bitrateBps,
    this.contentLength,
    this.initRangeEnd,
    this.indexRangeStart,
    this.indexRangeEnd,
    required this.expireAt,
    this.networkEpoch = 1,
    required this.updatedAt,
    this.extraJson,
  });

  StreamKey get key => StreamKey(providerId, trackId, qualityKey);

  factory L1StreamCacheRecord.fromJson(Map<String, dynamic> json) {
    return L1StreamCacheRecord(
      providerId: json['provider_id']?.toString() ?? '',
      trackId: json['track_id']?.toString() ?? '',
      qualityKey: json['quality_key']?.toString() ?? 'default',
      streamType: json['stream_type']?.toString() ?? 'direct_range',
      urlOrManifest: json['url_or_manifest']?.toString() ?? '',
      headersJson: json['headers_json']?.toString() ?? '{}',
      mimeType: json['mime_type']?.toString(),
      bitrateBps: (json['bitrate_bps'] as num?)?.toInt(),
      contentLength: (json['content_length'] as num?)?.toInt(),
      initRangeEnd: (json['init_range_end'] as num?)?.toInt(),
      indexRangeStart: (json['index_range_start'] as num?)?.toInt(),
      indexRangeEnd: (json['index_range_end'] as num?)?.toInt(),
      expireAt: (json['expire_at'] as num?)?.toInt() ?? 0,
      networkEpoch: (json['network_epoch'] as num?)?.toInt() ?? 1,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      extraJson: json['extra_json']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider_id': providerId,
    'track_id': trackId,
    'quality_key': qualityKey,
    'stream_type': streamType,
    'url_or_manifest': urlOrManifest,
    'headers_json': headersJson,
    if (mimeType != null) 'mime_type': mimeType,
    if (bitrateBps != null) 'bitrate_bps': bitrateBps,
    if (contentLength != null) 'content_length': contentLength,
    if (initRangeEnd != null) 'init_range_end': initRangeEnd,
    if (indexRangeStart != null) 'index_range_start': indexRangeStart,
    if (indexRangeEnd != null) 'index_range_end': indexRangeEnd,
    'expire_at': expireAt,
    'network_epoch': networkEpoch,
    'updated_at': updatedAt,
    if (extraJson != null) 'extra_json': extraJson,
  };

  static L1StreamCacheRecord? fromSpec(
    StreamSourceSpec spec, {
    required int expireAt,
    required int networkEpoch,
    required int updatedAt,
  }) {
    final extra = <String, dynamic>{};
    if (spec.audioFormat != null) {
      extra['audio_format'] = <String, dynamic>{
        'codec': spec.audioFormat!.codec.name,
        'sample_rate_hz': spec.audioFormat!.sampleRateHz,
        'bit_depth': spec.audioFormat!.bitDepth,
        'channels': spec.audioFormat!.channels,
      };
    }
    if (spec.loudness != null) {
      extra['loudness'] = spec.loudness!.toJson();
    }
    if (spec.albumLoudness != null) {
      extra['album_loudness'] = spec.albumLoudness!.toJson();
    }

    switch (spec) {
      case DirectRangeSpec():
        if (spec.hintExtension != null) {
          extra['hint_extension'] = spec.hintExtension;
        }
        if (spec.isPreviewOnly) extra['is_preview_only'] = true;
        if (spec.notice != null) extra['notice'] = spec.notice;
        if (spec.externalWebUrl != null) {
          extra['external_web_url'] = spec.externalWebUrl;
        }
        return L1StreamCacheRecord(
          providerId: spec.key.providerId,
          trackId: spec.key.trackId,
          qualityKey: spec.key.qualityKey,
          streamType: spec.kind,
          urlOrManifest: spec.url,
          headersJson: jsonEncode(spec.headers),
          mimeType: spec.mimeType,
          bitrateBps: spec.bitrateBps,
          contentLength: spec.contentLength,
          initRangeEnd: spec.initRangeEnd,
          indexRangeStart: spec.indexRangeStart,
          indexRangeEnd: spec.indexRangeEnd,
          expireAt: expireAt,
          networkEpoch: networkEpoch,
          updatedAt: updatedAt,
          extraJson: extra.isEmpty ? null : jsonEncode(extra),
        );
      case SegmentedManifestSpec():
        extra['format'] = spec.format.wireValue;
        return L1StreamCacheRecord(
          providerId: spec.key.providerId,
          trackId: spec.key.trackId,
          qualityKey: spec.key.qualityKey,
          streamType: spec.kind,
          urlOrManifest: spec.manifestUrlOrXml,
          headersJson: jsonEncode(spec.headers),
          mimeType: spec.mimeType,
          bitrateBps: spec.bitrateBps,
          expireAt: expireAt,
          networkEpoch: networkEpoch,
          updatedAt: updatedAt,
          extraJson: jsonEncode(extra),
        );
      case EncryptedRangeSpec():
        if (spec.hintExtension != null) {
          extra['hint_extension'] = spec.hintExtension;
        }
        extra['cipher'] = spec.cipher.toJson();
        return L1StreamCacheRecord(
          providerId: spec.key.providerId,
          trackId: spec.key.trackId,
          qualityKey: spec.key.qualityKey,
          streamType: spec.kind,
          urlOrManifest: spec.url,
          headersJson: jsonEncode(spec.headers),
          mimeType: spec.mimeType,
          bitrateBps: spec.bitrateBps,
          contentLength: spec.contentLength,
          expireAt: expireAt,
          networkEpoch: networkEpoch,
          updatedAt: updatedAt,
          extraJson: jsonEncode(extra),
        );
      case LocalFileSpec():
      case ExternalBackendSpec():
        return null;
    }
  }

  StreamSourceSpec? toSpec() {
    if (providerId.isEmpty || trackId.isEmpty || urlOrManifest.isEmpty) {
      return null;
    }
    final headers = _decodeHeaders(headersJson);
    final extra = _decodeExtra(extraJson);
    final audioFormat = _decodeAudioFormat(extra['audio_format']);
    final loudness = _decodeLoudness(extra['loudness']);
    final albumLoudness = _decodeLoudness(extra['album_loudness']);

    switch (streamType) {
      case 'direct_range':
        return DirectRangeSpec(
          key: key,
          url: urlOrManifest,
          headers: headers,
          contentLength: contentLength,
          bitrateBps: bitrateBps,
          mimeType: mimeType,
          hintExtension: extra['hint_extension']?.toString(),
          expireAt: expireAt,
          initRangeEnd: initRangeEnd,
          indexRangeStart: indexRangeStart,
          indexRangeEnd: indexRangeEnd,
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: audioFormat,
          isPreviewOnly: extra['is_preview_only'] == true,
          notice: extra['notice']?.toString(),
          externalWebUrl: extra['external_web_url']?.toString(),
        );
      case 'segmented_manifest':
        final rawFmt = extra['format']?.toString() ?? 'dash';
        final fmt = rawFmt == 'hls' ? ManifestFormat.hls : ManifestFormat.dash;
        return SegmentedManifestSpec(
          key: key,
          manifestUrlOrXml: urlOrManifest,
          format: fmt,
          headers: headers,
          bitrateBps: bitrateBps,
          mimeType: mimeType,
          expireAt: expireAt,
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: audioFormat,
        );
      case 'encrypted_range':
        final rawCipher = extra['cipher'];
        final StreamCipher cipher;
        if (rawCipher is Map) {
          cipher = StreamCipher.fromJson(Map<String, dynamic>.from(rawCipher));
        } else {
          cipher = DeezerBlowfishCipher(trackId: trackId);
        }
        return EncryptedRangeSpec(
          key: key,
          url: urlOrManifest,
          headers: headers,
          contentLength: contentLength,
          bitrateBps: bitrateBps,
          mimeType: mimeType,
          hintExtension: extra['hint_extension']?.toString(),
          cipher: cipher,
          expireAt: expireAt,
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: audioFormat,
        );
      default:
        return null;
    }
  }

  static Map<String, String> _decodeHeaders(String raw) {
    if (raw.trim().isEmpty) return const <String, String>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return const <String, String>{};
      final out = <String, String>{};
      parsed.forEach((k, v) {
        final ks = k?.toString();
        if (ks != null && ks.isNotEmpty && v != null) {
          out[ks] = v.toString();
        }
      });
      return Map<String, String>.unmodifiable(out);
    } catch (_) {
      return const <String, String>{};
    }
  }

  static Map<String, dynamic> _decodeExtra(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static AudioFormat? _decodeAudioFormat(dynamic raw) {
    if (raw is! Map) return null;
    final codecName = raw['codec']?.toString().trim().toLowerCase() ?? '';
    final codec = AudioCodec.values.where((c) => c.name == codecName).firstOrNull;
    if (codec == null) return null;
    final sr = (raw['sample_rate_hz'] as num?)?.toInt() ?? 44100;
    final bd = (raw['bit_depth'] as num?)?.toInt() ?? 16;
    final ch = (raw['channels'] as num?)?.toInt() ?? 2;
    return AudioFormat(codec: codec, sampleRateHz: sr, bitDepth: bd, channels: ch);
  }

  static NormalizedLoudness? _decodeLoudness(dynamic raw) {
    if (raw is! Map) return null;
    return NormalizedLoudness.fromJson(Map<String, dynamic>.from(raw));
  }
}

/// In-memory L1 cache entry stored in [L1StreamCache].
@immutable
class L1CacheEntry {
  final StreamSourceSpec spec;
  final int expireAt;
  final int networkEpoch;
  final int updatedAt;

  const L1CacheEntry({
    required this.spec,
    required this.expireAt,
    required this.networkEpoch,
    required this.updatedAt,
  });
}

/// Pluggable persistence backend for [L1StreamCache].
abstract interface class L1StreamCachePersistence {
  Future<List<L1StreamCacheRecord>> loadUnexpired(int nowSec);
  Future<void> upsert(L1StreamCacheRecord record);
  Future<void> delete({
    required String providerId,
    required String trackId,
    String? qualityKey,
  });
}
