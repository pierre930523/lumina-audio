import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// Shared cached 128x128 deterministic monochrome noise shader used to dither
/// dark gradients and ambient backdrops without runtime allocation.
class NoiseTextureCache {
  NoiseTextureCache._();

  static const int _tileSize = 128;
  static final Float64List _identityMatrix = Float64List.fromList(
    const <double>[
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0,
    ],
  );

  static ui.Image? _image;
  static ui.ImageShader? _shader;
  static bool _initialized = false;

  static ui.ImageShader? getOrCreateSync() {
    if (_initialized) return _shader;
    _initialized = true;
    try {
      const bucketCount = 16;
      final buckets = List<List<Offset>>.generate(
        bucketCount,
        (_) => <Offset>[],
      );
      var seed = 0x6A09E667;
      for (var y = 0; y < _tileSize; y++) {
        for (var x = 0; x < _tileSize; x++) {
          seed ^= (seed << 13) & 0xFFFFFFFF;
          seed ^= (seed >> 17);
          seed ^= (seed << 5) & 0xFFFFFFFF;
          final bucket = (seed >> 28) & 0xF;
          buckets[bucket].add(Offset(x + 0.5, y + 0.5));
        }
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.square
        ..isAntiAlias = false;

      for (var b = 0; b < bucketCount; b++) {
        final points = buckets[b];
        if (points.isEmpty) continue;
        final shade = (b * 17).clamp(0, 255);
        paint.color = Color.fromARGB(255, shade, shade, shade);
        canvas.drawPoints(ui.PointMode.points, points, paint);
      }

      final picture = recorder.endRecording();
      try {
        final img = picture.toImageSync(_tileSize, _tileSize);
        _image = img;
        _shader = ui.ImageShader(
          img,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          _identityMatrix,
        );
      } finally {
        picture.dispose();
      }
    } catch (_) {
      _image?.dispose();
      _image = null;
      _shader = null;
    }
    return _shader;
  }
}

/// Paints a cached [NoiseTextureCache] shader across the viewport to prevent
/// 8-bit color banding on smooth ambient gradients.
class NoiseGrainPainter extends CustomPainter {
  final ui.ImageShader shader;
  final double opacity;

  const NoiseGrainPainter({
    required this.shader,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..shader = shader
      ..color = Colors.white.withValues(alpha: opacity);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant NoiseGrainPainter oldDelegate) {
    return oldDelegate.shader != shader || oldDelegate.opacity != opacity;
  }
}
