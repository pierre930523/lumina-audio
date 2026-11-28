part of 'audio_service.dart';

/// Library Step 5 contract mixin: Static Playlists & Playlist Improver,
/// Tri-State Bulk Metadata Editor, Album Assets (PDF Booklets & Multi-Image
/// Gallery), and WAL Safe Hot Backup / Restore / Catalog & Audio Export.
mixin AudioServiceStep5Mixin {
  /// Emits whenever the underlying SQLite library database is hot-swapped or
  /// restored so UI caches reload fresh state immediately.
  Stream<void> get libraryReloadedStream => const Stream<void>.empty();

  // ---------------------------------------------------------------------------
  // Static Playlists & Playlist Improver
  // ---------------------------------------------------------------------------

  Future<List<StaticPlaylistSummary>> listStaticPlaylists() async =>
      const <StaticPlaylistSummary>[];

  Future<StaticPlaylistDetail?> createStaticPlaylist(
    CreateStaticPlaylistRequest req,
  ) async => null;

  Future<StaticPlaylistDetail?> getStaticPlaylistDetail(
    String playlistId,
  ) async => null;

  Future<bool> deleteStaticPlaylist(String playlistId) async => false;

  Future<StaticPlaylistDetail?> addTracksToStaticPlaylist(
    String playlistId,
    AddStaticPlaylistTracksRequest req,
  ) async => null;

  Future<PlaylistImprovementReport?> analyzePlaylistImprovements(
    String playlistId,
  ) async => null;

  Future<ApplyPlaylistImprovementsResult?> applyPlaylistImprovements(
    String playlistId,
    ApplyPlaylistImprovementsRequest req,
  ) async => null;

  Future<List<PlaylistSnapshotRecord>> listPlaylistSnapshots(
    String playlistId,
  ) async => const <PlaylistSnapshotRecord>[];

  Future<RevertPlaylistSnapshotResult?> revertPlaylistSnapshot(
    String snapshotId,
  ) async => null;

  // ---------------------------------------------------------------------------
  // Tri-State Bulk Metadata Editor
  // ---------------------------------------------------------------------------

  Future<BulkEditSummary?> getBulkEditSummary(
    BulkEditEntityType entityType,
    List<String> entityIds,
  ) async => null;

  Future<BulkEditResult?> applyBulkEdit(
    BulkEditEntityType entityType,
    List<String> entityIds,
    BulkEditPatch patch,
  ) async => null;

  // ---------------------------------------------------------------------------
  // Album Assets (PDF Booklets & Multi-Image Gallery)
  // ---------------------------------------------------------------------------

  Future<AlbumAssetsResponse?> getAlbumAssets(
    String albumVersionOrAlbumId,
  ) async => null;

  Future<Uint8List?> readAlbumAssetBytes(String assetId) async => null;

  Future<bool> openAlbumPdfAsset(AlbumAssetRecord asset) async => false;

  // ---------------------------------------------------------------------------
  // Database Backup, Restore & Catalog / Audio Export
  // ---------------------------------------------------------------------------

  Future<BackupSettings?> getBackupSettings() async => null;

  Future<BackupSettings?> updateBackupSettings({
    required String backupDir,
    required BackupScheduleMode scheduleMode,
    required int maxKeep,
  }) async => null;

  Future<List<BackupHistoryRecord>> listBackupHistory({int limit = 50}) async =>
      const <BackupHistoryRecord>[];

  Future<BackupHistoryRecord?> createLibraryBackup({
    BackupTriggerMode triggerMode = BackupTriggerMode.manual,
    String? backupDirOverride,
  }) async => null;

  Future<RestoreBackupResult?> restoreLibraryBackup(String backupPath) async =>
      null;

  Future<CatalogExportResult?> exportCatalog(CatalogExportRequest req) async =>
      null;

  Future<AudioExportProgress?> startAudioExport(AudioExportRequest req) async =>
      null;

  Future<AudioExportProgress?> getAudioExportProgress(String jobId) async =>
      null;

  Future<bool> cancelAudioExport(String jobId) async => false;

  // ---------------------------------------------------------------------------
  // Single-Track Actions, Metadata File Info & Hidden Track Filtering
  // ---------------------------------------------------------------------------

  Future<TrackFileInfo?> getTrackFileInfo(String trackId) async => null;

  Future<TrackVisibilityResult?> setTrackHidden(
    String trackId,
    bool isHidden,
  ) async => null;

  Future<TrackFileInfo?> rescanTrack(String trackId) async => null;

  Future<ReidentifyTrackResult?> reidentifyTrack(String trackId) async => null;

  Future<TrackAnalysisResult?> reanalyzeTrack(String trackId) async => null;

  Future<DeleteTrackResult?> deleteTrack(
    String trackId, {
    TrackDeleteMode mode = TrackDeleteMode.libraryOnly,
  }) async => null;

  Future<List<TrackInfo>> getLibraryTracksFiltered({
    int limit = 200,
    bool includeHidden = false,
  }) async {
    return (this as AudioService).getLibraryTracks(limit: limit);
  }

  Future<CanonicalAlbumDetail?> getAlbumDetailFiltered(
    String albumId, {
    bool includeHidden = false,
  }) => (this as AudioService).getAlbumDetail(albumId);

  Future<bool> revealTrackFolder(String filePath) => revealFileInFolder(filePath);
}
