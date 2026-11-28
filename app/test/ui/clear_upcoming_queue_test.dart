import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/protocol/protocol_models.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/playback/mock_playback_backend.dart';
import 'package:lumina_app/services/playback/playback_controller.dart';
import 'package:lumina_app/services/recommendation_settings_controller.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/recommendation_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/ui/mini_player/quick_queue_popover.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

const AudioFormat _cdFlac = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
);

TrackInfo _localTrack(String id, String title) => TrackInfo(
  id: id,
  title: title,
  artist: 'Artist $id',
  album: 'Album $id',
  duration: const Duration(minutes: 3),
  format: _cdFlac,
  providerName: 'Local Library',
  filePath: '/music/$id.flac',
);

TrackInfo _ytmTrack(String id, String title) => TrackInfo(
  id: id,
  title: title,
  artist: 'Artist $id',
  album: 'YTM Album',
  duration: const Duration(minutes: 3),
  format: _cdFlac,
  providerName: 'YouTube Music',
);

TrackMetadata _autoMeta(String trackId, String title) => TrackMetadata(
  providerId: 'youtube_music',
  trackId: trackId,
  title: title,
  artist: 'Radio Artist $trackId',
  primaryArtist: 'Radio Artist $trackId',
  album: 'Radio Album $trackId',
  durationMs: 180000,
  format: _cdFlac,
  providerName: 'YouTube Music',
);

class _FakeRadioProvider implements RecommendationProvider {
  final List<TrackMetadata> candidates;
  _FakeRadioProvider(this.candidates);

  @override
  String get recommendationProviderId => 'youtube_music';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.youtubeMusic;

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    return RadioPage(
      tracks: candidates.take(limit).toList(growable: false),
      sourceLabel: 'Fake Radio',
    );
  }

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async => const <FeedSection>[];

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async => null;
}

Future<({
  MockAudioService inner,
  StreamingManager manager,
  RecommendationSettingsController settings,
  AutoplayController autoplay,
  StreamingPlaybackCoordinator coordinator,
  CoordinatingAudioService audio,
})> _createDualHarness({
  required List<TrackInfo> userTracks,
  required int currentIndex,
  required List<TrackMetadata> autoTracks,
}) async {
  final inner = MockAudioService();
  final store = MemorySecureCredentialStore();
  final manager = StreamingManager(
    credentialStore: store,
    enableLiveWarmup: false,
  );
  final settings = RecommendationSettingsController(credentialStore: store);
  final radio = _FakeRadioProvider(autoTracks);
  final autoplay = AutoplayController(
    providerLookup: (pid) => pid == 'youtube_music' ? radio : null,
    settings: settings,
    allowBackgroundRefill: false,
  );
  final coordinator = StreamingPlaybackCoordinator(
    audioService: inner,
    streamingManager: manager,
    autoplayController: autoplay,
    debounceDelay: Duration.zero,
  );
  final audio = CoordinatingAudioService(
    inner: inner,
    coordinator: coordinator,
    disposeInner: false,
  );

  if (userTracks.isNotEmpty) {
    final active = userTracks[currentIndex];
    autoplay.setUserQueue(
      userTracks,
      currentTrack: active,
      currentIndex: currentIndex,
      bumpEpoch: false,
    );
    await autoplay.maybeTriggerRefill(
      seedOverride: TrackMetadata.fromTrackInfo(active),
    );
  }

  return (
    inner: inner,
    manager: manager,
    settings: settings,
    autoplay: autoplay,
    coordinator: coordinator,
    audio: audio,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ClearUpcomingQueue & enqueueTracks(playNext:) unit tests', () {
    test('AutoplayController.clearUpcoming preserves history & current track, clears user upcoming and autoQueue', () async {
      final t1 = _ytmTrack('ytm:u1', 'History 1');
      final t2 = _ytmTrack('ytm:u2', 'Current 2');
      final t3 = _ytmTrack('ytm:u3', 'Upcoming 3');
      final ap = AutoplayController(
        providerLookup: (pid) => pid == 'youtube_music'
            ? _FakeRadioProvider(<TrackMetadata>[
                _autoMeta('a1', 'Auto 1'),
                _autoMeta('a2', 'Auto 2'),
              ])
            : null,
        allowBackgroundRefill: false,
      );
      addTearDown(ap.dispose);

      ap.setUserQueue([t1, t2, t3], currentTrack: t2, currentIndex: 1, bumpEpoch: false);
      await ap.maybeTriggerRefill(seedOverride: TrackMetadata.fromTrackInfo(t2));
      expect(ap.userQueue.length, 3);
      expect(ap.autoQueue.length, 2);
      expect(ap.totalRemainingCount, 3);

      // Insert with playNext: true lands directly after t2 (at index 2)
      final addedNext = ap.appendToUserQueue([_ytmTrack('ytm:u_next', 'Play Next')], playNext: true);
      expect(addedNext, 1);
      expect(ap.userQueue.map((t) => t.id), ['ytm:u1', 'ytm:u2', 'ytm:u_next', 'ytm:u3']);

      final cleared = ap.clearUpcoming();
      expect(cleared, 4);
      expect(ap.userQueue.map((t) => t.id), ['ytm:u1', 'ytm:u2']);
      expect(ap.autoQueue, isEmpty);
      expect(ap.currentTrack?.id, 'ytm:u2');
      expect(ap.totalRemainingCount, 0);

      // Idempotent second call returns 0
      expect(ap.clearUpcoming(), 0);
    });

    test('MockAudioService & CoordinatingAudioService clearUpcomingQueue keep active playback running and history intact', () async {
      final t1 = _localTrack('loc-1', 'History');
      final t2 = _localTrack('loc-2', 'Playing');
      final t3 = _localTrack('loc-3', 'Upcoming');

      final harness = await _createDualHarness(
        userTracks: [t1, t2, t3],
        currentIndex: 1,
        autoTracks: [_autoMeta('a1', 'Auto 1'), _autoMeta('a2', 'Auto 2')],
      );
      addTearDown(() async {
        harness.audio.dispose();
        harness.coordinator.dispose();
        harness.autoplay.dispose();
        harness.settings.dispose();
        await harness.manager.disposeAsync();
        harness.inner.dispose();
      });

      await harness.inner.play(track: t2);
      expect(harness.audio.currentState.status, PlaybackStatus.playing);
      expect(harness.audio.currentState.track?.id, 'loc-2');

      final cleared = await harness.audio.clearUpcomingQueue();
      expect(cleared, 3);
      expect(harness.audio.currentState.status, PlaybackStatus.playing);
      expect(harness.audio.currentState.track?.id, 'loc-2');
      expect(harness.autoplay.userQueue.map((t) => t.id), ['loc-1', 'loc-2']);
      expect(harness.autoplay.autoQueue, isEmpty);
      expect(harness.audio.queue.map((t) => t.id), ['loc-1', 'loc-2']);

      // Legacy MockAudioService direct test (playNext + clearUpcomingQueue)
      final mock = MockAudioService();
      addTearDown(mock.dispose);
      await mock.playQueue([t1, t2, t3], startIndex: 1);
      final inserted = await mock.enqueueTracks([_localTrack('loc-next', 'Next')], playNext: true);
      expect(inserted, 1);
      expect(mock.queue.map((t) => t.id), ['loc-1', 'loc-2', 'loc-next', 'loc-3']);

      final mockCleared = await mock.clearUpcomingQueue();
      expect(mockCleared, 2);
      expect(mock.currentState.status, PlaybackStatus.playing);
      expect(mock.currentState.track?.id, 'loc-2');
      expect(mock.queue.map((t) => t.id), ['loc-1', 'loc-2']);
    });

    test('PlaybackController + MockPlaybackBackend clearUpcomingQueue preserves playing state and history', () async {
      final backend = MockPlaybackBackend();
      final ctrl = PlaybackController(
        backend: backend,
        enableAutoTicker: false,
      );
      addTearDown(() async {
        await ctrl.dispose();
        await backend.dispose();
      });

      final tracks = [
        ProtocolTrackMetadata.fromTrackInfo(_localTrack('t1', 'First')),
        ProtocolTrackMetadata.fromTrackInfo(_localTrack('t2', 'Second')),
        ProtocolTrackMetadata.fromTrackInfo(_localTrack('t3', 'Third')),
      ];
      await ctrl.loadQueue(tracks, startIndex: 1, autoPlay: true);
      expect(ctrl.currentState.status, PlaybackLifecycleState.playing);
      expect(ctrl.currentState.track?.trackId, 't2');
      expect(ctrl.currentQueue.currentIndex, 1);
      expect(ctrl.currentQueue.items.length, 3);

      final res = await ctrl.clearUpcomingQueue();
      expect(res.isOk, isTrue);
      expect(ctrl.currentState.status, PlaybackLifecycleState.playing);
      expect(ctrl.currentState.track?.trackId, 't2');
      expect(ctrl.currentQueue.currentIndex, 1);
      expect(
        ctrl.currentQueue.items.map((i) => i.track.trackId),
        ['t1', 't2'],
      );
    });
  });

  group('Clear Upcoming Queue UI widgets (QuickQueuePopover & NowPlayingDrawer)', () {
    testWidgets(
      'QuickQueuePopover (Dual): clears upcoming tracks, preserves playing & history, disables button at 0, shows toast',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final u1 = _localTrack('loc-u1', 'History One');
        final u2 = _localTrack('loc-u2', 'Playing Two');
        final u3 = _localTrack('loc-u3', 'Upcoming Three');
        final harness = await _createDualHarness(
          userTracks: [u1, u2, u3],
          currentIndex: 1,
          autoTracks: [_autoMeta('a1', 'Auto One'), _autoMeta('a2', 'Auto Two')],
        );
        await harness.inner.play(track: u2);
        addTearDown(() async {
          harness.audio.dispose();
          harness.coordinator.dispose();
          harness.autoplay.dispose();
          harness.settings.dispose();
          await harness.manager.disposeAsync();
          harness.inner.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Center(
                child: QuickQueuePopover(
                  audioService: harness.audio,
                  recommendationSettings: harness.settings,
                  onClose: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final btnFinder = find.byKey(const Key('btn_clear_upcoming_queue'));
        expect(btnFinder, findsOneWidget);
        expect(find.text('清除即將播放'), findsOneWidget);
        expect(tester.widget<TextButton>(btnFinder).onPressed, isNotNull);

        await tester.tap(btnFinder);
        await tester.pumpAndSettle();

        expect(find.text('已清除 3 首即將播放的歌曲'), findsOneWidget);
        expect(tester.widget<TextButton>(btnFinder).onPressed, isNull);
        expect(harness.audio.currentState.status, PlaybackStatus.playing);
        expect(harness.audio.currentState.track?.id, 'loc-u2');
        expect(harness.autoplay.userQueue.map((t) => t.id), ['loc-u1', 'loc-u2']);
        expect(harness.autoplay.autoQueue, isEmpty);
      },
    );

    testWidgets(
      'QuickQueuePopover (Legacy): clears upcoming tracks, disables button when upcoming == 0, shows toast',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final mock = MockAudioService();
        addTearDown(mock.dispose);
        final t1 = _localTrack('leg-1', 'Leg One');
        final t2 = _localTrack('leg-2', 'Leg Two');
        final t3 = _localTrack('leg-3', 'Leg Three');
        await mock.playQueue([t1, t2, t3], startIndex: 1);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Center(
                child: QuickQueuePopover(
                  audioService: mock,
                  onClose: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final btnFinder = find.byKey(const Key('btn_clear_upcoming_queue'));
        expect(btnFinder, findsOneWidget);
        expect(tester.widget<TextButton>(btnFinder).onPressed, isNotNull);

        await tester.tap(btnFinder);
        await tester.pumpAndSettle();

        expect(find.text('已清除 1 首即將播放的歌曲'), findsOneWidget);
        expect(tester.widget<TextButton>(btnFinder).onPressed, isNull);
        expect(mock.queue.map((t) => t.id), ['leg-1', 'leg-2']);
        expect(mock.currentState.track?.id, 'leg-2');
      },
    );

    testWidgets(
      'NowPlayingQueueDrawer: clears upcoming tracks via drawer button, disables button, shows toast',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final u1 = _localTrack('np-u1', 'NP History');
        final u2 = _localTrack('np-u2', 'NP Playing');
        final u3 = _localTrack('np-u3', 'NP Upcoming');
        final harness = await _createDualHarness(
          userTracks: [u1, u2, u3],
          currentIndex: 1,
          autoTracks: [_autoMeta('np-a1', 'NP Auto 1')],
        );
        await harness.inner.play(track: u2);
        final npCtrl = NowPlayingViewController()..setQueueDrawerOpen(true);
        addTearDown(() async {
          npCtrl.dispose();
          harness.audio.dispose();
          harness.coordinator.dispose();
          harness.autoplay.dispose();
          harness.settings.dispose();
          await harness.manager.disposeAsync();
          harness.inner.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: harness.audio,
                controller: npCtrl,
                recommendationSettings: harness.settings,
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final btnFinder = find.byKey(const Key('btn_drawer_clear_upcoming_queue'));
        expect(btnFinder, findsOneWidget);
        expect(tester.widget<TextButton>(btnFinder).onPressed, isNotNull);

        await tester.tap(btnFinder);
        await tester.pumpAndSettle();

        expect(find.text('已清除 2 首即將播放的歌曲'), findsOneWidget);
        expect(tester.widget<TextButton>(btnFinder).onPressed, isNull);
        expect(harness.audio.currentState.status, PlaybackStatus.playing);
        expect(harness.audio.currentState.track?.id, 'np-u2');
        expect(harness.autoplay.userQueue.map((t) => t.id), ['np-u1', 'np-u2']);
        expect(harness.autoplay.autoQueue, isEmpty);
      },
    );
  });
}
