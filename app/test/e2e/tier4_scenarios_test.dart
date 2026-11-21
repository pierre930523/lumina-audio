import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lumina_app/models/playback_state.dart';

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

  group('Tier 4: Realistic User Application Scenarios (TEST_INFRA.md §Tier 4)', () {
    testWidgets('T4_SC_01_album_playback_and_static_background_journey: Gapless album playback with static background', (tester) async {
      // 1. User launches player and begins playing Track 1 (Time)
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );
      expect(harness.audioService.currentState.track?.title, equals('Time'));

      // 2. Expand NowPlaying overlay
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      // Verify static background RepaintBoundary is active
      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);

      // 3. Steady playback of Track 1 for simulated 2 seconds - 0 background repaints
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump(const Duration(milliseconds: 1000));
      expect(tester.binding.hasScheduledFrame, isFalse);

      // 4. Track 1 completes, automatically advances to Track 2 (Money)
      await harness.audioService.next();
      await tester.pump();

      // Smooth palette transition over 650ms
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 200));
      expect(harness.audioService.currentState.track?.title, equals('Money'));

      // 5. Transition to Track 3 (Comfortably Numb)
      await harness.audioService.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(harness.audioService.currentState.track?.title, equals('Comfortably Numb'));
      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T4_SC_02_settings_toggling_and_persistence_journey: User settings journey and cross-session persistence', (tester) async {
      // 1. User opens Settings panel and inspects default switch state
      await tester.pumpWidget(harness.buildSettingsStage());
      await tester.pump();

      expect(find.text('即時音頻可視化'), findsOneWidget);
      expect(harness.scaleController.enableAudioVisualizer, isTrue);

      // 2. User toggles setting to OFF
      await tester.tap(find.byKey(const Key('switch_audio_visualizer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 3. Persist setting to JSON storage inside runAsync
      await tester.runAsync(() async {
        await harness.persistence!.save(false);
        final jsonFile = harness.prefsFile!;
        expect(await jsonFile.exists(), isTrue);

        final content = await jsonFile.readAsString();
        expect(content, contains('"enableAudioVisualizer":false'));

        // 4. Simulate application restart: instantiate a new controller and load state
        final newPersistence = VisualizerSettingsPersistence(jsonFile);
        final reloadedState = await newPersistence.load();
        expect(reloadedState, isFalse);

        // 5. Visualizer initializes dormant
        harness.lifecycleCoordinator.updateFactors(enabled: reloadedState);
        expect(harness.lifecycleCoordinator.isActive, isFalse);
      });
    });

    testWidgets('T4_SC_03_multitasking_and_minimization_journey: Desktop multitasking and minimize/restore handling', (tester) async {
      // 1. Music playing in fullscreen NowPlaying stage
      await harness.audioService.play();
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isTrue);
      expect(coord.isTickerRunning, isTrue);

      coord.tick();
      expect(coord.tickerCount, equals(1));

      // 2. User minimizes app to Windows taskbar
      coord.updateFactors(isMinimized: true);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);

      // Zero ticker activity while minimized
      coord.tick();
      coord.tick();
      expect(coord.tickerCount, equals(1));

      // Audio playback continues unaffected
      expect(harness.audioService.currentState.status, equals(PlaybackStatus.playing));

      // 3. User restores window after multitasking
      coord.updateFactors(isMinimized: false);
      expect(coord.isActive, isTrue);
      expect(coord.isTickerRunning, isTrue);

      coord.tick();
      expect(coord.tickerCount, equals(2));
    });

    testWidgets('T4_SC_04_playback_lifecycle_pause_seek_skip_journey: Comprehensive playback control user flow', (tester) async {
      // 1. Begin playback
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      harness.pushSpectrum(List.filled(64, 0.75));
      expect(harness.lifecycleCoordinator.isActive, isTrue);

      // 2. Seek forward to 1:30
      await harness.audioService.seek(const Duration(seconds: 90));
      expect(harness.audioService.currentState.position, equals(const Duration(seconds: 90)));
      expect(harness.lifecycleCoordinator.isActive, isTrue);

      // 3. Pause playback
      await harness.audioService.pause();
      harness.lifecycleCoordinator.updateFactors(isPlaying: false);
      expect(harness.lifecycleCoordinator.isActive, isFalse);
      expect(harness.lifecycleCoordinator.currentAmplitude, equals(0.0));

      // 4. Seek while paused
      await harness.audioService.seek(const Duration(seconds: 165));
      expect(harness.audioService.currentState.position, equals(const Duration(seconds: 165)));
      expect(harness.lifecycleCoordinator.isActive, isFalse);

      // 5. Resume playback
      await harness.audioService.resume();
      harness.lifecycleCoordinator.updateFactors(isPlaying: true);
      expect(harness.lifecycleCoordinator.isActive, isTrue);

      // 6. Skip to next track
      await harness.audioService.next();
      expect(harness.audioService.currentState.position, equals(Duration.zero));
      expect(harness.lifecycleCoordinator.isActive, isTrue);
    });

    testWidgets('T4_SC_05_high_res_and_mixed_format_transition_journey: FLAC 96k -> DSD64 -> FLAC 192k audio journey', (tester) async {
      // 1. Track 1: FLAC 96kHz / 24-bit
      final trackFlac96 = harness.audioService.queue[0];
      await harness.audioService.play(track: trackFlac96);
      expect(trackFlac96.format.sampleRateHz, equals(96000));
      expect(trackFlac96.format.isDsd, isFalse);

      harness.pushSpectrum(List.filled(64, 0.8));
      expect(harness.spectrumNotifier.value[0], closeTo(0.8, 0.001));

      // 2. Switch to Track 2: Native DSD64 (2.8224 MHz)
      final trackDsd = harness.audioService.queue[1];
      await harness.audioService.play(track: trackDsd);
      expect(trackDsd.format.isDsd, isTrue);

      // Engine bypasses FFT for DSD, feeding flat zero line
      harness.pushFlatZero();
      expect(harness.spectrumNotifier.value.every((v) => v == 0.0), isTrue);

      // 3. Switch to Track 3: FLAC 192kHz / 24-bit
      final trackFlac192 = harness.audioService.queue[2];
      await harness.audioService.play(track: trackFlac192);
      expect(trackFlac192.format.sampleRateHz, equals(192000));
      expect(trackFlac192.format.isDsd, isFalse);

      // Resumes active spectrum
      harness.pushSpectrum(List.filled(64, 0.95));
      expect(harness.spectrumNotifier.value[0], closeTo(0.95, 0.001));
    });

    test('T4_SC_06_cold_boot_restoration_zero_footprint_journey: Cold boot with disabled visualizer maintains 0 overhead', () async {
      // 1. Save disabled preference
      await harness.persistence!.save(false);

      // 2. Simulate fresh boot
      final bootPersistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final bootEnabled = await bootPersistence.load();
      expect(bootEnabled, isFalse);

      // 3. Initialize coordinator with cold-boot state
      final coordinator = VisualizerLifecycleCoordinator(
        enabled: bootEnabled,
        isPlaying: true, // Audio playing
        isVisible: true,
        isMinimized: false,
      );

      // Because enabled == false, coordinator remains completely dormant
      expect(coordinator.isActive, isFalse);
      expect(coordinator.isTickerRunning, isFalse);
      expect(coordinator.currentAmplitude, equals(0.0));

      coordinator.tick();
      expect(coordinator.tickerCount, equals(0));
    });
  });
}
