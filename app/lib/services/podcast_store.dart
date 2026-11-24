import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/podcast_models.dart';
import 'audio_service.dart';
import 'streaming/providers/youtube_music_provider.dart';

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

/// Bridges [AudioService] and [PodcastStore] to provide:
/// 1. Automatic throttled position saving during Podcast playback + immediate
///    flush on pause, stop, track switch, or disposal.
/// 2. One-shot auto-resume seek when a Podcast episode with saved progress
///    (`positionSeconds >= 5 && !completed`) begins playing.
/// 3. Clamped `-15s` / `+30s` relative skip helpers.
class PodcastPlaybackTracker {
  static const Duration skipBackwardDelta = Duration(seconds: -15);
  static const Duration skipForwardDelta = Duration(seconds: 30);

  final AudioService audioService;
  final PodcastStore store;

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;

  String? _activeTrackId;
  String? _activePodcastVideoId;
  Duration _lastKnownPosition = Duration.zero;
  Duration _lastKnownDuration = Duration.zero;
  PlaybackStatus _lastStatus = PlaybackStatus.uninitialized;
  String? _pendingAutoResumeVideoId;
  int? _pendingAutoResumeSeconds;
  bool _autoResumeSeekInFlight = false;
  bool _disposed = false;

  PodcastPlaybackTracker({
    required this.audioService,
    PodcastStore? store,
  }) : store = store ?? PodcastStore.instance {
    this.store.ensureLoadedSync();
    _stateSub = audioService.stateStream.listen(_onPlaybackState);
    _positionSub = audioService.positionStream.listen(_onPositionTick);
    _onPlaybackState(audioService.currentState);
  }

  static bool isPodcastTrack(TrackInfo? track) =>
      track != null && track.providerName == 'Podcast';

  /// Clamps `currentPosition + delta` to `[Duration.zero, trackDuration]`.
  static Duration computeClampedSeek({
    required Duration currentPosition,
    required Duration trackDuration,
    required Duration delta,
  }) {
    final rawMs = currentPosition.inMilliseconds + delta.inMilliseconds;
    if (rawMs <= 0) return Duration.zero;
    if (trackDuration > Duration.zero && rawMs >= trackDuration.inMilliseconds) {
      return trackDuration;
    }
    return Duration(milliseconds: rawMs);
  }

  /// Seeks relative by [delta] (`-15s` or `+30s`) clamped to the active track's
  /// `[Duration.zero, track.duration]` bounds.
  static Future<Duration> seekRelative(
    AudioService audioService,
    Duration delta, {
    PodcastStore? store,
  }) async {
    final state = audioService.currentState;
    final track = state.track;
    final target = computeClampedSeek(
      currentPosition: state.position,
      trackDuration: track?.duration ?? Duration.zero,
      delta: delta,
    );
    await audioService.seek(target);
    if (isPodcastTrack(track)) {
      final effectiveStore = store ?? PodcastStore.instance;
      effectiveStore.updateProgress(
        videoId: track!.id,
        position: target,
        duration: track.duration,
        immediate: true,
      );
    }
    return target;
  }

  void _onPlaybackState(PlaybackState state) {
    if (_disposed) return;

    final track = state.track;
    final nextTrackId = track?.id;
    final trackChanged = nextTrackId != _activeTrackId;

    // 1. If we switched away from an active podcast episode, flush its last progress.
    if (trackChanged && _activePodcastVideoId != null) {
      if (_lastKnownPosition > Duration.zero) {
        store.updateProgress(
          videoId: _activePodcastVideoId!,
          position: _lastKnownPosition,
          duration: _lastKnownDuration,
          immediate: true,
        );
      }
      _activePodcastVideoId = null;
      _pendingAutoResumeVideoId = null;
      _pendingAutoResumeSeconds = null;
      _autoResumeSeekInFlight = false;
    }

    // 2. When a new podcast track is selected (or re-triggered via loading),
    //    arm one-shot auto-resume if saved progress has positionSeconds >= 5 && !completed.
    final isNewPlaySession = trackChanged ||
        (state.status == PlaybackStatus.loading &&
            _lastStatus != PlaybackStatus.loading);

    _activeTrackId = nextTrackId;

    if (isPodcastTrack(track)) {
      final cleanVid = PodcastStore.normalizeVideoId(track!.id);
      _activePodcastVideoId = cleanVid;
      if (track.duration > Duration.zero) {
        _lastKnownDuration = track.duration;
      }

      if (isNewPlaySession && cleanVid.isNotEmpty) {
        final saved = store.progressFor(cleanVid);
        if (saved != null && saved.positionSeconds >= 5 && !saved.completed) {
          _pendingAutoResumeVideoId = cleanVid;
          _pendingAutoResumeSeconds = saved.positionSeconds;
        } else {
          _pendingAutoResumeVideoId = null;
          _pendingAutoResumeSeconds = null;
        }
        _lastKnownPosition = state.position;
      }

      // 3. One-shot auto-resume once the episode enters PlaybackStatus.playing.
      if (state.status == PlaybackStatus.playing &&
          _pendingAutoResumeVideoId == cleanVid &&
          _pendingAutoResumeSeconds != null) {
        final resumeSec = _pendingAutoResumeSeconds!;
        _pendingAutoResumeVideoId = null;
        _pendingAutoResumeSeconds = null;
        _autoResumeSeekInFlight = true;
        final targetPos = Duration(seconds: resumeSec);
        _lastKnownPosition = targetPos;
        unawaited(
          audioService.seek(targetPos).whenComplete(() {
            _autoResumeSeekInFlight = false;
          }),
        );
        _lastStatus = state.status;
        return;
      }

      // 4. Persist position on state changes.
      if (!_autoResumeSeekInFlight && cleanVid.isNotEmpty) {
        if (state.position > Duration.zero) {
          _lastKnownPosition = state.position;
        }
        final isPlaying = state.status == PlaybackStatus.playing;
        final wasPlaying = _lastStatus == PlaybackStatus.playing;
        if (isPlaying && state.position > Duration.zero) {
          store.updateProgress(
            videoId: cleanVid,
            position: state.position,
            duration: track.duration,
            immediate: false,
          );
        } else if (wasPlaying && !isPlaying && _lastKnownPosition > Duration.zero) {
          store.updateProgress(
            videoId: cleanVid,
            position: _lastKnownPosition,
            duration: track.duration,
            immediate: true,
          );
        } else if (state.status == PlaybackStatus.ended &&
            _lastKnownDuration > Duration.zero) {
          store.updateProgress(
            videoId: cleanVid,
            position: _lastKnownDuration,
            duration: _lastKnownDuration,
            immediate: true,
          );
        }
      }
    } else {
      _activePodcastVideoId = null;
      _pendingAutoResumeVideoId = null;
      _pendingAutoResumeSeconds = null;
    }

    _lastStatus = state.status;
  }

  void _onPositionTick(Duration position) {
    if (_disposed || _autoResumeSeekInFlight) return;
    final state = audioService.currentState;
    final track = state.track;
    if (!isPodcastTrack(track)) return;
    if (state.status != PlaybackStatus.playing) return;
    if (_pendingAutoResumeVideoId != null) return;
    if (position <= Duration.zero) return;

    final cleanVid =
        _activePodcastVideoId ?? PodcastStore.normalizeVideoId(track!.id);
    if (cleanVid.isEmpty) return;

    _lastKnownPosition = position;
    if (track!.duration > Duration.zero) {
      _lastKnownDuration = track.duration;
    }
    store.updateProgress(
      videoId: cleanVid,
      position: position,
      duration: track.duration,
      immediate: false,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stateSub?.cancel();
    _stateSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    if (_activePodcastVideoId != null && _lastKnownPosition > Duration.zero) {
      store.updateProgress(
        videoId: _activePodcastVideoId!,
        position: _lastKnownPosition,
        duration: _lastKnownDuration,
        immediate: true,
      );
    }
    unawaited(store.flush(sync: true));
  }
}
