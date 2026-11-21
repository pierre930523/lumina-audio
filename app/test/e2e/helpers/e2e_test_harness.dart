import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/services/visualizer_lifecycle_coordinator.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/settings/settings_widgets.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';

export 'package:lumina_app/services/visualizer_lifecycle_coordinator.dart';
export 'rebuild_counter.dart';

/// 64-band audio spectrum CustomPainter rendering dynamic bars inside RepaintBoundary.
/// Subscribes directly to [ValueListenable<Float32List>] so only the render object
/// repaints without triggering parent widget rebuilds.
class SpectrumPainter extends CustomPainter {
  final ValueListenable<Float32List> bands;
  final Color colorA;
  final Color colorB;
  final Color highlightColor;
  final int barCount;

  SpectrumPainter({
    required this.bands,
    this.colorA = const Color(0xFF13283C),
    this.colorB = const Color(0xFF388E3C),
    this.highlightColor = const Color(0xFF81C784),
    this.barCount = 64,
  }) : super(repaint: bands);

  @override
  void paint(Canvas canvas, Size size) {
    if (!size.isFinite || size.width <= 0 || size.height <= 0) return;

    final values = bands.value;
    final count = barCount;
    const double spacing = 1.5;
    final totalSpacing = (count - 1) * spacing;
    final barWidth = math.max(1.0, (size.width - totalSpacing) / count);

    final paint = Paint()..style = PaintingStyle.fill;
    final highlightPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = highlightColor.withValues(alpha: 0.9);

    for (int i = 0; i < count; i++) {
      double rawVal = 0.0;
      if (i < values.length) {
        final v = values[i];
        if (!v.isNaN && !v.isInfinite) {
          rawVal = v.clamp(0.0, 1.0);
        }
      }

      final x = i * (barWidth + spacing);
      final barHeight = rawVal * size.height;
      final y = size.height - barHeight;

      if (barHeight > 0.5) {
        final rect = Rect.fromLTWH(x, y, barWidth, barHeight);
        paint.shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            colorA.withValues(alpha: 0.35),
            colorB.withValues(alpha: 0.75),
          ],
        ).createShader(rect);

        final rrect = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(1.5),
        );
        canvas.drawRRect(rrect, paint);

        // Highlight accent at top of the bar
        if (barHeight > 3.0) {
          final capRect = Rect.fromLTWH(x, y, barWidth, math.min(2.0, barHeight));
          canvas.drawRRect(
            RRect.fromRectAndRadius(capRect, const Radius.circular(1.0)),
            highlightPaint,
          );
        }
      } else {
        // Flat baseline on rest
        final baselineRect = Rect.fromLTWH(x, size.height - 1.0, barWidth, 1.0);
        paint.shader = null;
        paint.color = colorA.withValues(alpha: 0.15);
        canvas.drawRect(baselineRect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) {
    return oldDelegate.colorA != colorA ||
        oldDelegate.colorB != colorB ||
        oldDelegate.highlightColor != highlightColor ||
        oldDelegate.barCount != barCount;
  }
}

/// Standalone visualizer widget wrapped in RepaintBoundary.
class SpectrumVisualizerWidget extends StatelessWidget {
  final ValueListenable<Float32List> bands;
  final AmbientPalette palette;
  final double height;
  final int barCount;

  const SpectrumVisualizerWidget({
    super.key,
    required this.bands,
    required this.palette,
    this.height = 48.0,
    this.barCount = 64,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: const Key('spectrum_visualizer_repaint_boundary'),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: SpectrumPainter(
            bands: bands,
            colorA: palette.colorA,
            colorB: palette.colorB,
            highlightColor: Color.lerp(palette.colorB, Colors.white, 0.4) ?? Colors.white,
            barCount: barCount,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Settings persistence helper for enableAudioVisualizer in ui_prefs.json.
class VisualizerSettingsPersistence {
  static const String key = 'enableAudioVisualizer';
  final File file;

  VisualizerSettingsPersistence(this.file);

  Future<void> save(bool enabled) async {
    try {
      Map<String, dynamic> data = {};
      if (await file.exists()) {
        try {
          final content = await file.readAsString();
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            data = decoded;
          }
        } catch (_) {}
      } else {
        await file.parent.create(recursive: true);
      }
      data[key] = enabled;
      await file.writeAsString(jsonEncode(data));
    } on FileSystemException catch (_) {
      // Absorb FileSystemException and PathAccessException on read-only systems
    } catch (_) {
      // Absorb any other file access issues gracefully
    }
  }

  Future<bool> load() async {
    if (!await file.exists()) return true; // Default ON
    try {
      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic> && decoded.containsKey(key)) {
        final val = decoded[key];
        if (val is bool) return val;
      }
      return true; // Fallback default
    } catch (_) {
      return true; // Corrupted syntax fallback default
    }
  }
}

// UiScaleController now natively implements enableAudioVisualizer and setEnableAudioVisualizer.

/// Dedicated UI widget for Visualizer Switch row matching dark theme card/switch styling.
class VisualizerSettingsSwitchRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const VisualizerSettingsSwitchRow({
    super.key,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchRow(
      key: const Key('switch_audio_visualizer'),
      title: '即時音頻可視化',
      subtitle: '在播放頁面底部顯示隨音樂即時跳動的頻譜效果；關閉可進一步節省 CPU 與 GPU 資源',
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Comprehensive E2E test harness providing isolated mock services and controlled spectrum simulation.
class E2ETestHarness {
  final MockAudioService audioService = MockAudioService();
  final UiScaleController scaleController = UiScaleController();
  final ValueNotifier<Float32List> spectrumNotifier =
      ValueNotifier<Float32List>(Float32List(64));
  final VisualizerLifecycleCoordinator lifecycleCoordinator =
      VisualizerLifecycleCoordinator(isVisible: true);

  Directory? tempDir;
  File? prefsFile;
  VisualizerSettingsPersistence? persistence;

  Future<void> setUp() async {
    tempDir = await Directory.systemTemp.createTemp('lumina_e2e_ui_');
    prefsFile = File('${tempDir!.path}${Platform.pathSeparator}ui_prefs.json');
    persistence = VisualizerSettingsPersistence(prefsFile!);
    scaleController.setEnableAudioVisualizer(true);
  }

  void stopCoordinator() {
    lifecycleCoordinator.updateFactors(
      enabled: false,
      isPlaying: false,
      isVisible: false,
      isMinimized: true,
    );
    lifecycleCoordinator.reset();
  }

  Future<void> tearDown() async {
    stopCoordinator();
    lifecycleCoordinator.dispose();
    audioService.dispose();
    scaleController.dispose();
    spectrumNotifier.dispose();
    if (tempDir != null && tempDir!.existsSync()) {
      try {
        tempDir!.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  void pushSpectrum(List<double> values) {
    final list = Float32List(64);
    for (int i = 0; i < 64 && i < values.length; i++) {
      list[i] = values[i];
    }
    spectrumNotifier.value = list;
  }

  void pushFlatZero() {
    spectrumNotifier.value = Float32List(64);
  }

  void feedAudioData({AudioFormat? format, List<double>? samples}) {
    final isDsd = format?.isDsd ?? audioService.currentState.track?.format.isDsd ?? false;
    if (isDsd) {
      spectrumNotifier.value = Float32List(64);
    } else {
      final list = Float32List(64);
      if (samples != null) {
        for (int i = 0; i < 64 && i < samples.length; i++) {
          list[i] = samples[i];
        }
      }
      spectrumNotifier.value = list;
    }
  }

  Widget buildNowPlayingStage({
    bool isVisible = true,
    NowPlayingViewController? controller,
    ArtworkPaletteService? paletteService,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1280,
          height: 800,
          child: NowPlayingOverlay(
            audioService: audioService,
            controller: controller,
            paletteService: paletteService,
            isVisible: isVisible,
            onCollapse: () {},
          ),
        ),
      ),
    );
  }

  Widget buildSettingsStage({bool? switchValue, ValueChanged<bool>? onToggle}) {
    final isEnabled = switchValue ?? scaleController.enableAudioVisualizer;
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsGroupCard(
            title: '播放行為',
            children: [
              VisualizerSettingsSwitchRow(
                value: isEnabled,
                onChanged: onToggle ?? (val) => scaleController.setEnableAudioVisualizer(val),
              ),
              const Divider(color: LuminaTokens.borderSubtle, height: 1),
              SettingsSwitchRow(
                key: const Key('switch_remember_playback_pos'),
                title: '記住播放位置',
                subtitle: '重新開啟曲目或恢復工作階段時從上次停止處接續播放。',
                value: scaleController.rememberPlaybackPosition,
                onChanged: scaleController.setRememberPlaybackPosition,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildVisualizerStage({
    ValueNotifier<Float32List>? notifier,
    AmbientPalette? palette,
    double height = 48.0,
    int barCount = 64,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SpectrumVisualizerWidget(
          bands: notifier ?? spectrumNotifier,
          palette: palette ?? AmbientPalette.defaultFallback,
          height: height,
          barCount: barCount,
        ),
      ),
    );
  }
}
