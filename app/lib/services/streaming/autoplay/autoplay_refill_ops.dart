part of '../autoplay_controller.dart';

extension _AutoplayRefillOps on AutoplayController {
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

  Future<void> _maybeTriggerRefillImpl({TrackMetadata? seedOverride}) {
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

    TrackInfo? nonBannedUserFallback() {
      for (var i = _userQueue.length - 1; i >= 0; i--) {
        if (_userQueue[i].preference != -1) return _userQueue[i];
      }
      return null;
    }

    final TrackMetadata? fallbackSeed = seedOverride ??
        (_currentTrack != null && _currentTrack!.preference != -1
            ? TrackMetadata.fromTrackInfo(_currentTrack!)
            : (() {
                final fb = nonBannedUserFallback();
                return fb != null ? TrackMetadata.fromTrackInfo(fb) : null;
              })());

    final seed = filter.seedPool.nextSeedForRefill(fallbackSeed: fallbackSeed);
    if (seed == null || filter.isTrackBanned(seed)) return;

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
      for (var pageIdx = 0; pageIdx < AutoplayController._maxEmptyPageRetries; pageIdx++) {
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
}
