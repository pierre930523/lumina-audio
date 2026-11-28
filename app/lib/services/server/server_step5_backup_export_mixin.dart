part of '../server_audio_service.dart';

/// Implements Library Step 5 Database Backup / Restore and Catalog / Audio
/// Export over REST.
mixin _ServerStep5BackupExportMixin on _ServerAudioServiceBase {
  @override
  Future<BackupSettings?> getBackupSettings() async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/backups/settings',
    );
    if (code == 200 && data is Map) {
      return BackupSettings.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<BackupSettings?> updateBackupSettings({
    required String backupDir,
    required BackupScheduleMode scheduleMode,
    required int maxKeep,
  }) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/backups/settings',
      body: <String, dynamic>{
        'backup_dir': backupDir,
        'schedule_mode': scheduleMode.toJson(),
        'max_keep': maxKeep,
      },
    );
    if (code == 200 && data is Map) {
      return BackupSettings.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<List<BackupHistoryRecord>> listBackupHistory({int limit = 50}) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/backups?limit=$limit',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map(
            (e) => BackupHistoryRecord.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false);
    }
    return const <BackupHistoryRecord>[];
  }

  @override
  Future<BackupHistoryRecord?> createLibraryBackup({
    BackupTriggerMode triggerMode = BackupTriggerMode.manual,
    String? backupDirOverride,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/backups',
      body: <String, dynamic>{
        'trigger_mode': triggerMode.toJson(),
        'backup_dir_override': ?backupDirOverride,
      },
      timeout: const Duration(seconds: 60),
    );
    if ((code == 200 || code == 201) && data is Map) {
      return BackupHistoryRecord.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<RestoreBackupResult?> restoreLibraryBackup(String backupPath) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/backups/restore',
      body: <String, dynamic>{'backup_path': backupPath},
      timeout: const Duration(seconds: 60),
    );
    if (code == 200 && data is Map) {
      final res = RestoreBackupResult.fromJson(Map<String, dynamic>.from(data));
      await _scheduleReloadTracksFromServer();
      if (!_disposed && !_libraryReloadedController.isClosed) {
        _libraryReloadedController.add(null);
      }
      return res;
    }
    return null;
  }

  @override
  Future<CatalogExportResult?> exportCatalog(CatalogExportRequest req) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/export/catalog',
      body: req.toJson(),
      timeout: const Duration(seconds: 60),
    );
    if (code == 200 && data is Map) {
      return CatalogExportResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<AudioExportProgress?> startAudioExport(AudioExportRequest req) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/export/audio',
      body: req.toJson(),
      timeout: const Duration(seconds: 30),
    );
    if ((code == 200 || code == 201 || code == 202) && data is Map) {
      return AudioExportProgress.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<AudioExportProgress?> getAudioExportProgress(String jobId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/export/audio/${Uri.encodeComponent(jobId)}',
    );
    if (code == 200 && data is Map) {
      return AudioExportProgress.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> cancelAudioExport(String jobId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/export/audio/${Uri.encodeComponent(jobId)}/cancel',
    );
    if (code != 200 && code != 204) return false;
    if (data is Map && data.containsKey('cancelled')) {
      return data['cancelled'] == true;
    }
    return true;
  }
}
