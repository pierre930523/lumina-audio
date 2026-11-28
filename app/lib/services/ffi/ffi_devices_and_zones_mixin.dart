part of '../ffi_audio_service.dart';

mixin _FfiDevicesAndZonesMixin on _FfiAudioServiceBase {
  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listAudioDevices();
    }
    if (!isNativeBound || _audioListDevicesFn == null) {
      return _delegate.listAudioDevices();
    }
    final raw = _takeRustString(_audioListDevicesFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final devs = decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioDeviceInfo.fromJson)
          .toList();
      _tracker.syncActiveFromDevices(devs);
      return devs;
    }
    return const [];
  }

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.setDeviceVolume(deviceId, volume);
      return;
    }
    if (!isNativeBound) {
      await _delegate.setDeviceVolume(deviceId, volume);
      return;
    }
    if (deviceId == activeDeviceId) {
      await setVolume(volume);
      return;
    }
    _tracker.setDeviceVolume(deviceId, volume);
  }

  @override
  Future<void> toggleDevicePlayPause(String deviceId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.toggleDevicePlayPause(deviceId);
      return;
    }
    if (!isNativeBound) {
      await _delegate.toggleDevicePlayPause(deviceId);
      return;
    }
    if (deviceId == activeDeviceId) {
      await togglePlayPause();
      return;
    }
    await selectAudioDevice(deviceId);
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else {
      final track = _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
      if (track != null) {
        await play(track: track);
      }
    }
  }

  @override
  Future<void> toggleZonePlayPause(String zoneId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.toggleZonePlayPause(zoneId);
      return;
    }
    if (!isNativeBound) {
      await _delegate.toggleZonePlayPause(zoneId);
      return;
    }
    final zones = await listZones();
    final z = zones.where((item) => item.id == zoneId).firstOrNull;
    final isPlaying =
        zonePlaybackStates[zoneId]?.status == PlaybackStatus.playing;
    if (z == null || !z.backend.startsWith('network_')) {
      await togglePlayPause();
      _tracker.updateZoneAction(
        zoneId,
        _state.status == PlaybackStatus.playing ? 'play' : 'pause',
        track: _state.track,
      );
      return;
    }
    await castToZone(zoneId, isPlaying ? 'pause' : 'play');
  }

  @override
  Future<void> selectAudioDevice(
    String? deviceId, {
    int backendIndex = -1,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.selectAudioDevice(
        deviceId,
        backendIndex: backendIndex,
      );
      return;
    }
    if (!isNativeBound || _audioSelectDeviceFn == null) {
      await _delegate.selectAudioDevice(deviceId, backendIndex: backendIndex);
      return;
    }

    final trimmed = deviceId?.trim();
    final selectingSystem =
        trimmed == null ||
        trimmed.isEmpty ||
        trimmed == AudioService.systemOutputId;
    final nativeId = selectingSystem ? '' : trimmed;

    _isReroutingDevice = true;
    try {
      final rc = _withNativeUtf8(
        nativeId,
        (p) => _audioSelectDeviceFn!(p, backendIndex),
      );
      if (rc != 0) {
        final errMsg = _lastErrorMsgFn != null
            ? _takeRustString(_lastErrorMsgFn!())
            : null;
        _lastError = (errMsg != null && errMsg.isNotEmpty)
            ? errMsg
            : 'Failed to select audio device (code $rc)';
        final rustState = _getStateFn?.call();
        if (rustState == 4) {
          _positionTimer?.cancel();
          _emitState(
            _state.copyWith(
              status: PlaybackStatus.error,
              lastError: _lastError,
            ),
          );
        }
      } else {
        _lastError = null;
        final prevStrict = _strictBitPerfect;
        final isSharedSelection =
            backendIndex == 2 || nativeId.startsWith('wasapi-shared::');
        if (isSharedSelection && _strictBitPerfect) {
          // Rust select_output_device already cleared strict_bit_perfect and restored
          // normal DSP/volume in a single RerouteOutput; sync Dart state without re-triggering.
          _strictBitPerfect = false;
        }
        final rustSnap = await getPlaybackState();
        final rustStrict = rustSnap?['strict_bit_perfect'] == true;
        final rustVol = (rustSnap?['volume'] as num?)?.toDouble();
        _strictBitPerfect = isSharedSelection ? false : rustStrict;

        if (selectingSystem) {
          _systemOutputActive = true;
          final devs = await listAudioDevices();
          final osDef =
              devs.where((d) => d.isDefault).firstOrNull ?? devs.firstOrNull;
          if (osDef != null) {
            _tracker.switchDevice(
              nextDeviceId: osDef.id,
              currentState: _state,
              currentQueueIndex: _currentIndex,
            );
            _tracker.updateActiveDeviceState(_state, queueIndex: _currentIndex);
          }
        } else {
          _systemOutputActive = false;
          if (_state.track == null) {
            final res = _tracker.switchDevice(
              nextDeviceId: nativeId,
              currentState: _state,
              currentQueueIndex: _currentIndex,
            );
            if (res.switched) {
              _currentIndex = res.queueIndex.clamp(
                0,
                _queue.isEmpty ? 0 : _queue.length - 1,
              );
              _pendingResumePosition = res.restoredState.position > Duration.zero
                  ? res.restoredState.position
                  : null;
              _needsLoadOnResume = res.restoredState.track != null &&
                  res.restoredState.status != PlaybackStatus.playing;
              final effVol =
                  (prevStrict && !_strictBitPerfect && rustVol != null)
                      ? rustVol
                      : res.restoredState.volume;
              _setVolumeFn?.call(
                res.restoredState.isMuted ? 0.0 : effVol,
              );
              _emitState(
                res.restoredState.copyWith(
                  volume: effVol,
                  isMuted: effVol == 0.0,
                ),
              );
            } else if (prevStrict && !_strictBitPerfect && rustVol != null) {
              _emitState(
                _state.copyWith(volume: rustVol, isMuted: rustVol == 0.0),
              );
            }
          } else {
            // Mid-playback reroute: Rust RerouteOutput kept the active track playing/paused
            // on the newly initialized backend. Keep UI synchronized with Rust engine state.
            _tracker.switchDevice(
              nextDeviceId: nativeId,
              currentState: _state,
              currentQueueIndex: _currentIndex,
            );
            final rustCode = _getStateFn?.call() ?? _state.status.code;
            final posMs =
                _getPositionFn?.call() ?? _state.position.inMilliseconds;
            final syncedStatus = _needsLoadOnResume
                ? PlaybackStatus.paused
                : PlaybackStatus.fromCode(rustCode);
            final syncedPos = _needsLoadOnResume
                ? (_pendingResumePosition ?? _state.position)
                : Duration(milliseconds: posMs);
            final effVol = rustVol ?? _state.volume;
            _emitState(
              _state.copyWith(
                status: syncedStatus,
                position: syncedPos,
                volume: effVol,
                isMuted: effVol == 0.0,
                deviceLost: false,
                lastError: null,
              ),
            );
            if (syncedStatus == PlaybackStatus.playing) {
              _startPositionTimer();
            } else {
              _positionTimer?.cancel();
            }
          }
        }
        _refreshSignalPath();
      }
    } finally {
      _isReroutingDevice = false;
    }
  }

  @override
  Future<List<AudioZoneInfo>> listZones() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listZones();
    }
    if (!isNativeBound || _zoneListFn == null) {
      return _delegate.listZones();
    }
    final raw = _takeRustString(_zoneListFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final zones = decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioZoneInfo.fromJson)
          .toList();
      _tracker.syncZones(zones, activeLocalState: _state);
      return zones;
    }
    return const [];
  }

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.discoverZones(
        ssdpAddr: ssdpAddr,
        airplayAddrs: airplayAddrs,
        clockSyncAddr: clockSyncAddr,
      );
    }
    if (!isNativeBound || _zoneDiscoverFn == null) {
      return _delegate.discoverZones(
        ssdpAddr: ssdpAddr,
        airplayAddrs: airplayAddrs,
        clockSyncAddr: clockSyncAddr,
      );
    }
    final raw = _takeRustString(_zoneDiscoverFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final zones = decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioZoneInfo.fromJson)
          .toList();
      _tracker.syncZones(zones, activeLocalState: _state);
      return zones;
    }
    return const [];
  }

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.groupZones(groupId, zoneIds);
      return;
    }
    if (!isNativeBound || _zoneGroupFn == null) {
      await _delegate.groupZones(groupId, zoneIds);
      return;
    }
    _withNativeUtf8(
      jsonEncode({'group_id': groupId, 'zone_ids': zoneIds}),
      (p) => _zoneGroupFn!(p),
    );
  }

  @override
  Future<void> setZoneVolume(String zoneId, double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.setZoneVolume(zoneId, clamped);
      return;
    }
    if (!isNativeBound || _zoneSetVolumeFn == null) {
      await _delegate.setZoneVolume(zoneId, clamped);
      return;
    }
    _withNativeUtf8(zoneId, (p) => _zoneSetVolumeFn!(p, clamped));
    _tracker.setZoneVolume(zoneId, clamped);
    if (zoneId == 'zone-local') {
      await setVolume(clamped);
    }
  }

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.syncZoneClock(zoneId, clockAddr: clockAddr);
    }
    if (!isNativeBound || _zoneSyncStatusFn == null) {
      return _delegate.syncZoneClock(zoneId, clockAddr: clockAddr);
    }
    final input = clockAddr == null
        ? zoneId
        : jsonEncode({'zone_id': zoneId, 'clock_addr': clockAddr});
    final raw = _withNativeUtf8(
      input,
      (p) => _takeRustString(_zoneSyncStatusFn!(p)),
    );
    if (raw == null) {
      return ClockSyncMeasurementModel(
        zoneId: zoneId,
        offsetUs: 0,
        rttUs: 0,
        driftPpm: 0.0,
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return ClockSyncMeasurementModel.fromJson(zoneId, decoded);
    }
    return ClockSyncMeasurementModel(
      zoneId: zoneId,
      offsetUs: 0,
      rttUs: 0,
      driftPpm: 0.0,
    );
  }

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.castToZone(zoneId, action, mediaUri: mediaUri);
    }
    _tracker.updateZoneAction(
      zoneId,
      action,
      track: _state.track ?? (_queue.isNotEmpty ? _queue.first : null),
    );
    return _delegate.castToZone(zoneId, action, mediaUri: mediaUri);
  }
}
