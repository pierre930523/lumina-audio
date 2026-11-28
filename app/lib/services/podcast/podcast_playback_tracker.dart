import 'dart:async';

import '../../models/playback_state.dart';
import '../audio_service.dart';
import '../podcast_store.dart';

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
