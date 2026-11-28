part of '../ffi_audio_service.dart';

mixin _FfiIngestionMixin on _FfiAudioServiceBase {
  @override
  Stream<ScanProgressEvent> get scanProgressStream =>
      _scanProgressController.stream;

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.startDirectoryScan(path, force: force);
    }
    if (!isNativeBound || _libScanStartFn == null) {
      return _delegate.startDirectoryScan(path, force: force);
    }
    final raw = await _callWriteWorker<String>('scan_start', {
      'path': path,
      'force': force,
    });
    if (_disposed) return null;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded['scan_id']?.toString();
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<String> startTagRescan({String? directory, bool force = false}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.startTagRescan(directory: directory, force: force);
    }
    if (!isNativeBound) {
      return _delegate.startTagRescan(directory: directory, force: force);
    }
    if (_libRescanStartFn != null) {
      final raw = await _callWriteWorker<String>('rescan_start', {
        'directory': directory,
        'force': force,
      });
      if (_disposed) return '';
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final scanId = decoded['scan_id']?.toString();
            if (scanId != null && scanId.isNotEmpty) {
              return scanId;
            }
          }
        } catch (_) {}
      }
      return '';
    }
    await rescanTags(directory: directory, force: force);
    return '';
  }

  @override
  Future<Map<String, dynamic>> forceRebuildLibrary({String? directory}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.forceRebuildLibrary(directory: directory);
    }
    if (!isNativeBound) {
      return _delegate.forceRebuildLibrary(directory: directory);
    }
    if (_libForceRebuildStartFn != null) {
      final raw = await _callWriteWorker<String>('force_rebuild_start', {
        'directory': directory,
        'force': true,
      });
      if (_disposed) return const <String, dynamic>{};
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            return Map<String, dynamic>.from(decoded);
          }
        } catch (_) {}
      }
      return const <String, dynamic>{};
    }
    final fallbackId = await startTagRescan(directory: directory, force: true);
    return <String, dynamic>{
      if (fallbackId.isNotEmpty) 'scan_id': fallbackId,
    };
  }

  @override
  Future<List<WatchedRootRecord>> listWatchedRoots() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listWatchedRoots();
    }
    if (!isNativeBound || _libWatchListFn == null) {
      return _delegate.listWatchedRoots();
    }
    final raw = await _callReadWorker<String>('watch_list');
    if (_disposed) return const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map(
                (e) => WatchedRootRecord.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList(growable: false);
        }
      } catch (_) {}
    }
    return const [];
  }

  @override
  Future<WatchedRootRecord?> addWatchedRoot(
    String rootPath, {
    WatchMode watchMode = WatchMode.nativeOs,
    int pollIntervalSec = 300,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.addWatchedRoot(
        rootPath,
        watchMode: watchMode,
        pollIntervalSec: pollIntervalSec,
      );
    }
    if (!isNativeBound || _libWatchAddFn == null) {
      return _delegate.addWatchedRoot(
        rootPath,
        watchMode: watchMode,
        pollIntervalSec: pollIntervalSec,
      );
    }
    final raw = await _callWriteWorker<String>('watch_add', {
      'rootPath': rootPath,
      'watchMode': watchMode.toJson(),
      'pollIntervalSec': pollIntervalSec,
    });
    if (_disposed) return null;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return WatchedRootRecord.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<bool> removeWatchedRoot(String rootPath) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.removeWatchedRoot(rootPath);
    }
    if (!isNativeBound || _libWatchRemoveFn == null) {
      return _delegate.removeWatchedRoot(rootPath);
    }
    final rc = await _callWriteWorker<int>('watch_remove', {
      'rootPath': rootPath,
    });
    return !_disposed && rc == 0;
  }

  @override
  Future<List<SkippedFileRecord>> getSkippedFiles({
    bool includeDismissed = false,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getSkippedFiles(includeDismissed: includeDismissed);
    }
    if (!isNativeBound || _libGetSkippedFilesFn == null) {
      return _delegate.getSkippedFiles(includeDismissed: includeDismissed);
    }
    final raw = await _callReadWorker<String>('skipped_files', {
      'includeDismissed': includeDismissed ? 1 : 0,
    });
    if (_disposed) return const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map(
                (e) => SkippedFileRecord.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList(growable: false);
        }
      } catch (_) {}
    }
    return const [];
  }

  @override
  Future<bool> dismissSkippedFile(String skippedId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.dismissSkippedFile(skippedId);
    }
    if (!isNativeBound || _libDismissSkippedFileFn == null) {
      return _delegate.dismissSkippedFile(skippedId);
    }
    final rc = await _callWriteWorker<int>('dismiss_skipped_file', {
      'skippedId': skippedId,
    });
    return !_disposed && rc == 0;
  }

  @override
  Future<Map<String, dynamic>> retrySkippedFile(String skippedId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.retrySkippedFile(skippedId);
    }
    if (!isNativeBound || _libRetrySkippedFileFn == null) {
      return _delegate.retrySkippedFile(skippedId);
    }
    final raw = await _callWriteWorker<String>('retry_skipped_file', {
      'skippedId': skippedId,
    });
    if (_disposed) {
      return const <String, dynamic>{
        'status': 'not_found',
        'detail': 'Retry failed',
      };
    }
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          if (map['status'] == 'imported') {
            await _reloadTracksFromNativeAsync();
            if (!_disposed) {
              _emitState(_state);
            }
          }
          return map;
        }
      } catch (_) {}
    }
    return const <String, dynamic>{
      'status': 'not_found',
      'detail': 'Retry failed',
    };
  }

  @override
  Future<bool> setMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
    dynamic value,
  ) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.setMetadataOverride(
        entityType,
        entityId,
        fieldName,
        value,
      );
    }
    if (!isNativeBound || _libSetMetadataOverrideFn == null) {
      return _delegate.setMetadataOverride(
        entityType,
        entityId,
        fieldName,
        value,
      );
    }
    final rc = await _callWriteWorker<int>('set_metadata_override', {
      'entityType': entityType,
      'entityId': entityId,
      'fieldName': fieldName,
      'valueJson': jsonEncode(value),
    });
    if (!_disposed && rc == 0) {
      await _reloadTracksFromNativeAsync();
      if (!_disposed) {
        _emitState(_state);
      }
      return true;
    }
    return false;
  }

  @override
  Future<bool> clearMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
  ) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.clearMetadataOverride(
        entityType,
        entityId,
        fieldName,
      );
    }
    if (!isNativeBound || _libClearMetadataOverrideFn == null) {
      return _delegate.clearMetadataOverride(entityType, entityId, fieldName);
    }
    final rc = await _callWriteWorker<int>('clear_metadata_override', {
      'entityType': entityType,
      'entityId': entityId,
      'fieldName': fieldName,
    });
    if (!_disposed && rc == 0) {
      await _reloadTracksFromNativeAsync();
      if (!_disposed) {
        _emitState(_state);
      }
      return true;
    }
    return false;
  }

  @override
  Future<List<MetadataOverrideRecord>> getMetadataOverrides(
    String entityType,
    String entityId,
  ) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getMetadataOverrides(entityType, entityId);
    }
    if (!isNativeBound || _libGetMetadataOverridesFn == null) {
      return _delegate.getMetadataOverrides(entityType, entityId);
    }
    final raw = await _callReadWorker<String>('get_metadata_overrides', {
      'entityType': entityType,
      'entityId': entityId,
    });
    if (_disposed) return const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded
              .whereType<Map>()
              .map(
                (e) => MetadataOverrideRecord.fromJson(
                  Map<String, dynamic>.from(e),
                ),
              )
              .toList(growable: false);
        }
      } catch (_) {}
    }
    return const [];
  }

  @override
  Future<Map<String, int>> ingestExternalCatalog(
    ExternalCatalogIngestBatch batch,
  ) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.ingestExternalCatalog(batch);
    }
    if (!isNativeBound || _libIngestExternalCatalogFn == null) {
      return _delegate.ingestExternalCatalog(batch);
    }
    final raw = await _callWriteWorker<String>('ingest_external_catalog', {
      'payload': jsonEncode(batch.toJson()),
    });
    if (_disposed) {
      return const <String, int>{'albums_ingested': 0, 'tracks_ingested': 0};
    }
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return <String, int>{
            'albums_ingested':
                (decoded['albums_ingested'] as num?)?.toInt() ?? 0,
            'tracks_ingested':
                (decoded['tracks_ingested'] as num?)?.toInt() ?? 0,
          };
        }
      } catch (_) {}
    }
    return const <String, int>{'albums_ingested': 0, 'tracks_ingested': 0};
  }

  @override
  Future<void> switchToLocalMode() async {
    _detachRemoteClientStreams();
    await _remoteClient?.switchToLocalMode();
    _remoteClient?.dispose();
    _remoteClient = null;
    _connectionMode = ConnectionMode.localOrUsbDac;
    if (!_disposed && !_connectionStatusController.isClosed) {
      _connectionStatusController.add(const ConnectionStatus.localConnected());
    }
  }
}
