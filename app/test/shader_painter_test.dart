import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/shaders/liquid_glass_painter.dart';
import 'package:lumina_app/shaders/mesh_fluid_painter.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('LiquidGlassPainter and MeshFluidBgPainter paint CPU fallbacks cleanly', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              SizedBox(
                width: 400,
                height: 300,
                child: CustomPaint(
                  painter: MeshFluidBgPainter(time: 2.5),
                ),
              ),
              SizedBox(
                width: 320,
                height: 80,
                child: CustomPaint(
                  painter: LiquidGlassPainter(radius: 24.0),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
