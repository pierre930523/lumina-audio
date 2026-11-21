import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/album_layout_settings_controller.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/visualizer_lifecycle_coordinator.dart';
import 'package:lumina_app/ui/now_playing/spectrum_visualizer.dart';
import 'package:material_ui/material_ui.dart';

class MockVisualizerEngineBridge implements VisualizerEngineBridge {
  int setEnabledCallCount = 0;
  int isEnabledCallCount = 0;
  int getBandsCallCount = 0;
  int lastSetEnabledValue = -1;
  int isEnabledState = 0;

  final Float32List mockBandsData = Float32List(64);

  @override
  int setVisualizerEnabled(int enabled) {
    setEnabledCallCount++;
    lastSetEnabledValue = enabled;
    isEnabledState = enabled;
    return 0;
  }

  @override
  int isVisualizerEnabled() {
    isEnabledCallCount++;
    return isEnabledState;
  }

  @override
  int getVisualizerBands(ffi.Pointer<ffi.Float> outPtr, int maxCount) {
    getBandsCallCount++;
    if (outPtr.address == 0 || maxCount < 64) return 0;
    final view = outPtr.asTypedList(64);
    view.setAll(0, mockBandsData);
    return 64;
  }

  @override
  ffi.Pointer<ffi.Float>? allocateBandsBuffer() => null;

  @override
  void freeBandsBuffer(ffi.Pointer<ffi.Float> ptr) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Milestone 1 - R1 Spectrum Visualizer & Repaint Tests', () {
    test('SpectrumPainter.shouldRepaint includes bands notifier comparison', () {
      final notifier1 = ValueNotifier<Float32List>(Float32List(64));
      final notifier2 = ValueNotifier<Float32List>(Float32List(64));

      final painter1 = SpectrumPainter(bands: notifier1);
      final painterSame = SpectrumPainter(bands: notifier1);
      final painterDiffBands = SpectrumPainter(bands: notifier2);
      final painterDiffColorA = SpectrumPainter(
        bands: notifier1,
        colorA: const Color(0xFFFF0000),
      );

      // Same properties -> shouldRepaint is false
      expect(painterSame.shouldRepaint(painter1), isFalse);

      // Different bands notifier -> shouldRepaint is true
      expect(painterDiffBands.shouldRepaint(painter1), isTrue);

      // Different color -> shouldRepaint is true
      expect(painterDiffColorA.shouldRepaint(painter1), isTrue);

      notifier1.dispose();
      notifier2.dispose();
    });

    testWidgets('SpectrumVisualizerWidget mounts and repaints cleanly', (tester) async {
      final bandsNotifier = ValueNotifier<Float32List>(Float32List(64));
      const palette = AmbientPalette.defaultFallback;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SpectrumVisualizerWidget(
              bands: bandsNotifier,
              palette: palette,
              height: 48,
            ),
          ),
        ),
      );

      expect(find.byType(SpectrumVisualizerWidget), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SpectrumVisualizerWidget),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );

      // Update bands and pump
      final updatedBands = Float32List(64);
      updatedBands[10] = 0.75;
      bandsNotifier.value = updatedBands;
      await tester.pump();

      bandsNotifier.dispose();
    });
  });

  group('Milestone 1 - R1 & R3 Visualizer Lifecycle, Conflation & Ballistics Decay', () {
    late MockVisualizerEngineBridge mockBridge;

    setUp(() {
      mockBridge = MockVisualizerEngineBridge();
    });

    test('safe buffer allocation via calloc initializes native buffer', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      coordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );

      expect(coordinator.isActive, isTrue);
      // Tick uses the native buffer allocated via calloc
      mockBridge.mockBandsData[5] = 0.6;
      coordinator.tick();
      expect(coordinator.tickerCount, equals(1));
      expect(coordinator.bandsNotifier.value[5], closeTo(0.6, 0.001));

      coordinator.dispose();
    });

    test('smooth ballistics decay occurs on pause when bands are active', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: true,
      );

      coordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );

      mockBridge.mockBandsData[20] = 0.8;
      coordinator.tick();
      expect(coordinator.bandsNotifier.value[20], closeTo(0.8, 0.001));

      // Pause audio -> enters decay mode instead of instant snap to 0.0
      coordinator.updateFactors(isPlaying: false);
      expect(coordinator.isActive, isFalse);
      expect(coordinator.isTickerRunning, isFalse);
      expect(coordinator.isDecayingOnPause, isTrue);
      expect(mockBridge.lastSetEnabledValue, equals(0));

      // Simulate decay ticks
      coordinator.tickDecay();
      expect(coordinator.bandsNotifier.value[20], closeTo(0.8 * 0.88, 0.001));

      coordinator.tickDecay();
      expect(coordinator.bandsNotifier.value[20], closeTo(0.8 * 0.88 * 0.88, 0.001));

      // Continue decaying until fully zeroed
      while (coordinator.isDecayingOnPause) {
        coordinator.tickDecay();
      }

      expect(coordinator.isDecayingOnPause, isFalse);
      expect(coordinator.bandsNotifier.value[20], equals(0.0));
      expect(coordinator.currentAmplitude, equals(0.0));

      coordinator.dispose();
    });

    test('resuming playback during pause decay cancels decay and re-arms active ticker', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: true,
      );

      coordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );

      mockBridge.mockBandsData[15] = 0.5;
      coordinator.tick();

      // Pause
      coordinator.updateFactors(isPlaying: false);
      expect(coordinator.isDecayingOnPause, isTrue);

      // Decay 1 tick
      coordinator.tickDecay();
      expect(coordinator.isDecayingOnPause, isTrue);

      // Resume playback
      coordinator.updateFactors(isPlaying: true);
      expect(coordinator.isDecayingOnPause, isFalse);
      expect(coordinator.isActive, isTrue);
      expect(coordinator.isTickerRunning, isTrue);
      expect(mockBridge.lastSetEnabledValue, equals(1));

      coordinator.dispose();
    });

    test('hiding or minimizing during pause decay immediately stops and achieves zero quiescence', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: true,
      );

      coordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );

      mockBridge.mockBandsData[10] = 0.9;
      coordinator.tick();

      // Pause
      coordinator.updateFactors(isPlaying: false);
      expect(coordinator.isDecayingOnPause, isTrue);

      // Window minimized -> decay aborts immediately
      coordinator.updateFactors(isMinimized: true);
      expect(coordinator.isDecayingOnPause, isFalse);
      expect(coordinator.isActive, isFalse);
      expect(coordinator.isTickerRunning, isFalse);
      expect(coordinator.currentAmplitude, equals(0.0));

      coordinator.dispose();
    });
  });

  group('Milestone 1 - R3 Single-Flight Worker Tests for Controllers', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('m1_controllers_test_');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('NowPlayingViewController single-flight worker coalesces rapid saves', () async {
      final testFile = File('${tempDir.path}${Platform.pathSeparator}now_playing_prefs.json');
      final controller = NowPlayingViewController(prefsFileOverride: testFile);

      // Rapid successive updates
      controller.setMode(NowPlayingViewMode.lyrics);
      controller.setLyricsFontScale(1.2);
      controller.setMode(NowPlayingViewMode.cover);
      controller.setLyricsFontScale(1.4);

      // Verify state updated in memory immediately
      expect(controller.mode, equals(NowPlayingViewMode.cover));
      expect(controller.lyricsFontScale, closeTo(1.4, 0.001));

      // Wait for save worker
      await controller.currentSaveFuture;

      expect(testFile.existsSync(), isTrue);
      final content = testFile.readAsStringSync();
      expect(content.contains('"cover"'), isTrue);
      expect(content.contains('1.4'), isTrue);

      controller.dispose();
    });

    test('AlbumLayoutSettingsController single-flight worker coalesces rapid saves', () async {
      final testFile = File('${tempDir.path}${Platform.pathSeparator}album_prefs.json');
      final controller = AlbumLayoutSettingsController(prefsFileOverride: testFile);

      // Rapid successive changes
      controller.setCoverTargetExtent(220.0);
      controller.setSpacingPreset(AlbumGridSpacingPreset.wide);
      controller.setViewMode(AlbumViewMode.list);
      controller.setShowCardContainer(true);

      // Memory state is immediate
      expect(controller.coverTargetExtent, closeTo(220.0, 0.001));
      expect(controller.spacingPreset, equals(AlbumGridSpacingPreset.wide));
      expect(controller.viewMode, equals(AlbumViewMode.list));
      expect(controller.showCardContainer, isTrue);

      // Await save completion
      await controller.currentSaveFuture;

      expect(testFile.existsSync(), isTrue);
      final content = testFile.readAsStringSync();
      expect(content.contains('220'), isTrue);
      expect(content.contains('"wide"'), isTrue);
      expect(content.contains('"list"'), isTrue);
      expect(content.contains('true'), isTrue);

      controller.dispose();
    });
  });

  group('Milestone 1 - R3 Persistence Routine (No Synchronous flush: true)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('m1_persist_test_');
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('PlaybackPersistenceService saves and restores cleanly without synchronous OS disk flush', () async {
      final testFile = File('${tempDir.path}${Platform.pathSeparator}playback.json');
      final service = PlaybackPersistenceService(
        prefsFileOverride: testFile,
        throttleDuration: const Duration(milliseconds: 50),
      );

      final track = TrackInfo(
        id: 'track_1',
        title: 'Song One',
        artist: 'Artist One',
        album: 'Album One',
        duration: const Duration(seconds: 180),
        format: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
      );

      final snapshot = service.buildSnapshot(
        state: PlaybackState(
          track: track,
          status: PlaybackStatus.playing,
          position: const Duration(seconds: 45),
          volume: 0.85,
        ),
        queue: [track],
      );

      await service.saveImmediate(snapshot);

      expect(testFile.existsSync(), isTrue);
      final loaded = await service.load();
      expect(loaded, isNotNull);
      expect(loaded!['volume'], closeTo(0.85, 0.001));
      expect(loaded['position_ms'], equals(45000));
      expect(loaded['track']['title'], equals('Song One'));

      service.dispose();
    });
  });
}
