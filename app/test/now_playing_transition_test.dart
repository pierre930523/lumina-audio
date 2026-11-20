import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/signal_path/quality_badge.dart';
import 'package:material_ui/material_ui.dart';

Widget _buildTestApp({
  required MockAudioService audioService,
  required NowPlayingViewController controller,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1280,
        height: 800,
        child: NowPlayingOverlay(
          audioService: audioService,
          controller: controller,
          onCollapse: () {},
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAudioService audioService;
  late NowPlayingViewController controller;

  setUp(() {
    audioService = MockAudioService();
    audioService.setSimulatedQuality(SignalQuality.highQuality);
    controller = NowPlayingViewController();
  });

  tearDown(() {
    audioService.dispose();
    controller.dispose();
  });

  group('NowPlaying Single Instance Invariant (AC #38)', () {
    testWidgets(
      'Single cover and track info instance throughout t = 0.0, 0.5, 1.0 (forward and reverse)',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        // 1. Mount initially in Cover mode (t = 0.0)
        controller.setMode(NowPlayingViewMode.cover);
        await tester.pumpWidget(
          _buildTestApp(
            audioService: audioService,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlbumArtworkView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('now_playing_hero_metadata')),
          findsOneWidget,
        );
        expect(find.byType(QualityBadge), findsOneWidget);

        final initialCoverWidget = tester.widget(find.byType(AlbumArtworkView));

        // 2. Initiate forward transition to Split (420ms total)
        controller.setMode(NowPlayingViewMode.split);
        await tester.pump(); // Start animation

        // Advance to t = 0.5 (210ms)
        await tester.pump(const Duration(milliseconds: 210));

        expect(find.byType(AlbumArtworkView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('now_playing_hero_metadata')),
          findsOneWidget,
        );
        expect(find.byType(QualityBadge), findsOneWidget);

        // Confirm identical persistent instance (zero rebuild churn during animation)
        final midCoverWidget = tester.widget(find.byType(AlbumArtworkView));
        expect(identical(initialCoverWidget, midCoverWidget), isTrue);

        // Advance to t = 1.0 (remaining 210ms)
        await tester.pump(const Duration(milliseconds: 210));
        await tester.pumpAndSettle();

        expect(find.byType(AlbumArtworkView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('now_playing_hero_metadata')),
          findsOneWidget,
        );
        expect(find.byType(QualityBadge), findsOneWidget);

        final endCoverWidget = tester.widget(find.byType(AlbumArtworkView));
        expect(identical(initialCoverWidget, endCoverWidget), isTrue);

        // 3. Reverse back from Split to Cover
        controller.setMode(NowPlayingViewMode.cover);
        await tester.pump();

        // Advance to t = 0.5 (210ms)
        await tester.pump(const Duration(milliseconds: 210));

        expect(find.byType(AlbumArtworkView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('now_playing_hero_metadata')),
          findsOneWidget,
        );
        expect(find.byType(QualityBadge), findsOneWidget);
        expect(
          identical(initialCoverWidget, tester.widget(find.byType(AlbumArtworkView))),
          isTrue,
        );

        // Advance to t = 0.0
        await tester.pump(const Duration(milliseconds: 210));
        await tester.pumpAndSettle();

        expect(find.byType(AlbumArtworkView), findsOneWidget);
        expect(
          find.byKey(const ValueKey('now_playing_hero_metadata')),
          findsOneWidget,
        );
        expect(find.byType(QualityBadge), findsOneWidget);
      },
    );
  });

  group('Independent RepaintBoundary Isolation (AC #39)', () {
    testWidgets(
      'Background, Cover, and Lyrics layers have independent non-nested RepaintBoundaries',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        controller.setMode(NowPlayingViewMode.split);
        await tester.pumpWidget(
          _buildTestApp(
            audioService: audioService,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // 1. Locate the 3 isolated RepaintBoundary keys
        final bgBoundaryFinder =
            find.byKey(const Key('now_playing_bg_repaint_boundary'));
        final coverBoundaryFinder =
            find.byKey(const Key('now_playing_cover_repaint_boundary'));
        final lyricsBoundaryFinder =
            find.byKey(const Key('now_playing_lyrics_repaint_boundary'));

        expect(bgBoundaryFinder, findsOneWidget);
        expect(coverBoundaryFinder, findsOneWidget);
        expect(lyricsBoundaryFinder, findsOneWidget);

        // 2. Verify all 3 RenderObjects are genuine repaint boundaries
        final bgRender = tester.renderObject(bgBoundaryFinder) as RenderRepaintBoundary;
        final coverRender =
            tester.renderObject(coverBoundaryFinder) as RenderRepaintBoundary;
        final lyricsRender =
            tester.renderObject(lyricsBoundaryFinder) as RenderRepaintBoundary;

        expect(bgRender.isRepaintBoundary, isTrue);
        expect(coverRender.isRepaintBoundary, isTrue);
        expect(lyricsRender.isRepaintBoundary, isTrue);

        // 3. Verify mutual non-nesting (no layer is ancestor or descendant of any other)
        expect(
          find.descendant(of: bgBoundaryFinder, matching: coverBoundaryFinder),
          findsNothing,
        );
        expect(
          find.descendant(of: bgBoundaryFinder, matching: lyricsBoundaryFinder),
          findsNothing,
        );
        expect(
          find.descendant(of: coverBoundaryFinder, matching: bgBoundaryFinder),
          findsNothing,
        );
        expect(
          find.descendant(of: coverBoundaryFinder, matching: lyricsBoundaryFinder),
          findsNothing,
        );
        expect(
          find.descendant(of: lyricsBoundaryFinder, matching: bgBoundaryFinder),
          findsNothing,
        );
        expect(
          find.descendant(of: lyricsBoundaryFinder, matching: coverBoundaryFinder),
          findsNothing,
        );
      },
    );
  });

  group('Animation Controller Parameters & Motion Kinematics (AC #40)', () {
    testWidgets(
      'Controller has 420ms duration, easeInOutCubic curve, and Interval(0.28, 1.0) lyrics fade',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        controller.setMode(NowPlayingViewMode.cover);
        await tester.pumpWidget(
          _buildTestApp(
            audioService: audioService,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // 1. Verify AnimationController duration is 420ms
        final state =
            tester.state<NowPlayingOverlayState>(find.byType(NowPlayingOverlay));
        expect(state.modeAnimController.duration, const Duration(milliseconds: 420));
        expect(state.modeAnimController.value, 0.0);

        final xCenter = tester.getCenter(find.byType(AlbumArtworkView)).dx;
        // In 1280x800, overlay center dx is 640.0
        expect((xCenter - 640.0).abs(), lessThan(1.0));

        // 2. Start transition to Split
        controller.setMode(NowPlayingViewMode.split);
        await tester.pump();

        // At t = 0.20 (84ms into 420ms animation)
        await tester.pump(const Duration(milliseconds: 84));
        final xAt20 = tester.getCenter(find.byType(AlbumArtworkView)).dx;

        // At t = 0.50 (advance 126ms more, total 210ms)
        await tester.pump(const Duration(milliseconds: 126));
        final xMid = tester.getCenter(find.byType(AlbumArtworkView)).dx;

        // At t = 1.00 (advance remaining 210ms, total 420ms)
        await tester.pump(const Duration(milliseconds: 210));
        await tester.pumpAndSettle();
        final xLeft = tester.getCenter(find.byType(AlbumArtworkView)).dx;

        // 3. Kinematic verification:
        // Verification with Curves.easeInOutCubic
        final expectedMid =
            xCenter + (xLeft - xCenter) * Curves.easeInOutCubic.transform(0.5);
        expect((xMid - expectedMid).abs(), lessThan(1.5));

        // Cubic ease-in check: at t = 0.20, curve(0.2) ≈ 0.054 (far below linear 0.20)
        final totalDist = (xLeft - xCenter).abs();
        final distAt20 = (xAt20 - xCenter).abs();
        expect(distAt20 / totalDist, lessThan(0.06));
        expect(
          (distAt20 / totalDist - Curves.easeInOutCubic.transform(0.2)).abs(),
          lessThan(0.005),
        );
      },
    );
  });

  group('Pointer Event and Visibility Management (AC #41)', () {
    testWidgets(
      'Lyrics IgnorePointer is active when t < 0.05 and Visibility maintains state',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        // 1. At t = 0.0 (Cover mode)
        controller.setMode(NowPlayingViewMode.cover);
        await tester.pumpWidget(
          _buildTestApp(
            audioService: audioService,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        final ignoreFinder =
            find.byKey(const Key('now_playing_lyrics_ignore_pointer'));
        final visFinder =
            find.byKey(const Key('now_playing_lyrics_visibility'));

        expect(ignoreFinder, findsOneWidget);
        expect(visFinder, findsOneWidget);

        final ignore0 = tester.widget<IgnorePointer>(ignoreFinder);
        final vis0 = tester.widget<Visibility>(visFinder);

        expect(ignore0.ignoring, isTrue);
        expect(vis0.visible, isFalse);
        expect(vis0.maintainState, isTrue);

        // 2. Start animation forward (to Split)
        controller.setMode(NowPlayingViewMode.split);
        await tester.pump();

        // Advance 16ms (t = 16 / 420 = 0.038 < 0.05)
        await tester.pump(const Duration(milliseconds: 16));
        final ignoreAt16 = tester.widget<IgnorePointer>(ignoreFinder);
        expect(ignoreAt16.ignoring, isTrue);

        // Advance 18ms more (total 34ms, t = 34 / 420 = 0.081 > 0.05)
        await tester.pump(const Duration(milliseconds: 18));
        final ignoreAt34 = tester.widget<IgnorePointer>(ignoreFinder);
        final visAt34 = tester.widget<Visibility>(visFinder);
        expect(ignoreAt34.ignoring, isFalse);
        expect(visAt34.visible, isTrue);

        // Advance to completion (t = 1.0)
        await tester.pump(const Duration(milliseconds: 386));
        await tester.pumpAndSettle();

        final ignoreAtEnd = tester.widget<IgnorePointer>(ignoreFinder);
        final visAtEnd = tester.widget<Visibility>(visFinder);
        expect(ignoreAtEnd.ignoring, isFalse);
        expect(visAtEnd.visible, isTrue);
      },
    );
  });

  group('Rapid Toggle & Mid-Flight Interruption Robustness', () {
    testWidgets(
      'Mid-flight reverse smoothly reverses direction without stutter or exception',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        controller.setMode(NowPlayingViewMode.cover);
        await tester.pumpWidget(
          _buildTestApp(
            audioService: audioService,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        final state =
            tester.state<NowPlayingOverlayState>(find.byType(NowPlayingOverlay));

        // 1. Start forward transition (Cover -> Split)
        controller.setMode(NowPlayingViewMode.split);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(state.modeAnimController.isAnimating, isTrue);
        expect(state.modeAnimController.value, greaterThan(0.1));
        expect(state.modeAnimController.value, lessThan(0.9));

        // 2. Immediately reverse mid-flight
        controller.setMode(NowPlayingViewMode.cover);
        await tester.pump();

        expect(state.modeAnimController.status, AnimationStatus.reverse);
        await tester.pumpAndSettle();

        expect(state.modeAnimController.value, 0.0);
        expect(controller.mode, NowPlayingViewMode.cover);
        expect(tester.takeException(), isNull);

        // 3. Cover tap mid-flight interruption
        // Tap cover to start forward
        await tester.tap(find.byType(AlbumArtworkView));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));

        expect(state.modeAnimController.status, AnimationStatus.forward);

        // Tap cover again mid-flight to interrupt and reverse
        await tester.tap(find.byType(AlbumArtworkView));
        await tester.pump();

        expect(state.modeAnimController.status, AnimationStatus.reverse);
        await tester.pumpAndSettle();

        expect(state.modeAnimController.value, 0.0);
        expect(controller.mode, NowPlayingViewMode.cover);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
