part of '../server_audio_service.dart';

mixin _ServerLibraryAndDevicesMixin on _ServerAudioServiceBase {
  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/albums?limit=$limit&include_hidden=$includeHidden',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(CanonicalAlbumSummary.fromJson)
          .where((a) => a.id.isNotEmpty && (a.trackCount == null || a.trackCount! > 0))
          .toList();
    }
    return const [];
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/albums/${Uri.encodeComponent(albumId)}',
    );
    if (code == 200 && data is Map<String, dynamic>) {
      final detail = CanonicalAlbumDetail.fromJson(data);
      final nonEmptyVersions = detail.versions
          .where((v) => v.tracks.isNotEmpty)
          .toList(growable: false);
      if (nonEmptyVersions.isEmpty) {
        return null;
      }
      if (nonEmptyVersions.length == detail.versions.length) {
        return detail;
      }
      return detail.copyWith(versions: nonEmptyVersions);
    }
    return null;
  }

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/artists/${Uri.encodeComponent(artistId)}',
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return ArtistDetailInfo.fromJson(data);
    }
    return null;
  }

  @override
  Future<int> deduplicateLibrary() async {
    final (code, data) =
        await _requestJson('POST', '/api/v1/library/deduplicate');
    if (code == 200 && data is Map) {
      return (data['merged_albums'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/enrich',
      body: {
        'musicbrainz_base_url': ?musicBrainzBaseUrl,
        'discogs_base_url': ?discogsBaseUrl,
      },
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return const {};
  }

  @override
  Future<DspPipelineConfigModel> getDspConfig() async {
    final (code, data) = await _requestJson('GET', '/api/v1/dsp/config');
    if (code == 200 && data is Map<String, dynamic>) {
      return DspPipelineConfigModel.fromJson(data);
    }
    return const DspPipelineConfigModel();
  }

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) async {
    await _requestJson('PUT', '/api/v1/dsp/config', body: config.toJson());
    await syncInitialState();
  }

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/dsp/autoeq',
      body: {'text': autoEqTxt, 'apply': true},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      final raw = data['peq_bands'] as List<dynamic>? ?? const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(PeqBandModel.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    final (code, data) = await _requestJson('GET', '/api/v1/audio/devices');
    if (code == 200 && data is List) {
      final devs = data
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
    final res = _tracker.switchDevice(
      nextDeviceId: deviceId,
      currentState: _state,
      currentQueueIndex: 0,
    );
    await _requestJson(
      'POST',
      '/api/v1/audio/devices/select',
      body: {'device_id': deviceId},
    );
    if (res.switched) {
      _state = res.restoredState;
      _tracker.updateActiveDeviceState(_state);
      if (!_stateController.isClosed) _stateController.add(_state);
    }
  }

  @override
  Future<List<AudioZoneInfo>> listZones() async {
    final (code, data) = await _requestJson('GET', '/api/v1/zones');
    if (code == 200 && data is List) {
      final zones = data
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
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/zones/discover',
      body: {
        'ssdp_addr': ?ssdpAddr,
        'airplay_addrs': ?airplayAddrs,
        'clock_sync_addr': ?clockSyncAddr,
      },
    );
    if (code == 200 && data is List) {
      final zones = data
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
    await _requestJson(
      'POST',
      '/api/v1/zones/group',
      body: {'group_id': groupId, 'zone_ids': zoneIds},
    );
  }

  @override
  Future<void> setZoneVolume(String zoneId, double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await _requestJson(
      'POST',
      '/api/v1/zones/${Uri.encodeComponent(zoneId)}/volume',
      body: {'volume': clamped},
    );
    _tracker.setZoneVolume(zoneId, clamped);
  }

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/zones/${Uri.encodeComponent(zoneId)}/sync',
      body: {'clock_addr': ?clockAddr},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return ClockSyncMeasurementModel.fromJson(zoneId, data);
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
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/zones/${Uri.encodeComponent(zoneId)}/cast',
      body: {'action': action, 'media_uri': ?mediaUri},
    );
    _tracker.updateZoneAction(
      zoneId,
      action,
      track: _state.track ?? _queue.firstOrNull,
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return const {};
  }
}
