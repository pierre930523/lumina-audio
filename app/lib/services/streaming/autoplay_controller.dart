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
  }) {
    if (_disposed) return;

    final prevCurrentId = _currentTrack?.id;
    if (bumpEpoch) {
      _queueEpoch++;
      _cancelActiveRefill();
      _autoQueue.clear();
      _radioCursors.clear();
      _consecutiveAutoFailures = 0;
    }

    _userQueue
      ..clear()
      ..addAll(tracks);

    if (currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < _userQueue.length) {
      _userCursorIndex = currentIndex;
      _currentTrack = currentTrack ?? _userQueue[currentIndex];
      _currentFromAutoQueue = false;
    } else if (currentTrack != null) {
      final idx = PlaybackPersistenceService.findTrackIndex(
        _userQueue,
        currentTrack,
      );
      if (idx >= 0) {
        _userCursorIndex = idx;
        _currentTrack = currentTrack;
        _currentFromAutoQueue = false;
      } else if (_currentFromAutoQueue &&
          _currentTrack?.id == currentTrack.id) {
        _userCursorIndex = _userQueue.length - 1;
        _currentTrack = currentTrack;
        _currentFromAutoQueue = true;
      } else {
        _userCursorIndex = -1;
        _currentTrack = currentTrack;
        _currentFromAutoQueue = false;
      }
    } else {
      _userCursorIndex = -1;
      _currentTrack = null;
      _currentFromAutoQueue = false;
    }

    if (_currentTrack != null && _currentTrack!.id != prevCurrentId) {
      _recordRecent(_currentTrack!);
      _resetTrackProgressTimer();
    } else if (_currentTrack == null) {
      _resetTrackProgressTimer();
    }

    _emitChange();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  void clearAll() {
    if (_disposed) return;
    _queueEpoch++;
    _cancelActiveRefill();
    _userQueue.clear();
    _autoQueue.clear();
    _radioCursors.clear();
    _currentTrack = null;
    _currentFromAutoQueue = false;
    _userCursorIndex = -1;
    _consecutiveAutoFailures = 0;
    _resetTrackProgressTimer();
    _emitChange();
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _queueEpoch++;
      _cancelActiveRefill();
      _autoQueue.clear();
      _consecutiveAutoFailures = 0;
      _emitChange();
    } else {
      _emitChange();
      if (needsRefill) {
        unawaited(maybeTriggerRefill());
      }
    }
    if (settings != null && settings!.autoplayEnabled != value) {
      unawaited(settings!.setAutoplayEnabled(value));
    }
  }

  void clearAutoQueue() {
    if (_disposed) return;
    _queueEpoch++;
    _cancelActiveRefill();
    _autoQueue.clear();
    _consecutiveAutoFailures = 0;
    _emitChange();
  }

  void removeAutoTrack(String trackId) {
    if (_disposed) return;
    final beforeLen = _autoQueue.length;
    _autoQueue.removeWhere((t) => t.id == trackId);
    if (_autoQueue.length != beforeLen) {
      _emitChange();
      if (needsRefill) {
        unawaited(maybeTriggerRefill());
      }
    }
  }

  void promoteAutoTrackToUserQueue(String trackId, {int? targetUserIndex}) {
    if (_disposed) return;
    final autoIdx = _autoQueue.indexWhere((t) => t.id == trackId);
    if (autoIdx < 0) return;

    final promoted = _autoQueue.removeAt(autoIdx);
    if (targetUserIndex == null) {
      _userQueue.add(promoted);
    } else {
      final insertIdx = targetUserIndex.clamp(0, _userQueue.length);
      _userQueue.insert(insertIdx, promoted);
      if (!_currentFromAutoQueue &&
          _userCursorIndex >= 0 &&
          insertIdx <= _userCursorIndex) {
        _userCursorIndex++;
      }
    }
    _emitChange();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  void reorderDualQueue(int oldCombinedIndex, int newCombinedIndex) {
    if (_disposed) return;
    final combined = combinedQueue;
    if (oldCombinedIndex < 0 ||
        oldCombinedIndex >= combined.length ||
        newCombinedIndex < 0 ||
        newCombinedIndex >= combined.length ||
        oldCombinedIndex == newCombinedIndex) {
      return;
    }

    final hasCurAuto = _currentFromAutoQueue && _currentTrack != null;
    final playedEnd = (_userCursorIndex + 1).clamp(0, _userQueue.length);
    final curAutoCombinedIdx = hasCurAuto ? playedEnd : -1;
    final autoStartIdx = _userQueue.length + (hasCurAuto ? 1 : 0);

    // Do not drag the currently playing auto track out from under playback.
    if (hasCurAuto && oldCombinedIndex == curAutoCombinedIdx) {
      return;
    }

    if (oldCombinedIndex < autoStartIdx) {
      // Moving an item that is already in _userQueue.
      final oldUserIdx = (hasCurAuto && oldCombinedIndex > curAutoCombinedIdx)
          ? oldCombinedIndex - 1
          : oldCombinedIndex;
      if (oldUserIdx < 0 || oldUserIdx >= _userQueue.length) return;

      final moved = _userQueue.removeAt(oldUserIdx);
      final maxUserDest = _userQueue.length;
      final rawDest = (hasCurAuto && newCombinedIndex > curAutoCombinedIdx)
          ? newCombinedIndex - 1
          : newCombinedIndex;
      final destUserIdx = rawDest.clamp(0, maxUserDest);
      _userQueue.insert(destUserIdx, moved);

      if (!_currentFromAutoQueue && _currentTrack != null) {
        final refreshedIdx = PlaybackPersistenceService.findTrackIndex(
          _userQueue,
          _currentTrack!,
        );
        if (refreshedIdx >= 0) {
          _userCursorIndex = refreshedIdx;
        }
      }
      _emitChange();
      return;
    }

    // Moving an item from _autoQueue: moving into or up to the user-queue
    // boundary automatically promotes it into _userQueue.
    final oldAutoIdx = oldCombinedIndex - autoStartIdx;
    if (oldAutoIdx < 0 || oldAutoIdx >= _autoQueue.length) return;

    final moved = _autoQueue.removeAt(oldAutoIdx);
    if (newCombinedIndex <= autoStartIdx) {
      final int destUserIdx;
      if (hasCurAuto && newCombinedIndex >= curAutoCombinedIdx) {
        // Place in remaining user queue (after already-played user tracks).
        destUserIdx = (newCombinedIndex - 1).clamp(playedEnd, _userQueue.length);
      } else {
        destUserIdx = newCombinedIndex.clamp(0, _userQueue.length);
        if (!_currentFromAutoQueue &&
            _userCursorIndex >= 0 &&
            destUserIdx <= _userCursorIndex) {
          _userCursorIndex++;
        }
      }
      _userQueue.insert(destUserIdx, moved);
    } else {
      final destAutoIdx = (newCombinedIndex - autoStartIdx).clamp(
        0,
        _autoQueue.length,
      );
      _autoQueue.insert(destAutoIdx, moved);
    }

    _emitChange();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  TrackInfo? peekNextTrack() {
    if (_userQueue.isNotEmpty) {
      final nextUserIdx = _userCursorIndex + 1;
      if (nextUserIdx >= 0 && nextUserIdx < _userQueue.length) {
        return _userQueue[nextUserIdx];
      }
    }
    if (_autoQueue.isNotEmpty) {
      return _autoQueue.first;
    }
    return null;
  }

  static bool _tracksMatch(TrackInfo a, TrackInfo b) {
    if (PlaybackPersistenceService.tracksMatch(a, b)) return true;
    if (a.id.trim().isNotEmpty && b.id.trim().isNotEmpty) {
      return a.responsiveArtworkKey == b.responsiveArtworkKey;
    }
    return false;
  }

  static int _findTrackIndex(List<TrackInfo> tracks, TrackInfo target) {
    final byExact = PlaybackPersistenceService.findTrackIndex(tracks, target);
    if (byExact >= 0) return byExact;
    if (target.id.trim().isEmpty) return -1;
    final targetKey = target.responsiveArtworkKey;
    return tracks.indexWhere(
      (t) => t.id.trim().isNotEmpty && t.responsiveArtworkKey == targetKey,
    );
  }

  static bool _isGenericDefaultFormat(AudioFormat f) {
    return f.codec == AudioCodec.flac &&
        f.sampleRateHz == 44100 &&
        f.bitDepth == 16 &&
        f.channels == 2 &&
        !f.isDsd &&
        f.bitrateKbps == null;
  }

  static TrackInfo _mergeQueueEntryMetadata(
    TrackInfo incoming,
    TrackInfo existing,
  ) {
    final mergedId = existing.id.trim().isNotEmpty ? existing.id : incoming.id;
    final inTitle = incoming.title.trim();
    final exTitle = existing.title.trim();
    final mergedTitle = (inTitle.isNotEmpty && inTitle != '未知曲目')
        ? incoming.title
        : (exTitle.isNotEmpty ? existing.title : incoming.title);
    final inArtist = incoming.artist.trim();
    final exArtist = existing.artist.trim();
    final mergedArtist = (inArtist.isNotEmpty && inArtist != '未知藝術家')
        ? incoming.artist
        : (exArtist.isNotEmpty ? existing.artist : incoming.artist);
    final inAlbum = incoming.album.trim();
    final exAlbum = existing.album.trim();
    final mergedAlbum = (inAlbum.isNotEmpty && inAlbum != '未知專輯')
        ? incoming.album
        : (exAlbum.isNotEmpty ? existing.album : incoming.album);
    final mergedCover =
        (incoming.coverUrl != null && incoming.coverUrl!.trim().isNotEmpty)
        ? incoming.coverUrl
        : existing.coverUrl;
    final mergedAlbumArt =
        (incoming.albumArtUrl != null &&
            incoming.albumArtUrl!.trim().isNotEmpty)
        ? incoming.albumArtUrl
        : (existing.albumArtUrl ?? mergedCover);
    final mergedDuration = incoming.duration > Duration.zero
        ? incoming.duration
        : existing.duration;
    final mergedFormat =
        _isGenericDefaultFormat(incoming.format) &&
            !_isGenericDefaultFormat(existing.format)
        ? existing.format
        : incoming.format;
    final mergedProvider =
        existing.providerName.trim().isNotEmpty &&
            existing.providerName != 'Remote Core' &&
            (incoming.providerName.trim().isEmpty ||
                incoming.providerName == 'Local Library' ||
                incoming.providerName == 'Remote Core')
        ? existing.providerName
        : incoming.providerName;

    return existing.copyWith(
      id: mergedId,
      title: mergedTitle,
      artist: mergedArtist,
      album: mergedAlbum,
      duration: mergedDuration,
      coverUrl: mergedCover,
      albumArtUrl: mergedAlbumArt,
      format: mergedFormat,
      providerName: mergedProvider,
      filePath: incoming.filePath ?? existing.filePath,
      albumArtist: incoming.albumArtist ?? existing.albumArtist,
      genre: incoming.genre ?? existing.genre,
      year: incoming.year ?? existing.year,
      trackNumber: incoming.trackNumber ?? existing.trackNumber,
      discNumber: incoming.discNumber ?? existing.discNumber,
      composer: incoming.composer ?? existing.composer,
      artworkCacheKey: incoming.artworkCacheKey ?? existing.artworkCacheKey,
      hasLyrics: incoming.hasLyrics || existing.hasLyrics,
      isrc: incoming.isrc ?? existing.isrc,
      qualityLabel: incoming.qualityLabel ?? existing.qualityLabel,
      artistId: incoming.artistId ?? existing.artistId,
    );
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
    } else {
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

  List<RecommendationProvider> get _effectiveExternalProviders =>
      externalProvidersProvider?.call() ?? _externalProviders;

  bool _isAuthRequired(String providerId) =>
      isAuthRequiredLookup?.call(providerId) ?? false;

  bool _isGuestCapable(String providerId) =>
      isGuestCapableLookup?.call(providerId) ?? (providerId == 'youtube_music');

  StreamingAuthState _authStateFor(String providerId) =>
      authStateLookup?.call(providerId) ?? StreamingAuthState.disconnected;

  bool _isProviderEligibleForRadio(String providerId) {
    final pid = providerId.trim().toLowerCase();
    if (pid.isEmpty || pid == 'local') return false;
    if (pid == 'youtube_music') {
      // YTM Guest mode works even without account login; ignore library-sync auth
      // state unless the provider itself is unavailable.
      return providerLookup(pid) != null;
    }
    if (_isAuthRequired(pid)) return false;
    if (pid == 'deezer') {
      // Deezer public radio/related endpoints work both connected and guest/public.
      return true;
    }
    if (_isGuestCapable(pid)) return true;
    return _authStateFor(pid) == StreamingAuthState.connected;
  }

  static bool _isCancellation(Object error, CancellationToken cancel) {
    if (cancel.isCancelled) return true;
    if (error is RecError && error.kind == RecErrorKind.cancelled) return true;
    if (error is StreamingException && error.isCancelled) return true;
    return false;
  }

  List<TrackMetadata> _buildActiveQueueTail() {
    final ordered = <TrackInfo>[];
    if (_currentTrack != null) {
      ordered.add(_currentTrack!);
    }
    final remainingStart = (_userCursorIndex + 1).clamp(0, _userQueue.length);
    if (remainingStart < _userQueue.length) {
      ordered.addAll(_userQueue.sublist(remainingStart));
    }
    ordered.addAll(_autoQueue);
    return ordered.map(TrackMetadata.fromTrackInfo).toList(growable: false);
  }

  Future<void> maybeTriggerRefill({TrackMetadata? seedOverride}) {
    if (_disposed || !_enabled) return Future<void>.value();
    if (!needsRefill && seedOverride == null) {
      return Future<void>.value();
    }

    final existing = _inFlightRefill;
    if (existing != null && _inFlightRefillEpoch == _queueEpoch) {
      return existing;
    }

    _cancelActiveRefill();
    final capturedEpoch = _queueEpoch;
    final cancel = CancellationToken();
    _inFlightRefillCancel = cancel;
    _inFlightRefillEpoch = capturedEpoch;

    late final Future<void> future;
    future =
        _runRefill(
          capturedEpoch: capturedEpoch,
          cancel: cancel,
          seedOverride: seedOverride,
        ).whenComplete(() {
          if (identical(_inFlightRefill, future)) {
            _inFlightRefill = null;
            _inFlightRefillEpoch = -1;
          }
          if (identical(_inFlightRefillCancel, cancel)) {
            _inFlightRefillCancel = null;
          }
        });
    _inFlightRefill = future;
    return future;
  }

  Future<void> _runRefill({
    required int capturedEpoch,
    required CancellationToken cancel,
    TrackMetadata? seedOverride,
  }) async {
    bool isStale() =>
        _disposed ||
        !_enabled ||
        capturedEpoch != _queueEpoch ||
        cancel.isCancelled;

    if (isStale()) return;

    final TrackMetadata? fallbackSeed = seedOverride ??
        (_currentTrack != null
            ? TrackMetadata.fromTrackInfo(_currentTrack!)
            : (_userQueue.isNotEmpty
                  ? TrackMetadata.fromTrackInfo(_userQueue.last)
                  : null));

    final seed = filter.seedPool.nextSeedForRefill(fallbackSeed: fallbackSeed);
    if (seed == null) return;

    final crossPlatformEnabled =
        settings?.crossPlatformRoutingEnabled ?? (trackRouter != null);

    // Apple Music DRM isolation: when cross-platform routing is off, external
    // Apple Music backend manages its own radio without polluting native queue.
    if (seed.providerId == 'apple_music' && !crossPlatformEnabled) {
      return;
    }

    final needed = (refillTargetCount - _autoQueue.length).clamp(
      1,
      refillTargetCount,
    );
    final seedKey = '${seed.providerId}:${seed.trackId}';

    final rawCandidates = <TrackMetadata>[];
    var fellBackFromPrimary = false;
    final seedProvider = providerLookup(seed.providerId);

    // 1. Native provider track radio when supported & eligible.
    if (seed.providerId == 'local' ||
        seedProvider == null ||
        !seedProvider.capabilities.supportsTrackRadio ||
        !_isProviderEligibleForRadio(seed.providerId)) {
      fellBackFromPrimary = true;
    } else {
      for (var pageIdx = 0; pageIdx < _maxEmptyPageRetries; pageIdx++) {
        if (isStale()) return;
        final cursor = _radioCursors[seedKey];
        try {
          final page = await seedProvider.getTrackRadio(
            seed,
            limit: needed + 4,
            cursor: cursor,
            cancel: cancel,
          );
          if (isStale()) return;
          if (page.nextCursor != null && page.nextCursor!.isNotEmpty) {
            _radioCursors[seedKey] = page.nextCursor;
          }
          if (page.tracks.isEmpty) {
            if (pageIdx == 0) {
              fellBackFromPrimary = true;
            }
            break;
          }
          rawCandidates.addAll(page.tracks);

          final preCheck = filter.filterCandidates(
            candidates: rawCandidates,
            seed: seed,
            activeQueueTail: _buildActiveQueueTail(),
            now: _clock(),
            limit: needed,
          );
          if (preCheck.length >= needed ||
              page.nextCursor == null ||
              page.nextCursor!.isEmpty) {
            break;
          }
        } catch (e) {
          if (_isCancellation(e, cancel) || isStale()) return;
          fellBackFromPrimary = true;
          break;
        }
      }
    }

    if (isStale()) return;

    var usablePreCheck = filter.filterCandidates(
      candidates: rawCandidates,
      seed: seed,
      activeQueueTail: _buildActiveQueueTail(),
      now: _clock(),
      limit: needed,
    );

    // 2. External metadata providers (e.g. Last.fm / ListenBrainz) when seed is
    //    local, primary fell back (e.g. Qobuz 401/disconnected), or short.
    if (seed.providerId == 'local' ||
        fellBackFromPrimary ||
        usablePreCheck.length < needed) {
      for (final ext in _effectiveExternalProviders) {
        if (isStale()) return;
        if (!ext.capabilities.supportsTrackRadio) continue;
        final extKey = '${ext.recommendationProviderId}:$seedKey';
        try {
          final page = await ext.getTrackRadio(
            seed,
            limit: needed + 4,
            cursor: _radioCursors[extKey],
            cancel: cancel,
          );
          if (isStale()) return;
          if (page.nextCursor != null && page.nextCursor!.isNotEmpty) {
            _radioCursors[extKey] = page.nextCursor;
          }
          rawCandidates.addAll(page.tracks);
        } catch (e) {
          if (_isCancellation(e, cancel) || isStale()) return;
        }
      }

      usablePreCheck = filter.filterCandidates(
        candidates: rawCandidates,
        seed: seed,
        activeQueueTail: _buildActiveQueueTail(),
        now: _clock(),
        limit: needed,
      );

      // 2b. Guest YouTube Music radio fallback if still short.
      if (usablePreCheck.length < needed && seed.providerId != 'youtube_music') {
        final ytm = providerLookup('youtube_music');
        if (ytm != null && ytm.capabilities.supportsTrackRadio) {
          final ytmKey = 'youtube_music:$seedKey';
          try {
            final page = await ytm.getTrackRadio(
              seed,
              limit: needed + 4,
              cursor: _radioCursors[ytmKey],
              cancel: cancel,
            );
            if (isStale()) return;
            if (page.nextCursor != null && page.nextCursor!.isNotEmpty) {
              _radioCursors[ytmKey] = page.nextCursor;
            }
            rawCandidates.addAll(page.tracks);
          } catch (e) {
            if (_isCancellation(e, cancel) || isStale()) return;
          }
        }
      }
    }

    if (isStale()) return;
    if (rawCandidates.isEmpty) return;

    // Pre-filter before cross-platform routing to avoid redundant lookups for
    // duplicates, variants, or quick-skipped artists.
    final preFiltered = filter.filterCandidates(
      candidates: rawCandidates,
      seed: seed,
      activeQueueTail: _buildActiveQueueTail(),
      now: _clock(),
      limit: needed + 6,
    );
    if (preFiltered.isEmpty || isStale()) return;

    final routed = <TrackMetadata>[];
    final router = trackRouter;
    for (final candidate in preFiltered) {
      if (isStale()) return;
      if (routed.length >= needed + 2) break;
      if (router != null) {
        try {
          final resolved = await router.resolveBestPlayableTrack(
            candidate,
            crossPlatformEnabled: crossPlatformEnabled,
            cancel: cancel,
          );
          if (isStale()) return;
          if (resolved != null) {
            routed.add(resolved);
          }
        } catch (e) {
          if (_isCancellation(e, cancel) || isStale()) return;
        }
      } else if (CrossPlatformTrackRouter.isPlayableProviderId(
        candidate.providerId,
      )) {
        routed.add(candidate);
      }
    }

    if (isStale() || routed.isEmpty) return;

    // Re-verify 3-layer dedup & artist cooldown after async routing because
    // metadata-only hits now carry resolved provider IDs and ISRCs, and
    // recentHistory / queues may have changed while routing was in flight.
    final finalCandidates = filter.filterCandidates(
      candidates: routed,
      seed: seed,
      activeQueueTail: _buildActiveQueueTail(),
      now: _clock(),
      limit: needed,
    );
    if (isStale() || finalCandidates.isEmpty) return;

    _autoQueue.addAll(finalCandidates.map((m) => m.toTrackInfo()));
    _emitChange();
  }

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
