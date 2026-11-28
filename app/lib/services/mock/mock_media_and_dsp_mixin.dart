part of '../mock_audio_service.dart';

mixin _MockMediaAndDspMixin on _MockAudioServiceBase {
  @override
  List<LyricLine> get currentLyrics {
    final trk = _state.track;
    if (trk == null) return const [];
    if (_userLyrics.containsKey(trk.id)) {
      return [
        LyricLine(
          start: Duration.zero,
          end: const Duration(seconds: 30),
          text: _userLyrics[trk.id]!,
        ),
      ];
    }
    if (trk.id == 'trk-001') {
      return _lyrics;
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    return {
      'state_code': _state.status.code,
      'state_name': _state.status.name,
      'position_ms': _state.position.inMilliseconds,
      'duration_ms': _state.track?.duration.inMilliseconds ?? 0,
      'clock_source': _state.clockSource,
      'seek_epoch': _state.seekEpoch,
      'is_seeking': _state.isSeeking,
      'dsp_bypassed': _dspBypassed,
      'strict_bit_perfect': _strictBitPerfect,
      'volume': _state.volume,
      'last_error': _state.lastError,
      'device_lost': _state.deviceLost,
      'current_track_id': _state.track?.id,
    };
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    if (_userCovers.containsKey(trackId)) {
      return {
        'found': true,
        'cache_path': _userCovers[trackId],
        'mime_type': 'image/jpeg',
        'source_kind': 'user',
        'width': maxDim,
        'height': maxDim,
      };
    }
    return {
      'found': false,
      'source_kind': 'placeholder',
      'cache_path': null,
    };
  }

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    _userCovers[trackId] = imagePath;
    return true;
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    _userCovers.remove(trackId);
    return true;
  }

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) async {
    return {
      'rescanned_count': _queue.length,
      'updated_count': _queue.length,
      'status': 'ok',
    };
  }

  @override
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  }) async {
    if (_userLyrics.containsKey(trackId)) {
      return {
        'found': true,
        'kind': 'synced',
        'source': 'user_file',
        'format': 'plain',
        'offset_ms': 0,
        'lines': [
          {
            'start_ms': 0,
            'end_ms': 30000,
            'text': _userLyrics[trackId]!,
            'words': [],
          },
        ],
      };
    }
    if (trackId == 'trk-001') {
      return {
        'found': true,
        'kind': 'synced',
        'source': 'embedded_synced',
        'format': 'enhanced_lrc',
        'offset_ms': 0,
        'lines': _lyrics
            .map(
              (l) => {
                'start_ms': l.start.inMilliseconds,
                'end_ms': l.end.inMilliseconds,
                'text': l.text,
                'words': l.words
                    .map(
                      (w) => {
                        'text': w.text,
                        'start_ms': w.start.inMilliseconds,
                        'end_ms': w.end.inMilliseconds,
                      },
                    )
                    .toList(),
              },
            )
            .toList(),
      };
    }
    return {
      'found': false,
      'kind': 'none',
      'source': 'none',
      'format': 'plain',
      'offset_ms': 0,
      'lines': [],
    };
  }

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) async {
    _userLyrics[trackId] = filePath;
    return true;
  }

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) async {
    _userLyrics.remove(trackId);
    return true;
  }

  @override
  Future<void> toggleDspBypass() async {
    if (_strictBitPerfect) {
      _dspBypassed = true;
      _emitSignalPath();
      return;
    }
    _forcedQuality = null;
    _dspBypassed = !_dspBypassed;
    _savedNormalBypass = _dspBypassed;
    _emitSignalPath();
  }

  @override
  void setSimulatedQuality(SignalQuality quality) {
    _forcedQuality = quality;
    if (quality == SignalQuality.lossless) {
      _dspBypassed = true;
    } else if (quality == SignalQuality.enhanced) {
      _dspBypassed = false;
    }
    _emitSignalPath();
  }

  @override
  Future<DspPipelineConfigModel> getDspConfig() async => _dspConfig;

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) async {
    _savedNormalBypass = config.bypass;
    if (_strictBitPerfect) {
      _dspConfig = config.copyWith(bypass: true);
      _dspBypassed = true;
    } else {
      _dspConfig = config;
      _dspBypassed = config.bypass;
    }
    _emitSignalPath();
  }

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) async {
    final parsed = <PeqBandModel>[];
    final re = RegExp(
      r'Filter\s+\d+:\s+ON\s+(\w+)\s+Fc\s+([\d.]+)\s+Hz\s+Gain\s+([+-]?[\d.]+)\s+dB\s+Q\s+([\d.]+)',
      caseSensitive: false,
    );
    for (final m in re.allMatches(autoEqTxt)) {
      parsed.add(
        PeqBandModel(
          filterType: m.group(1)!.toUpperCase() == 'LSC'
              ? 'low_shelf'
              : (m.group(1)!.toUpperCase() == 'HSC' ? 'high_shelf' : 'peaking'),
          frequencyHz: double.tryParse(m.group(2)!) ?? 1000.0,
          gainDb: double.tryParse(m.group(3)!) ?? 0.0,
          qFactor: double.tryParse(m.group(4)!) ?? 1.414,
        ),
      );
    }
    if (parsed.isNotEmpty) {
      _dspConfig = _dspConfig.copyWith(peqBands: parsed, bypass: false);
      _dspBypassed = false;
      _emitSignalPath();
    }
    return parsed;
  }

  @override
  bool get isStrictBitPerfect => _strictBitPerfect;

  @override
  DsdOutputModeOption get dsdOutputMode => _dsdOutputMode;

  @override
  Future<void> setStrictBitPerfect(bool enabled) async {
    if (_strictBitPerfect == enabled) return;
    _strictBitPerfect = enabled;
    if (enabled) {
      _savedNormalBypass = _dspBypassed;
      _savedNormalVolume = _state.volume;
      _dspBypassed = true;
      _dspConfig = _dspConfig.copyWith(bypass: true);
      _forcedQuality = SignalQuality.lossless;
      _emitState(_state.copyWith(volume: 1.0, isMuted: false));
    } else {
      _dspBypassed = _savedNormalBypass;
      _dspConfig = _dspConfig.copyWith(bypass: _savedNormalBypass);
      _forcedQuality = null;
      _emitState(
        _state.copyWith(
          volume: _savedNormalVolume,
          isMuted: _savedNormalVolume == 0.0,
        ),
      );
    }
    _emitSignalPath();
  }

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) async {
    _dsdOutputMode = mode;
    _emitSignalPath();
  }
}
