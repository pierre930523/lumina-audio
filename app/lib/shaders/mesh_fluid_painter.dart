import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';

/// CustomPainter for `shaders/mesh_fluid_bg.frag` with CPU fallback for headless tests.
class MeshFluidBgPainter extends CustomPainter {
  final ui.FragmentShader? shader;
  final double time;
  final Color colorA;
  final Color colorB;
  final Color colorC;
  final Color colorD;

  const MeshFluidBgPainter({
    this.shader,
    this.time = 0.0,
    this.colorA = const Color(0xFF0F172A),
    this.colorB = const Color(0xFF3B0764),
    this.colorC = const Color(0xFF0F766E),
    this.colorD = const Color(0xFF1E1B4B),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    if (shader != null) {
      shader!
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, time)
        ..setFloat(3, colorA.r)
        ..setFloat(4, colorA.g)
        ..setFloat(5, colorA.b)
        ..setFloat(6, colorA.a)
        ..setFloat(7, colorB.r)
        ..setFloat(8, colorB.g)
        ..setFloat(9, colorB.b)
        ..setFloat(10, colorB.a)
        ..setFloat(11, colorC.r)
        ..setFloat(12, colorC.g)
        ..setFloat(13, colorC.b)
        ..setFloat(14, colorC.a)
        ..setFloat(15, colorD.r)
        ..setFloat(16, colorD.g)
        ..setFloat(17, colorD.b)
        ..setFloat(18, colorD.a);
      canvas.drawRect(rect, Paint()..shader = shader);
      return;
    }

    if (size.isEmpty) return;

    // CPU fallback mirroring 4-point fluid mesh atmosphere
    final t = time * 0.22;

    final basePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [colorD, colorC],
      ).createShader(rect);
    canvas.drawRect(rect, basePaint);

    // Drifting coordinates matching `shaders/mesh_fluid_bg.frag`
    final p1 = Alignment(
      (0.25 + 0.18 * math.sin(t)) * 2.0 - 1.0,
      (0.30 + 0.16 * math.cos(t * 1.3)) * 2.0 - 1.0,
    );
    final p2 = Alignment(
      (0.75 + 0.16 * math.cos(t * 0.9)) * 2.0 - 1.0,
      (0.25 + 0.18 * math.sin(t * 1.1)) * 2.0 - 1.0,
    );
    final p3 = Alignment(
      (0.30 + 0.20 * math.cos(t * 1.2)) * 2.0 - 1.0,
      (0.75 + 0.14 * math.sin(t * 0.8)) * 2.0 - 1.0,
    );

    _drawBlob(canvas, rect, p1, colorA, 0.72, 0.95);
    _drawBlob(canvas, rect, p2, colorB, 0.58, 0.90);
    _drawBlob(canvas, rect, p3, colorC, 0.45, 0.85);

    // Subtle bottom dark vignette for crisp foreground text contrast
    final vignettePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          colorD.withValues(alpha: 0.28),
          const Color(0x6606080D),
        ],
        stops: const [0.45, 0.78, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, vignettePaint);
  }

  void _drawBlob(
    Canvas canvas,
    Rect rect,
    Alignment center,
    Color color,
    double alpha,
    double radius,
  ) {
    final blobPaint = Paint()
      ..shader = RadialGradient(
        center: center,
        radius: radius,
        colors: [
          color.withValues(alpha: alpha),
          color.withValues(alpha: alpha * 0.45),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, blobPaint);
  }

  @override
  bool shouldRepaint(covariant MeshFluidBgPainter oldDelegate) {
    return oldDelegate.time != time ||
        oldDelegate.colorA != colorA ||
        oldDelegate.colorB != colorB ||
        oldDelegate.colorC != colorC ||
        oldDelegate.colorD != colorD ||
        oldDelegate.shader != shader;
  }
}
