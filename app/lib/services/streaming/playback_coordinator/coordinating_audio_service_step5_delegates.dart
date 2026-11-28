part of '../streaming_playback_coordinator.dart';

/// Forwards all Library Step 5 Static Playlist / Improver, Bulk Edit, Album
/// Assets, and Backup / Restore / Export methods on [CoordinatingAudioService].
mixin _CoordinatingAudioServiceStep5DelegatesMixin implements AudioService {
  AudioService get inner;

  @override
  Stream<void> get libraryReloadedStream => inner.libraryReloadedStream;

  @override
  Future<List<StaticPlaylistSummary>> listStaticPlaylists() =>
      inner.listStaticPlaylists();

  @override
  Future<StaticPlaylistDetail?> createStaticPlaylist(
    CreateStaticPlaylistRequest req,
  ) => inner.createStaticPlaylist(req);

  @override
  Future<StaticPlaylistDetail?> getStaticPlaylistDetail(String playlistId) =>
      inner.getStaticPlaylistDetail(playlistId);

  @override
  Future<bool> deleteStaticPlaylist(String playlistId) =>
      inner.deleteStaticPlaylist(playlistId);

  @override
  Future<StaticPlaylistDetail?> addTracksToStaticPlaylist(
    String playlistId,
    AddStaticPlaylistTracksRequest req,
  ) => inner.addTracksToStaticPlaylist(playlistId, req);

  @override
  Future<PlaylistImprovementReport?> analyzePlaylistImprovements(
    String playlistId,
  ) => inner.analyzePlaylistImprovements(playlistId);

  @override
  Future<ApplyPlaylistImprovementsResult?> applyPlaylistImprovements(
    String playlistId,
    ApplyPlaylistImprovementsRequest req,
  ) => inner.applyPlaylistImprovements(playlistId, req);

  @override
  Future<List<PlaylistSnapshotRecord>> listPlaylistSnapshots(
    String playlistId,
  ) => inner.listPlaylistSnapshots(playlistId);

  @override
  Future<RevertPlaylistSnapshotResult?> revertPlaylistSnapshot(
    String snapshotId,
  ) => inner.revertPlaylistSnapshot(snapshotId);

  @override
  Future<BulkEditSummary?> getBulkEditSummary(
    BulkEditEntityType entityType,
    List<String> entityIds,
  ) => inner.getBulkEditSummary(entityType, entityIds);

  @override
  Future<BulkEditResult?> applyBulkEdit(
    BulkEditEntityType entityType,
    List<String> entityIds,
    BulkEditPatch patch,
  ) => inner.applyBulkEdit(entityType, entityIds, patch);

  @override
  Future<AlbumAssetsResponse?> getAlbumAssets(String albumVersionOrAlbumId) =>
      inner.getAlbumAssets(albumVersionOrAlbumId);

  @override
  Future<Uint8List?> readAlbumAssetBytes(String assetId) =>
      inner.readAlbumAssetBytes(assetId);

  @override
  Future<bool> openAlbumPdfAsset(AlbumAssetRecord asset) =>
      inner.openAlbumPdfAsset(asset);

  @override
  Future<BackupSettings?> getBackupSettings() => inner.getBackupSettings();

  @override
  Future<BackupSettings?> updateBackupSettings({
    required String backupDir,
    required BackupScheduleMode scheduleMode,
    required int maxKeep,
  }) => inner.updateBackupSettings(
    backupDir: backupDir,
    scheduleMode: scheduleMode,
    maxKeep: maxKeep,
  );

  @override
  Future<List<BackupHistoryRecord>> listBackupHistory({int limit = 50}) =>
      inner.listBackupHistory(limit: limit);

  @override
  Future<BackupHistoryRecord?> createLibraryBackup({
    BackupTriggerMode triggerMode = BackupTriggerMode.manual,
    String? backupDirOverride,
  }) => inner.createLibraryBackup(
    triggerMode: triggerMode,
    backupDirOverride: backupDirOverride,
  );

  @override
  Future<RestoreBackupResult?> restoreLibraryBackup(String backupPath) =>
      inner.restoreLibraryBackup(backupPath);

  @override
  Future<CatalogExportResult?> exportCatalog(CatalogExportRequest req) =>
      inner.exportCatalog(req);

  @override
  Future<AudioExportProgress?> startAudioExport(AudioExportRequest req) =>
      inner.startAudioExport(req);

  @override
  Future<AudioExportProgress?> getAudioExportProgress(String jobId) =>
      inner.getAudioExportProgress(jobId);

  @override
  Future<bool> cancelAudioExport(String jobId) =>
      inner.cancelAudioExport(jobId);

  @override
  Future<TrackFileInfo?> getTrackFileInfo(String trackId) =>
      inner.getTrackFileInfo(trackId);

  @override
  Future<TrackVisibilityResult?> setTrackHidden(
    String trackId,
    bool isHidden,
  ) => inner.setTrackHidden(trackId, isHidden);

  @override
  Future<TrackFileInfo?> rescanTrack(String trackId) =>
      inner.rescanTrack(trackId);

  @override
  Future<ReidentifyTrackResult?> reidentifyTrack(String trackId) =>
      inner.reidentifyTrack(trackId);

  @override
  Future<TrackAnalysisResult?> reanalyzeTrack(String trackId) =>
      inner.reanalyzeTrack(trackId);

  @override
  Future<DeleteTrackResult?> deleteTrack(
    String trackId, {
    TrackDeleteMode mode = TrackDeleteMode.libraryOnly,
  }) => inner.deleteTrack(trackId, mode: mode);

  @override
  Future<List<TrackInfo>> getLibraryTracksFiltered({
    int limit = 200,
    bool includeHidden = false,
  }) => inner.getLibraryTracksFiltered(
    limit: limit,
    includeHidden: includeHidden,
  );

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetailFiltered(
    String albumId, {
    bool includeHidden = false,
  }) => inner.getAlbumDetailFiltered(albumId, includeHidden: includeHidden);

  @override
  Future<bool> revealTrackFolder(String filePath) =>
      inner.revealTrackFolder(filePath);
}
