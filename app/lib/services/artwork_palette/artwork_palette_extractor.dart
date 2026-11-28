import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'ambient_palette.dart';

/// Pure Dart / Flutter image decoder & hue-bucket ambient palette extractor.
abstract final class ArtworkPaletteExtractor {
  static const int sampleSize = 32;

  static const int _hueBucketCount = 12;
  static const double _achromaticSaturationThreshold = 0.12;
  static const double _chromaticTotalRatioThreshold = 0.12;
  static const double _minSecondaryHueDistance = 35.0;
  static const double _minSecondaryWeightRatio = 0.08;
  static const double _minTertiaryWeightRatio = 0.06;

  static double _hueDistance(double h1, double h2) {
    final diff = (h1 - h2).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }

  /// Extracts a normalized 4-color [AmbientPalette] synchronously from raw RGBA bytes.
  static AmbientPalette extractFromRgba(
    Uint8List rgba,
    int width,
    int height, {
    AmbientPalette? fallback,
  }) {
    final safeFallback = fallback ?? AmbientPalette.defaultFallback;
    if (width <= 0 || height <= 0 || rgba.length < 4) {
      return safeFallback;
    }

    final maxPixels = rgba.length ~/ 4;
    if (maxPixels < width * height) {
      // Truncated buffer: clamp to available complete RGBA pixels.
      if (maxPixels == 0) return safeFallback;
    }

    final stepX = width > sampleSize * 2 ? math.max(1, width ~/ sampleSize) : 1;
    final stepY =
        height > sampleSize * 2 ? math.max(1, height ~/ sampleSize) : 1;

    final sumR = Float64List(_hueBucketCount);
    final sumG = Float64List(_hueBucketCount);
    final sumB = Float64List(_hueBucketCount);
    final bucketWeight = Float64List(_hueBucketCount);

    var chromaticWeight = 0.0;
    var achromaticWeight = 0.0;
    var weightedLightnessSum = 0.0;
    var validPixelCount = 0;

    for (var y = 0; y < height; y += stepY) {
      final rowOffset = y * width;
      for (var x = 0; x < width; x += stepX) {
        final pixelIndex = rowOffset + x;
        if (pixelIndex >= maxPixels) break;
        final offset = pixelIndex * 4;
        final a = rgba[offset + 3];
        if (a < 128) continue;

        final r = rgba[offset];
        final g = rgba[offset + 1];
        final b = rgba[offset + 2];

        final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
        final satFactor = 0.25 + hsl.saturation * 1.5;
        final lightFactor =
            (1.0 - (hsl.lightness - 0.5).abs() * 1.45).clamp(0.15, 1.0);
        final weight = satFactor * lightFactor;

        validPixelCount++;
        weightedLightnessSum += hsl.lightness * weight;

        if (hsl.saturation >= _achromaticSaturationThreshold) {
          final bucket = ((hsl.hue % 360.0) / 30.0).floor().clamp(
                0,
                _hueBucketCount - 1,
              );
          sumR[bucket] += r * weight;
          sumG[bucket] += g * weight;
          sumB[bucket] += b * weight;
          bucketWeight[bucket] += weight;
          chromaticWeight += weight;
        } else {
          achromaticWeight += weight;
        }
      }
    }

    final totalWeight = chromaticWeight + achromaticWeight;
    if (validPixelCount == 0 || totalWeight <= 0.0) {
      return safeFallback;
    }

    if (chromaticWeight >= totalWeight * _chromaticTotalRatioThreshold) {
      var primaryIdx = -1;
      var primaryWeight = -1.0;
      for (var i = 0; i < _hueBucketCount; i++) {
        if (bucketWeight[i] > primaryWeight) {
          primaryWeight = bucketWeight[i];
          primaryIdx = i;
        }
      }

      if (primaryIdx >= 0 && primaryWeight > 0.0) {
        Color bucketAverageColor(int idx) {
          final w = bucketWeight[idx];
          final r = (sumR[idx] / w).round().clamp(0, 255);
          final g = (sumG[idx] / w).round().clamp(0, 255);
          final b = (sumB[idx] / w).round().clamp(0, 255);
          return Color.fromARGB(255, r, g, b);
        }

        final primary = bucketAverageColor(primaryIdx);
        final primaryHsl = HSLColor.fromColor(primary);
        final primaryHue = primaryHsl.hue;

        var secondaryIdx = -1;
        var secondaryWeight = -1.0;
        for (var i = 0; i < _hueBucketCount; i++) {
          if (i == primaryIdx) continue;
          final w = bucketWeight[i];
          if (w < primaryWeight * _minSecondaryWeightRatio) continue;
          final candHue = HSLColor.fromColor(bucketAverageColor(i)).hue;
          if (_hueDistance(candHue, primaryHue) >= _minSecondaryHueDistance &&
              w > secondaryWeight) {
            secondaryWeight = w;
            secondaryIdx = i;
          }
        }

        final secondary = secondaryIdx >= 0
            ? bucketAverageColor(secondaryIdx)
            : primaryHsl.withHue((primaryHue + 28.0) % 360.0).toColor();
        final secondaryHue = HSLColor.fromColor(secondary).hue;

        var tertiaryIdx = -1;
        var tertiaryWeight = -1.0;
        for (var i = 0; i < _hueBucketCount; i++) {
          if (i == primaryIdx || i == secondaryIdx) continue;
          final w = bucketWeight[i];
          if (w < primaryWeight * _minTertiaryWeightRatio) continue;
          final candHue = HSLColor.fromColor(bucketAverageColor(i)).hue;
          if (_hueDistance(candHue, primaryHue) >= _minSecondaryHueDistance &&
              _hueDistance(candHue, secondaryHue) >= _minSecondaryHueDistance &&
              w > tertiaryWeight) {
            tertiaryWeight = w;
            tertiaryIdx = i;
          }
        }

        final tertiary = tertiaryIdx >= 0
            ? bucketAverageColor(tertiaryIdx)
            : primaryHsl
                .withHue(((primaryHue - 26.0) % 360.0 + 360.0) % 360.0)
                .toColor();

        return normalizePalette(
          primary,
          secondary,
          tertiary,
          achromatic: false,
        );
      }
    }

    // Achromatic / B&W / pure black / pure white cover: derive cool-slate dark palette.
    final avgLightness = (weightedLightnessSum / totalWeight).clamp(0.0, 1.0);
    final baseLightness = (0.05 + avgLightness * 0.22).clamp(0.05, 0.27);
    final base = HSLColor.fromAHSL(1.0, 215.0, 0.08, baseLightness).toColor();
    return normalizePalette(base, base, base, achromatic: true);
  }

  /// Normalizes [raw] into a dark, WCAG AA compliant ambient mesh color.
  static Color normalizeAmbientColor(
    Color raw, {
    required double minSat,
    required double maxSat,
    required double minLight,
    required double maxLight,
    double maxLuminance = 0.095,
  }) {
    final effectiveMinLight = math.max(minLight, 0.05);
    final effectiveMaxLight = math.max(maxLight, effectiveMinLight);
    final hsl = HSLColor.fromColor(raw);
    final sat = hsl.saturation.clamp(minSat, maxSat).toDouble();
    var light = hsl.lightness
        .clamp(effectiveMinLight, effectiveMaxLight)
        .toDouble();
    var color = hsl.withSaturation(sat).withLightness(light).toColor();

    for (var i = 0;
        i < 10 && color.computeLuminance() > maxLuminance && light > 0.04;
        i++) {
      light = (light * 0.86).clamp(0.04, 1.0).toDouble();
      color = hsl.withSaturation(sat).withLightness(light).toColor();
    }
    return color;
  }

  /// Normalizes [primary], [secondary], and [tertiary] into a balanced 4-color
  /// ambient palette with guaranteed dark luminance bounds.
  static AmbientPalette normalizePalette(
    Color primary,
    Color secondary,
    Color tertiary, {
    bool achromatic = false,
  }) {
    final colorA = normalizeAmbientColor(
      primary,
      minSat: achromatic ? 0.04 : 0.18,
      maxSat: achromatic ? 0.14 : 0.56,
      minLight: 0.14,
      maxLight: 0.27,
      maxLuminance: 0.095,
    );
    final colorB = normalizeAmbientColor(
      secondary,
      minSat: achromatic ? 0.04 : 0.16,
      maxSat: achromatic ? 0.12 : 0.52,
      minLight: 0.12,
      maxLight: 0.24,
      maxLuminance: 0.085,
    );
    final colorC = normalizeAmbientColor(
      tertiary,
      minSat: achromatic ? 0.03 : 0.14,
      maxSat: achromatic ? 0.10 : 0.46,
      minLight: 0.09,
      maxLight: 0.19,
      maxLuminance: 0.065,
    );
    final colorD = normalizeAmbientColor(
      primary,
      minSat: achromatic ? 0.02 : 0.08,
      maxSat: achromatic ? 0.07 : 0.28,
      minLight: 0.05,
      maxLight: 0.09,
      maxLuminance: 0.025,
    );
    return AmbientPalette(
      colorA: colorA,
      colorB: colorB,
      colorC: colorC,
      colorD: colorD,
    );
  }

  /// Decodes compressed image [bytes] downsampled to [sampleSize]x[sampleSize]
  /// and extracts its [AmbientPalette].
  static Future<AmbientPalette?> extractFromEncodedBytes(
    Uint8List bytes, {
    AmbientPalette? fallback,
  }) async {
    if (bytes.isEmpty) return null;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: sampleSize,
        targetHeight: sampleSize,
      );
      frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return extractFromRgba(
        rgba,
        image.width,
        image.height,
        fallback: fallback,
      );
    } catch (_) {
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
    }
  }

  /// Extracts an [AmbientPalette] asynchronously from an image file on disk.
  static Future<AmbientPalette?> extractFromFile(
    String filePath, {
    AmbientPalette? fallback,
  }) async {
    if (filePath.trim().isEmpty) return null;
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return await extractFromEncodedBytes(bytes, fallback: fallback);
    } catch (_) {
      return null;
    }
  }

  /// Extracts an [AmbientPalette] from any Flutter [ImageProvider].
  static Future<AmbientPalette?> extractFromImageProvider(
    ImageProvider provider, {
    AmbientPalette? fallback,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ??
        (Platform.environment.containsKey('FLUTTER_TEST')
            ? null
            : const Duration(seconds: 6));
    final completer = Completer<AmbientPalette?>();
    late final ImageStream stream;
    try {
      stream = provider.resolve(
        const ImageConfiguration(size: Size(32, 32)),
      );
    } catch (_) {
      return null;
    }
    late final ImageStreamListener listener;
    Timer? timeoutTimer;
    var settled = false;

    void finish(AmbientPalette? result) {
      if (settled) return;
      settled = true;
      timeoutTimer?.cancel();
      timeoutTimer = null;
      stream.removeListener(listener);
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    listener = ImageStreamListener(
      (ImageInfo info, bool synchronousCall) async {
        stream.removeListener(listener);
        try {
          final byteData = await info.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (byteData == null) {
            finish(null);
            return;
          }
          final rgba = byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          );
          finish(
            extractFromRgba(
              rgba,
              info.image.width,
              info.image.height,
              fallback: fallback,
            ),
          );
        } catch (_) {
          finish(null);
        } finally {
          info.dispose();
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        finish(null);
      },
    );

    stream.addListener(listener);
    if (!settled && effectiveTimeout != null) {
      timeoutTimer = Timer(effectiveTimeout, () {
        finish(null);
      });
    }
    return completer.future;
  }
}
