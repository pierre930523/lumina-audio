part of '../stream_source_spec.dart';

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
