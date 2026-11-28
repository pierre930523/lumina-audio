import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/home_dashboard_data_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/artists/artists_view.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/folders/folders_view.dart';
import 'package:lumina_app/ui/home/widgets/minimal_album_card.dart';
import 'package:lumina_app/ui/home/widgets/minimal_album_row.dart';
import 'package:lumina_app/ui/home/widgets/top_ambient_aura.dart';
import 'package:lumina_app/ui/home_shell/home_layout_wireframe.dart';
import 'package:lumina_app/ui/library/library_browser_view.dart';
import 'package:lumina_app/ui/listen_later/listen_later_view.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/playlists/smart_playlists_view.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/tags/tags_view.dart';
import 'package:lumina_app/ui/theme/lumina_glass_theme.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

part 'home_layout_presets_morph_and_polish.dart';
part 'home_layout_presets_nav_responsive.dart';

class _InstrumentedMockAudioService extends MockAudioService {
  int getAlbumsCalls = 0;
  int listProfilesCalls = 0;
  int listZonesCalls = 0;
  int playCalls = 0;
  int stopCalls = 0;

  void resetCounts() {
    getAlbumsCalls = 0;
    listProfilesCalls = 0;
    listZonesCalls = 0;
    playCalls = 0;
    stopCalls = 0;
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) {
    getAlbumsCalls++;
    return super.getAlbums(limit: limit, includeHidden: includeHidden);
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() {
    listProfilesCalls++;
    return super.listProfiles();
  }

  @override
  Future<List<AudioZoneInfo>> listZones() {
    listZonesCalls++;
    return super.listZones();
  }

  @override
  Future<void> play({TrackInfo? track}) {
    playCalls++;
    return super.play(track: track);
  }

  @override
  Future<void> stop() {
    stopCalls++;
    return super.stop();
  }
}

void _setupMockWindowChannel(WidgetTester tester) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('lumina/window'), (
        MethodCall call,
      ) async {
        if (call.method == 'isMaximized' || call.method == 'isFullScreen') {
          return false;
        }
        return null;
      });
  DesktopWindowController.instance = DesktopWindowController(
    isSupportedOverride: true,
  );
  addTearDown(() {
    DesktopWindowController.instance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
  });
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. Persistence & Zero-FOUC Restoration', () {
    late Directory tempDir;
    late File prefsFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lumina_preset_prefs_');
      prefsFile = File('${tempDir.path}${Platform.pathSeparator}ui_prefs.json');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test(
      'persists homeLayoutPreset, migrates legacy frosted-minimal/invalid to aura-quick-resume on disk, and restores via loadSync & load',
      () async {
        final ctrl = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(ctrl.dispose);
        expect(ctrl.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);
        expect(ctrl.themeMode, ThemeMode.dark);
        expect(ctrl.auraFollowCover, isTrue);
        expect(ctrl.minimalCoverMode, isFalse);

        for (final preset in const [
          HomeLayoutPreset.topbarMinimal,
          HomeLayoutPreset.classic,
          HomeLayoutPreset.auraQuickResume,
        ]) {
          ctrl.setHomeLayoutPreset(preset);
          final raw = jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>;
          expect(raw['homeLayoutPreset'], preset.storageKey);
        }
        ctrl
          ..setHomeLayoutPreset(HomeLayoutPreset.auraQuickResume)
          ..setThemeMode(ThemeMode.light)
          ..setAuraFollowCover(false)
          ..setMinimalCoverMode(true);

        final syncCtrl = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(syncCtrl.dispose);
        syncCtrl.loadSync();
        expect(syncCtrl.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);
        expect(syncCtrl.themeMode, ThemeMode.light);
        expect(syncCtrl.auraFollowCover, isFalse);
        expect(syncCtrl.minimalCoverMode, isTrue);

        final asyncCtrl = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(asyncCtrl.dispose);
        await asyncCtrl.load();
        expect(asyncCtrl.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);
        expect(asyncCtrl.themeMode, ThemeMode.light);
        expect(asyncCtrl.auraFollowCover, isFalse);
        expect(asyncCtrl.minimalCoverMode, isTrue);

        // Migration guard: legacy 'frosted-minimal' falls back to AJ and writes back.
        prefsFile.writeAsStringSync(jsonEncode({
          'homeLayoutPreset': 'frosted-minimal',
          'themeMode': 'dark',
        }));
        final migratedSync = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(migratedSync.dispose);
        migratedSync.loadSync();
        expect(migratedSync.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);
        expect(
          (jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>)['homeLayoutPreset'],
          'aura-quick-resume',
        );

        prefsFile.writeAsStringSync(jsonEncode({
          'home_layout_preset': 'removed-preset',
          'theme_mode': 'light',
        }));
        final migratedAsync = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(migratedAsync.dispose);
        await migratedAsync.load();
        expect(migratedAsync.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);
        expect(
          (jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>)['homeLayoutPreset'],
          'aura-quick-resume',
        );

        // Verify snake_case fallbacks and corrupt tolerance.
        prefsFile.writeAsStringSync(jsonEncode({
          'home_layout_preset': 'topbar-minimal',
          'theme_mode': 'light',
          'aura_follow_cover': false,
          'minimal_cover_mode': true,
        }));
        final snakeCtrl = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(snakeCtrl.dispose);
        snakeCtrl.loadSync();
        expect(snakeCtrl.homeLayoutPreset, HomeLayoutPreset.topbarMinimal);
        expect(snakeCtrl.themeMode, ThemeMode.light);
        expect(snakeCtrl.auraFollowCover, isFalse);
        expect(snakeCtrl.minimalCoverMode, isTrue);

        prefsFile.writeAsStringSync('{corrupt');
        final corruptCtrl = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(corruptCtrl.dispose);
        corruptCtrl.loadSync();
        expect(corruptCtrl.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);
      },
    );

    testWidgets(
      'zero-FOUC startup applies persisted preset & light theme on frame 0',
      (tester) async {
        _setupMockWindowChannel(tester);
        _setViewport(tester, const Size(1280, 800));
        addTearDown(tester.view.reset);

        prefsFile.writeAsStringSync(jsonEncode({
          'scale': 1.0,
          'homeLayoutPreset': 'topbar-minimal',
          'themeMode': 'light',
          'auraFollowCover': false,
          'minimalCoverMode': true,
        }));

        final svc = MockAudioService();
        final ctrl = UiScaleController(prefsFileOverride: prefsFile);
        addTearDown(() {
          svc.dispose();
          ctrl.dispose();
        });

        await tester.pumpWidget(LuminaApp(audioService: svc, uiScaleController: ctrl));
        await tester.pump(); // Frame 0 immediately after initState's loadSync()

        expect(find.byKey(const Key('home_layout_ai')), findsOneWidget);
        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.themeMode, ThemeMode.light);
        await tester.pumpAndSettle();
      },
    );
  });

  group('2 & 3 & 4. Live Switching, Shared Data Controller & Playback Continuity', () {
    test('HomeDashboardDataController single-flight ensures no duplicate API calls', () async {
      final svc = _InstrumentedMockAudioService();
      addTearDown(svc.dispose);
      final ctrl = HomeDashboardDataController(audioService: svc);
      addTearDown(ctrl.dispose);

      await Future.wait([ctrl.ensureLoaded(), ctrl.ensureLoaded()]);
      expect(svc.getAlbumsCalls, 1);
      expect(svc.listProfilesCalls, 1);
      expect(svc.listZonesCalls, 1);

      await ctrl.ensureLoaded();
      ctrl.reshuffleDiscovery();
      expect(svc.getAlbumsCalls, 1);
      expect(svc.listProfilesCalls, 1);
      expect(svc.listZonesCalls, 1);
    });

    testWidgets(
      'Switcher popover & Appearance settings switch AF/AI/AJ/Classic live with zero duplicate queries or playback drop',
      (tester) async {
        _setupMockWindowChannel(tester);
        _setViewport(tester, const Size(1440, 900));
        addTearDown(tester.view.reset);

        final svc = _InstrumentedMockAudioService();
        final scaleCtrl = UiScaleController();
        addTearDown(() {
          svc.dispose();
          scaleCtrl.dispose();
        });

        await svc.play(track: svc.queue.first);
        await svc.seek(const Duration(seconds: 42));

        await tester.pumpWidget(LuminaApp(audioService: svc, uiScaleController: scaleCtrl));
        await tester.pumpAndSettle();

        // Default preset is AJ (AF has been completely removed).
        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);
        expect(find.byKey(const Key('aj_top_ambient_aura')), findsOneWidget);
        expect(find.byKey(const Key('aj_quick_resume_grid')), findsOneWidget);
        expect(find.byKey(const Key('aj_explore_row')), findsOneWidget);
        expect(find.byKey(const Key('home_layout_af')), findsNothing);

        final miniState = tester.state<State<FloatingCapsuleMiniPlayer>>(
          find.byType(FloatingCapsuleMiniPlayer),
        );
        svc.resetCounts();

        // Open switcher popover and verify 3 wireframe previews (no AF).
        await tester.tap(find.byKey(const Key('btn_home_layout_switcher')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_layout_switcher_popover')), findsOneWidget);
        expect(find.byKey(const Key('layout_option_frosted_minimal')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('home_layout_switcher_popover')),
            matching: find.byType(HomeLayoutWireframe),
          ),
          findsNWidgets(3),
        );

        // AJ -> AI -> AJ -> Classic -> AJ via switcher popover (shared HomeDashboardDataController)
        await tester.tap(find.byKey(const Key('layout_option_topbar_minimal')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_layout_ai')), findsOneWidget);
        expect(find.byKey(const Key('ai_segment_bar')), findsOneWidget);
        expect(find.byKey(const Key('ai_album_wall')), findsOneWidget);

        await tester.tap(find.byKey(const Key('layout_option_aura_quick_resume')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);

        // Zero duplicate API fetches across AJ -> AI -> AJ
        expect(svc.getAlbumsCalls, 0);
        expect(svc.listProfilesCalls, 0);
        expect(svc.listZonesCalls, 0);

        // Also switch through Classic and back to AJ and verify zero playback drop
        await tester.tap(find.byKey(const Key('layout_option_classic')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);

        await tester.tap(find.byKey(const Key('layout_option_aura_quick_resume')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);

        // Zero playback interruption across layout switches
        expect(svc.playCalls, 0);
        expect(svc.stopCalls, 0);
        expect(svc.currentState.status, PlaybackStatus.playing);
        expect(svc.currentState.track?.id, svc.queue.first.id);
        expect(svc.currentState.position, const Duration(seconds: 42));
        expect(
          identical(
            tester.state<State<FloatingCapsuleMiniPlayer>>(
              find.byType(FloatingCapsuleMiniPlayer),
            ),
            miniState,
          ),
          isTrue,
        );

        // Navigate from popover to Appearance settings & verify switch sync and no AF option.
        await tester.tap(find.byKey(const Key('switcher_switch_aura_follow_cover')));
        await tester.tap(find.byKey(const Key('switcher_switch_minimal_cover_mode')));
        await tester.tap(find.byKey(const Key('btn_switcher_open_appearance')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('settings_layout_option_frosted_minimal')),
          findsNothing,
        );

        expect(find.byKey(const Key('appearance_scale_panel')), findsOneWidget);
        expect(scaleCtrl.auraFollowCover, isFalse);
        expect(scaleCtrl.minimalCoverMode, isTrue);

        final auraSwitch = find.byKey(const Key('switch_aura_follow_cover'));
        await tester.ensureVisible(auraSwitch);
        await tester.tap(auraSwitch);
        await tester.pumpAndSettle();
        expect(scaleCtrl.auraFollowCover, isTrue);

        final minSwitch = find.byKey(const Key('switch_minimal_cover_mode'));
        await tester.ensureVisible(minSwitch);
        await tester.tap(minSwitch);
        await tester.pumpAndSettle();
        expect(scaleCtrl.minimalCoverMode, isFalse);

        await tester.ensureVisible(
          find.byKey(const Key('settings_layout_option_aura_quick_resume')),
        );
        await tester.tap(
          find.byKey(const Key('settings_layout_option_aura_quick_resume')),
        );
        await tester.pumpAndSettle();
        expect(scaleCtrl.homeLayoutPreset, HomeLayoutPreset.auraQuickResume);

        await tester.tap(find.byKey(const Key('capsule_nav_home')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);
      },
    );
  });

  _registerNavAndResponsivePresetTests();
  _registerMorphAndPolishPresetTests();
}
