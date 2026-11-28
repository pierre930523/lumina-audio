import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'stream_source/stream_source_types.dart';

export 'stream_source/stream_source_types.dart';

part 'stream_source/stream_source_variants.dart';

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
