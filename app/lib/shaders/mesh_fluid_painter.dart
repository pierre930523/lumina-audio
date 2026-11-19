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

    // CPU fallback mirroring 4-point fluid mesh atmosphere
    final t = time * 0.22;
    final alignBegin = Alignment(math.sin(t) * 0.5, math.cos(t * 1.3) * 0.5);
    final alignEnd = Alignment(-math.cos(t * 0.9) * 0.5, math.sin(t * 1.1) * 0.5);

    final bgPaint = Paint()
      ..shader = LinearGradient(
        begin: alignBegin,
        end: alignEnd,
        colors: [colorA, colorB, colorC, colorD],
        stops: const [0.0, 0.35, 0.7, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);
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
