part of 'backup_export_models.dart';

/// Output format for catalog metadata exports.
enum CatalogExportFormat {
  csv('csv'),
  json('json');

  final String wireName;

  const CatalogExportFormat(this.wireName);

  String toJson() => wireName;

  static CatalogExportFormat fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'json' => CatalogExportFormat.json,
        _ => CatalogExportFormat.csv,
      };
}

/// Tagged union matching Rust `CatalogExportSource` (`#[serde(tag = "kind", rename_all = "snake_case")]`).
@immutable
sealed class CatalogExportSource {
  const CatalogExportSource();

  const factory CatalogExportSource.focusQuery(FocusQuery query) =
      CatalogExportFocusQuerySource;
  const factory CatalogExportSource.staticPlaylist(String playlistId) =
      CatalogExportStaticPlaylistSource;
  const factory CatalogExportSource.smartPlaylist(String playlistId) =
      CatalogExportSmartPlaylistSource;
  const factory CatalogExportSource.albums(List<String> albumIds) =
      CatalogExportAlbumsSource;
  const factory CatalogExportSource.tracks(List<String> trackIds) =
      CatalogExportTracksSource;

  String get kind;
  Map<String, dynamic> toJson();

  factory CatalogExportSource.fromJson(Map<String, dynamic> json) =>
      switch (json['kind']?.toString().trim().toLowerCase()) {
        'static_playlist' => CatalogExportStaticPlaylistSource(
          json['playlist_id']?.toString() ?? '',
        ),
        'smart_playlist' => CatalogExportSmartPlaylistSource(
          json['playlist_id']?.toString() ?? '',
        ),
        'albums' => CatalogExportAlbumsSource(_readStringList(json['album_ids'])),
        'tracks' => CatalogExportTracksSource(_readStringList(json['track_ids'])),
        _ => CatalogExportFocusQuerySource(
          json['query'] is Map
              ? FocusQuery.fromJson(Map<String, dynamic>.from(json['query'] as Map))
              : const FocusQuery(),
        ),
      };
}

@immutable
final class CatalogExportFocusQuerySource extends CatalogExportSource {
  final FocusQuery query;

  const CatalogExportFocusQuerySource(this.query);

  @override
  String get kind => 'focus_query';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'query': query.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogExportFocusQuerySource && other.query == query;

  @override
  int get hashCode => Object.hash(kind, query);
}

@immutable
final class CatalogExportStaticPlaylistSource extends CatalogExportSource {
  final String playlistId;

  const CatalogExportStaticPlaylistSource(this.playlistId);

  @override
  String get kind => 'static_playlist';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'playlist_id': playlistId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogExportStaticPlaylistSource && other.playlistId == playlistId;

  @override
  int get hashCode => Object.hash(kind, playlistId);
}

@immutable
final class CatalogExportSmartPlaylistSource extends CatalogExportSource {
  final String playlistId;

  const CatalogExportSmartPlaylistSource(this.playlistId);

  @override
  String get kind => 'smart_playlist';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'playlist_id': playlistId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogExportSmartPlaylistSource && other.playlistId == playlistId;

  @override
  int get hashCode => Object.hash(kind, playlistId);
}

@immutable
final class CatalogExportAlbumsSource extends CatalogExportSource {
  final List<String> albumIds;

  const CatalogExportAlbumsSource(this.albumIds);

  @override
  String get kind => 'albums';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'album_ids': albumIds,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogExportAlbumsSource && listEquals(other.albumIds, albumIds);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(albumIds));
}

@immutable
final class CatalogExportTracksSource extends CatalogExportSource {
  final List<String> trackIds;

  const CatalogExportTracksSource(this.trackIds);

  @override
  String get kind => 'tracks';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'track_ids': trackIds,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogExportTracksSource && listEquals(other.trackIds, trackIds);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(trackIds));
}

@immutable
class CatalogExportRequest {
  final CatalogExportSource source;
  final CatalogExportFormat format;
  final String outputPath;
  final bool includeHeaders;
  final bool utf8Bom;

  const CatalogExportRequest({
    required this.source,
    this.format = CatalogExportFormat.csv,
    this.outputPath = '',
    this.includeHeaders = true,
    this.utf8Bom = true,
  });

  factory CatalogExportRequest.fromJson(Map<String, dynamic> json) {
    final rawSource = json['source'];
    return CatalogExportRequest(
      source: rawSource is Map
          ? CatalogExportSource.fromJson(Map<String, dynamic>.from(rawSource))
          : const CatalogExportFocusQuerySource(FocusQuery()),
      format: CatalogExportFormat.fromJson(json['format']?.toString()),
      outputPath: json['output_path']?.toString() ?? '',
      includeHeaders: _readBool(json['include_headers'], fallback: true),
      utf8Bom: _readBool(json['utf8_bom'], fallback: true),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source': source.toJson(),
    'format': format.toJson(),
    'output_path': outputPath,
    'include_headers': includeHeaders,
    'utf8_bom': utf8Bom,
  };
}

@immutable
class CatalogExportResult {
  final CatalogExportFormat format;
  final String outputPath;
  final int rowCount;
  final int sizeBytes;
  final String? content;

  const CatalogExportResult({
    required this.format,
    this.outputPath = '',
    this.rowCount = 0,
    this.sizeBytes = 0,
    this.content,
  });

  factory CatalogExportResult.fromJson(Map<String, dynamic> json) =>
      CatalogExportResult(
        format: CatalogExportFormat.fromJson(json['format']?.toString()),
        outputPath: json['output_path']?.toString() ?? '',
        rowCount: (json['row_count'] as num?)?.toInt() ?? 0,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        content: json['content']?.toString(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'format': format.toJson(),
    'output_path': outputPath,
    'row_count': rowCount,
    'size_bytes': sizeBytes,
    if (content != null) 'content': content,
  };
}

@immutable
class AudioExportRequest {
  final CatalogExportSource source;
  final String destinationDir;
  final bool preserveStructure;
  final bool overwriteExisting;
  final bool generateM3u8;
  final String? playlistFilename;

  const AudioExportRequest({
    required this.source,
    required this.destinationDir,
    this.preserveStructure = true,
    this.overwriteExisting = false,
    this.generateM3u8 = true,
    this.playlistFilename,
  });

  factory AudioExportRequest.fromJson(Map<String, dynamic> json) {
    final rawSource = json['source'];
    return AudioExportRequest(
      source: rawSource is Map
          ? CatalogExportSource.fromJson(Map<String, dynamic>.from(rawSource))
          : const CatalogExportFocusQuerySource(FocusQuery()),
      destinationDir: json['destination_dir']?.toString() ?? '',
      preserveStructure: _readBool(json['preserve_structure'], fallback: true),
      overwriteExisting: _readBool(json['overwrite_existing']),
      generateM3u8: _readBool(json['generate_m3u8'], fallback: true),
      playlistFilename: json['playlist_filename']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'source': source.toJson(),
    'destination_dir': destinationDir,
    'preserve_structure': preserveStructure,
    'overwrite_existing': overwriteExisting,
    'generate_m3u8': generateM3u8,
    if (playlistFilename != null) 'playlist_filename': playlistFilename,
  };
}

/// Lifecycle status of a background audio file copy/export job.
enum AudioExportStatus {
  running('running'),
  completed('completed'),
  cancelled('cancelled'),
  failed('failed');

  final String wireName;

  const AudioExportStatus(this.wireName);

  String toJson() => wireName;

  static AudioExportStatus fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'completed' => AudioExportStatus.completed,
        'cancelled' => AudioExportStatus.cancelled,
        'failed' => AudioExportStatus.failed,
        _ => AudioExportStatus.running,
      };
}

/// Live progress & final report of a background audio export job.
@immutable
class AudioExportProgress {
  final String jobId;
  final AudioExportStatus status;
  final String destinationDir;
  final int totalTracks;
  final int copiedTracks;
  final int skippedTracks;
  final int failedTracks;
  final int bytesCopied;
  final String? currentFile;
  final String? m3u8Path;
  final List<String> errors;

  const AudioExportProgress({
    required this.jobId,
    required this.status,
    required this.destinationDir,
    this.totalTracks = 0,
    this.copiedTracks = 0,
    this.skippedTracks = 0,
    this.failedTracks = 0,
    this.bytesCopied = 0,
    this.currentFile,
    this.m3u8Path,
    this.errors = const <String>[],
  });

  factory AudioExportProgress.fromJson(Map<String, dynamic> json) =>
      AudioExportProgress(
        jobId: json['job_id']?.toString() ?? '',
        status: AudioExportStatus.fromJson(json['status']?.toString()),
        destinationDir: json['destination_dir']?.toString() ?? '',
        totalTracks: (json['total_tracks'] as num?)?.toInt() ?? 0,
        copiedTracks: (json['copied_tracks'] as num?)?.toInt() ?? 0,
        skippedTracks: (json['skipped_tracks'] as num?)?.toInt() ?? 0,
        failedTracks: (json['failed_tracks'] as num?)?.toInt() ?? 0,
        bytesCopied: (json['bytes_copied'] as num?)?.toInt() ?? 0,
        currentFile: json['current_file']?.toString(),
        m3u8Path: json['m3u8_path']?.toString(),
        errors: _readStringList(json['errors']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'job_id': jobId,
    'status': status.toJson(),
    'destination_dir': destinationDir,
    'total_tracks': totalTracks,
    'copied_tracks': copiedTracks,
    'skipped_tracks': skippedTracks,
    'failed_tracks': failedTracks,
    'bytes_copied': bytesCopied,
    if (currentFile != null) 'current_file': currentFile,
    if (m3u8Path != null) 'm3u8_path': m3u8Path,
    'errors': errors,
  };
}
