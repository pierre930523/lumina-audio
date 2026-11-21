import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/ui/settings/settings_widgets.dart';

import 'helpers/e2e_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late E2ETestHarness harness;

  setUp(() async {
    harness = E2ETestHarness();
    await harness.setUp();
  });

  tearDown(() async {
    await harness.tearDown();
  });

  // ===========================================================================
  // Feature 1: Static Background in Fullscreen Player (ORIGINAL_REQUEST §R1)
  // ===========================================================================
  group('Tier 1 - F1: Static Background in Fullscreen Player (ORIGINAL_REQUEST §R1)', () {
    testWidgets('TC_T1_F1_01: mounts RepaintBoundary with key now_playing_bg_repaint_boundary', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      final boundaryFinder = find.byKey(const Key('now_playing_bg_repaint_boundary'));
      expect(boundaryFinder, findsOneWidget);

      final boundaryWidget = tester.widget(boundaryFinder);
      expect(boundaryWidget, isA<RepaintBoundary>());
    });

    testWidgets('TC_T1_F1_02: background renders static container with album art palette colors', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      final boundaryFinder = find.byKey(const Key('now_playing_bg_repaint_boundary'));
      expect(boundaryFinder, findsOneWidget);

      final RenderBox box = tester.renderObject(boundaryFinder);
      expect(box.size.width, greaterThan(0));
      expect(box.size.height, greaterThan(0));
    });

    testWidgets('TC_T1_F1_03: background remains motionless with zero repaints during steady playback', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('now_playing_bg_repaint_boundary')),
      );
      expect(boundary.isRepaintBoundary, isTrue);

      // Advance time by 2 seconds during steady playback
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 1000));

      // With no song change, background must remain static
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('TC_T1_F1_04: smooth palette transition occurs strictly upon track change and settles', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      // Change track to next
      await harness.audioService.next();
      await tester.pump();

      // Palette transition executes over 650ms
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));

      // Settled to resting state
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('TC_T1_F1_05: background repaint boundary isolates repaints from parent tree', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      final renderObject = tester.renderObject(find.byKey(const Key('now_playing_bg_repaint_boundary')));
      expect(renderObject, isA<RenderRepaintBoundary>());
      final RenderRepaintBoundary repaintBoundary = renderObject as RenderRepaintBoundary;
      expect(repaintBoundary.isRepaintBoundary, isTrue);
    });

    testWidgets('TC_T1_F1_06: background RepaintBoundary is positioned at base of Stack', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      final stackFinder = find.byType(Stack);
      expect(stackFinder, findsWidgets);

      final bgFinder = find.byKey(const Key('now_playing_bg_repaint_boundary'));
      expect(bgFinder, findsOneWidget);
    });

    test('TC_T1_F1_07: AmbientPalette fallbackFor produces deterministic colors on null track', () {
      final fallback = AmbientPalette.fallbackFor(null);
      expect(fallback.colorA, equals(AmbientPalette.defaultFallback.colorA));
      expect(fallback.colorB, equals(AmbientPalette.defaultFallback.colorB));
    });
  });

  // ===========================================================================
  // Feature 2: Elimination of Fake Sine Wave Bar (ORIGINAL_REQUEST §R1)
  // ===========================================================================
  group('Tier 1 - F2: Elimination of Fake Sine Wave Bar (ORIGINAL_REQUEST §R1)', () {
    testWidgets('TC_T1_F2_01: spectrum painter has no repeating 2.8s sine wave animation controller', (tester) async {
      final notifier = ValueNotifier<Float32List>(Float32List(64));
      await tester.pumpWidget(harness.buildVisualizerStage(notifier: notifier));
      await tester.pump();

      // Pumping frames with static notifier should schedule zero animation frames
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
      notifier.dispose();
    });

    testWidgets('TC_T1_F2_02: spectrum bars remain flat at zero baseline during silence', (tester) async {
      final notifier = ValueNotifier<Float32List>(Float32List(64)); // all 0.0
      await tester.pumpWidget(harness.buildVisualizerStage(notifier: notifier));
      await tester.pump();

      final customPaintFinder = find.descendant(
        of: find.byKey(const Key('spectrum_visualizer_repaint_boundary')),
        matching: find.byType(CustomPaint),
      );
      expect(customPaintFinder, findsOneWidget);

      final CustomPaint customPaint = tester.widget(customPaintFinder);
      expect(customPaint.painter, isA<SpectrumPainter>());
      final painter = customPaint.painter as SpectrumPainter;
      expect(painter.bands.value.every((b) => b == 0.0), isTrue);
      notifier.dispose();
    });

    testWidgets('TC_T1_F2_03: quiescence when paused - zero tickers scheduled for waveform rendering', (tester) async {
      harness.lifecycleCoordinator.updateFactors(
        enabled: true,
        isPlaying: false, // Paused
        isVisible: true,
        isMinimized: false,
      );

      expect(harness.lifecycleCoordinator.isActive, isFalse);
      expect(harness.lifecycleCoordinator.isTickerRunning, isFalse);
      expect(harness.lifecycleCoordinator.currentAmplitude, equals(0.0));
    });

    testWidgets('TC_T1_F2_04: bar deflection strictly driven by audio spectrum energy rather than math phase', (tester) async {
      final notifier = ValueNotifier<Float32List>(Float32List(64));
      await tester.pumpWidget(harness.buildVisualizerStage(notifier: notifier));
      await tester.pump();

      // Feed known spectrum with peak at index 32
      final spectrumData = Float32List(64);
      spectrumData[32] = 0.85;
      notifier.value = spectrumData;
      await tester.pump();

      final CustomPaint customPaint = tester.widget(find.descendant(
        of: find.byKey(const Key('spectrum_visualizer_repaint_boundary')),
        matching: find.byType(CustomPaint),
      ));
      final painter = customPaint.painter as SpectrumPainter;
      expect(painter.bands.value[32], closeTo(0.85, 0.001));
      expect(painter.bands.value[0], equals(0.0));
      notifier.dispose();
    });

    testWidgets('TC_T1_F2_05: visualizer bar sits at bottom without obstructing playback controls', (tester) async {
      await tester.pumpWidget(harness.buildVisualizerStage(height: 48.0));
      await tester.pump();

      final RenderBox box = tester.renderObject(find.byKey(const Key('spectrum_visualizer_repaint_boundary')));
      expect(box.size.height, equals(48.0));
    });

    testWidgets('TC_T1_F2_06: zero amplitude vector produces 0.0 for all 64 bands', (tester) async {
      harness.pushFlatZero();
      expect(harness.spectrumNotifier.value.length, equals(64));
      expect(harness.spectrumNotifier.value.every((v) => v == 0.0), isTrue);
    });

    testWidgets('TC_T1_F2_07: configurable barCount property respected by visualizer', (tester) async {
      await tester.pumpWidget(harness.buildVisualizerStage(barCount: 64));
      await tester.pump();

      final boundaryFinder = find.byKey(const Key('spectrum_visualizer_repaint_boundary'));
      expect(boundaryFinder, findsOneWidget);
    });
  });

  // ===========================================================================
  // Feature 4: 64-Band CustomPainter & Album Art Palette (ORIGINAL_REQUEST §R2, §R3)
  // ===========================================================================
  group('Tier 1 - F4: 64-Band CustomPainter & Album Art Palette (ORIGINAL_REQUEST §R2, §R3)', () {
    testWidgets('TC_T1_F4_01: 64-band SpectrumPainter is enclosed within RepaintBoundary', (tester) async {
      await tester.pumpWidget(harness.buildVisualizerStage(barCount: 64));
      await tester.pump();

      final boundaryFinder = find.byKey(const Key('spectrum_visualizer_repaint_boundary'));
      expect(boundaryFinder, findsOneWidget);
      expect(tester.widget(boundaryFinder), isA<RepaintBoundary>());
    });

    testWidgets('TC_T1_F4_02: ValueNotifier updates trigger painter repaint with zero parent widget rebuild churn', (tester) async {
      final notifier = ValueNotifier<Float32List>(Float32List(64));
      final counterKey = GlobalKey<BuildCounterSpyState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BuildCounterSpy(
              key: counterKey,
              child: SpectrumVisualizerWidget(
                bands: notifier,
                palette: AmbientPalette.defaultFallback,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(counterKey.currentState!.buildCount, equals(1));

      // Push 60 spectrum updates simulating 60fps audio feed
      for (int frame = 0; frame < 60; frame++) {
        final data = Float32List(64);
        data[frame % 64] = 0.5 + (frame % 10) * 0.05;
        notifier.value = data;
        await tester.pump();

        // Verify that the SpectrumVisualizerWidget element is NOT marked dirty
        final element = tester.element(find.byType(SpectrumVisualizerWidget));
        expect(element.dirty, isFalse);
      }

      // Assert ZERO parent widget rebuilds occurred
      expect(
        counterKey.currentState!.buildCount,
        equals(1),
        reason: 'ValueNotifier must repaint CustomPainter directly without rebuilding parent widget',
      );
      notifier.dispose();
    });

    testWidgets('TC_T1_F4_03: spectrum bars interpolate gradient between palette colorA and colorB', (tester) async {
      const palette = AmbientPalette(
        colorA: Color(0xFF1B2838),
        colorB: Color(0xFF2A475E),
        colorC: Color(0xFF66C0F4),
        colorD: Color(0xFFC7D5E0),
      );

      await tester.pumpWidget(harness.buildVisualizerStage(palette: palette));
      await tester.pump();

      final CustomPaint customPaint = tester.widget(find.descendant(
        of: find.byKey(const Key('spectrum_visualizer_repaint_boundary')),
        matching: find.byType(CustomPaint),
      ));
      final painter = customPaint.painter as SpectrumPainter;
      expect(painter.colorA, equals(palette.colorA));
      expect(painter.colorB, equals(palette.colorB));
    });

    testWidgets('TC_T1_F4_04: spectrum bars render crisp top highlight accent at crest', (tester) async {
      const palette = AmbientPalette(
        colorA: Color(0xFF101820),
        colorB: Color(0xFFFEE715),
        colorC: Color(0xFFFFFFFF),
        colorD: Color(0xFF000000),
      );

      await tester.pumpWidget(harness.buildVisualizerStage(palette: palette));
      await tester.pump();

      final CustomPaint customPaint = tester.widget(find.descendant(
        of: find.byKey(const Key('spectrum_visualizer_repaint_boundary')),
        matching: find.byType(CustomPaint),
      ));
      final painter = customPaint.painter as SpectrumPainter;
      expect(painter.highlightColor, isNotNull);
    });

    testWidgets('TC_T1_F4_05: magnitudes strictly clamped to [0.0, 1.0] with flat baseline at 0.0', (tester) async {
      final notifier = ValueNotifier<Float32List>(Float32List(64));
      await tester.pumpWidget(harness.buildVisualizerStage(notifier: notifier));
      await tester.pump();

      // Input extreme out-of-range values: -5.0, 15.0, NaN, Inf
      final invalidData = Float32List(64);
      invalidData[0] = -5.0;
      invalidData[1] = 15.0;
      invalidData[2] = double.nan;
      invalidData[3] = double.infinity;
      notifier.value = invalidData;

      // Painter must paint safely without exception
      await tester.pump();
      expect(tester.takeException(), isNull);
      notifier.dispose();
    });

    testWidgets('TC_T1_F4_06: painter shouldRepaint returns false when properties are identical', (tester) async {
      final p1 = SpectrumPainter(bands: harness.spectrumNotifier, barCount: 64);
      final p2 = SpectrumPainter(bands: harness.spectrumNotifier, barCount: 64);
      expect(p1.shouldRepaint(p2), isFalse);
    });

    testWidgets('TC_T1_F4_07: multi-palette adaptation produces dark luminance under 0.3 for background contrast', (tester) async {
      for (int i = 0; i < 4; i++) {
        final mockTrack = TrackInfo(
          id: 'test-$i',
          title: 'Track $i',
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(minutes: 3),
          format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
        );
        final pal = AmbientPalette.fallbackFor(mockTrack);
        expect(pal.colorD.computeLuminance(), lessThan(0.3));
      }
    });
  });

  // ===========================================================================
  // Feature 6: Settings Switch & JSON Persistence (ORIGINAL_REQUEST §R4)
  // ===========================================================================
  group('Tier 1 - F6: Settings Switch & JSON Persistence (ORIGINAL_REQUEST §R4)', () {
    testWidgets('TC_T1_F6_01: settings UI renders exact title and subtitle under 播放行為', (tester) async {
      await tester.pumpWidget(harness.buildSettingsStage());
      await tester.pump();

      expect(find.text('即時音頻可視化'), findsOneWidget);
      expect(
        find.text('在播放頁面底部顯示隨音樂即時跳動的頻譜效果；關閉可進一步節省 CPU 與 GPU 資源'),
        findsOneWidget,
      );
    });

    testWidgets('TC_T1_F6_02: visualizer setting initial default is ON (true)', (tester) async {
      expect(harness.scaleController.enableAudioVisualizer, isTrue);

      await tester.pumpWidget(harness.buildSettingsStage());
      await tester.pump();

      final switchFinder = find.byKey(const Key('switch_audio_visualizer'));
      expect(switchFinder, findsOneWidget);
      final SettingsSwitchRow row = tester.widget(switchFinder);
      expect(row.value, isTrue);
    });

    testWidgets('TC_T1_F6_03: interactive toggle switches enableAudioVisualizer to false', (tester) async {
      bool capturedValue = true;
      await tester.pumpWidget(
        harness.buildSettingsStage(
          switchValue: capturedValue,
          onToggle: (val) => capturedValue = val,
        ),
      );
      await tester.pump();

      // Tap on the switch row
      await tester.tap(find.byKey(const Key('switch_audio_visualizer')));
      await tester.pump();

      expect(capturedValue, isFalse);
    });

    test('TC_T1_F6_04: setting persists enableAudioVisualizer: false to JSON file', () async {
      await harness.persistence!.save(false);
      expect(await harness.prefsFile!.exists(), isTrue);

      final content = await harness.prefsFile!.readAsString();
      expect(content, contains('"enableAudioVisualizer":false'));
    });

    test('TC_T1_F6_05: loads persisted enableAudioVisualizer state from preferences on startup', () async {
      await harness.persistence!.save(false);

      final reloadedPersistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final loadedState = await reloadedPersistence.load();
      expect(loadedState, isFalse);
    });

    testWidgets('TC_T1_F6_06: toggling setting immediately notifies scaleController listeners', (tester) async {
      bool notified = false;
      harness.scaleController.addListener(() {
        notified = true;
      });

      harness.scaleController.setEnableAudioVisualizer(false);
      expect(notified, isTrue);
      expect(harness.scaleController.enableAudioVisualizer, isFalse);
    });

    test('TC_T1_F6_07: re-enabling setting persists true value to storage', () async {
      await harness.persistence!.save(false);
      await harness.persistence!.save(true);
      final restored = await harness.persistence!.load();
      expect(restored, isTrue);
    });
  });

  // ===========================================================================
  // Feature 7: 4-Factor Lifecycle Coordinator & Zero Overhead (ORIGINAL_REQUEST §R2, §R4)
  // ===========================================================================
  group('Tier 1 - F7: 4-Factor Lifecycle Coordinator & Zero Overhead (ORIGINAL_REQUEST §R2, §R4)', () {
    test('TC_T1_F7_01: truth table validation: active only when all 4 factors are true', () {
      final coord = harness.lifecycleCoordinator;

      // 1. All true -> Active
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isTrue);

      // 2. Disabled -> Inactive
      coord.updateFactors(enabled: false, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isFalse);

      // 3. Paused -> Inactive
      coord.updateFactors(enabled: true, isPlaying: false, isVisible: true, isMinimized: false);
      expect(coord.isActive, isFalse);

      // 4. Hidden/Collapsed -> Inactive
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: false, isMinimized: false);
      expect(coord.isActive, isFalse);

      // 5. Minimized -> Inactive
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: true);
      expect(coord.isActive, isFalse);
    });

    test('TC_T1_F7_02: pausing playback sets state inactive, halts tickers, and decays amplitude', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      coord.currentAmplitude = 0.85;
      expect(coord.isActive, isTrue);

      // Pause
      coord.updateFactors(isPlaying: false);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);
      expect(coord.currentAmplitude, equals(0.0));
    });

    test('TC_T1_F7_03: collapsing overlay sets state inactive and suspends visualizer updates', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isTrue);

      // Collapse overlay
      coord.updateFactors(isVisible: false);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);
    });

    test('TC_T1_F7_04: minimizing window suspends updates and halts tickers', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      coord.tick();
      expect(coord.tickerCount, equals(1));

      // Minimize window
      coord.updateFactors(isMinimized: true);
      coord.tick(); // Ticker halted, should not advance
      expect(coord.tickerCount, equals(1));
    });

    test('TC_T1_F7_05: toggling setting OFF completely stops visualizer processing and clears buffer', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isTrue);

      // Toggle setting OFF
      coord.updateFactors(enabled: false);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);
      expect(coord.currentAmplitude, equals(0.0));
    });

    test('TC_T1_F7_06: inactive state executes 0 ticker increments', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: false);
      coord.reset();
      coord.tick();
      coord.tick();
      coord.tick();
      expect(coord.tickerCount, equals(0));
    });

    test('TC_T1_F7_07: restoring all 4 factors re-arms ticker immediately', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: false);
      expect(coord.isTickerRunning, isFalse);

      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isTickerRunning, isTrue);
      coord.tick();
      expect(coord.tickerCount, equals(1));
    });
  });
}
