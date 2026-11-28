import 'package:flutter/foundation.dart';

/// Metadata precedence policy for three-layer non-destructive resolution
/// (`user_edits` always takes precedence over `file_meta` and `cloud_meta`).
enum MetadataPolicy {
  inherit,
  file,
  cloud;

  String toJson() => switch (this) {
    MetadataPolicy.inherit => 'inherit',
    MetadataPolicy.file => 'file',
    MetadataPolicy.cloud => 'cloud',
  };

  /// Parses an entity-level policy (defaults to [MetadataPolicy.inherit]).
  static MetadataPolicy fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'file' => MetadataPolicy.file,
        'cloud' => MetadataPolicy.cloud,
        'inherit' => MetadataPolicy.inherit,
        _ => MetadataPolicy.inherit,
      };

  /// Parses the global `default_metadata_policy` setting (defaults to
  /// [MetadataPolicy.file]; never returns [MetadataPolicy.inherit]).
  static MetadataPolicy fromGlobalJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'cloud' => MetadataPolicy.cloud,
        _ => MetadataPolicy.file,
      };

  String get displayLabel => switch (this) {
    MetadataPolicy.inherit => '跟隨全域',
    MetadataPolicy.file => '優先本機標籤',
    MetadataPolicy.cloud => '優先雲端資料',
  };
}

/// Summary returned by one-click batch rescan of all active skipped files.
@immutable
class BatchRescanSkippedResult {
  final int total;
  final int resolved;
  final int removedMissing;
  final int stillSkipped;

  const BatchRescanSkippedResult({
    this.total = 0,
    this.resolved = 0,
    this.removedMissing = 0,
    this.stillSkipped = 0,
  });

  factory BatchRescanSkippedResult.fromJson(Map<String, dynamic> json) =>
      BatchRescanSkippedResult(
        total: (json['total'] as num?)?.toInt() ?? 0,
        resolved: (json['resolved'] as num?)?.toInt() ?? 0,
        removedMissing: (json['removed_missing'] as num?)?.toInt() ?? 0,
        stillSkipped: (json['still_skipped'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'total': total,
    'resolved': resolved,
    'removed_missing': removedMissing,
    'still_skipped': stillSkipped,
  };
}

/// Read-only preview counts for the "Clean Up Library" tool.
@immutable
class LibraryCleanupPreview {
  final int missingTracksCount;
  final int emptyAlbumVersionsCount;
  final int emptyAlbumsCount;
  final int orphanArtistsCount;
  final int orphanArtworkFilesCount;
  final int orphanArtworkBytes;
  final List<String> offlineRoots;
  final List<String> onlineRootsChecked;

  const LibraryCleanupPreview({
    this.missingTracksCount = 0,
    this.emptyAlbumVersionsCount = 0,
    this.emptyAlbumsCount = 0,
    this.orphanArtistsCount = 0,
    this.orphanArtworkFilesCount = 0,
    this.orphanArtworkBytes = 0,
    this.offlineRoots = const <String>[],
    this.onlineRootsChecked = const <String>[],
  });

  int get emptyAlbumsAndVersionsTotal =>
      emptyAlbumVersionsCount + emptyAlbumsCount;

  int get totalCleanableCount =>
      missingTracksCount +
      emptyAlbumVersionsCount +
      emptyAlbumsCount +
      orphanArtistsCount +
      orphanArtworkFilesCount;

  String get formattedArtworkBytes {
    if (orphanArtworkBytes <= 0) return '0 B';
    if (orphanArtworkBytes < 1024) return '$orphanArtworkBytes B';
    if (orphanArtworkBytes < 1024 * 1024) {
      return '${(orphanArtworkBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (orphanArtworkBytes < 1024 * 1024 * 1024) {
      return '${(orphanArtworkBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(orphanArtworkBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  factory LibraryCleanupPreview.fromJson(Map<String, dynamic> json) =>
      LibraryCleanupPreview(
        missingTracksCount:
            (json['missing_tracks_count'] as num?)?.toInt() ?? 0,
        emptyAlbumVersionsCount:
            (json['empty_album_versions_count'] as num?)?.toInt() ?? 0,
        emptyAlbumsCount: (json['empty_albums_count'] as num?)?.toInt() ?? 0,
        orphanArtistsCount:
            (json['orphan_artists_count'] as num?)?.toInt() ?? 0,
        orphanArtworkFilesCount:
            (json['orphan_artwork_files_count'] as num?)?.toInt() ?? 0,
        orphanArtworkBytes:
            (json['orphan_artwork_bytes'] as num?)?.toInt() ?? 0,
        offlineRoots: (json['offline_roots'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        onlineRootsChecked:
            (json['online_roots_checked'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'missing_tracks_count': missingTracksCount,
    'empty_album_versions_count': emptyAlbumVersionsCount,
    'empty_albums_count': emptyAlbumsCount,
    'orphan_artists_count': orphanArtistsCount,
    'orphan_artwork_files_count': orphanArtworkFilesCount,
    'orphan_artwork_bytes': orphanArtworkBytes,
    'offline_roots': offlineRoots,
    'online_roots_checked': onlineRootsChecked,
  };
}

/// User-selected categories for executing a library cleanup transaction.
@immutable
class LibraryCleanupOptions {
  final bool removeMissingTracks;
  final bool removeEmptyAlbums;
  final bool removeOrphanArtists;
  final bool removeOrphanArtworkCache;

  const LibraryCleanupOptions({
    this.removeMissingTracks = true,
    this.removeEmptyAlbums = true,
    this.removeOrphanArtists = true,
    this.removeOrphanArtworkCache = true,
  });

  bool get hasAnySelected =>
      removeMissingTracks ||
      removeEmptyAlbums ||
      removeOrphanArtists ||
      removeOrphanArtworkCache;

  factory LibraryCleanupOptions.fromJson(Map<String, dynamic> json) =>
      LibraryCleanupOptions(
        removeMissingTracks: json['remove_missing_tracks'] == true,
        removeEmptyAlbums: json['remove_empty_albums'] == true,
        removeOrphanArtists: json['remove_orphan_artists'] == true,
        removeOrphanArtworkCache: json['remove_orphan_artwork_cache'] == true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'remove_missing_tracks': removeMissingTracks,
    'remove_empty_albums': removeEmptyAlbums,
    'remove_orphan_artists': removeOrphanArtists,
    'remove_orphan_artwork_cache': removeOrphanArtworkCache,
  };
}

/// Result counts returned after executing a library cleanup transaction.
@immutable
class LibraryCleanupResult {
  final int removedTracks;
  final int removedAlbumVersions;
  final int removedAlbums;
  final int removedArtists;
  final int removedArtworkFiles;
  final int freedArtworkBytes;
  final List<String> skippedOfflineRoots;

  const LibraryCleanupResult({
    this.removedTracks = 0,
    this.removedAlbumVersions = 0,
    this.removedAlbums = 0,
    this.removedArtists = 0,
    this.removedArtworkFiles = 0,
    this.freedArtworkBytes = 0,
    this.skippedOfflineRoots = const <String>[],
  });

  int get totalRemovedCount =>
      removedTracks +
      removedAlbumVersions +
      removedAlbums +
      removedArtists +
      removedArtworkFiles;

  factory LibraryCleanupResult.fromJson(Map<String, dynamic> json) =>
      LibraryCleanupResult(
        removedTracks: (json['removed_tracks'] as num?)?.toInt() ?? 0,
        removedAlbumVersions:
            (json['removed_album_versions'] as num?)?.toInt() ?? 0,
        removedAlbums: (json['removed_albums'] as num?)?.toInt() ?? 0,
        removedArtists: (json['removed_artists'] as num?)?.toInt() ?? 0,
        removedArtworkFiles:
            (json['removed_artwork_files'] as num?)?.toInt() ?? 0,
        freedArtworkBytes: (json['freed_artwork_bytes'] as num?)?.toInt() ?? 0,
        skippedOfflineRoots:
            (json['skipped_offline_roots'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'removed_tracks': removedTracks,
    'removed_album_versions': removedAlbumVersions,
    'removed_albums': removedAlbums,
    'removed_artists': removedArtists,
    'removed_artwork_files': removedArtworkFiles,
    'freed_artwork_bytes': freedArtworkBytes,
    'skipped_offline_roots': skippedOfflineRoots,
  };
}
