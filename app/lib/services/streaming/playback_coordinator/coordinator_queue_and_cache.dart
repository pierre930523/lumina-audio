part of '../streaming_playback_coordinator.dart';

extension _CoordinatorQueueAndCacheExt on StreamingPlaybackCoordinator {
  void _setQueueContextInternal(
    List<TrackInfo>? queueContext, {
    TrackInfo? currentTrack,
    int? queueIndex,
    bool resetLookaheadOnChange = true,
    required bool syncAutoplayCurrentTrack,
  }) {
    final ap = autoplayController;
    if (ap != null) {
      if (queueContext != null && queueContext.isNotEmpty) {
        final matchesCombined = _listsHaveSameIds(
          queueContext,
          ap.combinedQueue,
        );
        if (matchesCombined) {
          final combined = ap.combinedQueue;
          _sharedQueue
            ..clear()
            ..addAll(combined);
          if (queueIndex != null &&
              queueIndex >= 0 &&
              queueIndex < _sharedQueue.length) {
            _sharedQueueIndex = queueIndex;
          } else if (currentTrack != null) {
            _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
              _sharedQueue,
              currentTrack,
            );
          } else {
            _sharedQueueIndex = -1;
          }
          if (syncAutoplayCurrentTrack &&
              currentTrack != null &&
              ap.currentTrack?.id != currentTrack.id) {
            ap.advanceToTrack(currentTrack);
          }
          return;
        }

        final userQueueChanged = !_listsHaveSameIds(queueContext, ap.userQueue);
        if (userQueueChanged || syncAutoplayCurrentTrack) {
          ap.setUserQueue(
            queueContext,
            currentTrack: currentTrack,
            currentIndex: queueIndex,
            bumpEpoch: userQueueChanged,
          );
        } else if (currentTrack != null && ap.currentTrack == null) {
          ap.setUserQueue(
            queueContext,
            currentTrack: currentTrack,
            currentIndex: queueIndex,
            bumpEpoch: false,
          );
        }

        final combined = ap.combinedQueue;
        _sharedQueue
          ..clear()
          ..addAll(combined);
        if (currentTrack != null) {
          _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
            _sharedQueue,
            currentTrack,
          );
        } else if (queueIndex != null &&
            queueIndex >= 0 &&
            queueIndex < _sharedQueue.length) {
          _sharedQueueIndex = queueIndex;
        } else {
          _sharedQueueIndex = -1;
        }
        if (userQueueChanged && resetLookaheadOnChange) {
          _cancelStablePlayTimer();
          _resetLookaheadCompleted();
          _cancelLookaheadPrefetch();
          _clearStandbyTracking();
          _syncStablePlayTimer(currentState);
        }
        if (ap.needsRefill) {
          unawaited(ap.maybeTriggerRefill());
        }
        return;
      }

      if (currentTrack != null) {
        if (PlaybackPersistenceService.findTrackIndex(
              ap.combinedQueue,
              currentTrack,
            ) >=
            0) {
          final combined = ap.combinedQueue;
          _sharedQueue
            ..clear()
            ..addAll(combined);
          _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
            _sharedQueue,
            currentTrack,
          );
          if (syncAutoplayCurrentTrack &&
              ap.currentTrack?.id != currentTrack.id) {
            ap.advanceToTrack(currentTrack);
          }
          return;
        }

        if (audioService.queue.isNotEmpty &&
            PlaybackPersistenceService.findTrackIndex(
                  audioService.queue,
                  currentTrack,
                ) >=
                0) {
          ap.setUserQueue(
            audioService.queue,
            currentTrack: currentTrack,
            bumpEpoch: true,
          );
        } else {
          ap.setUserQueue(
            <TrackInfo>[currentTrack],
            currentTrack: currentTrack,
            currentIndex: 0,
            bumpEpoch: true,
          );
        }
        _sharedQueue
          ..clear()
          ..addAll(ap.combinedQueue);
        _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
        if (ap.needsRefill) {
          unawaited(ap.maybeTriggerRefill());
        }
        return;
      }
      return;
    }

    if (queueContext != null && queueContext.isNotEmpty) {
      var queueChanged = _sharedQueue.length != queueContext.length;
      if (!queueChanged) {
        for (var i = 0; i < queueContext.length; i++) {
          if (_sharedQueue[i].id != queueContext[i].id) {
            queueChanged = true;
            break;
          }
        }
      }
      _sharedQueue
        ..clear()
        ..addAll(queueContext);
      if (queueIndex != null &&
          queueIndex >= 0 &&
          queueIndex < _sharedQueue.length) {
        _sharedQueueIndex = queueIndex;
      } else if (currentTrack != null) {
        _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
      } else {
        _sharedQueueIndex = -1;
      }
      if (queueChanged && resetLookaheadOnChange) {
        _cancelStablePlayTimer();
        _resetLookaheadCompleted();
        _cancelLookaheadPrefetch();
        _clearStandbyTracking();
        _syncStablePlayTimer(currentState);
      }
      return;
    }

    if (currentTrack != null) {
      if (_sharedQueue.isNotEmpty) {
        final idx = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
        if (idx >= 0) {
          _sharedQueueIndex = idx;
          return;
        }
      }
      if (audioService.queue.isNotEmpty &&
          PlaybackPersistenceService.findTrackIndex(
                audioService.queue,
                currentTrack,
              ) >=
              0) {
        _sharedQueue
          ..clear()
          ..addAll(audioService.queue);
        _sharedQueueIndex = PlaybackPersistenceService.findTrackIndex(
          _sharedQueue,
          currentTrack,
        );
        return;
      }
      if (_sharedQueue.isNotEmpty) {
        _sharedQueue
          ..clear()
          ..add(currentTrack);
        _sharedQueueIndex = 0;
      }
    }
  }

  void _clearSharedQueueImpl() {
    autoplayController?.clearAll();
    _sharedQueue.clear();
    _sharedQueueIndex = -1;
    _lastActivePlayingTrack = null;
    _lastTransitionTrack = null;
    _pendingSwapZeroPosTrack = null;
    _handledEndedTrackId = null;
    _handledEndedEpoch = -1;
    _pausedPendingTrack = null;
    _suppressStoppedAtEpoch = -1;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    _clearStandbyTracking();
    if (!_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(const <TrackInfo>[]);
    }
  }

  void _clearStandbyTracking({bool clearPrepared = true}) {
    _attemptedStandbyTrackId = null;
    _attemptedStandbyEpoch = -1;
    if (clearPrepared) {
      _preparedStandbyTrackId = null;
      _preparedStandbyEpoch = -1;
      _preparedStandbySpec = null;
      _preparedExternalHandoffTrackId = null;
      _preparedExternalHandoffEpoch = -1;
    }
  }

  void _cancelStablePlayTimer() {
    _stablePlayTimer?.cancel();
    _stablePlayTimer = null;
    _stablePlayTrackId = null;
    _stablePlayEpoch = -1;
  }

  void _resetLookaheadCompleted() {
    _lookaheadCompletedTrackId = null;
    _lookaheadCompletedEpoch = -1;
  }

  void _cancelLookaheadPrefetch() {
    _lookaheadCancelToken?.cancel();
    _lookaheadCancelToken = null;
    _inFlightLookaheadKey = null;
  }

  void _cancelHoverPrefetch() {
    _hoverCancelToken?.cancel();
    _hoverCancelToken = null;
    _inFlightHoverKey = null;
  }

  void _cancelAllPreResolves() {
    for (final entry in _preResolveCancelTokens.values) {
      entry.token.cancel();
    }
    _preResolveCancelTokens.clear();
  }

  void _cancelPrefetchForProviderImpl(String providerId) {
    if (_inFlightLookaheadKey?.providerId == providerId) {
      _cancelLookaheadPrefetch();
    }
    if (_inFlightHoverKey?.providerId == providerId) {
      _cancelHoverPrefetch();
    }
    final matchingPreResolves = _preResolveCancelTokens.entries
        .where((e) => e.value.providerId == providerId)
        .toList(growable: false);
    for (final entry in matchingPreResolves) {
      entry.value.token.cancel();
      _preResolveCancelTokens.remove(entry.key);
      _inFlightPreResolves.remove(entry.key);
    }
    _specCache.removeWhere((k, _) => k.providerId == providerId);
    if (_preparedStandbySpec?.key.providerId == providerId ||
        (_preparedExternalHandoffTrackId != null &&
            providerId == 'apple_music')) {
      _clearStandbyTracking();
    }
    if (_useCustomResolverRegistry) {
      _singleFlight.cancelProvider(providerId);
      _l1Cache.clearProvider(providerId);
    }
  }

  void _cancelPendingWork() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_pendingDebounceCompleter != null &&
        !_pendingDebounceCompleter!.isCompleted) {
      _pendingDebounceCompleter!.complete();
    }
    _pendingDebounceCompleter = null;
    _activeCancelToken?.cancel();
    _activeCancelToken = null;
    _cancelStablePlayTimer();
    _resetLookaheadCompleted();
    _cancelLookaheadPrefetch();
    _cancelHoverPrefetch();
    _cancelAllPreResolves();
  }

  ResolvedStreamResult? _getCachedStreamImpl(String trackId) {
    if (_useResolverPipeline) {
      final now = _clock();
      StreamKey? matchKey;
      _CachedSpecEntry? matchEntry;
      for (final entry in _specCache.entries) {
        if (entry.value.trackId == trackId ||
            entry.key.trackId == trackId) {
          matchKey = entry.key;
          matchEntry = entry.value;
          break;
        }
      }
      if (matchKey != null && matchEntry != null) {
        if (!now.isBefore(matchEntry.expiresAt)) {
          _specCache.remove(matchKey);
          return null;
        }
        return _toResolvedResultForCache(matchEntry.spec);
      }

      try {
        final probe = TrackInfo(
          id: trackId,
          title: '',
          artist: '',
          album: '',
          duration: Duration.zero,
          format: const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
        );
        final key = _resolverRegistry.deriveKey(probe);
        if (_usesLegacyCoordinatorSpecCache(key)) return null;
        final cached = _singleFlight.peekCached(key);
        if (cached != null) {
          return _toResolvedResultForCache(cached);
        }
      } catch (_) {}
      return null;
    }

    final entry = _cache[trackId];
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) {
      _cache.remove(trackId);
      return null;
    }
    return entry.result;
  }

  void _storeCache(TrackInfo track, ResolvedStreamResult result) {
    if (_isLocalhostProxyUrl(result.url)) return;
    final now = _clock();
    final ttl = StreamingPlaybackCoordinator.computeCacheTtl(
      track,
      result.url,
      now,
    );
    if (ttl <= Duration.zero) return;

    if (!_cache.containsKey(track.id) &&
        _cache.length >= StreamingPlaybackCoordinator._maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[track.id] = _CachedResolvedStream(
      result: result,
      expiresAt: now.add(ttl),
    );
  }

  StreamSourceSpec? _getCachedSpec(StreamKey key) {
    final entry = _specCache[key];
    if (entry == null) return null;
    if (!_clock().isBefore(entry.expiresAt)) {
      _specCache.remove(key);
      return null;
    }
    return entry.spec;
  }

  void _storeSpecCache(TrackInfo track, StreamSourceSpec spec) {
    final resolver = _resolverRegistry.resolverFor(spec.key.providerId);
    final caps = resolver?.capabilities;
    if (caps == null || !caps.supportsL1UrlCache) return;

    final now = _clock();
    final Duration ttl;
    if (resolver is LegacyStreamingProviderResolver &&
        spec is DirectRangeSpec) {
      ttl = StreamingPlaybackCoordinator.computeCacheTtl(track, spec.url, now);
    } else {
      final url = switch (spec) {
        DirectRangeSpec() => spec.url,
        EncryptedRangeSpec() => spec.url,
        _ => null,
      };
      if (url != null && _isLocalhostProxyUrl(url)) return;

      final int? expireAt = switch (spec) {
        DirectRangeSpec() => spec.expireAt,
        SegmentedManifestSpec() => spec.expireAt,
        EncryptedRangeSpec() => spec.expireAt,
        _ => null,
      };
      if (expireAt != null && expireAt > 0) {
        final expireDt = DateTime.fromMillisecondsSinceEpoch(expireAt * 1000);
        final usable =
            expireDt.difference(now) -
            Duration(seconds: caps.defaultL1SafetyMarginSec);
        ttl = usable > const Duration(seconds: 5) ? usable : Duration.zero;
      } else {
        ttl = const Duration(minutes: 10);
      }
    }

    if (ttl <= Duration.zero) return;

    if (!_specCache.containsKey(spec.key) &&
        _specCache.length >= StreamingPlaybackCoordinator._maxCacheEntries) {
      _specCache.remove(_specCache.keys.first);
    }
    _specCache[spec.key] = _CachedSpecEntry(
      trackId: track.id,
      spec: spec,
      expiresAt: now.add(ttl),
    );
  }

  StreamKey? _tryDeriveKey(TrackInfo track) {
    try {
      return _resolverRegistry.deriveKey(track);
    } catch (_) {
      return null;
    }
  }

  bool _usesLegacyCoordinatorSpecCache(StreamKey key) {
    if (!_hasCustomClock || _useCustomResolverRegistry) return false;
    final resolver = _resolverRegistry.resolverFor(key.providerId);
    return resolver is LegacyStreamingProviderResolver;
  }

  StreamSourceSpec? _peekCachedSpec(StreamKey key) {
    if (_usesLegacyCoordinatorSpecCache(key)) {
      return _getCachedSpec(key);
    }
    return _singleFlight.peekCached(key);
  }

  void _evictSpecCacheForTrack(TrackInfo track) {
    final key = _tryDeriveKey(track);
    if (key != null) {
      _specCache.remove(key);
      _l1Cache.evict(key);
      _l1Cache.evictTrack(key.providerId, key.trackId);
    }
    _specCache.removeWhere(
      (k, v) => v.trackId == track.id || k.trackId == track.id,
    );
  }
}
