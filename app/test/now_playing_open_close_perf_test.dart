import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/lyric.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
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

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(audioService: audioService),
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

        // 1. Trigger open in Split Lyrics mode -> frame 1 + 150ms (mid-open of 300ms transition)
        await tester.tap(find.byKey(const Key('btn_toggle_lyrics')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(find.byKey(const Key('now_playing_stage')), findsOneWidget);
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
        // Zero BackdropFilter inside NowPlayingOverlay or LyricsView.
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
        // Zero per-line ImageFiltered blur while transition is unsettled.
        expect(
          find.descendant(
            of: find.byType(LyricsView),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );

        // 2. Complete remaining 150ms -> AnimationStatus.completed (300ms total)
        await tester.pump(const Duration(milliseconds: 155));
        await tester.pump();

        expect(audioService.nowPlayingVisible, isTrue);
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

        // FFT resets to false on frame 1 of closing!
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

        // 4. Mid-close (150ms) -> still identical and FFT remains false
        await tester.pump(const Duration(milliseconds: 150));
        expect(audioService.nowPlayingVisible, isFalse);
        expect(
          identical(
            tester.state(find.byType(FloatingCapsuleMiniPlayer)),
            initialMiniPlayerState,
          ),
          isTrue,
        );

        // 5. Complete close (remaining 150ms + settle) -> back to closed
        await tester.pump(const Duration(milliseconds: 160));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('now_playing_stage')), findsNothing);
        expect(find.byType(FloatingCapsuleMiniPlayer), findsOneWidget);
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
