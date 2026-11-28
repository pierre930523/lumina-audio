import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/lyric.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/lyrics/lyrics_view.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 2: Now Playing Open/Close Frame Stability & Jank Elimination', () {
    testWidgets(
      'Workspace RepaintBoundary & FloatingCapsuleMiniPlayer State remain identical across closed -> opening -> opened -> closing -> closed; FFT gates on AnimationStatus.completed; zero BackdropFilter',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(scaleCtrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Closed state baseline
        expect(find.byType(FloatingCapsuleMiniPlayer), findsOneWidget);
        expect(find.byKey(const Key('now_playing_stage')), findsNothing);
        expect(audioService.nowPlayingVisible, isFalse);

        final workspaceBoundaryFinder = find.byKey(
          const Key('workspace_repaint_boundary'),
        );
        expect(workspaceBoundaryFinder, findsOneWidget);
        final initialWorkspaceElement = tester.element(workspaceBoundaryFinder);
        final initialWorkspaceRenderObj =
            tester.renderObject(workspaceBoundaryFinder) as RenderRepaintBoundary;
        final initialMiniPlayerState = tester.state(
          find.byType(FloatingCapsuleMiniPlayer),
        );

        // 1. Trigger open in Split Lyrics mode -> frame 1 + 140ms (mid-open of 280ms transition)
        await tester.tap(find.byKey(const Key('btn_toggle_lyrics')));
        await tester.pump();

        // Zero outer FadeTransition wrapping NowPlayingOverlay (eliminates full-screen saveLayer & bleed-through).
        final nowPlayingLayerFinder = find.byKey(
          const ValueKey('home_now_playing_layer'),
        );
        expect(nowPlayingLayerFinder, findsOneWidget);
        final outerFades = find.descendant(
          of: nowPlayingLayerFinder,
          matching: find.byType(FadeTransition),
        );
        for (final elem in outerFades.evaluate()) {
          expect(
            find.descendant(
              of: find.byElementPredicate((e) => identical(e, elem)),
              matching: find.byKey(const ValueKey('now_playing_stage')),
            ),
            findsNothing,
          );
        }

        // Verify full-sheet SlideTransition starts at Offset(0.0, 1.0) on frame 0
        final slideFinder = find.byKey(const Key('now_playing_slide_transition'));
        expect(slideFinder, findsOneWidget);
        final slideWidget = tester.widget<SlideTransition>(slideFinder);
        expect(slideWidget.position.value, const Offset(0.0, 1.0));

        // Verify opaque backing ColoredBox inside now_playing_bg_repaint_boundary
        expect(
          find.descendant(
            of: find.byKey(const Key('now_playing_bg_repaint_boundary')),
            matching: find.byWidgetPredicate(
              (w) => w is ColoredBox && w.color == LuminaTokens.canvasBg,
            ),
          ),
          findsOneWidget,
        );

        await tester.pump(const Duration(milliseconds: 140));
        expect(slideWidget.position.value.dy, greaterThan(0.0));
        expect(slideWidget.position.value.dy, lessThan(1.0));

        expect(find.byKey(const ValueKey('now_playing_stage')), findsOneWidget);
        expect(find.byType(FloatingCapsuleMiniPlayer), findsOneWidget);
        expect(
          identical(
            tester.element(workspaceBoundaryFinder),
            initialWorkspaceElement,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.renderObject(workspaceBoundaryFinder),
            initialWorkspaceRenderObj,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );
        // FFT MUST stay false mid-open before AnimationStatus.completed.
        expect(audioService.nowPlayingVisible, isFalse);
        // Zero BackdropFilter inside NowPlayingOverlay, LyricsView, or MiniPlayer mid-open.
        expect(
          find.descendant(
            of: find.byType(NowPlayingOverlay),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(LyricsView),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(FloatingCapsuleMiniPlayer),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        // Zero per-line ImageFiltered blur while transition is unsettled.
        expect(
          find.descendant(
            of: find.byType(LyricsView),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );

        // 2. Complete remaining 140ms -> AnimationStatus.completed (280ms total)
        await tester.pump(const Duration(milliseconds: 145));
        await tester.pump();

        expect(slideWidget.position.value, Offset.zero);
        expect(audioService.nowPlayingVisible, isTrue);
        // Home ambient layer is offstage while Now Playing covers it.
        expect(find.byKey(const Key('home_bg_repaint_boundary')), findsNothing);
        expect(
          identical(
            tester.element(workspaceBoundaryFinder),
            initialWorkspaceElement,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.renderObject(workspaceBoundaryFinder),
            initialWorkspaceRenderObj,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );

        // Expand lyrics settings toolbar and verify zero BackdropFilter there too.
        await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_toggle')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(NowPlayingOverlay),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );

        // 3. Trigger close via Esc -> frame 1 of closing
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        // Level 2 collapses lyrics toolbar first; send Esc again to collapse Now Playing.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        // FFT resets to false on frame 1 of closing, and mini-player BackdropFilter stays suppressed!
        expect(audioService.nowPlayingVisible, isFalse);
        expect(
          find.descendant(
            of: find.byType(FloatingCapsuleMiniPlayer),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(
          identical(
            tester.element(workspaceBoundaryFinder),
            initialWorkspaceElement,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.renderObject(workspaceBoundaryFinder),
            initialWorkspaceRenderObj,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );

        // 4. Mid-close (110ms of 220ms reverseDuration) -> still animating, FFT false, zero mini-player BackdropFilter
        await tester.pump(const Duration(milliseconds: 110));
        expect(slideWidget.position.value.dy, greaterThan(0.0));
        expect(slideWidget.position.value.dy, lessThan(1.0));
        expect(audioService.nowPlayingVisible, isFalse);
        expect(
          find.descendant(
            of: find.byType(FloatingCapsuleMiniPlayer),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );

        // 5. Complete close (remaining 115ms -> 225ms > 220ms reverseDuration) -> dismissed
        await tester.pump(const Duration(milliseconds: 115));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('now_playing_stage')), findsNothing);
        expect(find.byType(FloatingCapsuleMiniPlayer), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(FloatingCapsuleMiniPlayer),
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );
        expect(audioService.nowPlayingVisible, isFalse);
        expect(
          identical(
            tester.element(workspaceBoundaryFinder),
            initialWorkspaceElement,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.renderObject(workspaceBoundaryFinder),
            initialWorkspaceRenderObj,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );

        // 6. Five rapid open/close cycles settle cleanly without exceptions or identity churn
        for (var cycle = 0; cycle < 5; cycle++) {
          await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 120));
          expect(audioService.nowPlayingVisible, isFalse);

          // Mid-flight reverse from ~0.43 takes ~94ms (220ms * 0.43); check at 40ms mid-close
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          expect(
            find.descendant(
              of: find.byType(FloatingCapsuleMiniPlayer),
              matching: find.byType(BackdropFilter),
            ),
            findsNothing,
          );
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(FloatingCapsuleMiniPlayer),
              matching: find.byType(BackdropFilter),
            ),
            findsOneWidget,
          );
        }
        expect(find.byKey(const ValueKey('now_playing_stage')), findsNothing);
        expect(audioService.nowPlayingVisible, isFalse);
        expect(tester.takeException(), isNull);
        expect(
          identical(
            tester.element(workspaceBoundaryFinder),
            initialWorkspaceElement,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'Cover Image keeps gaplessPlayback == true in both FloatingCapsuleMiniPlayer and NowPlayingOverlay via LibraryIndexCache',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tmpDir = Directory.systemTemp.createTempSync('lumina_stage2_art_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File('${tmpDir.path}${Platform.pathSeparator}cover.png')
          ..writeAsBytesSync(_valid1x1Png);

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final activeTrackId = audioService.currentState.track!.id;

        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);
        cache.setArtworkPathSync(activeTrackId, imgFile.path);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              libraryCache: cache,
            ),
          ),
        );
        // Frame 0: mini player cover Image already mounted with gaplessPlayback == true
        final miniPlayerImgFinder = find.descendant(
          of: find.byType(FloatingCapsuleMiniPlayer),
          matching: find.byType(Image),
        );
        expect(miniPlayerImgFinder, findsOneWidget);
        expect(
          tester.widget<Image>(miniPlayerImgFinder).gaplessPlayback,
          isTrue,
        );

        // Open Now Playing and verify hero cover Image keeps gaplessPlayback == true
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();

        final overlayImgFinder = find.descendant(
          of: find.byType(NowPlayingOverlay),
          matching: find.byType(Image),
        );
        expect(overlayImgFinder, findsOneWidget);
        expect(
          tester.widget<Image>(overlayImgFinder).gaplessPlayback,
          isTrue,
        );
      },
    );

    testWidgets(
      'LyricsView uses cacheExtent 400.0 and gates per-line ImageFiltered blur on isTransitionSettled',
      (tester) async {
        final lyrics = [
          const LyricLine(
            start: Duration(seconds: 0),
            end: Duration(seconds: 4),
            text: 'Line zero',
          ),
          const LyricLine(
            start: Duration(seconds: 4),
            end: Duration(seconds: 8),
            text: 'Line one',
          ),
          const LyricLine(
            start: Duration(seconds: 8),
            end: Duration(seconds: 12),
            text: 'Line two',
          ),
        ];

        Widget buildHarness(bool settled) {
          return MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: LyricsView(
                  lyrics: lyrics,
                  currentPosition: const Duration(seconds: 1),
                  isTransitionSettled: settled,
                ),
              ),
            ),
          );
        }

        // Unsettled: zero ImageFiltered widgets and cacheExtent == 400.0
        await tester.pumpWidget(buildHarness(false));
        await tester.pump();

        final listView = tester.widget<ListView>(find.byType(ListView));
        // ignore: deprecated_member_use
        expect(listView.cacheExtent, 400.0);
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.byType(BackdropFilter), findsNothing);

        // Settled: ImageFiltered mounts for off-focus lines
        await tester.pumpWidget(buildHarness(true));
        await tester.pumpAndSettle();
        expect(find.byType(ImageFiltered), findsWidgets);
        expect(find.byType(BackdropFilter), findsNothing);
      },
    );
  });
}
