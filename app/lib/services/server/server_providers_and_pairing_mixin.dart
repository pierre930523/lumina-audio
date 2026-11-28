part of '../server_audio_service.dart';

mixin _ServerProvidersAndPairingMixin on _ServerAudioServiceBase {
  @override
  Future<List<ProviderStatusInfo>> listProviders() async {
    final (code, data) = await _requestJson('GET', '/api/v1/providers');
    if (code == 200 && data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(ProviderStatusInfo.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<bool> configureProvider(
    String kind,
    Map<String, dynamic> config,
  ) async {
    final route = switch (kind) {
      'qobuz' => '/api/v1/providers/qobuz',
      'deezer' => '/api/v1/providers/deezer',
      'web_dav' || 'webdav' => '/api/v1/providers/webdav',
      'smb' => '/api/v1/providers/smb',
      _ => '/api/v1/providers/local',
    };
    final (code, _) = await _requestJson('POST', route, body: config);
    return code == 200;
  }

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/providers/tidal/pkce/start',
      body: const {},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return TidalPkceStartInfo.fromJson(data);
    }
    return null;
  }

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) async {
    final (status, _) = await _requestJson(
      'POST',
      '/api/v1/providers/tidal/pkce/exchange',
      body: {'code': code, 'code_verifier': codeVerifier},
    );
    return status == 200;
  }

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/providers/${Uri.encodeComponent(kind)}/sync',
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return const {};
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() async {
    final (code, data) = await _requestJson('GET', '/api/v1/profiles');
    if (code == 200 && data is Map<String, dynamic>) {
      final list = data['profiles'] as List<dynamic>? ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(UserProfileInfo.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/profiles',
      body: {'name': name, 'avatar_color': avatarColor},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return UserProfileInfo.fromJson(data);
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
    final (code, _) = await _requestJson(
      'PUT',
      '/api/v1/profiles/${Uri.encodeComponent(profileId)}',
      body: {
        'name': ?name,
        'avatar_color': ?avatarColor,
        'is_default': ?isDefault,
      },
    );
    return code == 200;
  }

  @override
  Future<void> switchProfile(String profileId) async {
    await _requestJson(
      'POST',
      '/api/v1/profiles/${Uri.encodeComponent(profileId)}/activate',
    );
  }

  @override
  Future<bool> deleteProfile(String profileId) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/profiles/${Uri.encodeComponent(profileId)}',
    );
    return code == 200;
  }

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() async {
    final uri = Uri.tryParse(_baseUrl);
    final host = (uri != null && uri.host.isNotEmpty) ? uri.host : '127.0.0.1';
    final port = (uri != null && uri.hasPort) ? uri.port : 9888;
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/pair/initiate',
      body: {
        'device_name': 'Lumina-Host',
        'host': host,
        'port': port,
      },
      authenticated: false,
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return PairingInitiateInfo.fromJson(data);
    }
    return null;
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
    _baseUrl = _ServerAudioServiceBase._normalizeBaseUrl(baseUrl);
    _allowSelfSignedTls = allowSelfSignedTls;
    _mode = _baseUrl.startsWith('https://')
        ? ConnectionMode.wanRemote
        : ConnectionMode.lanRemote;

    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/pair/verify',
      body: {
        'pin': pin,
        'client_id': 'flutter-${DateTime.now().millisecondsSinceEpoch}',
        'device_name': deviceName,
        'platform': Platform.operatingSystem,
      },
      authenticated: false,
    );
    if (code == 200 && data is Map<String, dynamic>) {
      final token = data['token']?.toString();
      if (token != null && token.isNotEmpty) {
        _bearerToken = token;
        await connectWebSocket();
        await syncInitialState();
        return token;
      }
    }
    return null;
  }

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) async {
    _baseUrl = _ServerAudioServiceBase._normalizeBaseUrl(httpsBaseUrl);
    _allowSelfSignedTls = allowSelfSignedTls;
    _mode = ConnectionMode.wanRemote;

    if (bearerToken != null && bearerToken.trim().isNotEmpty) {
      _bearerToken = bearerToken.trim();
      final healthy = await checkHealth();
      if (!healthy) return false;
      await connectWebSocket();
      await syncInitialState();
      return true;
    }
    if (pin != null && pin.trim().length == 6) {
      final tok = await pairAndConnectRemote(
        baseUrl: httpsBaseUrl,
        pin: pin.trim(),
        allowSelfSignedTls: allowSelfSignedTls,
      );
      return tok != null;
    }
    return checkHealth();
  }

  @override
  bool get isSystemOutputActive => false;

  @override
  String? get lastError => _lastError ?? _state.lastError;

  @override
  int get preferredBufferFrames => 512;

  @override
  Future<bool> setBufferFrames(int frames) async => false;

  @override
  bool get isStrictBitPerfect => false;

  @override
  DsdOutputModeOption get dsdOutputMode => DsdOutputModeOption.auto;

  @override
  Future<void> setStrictBitPerfect(bool enabled) async {}

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) async {}

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async =>
      const [];

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async =>
      const AudioEngineOutputInfoModel();

  @override
  Future<void> switchToLocalMode() async {
    _wsIntentionalClose = true;
    _wsReconnectTimer?.cancel();
    _wsReconnectTimer = null;
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _mode = ConnectionMode.localOrUsbDac;
    _setConnectionStatus(const ConnectionStatus.localConnected());
  }

  @override
  Stream<QueueState> get queueStateStream => _queueStateController.stream;

  @override
  QueueState get currentQueueState => _queueState;

  @override
  Stream<ConnectionStatus> get connectionStatusStream =>
      _connectionStatusController.stream;

  @override
  ConnectionStatus get currentConnectionStatus => _connectionStatus;

  @override
  Stream<LuminaError> get errorStream => _errorController.stream;

  @override
  Stream<TrackInfo> get trackChangedStream => _trackChangedController.stream;

  @override
  Stream<List<TrackInfo>> get queueUpdatedStream =>
      _queueUpdatedController.stream;

  @override
  RepeatMode get repeatMode => _repeatMode;

  @override
  bool get shuffle => _shuffle;

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    _repeatMode = mode;
    _state = _state.copyWith(repeatMode: mode);
    if (!_disposed && !_stateController.isClosed) _stateController.add(_state);
    try {
      await _requestJson(
        'POST',
        '/api/v1/playback/command',
        body: SetRepeatModeCommand(mode: mode).toJson(),
      );
    } catch (_) {}
  }

  @override
  Future<void> setShuffle(bool enabled) async {
    _shuffle = enabled;
    _state = _state.copyWith(shuffle: enabled);
    if (!_disposed && !_stateController.isClosed) _stateController.add(_state);
    try {
      await _requestJson(
        'POST',
        '/api/v1/playback/command',
        body: SetShuffleCommand(enabled: enabled).toJson(),
      );
    } catch (_) {}
  }

  @override
  PlaybackBackend? get playbackBackend {
    _protocolBackend ??= RemotePlaybackBackend(
      baseUrl: _baseUrl,
      bearerToken: _bearerToken,
      allowSelfSignedTls: _allowSelfSignedTls,
      mode: _mode,
      baseRetryDelay: _wsBaseRetryDelay,
      maxRetryDelay: _wsMaxRetryDelay,
      autoReconnect: _wsAutoReconnect,
    );
    return _protocolBackend;
  }

  @override
  PlaybackController? get playbackController {
    _protocolController ??= PlaybackController(backend: playbackBackend!);
    return _protocolController;
  }

  @override
  AutoplayController? get autoplayController => null;

  @override
  void Function(TrackInfo track)? get hoverPrefetchCallback => null;

  @override
  Future<void> get dbReadyFuture => Future<void>.value();

  @override
  L1StreamCachePersistence? createL1CachePersistence() => null;

  @override
  SidecarLifecycleBinder? createSidecarLifecycleBinder() => null;

  @override
  VoidCallback? get streamingHttp2WarmupCallback => null;

  @override
  void attachStreamingHooks(StreamingManager manager) {}

  @override
  void detachStreamingHooks() {}

  @override
  ValueListenable<Float32List> get visualizerBandsNotifier =>
      AudioServiceVisualizerExt.defaultVisualizerNotifier;

  @override
  void setVisualizerSettingEnabled(bool enabled) {}

  @override
  void setNowPlayingVisible(bool visible) {}

  @override
  void setWindowMinimized(bool minimized) {}
}
