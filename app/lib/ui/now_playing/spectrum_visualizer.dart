import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/artwork_palette_service.dart';

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
    return oldDelegate.bands != bands ||
        oldDelegate.colorA != colorA ||
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
