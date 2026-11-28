part of '../ffi_audio_service.dart';

mixin _FfiStateSyncMixin on _FfiAudioServiceBase {
  @override
  Future<void> prepareStandbySpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    int? epoch,
  }) async {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter FfiAudioService',
      );
    }
    final effectiveEpoch = epoch ?? _activeEpoch;
    if (effectiveEpoch < _activeEpoch) return;

    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.prepareStandbySpecAsync(
        track,
        spec,
        epoch: effectiveEpoch,
      );
      return;
    }
    _pendingStandbyTrack = track;
    _rememberStandbyTrack(track);
    if (!isNativeBound) {
      await _delegate.prepareStandbySpecAsync(
        track,
        spec,
        epoch: effectiveEpoch,
      );
      return;
    }
    final prepareFn = _playbackPrepareStandbyAsyncFn;
    if (prepareFn == null) {
      return;
    }
    final resolvedFields = _ffiLegacyFieldsForSpec(spec);
    final payload = _ffiEncodeTrackPayload(
      track,
      streamUrl: resolvedFields.streamUrl,
      filePathOverride: resolvedFields.filePath,
      headers: resolvedFields.headers,
      hintExtension: resolvedFields.hintExtension,
      sourceSpec: spec,
      epoch: effectiveEpoch,
    );
    final rc = _withNativeUtf8(
      payload,
      (p) => prepareFn(p, effectiveEpoch),
    );
    if (rc != 0) {
      _pendingStandbyTrack = null;
      _standbyTracksById.remove(track.id);
    }
  }

  @override
  Future<bool> skipToStandby({int? epoch}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.skipToStandby(epoch: epoch);
    }
    if (!isNativeBound) {
      return _delegate.skipToStandby(epoch: epoch);
    }
    final skipAtEpochFn = _playbackSkipToStandbyAtEpochFn;
    final skipFn = _playbackSkipToStandbyFn;
    if (skipAtEpochFn == null && skipFn == null) return false;
    final requestedEpoch = (epoch != null && epoch > 0) ? epoch : _activeEpoch;
    final rc = skipAtEpochFn != null
        ? skipAtEpochFn(requestedEpoch)
        : skipFn!();
    if (rc == 1) {
      if (requestedEpoch > _activeEpoch) {
        _activeEpoch = requestedEpoch;
        _activeRequestId = requestedEpoch;
      }
      _lastError = null;
      _needsLoadOnResume = false;
      _pendingResumePosition = null;
      if (_playbackGetStateJsonFn != null) {
        final raw = _takeRustString(_playbackGetStateJsonFn!());
        if (raw != null) {
          try {
            final map = jsonDecode(raw) as Map<String, dynamic>;
            if (skipAtEpochFn == null) {
              // Legacy fallback: adopt Rust's epoch & play_request_id so polling isn't stranded.
              final rustEpoch = PlaybackState.parsePlaybackEpoch(map);
              final rustReqId = (map['play_request_id'] as num?)?.toInt() ?? 0;
              if (rustEpoch > 0) _activeEpoch = rustEpoch;
              if (rustReqId > 0) _activeRequestId = rustReqId;
            }
            _applyNativeStateJson(map);
          } catch (_) {}
        }
      }
      _refreshSignalPath();
      _startPositionTimer();
      return true;
    }
    if (rc < 0 && _lastErrorMsgFn != null) {
      final errMsg = _takeRustString(_lastErrorMsgFn!());
      if (errMsg != null && errMsg.isNotEmpty) {
        _lastError = errMsg;
      }
    }
    return false;
  }

  TrackInfo? _findMatchingTrackCandidate(
    String? reportedId,
    String? reportedProviderId,
  ) {
    if (reportedId == null || reportedId.isEmpty) return null;
    if (_pendingStandbyTrack != null &&
        _ffiTracksReferToSame(
          _pendingStandbyTrack,
          reportedId,
          reportedProviderId,
        )) {
      return _pendingStandbyTrack;
    }
    final directStandby = _standbyTracksById[reportedId];
    if (directStandby != null) return directStandby;
    for (final candidate in _standbyTracksById.values) {
      if (_ffiTracksReferToSame(candidate, reportedId, reportedProviderId)) {
        return candidate;
      }
    }
    for (final candidate in _queue) {
      if (_ffiTracksReferToSame(candidate, reportedId, reportedProviderId)) {
        return candidate;
      }
    }
    return null;
  }

  int _findTrackIndexInQueue(TrackInfo target) {
    final byExact = PlaybackPersistenceService.findTrackIndex(_queue, target);
    if (byExact >= 0) return byExact;
    final targetKey = target.responsiveArtworkKey;
    return _queue.indexWhere((t) => t.responsiveArtworkKey == targetKey);
  }

  @visibleForTesting
  bool processStateJsonForTest(Map<String, dynamic> json) =>
      _applyNativeStateJson(json);

  bool _applyNativeStateJson(Map<String, dynamic> json) {
    final stateCode = (json['state_code'] as num?)?.toInt() ?? 1;
    final posMs = (json['position_ms'] as num?)?.toInt() ?? 0;
    final durMs = (json['duration_ms'] as num?)?.toInt() ?? 0;
    final seekEpoch = (json['seek_epoch'] as num?)?.toInt() ?? _state.seekEpoch;
    final isSeeking = json['is_seeking'] == true;
    final deviceLost = json['device_lost'] == true;
    var lastErr = json['last_error']?.toString();
    final lastErrCode = json['last_error_code']?.toString().trim();
    final lastErrProvider = json['last_error_provider']?.toString().trim();
    final clockSrc = json['clock_source']?.toString() ?? _state.clockSource;
    final playReqId = (json['play_request_id'] as num?)?.toInt() ?? 0;
    final loadedReqId = (json['loaded_request_id'] as num?)?.toInt() ?? 0;
    final stateEpoch = PlaybackState.parsePlaybackEpoch(json);
    if (_activeEpoch > 0 && stateEpoch < _activeEpoch) {
      return false;
    }
    if (_activeRequestId > 0 &&
        playReqId > 0 &&
        playReqId != _activeRequestId) {
      return false;
    }
    final effectiveEpoch = stateEpoch > 0 ? stateEpoch : _activeEpoch;
    _updateDualDeckSnapshotFromJson(json);
    var status = PlaybackStatus.fromCode(stateCode);
    if (_activeRequestId > 0 && playReqId > loadedReqId) {
      status = PlaybackStatus.loading;
    }
    if (status == PlaybackStatus.error &&
        (lastErr == null || lastErr.trim().isEmpty) &&
        _lastErrorMsgFn != null) {
      final ffiErr = _takeRustString(_lastErrorMsgFn!());
      if (ffiErr != null && ffiErr.trim().isNotEmpty) {
        lastErr = ffiErr.trim();
      }
    }

    if (status == PlaybackStatus.error &&
        (lastErr == null || lastErr.trim().isEmpty) &&
        lastErrCode == 'AUTH_REQUIRED' &&
        lastErrProvider != null &&
        lastErrProvider.isNotEmpty) {
      lastErr = 'AUTH_REQUIRED: $lastErrProvider 授權已失效，請重新登入';
    }

    unawaited(
      handlePolledPlaybackStateError(
        status: status,
        lastErrorCode: lastErrCode,
        lastErrorProvider: lastErrProvider,
        lastError: lastErr,
        epoch: stateEpoch,
      ),
    );

    if (status == PlaybackStatus.stopped ||
        status == PlaybackStatus.error ||
        status == PlaybackStatus.paused) {
      if (_isReroutingDevice) return false;
      if (lastErr != null && lastErr.isNotEmpty) {
        _lastError = lastErr;
      }
      _positionTimer?.cancel();
    }

    final enteredPlaying =
        _state.status != PlaybackStatus.playing &&
        status == PlaybackStatus.playing;

    final swapGen =
        (json['swap_generation'] as num?)?.toInt() ??
        (json['swapGeneration'] as num?)?.toInt() ??
        _lastDualDeckSnapshot?.swapGeneration ??
        _state.swapGeneration;
    final rawTrackObj =
        json['current_track'] ??
        json['active_track'] ??
        _lastDualDeckSnapshot?.activeTrackJson;
    final currentTrackMap = rawTrackObj is Map
        ? Map<String, dynamic>.from(rawTrackObj)
        : null;
    final rawReportedId = json['current_track_id']?.toString().trim();
    final mapReportedId =
        _ffiNonEmptyString(currentTrackMap?['track_id']) ??
        _ffiNonEmptyString(currentTrackMap?['id']) ??
        _ffiNonEmptyString(currentTrackMap?['external_track_id']);
    final reportedTrackId =
        (rawReportedId != null && rawReportedId.isNotEmpty)
            ? rawReportedId
            : mapReportedId;
    final reportedProviderId =
        _ffiNonEmptyString(currentTrackMap?['provider_id']);

    final swapIncremented =
        swapGen > _lastObservedSwapGeneration && swapGen > 0;
    final trackIdChanged =
        reportedTrackId != null &&
        reportedTrackId.isNotEmpty &&
        !_ffiTracksReferToSame(
          _state.track,
          reportedTrackId,
          reportedProviderId,
        );
    final trackSwapped = swapIncremented || trackIdChanged;
    if (swapGen != _lastObservedSwapGeneration) {
      _lastObservedSwapGeneration = swapGen;
    }

    final jsonTrack = currentTrackMap != null
        ? _ffiTrackFromCurrentTrackMap(
            currentTrackMap,
            fallbackDurationMs: durMs,
          )
        : null;
    TrackInfo? updatedTrack;
    if (trackSwapped) {
      final matchedCandidate = _findMatchingTrackCandidate(
        reportedTrackId,
        reportedProviderId,
      );
      updatedTrack =
          _ffiMergeTrackInfo(
            matchedCandidate,
            jsonTrack,
            liveDurationMs: durMs,
          ) ??
          _ffiMergeTrackInfo(_state.track, null, liveDurationMs: durMs);
    } else {
      updatedTrack = _ffiMergeTrackInfo(
        _state.track,
        jsonTrack,
        liveDurationMs: durMs,
      );
    }

    if (trackSwapped && updatedTrack != null) {
      _pendingStandbyTrack = null;
      final qIdx = _findTrackIndexInQueue(updatedTrack);
      if (qIdx >= 0) {
        _currentIndex = qIdx;
        _queue[qIdx] = _ffiMergeTrackInfo(
          _queue[qIdx],
          updatedTrack,
          liveDurationMs: durMs,
        )!;
      }
      if (status == PlaybackStatus.playing) {
        _loadLyricsForTrack(updatedTrack);
        _refreshSignalPath();
      }
    } else if (enteredPlaying) {
      if (updatedTrack != null && _currentLyrics.isEmpty) {
        _loadLyricsForTrack(updatedTrack);
      }
      _refreshSignalPath();
    }

    _emitState(
      _state.copyWith(
        status: status,
        track: updatedTrack,
        position: Duration(milliseconds: posMs < 0 ? 0 : posMs),
        seekEpoch: seekEpoch,
        isSeeking: isSeeking,
        deviceLost: deviceLost,
        lastError: lastErr,
        clearLastError: lastErr == null || lastErr.isEmpty,
        clockSource: clockSrc,
        swapGeneration: swapGen,
        playbackEpoch: effectiveEpoch,
      ),
    );
    return true;
  }

  @override
  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!isNativeBound) {
        _positionTimer?.cancel();
        return;
      }
      if (_playbackGetStateJsonFn != null) {
        final raw = _takeRustString(_playbackGetStateJsonFn!());
        if (raw != null) {
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            _applyNativeStateJson(json);
          } catch (_) {}
        }
        return;
      }
      if (_activeEpoch > 0) {
        return;
      }

      final stateCode = _getStateFn!();
      final posMs = _getPositionFn!();
      final durMs = _getDurationFn!();
      final updatedTrack = _state.track != null && durMs > 0
          ? _state.track!.copyWith(duration: Duration(milliseconds: durMs))
          : _state.track;

      if (stateCode == 0 || stateCode == 1 || stateCode == 4 || stateCode == 2) {
        if (_isReroutingDevice) {
          return;
        }
        if (stateCode == 4 && _lastErrorMsgFn != null) {
          final errMsg = _takeRustString(_lastErrorMsgFn!());
          if (errMsg != null && errMsg.isNotEmpty) {
            _lastError = errMsg;
          }
        }
        _positionTimer?.cancel();
        _emitState(
          _state.copyWith(
            status: PlaybackStatus.fromCode(stateCode),
            track: updatedTrack,
            position: Duration(milliseconds: posMs),
            lastError: stateCode == 4 ? _lastError : null,
            clearLastError: stateCode != 4,
          ),
        );
      } else {
        _emitState(
          _state.copyWith(
            status: PlaybackStatus.fromCode(stateCode),
            track: updatedTrack,
            position: Duration(milliseconds: posMs),
          ),
        );
      }
    });
  }
}
