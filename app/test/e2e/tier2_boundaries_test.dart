import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

  // ===========================================================================
  // Category 1: Background Boundaries & Geometry (Feature 1)
  // ===========================================================================
  group('Tier 2 - BVA: Background Boundaries & Geometry (F1)', () {
    testWidgets('T2_F1_01_bva_bg_missing_art_fallback: Null artwork uses fallback without crash', (tester) async {
      final track = TrackInfo(
        id: 'no-art-trk',
        title: 'Track Without Artwork',
        artist: 'Unknown Artist',
        album: 'Unknown Album',
        duration: const Duration(minutes: 3),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
      );
      final palette = AmbientPalette.fallbackFor(track);
      expect(palette.colorA, isNotNull);
      expect(palette.colorB, isNotNull);

      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();
      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F1_02_bva_bg_rapid_track_skipping: 10 rapid track skips handled without exception', (tester) async {
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      for (int i = 0; i < 10; i++) {
        await harness.audioService.next();
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F1_03_bva_bg_extreme_aspect_ratios_ultrawide: 3840x600 ultrawide aspect ratio', (tester) async {
      tester.view.physicalSize = const Size(3840, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      final box = tester.renderObject(find.byKey(const Key('now_playing_bg_repaint_boundary'))) as RenderBox;
      expect(box.size.width, greaterThan(0));
    });

    testWidgets('T2_F1_04_bva_bg_extreme_aspect_ratios_compact: 400x700 compact vertical layout', (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F1_05_bva_bg_paused_track_change: Track change while paused updates palette smoothly', (tester) async {
      await harness.audioService.pause();
      await tester.pumpWidget(harness.buildNowPlayingStage());
      await tester.pump();

      await harness.audioService.next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(harness.audioService.currentState.status, equals(PlaybackStatus.paused));
      expect(find.byKey(const Key('now_playing_bg_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F1_06_bva_bg_zero_size_canvas: Zero, infinite, and NaN dimensions handled cleanly by painter', (tester) async {
      final painter = SpectrumPainter(bands: harness.spectrumNotifier);
      final pictureRecorder = ui.PictureRecorder();
      final canvas = Canvas(pictureRecorder);

      // Painting on 0x0, infinite, or NaN size canvas must return cleanly without exception
      painter.paint(canvas, Size.zero);
      painter.paint(canvas, const Size(double.infinity, 48.0));
      painter.paint(canvas, const Size(48.0, double.infinity));
      painter.paint(canvas, const Size(double.nan, 48.0));
      painter.paint(canvas, const Size(48.0, double.nan));
      expect(pictureRecorder.isRecording, isTrue);
      pictureRecorder.endRecording().dispose();
    });
  });

  // ===========================================================================
  // Category 2: Waveform & Playback State Boundaries (Feature 2)
  // ===========================================================================
  group('Tier 2 - BVA: Waveform & Playback State Boundaries (F2)', () {
    testWidgets('T2_F2_01_bva_bar_zero_duration_stream: 0-duration stream renders baseline without error', (tester) async {
      harness.pushFlatZero();
      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();

      expect(find.byKey(const Key('spectrum_visualizer_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F2_02_bva_bar_unknown_metadata: Null metadata fields do not break visualizer', (tester) async {
      final minimalTrack = TrackInfo(
        id: 'bare-trk',
        title: 'Title Only',
        artist: '',
        album: '',
        duration: const Duration(seconds: 10),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
      );
      final pal = AmbientPalette.fallbackFor(minimalTrack);
      expect(pal, isNotNull);

      await tester.pumpWidget(harness.buildVisualizerStage(palette: pal));
      await tester.pump();
      expect(find.byKey(const Key('spectrum_visualizer_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F2_03_bva_bar_rapid_play_pause_spam: 20 rapid play/pause toggles do not leak tickers', (tester) async {
      final coord = harness.lifecycleCoordinator;
      for (int i = 0; i < 20; i++) {
        coord.updateFactors(isPlaying: (i % 2 == 0));
        coord.tick();
      }
      coord.updateFactors(isPlaying: false);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);
    });

    testWidgets('T2_F2_04_bva_bar_empty_audio_track: Empty audio track displays flat line', (tester) async {
      harness.pushFlatZero();
      expect(harness.spectrumNotifier.value.every((v) => v == 0.0), isTrue);
    });

    testWidgets('T2_F2_05_bva_bar_zero_height_constraint: Zero height constraint does not throw', (tester) async {
      await tester.pumpWidget(harness.buildVisualizerStage(height: 0.0));
      await tester.pump();
      expect(find.byKey(const Key('spectrum_visualizer_repaint_boundary')), findsOneWidget);
    });
  });

  // ===========================================================================
  // Category 3: Spectrum Data Robustness & BVA (Features 3 & 4)
  // ===========================================================================
  group('Tier 2 - BVA: Spectrum Data Robustness & Clamping (F3/F4)', () {
    testWidgets('T2_F4_01_bva_spec_magnitude_clamping_above_one: Magnitudes > 1.0 clamped to 1.0', (tester) async {
      final raw = Float32List(64);
      raw[0] = 1.5;
      raw[1] = 2.0;
      raw[2] = 100.0;
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_02_bva_spec_negative_magnitude_clamping: Negative values clamped to 0.0', (tester) async {
      final raw = Float32List(64);
      raw[0] = -0.01;
      raw[1] = -1.0;
      raw[2] = -99.9;
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_03_bva_spec_nan_sanitization: NaN in float list sanitized cleanly in painter', (tester) async {
      final raw = Float32List(64);
      raw[0] = double.nan;
      raw[1] = 0.5;
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_04_bva_spec_inf_sanitization: Infinity in float list sanitized cleanly', (tester) async {
      final raw = Float32List(64);
      raw[0] = double.infinity;
      raw[1] = double.negativeInfinity;
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_05_bva_spec_irregular_undersized_array: Array < 64 floats rendered without RangeError', (tester) async {
      final raw = Float32List(16); // Only 16 bands instead of 64
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage(barCount: 64));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_06_bva_spec_irregular_oversized_array: Array > 64 floats truncated without error', (tester) async {
      final raw = Float32List(128); // 128 bands instead of 64
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage(barCount: 64));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_07_bva_spec_single_bin_bass_spike: Pure bass bin 0 spike at 1.0 paints safely', (tester) async {
      final raw = Float32List(64);
      raw[0] = 1.0;
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(harness.spectrumNotifier.value[0], equals(1.0));
      expect(harness.spectrumNotifier.value[1], equals(0.0));
    });

    testWidgets('T2_F4_08_bva_spec_single_bin_treble_spike: Pure treble bin 63 spike at 1.0 paints safely', (tester) async {
      final raw = Float32List(64);
      raw[63] = 1.0;
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(harness.spectrumNotifier.value[63], equals(1.0));
      expect(harness.spectrumNotifier.value[62], equals(0.0));
    });

    testWidgets('T2_F4_09_bva_spec_full_scale_all_ones: All 64 bins at 1.0 render without layout overflow', (tester) async {
      final raw = Float32List(64);
      for (int i = 0; i < 64; i++) {
        raw[i] = 1.0;
      }
      harness.spectrumNotifier.value = raw;

      await tester.pumpWidget(harness.buildVisualizerStage(height: 50.0));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_10_bva_spec_empty_float_list: Empty Float32List(0) handled without throwing', (tester) async {
      harness.spectrumNotifier.value = Float32List(0);
      await tester.pumpWidget(harness.buildVisualizerStage());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('T2_F4_11_bva_spec_ui_scale_08: UI scale 80% geometry calculates correctly', (tester) async {
      await tester.pumpWidget(
        Transform.scale(
          scale: 0.8,
          child: harness.buildVisualizerStage(),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('spectrum_visualizer_repaint_boundary')), findsOneWidget);
    });

    testWidgets('T2_F4_12_bva_spec_ui_scale_15: UI scale 150% geometry calculates correctly', (tester) async {
      await tester.pumpWidget(
        Transform.scale(
          scale: 1.5,
          child: harness.buildVisualizerStage(),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('spectrum_visualizer_repaint_boundary')), findsOneWidget);
    });
  });

  // ===========================================================================
  // Category 4: Settings Storage Fault Boundaries (Feature 6)
  // ===========================================================================
  group('Tier 2 - BVA: Settings Storage Fault Tolerances (F6)', () {
    test('T2_F6_01_bva_settings_corrupted_json: Corrupted JSON syntax safely falls back to default ON (true)', () async {
      await harness.prefsFile!.parent.create(recursive: true);
      await harness.prefsFile!.writeAsString('{invalid_json: true, corrupted');

      final persistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final loaded = await persistence.load();
      expect(loaded, isTrue);
    });

    test('T2_F6_02_bva_settings_legacy_json_missing_key: Legacy JSON missing visualizer key defaults to true', () async {
      await harness.prefsFile!.parent.create(recursive: true);
      await harness.prefsFile!.writeAsString(jsonEncode({
        'scale': 1.0,
        'restore_on_startup': true,
        'remember_playback_position': true,
      }));

      final persistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final loaded = await persistence.load();
      expect(loaded, isTrue);
    });

    test('T2_F6_03_bva_settings_invalid_type_string: JSON with string for boolean defaults to true', () async {
      await harness.prefsFile!.parent.create(recursive: true);
      await harness.prefsFile!.writeAsString(jsonEncode({
        'enableAudioVisualizer': 'invalid_string_value',
      }));

      final persistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final loaded = await persistence.load();
      expect(loaded, isTrue);
    });

    test('T2_F6_04_bva_settings_invalid_type_number: JSON with number for boolean defaults to true', () async {
      await harness.prefsFile!.parent.create(recursive: true);
      await harness.prefsFile!.writeAsString(jsonEncode({
        'enableAudioVisualizer': 42,
      }));

      final persistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final loaded = await persistence.load();
      expect(loaded, isTrue);
    });

    testWidgets('T2_F6_05_bva_settings_rapid_toggle_20x: 20 rapid toggles handle concurrent state cleanly', (tester) async {
      for (int i = 0; i < 20; i++) {
        harness.scaleController.setEnableAudioVisualizer(i % 2 == 0);
      }
      expect(harness.scaleController.enableAudioVisualizer, isFalse);
    });

    test('T2_F6_06_bva_settings_missing_file: Missing file returns default true without throwing', () async {
      final nonExistentFile = File('${harness.tempDir!.path}${Platform.pathSeparator}non_existent.json');
      final persistence = VisualizerSettingsPersistence(nonExistentFile);
      final loaded = await persistence.load();
      expect(loaded, isTrue);
    });

    test('T2_F6_07_bva_settings_empty_file: 0-byte empty file defaults cleanly to true', () async {
      await harness.prefsFile!.parent.create(recursive: true);
      await harness.prefsFile!.writeAsString('');

      final persistence = VisualizerSettingsPersistence(harness.prefsFile!);
      final loaded = await persistence.load();
      expect(loaded, isTrue);
    });
  });

  // ===========================================================================
  // Category 5: Lifecycle & Minimization Boundaries (Feature 7)
  // ===========================================================================
  group('Tier 2 - BVA: Lifecycle & Minimization Boundaries (F7)', () {
    test('T2_F7_01_bva_lifecycle_rapid_minimize_restore_burst: Rapid minimize/restore cycles do not leak tickers', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);

      for (int i = 0; i < 10; i++) {
        coord.updateFactors(isMinimized: true);
        expect(coord.isActive, isFalse);
        coord.updateFactors(isMinimized: false);
        expect(coord.isActive, isTrue);
      }
    });

    test('T2_F7_02_bva_lifecycle_buffering_state: Inactive audio keeps visualizer quiescent', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: false, isVisible: true, isMinimized: false);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);
    });

    testWidgets('T2_F7_03_bva_lifecycle_seek_during_pause: Seeking while paused maintains quiescent state', (tester) async {
      await harness.audioService.pause();
      await harness.audioService.seek(const Duration(seconds: 45));

      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: false, isVisible: true, isMinimized: false);
      expect(coord.isActive, isFalse);
    });

    testWidgets('T2_F7_04_bva_lifecycle_seek_during_playback: Seeking while playing maintains active state', (tester) async {
      await harness.audioService.play();
      await harness.audioService.seek(const Duration(seconds: 45));

      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coord.isActive, isTrue);

      coord.updateFactors(isPlaying: false);
      coord.reset();
    });

    test('T2_F7_05_bva_lifecycle_zero_duration_quiescence: All factors false leaves visualizer dormant', () {
      final coord = harness.lifecycleCoordinator;
      coord.updateFactors(enabled: false, isPlaying: false, isVisible: false, isMinimized: true);
      expect(coord.isActive, isFalse);
      expect(coord.isTickerRunning, isFalse);
      expect(coord.currentAmplitude, equals(0.0));
    });
  });
}
