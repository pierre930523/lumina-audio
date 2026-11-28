import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/album_layout_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:lumina_app/ui/theme/smooth_scroll.dart';
import 'package:material_ui/material_ui.dart';

class _TestAlbumsAudioService extends MockAudioService {
  final List<CanonicalAlbumSummary> albumsList;
  _TestAlbumsAudioService(this.albumsList);

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async => albumsList;
}

List<CanonicalAlbumSummary> _buildAlbums(int count) => List.generate(
  count,
  (i) => CanonicalAlbumSummary(
    id: 'alb-${i + 1}',
    title: 'Glide Test Album ${i + 1}',
    artist: 'Artist ${i + 1}',
    year: 2020 + (i % 5),
    trackCount: 8,
  ),
);

PointerScrollEvent _scrollEvent(
  Offset position,
  Offset delta, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  int ms = 100,
}) => PointerScrollEvent(
  position: position,
  kind: kind,
  scrollDelta: delta,
  timeStamp: Duration(milliseconds: ms),
);

Widget _buildScrollListHost({
  required ScrollController controller,
  bool wrapWithSmoothScroll = true,
  Axis scrollDirection = Axis.vertical,
}) {
  final list = ListView.builder(
    controller: controller,
    scrollDirection: scrollDirection,
    itemCount: 80,
    itemExtent: 50,
    itemBuilder: (_, i) => SizedBox(
      width: scrollDirection == Axis.horizontal ? 50 : null,
      height: scrollDirection == Axis.vertical ? 50 : null,
      child: Text('Row $i'),
    ),
  );
  return MaterialApp(
    scrollBehavior: const LuminaDesktopScrollBehavior(forceDesktop: true),
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 400,
        child: wrapWithSmoothScroll
            ? SmoothScrollWrapper(
                controller: controller,
                forceDesktop: true,
                child: list,
              )
            : list,
      ),
    ),
  );
}

void main() {
  group('GlideInertiaEngine physics & constants', () {
    test('uses Glide Inertia defaults and exact exponential damping formula', () {
      expect(GlideInertiaEngine.defaultDamping, 9.5);
      expect(GlideInertiaEngine.defaultWheelMultiplier, 1.15);
      expect(GlideInertiaEngine.defaultStopThreshold, 0.35);
      expect(GlideInertiaEngine.maxFrameDtSeconds, 0.05);
      expect(GlideInertiaEngine.highSpeedThresholdPxPerMs, 1.8);

      final engine = GlideInertiaEngine(minExtent: 0.0, maxExtent: 2000.0);
      expect(engine.addWheelDelta(100.0), isTrue);
      expect(engine.target, closeTo(115.0, 1e-9));
      expect(engine.current, 0.0);
      expect(engine.isActive, isTrue);

      const dt = 1.0 / 60.0;
      final expected1 = 115.0 * (1.0 - math.exp(-9.5 * dt));
      final pos1 = engine.step(dt);
      expect(pos1, closeTo(expected1, 1e-9));
      expect(engine.velocityPxPerMs, closeTo(expected1 / (dt * 1000.0), 1e-9));

      final expected2 =
          expected1 + (115.0 - expected1) * (1.0 - math.exp(-9.5 * dt));
      expect(engine.step(dt), closeTo(expected2, 1e-9));
    });

    test('clamps dt to 0.05s on large frame gaps and never overshoots', () {
      final largeGap = GlideInertiaEngine(maxExtent: 2000.0)..addWheelDelta(100.0);
      final clamped = GlideInertiaEngine(maxExtent: 2000.0)..addWheelDelta(100.0);

      final posLarge = largeGap.step(2.0);
      final posClamped = clamped.step(0.05);
      expect(posLarge, closeTo(posClamped, 1e-9));
      expect(posLarge, closeTo(115.0 * (1.0 - math.exp(-9.5 * 0.05)), 1e-9));
      expect(posLarge, lessThan(115.0));
      expect(largeGap.step(-0.5), closeTo(posLarge, 1e-9));
      expect(largeGap.step(double.nan), closeTo(posLarge, 1e-9));
    });

    test('snaps current = target and stops when remaining < 0.35', () {
      final engine = GlideInertiaEngine(maxExtent: 1000.0);
      expect(engine.addWheelDelta(0.2), isFalse);
      expect(engine.isActive, isFalse);
      expect(engine.current, closeTo(0.23, 1e-9));
      expect(engine.target, closeTo(0.23, 1e-9));
      expect(engine.velocityPxPerMs, 0.0);

      engine.syncTo(0.0);
      engine.addWheelDelta(100.0);
      for (var i = 0; i < 120 && engine.isActive; i++) {
        engine.step(1.0 / 60.0);
      }
      expect(engine.isActive, isFalse);
      expect(engine.current, engine.target);
      expect(engine.target, closeTo(115.0, 1e-9));
      expect(engine.velocityPxPerMs, 0.0);
    });

    test('Reverse Direction Braking immediately resets target = current + delta', () {
      final engine = GlideInertiaEngine(initialOffset: 500.0, maxExtent: 2000.0);
      engine.addWheelDelta(200.0); // target = 730.0
      final currentAfterTick = engine.step(0.016);
      expect(engine.target - currentAfterTick, greaterThan(150.0));

      engine.addWheelDelta(-40.0); // scaledDelta = -46.0
      expect(engine.target, closeTo(currentAfterTick - 46.0, 1e-9));
      expect(engine.target, lessThan(currentAfterTick));
      expect(engine.step(0.016), lessThan(currentAfterTick));

      engine.addWheelDelta(100.0);
      expect(engine.target, closeTo(engine.current + 115.0, 1e-9));
    });

    test('normalizes deltaMode (pixel/line/page) and strictly clamps bounds', () {
      expect(normalizeWheelDelta(25.0, deltaMode: WheelDeltaMode.pixel), 25.0);
      expect(normalizeWheelDelta(3.0, deltaMode: WheelDeltaMode.line), 120.0);
      expect(
        normalizeWheelDelta(0.5, deltaMode: WheelDeltaMode.page, viewportDimension: 720.0),
        360.0,
      );
      expect(WheelDeltaMode.fromCode(0), WheelDeltaMode.pixel);
      expect(WheelDeltaMode.fromCode(1), WheelDeltaMode.line);
      expect(WheelDeltaMode.fromCode(2), WheelDeltaMode.page);

      final engine = GlideInertiaEngine(
        initialOffset: 450.0,
        minExtent: 0.0,
        maxExtent: 500.0,
      );
      engine.addWheelDelta(3.0, deltaMode: WheelDeltaMode.line);
      expect(engine.target, 500.0);
      engine.addWheelDelta(1.0, deltaMode: WheelDeltaMode.page, viewportDimension: 600.0);
      expect(engine.target, 500.0);

      final atBottom = engine.step(0.016);
      engine.addWheelDelta(-20.0);
      expect(engine.target, closeTo(atBottom - 23.0, 1e-9));

      engine.syncTo(10.0, minExtent: 0.0, maxExtent: 500.0);
      engine.addWheelDelta(-200.0);
      expect(engine.target, 0.0);
    });
  });

  group('TrackpadHeuristicTracker & Windows HiDPI scaling', () {
    test('bypasses trackpad, horizontal dx, fractional dpr=1, and consecutive <40px', () {
      final tracker = TrackpadHeuristicTracker();
      bool check({
        bool trackpad = false,
        double dx = 0.0,
        double dy = 0.0,
        double dpr = 1.0,
        bool shift = false,
        int ms = 10,
      }) => tracker.shouldBypass(
        isTrackpadKind: trackpad,
        rawDx: dx,
        rawDy: dy,
        devicePixelRatio: dpr,
        isShiftPressed: shift,
        timestamp: Duration(milliseconds: ms),
      );

      expect(check(trackpad: true, dy: 100.0, ms: 10), isTrue);
      tracker.reset();
      expect(check(dx: 24.0, ms: 20), isTrue);
      expect(check(dx: 100.0, shift: true, ms: 30), isFalse);
      expect(check(dy: 12.5, ms: 1000), isTrue);

      tracker.reset();
      expect(check(dy: 20.0, ms: 2000), isFalse);
      expect(check(dy: 20.0, ms: 2016), isTrue);
    });

    test('does NOT falsely bypass physical wheel under Windows 150% DPI scaling', () {
      final tracker = TrackpadHeuristicTracker();
      const dpr = 1.5;
      const logicalDy = 100.0 / dpr; // 66.66666666666667 -> physical 100.0

      for (final ms in [500, 516]) {
        expect(
          tracker.shouldBypass(
            isTrackpadKind: false,
            rawDx: 0.0,
            rawDy: logicalDy,
            devicePixelRatio: dpr,
            isShiftPressed: false,
            timestamp: Duration(milliseconds: ms),
          ),
          isFalse,
        );
      }
    });
  });

  group('ScrollVelocityScope, ScrollCardEntrance & AlbumArtworkView bypass', () {
    testWidgets('ScrollCardEntrance animates <=1.8 and bypasses >1.8 px/ms', (tester) async {
      final velocity = ValueNotifier<double>(0.5);
      addTearDown(velocity.dispose);

      Widget cardHost(Key k) => MaterialApp(
        home: ScrollVelocityScope(
          velocityListenable: velocity,
          child: ScrollCardEntrance(key: k, child: const SizedBox(width: 100, height: 100)),
        ),
      );

      await tester.pumpWidget(cardHost(const Key('slow_card')));
      final slowFade = tester.widget<FadeTransition>(
        find.descendant(of: find.byKey(const Key('slow_card')), matching: find.byType(FadeTransition)),
      );
      expect(slowFade.opacity.value, 0.0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(slowFade.opacity.value, 1.0);

      velocity.value = 2.5;
      await tester.pumpWidget(cardHost(const Key('fast_card')));
      final fastFade = tester.widget<FadeTransition>(
        find.descendant(of: find.byKey(const Key('fast_card')), matching: find.byType(FadeTransition)),
      );
      expect(fastFade.opacity.value, 1.0);
      final fastTransform = tester.widget<Transform>(
        find.descendant(of: find.byKey(const Key('fast_card')), matching: find.byType(Transform)),
      );
      expect(fastTransform.transform.getTranslation().y, 0.0);
    });

    testWidgets('ScrollCardEntrance snaps mid-animation without rebuilding subtree', (tester) async {
      final velocity = ValueNotifier<double>(0.2);
      addTearDown(velocity.dispose);
      var siblingBuilds = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ScrollVelocityScope(
            velocityListenable: velocity,
            child: Column(
              children: [
                Builder(
                  builder: (context) {
                    siblingBuilds++;
                    ScrollVelocityScope.listenableOf(context);
                    return const SizedBox(height: 10);
                  },
                ),
                const ScrollCardEntrance(key: Key('snap_card'), child: SizedBox(width: 80, height: 80)),
              ],
            ),
          ),
        ),
      );
      final buildsAtMount = siblingBuilds;
      await tester.pump(const Duration(milliseconds: 30));
      final fade = tester.widget<FadeTransition>(
        find.descendant(of: find.byKey(const Key('snap_card')), matching: find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, lessThan(1.0));

      velocity.value = 2.2;
      await tester.pump();
      expect(fade.opacity.value, 1.0);
      expect(siblingBuilds, buildsAtMount);
    });

    testWidgets('AlbumArtworkView uses Duration.zero >1.8 px/ms and 380ms when slow', (tester) async {
      final velocity = ValueNotifier<double>(0.4);
      addTearDown(velocity.dispose);
      final service = MockAudioService();
      addTearDown(service.dispose);
      const album = CanonicalAlbumSummary(id: 'alb-art-1', title: 'Art', artist: 'Artist');

      Widget buildArt({int revision = 0}) => MaterialApp(
        theme: LuminaTokens.buildDarkTheme(),
        home: Scaffold(
          body: ScrollVelocityScope(
            velocityListenable: velocity,
            child: AlbumArtworkView(album: album, size: 120, audioService: service, revision: revision),
          ),
        ),
      );

      await tester.pumpWidget(buildArt());
      await tester.pump();
      AnimatedSwitcher findSwitcher() => tester.widget<AnimatedSwitcher>(
        find.descendant(of: find.byType(AlbumArtworkView), matching: find.byType(AnimatedSwitcher)),
      );
      expect(findSwitcher().duration, const Duration(milliseconds: 380));

      velocity.value = 2.4;
      await tester.pumpWidget(buildArt(revision: 1));
      await tester.pump();
      expect(findSwitcher().duration, Duration.zero);
    });
  });

  group('Widget end-to-end GlideScrollController & AlbumsAndCreditsView', () {
    testWidgets('zero 1-frame snap, damping glide, reverse braking & trackpad/fractional bypass', (
      tester,
    ) async {
      final controller = GlideScrollController(forceDesktop: true);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_buildScrollListHost(controller: controller));
      expect(find.byType(LuminaDesktopScrollScope), findsNothing);
      final center = tester.getCenter(find.byType(ListView));

      await tester.sendEventToBinding(_scrollEvent(center, const Offset(0, 200), ms: 100));
      await tester.pump();
      expect(controller.offset, 0.0);

      await tester.pump(const Duration(milliseconds: 16));
      final step1 = controller.offset;
      expect(step1, greaterThan(0.0));
      expect(step1, lessThan(230.0));

      await tester.sendEventToBinding(_scrollEvent(center, const Offset(0, -40), ms: 132));
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, lessThan(step1));

      await tester.sendEventToBinding(_scrollEvent(center, const Offset(0, 300), ms: 300));
      await tester.pump(const Duration(milliseconds: 16));
      final beforeTrackpad = controller.offset;

      await tester.sendEventToBinding(
        _scrollEvent(center, const Offset(0, 18), kind: PointerDeviceKind.trackpad, ms: 320),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, closeTo(beforeTrackpad + 18.0, 1e-3));
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.offset, closeTo(beforeTrackpad + 18.0, 1e-3));

      // Fractional delta at dpr = 1.0 also bypasses 1:1.
      final beforeFrac = controller.offset;
      await tester.sendEventToBinding(_scrollEvent(center, const Offset(0, 12.5), ms: 600));
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, closeTo(beforeFrac + 12.5, 1e-3));
    });

    testWidgets('horizontal deltaX != 0 and 150% Windows DPI mouse wheel behave per spec', (
      tester,
    ) async {
      final horizController = GlideScrollController(forceDesktop: true);
      addTearDown(horizController.dispose);
      await tester.pumpWidget(
        _buildScrollListHost(controller: horizController, scrollDirection: Axis.horizontal),
      );
      await tester.sendEventToBinding(
        _scrollEvent(tester.getCenter(find.byType(ListView)), const Offset(30, 0), ms: 100),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(horizController.offset, closeTo(30.0, 1e-3));

      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = GlideScrollController(forceDesktop: true);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _buildScrollListHost(controller: controller, wrapWithSmoothScroll: false),
      );
      expect(find.byType(LuminaDesktopScrollScope), findsOneWidget);

      const logicalDelta = 100.0 / 1.5;
      await tester.sendEventToBinding(
        _scrollEvent(tester.getCenter(find.byType(ListView)), const Offset(0, logicalDelta), ms: 100),
      );
      await tester.pump();
      expect(controller.offset, 0.0);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, closeTo(logicalDelta * 1.15, 0.5));
    });

    testWidgets('AlbumsAndCreditsView handles PointerScrollEvent with SmoothScrollWrapper', (
      tester,
    ) async {
      final service = _TestAlbumsAudioService(_buildAlbums(40));
      addTearDown(service.dispose);
      final layout = AlbumLayoutSettingsController();
      addTearDown(layout.dispose);
      final offsets = <double>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          scrollBehavior: const LuminaDesktopScrollBehavior(forceDesktop: true),
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 600,
              child: AlbumsAndCreditsView(
                audioService: service,
                layoutController: layout,
                onScrollOffsetChanged: offsets.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gridFinder = find.byKey(const Key('album_grid_view'));
      expect(gridFinder, findsOneWidget);
      expect(find.byType(ScrollCardEntrance), findsWidgets);

      await tester.sendEventToBinding(_scrollEvent(tester.getCenter(gridFinder), const Offset(0, 120), ms: 200));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(offsets, isNotEmpty);
      expect(offsets.last, greaterThan(0.0));
      expect(offsets.last, lessThan(120.0 * 1.15));

      await tester.pumpAndSettle();
      expect(offsets.last, closeTo(120.0 * 1.15, 0.5));
    });
  });
}
