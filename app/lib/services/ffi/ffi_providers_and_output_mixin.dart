part of '../ffi_audio_service.dart';

mixin _FfiProvidersAndOutputMixin on _FfiAudioServiceBase {
  @override
  Future<List<ProviderStatusInfo>> listProviders() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listProviders();
    }
    if (isNativeBound && _providerListFn != null) {
      final raw = _takeRustString(_providerListFn!());
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            return decoded
                .whereType<Map>()
                .map(
                  (e) => ProviderStatusInfo.fromJson(
                    Map<String, dynamic>.from(e),
                  ),
                )
                .toList(growable: false);
          }
        } catch (_) {}
      }
    }
    return _delegate.listProviders();
  }

  @override
  Future<bool> configureProvider(
    String kind,
    Map<String, dynamic> config,
  ) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.configureProvider(kind, config);
    }
    if (!isNativeBound) {
      return _delegate.configureProvider(kind, config);
    }
    if (config['disconnect'] == true) {
      return _delegate.configureProvider(kind, config);
    }
    if (_providerConfigureFn == null) {
      return false;
    }
    final rc = _withNativeUtf8(
      kind,
      (kp) => _withNativeUtf8(
        jsonEncode(config),
        (cp) => _providerConfigureFn!(kp, cp),
      ),
    );
    if (rc == 0) {
      await _delegate.configureProvider(kind, config);
      return true;
    }
    final errMsg =
        _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
    _lastError = (errMsg != null && errMsg.isNotEmpty)
        ? errMsg
        : 'Failed to configure provider $kind (code $rc)';
    return false;
  }

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.startTidalPkce();
    }
    if (!isNativeBound || _tidalPkceStartFn == null) {
      return _delegate.startTidalPkce();
    }
    final raw = _takeRustString(_tidalPkceStartFn!());
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return TidalPkceStartInfo.fromJson(decoded);
    }
    return null;
  }

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.completeTidalPkce(code, codeVerifier);
    }
    if (!isNativeBound || _tidalPkceCompleteFn == null) {
      return _delegate.completeTidalPkce(code, codeVerifier);
    }
    final raw = _withNativeUtf8(
      jsonEncode({'code': code, 'code_verifier': codeVerifier}),
      (p) => _takeRustString(_tidalPkceCompleteFn!(p)),
    );
    return raw != null;
  }

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.syncProvider(kind);
    }
    if (!isNativeBound) {
      return _delegate.syncProvider(kind);
    }
    if (_providerSyncFn == null) {
      return {'provider': kind, 'tracks_count': 0};
    }
    final res = await _callWriteWorker<List<dynamic>>('provider_sync', {
      'kind': kind,
    });
    if (_disposed) return {'provider': kind, 'tracks_count': 0};
    final raw = res != null && res.isNotEmpty ? res[0] as String? : null;
    final errMsg = res != null && res.length > 1 ? res[1] as String? : null;
    await _reloadTracksFromNativeAsync();
    if (_disposed) return {'provider': kind, 'tracks_count': 0};
    if (raw == null) {
      if (errMsg != null && errMsg.isNotEmpty) {
        _lastError = errMsg;
      }
      return {
        'provider': kind,
        'tracks_count': 0,
        if (_lastError != null) 'error': _lastError,
      };
    }
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listProfiles();
    }
    if (!isNativeBound || _profileListFn == null) {
      return _delegate.listProfiles();
    }
    final raw = await _callReadWorker<String>('list_profiles');
    if (_disposed || raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final list = decoded
          .whereType<Map<String, dynamic>>()
          .map(UserProfileInfo.fromJson)
          .toList();
      if (list.isEmpty) {
        await createProfile('預設聆聽者');
        return listProfiles();
      }
      return list;
    }
    return const [];
  }

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.createProfile(name, avatarColor: avatarColor);
    }
    if (!isNativeBound || _profileCreateFn == null) {
      return _delegate.createProfile(name, avatarColor: avatarColor);
    }
    final raw = await _callWriteWorker<String>('create_profile', {
      'payload': jsonEncode({'name': name, 'avatar_color': avatarColor}),
    });
    if (!_disposed && raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return UserProfileInfo.fromJson(decoded);
      }
    }
    return UserProfileInfo(id: 'local', name: name, avatarColor: avatarColor);
  }

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.updateProfile(
        profileId,
        name: name,
        avatarColor: avatarColor,
        isDefault: isDefault,
      );
    }
    if (!isNativeBound || _profileUpdateFn == null) {
      return _delegate.updateProfile(
        profileId,
        name: name,
        avatarColor: avatarColor,
        isDefault: isDefault,
      );
    }
    final rc = await _callWriteWorker<int>('update_profile', {
      'profileId': profileId,
      'payload': jsonEncode({
        'name': ?name,
        'avatar_color': ?avatarColor,
        'is_default': ?isDefault,
      }),
    });
    return !_disposed && rc == 0;
  }

  @override
  Future<void> switchProfile(String profileId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.switchProfile(profileId);
      return;
    }
    if (!isNativeBound || _profileSwitchFn == null) {
      await _delegate.switchProfile(profileId);
      return;
    }
    await _callWriteWorker<int>('switch_profile', {'profileId': profileId});
  }

  @override
  Future<bool> deleteProfile(String profileId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.deleteProfile(profileId);
    }
    if (!isNativeBound || _profileDeleteFn == null) {
      return _delegate.deleteProfile(profileId);
    }
    final rc = await _callWriteWorker<int>('delete_profile', {
      'profileId': profileId,
    });
    return !_disposed && rc == 0;
  }

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() async {
    if (!isNativeBound || _serverStartFn == null || _serverGetPortFn == null) {
      return _delegate.initiateHostPairing();
    }
    var port = _serverGetPortFn!();
    if (port == 0) {
      _serverStartFn!(0, 1);
      port = _serverGetPortFn!();
    }
    if (port > 0) {
      final svc = ServerAudioService(baseUrl: 'http://127.0.0.1:$port');
      return svc.initiateHostPairing();
    }
    return _delegate.initiateHostPairing();
  }

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) {
    return MdnsDiscoveryClient.discover(
      targetHost: multicastHost,
      port: port,
      timeout: timeout,
    );
  }

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) async {
    _remoteClient?.dispose();
    final remote = ServerAudioService(
      baseUrl: baseUrl,
      allowSelfSignedTls: allowSelfSignedTls,
      mode: baseUrl.startsWith('https://')
          ? ConnectionMode.wanRemote
          : ConnectionMode.lanRemote,
    );
    final tok = await remote.pairAndConnectRemote(
      baseUrl: baseUrl,
      pin: pin,
      deviceName: deviceName,
      allowSelfSignedTls: allowSelfSignedTls,
    );
    if (tok != null) {
      _remoteClient = remote;
      _connectionMode = remote.connectionMode;
      _attachRemoteScanProgress(remote);
    } else {
      remote.dispose();
    }
    return tok;
  }

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) async {
    _remoteClient?.dispose();
    final remote = ServerAudioService(
      baseUrl: httpsBaseUrl,
      bearerToken: bearerToken,
      allowSelfSignedTls: allowSelfSignedTls,
      mode: ConnectionMode.wanRemote,
    );
    final ok = await remote.connectWanDirect(
      httpsBaseUrl: httpsBaseUrl,
      bearerToken: bearerToken,
      pin: pin,
      allowSelfSignedTls: allowSelfSignedTls,
    );
    if (ok) {
      _remoteClient = remote;
      _connectionMode = ConnectionMode.wanRemote;
      _attachRemoteScanProgress(remote);
    } else {
      remote.dispose();
    }
    return ok;
  }

  @override
  bool get isStrictBitPerfect =>
      !isNativeBound ? _delegate.isStrictBitPerfect : _strictBitPerfect;

  @override
  DsdOutputModeOption get dsdOutputMode =>
      !isNativeBound ? _delegate.dsdOutputMode : _dsdOutputMode;

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async {
    if (!isNativeBound || _audioGetOutputInfoFn == null) {
      return _delegate.getOutputInfo();
    }
    final raw = _takeRustString(_audioGetOutputInfoFn!());
    if (raw == null || raw.isEmpty) {
      return const AudioEngineOutputInfoModel();
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final info = AudioEngineOutputInfoModel.fromJson(decoded);
      if (info.output.bufferSizeFrames > 0) {
        _preferredBufferFrames = info.output.bufferSizeFrames;
      }
      return info;
    }
    return const AudioEngineOutputInfoModel();
  }

  @override
  Future<bool> setBufferFrames(int frames) async {
    if (!isNativeBound || _audioSetBufferFramesFn == null) {
      return _delegate.setBufferFrames(frames);
    }
    final rc = _audioSetBufferFramesFn!(frames);
    if (rc != 0) {
      final errMsg =
          _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
      _lastError = errMsg ?? 'Failed to set buffer frames (code $rc)';
      return false;
    }
    _lastError = null;
    _preferredBufferFrames = frames;
    _refreshSignalPath();
    return true;
  }

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async {
    if (!isNativeBound || _audioListDeviceCapsFn == null) {
      return _delegate.listDeviceCapabilities();
    }
    final raw = _takeRustString(_audioListDeviceCapsFn!());
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioDeviceCapabilitiesModel.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<void> setStrictBitPerfect(bool enabled) async {
    if (!isNativeBound || _audioSetStrictModeFn == null) {
      await _delegate.setStrictBitPerfect(enabled);
      return;
    }
    if (!_strictBitPerfect && enabled) {
      _savedNormalVolume = _state.volume;
    }
    final rc = _audioSetStrictModeFn!(enabled ? 1 : 0);
    if (rc != 0) {
      final errMsg =
          _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
      _lastError = errMsg ?? 'Strict Mode switch failed (code $rc)';
    } else {
      _lastError = null;
      _strictBitPerfect = enabled;
      if (enabled) {
        _emitState(_state.copyWith(volume: 1.0, isMuted: false));
      } else {
        _emitState(
          _state.copyWith(
            volume: _savedNormalVolume,
            isMuted: _savedNormalVolume == 0.0,
          ),
        );
      }
      _refreshSignalPath();
    }
  }

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) async {
    if (!isNativeBound || _audioSetDsdModeFn == null) {
      await _delegate.setDsdOutputMode(mode);
      return;
    }
    final rc = _audioSetDsdModeFn!(mode.ffiCode);
    if (rc != 0) {
      final errMsg =
          _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
      _lastError = errMsg ?? 'DSD mode switch failed (code $rc)';
    } else {
      _lastError = null;
      _dsdOutputMode = mode;
      _refreshSignalPath();
    }
  }
}
