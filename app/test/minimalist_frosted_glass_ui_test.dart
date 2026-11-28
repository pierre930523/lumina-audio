import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/common/ambient_dynamic_background.dart';
import 'package:lumina_app/ui/common/audio_quality_badge.dart';
import 'package:lumina_app/ui/common/desktop_window_caption.dart';
import 'package:lumina_app/ui/common/frosted_glass_container.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/playback_controls.dart';
import 'package:lumina_app/ui/now_playing/now_playing_layout.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const Set<int> _macOsTrafficLightArgb = <int>{
  0xFFFF5F56,
  0xFFFF5F57,
  0xFFFFBD2E,
  0xFFFEBC2E,
  0xFF27C93F,
  0xFF28C840,
};

class _FiveAlbumMockAudioService extends MockAudioService {
  final String _coverPath;

  _FiveAlbumMockAudioService(this._coverPath);

  static const _albumsList = <CanonicalAlbumSummary>[
    CanonicalAlbumSummary(
      id: 'alb-dsotm',
      title: 'The Dark Side of the Moon',
      artist: 'Pink Floyd',
      year: 1973,
      availableProviders: ['qobuz', 'local'],
    ),
    CanonicalAlbumSummary(
      id: 'alb-wall',
      title: 'The Wall',
      artist: 'Pink Floyd',
      year: 1979,
      availableProviders: ['tidal'],
    ),
    CanonicalAlbumSummary(
      id: 'alb-kind',
      title: 'Kind of Blue',
      artist: 'Miles Davis',
      year: 1959,
      availableProviders: ['qobuz'],
    ),
    CanonicalAlbumSummary(
      id: 'alb-rumours',
      title: 'Rumours',
      artist: 'Fleetwood Mac',
      year: 1977,
      availableProviders: ['local'],
    ),
    CanonicalAlbumSummary(
      id: 'alb-blue',
      title: 'Blue Train',
      artist: 'John Coltrane',
      year: 1958,
      availableProviders: ['tidal'],
    ),
    CanonicalAlbumSummary(
      id: 'alb-abbey',
      title: 'Abbey Road',
      artist: 'The Beatles',
      year: 1969,
      availableProviders: ['local'],
    ),
  ];

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async => _albumsList.take(limit).toList();

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackOrAlbumId, {
    String? path,
    int maxDim = 600,
  }) async {
    return <String, dynamic>{
      'found': true,
      'cache_path': _coverPath,
    };
  }
}

void _assertNoMacOsTrafficLights(WidgetTester tester) {
  for (final container in tester.widgetList<Container>(find.byType(Container))) {
    final dec = container.decoration;
    if (dec is BoxDecoration && dec.shape == BoxShape.circle && dec.color != null) {
      expect(
        _macOsTrafficLightArgb.contains(dec.color!.toARGB32()),
        isFalse,
        reason: 'Forbidden macOS traffic light dot found: ${dec.color}',
      );
    }
  }
  for (final box in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox))) {
    final dec = box.decoration;
    if (dec is BoxDecoration && dec.shape == BoxShape.circle && dec.color != null) {
      expect(
        _macOsTrafficLightArgb.contains(dec.color!.toARGB32()),
        isFalse,
        reason: 'Forbidden macOS traffic light dot found: ${dec.color}',
      );
    }
  }
}

void _assertWindowsCaptionButtonsPresent(WidgetTester tester, {Finder? within}) {
  final scope = within ?? find.byType(HomeScreen);
  expect(
    find.descendant(
      of: scope,
      matching: find.byType(DesktopWindowCaptionButtons),
    ),
    findsOneWidget,
  );
  for (final keyName in const [
    'btn_window_minimize',
    'btn_window_fullscreen',
    'btn_window_maximize',
    'btn_window_close',
  ]) {
    expect(
      find.descendant(of: scope, matching: find.byKey(Key(keyName))),
      findsOneWidget,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String coverFilePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('lumina_frosted_glass_');
    final coverFile = File('${tempDir.path}${Platform.pathSeparator}cover.png')
      ..writeAsBytesSync(_valid1x1Png);
    coverFilePath = coverFile.path;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumina/window'), (
          MethodCall call,
        ) async {
          if (call.method == 'isMaximized' || call.method == 'isFullScreen') {
            return false;
          }
          return null;
        });
  });

  tearDown(() {
    DesktopWindowController.instance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  group('Minimalist Dark Frosted Glass & Ambient Design System', () {
    test(
      'glass text & Gold Hi-Res tokens satisfy WCAG AA contrast against dark glass surfaces',
      () {
        for (final bg in const [
          LuminaTokens.canvasBg,
          LuminaTokens.glassDrawerBg,
          LuminaTokens.glassPlayerBarBg,
        ]) {
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.glassTextPrimary, bg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.glassTextSecondary, bg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.glassTextTertiary, bg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.hiResGoldText, bg),
            greaterThanOrEqualTo(4.5),
          );
        }
      },
    );

    testWidgets(
      'AmbientDynamicBackground renders zero Image widgets and stops all steady-state tickers when idle',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        addTearDown(service.dispose);
        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(scaleCtrl.dispose);
        for (final t in service.queue) {
          cache.setArtworkPathSync(t.id, coverFilePath);
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: service,
              libraryCache: cache,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final ambientFinder = find.byKey(const ValueKey('home_ambient_bg_layer'));
        expect(ambientFinder, findsOneWidget);
        expect(find.byKey(const Key('home_bg_repaint_boundary')), findsOneWidget);
        expect(find.byKey(const Key('home_ambient_bg')), findsOneWidget);

        // Zero Image widgets inside AmbientDynamicBackground (decodes to ui.Image for CustomPaint).
        expect(
          find.descendant(
            of: find.byType(AmbientDynamicBackground),
            matching: find.byType(Image),
          ),
          findsNothing,
        );

        // Zero steady-state animation tickers when idle.
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.hasScheduledFrame, isFalse);

        // Track change animates over 800ms and settles cleanly back to zero scheduled frames.
        await service.play(track: service.queue[1]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);

        // Expanding Now Playing Focus View mounts its ambient background and settles cleanly too.
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('now_playing_bg_repaint_boundary')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('now_playing_ambient_bg')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AmbientDynamicBackground),
            matching: find.byType(Image),
          ),
          findsNothing,
        );
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );

    testWidgets(
      'Home shell has Windows captions (no macOS dots), single-row 5 stat pills, frameless 5-col Recent Activity, Recommended & Recently Played',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        final winCtrl = DesktopWindowController(isSupportedOverride: true);
        final cache = LibraryIndexCache();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(() {
          service.dispose();
          cache.dispose();
          scaleCtrl.dispose();
        });
        final albums = await service.getAlbums();
        for (final alb in albums) {
          cache.putAlbumSummarySync(alb);
          cache.setArtworkPathSync(alb.id, coverFilePath);
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: service,
              libraryCache: cache,
              windowController: winCtrl,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Windows caption buttons present; zero macOS dots.
        _assertWindowsCaptionButtonsPresent(tester);
        _assertNoMacOsTrafficLights(tester);

        // Top-right DSP quick button opens DSP panel cleanly.
        expect(find.byKey(const Key('btn_topbar_dsp')), findsOneWidget);
        await tester.tap(find.byKey(const Key('btn_topbar_dsp')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('dsp_control_panel')), findsOneWidget);
        await tester.tap(find.byKey(const Key('nav_tab_home')));
        await tester.pumpAndSettle();

        // 5-column single-row frosted glass stat pills.
        const statKeys = [
          'stat_card_artists',
          'stat_card_albums',
          'stat_card_tracks',
          'stat_card_zones',
          'stat_card_connection',
        ];
        final statRects = <Rect>[];
        for (final k in statKeys) {
          final finder = find.byKey(Key(k));
          expect(finder, findsOneWidget);
          expect(
            find.descendant(
              of: finder,
              matching: find.byType(FrostedGlassContainer),
            ),
            findsOneWidget,
          );
          statRects.add(tester.getRect(finder));
        }
        for (final r in statRects) {
          expect((r.top - statRects.first.top).abs(), lessThan(1.0));
          expect(r.height, closeTo(44.0, 0.5));
          expect((r.width - statRects.first.width).abs(), lessThan(1.5));
        }

        // 5-column frameless Recent Activity row at 1440x900.
        final activityFinder = find.byKey(const Key('home_recent_activity_card'));
        expect(activityFinder, findsOneWidget);
        final visibleAlbumCards = albums
            .map((a) => find.byKey(Key('home_recent_album_${a.id}')))
            .where((f) => f.evaluate().isNotEmpty)
            .toList();
        expect(visibleAlbumCards.length, 5);
        final firstCardRect = tester.getRect(visibleAlbumCards.first);
        for (final cardFinder in visibleAlbumCards) {
          expect(
            (tester.getRect(cardFinder).top - firstCardRect.top).abs(),
            lessThan(1.0),
          );
        }

        // Lower asymmetric 62:38 section: Recommended left, frameless Recently Played right.
        final recFinder = find.byKey(const Key('home_recommended_section'));
        final queueFinder = find.byKey(const Key('home_quick_queue_card'));
        expect(recFinder, findsOneWidget);
        expect(queueFinder, findsOneWidget);
        final recRect = tester.getRect(recFinder);
        final queueRect = tester.getRect(queueFinder);
        expect(recRect.left, lessThan(queueRect.left));
        expect((recRect.top - queueRect.top).abs(), lessThan(2.0));
        expect(recRect.width, greaterThan(queueRect.width));
        expect(find.byKey(const Key('home_recommended_card_0')), findsOneWidget);
        expect(find.byKey(const Key('home_recommended_card_1')), findsOneWidget);
        expect(find.byKey(const Key('home_recommended_card_2')), findsOneWidget);
        expect(
          find.byKey(Key('home_recent_track_${service.queue.first.id}')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Shared frameless PlaybackControls (Shuffle, Prev, Play/Pause, Next, Repeat), Gold Hi-Res QualityBadge & linear TrackProgressBar',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        service.setSimulatedQuality(SignalQuality.lossless);
        addTearDown(service.dispose);

        await tester.pumpWidget(
          LuminaApp(audioService: service),
        );
        await tester.pumpAndSettle();

        final controlsFinder = find.byType(PlaybackControls);
        expect(controlsFinder, findsOneWidget);
        expect(find.byKey(const Key('btn_shuffle')), findsOneWidget);
        expect(find.byKey(const Key('btn_previous')), findsOneWidget);
        expect(find.byKey(const Key('btn_play_pause')), findsOneWidget);
        expect(find.byKey(const Key('btn_next')), findsOneWidget);
        expect(find.byKey(const Key('btn_repeat')), findsOneWidget);

        // Gold Hi-Res badge inside PlaybackControls, dead-center Play/Pause.
        expect(find.byType(AudioQualityBadge), findsOneWidget);
        expect(find.text('Hi-Res'), findsOneWidget);
        expect(
          find.descendant(
            of: controlsFinder,
            matching: find.byType(AudioQualityBadge),
          ),
          findsOneWidget,
        );
        final capsuleRect =
            tester.getRect(find.byKey(const Key('liquid_glass_capsule')));
        final playCenter =
            tester.getCenter(find.byKey(const Key('btn_play_pause')));
        expect((playCenter.dx - capsuleRect.center.dx).abs(), lessThan(1.0));

        // Linear TrackProgressBar with pure white activeTrackColor.
        final slider = tester.widget<Slider>(
          find.byKey(const Key('track_progress_slider')),
        );
        expect(slider.value, greaterThanOrEqualTo(0.0));
        final sliderTheme = tester.widget<SliderTheme>(
          find.ancestor(
            of: find.byKey(const Key('track_progress_slider')),
            matching: find.byType(SliderTheme),
          ),
        );
        expect(sliderTheme.data.trackHeight, 2.5);
        expect(
          sliderTheme.data.activeTrackColor,
          LuminaTokens.glassTextPrimary,
        );
        expect(
          sliderTheme.data.inactiveTrackColor,
          LuminaTokens.glassTrackUnplayed,
        );

        // Repeat cycle: off -> all -> one (keeps current track on btn_next) -> off.
        await tester.tap(find.byKey(const Key('btn_repeat')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_repeat')));
        await tester.pumpAndSettle();
        final currentTrackId = service.currentState.track!.id;
        await tester.tap(find.byKey(const Key('btn_next')));
        await tester.pumpAndSettle();
        expect(service.currentState.track?.id, currentTrackId);

        // Disable repeat-one and toggle Shuffle; btn_next advances track.
        await tester.tap(find.byKey(const Key('btn_repeat')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_shuffle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_next')));
        await tester.pumpAndSettle();
        expect(service.currentState.track?.id, isNot(currentTrackId));
      },
    );

    testWidgets(
      'Now Playing Focus View, single format capsule, lyrics split toggle, right Queue Drawer & Esc cascade',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        final winCtrl = DesktopWindowController(isSupportedOverride: true);
        final npCtrl = NowPlayingViewController();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(() {
          service.dispose();
          npCtrl.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: service,
              windowController: winCtrl,
              nowPlayingController: npCtrl,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Clicking mini-player cover opens centered Focus View (cover mode).
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
        expect(npCtrl.mode, NowPlayingViewMode.cover);
        expect(find.byKey(const Key('lyrics_list_view')), findsNothing);

        final overlayFinder = find.byKey(const Key('now_playing_overlay'));
        final overlayRect = tester.getRect(overlayFinder);

        // Windows captions present inside Now Playing; zero macOS dots; zero BackdropFilter.
        _assertWindowsCaptionButtonsPresent(
          tester,
          within: find.byType(NowPlayingOverlay),
        );
        _assertNoMacOsTrafficLights(tester);
        expect(
          find.descendant(
            of: find.byType(NowPlayingOverlay),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );

        // Centered hero cover & single format capsule; NO duplicate QualityBadge in metadata.
        final coverFinder = find.byKey(const ValueKey('now_playing_hero_cover_card'));
        expect(coverFinder, findsOneWidget);
        final coverRect = tester.getRect(coverFinder);
        expect((coverRect.center.dx - overlayRect.center.dx).abs(), lessThan(1.0));
        expect(coverRect.width, inInclusiveRange(480.0, 540.0));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('now_playing_hero_metadata')),
            matching: find.text(service.currentState.track!.format.label),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(NowPlayingOverlay),
            matching: find.byType(AudioQualityBadge),
          ),
          findsNothing,
        );
        // Single AudioQualityBadge lives in the shared frameless bottom bar.
        expect(find.byType(AudioQualityBadge), findsOneWidget);

        // '詞' toggles Split Lyrics View <-> Focus View.
        await tester.tap(find.byKey(const Key('btn_toggle_lyrics')));
        await tester.pumpAndSettle();
        expect(npCtrl.mode, NowPlayingViewMode.split);
        expect(find.byKey(const Key('lyrics_list_view')), findsOneWidget);

        await tester.tap(find.byKey(const Key('btn_toggle_lyrics')));
        await tester.pumpAndSettle();
        expect(npCtrl.mode, NowPlayingViewMode.cover);
        expect(find.byKey(const Key('lyrics_list_view')), findsNothing);

        // '歌單' opens right slide-out Queue Drawer; click plays item; Esc closes drawer BEFORE Now Playing.
        await tester.tap(find.byKey(const Key('btn_quick_queue_popover')));
        await tester.pumpAndSettle();
        expect(npCtrl.queueDrawerOpen, isTrue);
        final drawerFinder = find.byKey(const Key('now_playing_queue_drawer'));
        expect(drawerFinder, findsOneWidget);
        final drawerRect = tester.getRect(drawerFinder);
        expect(drawerRect.right, greaterThan(overlayRect.center.dx));

        final targetTrack = service.queue[1];
        await tester.tap(find.byKey(Key('now_playing_queue_item_${targetTrack.id}')));
        await tester.pumpAndSettle();
        expect(service.currentState.track?.id, targetTrack.id);

        // First Esc closes Queue Drawer while keeping Now Playing open.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(npCtrl.queueDrawerOpen, isFalse);
        expect(find.byKey(const Key('now_playing_queue_drawer')), findsNothing);
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

        // Second Esc collapses Now Playing back to Home.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
        expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
      },
    );

    testWidgets(
      'Zero overflow across 1280x800, 1440x900, 1920x1080, 800x600 at 100% and 150% UI scale',
      (tester) async {
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(() {
          service.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(
            audioService: service,
            uiScaleController: scaleCtrl,
          ),
        );
        await tester.pumpAndSettle();

        const sizes = <Size>[
          Size(1280, 800),
          Size(1440, 900),
          Size(1920, 1080),
          Size(800, 600),
        ];

        for (final scale in const [1.0, 1.5]) {
          scaleCtrl.setScale(scale);
          for (final sz in sizes) {
            tester.view.devicePixelRatio = 1.0;
            tester.view.physicalSize = sz;
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Home overflow at ${sz.width}x${sz.height} @ ${scale}x',
            );

            // Open Focus View
            await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason:
                  'Focus View overflow at ${sz.width}x${sz.height} @ ${scale}x',
            );

            // Toggle Split Lyrics
            await tester.tap(find.byKey(const Key('btn_now_playing_mode_split')));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason:
                  'Split View overflow at ${sz.width}x${sz.height} @ ${scale}x',
            );

            // Open Queue Drawer
            await tester.tap(find.byKey(const Key('btn_now_playing_queue')));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('now_playing_queue_drawer')),
              findsOneWidget,
            );
            expect(
              tester.takeException(),
              isNull,
              reason:
                  'Queue Drawer overflow at ${sz.width}x${sz.height} @ ${scale}x',
            );

            // Close Queue Drawer and collapse Now Playing
            await tester.tap(find.byKey(const Key('btn_close_now_playing_queue')));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason:
                  'Collapse overflow at ${sz.width}x${sz.height} @ ${scale}x',
            );
          }
        }
      },
    );

    testWidgets(
      'Now Playing enlarged responsive cover targets (1280x720..2560x1440), BoxFit.cover, responsive radius/typography, and zero idle tickers',
      (tester) async {
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        final npCtrl = NowPlayingViewController()
          ..setMode(NowPlayingViewMode.cover);
        addTearDown(() {
          service.dispose();
          npCtrl.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: service,
                controller: npCtrl,
                bottomClearance: 99.0,
                hasHostControls: true,
                onCollapse: () {},
              ),
            ),
          ),
        );

        final cases = <(Size, double, double, double)>[
          // (viewport, expectedCover, expectedTitleFont, expectedRadius)
          (const Size(1280, 720), 403.0, 22.0, 14.0),
          (const Size(1280, 800), 448.0, 22.4, 14.4),
          (const Size(1440, 900), 504.0, 25.2, 16.2),
          (const Size(1920, 1080), 604.0, 30.24, 19.44),
          (const Size(2560, 1440), 640.0, 34.0, 22.0),
        ];

        for (final (vp, expectedCover, expectedTitle, expectedRadius)
            in cases) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = vp;
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'Cover overflow at ${vp.width}x${vp.height}',
          );

          final metrics = NowPlayingLayoutMetrics.compute(
            width: vp.width,
            height: vp.height - 48.0 - 99.0,
            mode: NowPlayingViewMode.cover,
            viewportWidth: vp.width,
            viewportHeight: vp.height,
          );
          expect(metrics.coverSide, closeTo(expectedCover, 1.0));
          expect(metrics.titleFontSize, closeTo(expectedTitle, 0.05));
          expect(metrics.coverBorderRadius, closeTo(expectedRadius, 0.05));
          expect(
            metrics.gap,
            closeTo((vp.height * 0.025).clamp(16.0, 28.0), 0.05),
          );

          final coverFinder = find.byKey(
            const ValueKey('now_playing_hero_cover_card'),
          );
          expect(coverFinder, findsOneWidget);
          final coverRect = tester.getRect(coverFinder);
          expect(coverRect.width, closeTo(expectedCover, 1.0));
          expect(coverRect.height, closeTo(coverRect.width, 0.5));

          final artworkWidget = tester.widget<AlbumArtworkView>(
            find.descendant(
              of: coverFinder,
              matching: find.byType(AlbumArtworkView),
            ),
          );
          expect(artworkWidget.fit, BoxFit.cover);
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(BackdropFilter),
            ),
            findsNothing,
          );
        }

        // Resize animation settles with zero ongoing idle tickers.
        await tester.pump(const Duration(seconds: 1));
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );

    testWidgets(
      'Now Playing Split mode keeps zero cover-lyrics horizontal overlap at 700x700, 900x800, 1280x800, and 1920x1080',
      (tester) async {
        addTearDown(tester.view.reset);

        final service = _FiveAlbumMockAudioService(coverFilePath);
        final npCtrl = NowPlayingViewController()
          ..setMode(NowPlayingViewMode.split);
        addTearDown(() {
          service.dispose();
          npCtrl.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: service,
                controller: npCtrl,
                bottomClearance: 99.0,
                hasHostControls: true,
                onCollapse: () {},
              ),
            ),
          ),
        );

        for (final vp in const <Size>[
          Size(700, 700),
          Size(900, 800),
          Size(1280, 800),
          Size(1920, 1080),
        ]) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = vp;
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: 'Split overflow at ${vp.width}x${vp.height}',
          );

          final coverRect = tester.getRect(
            find.byKey(const ValueKey('now_playing_hero_cover_card')),
          );
          final lyricsRect = tester.getRect(
            find.byKey(const Key('now_playing_lyrics_repaint_boundary')),
          );
          expect(
            coverRect.right,
            lessThanOrEqualTo(lyricsRect.left - 16.0),
            reason:
                'Split cover overlapped lyrics at ${vp.width}x${vp.height}: '
                'coverRight=${coverRect.right}, lyricsLeft=${lyricsRect.left}',
          );
          expect(
            coverRect.left,
            greaterThanOrEqualTo(12.0),
            reason:
                'Split cover clipped left edge at ${vp.width}x${vp.height}',
          );
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(BackdropFilter),
            ),
            findsNothing,
          );
        }
      },
    );
  });
}
