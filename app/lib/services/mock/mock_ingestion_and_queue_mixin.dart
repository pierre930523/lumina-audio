part of '../mock_audio_service.dart';

mixin _MockIngestionAndQueueMixin on _MockAudioServiceBase {
  @visibleForTesting
  void emitScanProgress(ScanProgressEvent event) {
    if (!_disposed && !_scanProgressController.isClosed) {
      _scanProgressController.add(event);
    }
  }

  @visibleForTesting
  void seedSkippedFiles(List<SkippedFileRecord> records) {
    _skippedFiles
      ..clear()
      ..addAll(records);
  }

  @visibleForTesting
  List<ExternalCatalogIngestBatch> get ingestedExternalBatches =>
      List<ExternalCatalogIngestBatch>.unmodifiable(_ingestedExternalBatches);

  bool get visualizerSettingEnabled => _visualizerSettingEnabled;
  bool get nowPlayingVisible => _nowPlayingVisible;
  bool get windowMinimized => _windowMinimized;

  @override
  ValueListenable<Float32List> get visualizerBandsNotifier =>
      _visualizerBandsNotifier;

  @override
  void setVisualizerSettingEnabled(bool enabled) {
    _visualizerSettingEnabled = enabled;
  }

  @override
  void setNowPlayingVisible(bool visible) {
    _nowPlayingVisible = visible;
  }

  @override
  void setWindowMinimized(bool minimized) {
    _windowMinimized = minimized;
  }

  @override
  Stream<ScanProgressEvent> get scanProgressStream =>
      _scanProgressController.stream;

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    final scanId = 'mock-scan-${++_mockScanSeq}';
    emitScanProgress(
      ScanProgressEvent(
        scanId: scanId,
        rootPath: trimmed,
        state: ScanLifecycleState.discovering,
        currentPath: trimmed,
      ),
    );
    final count = await scanDirectory(trimmed);
    emitScanProgress(
      ScanProgressEvent(
        scanId: scanId,
        rootPath: trimmed,
        state: ScanLifecycleState.completed,
        scanned: count,
        added: count,
        totalEstimated: count,
      ),
    );
    return scanId;
  }

  @override
  Future<String> startTagRescan({String? directory, bool force = false}) async {
    final rootPath = (directory ?? '').trim();
    final scanId = 'mock-rescan-${++_mockScanSeq}';
    emitScanProgress(
      ScanProgressEvent(
        scanId: scanId,
        rootPath: rootPath,
        state: ScanLifecycleState.discovering,
        currentPath: rootPath.isNotEmpty ? rootPath : null,
      ),
    );
    final res = await rescanTags(directory: directory, force: force);
    final count = (res?['updated_count'] as num?)?.toInt() ??
        (res?['rescanned_count'] as num?)?.toInt() ??
        _queue.length;
    emitScanProgress(
      ScanProgressEvent(
        scanId: scanId,
        rootPath: rootPath,
        state: ScanLifecycleState.completed,
        scanned: count,
        updated: count,
        totalEstimated: count,
      ),
    );
    return scanId;
  }

  @override
  Future<Map<String, dynamic>> forceRebuildLibrary({String? directory}) async {
    final rootPath = (directory ?? '').trim();
    final scanId = 'mock-rebuild-${++_mockScanSeq}';
    emitScanProgress(
      ScanProgressEvent(
        scanId: scanId,
        rootPath: rootPath.isNotEmpty ? rootPath : 'local',
        state: ScanLifecycleState.discovering,
        currentPath: rootPath.isNotEmpty ? rootPath : null,
      ),
    );
    _skippedFiles.removeWhere((f) => !f.dismissed);
    final res = await rescanTags(directory: directory, force: true);
    final count = (res?['updated_count'] as num?)?.toInt() ??
        (res?['rescanned_count'] as num?)?.toInt() ??
        _queue.length;
    emitScanProgress(
      ScanProgressEvent(
        scanId: scanId,
        rootPath: rootPath.isNotEmpty ? rootPath : 'local',
        state: ScanLifecycleState.completed,
        scanned: count,
        updated: count,
        totalEstimated: count,
      ),
    );
    return <String, dynamic>{'scan_id': scanId};
  }

  @override
  Future<List<WatchedRootRecord>> listWatchedRoots() async =>
      List<WatchedRootRecord>.unmodifiable(_watchedRoots);

  @override
  Future<WatchedRootRecord?> addWatchedRoot(
    String rootPath, {
    WatchMode watchMode = WatchMode.nativeOs,
    int pollIntervalSec = 300,
  }) async {
    final trimmed = rootPath.trim();
    if (trimmed.isEmpty) return null;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final idx = _watchedRoots.indexWhere(
      (r) => r.rootPath.toLowerCase() == trimmed.toLowerCase(),
    );
    final record = WatchedRootRecord(
      id: idx >= 0
          ? _watchedRoots[idx].id
          : 'root-${_watchedRoots.length + 1}',
      providerId: watchMode == WatchMode.nasPolling &&
              trimmed.toLowerCase().startsWith('smb://')
          ? 'smb'
          : 'local',
      rootPath: trimmed,
      watchMode: watchMode,
      pollIntervalSec: pollIntervalSec,
      isOnline: true,
      lastScanAt: nowIso,
      updatedAt: nowIso,
    );
    if (idx >= 0) {
      _watchedRoots[idx] = record;
    } else {
      _watchedRoots.add(record);
    }
    return record;
  }

  @override
  Future<bool> removeWatchedRoot(String rootPath) async {
    final trimmed = rootPath.trim().toLowerCase();
    final before = _watchedRoots.length;
    _watchedRoots.removeWhere((r) => r.rootPath.toLowerCase() == trimmed);
    return _watchedRoots.length != before;
  }

  @override
  Future<List<SkippedFileRecord>> getSkippedFiles({
    bool includeDismissed = false,
  }) async {
    if (includeDismissed) {
      return List<SkippedFileRecord>.unmodifiable(_skippedFiles);
    }
    return _skippedFiles.where((f) => !f.dismissed).toList(growable: false);
  }

  @override
  Future<bool> dismissSkippedFile(String skippedId) async {
    final idx = _skippedFiles.indexWhere((f) => f.id == skippedId);
    if (idx < 0) return false;
    final old = _skippedFiles[idx];
    _skippedFiles[idx] = SkippedFileRecord(
      id: old.id,
      providerId: old.providerId,
      filePath: old.filePath,
      reason: old.reason,
      detail: old.detail,
      fileSize: old.fileSize,
      fileMtime: old.fileMtime,
      firstSeenAt: old.firstSeenAt,
      lastSeenAt: old.lastSeenAt,
      dismissed: true,
    );
    return true;
  }

  @override
  Future<Map<String, dynamic>> retrySkippedFile(String skippedId) async {
    final idx = _skippedFiles.indexWhere((f) => f.id == skippedId);
    if (idx < 0) {
      return const <String, dynamic>{
        'status': 'not_found',
        'detail': 'Skipped file record not found',
      };
    }
    final removed = _skippedFiles.removeAt(idx);
    return <String, dynamic>{
      'status': 'imported',
      'detail': 'Re-imported ${removed.filePath}',
    };
  }

  @override
  Future<bool> setMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
    dynamic value,
  ) async {
    final key = '$entityType:$entityId';
    final map = _metadataOverrides.putIfAbsent(
      key,
      () => <String, MetadataOverrideRecord>{},
    );
    map[fieldName] = MetadataOverrideRecord(
      entityType: entityType,
      entityId: entityId,
      fieldName: fieldName,
      valueJson: jsonEncode(value),
      sourceLayer: MetadataLayer.userEdit,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    return true;
  }

  @override
  Future<bool> clearMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
  ) async {
    final map = _metadataOverrides['$entityType:$entityId'];
    if (map == null) return false;
    return map.remove(fieldName) != null;
  }

  @override
  Future<List<MetadataOverrideRecord>> getMetadataOverrides(
    String entityType,
    String entityId,
  ) async {
    final map = _metadataOverrides['$entityType:$entityId'];
    if (map == null || map.isEmpty) return const [];
    return List<MetadataOverrideRecord>.unmodifiable(map.values);
  }

  @override
  Future<Map<String, int>> ingestExternalCatalog(
    ExternalCatalogIngestBatch batch,
  ) async {
    _ingestedExternalBatches.add(batch);
    var tracks = 0;
    for (final a in batch.albums) {
      tracks += a.tracks.length;
    }
    return <String, int>{
      'albums_ingested': batch.albums.length,
      'tracks_ingested': tracks,
    };
  }

  @override
  Stream<QueueState> get queueStateStream => _queueStateController.stream;

  @override
  QueueState get currentQueueState => QueueState(
        items: <QueueItem>[
          for (var i = 0; i < _queue.length; i++)
            QueueItem(
              itemId: 'mock-$i-${_queue[i].id}',
              track: ProtocolTrackMetadata.fromTrackInfo(_queue[i]),
              isUserQueued: true,
            ),
        ],
        currentIndex:
            _queue.isEmpty ? null : _currentIndex.clamp(0, _queue.length - 1),
        repeatMode: _repeatMode,
        shuffle: _shuffle,
        queueEpoch: _queueEpoch,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );

  @override
  RepeatMode get repeatMode => _repeatMode;

  @override
  bool get shuffle => _shuffle;

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    _repeatMode = mode;
    _queueEpoch++;
    _state = _state.copyWith(repeatMode: mode);
    if (!_disposed && !_stateController.isClosed) _stateController.add(_state);
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    _queueEpoch++;
    _state = _state.copyWith(shuffle: enabled);
    if (!_disposed && !_stateController.isClosed) _stateController.add(_state);
    if (!_disposed && !_queueStateController.isClosed) {
      _queueStateController.add(currentQueueState);
    }
  }
}
