part of '../ffi_audio_service.dart';

/// Implements Library Step 5 Database Backup / Restore and Catalog / Audio
/// Export over FFI.
mixin _FfiStep5BackupExportMixin
    on _FfiAudioServiceBase, _FfiStep5BindingsMixin, _FfiStep5Mixin {
  @override
  Future<BackupSettings?> getBackupSettings() async {
    if (_useRemoteStep5Client) return _remoteClient!.getBackupSettings();
    if (!isNativeBound || _libGetBackupSettingsFn == null) {
      return _delegate.getBackupSettings();
    }
    final raw = await _callReadWorker<String>('get_backup_settings');
    final map = _decodeStep5Map(raw);
    return map != null ? BackupSettings.fromJson(map) : null;
  }

  @override
  Future<BackupSettings?> updateBackupSettings({
    required String backupDir,
    required BackupScheduleMode scheduleMode,
    required int maxKeep,
  }) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.updateBackupSettings(
        backupDir: backupDir,
        scheduleMode: scheduleMode,
        maxKeep: maxKeep,
      );
    }
    if (!isNativeBound || _libUpdateBackupSettingsFn == null) {
      return _delegate.updateBackupSettings(
        backupDir: backupDir,
        scheduleMode: scheduleMode,
        maxKeep: maxKeep,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
      'backup_dir': backupDir,
      'schedule_mode': scheduleMode.toJson(),
      'max_keep': maxKeep,
    });
    final raw = await _callWriteWorker<String>('update_backup_settings', {
      'payloadJson': payload,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? BackupSettings.fromJson(map) : null;
  }

  @override
  Future<List<BackupHistoryRecord>> listBackupHistory({int limit = 50}) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.listBackupHistory(limit: limit);
    }
    if (!isNativeBound || _libListBackupHistoryFn == null) {
      return _delegate.listBackupHistory(limit: limit);
    }
    final raw = await _callReadWorker<String>('list_backup_history', {
      'limit': limit,
    });
    if (_disposed || raw == null || raw.isEmpty) {
      return const <BackupHistoryRecord>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
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
    if (_useRemoteStep5Client) {
      return _remoteClient!.createLibraryBackup(
        triggerMode: triggerMode,
        backupDirOverride: backupDirOverride,
      );
    }
    if (!isNativeBound || _libCreateBackupFn == null) {
      return _delegate.createLibraryBackup(
        triggerMode: triggerMode,
        backupDirOverride: backupDirOverride,
      );
    }
    final payload = jsonEncode(<String, dynamic>{
      'trigger_mode': triggerMode.toJson(),
      'backup_dir_override': ?backupDirOverride,
    });
    final raw = await _callWriteWorker<String>('create_library_backup', {
      'payloadJson': payload,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? BackupHistoryRecord.fromJson(map) : null;
  }

  @override
  Future<RestoreBackupResult?> restoreLibraryBackup(String backupPath) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.restoreLibraryBackup(backupPath);
    }
    if (!isNativeBound || _libRestoreBackupFn == null) {
      return _delegate.restoreLibraryBackup(backupPath);
    }
    final payload = jsonEncode(<String, dynamic>{'backup_path': backupPath});
    final raw = await _callWriteWorker<String>('restore_library_backup', {
      'payloadJson': payload,
    });
    final map = _decodeStep5Map(raw);
    if (map == null) return null;
    final res = RestoreBackupResult.fromJson(map);
    await _reloadTracksFromNativeAsync();
    if (!_disposed && !_libraryReloadedController.isClosed) {
      _libraryReloadedController.add(null);
    }
    return res;
  }

  @override
  Future<CatalogExportResult?> exportCatalog(CatalogExportRequest req) async {
    if (_useRemoteStep5Client) return _remoteClient!.exportCatalog(req);
    if (!isNativeBound || _libExportCatalogFn == null) {
      return _delegate.exportCatalog(req);
    }
    final raw = await _callWriteWorker<String>('export_catalog', {
      'payloadJson': jsonEncode(req.toJson()),
    });
    final map = _decodeStep5Map(raw);
    return map != null ? CatalogExportResult.fromJson(map) : null;
  }

  @override
  Future<AudioExportProgress?> startAudioExport(AudioExportRequest req) async {
    if (_useRemoteStep5Client) return _remoteClient!.startAudioExport(req);
    if (!isNativeBound || _libStartAudioExportFn == null) {
      return _delegate.startAudioExport(req);
    }
    final raw = await _callWriteWorker<String>('start_audio_export', {
      'payloadJson': jsonEncode(req.toJson()),
    });
    final map = _decodeStep5Map(raw);
    return map != null ? AudioExportProgress.fromJson(map) : null;
  }

  @override
  Future<AudioExportProgress?> getAudioExportProgress(String jobId) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.getAudioExportProgress(jobId);
    }
    if (!isNativeBound || _libGetAudioExportProgressFn == null) {
      return _delegate.getAudioExportProgress(jobId);
    }
    final raw = await _callReadWorker<String>('get_audio_export_progress', {
      'jobId': jobId,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? AudioExportProgress.fromJson(map) : null;
  }

  @override
  Future<bool> cancelAudioExport(String jobId) async {
    if (_useRemoteStep5Client) return _remoteClient!.cancelAudioExport(jobId);
    if (!isNativeBound || _libCancelAudioExportFn == null) {
      return _delegate.cancelAudioExport(jobId);
    }
    final rc = await _callWriteWorker<int>('cancel_audio_export', {
      'jobId': jobId,
    });
    return !_disposed && rc == 0;
  }
}
