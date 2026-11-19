import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';

/// CustomPainter for `shaders/liquid_glass.frag` with CPU fallback for headless tests.
class LiquidGlassPainter extends CustomPainter {
  final ui.FragmentShader? shader;
  final ui.Image? backdropImage;
  final double radius;
  final double refractionStrength;
  final Color tint;

  const LiquidGlassPainter({
    this.shader,
    this.backdropImage,
    this.radius = 28.0,
    this.refractionStrength = 0.04,
    this.tint = const Color(0x381E293B),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    if (shader != null && backdropImage != null) {
      shader!
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, radius)
        ..setFloat(3, refractionStrength)
        ..setFloat(4, tint.r)
        ..setFloat(5, tint.g)
        ..setFloat(6, tint.b)
        ..setFloat(7, tint.a)
        ..setImageSampler(0, backdropImage!);
      final paint = Paint()..shader = shader;
      canvas.drawRRect(rrect, paint);
      return;
    }

    // Graceful CPU fallback for headless tests or before shader asset finishes loading
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          tint.withValues(alpha: (tint.a + 0.14).clamp(0.0, 1.0)),
          tint,
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, fillPaint);

    // Specular rim highlight
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0x66FFFFFF),
          Color(0x18FFFFFF),
          Color(0x33A855F7),
        ],
      ).createShader(rect);
    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant LiquidGlassPainter oldDelegate) {
    return oldDelegate.radius != radius ||
        oldDelegate.refractionStrength != refractionStrength ||
        oldDelegate.tint != tint ||
        oldDelegate.shader != shader ||
        oldDelegate.backdropImage != backdropImage;
  }
}
