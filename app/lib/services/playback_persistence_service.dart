import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/audio_format.dart';
import '../models/playback_state.dart';
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
  Map<String, dynamic>? _pendingSnapshot;
  Completer<void>? _activeSaveCompleter;
  bool _disposed = false;

  List<Map<String, dynamic>>? _cachedQueueTracks;
  int _cachedQueueLength = -1;
  String _cachedQueueSignature = '';

  PlaybackPersistenceService({
    this.prefsFileOverride,
    this.throttleDuration = const Duration(milliseconds: 3500),
  });

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
    if (raw is! Map<String, dynamic>) return null;
    final durMs = (raw['duration_ms'] as num?)?.toInt() ?? 0;
    final codecName = raw['codec']?.toString() ?? 'flac';
    final codec = AudioCodec.values.firstWhere(
      (c) => c.name.toLowerCase() == codecName.toLowerCase(),
      orElse: () => AudioCodec.flac,
    );

    return TrackInfo(
      id: raw['id']?.toString() ?? '',
      title: raw['title']?.toString() ?? '未知曲目',
      artist: raw['artist']?.toString() ?? '未知歌手',
      album: raw['album']?.toString() ?? '未知專輯',
      duration: Duration(milliseconds: durMs),
      coverUrl: raw['cover_url']?.toString(),
      albumArtUrl: raw['album_art_url']?.toString(),
      filePath: raw['file_path']?.toString(),
      albumArtist: raw['album_artist']?.toString(),
      genre: raw['genre']?.toString(),
      year: (raw['year'] as num?)?.toInt(),
      trackNumber: (raw['track_number'] as num?)?.toInt(),
      discNumber: (raw['disc_number'] as num?)?.toInt(),
      composer: raw['composer']?.toString(),
      artworkCacheKey: raw['artwork_cache_key']?.toString(),
      hasLyrics: raw['has_lyrics'] == true,
      format: AudioFormat(
        codec: codec,
        sampleRateHz: (raw['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (raw['bit_depth'] as num?)?.toInt() ?? 16,
        channels: (raw['channels'] as num?)?.toInt() ?? 2,
        isDsd: raw['is_dsd'] == true,
      ),
      providerName: raw['provider_name']?.toString() ?? 'local',
    );
  }

  Map<String, dynamic> buildSnapshot({
    required PlaybackState state,
    required List<TrackInfo> queue,
    int? queueIndex,
  }) {
    final track = state.track;
    final resolvedQueueIndex = queueIndex ??
        (track != null ? queue.indexWhere((t) => t.id == track.id) : 0);

    final queueSig =
        '${queue.length}_${queue.firstOrNull?.id}_${queue.lastOrNull?.id}';
    if (_cachedQueueTracks == null ||
        _cachedQueueLength != queue.length ||
        _cachedQueueSignature != queueSig) {
      _cachedQueueTracks = queue.map(_serializeTrack).toList();
      _cachedQueueLength = queue.length;
      _cachedQueueSignature = queueSig;
    }

    return {
      'version': 1,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'position_ms': state.position.inMilliseconds,
      'volume': state.volume,
      'is_muted': state.isMuted,
      'track': track != null ? _serializeTrack(track) : null,
      'queue_index': resolvedQueueIndex < 0 ? 0 : resolvedQueueIndex,
      'queue_tracks': _cachedQueueTracks,
    };
  }

  /// Saves snapshot immediately to disk using a single-flight worker to prevent unbounded Future queues.
  Future<void> saveImmediate(Map<String, dynamic> snapshot) async {
    if (_disposed) return;
    _lastSavedData = snapshot;
    _hasPendingSave = false;
    _throttleTimer?.cancel();
    _throttleTimer = null;

    if (_isSaving) {
      _pendingSnapshot = snapshot;
      return _activeSaveCompleter?.future ?? Future.value();
    }

    _isSaving = true;
    _activeSaveCompleter = Completer<void>();

    try {
      Map<String, dynamic>? nextSnapshot = snapshot;
      while (nextSnapshot != null && !_disposed) {
        final currentToSave = nextSnapshot;
        _pendingSnapshot = null;
        await _performSave(currentToSave);
        nextSnapshot = _pendingSnapshot;
      }
    } finally {
      _isSaving = false;
      _activeSaveCompleter?.complete();
      _activeSaveCompleter = null;
    }
  }

  Future<void> _performSave(Map<String, dynamic> snapshot) async {
    final file = _resolveFile();
    if (file == null) return;

    try {
      final payload = const JsonEncoder.withIndent('  ').convert(snapshot);
      final parent = file.parent;
      if (prefsFileOverride != null) {
        if (!parent.existsSync()) parent.createSync(recursive: true);
        file.writeAsStringSync(payload, flush: true);
      } else {
        if (!await parent.exists()) await parent.create(recursive: true);
        await file.writeAsString(payload, flush: true);
      }
    } catch (e) {
      if (kDebugMode) {
        // ignore: avoid_print
        print('PlaybackPersistenceService save error: $e');
      }
    }
  }

  /// Throttled save: calls will execute at most once per [throttleDuration].
  void saveThrottled(Map<String, dynamic> snapshot) {
    if (_disposed) return;
    _lastSavedData = snapshot;
    _hasPendingSave = true;

    if (_throttleTimer != null && _throttleTimer!.isActive) {
      return;
    }

    _throttleTimer = Timer(throttleDuration, () {
      if (_hasPendingSave && _lastSavedData != null) {
        saveImmediate(_lastSavedData!);
      }
    });
  }

  /// Flushes any pending throttled saves immediately (e.g. on window close).
  Future<void> flush() async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    if (_hasPendingSave && _lastSavedData != null) {
      await saveImmediate(_lastSavedData!);
    } else if (_isSaving && _activeSaveCompleter != null) {
      await _activeSaveCompleter!.future;
    }
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
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  /// Restores saved playback session onto [audioService].
  /// Sets volume, restores track info & position, and leaves player in paused state.
  Future<bool> restoreSession(AudioService audioService) async {
    final data = await load();
    if (data == null) return false;

    try {
      final savedVolume = (data['volume'] as num?)?.toDouble();
      if (savedVolume != null && savedVolume.isFinite) {
        await audioService.setVolume(savedVolume.clamp(0.0, 1.0));
      }

      final rawTrack = data['track'];
      final savedTrack = _deserializeTrack(rawTrack);
      final savedPosMs = (data['position_ms'] as num?)?.toInt() ?? 0;
      final savedPos = Duration(milliseconds: savedPosMs);

      if (savedTrack != null) {
        // Seek to saved position without auto-playing
        if (savedPos > Duration.zero) {
          await audioService.seek(savedPos);
        }
        return true;
      }
    } catch (_) {}
    return false;
  }

  void dispose() {
    _disposed = true;
    _throttleTimer?.cancel();
    _throttleTimer = null;
  }
}
