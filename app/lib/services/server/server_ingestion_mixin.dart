part of '../server_audio_service.dart';

mixin _ServerIngestionMixin on _ServerAudioServiceBase {
  @override
  Stream<ScanProgressEvent> get scanProgressStream =>
      _scanProgressController.stream;

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/scan/start',
      body: <String, dynamic>{'dir_path': path, 'force': force},
    );
    if (code == 200 && data is Map) {
      return data['scan_id']?.toString();
    }
    return null;
  }

  @override
  Future<String> startTagRescan({String? directory, bool force = false}) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/rescan/start',
      body: <String, dynamic>{
        'directory': directory,
        'force': force,
      },
    );
    if (code == 200 && data is Map) {
      return data['scan_id']?.toString() ?? '';
    }
    return '';
  }

  @override
  Future<Map<String, dynamic>> forceRebuildLibrary({String? directory}) async {
    final dir = directory?.trim();
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/rebuild/start',
      body: <String, dynamic>{
        if (dir != null && dir.isNotEmpty) 'dir_path': dir,
        'force': true,
      },
    );
    if (code == 200 && data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<WatchedRootRecord>> listWatchedRoots() async {
    final (code, data) = await _requestJson('GET', '/api/v1/library/watch');
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => WatchedRootRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<WatchedRootRecord?> addWatchedRoot(
    String rootPath, {
    WatchMode watchMode = WatchMode.nativeOs,
    int pollIntervalSec = 300,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/watch',
      body: <String, dynamic>{
        'root_path': rootPath,
        'watch_mode': watchMode.toJson(),
        'poll_interval_sec': pollIntervalSec,
      },
    );
    if (code == 200 && data is Map) {
      return WatchedRootRecord.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> removeWatchedRoot(String rootPath) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/watch?root_path=${Uri.encodeQueryComponent(rootPath)}',
    );
    if (code == 200 || code == 204) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<List<SkippedFileRecord>> getSkippedFiles({
    bool includeDismissed = false,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/skipped?include_dismissed=$includeDismissed',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => SkippedFileRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<bool> dismissSkippedFile(String skippedId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/skipped/${Uri.encodeComponent(skippedId)}/dismiss',
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<Map<String, dynamic>> retrySkippedFile(String skippedId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/skipped/${Uri.encodeComponent(skippedId)}/retry',
    );
    if (code == 200 && data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return const <String, dynamic>{
      'status': 'not_found',
      'detail': 'Retry request failed',
    };
  }

  @override
  Future<bool> setMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
    dynamic value,
  ) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/overrides/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}',
      body: <String, dynamic>{
        'field_name': fieldName,
        'value_json': jsonEncode(value),
      },
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
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
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/overrides/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}/${Uri.encodeComponent(fieldName)}',
    );
    if (code == 200 || code == 204) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<List<MetadataOverrideRecord>> getMetadataOverrides(
    String entityType,
    String entityId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/overrides/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map(
            (e) => MetadataOverrideRecord.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<Map<String, int>> ingestExternalCatalog(
    ExternalCatalogIngestBatch batch,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/ingest',
      body: batch.toJson(),
    );
    if (code == 200 && data is Map) {
      return <String, int>{
        'albums_ingested': (data['albums_ingested'] as num?)?.toInt() ?? 0,
        'tracks_ingested': (data['tracks_ingested'] as num?)?.toInt() ?? 0,
      };
    }
    return const <String, int>{'albums_ingested': 0, 'tracks_ingested': 0};
  }

  @override
  Future<MetadataPolicy> getDefaultMetadataPolicy() async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/settings/metadata-policy',
    );
    if (code == 200 && data is Map) {
      return MetadataPolicy.fromGlobalJson(data['policy']?.toString());
    }
    return MetadataPolicy.file;
  }

  @override
  Future<bool> setDefaultMetadataPolicy(MetadataPolicy policy) async {
    final effective =
        policy == MetadataPolicy.cloud ? MetadataPolicy.cloud : MetadataPolicy.file;
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/settings/metadata-policy',
      body: <String, dynamic>{'policy': effective.toJson()},
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
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
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/metadata/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}/policy',
      body: <String, dynamic>{'policy': policy.toJson()},
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
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
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/metadata/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}/user-edits',
      body: edits,
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<bool> revertEntityToFileMeta(
    String entityType,
    String entityId,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/metadata/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}/revert',
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<BatchRescanSkippedResult> rescanAllSkippedFiles() async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/skipped/rescan-all',
    );
    if (code == 200 && data is Map) {
      return BatchRescanSkippedResult.fromJson(Map<String, dynamic>.from(data));
    }
    return const BatchRescanSkippedResult();
  }

  @override
  Future<LibraryCleanupPreview> previewLibraryCleanup() async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/cleanup/preview',
    );
    if (code == 200 && data is Map) {
      return LibraryCleanupPreview.fromJson(Map<String, dynamic>.from(data));
    }
    return const LibraryCleanupPreview();
  }

  @override
  Future<LibraryCleanupResult> executeLibraryCleanup(
    LibraryCleanupOptions options,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/cleanup/execute',
      body: options.toJson(),
    );
    if (code == 200 && data is Map) {
      return LibraryCleanupResult.fromJson(Map<String, dynamic>.from(data));
    }
    return const LibraryCleanupResult();
  }
}
