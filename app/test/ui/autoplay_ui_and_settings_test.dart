import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/recommendation_settings_controller.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/recommendation_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/mini_player/quick_queue_popover.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/settings/general_settings_panel.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

const AudioFormat _cdFlac = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
);

TrackInfo _userTrack(String id, String title, String artist) => TrackInfo(
  id: id,
  title: title,
  artist: artist,
  album: 'User Album',
  duration: const Duration(minutes: 3, seconds: 30),
  format: _cdFlac,
  providerName: 'YouTube Music',
);

TrackMetadata _autoMeta(String trackId, String title, String artist) =>
    TrackMetadata(
      providerId: 'youtube_music',
      trackId: trackId,
      title: title,
      artist: artist,
      primaryArtist: artist,
      album: 'Radio Album',
      durationMs: 210000,
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
})> _createDualQueueHarness({
  required List<TrackInfo> userTracks,
  required List<TrackMetadata> autoTracks,
  bool allowBackgroundRefill = false,
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
    allowBackgroundRefill: allowBackgroundRefill,
  );
  final coordinator = StreamingPlaybackCoordinator(
    audioService: inner,
    streamingManager: manager,
    autoplayController: autoplay,
  );
  final audio = CoordinatingAudioService(
    inner: inner,
    coordinator: coordinator,
    disposeInner: false,
  );

  if (userTracks.isNotEmpty) {
    autoplay.setUserQueue(
      userTracks,
      currentTrack: userTracks.first,
      currentIndex: 0,
      bumpEpoch: false,
    );
    await autoplay.maybeTriggerRefill(
      seedOverride: TrackMetadata.fromTrackInfo(userTracks.first),
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

  group('QuickQueuePopover dual-segment queue & drag/promote/remove/clear', () {
    testWidgets(
      'displays separated user/auto sections, promotes, removes, clears auto-only, and drag-reorders auto item into userQueue',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final u1 = _userTrack('ytm:user_1', 'User One', 'Artist U1');
        final u2 = _userTrack('ytm:user_2', 'User Two', 'Artist U2');
        final a1 = _autoMeta('auto_1', 'Auto One', 'Artist A1');
        final a2 = _autoMeta('auto_2', 'Auto Two', 'Artist A2');
        final a3 = _autoMeta('auto_3', 'Auto Three', 'Artist A3');

        final harness = await _createDualQueueHarness(
          userTracks: <TrackInfo>[u1, u2],
          autoTracks: <TrackMetadata>[a1, a2, a3],
        );
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
                  onOpenLibrary: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('quick_queue_popover')), findsOneWidget);
        expect(find.text('待播佇列'), findsOneWidget);
        expect(find.text('接下來自動推薦（Autoplay）'), findsOneWidget);
        expect(find.text('播放佇列（5 首）'), findsOneWidget);
        expect(find.byKey(const Key('quick_queue_item_ytm:user_1')), findsOneWidget);
        expect(find.byKey(const Key('quick_queue_item_ytm:user_2')), findsOneWidget);
        expect(find.byKey(const Key('quick_queue_item_ytm:auto_1')), findsOneWidget);
        expect(find.byKey(const Key('quick_queue_item_ytm:auto_2')), findsOneWidget);
        expect(find.byKey(const Key('quick_queue_item_ytm:auto_3')), findsOneWidget);

        // 1. Promote button moves auto_1 into userQueue.
        await tester.tap(
          find.byKey(const Key('btn_promote_auto_track_ytm:auto_1')),
        );
        await tester.pumpAndSettle();
        expect(
          harness.autoplay.userQueue.map((t) => t.id),
          equals(<String>['ytm:user_1', 'ytm:user_2', 'ytm:auto_1']),
        );
        expect(
          harness.autoplay.autoQueue.map((t) => t.id),
          equals(<String>['ytm:auto_2', 'ytm:auto_3']),
        );

        // 2. Drag auto_2 upward onto user_2 -> promotes auto_2 into userQueue.
        final auto2HandleCenter = tester.getCenter(
          find.byKey(const Key('quick_queue_drag_handle_ytm:auto_2')),
        );
        final user2Center = tester.getCenter(
          find.byKey(const Key('quick_queue_item_ytm:user_2')),
        );
        await tester.drag(
          find.byKey(const Key('quick_queue_drag_handle_ytm:auto_2')),
          user2Center - auto2HandleCenter,
        );
        await tester.pumpAndSettle();
        expect(
          harness.autoplay.userQueue.any((t) => t.id == 'ytm:auto_2'),
          isTrue,
        );
        expect(
          harness.autoplay.autoQueue.any((t) => t.id == 'ytm:auto_2'),
          isFalse,
        );

        // 3. Remove single auto_3 track.
        await tester.tap(
          find.byKey(const Key('btn_remove_auto_track_ytm:auto_3')),
        );
        await tester.pumpAndSettle();
        expect(harness.autoplay.autoQueue, isEmpty);

        // 4. Refill auto tracks again, then clear autoQueue ONLY.
        await harness.autoplay.maybeTriggerRefill(
          seedOverride: TrackMetadata.fromTrackInfo(u1),
        );
        await tester.pumpAndSettle();
        expect(harness.autoplay.autoQueue, isNotEmpty);

        await tester.tap(find.byKey(const Key('btn_clear_auto_queue')));
        await tester.pumpAndSettle();
        expect(harness.autoplay.autoQueue, isEmpty);
        expect(harness.autoplay.userQueue.length, equals(4));

        // 5. Refill and toggle Autoplay OFF via popover header toggle button.
        await harness.autoplay.maybeTriggerRefill(
          seedOverride: TrackMetadata.fromTrackInfo(u1),
        );
        await tester.pumpAndSettle();
        expect(harness.autoplay.autoQueue, isNotEmpty);

        await tester.tap(find.byKey(const Key('btn_queue_autoplay_toggle')));
        await tester.pumpAndSettle();
        expect(harness.autoplay.enabled, isFalse);
        expect(harness.settings.autoplayEnabled, isFalse);
        expect(harness.autoplay.autoQueue, isEmpty);
        expect(harness.autoplay.userQueue.length, equals(4));
      },
    );
  });

  group('FloatingCapsuleMiniPlayer Autoplay toggle', () {
    testWidgets(
      'btn_autoplay_toggle turns Autoplay OFF, clears autoQueue immediately without disturbing current track or userQueue, and has zero overflow across widths',
      (WidgetTester tester) async {
        const u1 = TrackInfo(
          id: 'local_user_1',
          title: 'Local User One',
          artist: 'Artist U1',
          album: 'User Album',
          duration: Duration(minutes: 3, seconds: 30),
          format: _cdFlac,
          providerName: 'Local',
          filePath: '/music/local_user_1.flac',
        );
        final u2 = _userTrack('ytm:user_2', 'User Two', 'Artist U2');
        final a1 = _autoMeta('auto_1', 'Auto One', 'Artist A1');
        final a2 = _autoMeta('auto_2', 'Auto Two', 'Artist A2');

        final harness = await _createDualQueueHarness(
          userTracks: <TrackInfo>[u1, u2],
          autoTracks: <TrackMetadata>[a1, a2],
        );
        await harness.inner.play(track: u1);
        addTearDown(() async {
          harness.audio.dispose();
          harness.coordinator.dispose();
          harness.autoplay.dispose();
          harness.settings.dispose();
          await harness.manager.disposeAsync();
          harness.inner.dispose();
        });

        for (final size in const <Size>[
          Size(1280, 800),
          Size(600, 700),
          Size(360, 700),
        ]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: FloatingCapsuleMiniPlayer(
                    audioService: harness.audio,
                    recommendationSettings: harness.settings,
                    showLyrics: false,
                    onToggleLyrics: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('btn_autoplay_toggle')), findsOneWidget);
        }

        // Test toggle OFF on desktop width.
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpAndSettle();

        expect(harness.autoplay.enabled, isTrue);
        expect(harness.autoplay.autoQueue.length, equals(2));
        expect(harness.audio.currentState.status, PlaybackStatus.playing);
        expect(harness.audio.currentState.track?.id, equals('local_user_1'));

        await tester.tap(find.byKey(const Key('btn_autoplay_toggle')));
        await tester.pumpAndSettle();

        expect(harness.autoplay.enabled, isFalse);
        expect(harness.settings.autoplayEnabled, isFalse);
        expect(harness.autoplay.autoQueue, isEmpty);
        expect(
          harness.autoplay.userQueue.map((t) => t.id),
          equals(<String>['local_user_1', 'ytm:user_2']),
        );
        expect(harness.audio.currentState.status, PlaybackStatus.playing);
        expect(harness.audio.currentState.track?.id, equals('local_user_1'));
      },
    );
  });

  group('NowPlayingOverlay dual-segment queue drawer', () {
    testWidgets(
      'shows separated sections and supports promote, remove, clear, and autoplay toggle',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final u1 = _userTrack('ytm:user_1', 'User One', 'Artist U1');
        final a1 = _autoMeta('auto_1', 'Auto One', 'Artist A1');
        final a2 = _autoMeta('auto_2', 'Auto Two', 'Artist A2');
        final a3 = _autoMeta('auto_3', 'Auto Three', 'Artist A3');

        final harness = await _createDualQueueHarness(
          userTracks: <TrackInfo>[u1],
          autoTracks: <TrackMetadata>[a1, a2, a3],
        );
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

        expect(find.byKey(const Key('now_playing_queue_drawer')), findsOneWidget);
        expect(find.text('待播佇列'), findsOneWidget);
        expect(find.text('接下來自動推薦（Autoplay）'), findsOneWidget);
        expect(
          find.byKey(const Key('now_playing_queue_item_ytm:user_1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('now_playing_queue_item_ytm:auto_1')),
          findsOneWidget,
        );

        // Promote auto_1
        await tester.tap(
          find.byKey(const Key('btn_drawer_promote_auto_track_ytm:auto_1')),
        );
        await tester.pumpAndSettle();
        expect(
          harness.autoplay.userQueue.map((t) => t.id),
          equals(<String>['ytm:user_1', 'ytm:auto_1']),
        );

        // Remove auto_2
        await tester.tap(
          find.byKey(const Key('btn_drawer_remove_auto_track_ytm:auto_2')),
        );
        await tester.pumpAndSettle();
        expect(
          harness.autoplay.autoQueue.map((t) => t.id),
          equals(<String>['ytm:auto_3']),
        );

        // Drag auto_3 into userQueue via drawer drag handle
        final drawerAuto3Handle = tester.getCenter(
          find.byKey(const Key('drawer_queue_drag_handle_ytm:auto_3')),
        );
        final drawerUser1 = tester.getCenter(
          find.byKey(const Key('now_playing_queue_item_ytm:user_1')),
        );
        await tester.drag(
          find.byKey(const Key('drawer_queue_drag_handle_ytm:auto_3')),
          drawerUser1 - drawerAuto3Handle,
        );
        await tester.pumpAndSettle();
        expect(
          harness.autoplay.userQueue.any((t) => t.id == 'ytm:auto_3'),
          isTrue,
        );
        expect(harness.autoplay.autoQueue, isEmpty);

        // Refill and clear auto queue
        await harness.autoplay.maybeTriggerRefill(
          seedOverride: TrackMetadata.fromTrackInfo(u1),
        );
        await tester.pumpAndSettle();
        expect(harness.autoplay.autoQueue, isNotEmpty);

        await tester.tap(find.byKey(const Key('btn_drawer_clear_auto_queue')));
        await tester.pumpAndSettle();
        expect(harness.autoplay.autoQueue, isEmpty);
        expect(harness.autoplay.userQueue.length, equals(3));

        // Toggle Autoplay OFF via drawer button
        await tester.tap(find.byKey(const Key('btn_drawer_autoplay_toggle')));
        await tester.pumpAndSettle();
        expect(harness.autoplay.enabled, isFalse);
        expect(harness.settings.autoplayEnabled, isFalse);
      },
    );
  });

  group('GeneralSettingsPanel Autoplay & Recommendation settings', () {
    testWidgets(
      'toggles switches, reorders and resets platform priority, and saves Last.fm API key',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir = Directory.systemTemp.createTempSync('lumina_rec_ui_');
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        final store = MemorySecureCredentialStore();
        final recSettings = RecommendationSettingsController(
          prefsFileOverride: File('${tempDir.path}/rec_prefs.json'),
          credentialStore: store,
        );
        final scaleCtrl = UiScaleController(
          prefsFileOverride: File('${tempDir.path}/ui_prefs.json'),
        );
        final audioService = MockAudioService();
        addTearDown(() {
          recSettings.dispose();
          scaleCtrl.dispose();
          audioService.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: GeneralSettingsPanel(
                audioService: audioService,
                scaleController: scaleCtrl,
                recommendationSettings: recSettings,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('自動推薦與無限接播'), findsOneWidget);

        // 1. Toggle Autoplay
        final autoplaySwitch = find.byKey(const Key('switch_autoplay_enabled'));
        await tester.ensureVisible(autoplaySwitch);
        await tester.tap(autoplaySwitch);
        await tester.pumpAndSettle();
        expect(recSettings.autoplayEnabled, isFalse);

        // 2. Toggle cross-platform routing
        final routingSwitch = find.byKey(
          const Key('switch_cross_platform_routing'),
        );
        await tester.ensureVisible(routingSwitch);
        await tester.tap(routingSwitch);
        await tester.pumpAndSettle();
        expect(recSettings.crossPlatformRoutingEnabled, isFalse);

        // 3. Reorder platform priority (move tidal up above local, then deezer down)
        final upTidal = find.byKey(const Key('btn_priority_up_tidal'));
        await tester.ensureVisible(upTidal);
        await tester.tap(upTidal);
        await tester.pumpAndSettle();
        expect(
          recSettings.platformPriority,
          equals(<String>['tidal', 'local', 'qobuz', 'deezer', 'youtube_music']),
        );

        final downDeezer = find.byKey(const Key('btn_priority_down_deezer'));
        await tester.ensureVisible(downDeezer);
        await tester.tap(downDeezer);
        await tester.pumpAndSettle();
        expect(
          recSettings.platformPriority,
          equals(<String>['tidal', 'local', 'qobuz', 'youtube_music', 'deezer']),
        );

        // Reset priority
        final resetBtn = find.byKey(const Key('btn_priority_reset'));
        await tester.ensureVisible(resetBtn);
        await tester.tap(resetBtn);
        await tester.pumpAndSettle();
        expect(
          recSettings.platformPriority,
          equals(RecommendationSettingsController.defaultPlatformPriority),
        );

        // 4. Toggle ListenBrainz
        final lbSwitch = find.byKey(const Key('switch_listenbrainz_enabled'));
        await tester.ensureVisible(lbSwitch);
        await tester.tap(lbSwitch);
        await tester.pumpAndSettle();
        expect(recSettings.listenBrainzEnabled, isFalse);

        // 5. Save Last.fm API Key
        final keyInput = find.byKey(const Key('input_lastfm_api_key'));
        await tester.ensureVisible(keyInput);
        await tester.enterText(keyInput, 'lfm_secret_key_42');
        await tester.pumpAndSettle();

        final saveBtn = find.byKey(const Key('btn_save_lastfm_api_key'));
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.pumpAndSettle();

        expect(recSettings.lastFmApiKey, equals('lfm_secret_key_42'));
        expect(
          await store.read(
            RecommendationSettingsController.lastFmApiKeyCredentialKey,
          ),
          equals('lfm_secret_key_42'),
        );
      },
    );
  });

  group('HomeScreen end-to-end Autoplay wiring', () {
    testWidgets(
      'syncs mini-player btn_autoplay_toggle with GeneralSettingsPanel switch_autoplay_enabled',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final audioService = MockAudioService();
        final winCtrl = DesktopWindowController(isSupportedOverride: false);
        addTearDown(audioService.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              windowController: winCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Mini player renders Autoplay toggle button without overflow.
        expect(find.byKey(const Key('btn_autoplay_toggle')), findsOneWidget);

        // Open Settings -> GeneralSettingsPanel -> Autoplay switch starts ON.
        await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
        await tester.pumpAndSettle();
        final settingsSwitch = find.byKey(const Key('switch_autoplay_enabled'));
        await tester.ensureVisible(settingsSwitch);
        expect(settingsSwitch, findsOneWidget);
        expect(
          tester.widget<Switch>(
            find.descendant(
              of: settingsSwitch,
              matching: find.byType(Switch),
            ),
          ).value,
          isTrue,
        );

        // Toggle OFF via capsule btn_autoplay_toggle -> Settings switch updates to OFF!
        await tester.tap(find.byKey(const Key('btn_autoplay_toggle')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Switch>(
            find.descendant(
              of: settingsSwitch,
              matching: find.byType(Switch),
            ),
          ).value,
          isFalse,
        );
      },
    );
  });
}
