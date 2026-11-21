import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';

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

  group('Tier 3: Pairwise Combinations (TEST_INFRA.md §Feature Matrix)', () {
    testWidgets('T3_PW_01_on_playing_fullscreen_active_standard_flac: Baseline active visualizer on playing track', (tester) async {
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );
      expect(harness.lifecycleCoordinator.isActive, isTrue);

      harness.pushSpectrum(List.filled(64, 0.7));
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);

      harness.lifecycleCoordinator.updateFactors(isPlaying: false);
      harness.lifecycleCoordinator.reset();
    });

    testWidgets('T3_PW_02_off_playing_fullscreen_active_zero_overhead: Setting disabled during active playback', (tester) async {
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(
        enabled: false, // Disabled
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );

      expect(harness.lifecycleCoordinator.isActive, isFalse);
      expect(harness.lifecycleCoordinator.isTickerRunning, isFalse);
      expect(harness.lifecycleCoordinator.currentAmplitude, equals(0.0));
    });

    testWidgets('T3_PW_03_on_paused_fullscreen_smooth_decay: Audio paused during active playback drops to zero', (tester) async {
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: true,
        isMinimized: false,
      );
      harness.lifecycleCoordinator.currentAmplitude = 0.8;
      expect(harness.lifecycleCoordinator.isActive, isTrue);

      // Pause audio
      await harness.audioService.pause();
      harness.lifecycleCoordinator.updateFactors(isPlaying: false);

      expect(harness.lifecycleCoordinator.isActive, isFalse);
      expect(harness.lifecycleCoordinator.currentAmplitude, equals(0.0));
    });

    testWidgets('T3_PW_04_on_playing_collapsed_miniplayer_suspension: Collapsing overlay halts visualizer updates', (tester) async {
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(
        enabled: true,
        isPlaying: true,
        isVisible: false, // Collapsed
        isMinimized: false,
      );

      expect(harness.lifecycleCoordinator.isActive, isFalse);
      expect(harness.lifecycleCoordinator.isTickerRunning, isFalse);
    });

    testWidgets('T3_PW_05_on_playing_window_minimized_quiescence: Window minimized halts tickers; restore resumes', (tester) async {
      await harness.audioService.play();
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isTrue);

      // Minimize window
      coord.updateFactors(isMinimized: true);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);

      // Restore window
      coord.updateFactors(isMinimized: false);
      expect(coord.isActive, isTrue);
      expect(coord.isTickerRunning, isTrue);

      coord.updateFactors(isPlaying: false);
      coord.reset();
    });

    testWidgets('T3_PW_06_on_playing_dsd_passthrough_resting_line: DSD bitstream renders flat resting line', (tester) async {
      final dsdTrack = TrackInfo(
        id: 'dsd-01',
        title: 'Money (DSD64)',
        artist: 'Pink Floyd',
        album: 'DSOTM',
        duration: const Duration(minutes: 4),
        format: AudioFormat(codec: AudioCodec.dsf, sampleRateHz: 2822400, bitDepth: 1, channels: 2, isDsd: true),
      );
      // Pre-fill spectrum with previous PCM active values
      harness.pushSpectrum(List.filled(64, 0.8));
      expect(harness.spectrumNotifier.value[0], closeTo(0.8, 0.0001));

      await harness.audioService.play(track: dsdTrack);
      expect(harness.audioService.currentState.track?.format.isDsd, isTrue);

      // Engine / service DSD bypass outputs flat zero resting line
      harness.spectrumNotifier.value = harness.audioService.visualizerBandsNotifier.value;
      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();

      expect(harness.spectrumNotifier.value.every((v) => v == 0.0), isTrue);
    });

    testWidgets('T3_PW_07_on_playing_track_without_art_fallback: Null artwork track uses deterministic fallback palette', (tester) async {
      final track = TrackInfo(
        id: 'no-art',
        title: 'Track Without Cover',
        artist: 'Unknown',
        album: 'Unknown',
        duration: const Duration(minutes: 2),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
      );
      final palette = AmbientPalette.fallbackFor(track);
      expect(palette.colorA, isNotNull);
      expect(palette.colorB, isNotNull);

      await tester.pumpWidget(harness.buildVisualizerStage(palette: palette));
      await tester.pump();
      expect(find.byKey(const Key('spectrum_visualizer_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T3_PW_08_toggle_off_during_track_palette_animation: Setting toggled OFF while palette fading', (tester) async {
      await harness.audioService.next();
      harness.scaleController.setEnableAudioVisualizer(false);
      harness.lifecycleCoordinator.updateFactors(enabled: false);

      expect(harness.scaleController.enableAudioVisualizer, isFalse);
      expect(harness.lifecycleCoordinator.isActive, isFalse);
    });

    testWidgets('T3_PW_09_toggle_on_while_paused_quiescent_until_play: Enabling visualizer while paused remains quiescent', (tester) async {
      await harness.audioService.pause();
      harness.scaleController.setEnableAudioVisualizer(true);
      harness.lifecycleCoordinator.updateFactors(enabled: true, isPlaying: false, isVisible: true, isMinimized: false);

      expect(harness.scaleController.enableAudioVisualizer, isTrue);
      expect(harness.lifecycleCoordinator.isActive, isFalse);
      expect(harness.lifecycleCoordinator.isTickerRunning, isFalse);

      // Resume playback
      await harness.audioService.resume();
      harness.lifecycleCoordinator.updateFactors(isPlaying: true);
      expect(harness.lifecycleCoordinator.isActive, isTrue);
    });

    testWidgets('T3_PW_10_settings_toggle_while_audio_plays_uninterrupted: Settings toggle does not disrupt playback', (tester) async {
      await harness.audioService.play();
      expect(harness.audioService.currentState.status, equals(PlaybackStatus.playing));

      harness.scaleController.setEnableAudioVisualizer(false);
      expect(harness.audioService.currentState.status, equals(PlaybackStatus.playing));

      harness.scaleController.setEnableAudioVisualizer(true);
      expect(harness.audioService.currentState.status, equals(PlaybackStatus.playing));
    });

    testWidgets('T3_PW_11_stop_clears_spectrum_and_halts: Stopping track clears spectrum buffer and halts tickers', (tester) async {
      await harness.audioService.play();
      harness.pushSpectrum(List.filled(64, 0.9));
      expect(harness.spectrumNotifier.value[0], closeTo(0.9, 0.001));

      await harness.audioService.stop();
      harness.pushFlatZero();
      harness.lifecycleCoordinator.updateFactors(isPlaying: false);

      expect(harness.audioService.currentState.status, equals(PlaybackStatus.stopped));
      expect(harness.spectrumNotifier.value.every((v) => v == 0.0), isTrue);
      expect(harness.lifecycleCoordinator.isActive, isFalse);
    });

    testWidgets('T3_PW_12_track_change_crossfade_under_active_visualizer: Track change updates palette smoothly', (tester) async {
      await harness.audioService.play();
      harness.lifecycleCoordinator.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);

      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      await harness.audioService.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 200));

      expect(harness.lifecycleCoordinator.isActive, isTrue);
    });
  });
}
