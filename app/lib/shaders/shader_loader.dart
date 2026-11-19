import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

class LoadedShaders {
  final ui.FragmentProgram? liquidGlassProgram;
  final ui.FragmentProgram? meshFluidProgram;
  final ui.Image? backdropImage;

  const LoadedShaders({
    this.liquidGlassProgram,
    this.meshFluidProgram,
    this.backdropImage,
  });

  static const empty = LoadedShaders();
}

class ShaderLoader {
  static Future<LoadedShaders> load() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return LoadedShaders.empty;
    }

    try {
      final glassProgram = await ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      );
      final meshProgram = await ui.FragmentProgram.fromAsset(
        'shaders/mesh_fluid_bg.frag',
      );
      final backdrop = await _buildBackdropImage();
      return LoadedShaders(
        liquidGlassProgram: glassProgram,
        meshFluidProgram: meshProgram,
        backdropImage: backdrop,
      );
    } catch (_) {
      return LoadedShaders.empty;
    }
  }

  static Future<ui.Image> _buildBackdropImage() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const rect = Rect.fromLTWH(0, 0, 64, 64);
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0xFF0F172A),
          Color(0xFF3B0764),
          Color(0xFF0F766E),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
    final picture = recorder.endRecording();
    return picture.toImage(64, 64);
  }
}
