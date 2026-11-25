import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'playback_state.dart';
import 'streaming_models.dart';

/// Structured reason why a local/NAS audio file was quarantined during scan.
enum SkipReason {
  corruptHeader,
  permissionDenied,
  unsupportedFormat,
  unsplitCueOrIso,
  garbledTags,
  ioError;

  String toJson() => switch (this) {
    SkipReason.corruptHeader => 'corrupt_header',
    SkipReason.permissionDenied => 'permission_denied',
    SkipReason.unsupportedFormat => 'unsupported_format',
    SkipReason.unsplitCueOrIso => 'unsplit_cue_or_iso',
    SkipReason.garbledTags => 'garbled_tags',
    SkipReason.ioError => 'io_error',
  };

  static SkipReason fromJson(String? raw) => switch (raw?.trim().toLowerCase()) {
    'corrupt_header' => SkipReason.corruptHeader,
    'permission_denied' => SkipReason.permissionDenied,
    'unsupported_format' => SkipReason.unsupportedFormat,
    'unsplit_cue_or_iso' => SkipReason.unsplitCueOrIso,
    'garbled_tags' => SkipReason.garbledTags,
    'io_error' => SkipReason.ioError,
    _ => SkipReason.ioError,
  };

  String get displayLabel => switch (this) {
    SkipReason.corruptHeader => '音訊標頭損毀',
    SkipReason.permissionDenied => '權限不足',
    SkipReason.unsupportedFormat => '不支援的格式',
    SkipReason.unsplitCueOrIso => '未分割的 CUE / ISO 映像',
    SkipReason.garbledTags => '標籤編碼異常',
    SkipReason.ioError => '檔案讀取錯誤',
  };
}

/// Quarantine record for a file skipped during directory ingestion.
@immutable
class SkippedFileRecord {
  final String id;
  final String providerId;
  final String filePath;
  final SkipReason reason;
  final String detail;
  final int? fileSize;
  final int? fileMtime;
  final String firstSeenAt;
  final String lastSeenAt;
  final bool dismissed;

  const SkippedFileRecord({
    required this.id,
    required this.providerId,
    required this.filePath,
    required this.reason,
    required this.detail,
    this.fileSize,
    this.fileMtime,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.dismissed = false,
  });

  factory SkippedFileRecord.fromJson(Map<String, dynamic> json) =>
      SkippedFileRecord(
        id: json['id']?.toString() ?? '',
        providerId: json['provider_id']?.toString() ?? 'local',
        filePath: json['file_path']?.toString() ?? '',
        reason: SkipReason.fromJson(json['reason']?.toString()),
        detail: json['detail']?.toString() ?? '',
        fileSize: (json['file_size'] as num?)?.toInt(),
        fileMtime: (json['file_mtime'] as num?)?.toInt(),
        firstSeenAt: json['first_seen_at']?.toString() ?? '',
        lastSeenAt: json['last_seen_at']?.toString() ?? '',
        dismissed: json['dismissed'] == true || json['dismissed'] == 1,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'provider_id': providerId,
    'file_path': filePath,
    'reason': reason.toJson(),
    'detail': detail,
    if (fileSize != null) 'file_size': fileSize,
    if (fileMtime != null) 'file_mtime': fileMtime,
    'first_seen_at': firstSeenAt,
    'last_seen_at': lastSeenAt,
    'dismissed': dismissed,
  };
}

/// Lifecycle phase of an asynchronous library scan / watch session.
enum ScanLifecycleState {
  idle,
  discovering,
  probing,
  persisting,
  watching,
  completed,
  failed;

  String toJson() => name;

  static ScanLifecycleState fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'idle' => ScanLifecycleState.idle,
        'discovering' => ScanLifecycleState.discovering,
        'probing' => ScanLifecycleState.probing,
        'persisting' => ScanLifecycleState.persisting,
        'watching' => ScanLifecycleState.watching,
        'completed' => ScanLifecycleState.completed,
        'failed' => ScanLifecycleState.failed,
        _ => ScanLifecycleState.idle,
      };
}

/// Incremental scan telemetry emitted over FFI callbacks and WebSocket events.
@immutable
class ScanProgressEvent {
  final String scanId;
  final String rootPath;
  final ScanLifecycleState state;
  final int scanned;
  final int added;
  final int updated;
  final int unchanged;
  final int skipped;
  final int pruned;
  final int? totalEstimated;
  final String? currentPath;
  final String? message;

  const ScanProgressEvent({
    required this.scanId,
    required this.rootPath,
    required this.state,
    this.scanned = 0,
    this.added = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.skipped = 0,
    this.pruned = 0,
    this.totalEstimated,
    this.currentPath,
    this.message,
  });

  factory ScanProgressEvent.fromJson(Map<String, dynamic> json) =>
      ScanProgressEvent(
        scanId: json['scan_id']?.toString() ?? '',
        rootPath: json['root_path']?.toString() ?? '',
        state: ScanLifecycleState.fromJson(json['state']?.toString()),
        scanned: (json['scanned'] as num?)?.toInt() ?? 0,
        added: (json['added'] as num?)?.toInt() ?? 0,
        updated: (json['updated'] as num?)?.toInt() ?? 0,
        unchanged: (json['unchanged'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        pruned: (json['pruned'] as num?)?.toInt() ?? 0,
        totalEstimated: (json['total_estimated'] as num?)?.toInt(),
        currentPath: json['current_path']?.toString(),
        message: json['message']?.toString(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scan_id': scanId,
    'root_path': rootPath,
    'state': state.toJson(),
    'scanned': scanned,
    'added': added,
    'updated': updated,
    'unchanged': unchanged,
    'skipped': skipped,
    'pruned': pruned,
    if (totalEstimated != null) 'total_estimated': totalEstimated,
    if (currentPath != null) 'current_path': currentPath,
    if (message != null) 'message': message,
  };
}

/// Strategy used to monitor a configured music library root directory.
enum WatchMode {
  nativeOs,
  nasPolling,
  manual;

  String toJson() => switch (this) {
    WatchMode.nativeOs => 'native_os',
    WatchMode.nasPolling => 'nas_polling',
    WatchMode.manual => 'manual',
  };

  static WatchMode fromJson(String? raw) => switch (raw?.trim().toLowerCase()) {
    'native_os' => WatchMode.nativeOs,
    'nas_polling' => WatchMode.nasPolling,
    'manual' => WatchMode.manual,
    _ => WatchMode.nativeOs,
  };
}

/// Persisted watched folder root and its current monitoring health.
@immutable
class WatchedRootRecord {
  final String id;
  final String providerId;
  final String rootPath;
  final WatchMode watchMode;
  final int pollIntervalSec;
  final bool isOnline;
  final String? lastScanAt;
  final String updatedAt;

  const WatchedRootRecord({
    required this.id,
    required this.providerId,
    required this.rootPath,
    this.watchMode = WatchMode.nativeOs,
    this.pollIntervalSec = 300,
    this.isOnline = true,
    this.lastScanAt,
    required this.updatedAt,
  });

  factory WatchedRootRecord.fromJson(Map<String, dynamic> json) =>
      WatchedRootRecord(
        id: json['id']?.toString() ?? '',
        providerId: json['provider_id']?.toString() ?? 'local',
        rootPath: json['root_path']?.toString() ?? '',
        watchMode: WatchMode.fromJson(json['watch_mode']?.toString()),
        pollIntervalSec: (json['poll_interval_sec'] as num?)?.toInt() ?? 300,
        isOnline: json['is_online'] != false && json['is_online'] != 0,
        lastScanAt: json['last_scan_at']?.toString(),
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'provider_id': providerId,
    'root_path': rootPath,
    'watch_mode': watchMode.toJson(),
    'poll_interval_sec': pollIntervalSec,
    'is_online': isOnline,
    if (lastScanAt != null) 'last_scan_at': lastScanAt,
    'updated_at': updatedAt,
  };
}

/// Precedence layer for non-destructive metadata overrides
/// (`fileTag < cloudEnrichment < userEdit`).
enum MetadataLayer {
  fileTag,
  cloudEnrichment,
  userEdit;

  String toJson() => switch (this) {
    MetadataLayer.fileTag => 'file_tag',
    MetadataLayer.cloudEnrichment => 'cloud_enrichment',
    MetadataLayer.userEdit => 'user_edit',
  };

  static MetadataLayer fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'file_tag' => MetadataLayer.fileTag,
        'cloud_enrichment' => MetadataLayer.cloudEnrichment,
        'user_edit' => MetadataLayer.userEdit,
        _ => MetadataLayer.userEdit,
      };
}

/// Non-destructive metadata field override stored in SQLite.
@immutable
class MetadataOverrideRecord {
  final String entityType;
  final String entityId;
  final String fieldName;
  final String valueJson;
  final MetadataLayer sourceLayer;
  final String updatedAt;

  const MetadataOverrideRecord({
    required this.entityType,
    required this.entityId,
    required this.fieldName,
    required this.valueJson,
    this.sourceLayer = MetadataLayer.userEdit,
    required this.updatedAt,
  });

  factory MetadataOverrideRecord.fromJson(Map<String, dynamic> json) =>
      MetadataOverrideRecord(
        entityType: json['entity_type']?.toString() ?? 'track',
        entityId: json['entity_id']?.toString() ?? '',
        fieldName: json['field_name']?.toString() ?? '',
        valueJson: json['value_json']?.toString() ?? '',
        sourceLayer: MetadataLayer.fromJson(json['source_layer']?.toString()),
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entity_type': entityType,
    'entity_id': entityId,
    'field_name': fieldName,
    'value_json': valueJson,
    'source_layer': sourceLayer.toJson(),
    'updated_at': updatedAt,
  };
}

/// Lightweight streaming track metadata for canonical library ingestion.
/// Intentionally contains NO stream URL field (URLs are resolved lazily).
@immutable
class ExternalTrackIngest {
  final String externalTrackId;
  final String title;
  final String artistName;
  final int discNumber;
  final int trackNumber;
  final int durationMs;
  final String? isrc;
  final String? genre;
  final String? composer;
  final String? codec;
  final int? sampleRateHz;
  final int? bitDepth;
  final int? bitrateKbps;

  const ExternalTrackIngest({
    required this.externalTrackId,
    required this.title,
    required this.artistName,
    this.discNumber = 1,
    this.trackNumber = 1,
    this.durationMs = 0,
    this.isrc,
    this.genre,
    this.composer,
    this.codec,
    this.sampleRateHz,
    this.bitDepth,
    this.bitrateKbps,
  });

  factory ExternalTrackIngest.fromJson(Map<String, dynamic> json) =>
      ExternalTrackIngest(
        externalTrackId: json['external_track_id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artistName: json['artist_name']?.toString() ?? '',
        discNumber: (json['disc_number'] as num?)?.toInt() ?? 1,
        trackNumber: (json['track_number'] as num?)?.toInt() ?? 1,
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        isrc: json['isrc']?.toString(),
        genre: json['genre']?.toString(),
        composer: json['composer']?.toString(),
        codec: json['codec']?.toString(),
        sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt(),
        bitDepth: (json['bit_depth'] as num?)?.toInt(),
        bitrateKbps: (json['bitrate_kbps'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'external_track_id': externalTrackId,
    'title': title,
    'artist_name': artistName,
    'disc_number': discNumber,
    'track_number': trackNumber,
    'duration_ms': durationMs,
    if (isrc != null && isrc!.trim().isNotEmpty) 'isrc': isrc,
    if (genre != null && genre!.trim().isNotEmpty) 'genre': genre,
    if (composer != null && composer!.trim().isNotEmpty) 'composer': composer,
    if (codec != null && codec!.trim().isNotEmpty) 'codec': codec,
    if (sampleRateHz != null) 'sample_rate_hz': sampleRateHz,
    if (bitDepth != null) 'bit_depth': bitDepth,
    if (bitrateKbps != null) 'bitrate_kbps': bitrateKbps,
  };
}

/// Lightweight streaming album metadata for canonical library ingestion.
/// Intentionally contains NO expiring audio stream URLs.
@immutable
class ExternalAlbumIngest {
  final String externalAlbumId;
  final String title;
  final String artistName;
  final String? albumArtist;
  final int? releaseYear;
  final String? upc;
  final String? coverUrl;
  final String? editionLabel;
  final int? discCount;
  final List<ExternalTrackIngest> tracks;

  const ExternalAlbumIngest({
    required this.externalAlbumId,
    required this.title,
    required this.artistName,
    this.albumArtist,
    this.releaseYear,
    this.upc,
    this.coverUrl,
    this.editionLabel,
    this.discCount,
    this.tracks = const [],
  });

  factory ExternalAlbumIngest.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    return ExternalAlbumIngest(
      externalAlbumId: json['external_album_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artistName: json['artist_name']?.toString() ?? '',
      albumArtist: json['album_artist']?.toString(),
      releaseYear: (json['release_year'] as num?)?.toInt(),
      upc: json['upc']?.toString(),
      coverUrl: json['cover_url']?.toString(),
      editionLabel: json['edition_label']?.toString(),
      discCount: (json['disc_count'] as num?)?.toInt(),
      tracks: rawTracks
          .whereType<Map>()
          .map(
            (e) => ExternalTrackIngest.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'external_album_id': externalAlbumId,
    'title': title,
    'artist_name': artistName,
    if (albumArtist != null && albumArtist!.trim().isNotEmpty)
      'album_artist': albumArtist,
    if (releaseYear != null) 'release_year': releaseYear,
    if (upc != null && upc!.trim().isNotEmpty) 'upc': upc,
    if (coverUrl != null && coverUrl!.trim().isNotEmpty) 'cover_url': coverUrl,
    if (editionLabel != null && editionLabel!.trim().isNotEmpty)
      'edition_label': editionLabel,
    if (discCount != null) 'disc_count': discCount,
    'tracks': tracks.map((t) => t.toJson()).toList(growable: false),
  };
}

/// Batch payload handed off from Dart streaming catalog sync to Rust canonical DB.
/// Strictly lightweight metadata + platform IDs (zero expiring stream URLs).
@immutable
class ExternalCatalogIngestBatch {
  final String provider;
  final List<ExternalAlbumIngest> albums;

  const ExternalCatalogIngestBatch({
    required this.provider,
    this.albums = const [],
  });

  factory ExternalCatalogIngestBatch.fromJson(Map<String, dynamic> json) {
    final rawAlbums = json['albums'] as List<dynamic>? ?? const [];
    return ExternalCatalogIngestBatch(
      provider: json['provider']?.toString() ?? '',
      albums: rawAlbums
          .whereType<Map>()
          .map(
            (e) => ExternalAlbumIngest.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'albums': albums.map((a) => a.toJson()).toList(growable: false),
  };

  /// Converts an in-memory [StreamingCatalog] into a canonical ingest batch
  /// without ever carrying audio stream URLs or local file paths.
  factory ExternalCatalogIngestBatch.fromStreamingCatalog(
    String providerId,
    StreamingCatalog catalog,
  ) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final albumBuilders = <String, _MutableAlbumIngest>{};
    final keyByTitleArtist = <String, String>{};

    for (final album in catalog.albums) {
      final cleanAlbumId = _stripProviderPrefix(album.id, normalizedProvider);
      if (cleanAlbumId.isEmpty) continue;
      final normTitle = album.title.trim();
      final normArtist = album.artist.trim();
      final builder = _MutableAlbumIngest(
        externalAlbumId: cleanAlbumId,
        title: normTitle.isNotEmpty ? normTitle : 'Unknown Album',
        artistName: normArtist.isNotEmpty ? normArtist : 'Unknown Artist',
        albumArtist: normArtist.isNotEmpty ? normArtist : null,
        releaseYear: album.year,
        coverUrl: normalizeStreamingCoverUrl(album.coverUrl),
      );
      albumBuilders[cleanAlbumId] = builder;
      final lookupKey = _albumLookupKey(builder.title, builder.artistName);
      keyByTitleArtist.putIfAbsent(lookupKey, () => cleanAlbumId);
    }

    final seenTrackIds = <String>{};
    final allTracks = <TrackInfo>[
      ...catalog.tracks,
      for (final pl in catalog.playlists) ...pl.tracks,
    ];

    for (final track in allTracks) {
      final cleanTrackId = _stripProviderPrefix(track.id, normalizedProvider);
      if (cleanTrackId.isEmpty || !seenTrackIds.add(cleanTrackId)) continue;

      final albumTitle = track.album.trim().isNotEmpty
          ? track.album.trim()
          : track.title.trim();
      final albumArtist = track.effectiveAlbumArtist.trim().isNotEmpty
          ? track.effectiveAlbumArtist.trim()
          : 'Unknown Artist';
      final lookupKey = _albumLookupKey(albumTitle, albumArtist);

      var targetAlbumId = keyByTitleArtist[lookupKey];
      if (targetAlbumId == null) {
        targetAlbumId = '$normalizedProvider:synth:$lookupKey';
        keyByTitleArtist[lookupKey] = targetAlbumId;
        albumBuilders[targetAlbumId] = _MutableAlbumIngest(
          externalAlbumId: targetAlbumId,
          title: albumTitle.isNotEmpty ? albumTitle : 'Unknown Album',
          artistName: albumArtist,
          albumArtist: track.albumArtist?.trim().isNotEmpty == true
              ? track.albumArtist!.trim()
              : albumArtist,
          releaseYear: track.year,
          coverUrl: normalizeStreamingCoverUrl(track.artworkUrl),
        );
      } else {
        final existing = albumBuilders[targetAlbumId]!;
        existing.coverUrl ??= normalizeStreamingCoverUrl(track.artworkUrl);
        existing.releaseYear ??= track.year;
      }

      final discNum = (track.discNumber != null && track.discNumber! > 0)
          ? track.discNumber!
          : 1;
      final bucket = albumBuilders[targetAlbumId]!;
      final trackNum = (track.trackNumber != null && track.trackNumber! > 0)
          ? track.trackNumber!
          : bucket.tracks.length + 1;
      if (discNum > bucket.maxDiscNumber) {
        bucket.maxDiscNumber = discNum;
      }

      bucket.tracks.add(
        ExternalTrackIngest(
          externalTrackId: cleanTrackId,
          title: track.title.trim().isNotEmpty ? track.title.trim() : cleanTrackId,
          artistName: track.artist.trim().isNotEmpty
              ? track.artist.trim()
              : albumArtist,
          discNumber: discNum,
          trackNumber: trackNum,
          durationMs: track.duration.inMilliseconds.clamp(0, 1 << 50),
          isrc: track.isrc?.trim().isNotEmpty == true ? track.isrc!.trim() : null,
          genre: track.genre?.trim().isNotEmpty == true ? track.genre!.trim() : null,
          composer: track.composer?.trim().isNotEmpty == true
              ? track.composer!.trim()
              : null,
          codec: _codecToSnakeCase(track.format.codec),
          sampleRateHz: track.format.sampleRateHz > 0
              ? track.format.sampleRateHz
              : null,
          bitDepth: track.format.bitDepth > 0 ? track.format.bitDepth : null,
          bitrateKbps:
              (track.format.bitrateKbps != null && track.format.bitrateKbps! > 0)
              ? track.format.bitrateKbps
              : null,
        ),
      );
    }

    return ExternalCatalogIngestBatch(
      provider: normalizedProvider,
      albums: albumBuilders.values
          .map((b) => b.build())
          .toList(growable: false),
    );
  }

  static String _stripProviderPrefix(String rawId, String providerId) {
    var trimmed = rawId.trim();
    if (trimmed.isEmpty) return '';
    final prefixes = <String>[
      '$providerId:',
      if (providerId == 'apple_music') 'apple:',
      if (providerId == 'youtube_music') ...['ytm:', 'ytm_'],
    ];
    for (final prefix in prefixes) {
      if (trimmed.toLowerCase().startsWith(prefix)) {
        trimmed = trimmed.substring(prefix.length).trim();
        break;
      }
    }
    return trimmed;
  }

  static String _albumLookupKey(String title, String artist) =>
      '${title.trim().toLowerCase()}::${artist.trim().toLowerCase()}';

  static String _codecToSnakeCase(AudioCodec codec) => codec.name;
}

class _MutableAlbumIngest {
  final String externalAlbumId;
  final String title;
  final String artistName;
  final String? albumArtist;
  int? releaseYear;
  String? coverUrl;
  int maxDiscNumber = 1;
  final List<ExternalTrackIngest> tracks = <ExternalTrackIngest>[];

  _MutableAlbumIngest({
    required this.externalAlbumId,
    required this.title,
    required this.artistName,
    this.albumArtist,
    this.releaseYear,
    this.coverUrl,
  });

  ExternalAlbumIngest build() => ExternalAlbumIngest(
    externalAlbumId: externalAlbumId,
    title: title,
    artistName: artistName,
    albumArtist: albumArtist,
    releaseYear: releaseYear,
    coverUrl: coverUrl,
    discCount: tracks.isEmpty ? null : maxDiscNumber,
    tracks: List<ExternalTrackIngest>.unmodifiable(tracks),
  );
}
