part of 'ambient_dynamic_background.dart';

/// Shared bounded LRU cache of decoded 96px ambient cover textures.
/// Hands out lightweight reference-counted `ui.Image.clone()` handles so
/// multiple `AmbientDynamicBackground` instances share GPU textures with zero
/// disk reads or redundant codec decodes on frame 0.
class _AmbientDecodedCoverCache {
  static const int _maxEntries = 16;
  static final LinkedHashMap<String, ui.Image> _entries =
      LinkedHashMap<String, ui.Image>();

  static ui.Image? getClone(String key) {
    final existing = _entries.remove(key);
    if (existing == null) return null;
    try {
      final cloned = existing.clone();
      _entries[key] = existing;
      return cloned;
    } catch (_) {
      try {
        existing.dispose();
      } catch (_) {}
      return null;
    }
  }

  static void put(String key, ui.Image image) {
    if (key.isEmpty) return;
    ui.Image? stored;
    try {
      stored = image.clone();
    } catch (_) {
      return;
    }
    final previous = _entries.remove(key);
    try {
      previous?.dispose();
    } catch (_) {}
    _entries[key] = stored;
    while (_entries.length > _maxEntries) {
      final oldestKey = _entries.keys.first;
      final evicted = _entries.remove(oldestKey);
      try {
        evicted?.dispose();
      } catch (_) {}
    }
  }
}

class _CoverFrameModel extends ChangeNotifier {
  ui.Image? prevImage;
  ui.Image? currImage;
  bool _disposed = false;

  void beginTransition(ui.Image? nextImage) {
    if (_disposed) {
      nextImage?.dispose();
      return;
    }
    if (identical(currImage, nextImage) && nextImage != null) {
      return;
    }
    prevImage?.dispose();
    prevImage = currImage;
    currImage = nextImage;
    notifyListeners();
  }

  void setImmediate(ui.Image? nextImage) {
    if (_disposed) {
      nextImage?.dispose();
      return;
    }
    prevImage?.dispose();
    prevImage = null;
    if (!identical(currImage, nextImage)) {
      currImage?.dispose();
      currImage = nextImage;
    }
    notifyListeners();
  }

  void clearPrevious() {
    if (prevImage == null) return;
    prevImage?.dispose();
    prevImage = null;
  }

  void disposeAll() {
    _disposed = true;
    prevImage?.dispose();
    prevImage = null;
    currImage?.dispose();
    currImage = null;
    dispose();
  }
}

Color _adaptMeshColor(
  Color color,
  LuminaGlassTheme glass,
  double tintStrength,
) {
  final strength = tintStrength.clamp(0.0, 1.0).toDouble();
  if (glass.isDark) {
    if (strength >= 0.999) return color;
    return Color.lerp(glass.canvasBg, color, strength) ?? color;
  }
  final hsl = HSLColor.fromColor(color);
  final pastel = hsl
      .withLightness((hsl.lightness * 0.30 + 0.72).clamp(0.78, 0.94))
      .withSaturation((hsl.saturation * 0.50).clamp(0.06, 0.36))
      .toColor();
  return Color.lerp(glass.canvasBg, pastel, 0.60 * strength) ?? pastel;
}

class _AmbientCoverPainter extends CustomPainter {
  static const double _sat = LuminaTokens.ambientCoverSaturation;
  static const double _invSat = 1.0 - _sat;
  static const double _lightSat = 0.85;
  static const double _invLightSat = 1.0 - _lightSat;
  static const double _lumR = 0.2126;
  static const double _lumG = 0.7152;
  static const double _lumB = 0.0722;

  static const ColorFilter _saturationFilter = ColorFilter.matrix(<double>[
    _invSat * _lumR + _sat,
    _invSat * _lumG,
    _invSat * _lumB,
    0.0,
    0.0,
    _invSat * _lumR,
    _invSat * _lumG + _sat,
    _invSat * _lumB,
    0.0,
    0.0,
    _invSat * _lumR,
    _invSat * _lumG,
    _invSat * _lumB + _sat,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
  ]);

  static const ColorFilter _lightSaturationFilter = ColorFilter.matrix(<double>[
    _invLightSat * _lumR + _lightSat,
    _invLightSat * _lumG,
    _invLightSat * _lumB,
    0.0,
    0.0,
    _invLightSat * _lumR,
    _invLightSat * _lumG + _lightSat,
    _invLightSat * _lumB,
    0.0,
    0.0,
    _invLightSat * _lumR,
    _invLightSat * _lumG,
    _invLightSat * _lumB + _lightSat,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
  ]);

  final _CoverFrameModel model;
  final Animation<double> progress;
  final double coverOpacity;
  final bool lightMode;

  _AmbientCoverPainter({
    required this.model,
    required this.progress,
    required Listenable repaint,
    this.coverOpacity = 1.0,
    this.lightMode = false,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final prev = model.prevImage;
    final curr = model.currImage;
    if (prev == null && curr == null) return;
    if (coverOpacity <= 0.001) return;

    final t = progress.value.clamp(0.0, 1.0).toDouble();
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    if (prev != null && t < 1.0) {
      _drawCover(canvas, size, prev, (1.0 - t) * coverOpacity);
    }
    if (curr != null && t > 0.0) {
      _drawCover(canvas, size, curr, t * coverOpacity);
    }

    canvas.restore();
  }

  void _drawCover(Canvas canvas, Size size, ui.Image image, double opacity) {
    final alpha = opacity.clamp(0.0, 1.0).toDouble();
    if (alpha <= 0.001) return;
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    if (imgW <= 0.0 || imgH <= 0.0) return;

    final coverScale =
        math.max(size.width / imgW, size.height / imgH) *
        LuminaTokens.ambientCoverScale;
    final dstW = imgW * coverScale;
    final dstH = imgH * coverScale;
    final dstRect = Rect.fromLTWH(
      (size.width - dstW) / 2.0,
      (size.height - dstH) / 2.0,
      dstW,
      dstH,
    );
    final srcRect = Rect.fromLTWH(0.0, 0.0, imgW, imgH);

    // Covers in _AmbientDecodedCoverCache are pre-blurred offscreen at <=64px,
    // so upscaling with FilterQuality.high avoids per-frame full-viewport blur.
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: alpha)
      ..colorFilter = lightMode ? _lightSaturationFilter : _saturationFilter
      ..filterQuality = FilterQuality.high
      ..isAntiAlias = true;

    canvas.drawImageRect(image, srcRect, dstRect, paint);
  }

  @override
  bool shouldRepaint(covariant _AmbientCoverPainter oldDelegate) {
    return oldDelegate.model != model ||
        oldDelegate.progress != progress ||
        oldDelegate.coverOpacity != coverOpacity ||
        oldDelegate.lightMode != lightMode;
  }
}

extension _AmbientMeshLayerExt on _AmbientDynamicBackgroundState {
  Widget _buildMeshLayer(LuminaGlassTheme glass, bool isDark, double tint) {
    final mesh = AnimatedBuilder(
      animation: _paletteCurve,
      builder: (context, _) {
        final palette = _currentPalette;
        return CustomPaint(
          key: widget.meshPainterKey,
          painter: MeshFluidBgPainter(
            shader: _meshShader,
            time: 0.0,
            colorA: _adaptMeshColor(palette.colorA, glass, tint),
            colorB: _adaptMeshColor(palette.colorB, glass, tint),
            colorC: _adaptMeshColor(palette.colorC, glass, tint),
            colorD: _adaptMeshColor(palette.colorD, glass, tint),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
    if (isDark) return mesh;
    return Opacity(
      opacity: (0.48 * tint).clamp(0.0, 1.0),
      child: mesh,
    );
  }
}
