part of '../mock_audio_service.dart';

mixin _MockMaintenanceMixin on _MockAudioServiceBase {
  @visibleForTesting
  void seedEntityMetadataLayers(
    String entityType,
    String entityId, {
    Map<String, dynamic>? fileMeta,
    Map<String, dynamic>? cloudMeta,
    Map<String, dynamic>? userEdits,
    MetadataPolicy? policy,
  }) {
    final key = '$entityType:$entityId';
    if (fileMeta != null) {
      _entityFileMeta[key] = Map<String, dynamic>.from(fileMeta);
    }
    if (cloudMeta != null) {
      _entityCloudMeta[key] = Map<String, dynamic>.from(cloudMeta);
    }
    if (userEdits != null) {
      _entityUserEdits[key] = Map<String, dynamic>.from(userEdits);
    }
    if (policy != null) {
      _entityMetaPolicies[key] = policy;
    }
  }

  @visibleForTesting
  void seedCleanupPreview(LibraryCleanupPreview preview) {
    _mockCleanupPreview = preview;
  }

  @visibleForTesting
  LibraryCleanupOptions? get lastCleanupOptions => _lastCleanupOptions;

  @override
  Future<MetadataPolicy> getDefaultMetadataPolicy() async =>
      _defaultMetadataPolicy;

  @override
  Future<bool> setDefaultMetadataPolicy(MetadataPolicy policy) async {
    _defaultMetadataPolicy =
        policy == MetadataPolicy.cloud ? MetadataPolicy.cloud : MetadataPolicy.file;
    return true;
  }

  @override
  Future<bool> setEntityMetaPolicy(
    String entityType,
    String entityId,
    MetadataPolicy policy,
  ) async {
    _entityMetaPolicies['$entityType:$entityId'] = policy;
    return true;
  }

  @override
  Future<bool> setEntityUserEdits(
    String entityType,
    String entityId,
    Map<String, dynamic> edits,
  ) async {
    final key = '$entityType:$entityId';
    final target = _entityUserEdits.putIfAbsent(key, () => <String, dynamic>{});
    final ovMap = _metadataOverrides.putIfAbsent(
      key,
      () => <String, MetadataOverrideRecord>{},
    );
    final nowIso = DateTime.now().toUtc().toIso8601String();
    for (final entry in edits.entries) {
      if (entry.value == null) {
        target.remove(entry.key);
        ovMap.remove(entry.key);
      } else {
        target[entry.key] = entry.value;
        ovMap[entry.key] = MetadataOverrideRecord(
          entityType: entityType,
          entityId: entityId,
          fieldName: entry.key,
          valueJson: jsonEncode(entry.value),
          sourceLayer: MetadataLayer.userEdit,
          updatedAt: nowIso,
        );
      }
    }
    if (target.isEmpty) {
      _entityUserEdits.remove(key);
    }
    return true;
  }

  @override
  Future<bool> revertEntityToFileMeta(
    String entityType,
    String entityId,
  ) async {
    final key = '$entityType:$entityId';
    _entityUserEdits.remove(key);
    _metadataOverrides.remove(key);
    return true;
  }

  @override
  Future<BatchRescanSkippedResult> rescanAllSkippedFiles() async {
    final active = _skippedFiles.where((f) => !f.dismissed).toList();
    var resolved = 0;
    var removedMissing = 0;
    var stillSkipped = 0;
    final remaining = <SkippedFileRecord>[];

    for (final item in _skippedFiles) {
      if (item.dismissed) {
        remaining.add(item);
        continue;
      }
      if (item.reason == SkipReason.ioError) {
        removedMissing++;
      } else if (item.reason == SkipReason.corruptHeader ||
          item.reason == SkipReason.garbledTags) {
        resolved++;
      } else {
        stillSkipped++;
        remaining.add(item);
      }
    }
    _skippedFiles
      ..clear()
      ..addAll(remaining);

    return BatchRescanSkippedResult(
      total: active.length,
      resolved: resolved,
      removedMissing: removedMissing,
      stillSkipped: stillSkipped,
    );
  }

  @override
  Future<LibraryCleanupPreview> previewLibraryCleanup() async =>
      _mockCleanupPreview;

  @override
  Future<LibraryCleanupResult> executeLibraryCleanup(
    LibraryCleanupOptions options,
  ) async {
    _lastCleanupOptions = options;
    final cur = _mockCleanupPreview;
    final removedTracks =
        options.removeMissingTracks ? cur.missingTracksCount : 0;
    final removedVersions =
        options.removeEmptyAlbums ? cur.emptyAlbumVersionsCount : 0;
    final removedAlbums =
        options.removeEmptyAlbums ? cur.emptyAlbumsCount : 0;
    final removedArtists =
        options.removeOrphanArtists ? cur.orphanArtistsCount : 0;
    final removedArtwork =
        options.removeOrphanArtworkCache ? cur.orphanArtworkFilesCount : 0;
    final freedBytes =
        options.removeOrphanArtworkCache ? cur.orphanArtworkBytes : 0;

    _mockCleanupPreview = LibraryCleanupPreview(
      missingTracksCount:
          options.removeMissingTracks ? 0 : cur.missingTracksCount,
      emptyAlbumVersionsCount:
          options.removeEmptyAlbums ? 0 : cur.emptyAlbumVersionsCount,
      emptyAlbumsCount: options.removeEmptyAlbums ? 0 : cur.emptyAlbumsCount,
      orphanArtistsCount:
          options.removeOrphanArtists ? 0 : cur.orphanArtistsCount,
      orphanArtworkFilesCount:
          options.removeOrphanArtworkCache ? 0 : cur.orphanArtworkFilesCount,
      orphanArtworkBytes:
          options.removeOrphanArtworkCache ? 0 : cur.orphanArtworkBytes,
      offlineRoots: cur.offlineRoots,
      onlineRootsChecked: cur.onlineRootsChecked,
    );

    return LibraryCleanupResult(
      removedTracks: removedTracks,
      removedAlbumVersions: removedVersions,
      removedAlbums: removedAlbums,
      removedArtists: removedArtists,
      removedArtworkFiles: removedArtwork,
      freedArtworkBytes: freedBytes,
      skippedOfflineRoots: cur.offlineRoots,
    );
  }
}
