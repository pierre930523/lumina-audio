import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/audio_service.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/l1_stream_cache.dart';
import 'package:lumina_app/services/streaming/playback_backend.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';

TrackInfo _makeTrack(
  String id, {
  String title = '',
  String providerName = '',
  String? filePath,
  Duration duration = const Duration(seconds: 200),
}) {
  final resolvedProvider = providerName.isNotEmpty
      ? providerName
      : switch (id.split(':').first) {
          'qobuz' => 'Qobuz',
          'tidal' => 'Tidal',
          'deezer' => 'Deezer',
          'ytm' => 'YouTube Music',
          'apple' => 'Apple Music',
          _ => 'Local Library',
        };
  return TrackInfo(
    id: id,
    title: title.isEmpty ? 'Track $id' : title,
    artist: 'Test Artist',
    album: 'Test Album',
    duration: duration,
    filePath: filePath,
    providerName: resolvedProvider,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
  );
}

class _CountingResolver implements StreamResolver {
  @override
  final String providerId;

  @override
  final ProviderCapabilities capabilities;

  final Future<StreamSourceSpec> Function(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) onResolve;

  final List<StreamKey> resolvedKeys = <StreamKey>[];

  _CountingResolver({
    required this.providerId,
    required this.capabilities,
    required this.onResolve,
  });

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) {
    resolvedKeys.add(key);
    return onResolve(key, cancelToken: cancelToken);
  }
}

class _SpyNativeDualDeckBackend extends NativePlaybackBackend {
  final List<({StreamSourceSpec spec, TrackInfo track, int epoch})> playCalls =
      [];
  final List<({StreamSourceSpec spec, TrackInfo track, int epoch})>
      prepareStandbyCalls = [];
  final List<int> skipToStandbyEpochs = [];
  final List<int> stopEpochs = [];

  bool forceSkipToStandbyResult = true;
  bool overrideSkipResult = false;
  TrackInfo? _preparedTrack;
  StreamSourceSpec? _preparedSpec;
  bool _ready = false;

  _SpyNativeDualDeckBackend(super.audioService);

  @override
  bool get isStandbyReady => _ready || super.isStandbyReady;

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    playCalls.add((spec: spec, track: track, epoch: epoch));
    _ready = false;
    _preparedTrack = null;
    _preparedSpec = null;
    await super.play(spec, track, epoch: epoch);
  }

  @override
  Future<void> prepareStandby(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    prepareStandbyCalls.add((spec: spec, track: track, epoch: epoch));
    _preparedTrack = track;
    _preparedSpec = spec;
    _ready = true;
    await super.prepareStandby(spec, track, epoch: epoch);
  }

  @override
  Future<bool> skipToStandby({required int epoch}) async {
    skipToStandbyEpochs.add(epoch);
    if (overrideSkipResult && !forceSkipToStandbyResult) {
      _ready = false;
      _preparedTrack = null;
      _preparedSpec = null;
      return false;
    }
    if (!_ready || _preparedTrack == null || _preparedSpec == null) {
      return false;
    }
    _ready = false;
    _preparedTrack = null;
    _preparedSpec = null;
    return super.skipToStandby(epoch: epoch);
  }

  @override
  Future<void> stop({required int epoch}) async {
    stopEpochs.add(epoch);
    _ready = false;
    _preparedTrack = null;
    _preparedSpec = null;
    await super.stop(epoch: epoch);
  }
}

class _FakeExternalBridge implements ExternalPlaybackBridge {
  void Function(ExternalPlaybackEvent event)? _handler;
  final List<({String trackUri, String? previewUrl, int epoch, String? webUrl})>
      playCalls = [];
  final List<int> stopEpochs = [];

  @override
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler) {
    _handler = handler;
  }

  void emitHostState(ExternalPlaybackEvent event) {
    _handler?.call(event);
  }

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  }) async {}

  @override
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  }) async {
    playCalls.add((
      trackUri: trackUri,
      previewUrl: previewUrl,
      epoch: epoch,
      webUrl: externalWebUrl,
    ));
    _handler?.call(
      ExternalPlaybackEvent(
        epoch: epoch,
        status: 'playing',
        positionMs: 0,
        durationMs: 180000,
      ),
    );
  }

  @override
  Future<void> pause({required int epoch}) async {}

  @override
  Future<void> resume({required int epoch}) async {}

  @override
  Future<void> seek({required Duration position, required int epoch}) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop({required int epoch}) async {
    stopEpochs.add(epoch);
  }

  @override
  void dispose() {
    _handler = null;
  }
}

StreamResolverRegistry _buildRegistry({
  required _CountingResolver qobuz,
  required _CountingResolver tidal,
  required _CountingResolver deezer,
  required _CountingResolver ytm,
  required _CountingResolver apple,
}) {
  final registry = StreamResolverRegistry();
  registry.register(
    qobuz,
    idPrefixes: const <String>['qobuz:', 'streaming:qobuz:'],
    providerNames: const <String>['qobuz'],
  );
  registry.register(
    tidal,
    idPrefixes: const <String>['tidal:', 'streaming:tidal:'],
    providerNames: const <String>['tidal'],
  );
  registry.register(
    deezer,
    idPrefixes: const <String>['deezer:', 'streaming:deezer:'],
    providerNames: const <String>['deezer'],
  );
  registry.register(
    ytm,
    idPrefixes: const <String>['ytm:', 'streaming:youtube_music:'],
    providerNames: const <String>['youtube music'],
  );
  registry.register(
    apple,
    idPrefixes: const <String>['apple:', 'streaming:apple_music:'],
    providerNames: const <String>['apple music'],
  );
  return registry;
}

({
  _CountingResolver qobuz,
  _CountingResolver tidal,
  _CountingResolver deezer,
  _CountingResolver ytm,
  _CountingResolver apple,
}) _createResolvers() {
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return (
    qobuz: _CountingResolver(
      providerId: 'qobuz',
      capabilities: ProviderCapabilities.qobuz,
      onResolve: (key, {cancelToken}) async => DirectRangeSpec(
        key: key,
        url: 'https://qobuz.cdn.example/${key.trackId}.flac',
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        bitrateBps: 1411200,
        contentLength: 24000000,
        expireAt: nowSec + 3600,
      ),
    ),
    tidal: _CountingResolver(
      providerId: 'tidal',
      capabilities: ProviderCapabilities.tidal,
      onResolve: (key, {cancelToken}) async => SegmentedManifestSpec(
        key: key,
        manifestUrlOrXml: '<MPD id="${key.trackId}"/>',
        format: ManifestFormat.dash,
        mimeType: 'audio/flac',
        bitrateBps: 2304000,
        expireAt: nowSec + 3600,
      ),
    ),
    deezer: _CountingResolver(
      providerId: 'deezer',
      capabilities: ProviderCapabilities.deezer,
      onResolve: (key, {cancelToken}) async => EncryptedRangeSpec(
        key: key,
        url: 'https://deezer.cdn.example/${key.trackId}',
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        bitrateBps: 1411200,
        contentLength: 20000000,
        cipher: DeezerBlowfishCipher(trackId: key.trackId),
        expireAt: nowSec + 3600,
      ),
    ),
    ytm: _CountingResolver(
      providerId: 'youtube_music',
      capabilities: ProviderCapabilities.youtubeMusic,
      onResolve: (key, {cancelToken}) async => DirectRangeSpec(
        key: key,
        url: 'https://rr1.googlevideo.com/${key.trackId}.webm',
        mimeType: 'audio/webm; codecs="opus"',
        hintExtension: 'webm',
        bitrateBps: 160000,
        contentLength: 3500000,
        expireAt: nowSec + 21600,
      ),
    ),
    apple: _CountingResolver(
      providerId: 'apple_music',
      capabilities: ProviderCapabilities.appleMusic,
      onResolve: (key, {cancelToken}) async => ExternalBackendSpec(
        key: key,
        providerId: 'apple_music',
        trackUri: 'apple:${key.trackId}',
        externalWebUrl: 'https://music.apple.com/us/song/${key.trackId}',
      ),
    ),
  );
}

void main() {
  group('Phase 4 Models, FFI Surface & Mock/DualDeck Contracts', () {
    test('parseDeckState and DualDeckStatus parse wire strings and readiness', () {
      expect(parseDeckState('IDLE'), DeckState.idle);
      expect(parseDeckState('RESOLVING'), DeckState.resolving);
      expect(parseDeckState('PREBUFFERING'), DeckState.prebuffering);
      expect(parseDeckState('STANDBY_READY'), DeckState.standbyReady);
      expect(parseDeckState('PLAYING'), DeckState.playing);
      expect(parseDeckState('SEEKING'), DeckState.seeking);
      expect(parseDeckState('RECOVERING_403'), DeckState.recovering403);
      expect(parseDeckState('DRAINING'), DeckState.draining);
      expect(parseDeckState('standbyReady'), DeckState.standbyReady);
      expect(parseDeckState('3'), DeckState.standbyReady);
      expect(parseDeckState('unknown'), DeckState.idle);
      expect(parseDeckState(null), DeckState.idle);

      final deckAPlayingDeckBReady = DualDeckStatus.fromJson(
        const <String, dynamic>{
          'active_deck': 'deck_a',
          'deck_a_state': 'PLAYING',
          'deck_b_state': 'STANDBY_READY',
          'standby_buffered_ms': 2500,
          'gapless_transitions': 2,
          'manual_zero_latency_switches': 1,
          'format_mismatch_recoveries': 0,
        },
      );
      expect(deckAPlayingDeckBReady.activeDeck, 'deck_a');
      expect(deckAPlayingDeckBReady.activeDeckState, DeckState.playing);
      expect(deckAPlayingDeckBReady.standbyDeckState, DeckState.standbyReady);
      expect(deckAPlayingDeckBReady.isStandbyReady, isTrue);
      expect(deckAPlayingDeckBReady.standbyBufferedMs, 2500);
      expect(deckAPlayingDeckBReady.gaplessTransitions, 2);
      expect(deckAPlayingDeckBReady.manualZeroLatencySwitches, 1);

      final deckBPlayingDeckAReady = DualDeckStatus.fromJson(
        const <String, dynamic>{
          'dual_deck': <String, dynamic>{
            'active_deck': 'deck_b',
            'deck_a_state': 'STANDBY_READY',
            'deck_b_state': 'PLAYING',
            'standby_buffered_ms': 2800,
          },
        },
      );
      expect(deckBPlayingDeckAReady.activeDeck, 'deck_b');
      expect(deckBPlayingDeckAReady.activeDeckState, DeckState.playing);
      expect(deckBPlayingDeckAReady.standbyDeckState, DeckState.standbyReady);
      expect(deckBPlayingDeckAReady.isStandbyReady, isTrue);

      const notReady = DualDeckStatus(
        activeDeck: 'deck_a',
        deckAState: DeckState.playing,
        deckBState: DeckState.prebuffering,
      );
      expect(notReady.isStandbyReady, isFalse);
    });

    test(
      'FfiAudioService handles missing Phase 4 C-ABI symbols gracefully and tracks DualDeckStatus from polled JSON',
      () async {
        final ffi = FfiAudioService(headless: true);
        addTearDown(ffi.dispose);

        expect(ffi.isStandbyDeckReady, isFalse);
        expect(ffi.lastDualDeckSnapshot, isNull);
        if (!ffi.isNativeBound) {
          expect(await ffi.getL2CacheTotalBytes(), isNull);
          expect(await ffi.evictL2CacheNow(), isFalse);
          expect(await ffi.flushL2CacheAccess(), isFalse);
          expect(await ffi.runL2CacheOrphanSweep(), isFalse);
        } else {
          expect(await ffi.getL2CacheTotalBytes(), greaterThanOrEqualTo(0));
          expect(await ffi.evictL2CacheNow(), isA<bool>());
          expect(await ffi.flushL2CacheAccess(), isA<bool>());
          expect(await ffi.runL2CacheOrphanSweep(), isA<bool>());
        }
        expect(await ffi.skipToStandby(), isFalse);

        // ExternalBackendSpec is strictly rejected by native AudioService.
        expect(
          () => ffi.prepareStandbySpecAsync(
            _makeTrack('apple:101'),
            const ExternalBackendSpec(
              key: StreamKey('apple_music', '101', 'default'),
              providerId: 'apple_music',
              trackUri: 'apple:101',
            ),
            epoch: 1,
          ),
          throwsStateError,
        );

        // State JSON with dual-deck snapshot updates lastDualDeckSnapshot & isStandbyDeckReady.
        final accepted = ffi.processStateJsonForTest(const <String, dynamic>{
          'state_code': 2,
          'position_ms': 185000,
          'duration_ms': 200000,
          'epoch': 4,
          'active_deck': 'deck_a',
          'deck_a_state': 'PLAYING',
          'deck_b_state': 'STANDBY_READY',
          'standby_buffered_ms': 2600,
          'gapless_transitions': 1,
          'manual_zero_latency_switches': 3,
          'format_mismatch_recoveries': 1,
        });
        expect(accepted, isTrue);
        expect(ffi.isStandbyDeckReady, isTrue);
        expect(ffi.lastDualDeckSnapshot?.activeDeck, 'deck_a');
        expect(ffi.lastDualDeckSnapshot?.deckBState, DeckState.standbyReady);
        expect(ffi.lastDualDeckSnapshot?.standbyBufferedMs, 2600);
        expect(ffi.lastDualDeckSnapshot?.manualZeroLatencySwitches, 3);
        expect(ffi.lastDualDeckSnapshot?.formatMismatchRecoveries, 1);

        // When native core_ffi.dll is absent, delegate fallback handles standby;
        // when an older native core_ffi.dll is loaded without Phase 4 symbols,
        // prepareStandbySpecAsync / skipToStandby degrade cleanly without crash.
        final qobuzTrack = _makeTrack('qobuz:55');
        await ffi.prepareStandbySpecAsync(
          qobuzTrack,
          const DirectRangeSpec(
            key: StreamKey('qobuz', '55', 'default'),
            url: 'https://qobuz.example/55.flac',
          ),
          epoch: 5,
        );
        final skipped = await ffi.skipToStandby(epoch: 5);
        if (!ffi.isNativeBound) {
          expect(skipped, isTrue);
          expect(ffi.currentState.track?.id, 'qobuz:55');
          expect(ffi.currentState.status, PlaybackStatus.playing);
        } else {
          expect(skipped, isFalse);
        }
      },
    );

    test(
      'MockAudioService DualDeckAudioService prepares standby, rejects ExternalBackendSpec, and flips on skipToStandby',
      () async {
        final mock = MockAudioService();
        addTearDown(mock.dispose);

        final AudioService asInterface = mock;
        expect(asInterface.isStandbyDeckReady, isFalse);
        expect(await asInterface.skipToStandby(epoch: 1), isFalse);

        final nextTrack = _makeTrack('qobuz:900');
        const spec = DirectRangeSpec(
          key: StreamKey('qobuz', '900', 'default'),
          url: 'https://qobuz.example/900.flac',
        );
        await asInterface.prepareStandbySpecAsync(nextTrack, spec, epoch: 2);
        expect(asInterface.isStandbyDeckReady, isTrue);
        expect(mock.standbyTrack?.id, 'qobuz:900');

        expect(await asInterface.skipToStandby(epoch: 2), isTrue);
        expect(asInterface.isStandbyDeckReady, isFalse);
        expect(mock.currentState.track?.id, 'qobuz:900');
        expect(mock.currentState.status, PlaybackStatus.playing);
        expect(mock.lastSourceSpec, spec);
      },
    );
  });

  group('Phase 4 Pre-Decode Trigger (15-20s remaining & >75% progress)', () {
    test(
      'triggers prepareStandby once per (epoch, track) at 15-20s remaining across qobuz, tidal, deezer, youtube_music, and local',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyNativeDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final resolvers = _createResolvers();
        final registry = _buildRegistry(
          qobuz: resolvers.qobuz,
          tidal: resolvers.tidal,
          deezer: resolvers.deezer,
          ytm: resolvers.ytm,
          apple: resolvers.apple,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('qobuz:1', duration: const Duration(seconds: 200)),
          _makeTrack('tidal:2', duration: const Duration(seconds: 200)),
          _makeTrack('deezer:3', duration: const Duration(seconds: 200)),
          _makeTrack('ytm:4', duration: const Duration(seconds: 200)),
          _makeTrack(
            'local:5',
            filePath: '/music/local_5.flac',
            duration: const Duration(seconds: 200),
          ),
        ];

        // 1. Active = Qobuz, Next = Tidal.
        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(nativeBackend.prepareStandbyCalls, isEmpty);

        // Before trigger zone (50s remaining, 75% exactly): must NOT trigger.
        await coordinator.seek(const Duration(seconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, isEmpty);
        expect(resolvers.tidal.resolvedKeys, isEmpty);

        // Enter 15-20s remaining window (18s remaining at t=182s) -> prepares Tidal once.
        await coordinator.seek(const Duration(seconds: 182));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(1));
        expect(nativeBackend.prepareStandbyCalls.last.track.id, 'tidal:2');
        expect(
          nativeBackend.prepareStandbyCalls.last.spec,
          isA<SegmentedManifestSpec>(),
        );
        expect(resolvers.tidal.resolvedKeys, hasLength(1));
        expect(coordinator.isStandbyReady, isTrue);

        // Repeated ticks in same (epoch, track) do NOT re-trigger prepareStandby.
        await audio.seek(const Duration(seconds: 185));
        await audio.seek(const Duration(seconds: 190));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(1));
        expect(resolvers.tidal.resolvedKeys, hasLength(1));

        // 2. Active = Tidal, Next = Deezer -> triggers EncryptedRangeSpec standby.
        await coordinator.playTrack(queue[1], queueContext: queue);
        await coordinator.seek(const Duration(seconds: 182));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(2));
        expect(nativeBackend.prepareStandbyCalls.last.track.id, 'deezer:3');
        expect(
          nativeBackend.prepareStandbyCalls.last.spec,
          isA<EncryptedRangeSpec>(),
        );

        // 3. Active = Deezer, Next = YTM -> triggers DirectRangeSpec standby.
        await coordinator.playTrack(queue[2], queueContext: queue);
        await coordinator.seek(const Duration(seconds: 183));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(3));
        expect(nativeBackend.prepareStandbyCalls.last.track.id, 'ytm:4');
        expect(
          nativeBackend.prepareStandbyCalls.last.spec,
          isA<DirectRangeSpec>(),
        );

        // 4. Active = YTM, Next = Local file -> triggers LocalFileSpec standby.
        await coordinator.playTrack(queue[3], queueContext: queue);
        await coordinator.seek(const Duration(seconds: 184));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(4));
        expect(nativeBackend.prepareStandbyCalls.last.track.id, 'local:5');
        expect(
          nativeBackend.prepareStandbyCalls.last.spec,
          isA<LocalFileSpec>(),
        );

        // 5. Active = Local (playing on audioService), Next = Qobuz -> triggers Qobuz standby.
        await coordinator.stop();
        coordinator.setQueueContext(queue, currentTrack: queue[4], queueIndex: 4);
        await audio.play(track: queue[4]);
        await audio.seek(const Duration(seconds: 182));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(5));
        expect(nativeBackend.prepareStandbyCalls.last.track.id, 'qobuz:1');
        expect(
          nativeBackend.prepareStandbyCalls.last.spec,
          isA<DirectRangeSpec>(),
        );
      },
    );

    test(
      'triggers prepareStandby at >75% progress for short tracks while ignoring <=75%',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyNativeDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final resolvers = _createResolvers();
        final registry = _buildRegistry(
          qobuz: resolvers.qobuz,
          tidal: resolvers.tidal,
          deezer: resolvers.deezer,
          ytm: resolvers.ytm,
          apple: resolvers.apple,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        // 20s short track: at t=10s (50%) must NOT fire prematurely even though
        // remaining is 10s; at t=16s (80% > 75%) MUST fire!
        final shortQueue = <TrackInfo>[
          _makeTrack('qobuz:short_1', duration: const Duration(seconds: 20)),
          _makeTrack('qobuz:short_2', duration: const Duration(seconds: 20)),
        ];

        await coordinator.playTrack(shortQueue[0], queueContext: shortQueue);
        await coordinator.seek(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, isEmpty);

        // Exactly 75% (15s / 20s) is not > 75%.
        await coordinator.seek(const Duration(seconds: 15));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, isEmpty);

        // 16s / 20s = 80% (> 75%) -> triggers standby pre-decode!
        await coordinator.seek(const Duration(seconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(nativeBackend.prepareStandbyCalls, hasLength(1));
        expect(
          nativeBackend.prepareStandbyCalls.single.track.id,
          'qobuz:short_2',
        );
      },
    );

    test(
      'triggers Native prepareStandby even when currently active track is Apple Music ExternalBackend',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyNativeDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final resolvers = _createResolvers();
        final registry = _buildRegistry(
          qobuz: resolvers.qobuz,
          tidal: resolvers.tidal,
          deezer: resolvers.deezer,
          ytm: resolvers.ytm,
          apple: resolvers.apple,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('apple:ext_1', duration: const Duration(seconds: 180)),
          _makeTrack('qobuz:nat_2', duration: const Duration(seconds: 210)),
        ];

        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(coordinator.isExternalBackendActive, isTrue);
        final epoch = coordinator.currentEpoch;

        // Host reports 163s / 180s (17s remaining) -> Native Standby prepares qobuz:nat_2!
        bridge.emitHostState(
          ExternalPlaybackEvent(
            epoch: epoch,
            status: 'playing',
            positionMs: 163000,
            durationMs: 180000,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(nativeBackend.prepareStandbyCalls, hasLength(1));
        expect(nativeBackend.prepareStandbyCalls.single.track.id, 'qobuz:nat_2');
        expect(coordinator.isStandbyReady, isTrue);

        // Manual skip from Apple Music -> Qobuz stops external backend and flips via skipToStandby!
        await coordinator.next();
        expect(bridge.stopEpochs, isNotEmpty);
        expect(nativeBackend.skipToStandbyEpochs, hasLength(1));
        expect(nativeBackend.playCalls, isEmpty);
        expect(resolvers.qobuz.resolvedKeys, hasLength(1));
        expect(coordinator.isExternalBackendActive, isFalse);
        expect(audio.currentState.track?.id, 'qobuz:nat_2');
        expect(audio.currentState.status, PlaybackStatus.playing);
      },
    );
  });

  group('Phase 4 Apple Music Isolation & Zero L1/L2 Cache Writes', () {
    test(
      'Apple Music next track skips Native prepareStandby, marks external handoff prepared, and writes ZERO L1/L2 entries',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyNativeDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final l1Persistence = InMemoryL1StreamCachePersistence();
        final l1Cache = L1StreamCache(persistence: l1Persistence);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          l1Cache: l1Cache,
          enableLiveWarmup: false,
        );
        final resolvers = _createResolvers();
        final registry = _buildRegistry(
          qobuz: resolvers.qobuz,
          tidal: resolvers.tidal,
          deezer: resolvers.deezer,
          ytm: resolvers.ytm,
          apple: resolvers.apple,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('qobuz:10', duration: const Duration(seconds: 200)),
          _makeTrack('apple:20', duration: const Duration(seconds: 180)),
        ];

        await coordinator.playTrack(queue[0], queueContext: queue);
        await coordinator.seek(const Duration(seconds: 182));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Apple Music MUST NOT enter Native prepareStandby or write L1/L2!
        expect(nativeBackend.prepareStandbyCalls, isEmpty);
        expect(audio.isStandbyDeckReady, isFalse);
        expect(audio.standbyTrack, isNull);
        expect(resolvers.apple.resolvedKeys, isEmpty);
        expect(l1Cache.length, 0);
        expect(l1Persistence.upsertCalls, 0);
        // Only the active Qobuz track (qobuz:10) may be in coordinator L1 cache;
        // Apple Music (apple:20) has ZERO L1 or L2 entries.
        expect(coordinator.cacheLength, 1);
        expect(coordinator.getCachedStream('qobuz:10'), isNotNull);
        expect(coordinator.getCachedStream('apple:20'), isNull);

        // Even directly putting ExternalBackendSpec into L1StreamCache writes 0 entries.
        l1Cache.put(
          const ExternalBackendSpec(
            key: StreamKey('apple_music', '20', 'default'),
            providerId: 'apple_music',
            trackUri: 'apple:20',
          ),
          ProviderCapabilities.appleMusic,
        );
        expect(l1Cache.length, 0);
        expect(l1Persistence.upsertCalls, 0);

        // External handoff readiness IS prepared on both coordinator and AppleMusicPlaybackBackend.
        expect(coordinator.isExternalHandoffPrepared, isTrue);
        expect(coordinator.preparedExternalHandoffTrackId, 'apple:20');
        expect(externalBackend.isExternalHandoffPrepared, isTrue);
        expect(externalBackend.preparedExternalTrackId, 'apple:20');

        // Calling prepareStandby directly on AppleMusicPlaybackBackend is also a strict no-op.
        await externalBackend.prepareStandby(
          const ExternalBackendSpec(
            key: StreamKey('apple_music', '20', 'default'),
            providerId: 'apple_music',
            trackUri: 'apple:20',
          ),
          queue[1],
          epoch: 99,
        );
        expect(externalBackend.isStandbyReady, isFalse);
        expect(await externalBackend.skipToStandby(epoch: 99), isFalse);
      },
    );
  });

  group('Phase 4 Zero-Latency Manual Skip & Seamless Fallback', () {
    test(
      'manual skip uses skipToStandby() without re-resolving or debounce delay when Standby is STANDBY_READY',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyNativeDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final resolvers = _createResolvers();
        final registry = _buildRegistry(
          qobuz: resolvers.qobuz,
          tidal: resolvers.tidal,
          deezer: resolvers.deezer,
          ytm: resolvers.ytm,
          apple: resolvers.apple,
        );

        // Long debounceDelay proves zero-latency standby skip bypasses debounce!
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: const Duration(milliseconds: 500),
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('qobuz:a', duration: const Duration(seconds: 200)),
          _makeTrack('ytm:b', duration: const Duration(seconds: 200)),
          _makeTrack('deezer:c', duration: const Duration(seconds: 200)),
        ];

        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(nativeBackend.playCalls, hasLength(1));

        // Pre-decode ytm:b at 18s remaining.
        await coordinator.seek(const Duration(seconds: 182));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(resolvers.ytm.resolvedKeys, hasLength(1));
        expect(nativeBackend.prepareStandbyCalls, hasLength(1));
        expect(coordinator.preparedStandbyTrackId, 'ytm:b');
        expect(coordinator.isStandbyReady, isTrue);

        // Manual skip via next() must flip via skipToStandby() immediately (<50ms,
        // bypassing the 500ms debounce) with ZERO second resolve and ZERO play() rebuild!
        final sw = Stopwatch()..start();
        await coordinator.next();
        sw.stop();

        expect(sw.elapsedMilliseconds, lessThan(200));
        expect(nativeBackend.skipToStandbyEpochs, hasLength(1));
        expect(nativeBackend.playCalls, hasLength(1));
        expect(resolvers.ytm.resolvedKeys, hasLength(1));
        expect(audio.currentState.track?.id, 'ytm:b');
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(coordinator.preparedStandbyTrackId, isNull);

        // Next track deezer:c pre-decodes on ytm:b and flips via direct playTrack(deezer:c).
        await coordinator.seek(const Duration(seconds: 185));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(resolvers.deezer.resolvedKeys, hasLength(1));
        expect(coordinator.preparedStandbyTrackId, 'deezer:c');

        await coordinator.playTrack(queue[2], queueContext: queue);
        expect(nativeBackend.skipToStandbyEpochs, hasLength(2));
        expect(nativeBackend.playCalls, hasLength(1));
        expect(resolvers.deezer.resolvedKeys, hasLength(1));
        expect(audio.currentState.track?.id, 'deezer:c');
        expect(audio.currentState.status, PlaybackStatus.playing);
      },
    );

    test(
      'seamlessly falls back to normal play resolution if skipToStandby returns false',
      () async {
        final audio = MockAudioService();
        final nativeBackend = _SpyNativeDualDeckBackend(audio);
        final bridge = _FakeExternalBridge();
        final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          enableLiveWarmup: false,
        );
        final resolvers = _createResolvers();
        final registry = _buildRegistry(
          qobuz: resolvers.qobuz,
          tidal: resolvers.tidal,
          deezer: resolvers.deezer,
          ytm: resolvers.ytm,
          apple: resolvers.apple,
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolverRegistry: registry,
          nativeBackend: nativeBackend,
          externalBackend: externalBackend,
          debounceDelay: Duration.zero,
          lookaheadDelay: const Duration(seconds: 60),
        );
        addTearDown(() {
          coordinator.dispose();
          manager.dispose();
          externalBackend.dispose();
          nativeBackend.dispose();
          audio.dispose();
        });

        final queue = <TrackInfo>[
          _makeTrack('qobuz:p1', duration: const Duration(seconds: 200)),
          _makeTrack('qobuz:p2', duration: const Duration(seconds: 200)),
        ];

        await coordinator.playTrack(queue[0], queueContext: queue);
        await coordinator.seek(const Duration(seconds: 185));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(coordinator.isStandbyReady, isTrue);

        // Force standby switch to fail (e.g. standby deck invalidated/evicted).
        nativeBackend
          ..overrideSkipResult = true
          ..forceSkipToStandbyResult = false;

        await coordinator.playTrack(queue[1], queueContext: queue);
        expect(nativeBackend.skipToStandbyEpochs, hasLength(1));
        // Falls back cleanly to normal backend.play() using warm L1 spec!
        expect(nativeBackend.playCalls, hasLength(2));
        expect(nativeBackend.playCalls.last.track.id, 'qobuz:p2');
        expect(audio.currentState.track?.id, 'qobuz:p2');
        expect(audio.currentState.status, PlaybackStatus.playing);
      },
    );
  });
}
