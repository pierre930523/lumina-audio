import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/podcast_models.dart';
import 'streaming/providers/youtube_music_provider.dart';

export 'podcast/podcast_playback_tracker.dart';

/// Persistent store for Podcast episode listening progress and locally
/// bookmarked YouTube Music podcast shows (`%LOCALAPPDATA%\LuminaAudio\podcast_state.json`).
///
/// Automatically skips disk I/O under `FLUTTER_TEST` unless a custom
/// [storageFile] or [storageFilePath] is explicitly injected.
class PodcastStore extends ChangeNotifier {
  static final PodcastStore instance = PodcastStore();

  final File? _injectedFile;
  final DateTime Function() _clock;
  final Duration throttleInterval;

  final Map<String, PodcastEpisodeProgress> _progressByVideoId =
      <String, PodcastEpisodeProgress>{};
  final List<PodcastShow> _bookmarkedShows = <PodcastShow>[];

  Timer? _throttleTimer;
  bool _dirty = false;
  bool _loaded = false;
  bool _disposed = false;

  PodcastStore({
    File? storageFile,
    String? storageFilePath,
    DateTime Function()? clock,
    this.throttleInterval = const Duration(seconds: 3),
  })  : _injectedFile = storageFile ??
            (storageFilePath != null && storageFilePath.trim().isEmpty == false
                ? File(storageFilePath.trim())
                : null),
        _clock = clock ?? DateTime.now;

  File? get _effectiveFile {
    if (_injectedFile != null) return _injectedFile;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    if (!Platform.isWindows) return null;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) return null;
    return File(
      '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}podcast_state.json',
    );
  }

  Map<String, PodcastEpisodeProgress> get progressMap =>
      Map<String, PodcastEpisodeProgress>.unmodifiable(_progressByVideoId);

  List<PodcastShow> get bookmarkedShows =>
      List<PodcastShow>.unmodifiable(_bookmarkedShows);

  /// Normalizes a raw `videoId` or `ytm:<videoId>` track ID into a clean
  /// 11-char videoId (or trimmed non-prefix string for custom test IDs).
  static String normalizeVideoId(String rawId) {
    final trimmed = rawId.trim();
    if (trimmed.isEmpty) return '';
    final extracted = YouTubeMusicProvider.tryExtractCleanVideoId(trimmed);
    if (extracted != null && extracted.isNotEmpty) return extracted;
    var s = trimmed;
    for (final prefix in const <String>[
      'streaming:youtube_music:',
      'youtube_music:',
      'podcast_rss:',
      'rss:',
      'ytm:',
      'MPED',
    ]) {
      if (s.startsWith(prefix) && s.length > prefix.length) {
        s = s.substring(prefix.length).trim();
      }
    }
    return s;
  }

  /// Synchronously loads state from disk if not yet loaded.
  void ensureLoadedSync() {
    if (_loaded) return;
    _loaded = true;
    loadSync();
  }

  /// Synchronously reads `podcast_state.json` from [_effectiveFile].
  void loadSync() {
    _loaded = true;
    final file = _effectiveFile;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      if (raw.trim().isEmpty) return;
      _applyDecodedJson(jsonDecode(raw));
      _safeNotify();
    } catch (_) {
      // Resilient to corrupted JSON state file.
    }
  }

  /// Asynchronously reads `podcast_state.json` from [_effectiveFile].
  Future<void> load() async {
    _loaded = true;
    final file = _effectiveFile;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      _applyDecodedJson(jsonDecode(raw));
      _safeNotify();
    } catch (_) {
      // Resilient to corrupted JSON state file.
    }
  }

  void _applyDecodedJson(dynamic decoded) {
    if (decoded is! Map) return;
    _progressByVideoId.clear();
    final rawProgress = decoded['progress'];
    if (rawProgress is Map) {
      for (final entry in rawProgress.entries) {
        if (entry.value is Map) {
          final map = Map<String, dynamic>.from(entry.value as Map);
          map['videoId'] ??= entry.key.toString();
          final p = PodcastEpisodeProgress.fromJson(map);
          final key = normalizeVideoId(p.videoId);
          if (key.isNotEmpty) {
            _progressByVideoId[key] = p.copyWith(videoId: key);
          }
        }
      }
    }

    _bookmarkedShows.clear();
    final rawShows = decoded['bookmarkedShows'];
    if (rawShows is List) {
      final seen = <String>{};
      for (final item in rawShows) {
        if (item is Map) {
          final show = PodcastShow.fromJson(Map<String, dynamic>.from(item));
          if (show.id.isNotEmpty && seen.add(show.id)) {
            _bookmarkedShows.add(show);
          }
        }
      }
    }
  }

  PodcastEpisodeProgress? progressFor(String videoIdOrTrackId) {
    ensureLoadedSync();
    final key = normalizeVideoId(videoIdOrTrackId);
    if (key.isEmpty) return null;
    return _progressByVideoId[key];
  }

  bool isBookmarked(String showId) {
    ensureLoadedSync();
    final clean = showId.trim();
    if (clean.isEmpty) return false;
    return _bookmarkedShows.any((s) => s.id == clean);
  }

  Future<void> addBookmark(PodcastShow show) async {
    ensureLoadedSync();
    final cleanId = show.id.trim();
    if (cleanId.isEmpty) return;
    final idx = _bookmarkedShows.indexWhere((s) => s.id == cleanId);
    if (idx >= 0) {
      _bookmarkedShows[idx] = show;
    } else {
      _bookmarkedShows.insert(0, show);
    }
    _dirty = true;
    _safeNotify();
    await flush(sync: true);
  }

  Future<void> removeBookmark(String showId) async {
    ensureLoadedSync();
    final cleanId = showId.trim();
    if (cleanId.isEmpty) return;
    final before = _bookmarkedShows.length;
    _bookmarkedShows.removeWhere((s) => s.id == cleanId);
    if (_bookmarkedShows.length != before) {
      _dirty = true;
      _safeNotify();
      await flush(sync: true);
    }
  }

  Future<bool> toggleBookmark(PodcastShow show) async {
    ensureLoadedSync();
    if (isBookmarked(show.id)) {
      await removeBookmark(show.id);
      return false;
    } else {
      await addBookmark(show);
      return true;
    }
  }

  /// Merges locally bookmarked shows with remote subscribed shows from
  /// `FEmusic_library_non_music_audio_list`, preserving local bookmarks first
  /// and deduplicating by `show.id`.
  List<PodcastShow> mergeWithRemoteShows(List<PodcastShow> remoteShows) {
    ensureLoadedSync();
    final merged = <PodcastShow>[];
    final seen = <String>{};
    for (final local in _bookmarkedShows) {
      if (local.id.isNotEmpty && seen.add(local.id)) {
        merged.add(local);
      }
    }
    for (final remote in remoteShows) {
      if (remote.id.isNotEmpty && seen.add(remote.id)) {
        merged.add(remote);
      }
    }
    return merged;
  }

  /// Updates listening progress for [videoId].
  ///
  /// When [immediate] is true, flushes to disk immediately; otherwise schedules
  /// a throttled background save.
  void updateProgress({
    required String videoId,
    required Duration position,
    required Duration duration,
    bool immediate = false,
  }) {
    ensureLoadedSync();
    final key = normalizeVideoId(videoId);
    if (key.isEmpty) return;

    final posSec = position.inSeconds < 0 ? 0 : position.inSeconds;
    final existing = _progressByVideoId[key];
    final durSec = duration.inSeconds > 0
        ? duration.inSeconds
        : (existing?.durationSeconds ?? 0);

    final completed = PodcastEpisodeProgress.shouldMarkCompleted(
      positionSeconds: posSec,
      durationSeconds: durSec,
    );

    final next = PodcastEpisodeProgress(
      videoId: key,
      positionSeconds: posSec,
      durationSeconds: durSec,
      updatedAt: _clock().toUtc(),
      completed: completed,
    );

    final changed = existing == null ||
        existing.positionSeconds != next.positionSeconds ||
        existing.durationSeconds != next.durationSeconds ||
        existing.completed != next.completed;

    _progressByVideoId[key] = next;
    if (changed) {
      _dirty = true;
      _safeNotify();
    }

    if (immediate) {
      unawaited(flush(sync: true));
    } else if (_dirty) {
      _scheduleThrottledFlush();
    }
  }

  void _scheduleThrottledFlush() {
    if (_throttleTimer != null && _throttleTimer!.isActive) return;
    _throttleTimer = Timer(throttleInterval, () {
      _throttleTimer = null;
      if (!_disposed && _dirty) {
        unawaited(flush(sync: false));
      }
    });
  }

  Map<String, dynamic> _buildPayloadJson() {
    final progressJson = <String, dynamic>{};
    for (final entry in _progressByVideoId.entries) {
      progressJson[entry.key] = entry.value.toJson();
    }
    return <String, dynamic>{
      'version': 1,
      'updatedAt': _clock().toUtc().toIso8601String(),
      'progress': progressJson,
      'bookmarkedShows': _bookmarkedShows.map((s) => s.toJson()).toList(),
    };
  }

  Future<void> flush({bool sync = false}) async {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    final file = _effectiveFile;
    if (file == null) {
      _dirty = false;
      return;
    }
    try {
      final encoded = jsonEncode(_buildPayloadJson());
      if (sync) {
        if (!file.parent.existsSync()) {
          file.parent.createSync(recursive: true);
        }
        file.writeAsStringSync(encoded, flush: true);
      } else {
        if (!file.parent.existsSync()) {
          await file.parent.create(recursive: true);
        }
        await file.writeAsString(encoded, flush: true);
      }
      _dirty = false;
    } catch (_) {}
  }

  @visibleForTesting
  void resetForTest() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _progressByVideoId.clear();
    _bookmarkedShows.clear();
    _dirty = false;
    _loaded = true;
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_dirty) {
      unawaited(flush(sync: true));
    } else {
      _throttleTimer?.cancel();
      _throttleTimer = null;
    }
    super.dispose();
  }
}
