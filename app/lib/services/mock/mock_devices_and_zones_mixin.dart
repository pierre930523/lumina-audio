part of '../mock_audio_service.dart';

mixin _MockDevicesAndZonesMixin on _MockAudioServiceBase {
  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    _tracker.syncActiveFromDevices(_devices);
    return _devices;
  }

  @override
  String? get activeDeviceId => _tracker.activeDeviceId;

  @override
  bool get isSystemOutputActive => _systemOutputActive;

  @override
  String? get lastError => _lastError;

  @override
  int get preferredBufferFrames => _preferredBufferFrames;

  @override
  Future<bool> setBufferFrames(int frames) async {
    _preferredBufferFrames = frames.clamp(32, 32768);
    return true;
  }

  @override
  Map<String, PlaybackState> get devicePlaybackStates =>
      _tracker.snapshotDevices(_state);

  @override
  Map<String, PlaybackState> get zonePlaybackStates =>
      _tracker.snapshotZones(activeLocalState: _state);

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) async {
    if (deviceId == activeDeviceId) {
      await setVolume(volume);
      return;
    }
    _tracker.setDeviceVolume(deviceId, volume);
  }

  @override
  Future<void> toggleDevicePlayPause(String deviceId) async {
    if (deviceId == activeDeviceId) {
      await togglePlayPause();
      return;
    }
    await selectAudioDevice(deviceId);
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else {
      await play(track: _state.track ?? _queue.firstOrNull);
    }
  }

  @override
  Future<void> toggleZonePlayPause(String zoneId) async {
    final z = _zones.where((item) => item.id == zoneId).firstOrNull;
    final zoneState = zonePlaybackStates[zoneId];
    final isPlaying = zoneState?.status == PlaybackStatus.playing;
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
    final trimmed = deviceId?.trim();
    if (trimmed == null ||
        trimmed.isEmpty ||
        trimmed == AudioService.systemOutputId) {
      _lastError = null;
      _systemOutputActive = true;
      return;
    }
    _systemOutputActive = false;
    _lastError = null;
    final result = _tracker.switchDevice(
      nextDeviceId: trimmed,
      currentState: _state,
      currentQueueIndex: _currentIndex,
    );
    if (result.switched) {
      _currentIndex = result.queueIndex.clamp(
        0,
        _queue.isEmpty ? 0 : _queue.length - 1,
      );
      _emitState(result.restoredState);
    }
    for (var i = 0; i < _devices.length; i++) {
      final d = _devices[i];
      _devices[i] = AudioDeviceInfo(
        id: d.id,
        name: d.name,
        backend: d.backend,
        isDefault: d.id == trimmed,
        isExclusive: d.isExclusive,
        supportedSampleRates: d.supportedSampleRates,
      );
    }
  }

  @override
  Future<List<AudioZoneInfo>> listZones() async {
    _tracker.syncZones(_zones, activeLocalState: _state);
    return List.unmodifiable(_zones);
  }

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) async {
    if (!_zones.any((z) => z.backend == 'network_airplay')) {
      _zones.add(
        const AudioZoneInfo(
          id: 'airplay-bedroom',
          name: 'Bedroom AirPlay Receiver',
          backend: 'network_airplay',
          volume: 0.6,
          clockOffsetUs: -420,
          rttUs: 610,
          driftPpm: -0.8,
        ),
      );
    }
    _tracker.syncZones(_zones, activeLocalState: _state);
    return List.unmodifiable(_zones);
  }

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) async {
    for (var i = 0; i < _zones.length; i++) {
      final z = _zones[i];
      if (zoneIds.contains(z.id)) {
        _zones[i] = AudioZoneInfo(
          id: z.id,
          name: z.name,
          backend: z.backend,
          groupId: groupId,
          volume: z.volume,
          isActive: z.isActive,
          clockOffsetUs: z.clockOffsetUs,
          rttUs: z.rttUs,
          driftPpm: z.driftPpm,
        );
      }
    }
  }

  @override
  Future<void> setZoneVolume(String zoneId, double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    for (var i = 0; i < _zones.length; i++) {
      final z = _zones[i];
      if (z.id == zoneId) {
        _zones[i] = AudioZoneInfo(
          id: z.id,
          name: z.name,
          backend: z.backend,
          groupId: z.groupId,
          volume: clamped,
          isActive: z.isActive,
          clockOffsetUs: z.clockOffsetUs,
          rttUs: z.rttUs,
          driftPpm: z.driftPpm,
        );
      }
    }
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
    return ClockSyncMeasurementModel(
      zoneId: zoneId,
      offsetUs: 120,
      rttUs: 450,
      driftPpm: 0.4,
      sampleCount: 5,
    );
  }

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) async {
    _tracker.updateZoneAction(
      zoneId,
      action,
      track: _state.track ?? _queue.firstOrNull,
    );
    return {
      'zone_id': zoneId,
      'action': action,
      'status': 'ok',
    };
  }

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async {
    final devs = await listAudioDevices();
    return devs.map((d) {
      final isAsio = d.backend == 'windows_asio';
      final isShared = d.backend == 'windows_wasapi_shared';
      final isExcl = d.backend == 'windows_wasapi_exclusive' ||
          d.backend == 'mobile_direct' ||
          d.isExclusive;
      final modes = <String>[
        if (isAsio) ...[
          'asio_pcm',
          'asio_native_dsd',
          'dop_over_asio',
        ] else if (isShared) ...[
          'wasapi_shared',
          'dsd_to_pcm',
        ] else ...[
          'wasapi_exclusive',
          if (d.supportedSampleRates.contains(176400) ||
              d.supportedSampleRates.contains(192000))
            'dop_over_wasapi_exclusive',
        ],
      ];
      return AudioDeviceCapabilitiesModel(
        deviceId: d.id,
        name: d.name,
        backend: d.backend,
        transport: isAsio ? 'asio' : (isShared ? 'speakers' : 'usb_dac'),
        isDefault: d.isDefault,
        isOsDefault: d.isDefault,
        isExclusive: !isShared && d.isExclusive,
        hardwareSupportsExclusive: isExcl,
        supportedSampleRates: d.supportedSampleRates,
        supportedBitDepths: isShared ? const [32] : const [16, 24, 32],
        supportedContainerBits: isShared ? const [32] : const [16, 24, 32],
        supportedChannels: const [2],
        supportedOutputModes: modes,
        supportsNativeDsd: isAsio,
        supportsDop: !isShared && d.isExclusive,
        supportsFloat32: isShared || isAsio,
        asioAvailable: isAsio,
        exclusiveAvailable: !isShared && d.isExclusive,
        bufferSizeSupported: !isShared,
        minBufferFrames: isShared ? null : 64,
        maxBufferFrames: isShared ? null : 2048,
        defaultBufferFrames: isShared ? null : 512,
      );
    }).toList();
  }

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async {
    final trk = _state.track;
    final fmt = trk?.format;
    final dev = (await listAudioDevices()).firstWhere(
      (d) => d.id == activeDeviceId,
      orElse: () => const AudioDeviceInfo(
        id: 'mock',
        name: 'Virtual DAC',
        backend: 'windows_wasapi_shared',
      ),
    );
    return AudioEngineOutputInfoModel(
      source: AudioSourceInfoModel(
        codec: fmt?.codec.displayName ?? 'FLAC',
        sampleRateHz: fmt?.sampleRateHz ?? 96000,
        bitDepth: fmt?.bitDepth ?? 24,
        channels: fmt?.channels ?? 2,
        channelLayout: (fmt?.channels ?? 2) == 1 ? 'Mono (1.0)' : 'Stereo (L/R)',
        sourceFormat: fmt?.label ?? 'FLAC 96 kHz / 24-bit',
        title: trk?.title,
        artist: trk?.artist,
        album: trk?.album,
      ),
      decoder: AudioDecoderInfoModel(
        decoderType: 'Mock UI Preview Decoder (未連結原生 Rust 引擎)',
        decodedPcmFormat: 'Preview Mode',
        sampleRateHz: fmt?.sampleRateHz ?? 96000,
        containerBits: fmt?.bitDepth ?? 24,
        validBits: fmt?.bitDepth ?? 24,
        integerPreserved: _strictBitPerfect,
      ),
      output: AudioOutputInfoModel(
        selectedDevice: dev.name,
        transportKind: dev.backend == 'windows_asio' ? 'ASIO 驅動' : '虛擬預覽',
        audioApi: dev.backend,
        outputMode: dev.backend == 'windows_wasapi_shared'
            ? 'WASAPI Shared'
            : (_strictBitPerfect ? 'Strict Mode (Preview)' : 'Mock Output'),
        sampleRateHz: fmt?.sampleRateHz ?? 96000,
        containerBits: 32,
        validBits: fmt?.bitDepth ?? 24,
        channels: fmt?.channels ?? 2,
        bufferSizeFrames: _preferredBufferFrames,
        dspStatus: _dspBypassed ? 'Bypassed' : 'Enabled',
        softwareVolumeStatus: _strictBitPerfect
            ? 'Disabled (Unity 1.0x)'
            : (_state.volume == 1.0 ? 'Unity (1.0x)' : 'Active Attenuated'),
        strictMode: dev.backend != 'windows_wasapi_shared' && _strictBitPerfect,
        hardwareVolumeRecommended:
            dev.backend != 'windows_wasapi_shared' && _strictBitPerfect,
        degradationReason: '目前為預覽模式（MockService），未進行原生硬體樣本驗證',
      ),
      verification: const AudioVerificationInfoModel(
        pcmSampleCheck: 'Not Active (Preview Service)',
        sampleHashMatch: false,
        formatMatch: false,
        outputPath: 'Preview (Unverified)',
        verificationLevel: 'Mock Preview Only — Native FFI Engine Not Loaded',
        status: 'NOT VERIFIED',
      ),
    );
  }
}
