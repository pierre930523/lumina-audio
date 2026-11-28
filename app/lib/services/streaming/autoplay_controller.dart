import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/recommendation_models.dart';
import '../../models/streaming_models.dart';
import '../playback_persistence_service.dart';
import '../recommendation_settings_controller.dart';
import 'autoplay_filter.dart';
import 'cross_platform_track_router.dart';
import 'recommendation_provider.dart';

part 'autoplay/autoplay_queue_ops.dart';
part 'autoplay/autoplay_refill_ops.dart';

/// Manages the dual-segment playback queue (`_userQueue` + `_autoQueue`),
/// effective seed qualification, single-flight background radio refills,
/// epoch-guarded cancellation, and silent auto-track failure tracking.
class AutoplayController {
  static const int maxConsecutiveAutoFailures = 5;
  static const int _maxEmptyPageRetries = 2;

  final RecommendationProvider? Function(String providerId) providerLookup;
  final List<RecommendationProvider> _externalProviders;
  final List<RecommendationProvider> Function()? externalProvidersProvider;
  final CrossPlatformTrackRouter? trackRouter;
  final RecommendationSettingsController? settings;
  final bool Function(String providerId)? isAuthRequiredLookup;
  final bool Function(String providerId)? isGuestCapableLookup;
  final StreamingAuthState Function(String providerId)? authStateLookup;
  final AutoplayFilter filter;
  final DateTime Function() _clock;
  final int refillTriggerRemaining;
  final int refillTargetCount;
  final bool allowBackgroundRefill;
  final void Function(String message)? logSink;

  final List<TrackInfo> _userQueue = <TrackInfo>[];
  final List<TrackInfo> _autoQueue = <TrackInfo>[];
  final Map<String, String?> _radioCursors = <String, String?>{};
  final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  TrackInfo? _currentTrack;
  bool _currentFromAutoQueue = false;
  int _userCursorIndex = -1;
  int _queueEpoch = 0;
  bool _enabled = true;
  Future<void>? _inFlightRefill;
  int _inFlightRefillEpoch = -1;
  CancellationToken? _inFlightRefillCancel;
  int _consecutiveAutoFailures = 0;
  bool _disposed = false;

  Duration _maxObservedPosition = Duration.zero;
  DateTime? _currentTrackStartedAt;
  bool _seedQualifiedForCurrentPlay = false;

  AutoplayController({
    required this.providerLookup,
    List<RecommendationProvider> externalProviders =
        const <RecommendationProvider>[],
    this.externalProvidersProvider,
    this.trackRouter,
    this.settings,
    this.isAuthRequiredLookup,
    this.isGuestCapableLookup,
    this.authStateLookup,
    AutoplayFilter? filter,
    DateTime Function()? clock,
    this.refillTriggerRemaining = 2,
    int refillTargetCount = 8,
    this.allowBackgroundRefill = true,
    this.logSink,
  }) : _externalProviders = List<RecommendationProvider>.from(externalProviders),
       filter = filter ?? AutoplayFilter(),
       _clock = clock ?? DateTime.now,
       refillTargetCount = refillTargetCount < 1 ? 1 : refillTargetCount {
    if (settings != null) {
      _enabled = settings!.autoplayEnabled;
      settings!.addListener(_onSettingsChanged);
    }
  }

  void _onSettingsChanged() {
    if (_disposed || settings == null) return;
    final next = settings!.autoplayEnabled;
    if (next != _enabled) {
      setEnabled(next);
    }
  }

  void _log(String message) {
    final sink = logSink;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint(message);
    }
  }

  void _emitChange() {
    if (!_disposed && !_changesController.isClosed) {
      _changesController.add(null);
    }
  }

  bool get enabled => _enabled;
  int get queueEpoch => _queueEpoch;
  bool get isRefilling => _inFlightRefill != null;
  int get consecutiveAutoFailures => _consecutiveAutoFailures;
  List<TrackInfo> get userQueue => List<TrackInfo>.unmodifiable(_userQueue);
  List<TrackInfo> get autoQueue => List<TrackInfo>.unmodifiable(_autoQueue);
  TrackInfo? get currentTrack => _currentTrack;
  bool get isCurrentFromAutoQueue => _currentFromAutoQueue;
  Stream<void> get changes => _changesController.stream;

  int get remainingUserQueueCount {
    if (_userQueue.isEmpty) return 0;
    final nextStart = _userCursorIndex + 1;
    if (nextStart <= 0) return _userQueue.length;
    if (nextStart >= _userQueue.length) return 0;
    return _userQueue.length - nextStart;
  }

  int get totalRemainingCount => remainingUserQueueCount + _autoQueue.length;

  bool get needsRefill =>
      !_disposed &&
      _enabled &&
      allowBackgroundRefill &&
      totalRemainingCount <= refillTriggerRemaining;

  List<TrackInfo> get combinedQueue {
    if (!_currentFromAutoQueue || _currentTrack == null) {
      return List<TrackInfo>.unmodifiable(<TrackInfo>[
        ..._userQueue,
        ..._autoQueue,
      ]);
    }

    final playedEnd = (_userCursorIndex + 1).clamp(0, _userQueue.length);
    return List<TrackInfo>.unmodifiable(<TrackInfo>[
      ..._userQueue.sublist(0, playedEnd),
      _currentTrack!,
      ..._userQueue.sublist(playedEnd),
      ..._autoQueue,
    ]);
  }

  bool isAutoTrack(String trackId) {
    if (_currentFromAutoQueue && _currentTrack?.id == trackId) return true;
    return _autoQueue.any((t) => t.id == trackId);
  }

  void _cancelActiveRefill() {
    _inFlightRefillCancel?.cancel();
    _inFlightRefillCancel = null;
  }

  void _resetTrackProgressTimer() {
    _maxObservedPosition = Duration.zero;
    _currentTrackStartedAt = _currentTrack != null ? _clock() : null;
    _seedQualifiedForCurrentPlay = false;
  }

  void _recordRecent(TrackInfo track) {
    filter.recentHistory.record(TrackMetadata.fromTrackInfo(track));
  }

  void setUserQueue(
    List<TrackInfo> tracks, {
    TrackInfo? currentTrack,
    int? currentIndex,
    bool bumpEpoch = true,
  }) =>
      _setUserQueueImpl(
        tracks,
        currentTrack: currentTrack,
        currentIndex: currentIndex,
        bumpEpoch: bumpEpoch,
      );

  int appendToUserQueue(List<TrackInfo> tracks, {bool playNext = false}) =>
      _appendToUserQueueImpl(tracks, playNext: playNext);

  void syncTrackPreference(String trackId, int preference) =>
      _syncTrackPreferenceImpl(trackId, preference);

  void syncArtistPreference(String artist, int preference) =>
      filter.setBannedArtist(artist, preference == -1);

  void clearAll() => _clearAllImpl();

  /// Clears all upcoming tracks strictly after the currently playing track
  /// (remaining user queue and auto-generated recommendations), while keeping
  /// the current track and played history intact. Returns cleared track count.
  int clearUpcoming() => _clearUpcomingImpl();

  void setEnabled(bool value) => _setEnabledImpl(value);

  void clearAutoQueue() => _clearAutoQueueImpl();

  void removeAutoTrack(String trackId) => _removeAutoTrackImpl(trackId);

  void promoteAutoTrackToUserQueue(String trackId, {int? targetUserIndex}) =>
      _promoteAutoTrackToUserQueueImpl(
        trackId,
        targetUserIndex: targetUserIndex,
      );

  void reorderDualQueue(int oldCombinedIndex, int newCombinedIndex) =>
      _reorderDualQueueImpl(oldCombinedIndex, newCombinedIndex);

  TrackInfo? peekNextTrack() {
    if (_userQueue.isNotEmpty) {
      final start = (_userCursorIndex + 1).clamp(0, _userQueue.length);
      for (var i = start; i < _userQueue.length; i++) {
        if (_userQueue[i].preference != -1) {
          return _userQueue[i];
        }
      }
    }
    for (final t in _autoQueue) {
      if (t.preference != -1) {
        return t;
      }
    }
    return null;
  }

  Duration get currentTrackObservedPlayDuration {
    final now = _clock();
    final wallPlayed = _currentTrackStartedAt != null
        ? now.difference(_currentTrackStartedAt!)
        : Duration.zero;
    return _maxObservedPosition > wallPlayed ? _maxObservedPosition : wallPlayed;
  }

  /// Atomically consumes a transitioned [track] from `user_queue` (when
  /// `remainingUserQueueCount > 0`) or `_autoQueue` (matching by id or
  /// normalized `providerId:trackId`), merging richer queue metadata into the
  /// returned active [TrackInfo] and triggering background refill when
  /// `needsRefill` (`<= 2`).
  TrackInfo consumeTransitionedTrack(
    TrackInfo track, {
    bool userInitiatedSkip = false,
    bool forceAdvance = false,
    bool deferSideEffects = false,
  }) {
    if (_disposed) return track;

    if (!forceAdvance &&
        _currentTrack != null &&
        _tracksMatch(_currentTrack!, track)) {
      // Metadata/duration enrichment for the already-active track.
      final prev = _currentTrack!;
      final merged = _mergeQueueEntryMetadata(track, prev);
      _currentTrack = merged;
      final metaChanged =
          merged.title != prev.title ||
          merged.artist != prev.artist ||
          merged.album != prev.album ||
          merged.coverUrl != prev.coverUrl ||
          merged.duration != prev.duration;
      if (metaChanged) {
        _emitChange();
      }
      if (!deferSideEffects && needsRefill) {
        unawaited(maybeTriggerRefill());
      }
      return merged;
    }

    // Quick-skip detection: user skipping out of an auto-queued track within 10s
    // downranks its primary artist for 30 minutes and keeps it out of seeds.
    if (!deferSideEffects &&
        userInitiatedSkip &&
        _currentFromAutoQueue &&
        _currentTrack != null) {
      final now = _clock();
      final observed = currentTrackObservedPlayDuration;
      if (observed < EffectiveSeedPool.quickSkipThreshold) {
        filter.seedPool.recordQuickSkip(
          TrackMetadata.fromTrackInfo(_currentTrack!),
          now,
        );
      }
    }

    if (remainingUserQueueCount > 0) {
      final remainingStart = (_userCursorIndex + 1).clamp(0, _userQueue.length);
      final remainingUserIdx = remainingStart < _userQueue.length
          ? _findTrackIndex(_userQueue.sublist(remainingStart), track)
          : -1;
      if (remainingUserIdx >= 0) {
        final targetIdx = remainingStart + remainingUserIdx;
        final merged = _mergeQueueEntryMetadata(track, _userQueue[targetIdx]);
        _userQueue[targetIdx] = merged;
        _userCursorIndex = targetIdx;
        _currentTrack = merged;
        _currentFromAutoQueue = false;
      } else {
        _consumeFromAutoOrEarlierUserQueue(track);
      }
    } else {
      _consumeFromAutoOrEarlierUserQueue(track);
    }

    final resolved = _currentTrack!;
    if (!deferSideEffects) {
      _recordRecent(resolved);
    }
    _resetTrackProgressTimer();
    _emitChange();

    if (!deferSideEffects && needsRefill) {
      unawaited(maybeTriggerRefill());
    }
    return resolved;
  }

  void _consumeFromAutoOrEarlierUserQueue(TrackInfo track) {
    final autoIdx = _findTrackIndex(_autoQueue, track);
    if (autoIdx >= 0) {
      final popped = _autoQueue.removeAt(autoIdx);
      _currentTrack = _mergeQueueEntryMetadata(track, popped);
      _currentFromAutoQueue = true;
    } else {
      final earlierUserIdx = _findTrackIndex(_userQueue, track);
      if (earlierUserIdx >= 0) {
        final merged = _mergeQueueEntryMetadata(
          track,
          _userQueue[earlierUserIdx],
        );
        _userQueue[earlierUserIdx] = merged;
        _userCursorIndex = earlierUserIdx;
        _currentTrack = merged;
        _currentFromAutoQueue = false;
      } else {
        _currentTrack = track;
        _currentFromAutoQueue = false;
      }
    }
  }

  void advanceToTrack(
    TrackInfo track, {
    bool userInitiatedSkip = false,
    bool deferSideEffects = false,
  }) {
    consumeTransitionedTrack(
      track,
      userInitiatedSkip: userInitiatedSkip,
      deferSideEffects: deferSideEffects,
    );
  }

  /// Commits deferred quick-skip penalty, recent-history recording, and
  /// background refill once a rapid-skip burst settles on [settledTrack].
  void finalizeSettledSkip({
    TrackInfo? abandonedTrack,
    required bool abandonedWasAuto,
    required Duration abandonedPlayed,
    required TrackInfo settledTrack,
  }) {
    if (_disposed) return;
    if (abandonedTrack != null &&
        abandonedWasAuto &&
        abandonedTrack.id != settledTrack.id &&
        abandonedPlayed < EffectiveSeedPool.quickSkipThreshold) {
      filter.seedPool.recordQuickSkip(
        TrackMetadata.fromTrackInfo(abandonedTrack),
        _clock(),
      );
    }
    _recordRecent(settledTrack);
    _resetTrackProgressTimer();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  void onPlaybackProgress(TrackInfo track, Duration position) {
    if (_disposed) return;
    if (_currentTrack == null || _currentTrack!.id != track.id) return;
    if (position < Duration.zero) return;

    if (position > _maxObservedPosition) {
      _maxObservedPosition = position;
    }

    // Never qualify a banned track (`preference == -1`) as an autoplay seed.
    if (track.preference == -1 || _currentTrack!.preference == -1) {
      return;
    }

    final effectiveDuration = track.duration > Duration.zero
        ? track.duration
        : _currentTrack!.duration;

    if (!_seedQualifiedForCurrentPlay &&
        EffectiveSeedPool.isQualifiedSeed(
          _maxObservedPosition,
          effectiveDuration,
        )) {
      _seedQualifiedForCurrentPlay = true;
      final qualifiedMeta = TrackMetadata.fromTrackInfo(
        track.duration > Duration.zero ? track : _currentTrack!,
      );
      filter.seedPool.recordQualifiedSeed(qualifiedMeta);
      _consecutiveAutoFailures = 0;
    }
  }

  ({TrackInfo? nextTrack, bool reachedFailureLimit})
  handleAutoTrackUnplayable(TrackInfo failedTrack, String reason) {
    _log('[Autoplay] Unplayable auto track ${failedTrack.id}: $reason');

    final removed = _autoQueue.any((t) => t.id == failedTrack.id);
    _autoQueue.removeWhere((t) => t.id == failedTrack.id);
    if (_currentFromAutoQueue && _currentTrack?.id == failedTrack.id) {
      _currentTrack = null;
      _currentFromAutoQueue = false;
    }
    _recordRecent(failedTrack);
    _consecutiveAutoFailures++;
    if (removed || _currentTrack == null) {
      _emitChange();
    }

    if (_consecutiveAutoFailures >= maxConsecutiveAutoFailures) {
      return (nextTrack: null, reachedFailureLimit: true);
    }

    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
    return (nextTrack: peekNextTrack(), reachedFailureLimit: false);
  }

  Future<void> maybeTriggerRefill({TrackMetadata? seedOverride}) =>
      _maybeTriggerRefillImpl(seedOverride: seedOverride);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    settings?.removeListener(_onSettingsChanged);
    _cancelActiveRefill();
    if (!_changesController.isClosed) {
      unawaited(_changesController.close());
    }
  }
}
