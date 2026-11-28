part of '../mock_audio_service.dart';

mixin _MockProvidersAndProfilesMixin on _MockAudioServiceBase {
  File _providerPrefsFile() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}provider_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_provider_prefs.json',
    );
  }

  Future<void> _ensureProvidersLoaded() async {
    if (_providersLoaded) return;
    _providersLoaded = true;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final file = _providerPrefsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final activeKinds = decoded.map((e) => e.toString()).toSet();
      for (var i = 0; i < _providers.length; i++) {
        final k = _providers[i].kind;
        if (k == 'local') continue;
        final loggedIn = activeKinds.contains(k);
        _providers[i] = ProviderStatusInfo(
          kind: k,
          isConfigured: loggedIn,
          isOnline: loggedIn,
        );
      }
    } catch (_) {
      // Keep default provider states on unreadable prefs.
    }
  }

  Future<void> _saveProviderPrefs() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      final file = _providerPrefsFile();
      await file.parent.create(recursive: true);
      final active = _providers
          .where((p) => p.kind != 'local' && (p.isOnline || p.isConfigured))
          .map((p) => p.kind)
          .toList();
      await file.writeAsString(jsonEncode(active));
    } catch (_) {
      // Ignore write failures gracefully.
    }
  }

  @override
  Future<List<ProviderStatusInfo>> listProviders() async {
    await _ensureProvidersLoaded();
    return List.unmodifiable(_providers);
  }

  @override
  Future<bool> configureProvider(
    String kind,
    Map<String, dynamic> config,
  ) async {
    await _ensureProvidersLoaded();
    final isDisconnect = config['disconnect'] == true;
    final idx = _providers.indexWhere((p) => p.kind == kind);
    final nextStatus = ProviderStatusInfo(
      kind: kind,
      isConfigured: !isDisconnect,
      isOnline: !isDisconnect,
    );
    if (idx >= 0) {
      _providers[idx] = nextStatus;
    } else {
      _providers.add(nextStatus);
    }
    await _saveProviderPrefs();
    return true;
  }

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() async =>
      const TidalPkceStartInfo(
        authUrl:
            'https://login.tidal.com/authorize?response_type=code&code_challenge=demo',
        verifier: 'demo_verifier_1234567890_abcdefghijklmnopqrstuvwxyz',
        challenge: 'demo_challenge',
      );

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) async {
    await configureProvider('tidal', {'code': code});
    return true;
  }

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) async {
    final samples = <String, TrackInfo>{
      'apple_music': const TrackInfo(
        id: 'am-001',
        title: '群青（ALAC Studio Master）',
        artist: 'YOASOBI',
        album: 'THE BOOK 2',
        duration: Duration(minutes: 4, seconds: 8),
        format: AudioFormat(
          codec: AudioCodec.alac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'Apple Music Lossless',
      ),
      'youtube_music': const TrackInfo(
        id: 'ytm-001',
        title: '偶像 Idol (Studio Live)',
        artist: 'YOASOBI',
        album: 'YOASOBI 5th Anniversary Live',
        duration: Duration(minutes: 3, seconds: 42),
        format: AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'YouTube Music',
      ),
      'deezer': const TrackInfo(
        id: 'dz-001',
        title: 'Get Lucky (Studio Edition)',
        artist: 'Daft Punk',
        album: 'Random Access Memories',
        duration: Duration(minutes: 6, seconds: 9),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
        providerName: 'Deezer HiFi',
      ),
    };
    final sample = samples[kind];
    if (sample != null && !_queue.any((t) => t.id == sample.id)) {
      _queue.add(sample);
    }
    return {
      'provider': kind,
      'tracks_count': _queue.length,
    };
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() async =>
      List.unmodifiable(_profiles);

  String get activeProfileId => _activeProfileId;

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) async {
    final created = UserProfileInfo(
      id: 'prof-${_profiles.length + 1}',
      name: name,
      avatarColor: avatarColor,
      isDefault: false,
    );
    _profiles.add(created);
    return created;
  }

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) async {
    final idx = _profiles.indexWhere((p) => p.id == profileId);
    if (idx < 0) return false;
    final cur = _profiles[idx];
    _profiles[idx] = UserProfileInfo(
      id: cur.id,
      name: name ?? cur.name,
      avatarColor: avatarColor ?? cur.avatarColor,
      isDefault: isDefault ?? cur.isDefault,
    );
    return true;
  }

  @override
  Future<void> switchProfile(String profileId) async {
    _activeProfileId = profileId;
  }

  @override
  Future<bool> deleteProfile(String profileId) async {
    final idx = _profiles.indexWhere((p) => p.id == profileId && !p.isDefault);
    if (idx < 0) return false;
    _profiles.removeAt(idx);
    if (_activeProfileId == profileId) {
      _activeProfileId = _profiles.first.id;
    }
    return true;
  }

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() async {
    return const PairingInitiateInfo(
      pin: '849201',
      qrPayload: 'lumina://pair?pin=849201&host=127.0.0.1&port=9888',
      expiresInSec: 60,
    );
  }

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    if (port != 5353) {
      return MdnsDiscoveryClient.discover(
        targetHost: multicastHost,
        port: port,
        timeout: timeout,
      );
    }
    return const [
      DiscoveredServerInfo(
        serverName: 'Lumina-Desktop',
        host: '127.0.0.1',
        port: 9888,
        txtRecords: {'version': '0.1.0', 'api_version': '1'},
      ),
    ];
  }

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) async {
    _connectionMode = baseUrl.startsWith('https://')
        ? ConnectionMode.wanRemote
        : ConnectionMode.lanRemote;
    _activeServerUrl = baseUrl;
    return 'lum_sec_mock_token_$pin';
  }

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) async {
    _connectionMode = ConnectionMode.wanRemote;
    _activeServerUrl = httpsBaseUrl;
    return true;
  }

  @override
  Future<void> switchToLocalMode() async {
    _connectionMode = ConnectionMode.localOrUsbDac;
    _activeServerUrl = null;
  }
}
