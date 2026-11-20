import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Dynamic, ultra-low-opacity ambient waveform rhythm bar positioned along
/// the bottom of the Now Playing stage. Gently dances during playback and
/// smoothly settles to a flat resting line when paused.
class DynamicWaveformBar extends StatefulWidget {
  final bool isPlaying;
  final Color primaryColor;
  final Color secondaryColor;
  final double height;
  final int barCount;

  const DynamicWaveformBar({
    super.key,
    required this.isPlaying,
    required this.primaryColor,
    required this.secondaryColor,
    this.height = 32.0,
    this.barCount = 42,
  });

  @override
  State<DynamicWaveformBar> createState() => _DynamicWaveformBarState();
}

class _DynamicWaveformBarState extends State<DynamicWaveformBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;
  double _motionFactor = 0.0;

  bool get _shouldAnimate {
    if (kIsWeb) return widget.isPlaying;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return widget.isPlaying;
  }

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..addListener(() {
        if (mounted) setState(() {});
      });

    if (_shouldAnimate) {
      _motionFactor = 1.0;
      _waveController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant DynamicWaveformBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      if (_shouldAnimate) {
        if (!_waveController.isAnimating) _waveController.repeat();
      } else {
        if (_waveController.isAnimating) _waveController.stop();
      }
    }
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Smoothly ease motion factor towards target
    final target = widget.isPlaying ? 1.0 : 0.0;
    _motionFactor += (target - _motionFactor) * 0.12;

    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        painter: _WaveformPainter(
          phase: _waveController.value * 2.0 * math.pi,
          motion: _motionFactor,
          barCount: widget.barCount,
          colorA: widget.primaryColor.withValues(alpha: 0.22),
          colorB: widget.secondaryColor.withValues(alpha: 0.18),
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double phase;
  final double motion;
  final int barCount;
  final Color colorA;
  final Color colorB;

  const _WaveformPainter({
    required this.phase,
    required this.motion,
    required this.barCount,
    required this.colorA,
    required this.colorB,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final barWidth = math.max(2.0, (size.width / (barCount * 1.8)).floorToDouble());
    final totalSpacing = size.width - (barWidth * barCount);
    final gap = totalSpacing / (barCount - 1);

    final paint = Paint()..style = PaintingStyle.fill;
    final maxH = size.height * 0.85;
    final minH = 2.0;

    for (int i = 0; i < barCount; i++) {
      final t = i / (barCount - 1);
      final x = i * (barWidth + gap);

      // Multi-harmonic sine formula
      final wave1 = math.sin(phase + i * 0.22);
      final wave2 = math.cos(phase * 1.3 - i * 0.18);
      final wave3 = math.sin(phase * 0.7 + i * 0.35);
      final normalized = ((wave1 * 0.45 + wave2 * 0.35 + wave3 * 0.20).abs());

      final h = minH + (maxH - minH) * normalized * motion;
      final y = size.height - h;

      paint.color = Color.lerp(colorA, colorB, t) ?? colorA;
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barWidth, h),
        Radius.circular(barWidth * 0.5),
      );
      canvas.drawRRect(rrect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.motion != motion ||
        oldDelegate.colorA != colorA ||
        oldDelegate.colorB != colorB;
  }
}
