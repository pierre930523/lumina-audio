part of '../ffi_audio_service.dart';

mixin _FfiLibraryMaintenanceMixin on _FfiAudioServiceBase {
  @override
  void _bindLibraryMaintenanceSymbols(ffi.DynamicLibrary dylib) {
    F? tryLookup<F>(F Function() lookup) {
      try {
        return lookup();
      } catch (_) {
        return null;
      }
    }

    _settingsGetDefaultMetaPolicyFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_settings_get_default_metadata_policy',
      ),
    );
    _settingsSetDefaultMetaPolicyFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_settings_set_default_metadata_policy',
      ),
    );
    _libSetEntityMetaPolicyFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr3IntNative, _LuminaStr3IntDart>(
        'lumina_library_set_entity_meta_policy',
      ),
    );
    _libSetEntityUserEditsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr3IntNative, _LuminaStr3IntDart>(
        'lumina_library_set_entity_user_edits',
      ),
    );
    _libRevertEntityToFileMetaFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>(
        'lumina_library_revert_entity_to_file_meta',
      ),
    );
    _libRescanAllSkippedFilesFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_rescan_all_skipped_files',
      ),
    );
    _libPreviewCleanupFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_preview_cleanup',
      ),
    );
    _libExecuteCleanupFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_execute_cleanup',
      ),
    );
  }

  @override
  Future<MetadataPolicy> getDefaultMetadataPolicy() async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getDefaultMetadataPolicy();
    }
    if (!isNativeBound || _settingsGetDefaultMetaPolicyFn == null) {
      return _delegate.getDefaultMetadataPolicy();
    }
    final raw = await _callReadWorker<String>('get_default_metadata_policy');
    if (_disposed || raw == null || raw.isEmpty) {
      return MetadataPolicy.file;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return MetadataPolicy.fromGlobalJson(decoded['policy']?.toString());
      }
    } catch (_) {}
    return MetadataPolicy.file;
  }

  @override
  Future<bool> setDefaultMetadataPolicy(MetadataPolicy policy) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.setDefaultMetadataPolicy(policy);
    }
    if (!isNativeBound || _settingsSetDefaultMetaPolicyFn == null) {
      return _delegate.setDefaultMetadataPolicy(policy);
    }
    final effective =
        policy == MetadataPolicy.cloud ? MetadataPolicy.cloud : MetadataPolicy.file;
    final rc = await _callWriteWorker<int>('set_default_metadata_policy', {
      'policy': effective.toJson(),
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
  Future<bool> setEntityMetaPolicy(
    String entityType,
    String entityId,
    MetadataPolicy policy,
  ) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.setEntityMetaPolicy(entityType, entityId, policy);
    }
    if (!isNativeBound || _libSetEntityMetaPolicyFn == null) {
      return _delegate.setEntityMetaPolicy(entityType, entityId, policy);
    }
    final rc = await _callWriteWorker<int>('set_entity_meta_policy', {
      'entityType': entityType,
      'entityId': entityId,
      'policy': policy.toJson(),
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
  Future<bool> setEntityUserEdits(
    String entityType,
    String entityId,
    Map<String, dynamic> edits,
  ) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.setEntityUserEdits(entityType, entityId, edits);
    }
    if (!isNativeBound || _libSetEntityUserEditsFn == null) {
      return _delegate.setEntityUserEdits(entityType, entityId, edits);
    }
    final rc = await _callWriteWorker<int>('set_entity_user_edits', {
      'entityType': entityType,
      'entityId': entityId,
      'editsJson': jsonEncode(edits),
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
  Future<bool> revertEntityToFileMeta(
    String entityType,
    String entityId,
  ) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.revertEntityToFileMeta(entityType, entityId);
    }
    if (!isNativeBound || _libRevertEntityToFileMetaFn == null) {
      return _delegate.revertEntityToFileMeta(entityType, entityId);
    }
    final rc = await _callWriteWorker<int>('revert_entity_to_file_meta', {
      'entityType': entityType,
      'entityId': entityId,
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
  Future<BatchRescanSkippedResult> rescanAllSkippedFiles() async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.rescanAllSkippedFiles();
    }
    if (!isNativeBound || _libRescanAllSkippedFilesFn == null) {
      return _delegate.rescanAllSkippedFiles();
    }
    final raw = await _callWriteWorker<String>('rescan_all_skipped_files');
    if (_disposed) return const BatchRescanSkippedResult();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final res = BatchRescanSkippedResult.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          if (res.resolved > 0) {
            await _reloadTracksFromNativeAsync();
            if (!_disposed) {
              _emitState(_state);
            }
          }
          return res;
        }
      } catch (_) {}
    }
    return const BatchRescanSkippedResult();
  }

  @override
  Future<LibraryCleanupPreview> previewLibraryCleanup() async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.previewLibraryCleanup();
    }
    if (!isNativeBound || _libPreviewCleanupFn == null) {
      return _delegate.previewLibraryCleanup();
    }
    final raw = await _callReadWorker<String>('preview_library_cleanup');
    if (_disposed || raw == null || raw.isEmpty) {
      return const LibraryCleanupPreview();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return LibraryCleanupPreview.fromJson(
          Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {}
    return const LibraryCleanupPreview();
  }

  @override
  Future<LibraryCleanupResult> executeLibraryCleanup(
    LibraryCleanupOptions options,
  ) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.executeLibraryCleanup(options);
    }
    if (!isNativeBound || _libExecuteCleanupFn == null) {
      return _delegate.executeLibraryCleanup(options);
    }
    final raw = await _callWriteWorker<String>('execute_library_cleanup', {
      'optionsJson': jsonEncode(options.toJson()),
    });
    if (_disposed) return const LibraryCleanupResult();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final res = LibraryCleanupResult.fromJson(
            Map<String, dynamic>.from(decoded),
          );
          await _reloadTracksFromNativeAsync();
          if (!_disposed) {
            _emitState(_state);
          }
          return res;
        }
      } catch (_) {}
    }
    return const LibraryCleanupResult();
  }
}
