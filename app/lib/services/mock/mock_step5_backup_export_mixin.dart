part of '../mock_audio_service.dart';

/// Rich in-memory MockAudioService implementation for Step 5 Database Backup /
/// Restore and Catalog / Audio Export.
mixin _MockStep5BackupExportMixin
    on
        _MockAudioServiceBase,
        _MockAlbumGroupingMixin,
        _MockFocusTagsFoldersMixin,
        _MockStep4Mixin,
        _MockStep5Mixin {
  BackupSettings _mockBackupSettings = const BackupSettings(
    backupDir: '',
    scheduleMode: BackupScheduleMode.off,
    maxKeep: 10,
    resolvedBackupDir: r'C:\Users\Mock\AppData\Local\LuminaAudio\backups',
  );
  final List<BackupHistoryRecord> _mockBackupHistory = <BackupHistoryRecord>[];
  final Map<String, AudioExportProgress> _mockAudioExportJobs =
      <String, AudioExportProgress>{};

  @override
  Future<BackupSettings?> getBackupSettings() async => _mockBackupSettings;

  @override
  Future<BackupSettings?> updateBackupSettings({
    required String backupDir,
    required BackupScheduleMode scheduleMode,
    required int maxKeep,
  }) async {
    final trimmed = backupDir.trim();
    final clampedKeep = maxKeep.clamp(1, 100);
    _mockBackupSettings = BackupSettings(
      backupDir: trimmed,
      scheduleMode: scheduleMode,
      maxKeep: clampedKeep,
      resolvedBackupDir: trimmed.isNotEmpty
          ? trimmed
          : r'C:\Users\Mock\AppData\Local\LuminaAudio\backups',
    );
    return _mockBackupSettings;
  }

  @override
  Future<List<BackupHistoryRecord>> listBackupHistory({int limit = 50}) async =>
      _mockBackupHistory.take(limit.clamp(1, 500)).toList(growable: false);

  @override
  Future<BackupHistoryRecord?> createLibraryBackup({
    BackupTriggerMode triggerMode = BackupTriggerMode.manual,
    String? backupDirOverride,
  }) async {
    final id = _nextStep5Id('bkp');
    final dir = (backupDirOverride != null && backupDirOverride.trim().isNotEmpty)
        ? backupDirOverride.trim()
        : _mockBackupSettings.resolvedBackupDir;
    final stem = 'lumina_backup_$id';
    final record = BackupHistoryRecord(
      id: id,
      triggerMode: triggerMode,
      backupPath: '$dir${Platform.pathSeparator}$stem.db',
      manifestPath: '$dir${Platform.pathSeparator}$stem.manifest.json',
      sha256: 'mocksha256${id.padLeft(54, '0')}',
      sizeBytes: 262144,
      schemaVersion: 12,
      status: 'completed',
      createdAt: _nowIso(),
      existsOnDisk: true,
    );
    _mockBackupHistory.insert(0, record);

    var kept = 0;
    for (var i = 0; i < _mockBackupHistory.length; i++) {
      final r = _mockBackupHistory[i];
      if (r.status == 'completed' && r.triggerMode != BackupTriggerMode.preRestore) {
        kept++;
        if (kept > _mockBackupSettings.maxKeep) {
          _mockBackupHistory[i] = BackupHistoryRecord(
            id: r.id,
            triggerMode: r.triggerMode,
            backupPath: r.backupPath,
            manifestPath: r.manifestPath,
            sha256: r.sha256,
            sizeBytes: r.sizeBytes,
            schemaVersion: r.schemaVersion,
            status: 'pruned',
            createdAt: r.createdAt,
            existsOnDisk: false,
          );
        }
      }
    }
    return record;
  }

  @override
  Future<RestoreBackupResult?> restoreLibraryBackup(String backupPath) async {
    final trimmed = backupPath.trim();
    if (trimmed.isEmpty) return null;
    final preRestore = await createLibraryBackup(
      triggerMode: BackupTriggerMode.preRestore,
    );
    final existing = _mockBackupHistory
        .where((r) => r.backupPath == trimmed)
        .firstOrNull;
    final res = RestoreBackupResult(
      restoredBackupId: existing?.id ?? _nextStep5Id('restored'),
      preRestoreBackupId: preRestore?.id,
      restoredFromPath: trimmed,
      schemaVersion: 12,
      tableCounts: <String, int>{
        'canonical_albums': _ensureAlbumGroups().length,
        'track_sources': _queue.length,
        'playlists': _ensureStaticPlaylists().length,
      },
    );
    if (!_disposed && !_libraryReloadedController.isClosed) {
      _libraryReloadedController.add(null);
    }
    return res;
  }

  int _resolveMockExportCount(CatalogExportSource source) => switch (source) {
    CatalogExportFocusQuerySource() => _queue.length,
    CatalogExportStaticPlaylistSource(:final playlistId) =>
      _ensureStaticPlaylists()
              .where((p) => p.id == playlistId)
              .firstOrNull
              ?.items
              .length ??
          0,
    CatalogExportSmartPlaylistSource() => _queue.length,
    CatalogExportAlbumsSource(:final albumIds) => albumIds.length,
    CatalogExportTracksSource(:final trackIds) => trackIds.length,
  };

  @override
  Future<CatalogExportResult?> exportCatalog(CatalogExportRequest req) async {
    final rows = _resolveMockExportCount(req.source);
    return CatalogExportResult(
      format: req.format,
      outputPath: req.outputPath,
      rowCount: rows,
      sizeBytes: rows * 128 + (req.includeHeaders ? 160 : 0),
    );
  }

  @override
  Future<AudioExportProgress?> startAudioExport(AudioExportRequest req) async {
    final jobId = _nextStep5Id('exp');
    final total = _resolveMockExportCount(req.source);
    final progress = AudioExportProgress(
      jobId: jobId,
      status: AudioExportStatus.completed,
      destinationDir: req.destinationDir,
      totalTracks: total,
      copiedTracks: total,
      skippedTracks: 0,
      failedTracks: 0,
      bytesCopied: total * 4 * 1024 * 1024,
      m3u8Path: req.generateM3u8
          ? '${req.destinationDir}${Platform.pathSeparator}${req.playlistFilename ?? 'export.m3u8'}'
          : null,
    );
    _mockAudioExportJobs[jobId] = progress;
    return progress;
  }

  @override
  Future<AudioExportProgress?> getAudioExportProgress(String jobId) async =>
      _mockAudioExportJobs[jobId];

  @override
  Future<bool> cancelAudioExport(String jobId) async {
    final job = _mockAudioExportJobs[jobId];
    if (job == null) return false;
    _mockAudioExportJobs[jobId] = AudioExportProgress(
      jobId: job.jobId,
      status: AudioExportStatus.cancelled,
      destinationDir: job.destinationDir,
      totalTracks: job.totalTracks,
      copiedTracks: job.copiedTracks,
      skippedTracks: job.skippedTracks,
      failedTracks: job.failedTracks,
      bytesCopied: job.bytesCopied,
      currentFile: job.currentFile,
      m3u8Path: job.m3u8Path,
      errors: job.errors,
    );
    return true;
  }
}
