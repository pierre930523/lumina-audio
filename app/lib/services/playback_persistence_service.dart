import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/audio_format.dart';
import '../models/playback_state.dart';
import '../models/streaming_models.dart';
import 'audio_service.dart';

/// Persists playback state across app restarts (track, progress, volume, queue).
/// Supports instant saving on critical events (track change, pause, seek, app exit)
/// and throttled saving (every 3-4s) during active playback.
class PlaybackPersistenceService {
  final File? prefsFileOverride;
  final Duration throttleDuration;

  Timer? _throttleTimer;
  bool _hasPendingSave = false;
  Map<String, dynamic>? _lastSavedData;
  bool _isSaving = false;
  bool _isRestoring = false;
  Map<String, dynamic>? _pendingSnapshot;
  int _pendingSnapshotSeq = 0;
  int _snapshotSeq = 0;
  int _lastWrittenSeq = 0;
  Completer<void>? _activeSaveCompleter;
  bool _disposed = false;

  List<Map<String, dynamic>>? _cachedQueueTracks;
  int _cachedQueueLength = -1;
  String _cachedQueueSignature = '';

  bool get isRestoring => _isRestoring;

  PlaybackPersistenceService({
    this.prefsFileOverride,
    this.throttleDuration = const Duration(milliseconds: 3500),
  });

  /// Normalizes a file path or URI for deterministic matching across library rescans and restarts.
  static String? normalizeTrackPath(String? raw) {
    if (raw == null) return null;
    var p = raw.trim();
    if (p.isEmpty) return null;
    if (Platform.isWindows) {
      p = p.replaceAll('/', '\\').toLowerCase();
      final isUnc = p.startsWith('\\\\');
      p = p.replaceAll(RegExp(r'\\{2,}'), '\\');
      if (isUnc && !p.startsWith('\\\\')) {
        p = '\\$p';
      }
    }
    return p;
  }

  /// Returns true when [a] and [b] refer to the same track (normalized path first, then id).
  static bool tracksMatch(TrackInfo a, TrackInfo b) {
    final pathA = normalizeTrackPath(a.filePath);
    final pathB = normalizeTrackPath(b.filePath);
    if (pathA != null && pathB != null) {
      return pathA == pathB;
    }
    return a.id.isNotEmpty && a.id == b.id;
  }

  /// Finds the index of [target] in [tracks] using normalized filePath first, then track id.
  static int findTrackIndex(List<TrackInfo> tracks, TrackInfo target) {
    final normTarget = normalizeTrackPath(target.filePath);
    if (normTarget != null) {
      final byPath = tracks.indexWhere(
        (t) => normalizeTrackPath(t.filePath) == normTarget,
      );
      if (byPath >= 0) return byPath;
    }
    if (target.id.isNotEmpty) {
      final byId = tracks.indexWhere((t) => t.id == target.id);
      if (byId >= 0) return byId;
    }
    return -1;
  }

  File? _resolveFile() {
    if (prefsFileOverride != null) return prefsFileOverride;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}playback_state.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_playback_state.json',
    );
  }

  Map<String, dynamic> _serializeTrack(TrackInfo t) {
    return {
      'id': t.id,
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'duration_ms': t.duration.inMilliseconds,
      'cover_url': t.coverUrl,
      'album_art_url': t.albumArtUrl,
      'file_path': t.filePath,
      'album_artist': t.albumArtist,
      'genre': t.genre,
      'year': t.year,
      'track_number': t.trackNumber,
      'disc_number': t.discNumber,
      'composer': t.composer,
      'artwork_cache_key': t.artworkCacheKey,
      'has_lyrics': t.hasLyrics,
      'sample_rate_hz': t.format.sampleRateHz,
      'bit_depth': t.format.bitDepth,
      'channels': t.format.channels,
      'codec': t.format.codec.name,
      'is_dsd': t.format.isDsd,
      'provider_name': t.providerName,
    };
  }

  TrackInfo? _deserializeTrack(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final id = map['id']?.toString() ?? '';
    final title = map['title']?.toString() ?? '';
    final filePath = map['file_path']?.toString();
    if (id.isEmpty && title.isEmpty && (filePath == null || filePath.isEmpty)) {
      return null;
    }

    final durMs = (map['duration_ms'] as num?)?.toInt() ?? 0;
    final codecName = map['codec']?.toString() ?? 'flac';
    final codec = AudioCodec.fromString(codecName);
    final rawCover = map['cover_url']?.toString();
    final rawAlbumArt = map['album_art_url']?.toString();

    return TrackInfo(
      id: id,
      title: title.isNotEmpty ? title : '未知曲目',
      artist: map['artist']?.toString() ?? '未知歌手',
      album: map['album']?.toString() ?? '未知專輯',
      duration: Duration(milliseconds: durMs < 0 ? 0 : durMs),
      coverUrl: rawCover == null
          ? null
          : (upgradeStreamingCoverUrl(rawCover) ?? rawCover),
      albumArtUrl: rawAlbumArt == null
          ? null
          : (upgradeStreamingCoverUrl(rawAlbumArt) ?? rawAlbumArt),
      filePath: filePath,
      albumArtist: map['album_artist']?.toString(),
      genre: map['genre']?.toString(),
      year: (map['year'] as num?)?.toInt(),
      trackNumber: (map['track_number'] as num?)?.toInt(),
      discNumber: (map['disc_number'] as num?)?.toInt(),
      composer: map['composer']?.toString(),
      artworkCacheKey: map['artwork_cache_key']?.toString(),
      hasLyrics: map['has_lyrics'] == true,
      format: AudioFormat(
        codec: codec,
        sampleRateHz: (map['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (map['bit_depth'] as num?)?.toInt() ?? 16,
        channels: (map['channels'] as num?)?.toInt() ?? 2,
        isDsd: map['is_dsd'] == true,
      ),
      providerName: map['provider_name']?.toString() ?? 'local',
    );
  }

  Map<String, dynamic> buildSnapshot({
    required PlaybackState state,
    required List<TrackInfo> queue,
    int? queueIndex,
  }) {
    final track = state.track;
    final resolvedQueueIndex =
        queueIndex ?? (track != null ? findTrackIndex(queue, track) : 0);

    final queueSig = queue.isEmpty
        ? '0'
        : '${queue.length}_${queue.first.id}_${queue.first.filePath}_${queue[queue.length ~/ 2].id}_${queue.last.id}_${queue.last.filePath}';
    if (_cachedQueueTracks == null ||
        _cachedQueueLength != queue.length ||
        _cachedQueueSignature != queueSig) {
      _cachedQueueTracks = queue.map(_serializeTrack).toList();
      _cachedQueueLength = queue.length;
      _cachedQueueSignature = queueSig;
    }

    return {
      'version': 2,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'position_ms': state.position.inMilliseconds,
      'volume': state.volume,
      'is_muted': state.isMuted,
      'track': track != null ? _serializeTrack(track) : null,
      'queue_index': resolvedQueueIndex < 0 ? 0 : resolvedQueueIndex,
      'queue_tracks': _cachedQueueTracks,
    };
  }

  bool _hasExistingValidSession() {
    if (_lastSavedData?['track'] != null) return true;
    final file = _resolveFile();
    if (file == null) return false;
    try {
      if (!file.existsSync()) return false;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return false;
      final decoded = jsonDecode(raw);
      return decoded is Map && decoded['track'] != null;
    } catch (_) {
      return false;
    }
  }

  bool _shouldSkipEmptySnapshot(
    Map<String, dynamic> snapshot, {
    required bool allowEmptyTrack,
  }) {
    if (allowEmptyTrack) return false;
    if (snapshot['track'] != null) return false;
    return _hasExistingValidSession();
  }

  /// Saves snapshot immediately to disk using a single-flight worker to prevent unbounded Future queues.
  Future<void> saveImmediate(
    Map<String, dynamic> snapshot, {
    bool allowEmptyTrack = false,
    bool syncFlush = false,
  }) async {
    if (_disposed || _isRestoring) return;
    if (_shouldSkipEmptySnapshot(snapshot, allowEmptyTrack: allowEmptyTrack)) {
      return;
    }

    final seq = ++_snapshotSeq;
    _lastSavedData = snapshot;
    _hasPendingSave = false;
    _throttleTimer?.cancel();
    _throttleTimer = null;

    if (_isSaving) {
      _pendingSnapshot = snapshot;
      _pendingSnapshotSeq = seq;
      if (syncFlush) {
        await _activeSaveCompleter?.future;
        if (_pendingSnapshot != null) {
          final latest = _pendingSnapshot!;
          final latestSeq = _pendingSnapshotSeq;
          _pendingSnapshot = null;
          await _performSave(latest, syncFlush: true, seq: latestSeq);
        }
        return;
      }
      return _activeSaveCompleter?.future ?? Future.value();
    }

    if (syncFlush) {
      await _performSave(snapshot, syncFlush: true, seq: seq);
      return;
    }

    _isSaving = true;
    _activeSaveCompleter = Completer<void>();

    try {
      Map<String, dynamic>? nextSnapshot = snapshot;
      var nextSeq = seq;
      while (nextSnapshot != null) {
        final currentToSave = nextSnapshot;
        final currentSeq = nextSeq;
        _pendingSnapshot = null;
        await _performSave(
          currentToSave,
          syncFlush: syncFlush,
          seq: currentSeq,
        );
        if (_disposed) {
          if (_pendingSnapshot != null) {
            final finalSnap = _pendingSnapshot!;
            final finalSeq = _pendingSnapshotSeq;
            _pendingSnapshot = null;
            await _performSave(finalSnap, syncFlush: true, seq: finalSeq);
          }
          break;
        }
        nextSnapshot = _pendingSnapshot;
        nextSeq = _pendingSnapshotSeq;
      }
    } finally {
      _isSaving = false;
      final completer = _activeSaveCompleter;
      _activeSaveCompleter = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void _logSaved(Map<String, dynamic> snapshot) {
    final trackMap = snapshot['track'];
    final trackTitle = (trackMap is Map && trackMap['title'] != null)
        ? trackMap['title'].toString()
        : 'none';
    final posMs = (snapshot['position_ms'] as num?)?.toInt() ?? 0;
    debugPrint('[PlaybackPersist] Saved: $trackTitle @ ${posMs}ms');
  }

  void _performSaveSync(Map<String, dynamic> snapshot, {required int seq}) {
    if (seq <= _lastWrittenSeq) return;
    final file = _resolveFile();
    if (file == null) return;

    try {
      final payload = const JsonEncoder.withIndent('  ').convert(snapshot);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);

      final tmpFile = File('${file.path}.tmp');
      try {
        tmpFile.writeAsStringSync(payload, flush: true);
        tmpFile.renameSync(file.path);
      } catch (_) {
        try {
          if (tmpFile.existsSync()) tmpFile.deleteSync();
        } catch (_) {}
        file.writeAsStringSync(payload, flush: true);
      }

      _lastWrittenSeq = seq;
      _logSaved(snapshot);
    } catch (e) {
      debugPrint('PlaybackPersistenceService save error: $e');
    }
  }

  Future<void> _performSave(
    Map<String, dynamic> snapshot, {
    bool syncFlush = false,
    int? seq,
  }) async {
    final effectiveSeq = seq ?? ++_snapshotSeq;
    if (effectiveSeq <= _lastWrittenSeq) return;
    final file = _resolveFile();
    if (file == null) return;

    if (syncFlush || prefsFileOverride != null) {
      _performSaveSync(snapshot, seq: effectiveSeq);
      return;
    }

    try {
      final payload = const JsonEncoder.withIndent('  ').convert(snapshot);
      final parent = file.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      if (effectiveSeq <= _lastWrittenSeq) return;

      final tmpFile = File('${file.path}.tmp');
      try {
        await tmpFile.writeAsString(payload, flush: true);
        if (effectiveSeq <= _lastWrittenSeq) {
          try {
            if (await tmpFile.exists()) await tmpFile.delete();
          } catch (_) {}
          return;
        }
        await tmpFile.rename(file.path);
      } catch (_) {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
        if (effectiveSeq <= _lastWrittenSeq) return;
        await file.writeAsString(payload, flush: true);
      }

      _lastWrittenSeq = effectiveSeq;
      _logSaved(snapshot);
    } catch (e) {
      debugPrint('PlaybackPersistenceService save error: $e');
    }
  }

  /// Throttled save: calls will execute at most once per [throttleDuration].
  void saveThrottled(
    Map<String, dynamic> snapshot, {
    bool allowEmptyTrack = false,
  }) {
    if (_disposed || _isRestoring) return;
    if (_shouldSkipEmptySnapshot(snapshot, allowEmptyTrack: allowEmptyTrack)) {
      return;
    }

    ++_snapshotSeq;
    _lastSavedData = snapshot;
    _hasPendingSave = true;

    if (_throttleTimer != null && _throttleTimer!.isActive) {
      return;
    }

    _throttleTimer = Timer(throttleDuration, () {
      if (_hasPendingSave && _lastSavedData != null && !_disposed && !_isRestoring) {
        saveImmediate(_lastSavedData!, allowEmptyTrack: allowEmptyTrack);
      }
    });
  }

  /// Flushes any pending throttled saves immediately (never aborted by dispose).
  Future<void> flush({bool syncFlush = false}) async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    if (_isRestoring) return;

    if (_hasPendingSave && _lastSavedData != null) {
      final snap = _lastSavedData!;
      _hasPendingSave = false;
      final seq = ++_snapshotSeq;
      if (_isSaving) {
        _pendingSnapshot = snap;
        _pendingSnapshotSeq = seq;
        await _activeSaveCompleter?.future;
        if (_pendingSnapshot != null) {
          final remaining = _pendingSnapshot!;
          final remainingSeq = _pendingSnapshotSeq;
          _pendingSnapshot = null;
          await _performSave(remaining, syncFlush: syncFlush, seq: remainingSeq);
        }
        return;
      }
      await _performSave(snap, syncFlush: syncFlush, seq: seq);
    } else if (_isSaving && _activeSaveCompleter != null) {
      await _activeSaveCompleter!.future;
    }
  }

  /// Awaits any active save and synchronously/atomically flushes the final [snapshot] for app exit.
  Future<void> saveAndFlushForExit(
    Map<String, dynamic> snapshot, {
    bool allowEmptyTrack = false,
  }) async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    if (_isRestoring) return;

    var target = snapshot;
    if (_shouldSkipEmptySnapshot(snapshot, allowEmptyTrack: allowEmptyTrack)) {
      if (_hasPendingSave &&
          _lastSavedData != null &&
          _lastSavedData!['track'] != null) {
        target = _lastSavedData!;
      } else {
        return;
      }
    }

    final seq = ++_snapshotSeq;
    _lastSavedData = target;
    _hasPendingSave = false;
    _pendingSnapshot = null;

    if (_isSaving && _activeSaveCompleter != null) {
      await _activeSaveCompleter!.future;
    }

    await _performSave(target, syncFlush: true, seq: seq);
  }

  /// Loads saved state from disk.
  Future<Map<String, dynamic>?> load() async {
    final file = _resolveFile();
    if (file == null) return null;

    try {
      final exists = prefsFileOverride != null
          ? file.existsSync()
          : await file.exists();
      if (!exists) return null;

      final raw = prefsFileOverride != null
          ? file.readAsStringSync()
          : await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static bool _isRemoteUri(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('smb://') ||
        lower.startsWith('dav://') ||
        lower.startsWith('webdav://');
  }

  static bool _canRestoreMissingFromQueueTrack(
    TrackInfo track, {
    required bool isInTest,
  }) {
    final fp = track.filePath?.trim();
    if (fp == null || fp.isEmpty) return true;
    if (_isRemoteUri(fp)) return true;
    if (isInTest) return true;
    try {
      return File(fp).existsSync();
    } catch (_) {
      return false;
    }
  }

  List<TrackInfo> _mergeRestoredQueue({
    required List<TrackInfo> savedQueue,
    required List<TrackInfo> existingQueue,
    required TrackInfo matchedTrack,
    required int savedQueueIndex,
    required bool isInTest,
  }) {
    final restored = <TrackInfo>[];

    void addIfUnique(TrackInfo candidate) {
      if (findTrackIndex(restored, candidate) < 0) {
        restored.add(candidate);
      }
    }

    for (final savedItem in savedQueue) {
      final existingIdx = findTrackIndex(existingQueue, savedItem);
      if (existingIdx >= 0) {
        final libTrack = existingQueue[existingIdx];
        final resolved = libTrack.duration <= Duration.zero &&
                savedItem.duration > Duration.zero
            ? libTrack.copyWith(duration: savedItem.duration)
            : libTrack;
        addIfUnique(resolved);
      } else if (_canRestoreMissingFromQueueTrack(savedItem, isInTest: isInTest)) {
        addIfUnique(savedItem);
      }
    }

    if (restored.isEmpty) {
      for (final existing in existingQueue) {
        addIfUnique(existing);
      }
      if (findTrackIndex(restored, matchedTrack) < 0) {
        final insertAt = savedQueueIndex.clamp(0, restored.length);
        restored.insert(insertAt, matchedTrack);
      }
    } else {
      if (findTrackIndex(restored, matchedTrack) < 0) {
        final insertAt = savedQueueIndex.clamp(0, restored.length);
        restored.insert(insertAt, matchedTrack);
      }
      // Preserve any real library tracks (with filePath) that weren't in savedQueue.
      for (final existing in existingQueue) {
        final hasLocalPath =
            existing.filePath != null && existing.filePath!.trim().isNotEmpty;
        if (hasLocalPath) {
          addIfUnique(existing);
        }
      }
    }

    return restored;
  }

  /// Restores saved playback session onto [audioService].
  /// Sets volume, restores track, queue & position, and leaves player in paused standby.
  Future<bool> restoreSession(
    AudioService audioService, {
    bool rememberPosition = true,
  }) async {
    _isRestoring = true;
    try {
      final data = await load();
      if (data == null) return false;
      _lastSavedData ??= data;

      final rawVolume = (data['volume'] as num?)?.toDouble();
      final savedVolume =
          (rawVolume != null && rawVolume.isFinite) ? rawVolume.clamp(0.0, 1.0) : null;
      final isMuted = data['is_muted'] == true;

      if (!rememberPosition) {
        if (savedVolume != null) {
          await audioService.setVolume(savedVolume);
        }
        if (isMuted && !audioService.currentState.isMuted) {
          await audioService.toggleMute();
        }
        await Future<void>.microtask(() {});
        return false;
      }

      final savedTrack = _deserializeTrack(data['track']);
      if (savedTrack == null) {
        if (savedVolume != null) {
          await audioService.setVolume(savedVolume);
        }
        if (isMuted && !audioService.currentState.isMuted) {
          await audioService.toggleMute();
        }
        await Future<void>.microtask(() {});
        return false;
      }

      final isInTest = prefsFileOverride != null ||
          Platform.environment.containsKey('FLUTTER_TEST');

      final existingQueue = audioService.queue;
      final matchedQueueIdx = findTrackIndex(existingQueue, savedTrack);
      late final TrackInfo matchedTrack;
      if (matchedQueueIdx >= 0) {
        final libTrack = existingQueue[matchedQueueIdx];
        matchedTrack = libTrack.duration <= Duration.zero &&
                savedTrack.duration > Duration.zero
            ? libTrack.copyWith(duration: savedTrack.duration)
            : libTrack;
      } else {
        if (!_canRestoreMissingFromQueueTrack(savedTrack, isInTest: isInTest)) {
          if (savedVolume != null) {
            await audioService.setVolume(savedVolume);
          }
          if (isMuted && !audioService.currentState.isMuted) {
            await audioService.toggleMute();
          }
          await Future<void>.microtask(() {});
          return false;
        }
        matchedTrack = savedTrack;
      }

      final savedQueue = <TrackInfo>[];
      final rawQueue = data['queue_tracks'];
      if (rawQueue is List) {
        for (final item in rawQueue) {
          final parsed = _deserializeTrack(item);
          if (parsed != null) {
            savedQueue.add(parsed);
          }
        }
      }

      final savedQueueIndex = (data['queue_index'] as num?)?.toInt() ?? 0;
      final restoredQueue = _mergeRestoredQueue(
        savedQueue: savedQueue,
        existingQueue: existingQueue,
        matchedTrack: matchedTrack,
        savedQueueIndex: savedQueueIndex,
        isInTest: isInTest,
      );

      var matchedIndex = findTrackIndex(restoredQueue, matchedTrack);
      if (matchedIndex < 0) {
        restoredQueue.insert(0, matchedTrack);
        matchedIndex = 0;
      }

      final savedPosMs = (data['position_ms'] as num?)?.toInt() ?? 0;
      var clampedPos = Duration(milliseconds: savedPosMs < 0 ? 0 : savedPosMs);
      if (matchedTrack.duration > Duration.zero &&
          clampedPos > matchedTrack.duration) {
        clampedPos = matchedTrack.duration;
      }

      await audioService.restorePlaybackSession(
        track: matchedTrack,
        position: clampedPos,
        queue: restoredQueue,
        queueIndex: matchedIndex,
        volume: savedVolume,
        isMuted: isMuted,
      );

      // Allow any broadcast stream events emitted during restore to be delivered
      // before clearing _isRestoring.
      await Future<void>.microtask(() {});

      debugPrint(
        '[PlaybackPersist] Restored: ${matchedTrack.title} @ ${clampedPos.inMilliseconds}ms',
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      _isRestoring = false;
    }
  }

  void dispose() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    final pending = _pendingSnapshot ??
        (_lastWrittenSeq < _snapshotSeq ? _lastSavedData : null);
    if (pending != null &&
        !_isRestoring &&
        !_shouldSkipEmptySnapshot(pending, allowEmptyTrack: false)) {
      _pendingSnapshot = null;
      _hasPendingSave = false;
      final seq = _snapshotSeq > _lastWrittenSeq ? _snapshotSeq : ++_snapshotSeq;
      _performSaveSync(pending, seq: seq);
    }
    _disposed = true;
  }
}
