import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../models/playback_state.dart';
import 'audio_service.dart';
import 'library_index_cache.dart';

/// 4-color WCAG-safe dark ambient palette aligned to `shaders/mesh_fluid_bg.frag`.
@immutable
class AmbientPalette {
  final Color colorA;
  final Color colorB;
  final Color colorC;
  final Color colorD;

  const AmbientPalette({
    required this.colorA,
    required this.colorB,
    required this.colorC,
    required this.colorD,
  });

  static const AmbientPalette defaultFallback = AmbientPalette(
    colorA: Color(0xFF13283C),
    colorB: Color(0xFF1F2347),
    colorC: Color(0xFF0E3039),
    colorD: Color(0xFF0B0F17),
  );

  static const List<AmbientPalette> _fallbackPalettes = [
    defaultFallback,
    AmbientPalette(
      colorA: Color(0xFF2D1635),
      colorB: Color(0xFF3A1A2E),
      colorC: Color(0xFF1D1736),
      colorD: Color(0xFF0E0B14),
    ),
    AmbientPalette(
      colorA: Color(0xFF123029),
      colorB: Color(0xFF162C38),
      colorC: Color(0xFF1E2924),
      colorD: Color(0xFF0A110F),
    ),
    AmbientPalette(
      colorA: Color(0xFF332016),
      colorB: Color(0xFF291D2E),
      colorC: Color(0xFF1F2632),
      colorD: Color(0xFF100C0B),
    ),
  ];

  /// Deterministically selects a dark WCAG-safe fallback palette for [track].
  static AmbientPalette fallbackFor(TrackInfo? track) {
    if (track == null) return defaultFallback;
    final seed = '${track.album.trim().toLowerCase()}|${track.title.trim().toLowerCase()}';
    if (seed == '|') return defaultFallback;
    // FNV-1a 32-bit hash for cross-run determinism (unlike String.hashCode).
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return _fallbackPalettes[hash % _fallbackPalettes.length];
  }

  /// Linearly interpolates between two [AmbientPalette] instances.
  static AmbientPalette lerp(AmbientPalette a, AmbientPalette b, double t) {
    final clamped = t.clamp(0.0, 1.0).toDouble();
    return AmbientPalette(
      colorA: Color.lerp(a.colorA, b.colorA, clamped) ?? a.colorA,
      colorB: Color.lerp(a.colorB, b.colorB, clamped) ?? a.colorB,
      colorC: Color.lerp(a.colorC, b.colorC, clamped) ?? a.colorC,
      colorD: Color.lerp(a.colorD, b.colorD, clamped) ?? a.colorD,
    );
  }

  List<Color> get colors => [colorA, colorB, colorC, colorD];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AmbientPalette &&
        other.colorA == colorA &&
        other.colorB == colorB &&
        other.colorC == colorC &&
        other.colorD == colorD;
  }

  @override
  int get hashCode => Object.hash(colorA, colorB, colorC, colorD);

  @override
  String toString() =>
      'AmbientPalette(A: $colorA, B: $colorB, C: $colorC, D: $colorD)';
}

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
  }) async {
    final completer = Completer<AmbientPalette?>();
    final stream = provider.resolve(
      const ImageConfiguration(size: Size(32, 32)),
    );
    late final ImageStreamListener listener;
    var settled = false;

    void finish(AmbientPalette? result) {
      if (settled) return;
      settled = true;
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
    return completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        finish(null);
        return null;
      },
    );
  }
}

/// Service resolving and LRU-caching [AmbientPalette]s for playing tracks.
class ArtworkPaletteService {
  static const int defaultMaxEntries = 128;

  final int maxEntries;
  final Future<AmbientPalette?> Function(String path)? fileExtractorOverride;
  final Future<AmbientPalette?> Function(String url)? urlExtractorOverride;

  final LinkedHashMap<String, AmbientPalette> _cache =
      LinkedHashMap<String, AmbientPalette>();
  final Map<String, Future<AmbientPalette>> _inFlight = {};

  ArtworkPaletteService({
    this.maxEntries = defaultMaxEntries,
    this.fileExtractorOverride,
    this.urlExtractorOverride,
  }) : assert(maxEntries > 0);

  static bool _isHttpUrl(String value) =>
      value.startsWith('http://') || value.startsWith('https://');

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String? _albumKeyForTrack(TrackInfo? track) {
    if (track == null) return null;
    final album = track.album.trim().toLowerCase();
    if (album.isEmpty) return null;
    final artist = track.effectiveAlbumArtist.trim().toLowerCase();
    return 'album:$artist|$album';
  }

  /// Computes a stable cache key for [resolvedCachePath], [resolvedCoverUrl], or [track].
  String cacheKeyFor({
    TrackInfo? track,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) {
    final cp = resolvedCachePath?.trim();
    if (cp != null && cp.isNotEmpty) {
      return 'file:$cp';
    }
    final cu = resolvedCoverUrl?.trim();
    if (cu != null && cu.isNotEmpty) {
      return 'url:$cu';
    }
    if (track != null) {
      final ack = track.artworkCacheKey?.trim();
      if (ack != null && ack.isNotEmpty) {
        return 'art:$ack';
      }
      final directUrl = _firstNonEmpty([track.coverUrl, track.albumArtUrl]);
      if (directUrl != null) {
        return _isHttpUrl(directUrl) ? 'url:$directUrl' : 'file:$directUrl';
      }
      final albumKey = _albumKeyForTrack(track);
      if (albumKey != null) {
        return albumKey;
      }
      final id = track.id.trim();
      if (id.isNotEmpty) {
        return 'track:$id';
      }
      return 'title:${track.title.trim().toLowerCase()}';
    }
    return 'default';
  }

  /// Synchronous LRU lookup; promotes hit to most-recently-used.
  AmbientPalette? getCachedSync(String key) {
    final hit = _cache.remove(key);
    if (hit == null) return null;
    _cache[key] = hit;
    return hit;
  }

  /// Inserts or updates [key] in the bounded LRU cache.
  void putCachedSync(String key, AmbientPalette palette) {
    if (key.isEmpty) return;
    _cache.remove(key);
    _cache[key] = palette;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  int get cacheLength => _cache.length;

  void clearCache() {
    _cache.clear();
    _inFlight.clear();
  }

  /// Resolves an [AmbientPalette] for [track] or explicit artwork path/URL,
  /// deduplicating in-flight work and preserving `maxDim: 0` on disk queries.
  Future<AmbientPalette> resolvePalette({
    TrackInfo? track,
    AudioService? audioService,
    LibraryIndexCache? libraryCache,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) {
    final syncHit = _lookupSync(
      track: track,
      libraryCache: libraryCache,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    );
    if (syncHit != null) {
      return Future.value(syncHit);
    }

    final primaryKey = cacheKeyFor(
      track: track,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    );
    final existing = _inFlight[primaryKey];
    if (existing != null) {
      return existing;
    }

    final future = _resolveImpl(
      track: track,
      audioService: audioService,
      libraryCache: libraryCache,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    ).whenComplete(() {
      _inFlight.remove(primaryKey);
    });

    _inFlight[primaryKey] = future;
    return future;
  }

  AmbientPalette? _lookupSync({
    TrackInfo? track,
    LibraryIndexCache? libraryCache,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) {
    final cp = resolvedCachePath?.trim();
    if (cp != null && cp.isNotEmpty) {
      return getCachedSync('file:$cp');
    }
    final cu = resolvedCoverUrl?.trim();
    if (cu != null && cu.isNotEmpty) {
      return getCachedSync('url:$cu');
    }
    if (track == null) return null;

    final ack = track.artworkCacheKey?.trim();
    if (ack != null && ack.isNotEmpty) {
      final hit = getCachedSync('art:$ack');
      if (hit != null) return hit;
    }

    final directUrl = _firstNonEmpty([track.coverUrl, track.albumArtUrl]);
    if (directUrl != null) {
      final directKey =
          _isHttpUrl(directUrl) ? 'url:$directUrl' : 'file:$directUrl';
      return getCachedSync(directKey);
    }

    if (track.id.trim().isNotEmpty) {
      final hit = getCachedSync('track:${track.id.trim()}');
      if (hit != null) return hit;
    }

    final canonicalAlbumId = libraryCache?.resolveAlbumIdForTrack(track);
    if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty) {
      final hit = getCachedSync('canonical_album:$canonicalAlbumId');
      if (hit != null) return hit;
    }

    final albumKey = _albumKeyForTrack(track);
    if (albumKey != null) {
      final hit = getCachedSync(albumKey);
      if (hit != null) return hit;
    }

    return null;
  }

  Future<AmbientPalette> _resolveImpl({
    TrackInfo? track,
    AudioService? audioService,
    LibraryIndexCache? libraryCache,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) async {
    final fallback = AmbientPalette.fallbackFor(track);
    final canonicalAlbumId =
        track != null ? libraryCache?.resolveAlbumIdForTrack(track) : null;

    void storeResolved(
      AmbientPalette palette, {
      String? resolvedKey,
    }) {
      if (resolvedKey != null && resolvedKey.isNotEmpty) {
        putCachedSync(resolvedKey, palette);
      }
      if (track != null) {
        final ack = track.artworkCacheKey?.trim();
        if (ack != null && ack.isNotEmpty) {
          putCachedSync('art:$ack', palette);
        }
        if (track.id.trim().isNotEmpty) {
          putCachedSync('track:${track.id.trim()}', palette);
        }
        if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty) {
          putCachedSync('canonical_album:$canonicalAlbumId', palette);
        }
        final albumKey = _albumKeyForTrack(track);
        if (albumKey != null) {
          putCachedSync(albumKey, palette);
        }
      }
    }

    // 1. Explicit local file path.
    final cp = resolvedCachePath?.trim();
    if (cp != null && cp.isNotEmpty) {
      final extracted = await _extractFile(cp, fallback: fallback);
      if (extracted != null) {
        storeResolved(extracted, resolvedKey: 'file:$cp');
        return extracted;
      }
      final cu = resolvedCoverUrl?.trim();
      if (cu != null && cu.isNotEmpty) {
        final urlExtracted = await _extractUrlOrPath(cu, fallback: fallback);
        if (urlExtracted != null) {
          storeResolved(urlExtracted, resolvedKey: 'url:$cu');
          return urlExtracted;
        }
      }
      return fallback;
    }

    // 2. Explicit cover URL.
    final cu = resolvedCoverUrl?.trim();
    if (cu != null && cu.isNotEmpty) {
      final extracted = await _extractUrlOrPath(cu, fallback: fallback);
      if (extracted != null) {
        storeResolved(extracted, resolvedKey: 'url:$cu');
        return extracted;
      }
      return fallback;
    }

    if (track == null) return fallback;

    // 3. Direct URL or local file path on TrackInfo.
    final directUrl = _firstNonEmpty([track.coverUrl, track.albumArtUrl]);
    if (directUrl != null && !directUrl.startsWith('/api/')) {
      final directKey =
          _isHttpUrl(directUrl) ? 'url:$directUrl' : 'file:$directUrl';
      final cachedDirect = getCachedSync(directKey);
      if (cachedDirect != null) {
        storeResolved(cachedDirect);
        return cachedDirect;
      }
      final extracted = _isHttpUrl(directUrl)
          ? await _extractUrlOrPath(directUrl, fallback: fallback)
          : await _extractFile(directUrl, fallback: fallback);
      if (extracted != null) {
        storeResolved(extracted, resolvedKey: directKey);
        return extracted;
      }
    }

    // 4. Synchronous path from LibraryIndexCache.
    if (libraryCache != null) {
      final syncPath = _firstNonEmpty([
        track.id.isNotEmpty ? libraryCache.getArtworkPathSync(track.id) : null,
        (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty)
            ? libraryCache.getArtworkPathSync(canonicalAlbumId)
            : null,
      ]);
      if (syncPath != null) {
        final key = 'file:$syncPath';
        final cached = getCachedSync(key);
        if (cached != null) {
          storeResolved(cached);
          return cached;
        }
        final extracted = await _extractFile(syncPath, fallback: fallback);
        if (extracted != null) {
          storeResolved(extracted, resolvedKey: key);
          return extracted;
        }
      }
    }

    // 5. Asynchronous artwork resolution preserving full-res disk contract (maxDim: 0).
    if (audioService != null) {
      String? resolvedPath;
      if (libraryCache != null) {
        if (canonicalAlbumId != null &&
            canonicalAlbumId.isNotEmpty &&
            !libraryCache.hasArtworkCached(canonicalAlbumId)) {
          try {
            resolvedPath = await libraryCache.resolveArtworkPath(
              audioService,
              canonicalAlbumId,
              maxDim: 0,
            );
          } catch (_) {}
        }
        if ((resolvedPath == null || resolvedPath.isEmpty) &&
            track.id.isNotEmpty &&
            !libraryCache.hasArtworkCached(track.id)) {
          try {
            resolvedPath = await libraryCache.resolveArtworkPath(
              audioService,
              track.id,
              path: track.filePath,
              maxDim: 0,
            );
          } catch (_) {}
        }
      } else if (track.id.isNotEmpty) {
        try {
          final res = await audioService.getArtwork(
            track.id,
            path: track.filePath,
            maxDim: 0,
          );
          if (res != null && res['found'] == true) {
            final candidate = res['cache_path']?.toString();
            if (candidate != null && candidate.isNotEmpty) {
              resolvedPath = candidate;
            }
          }
        } catch (_) {}
      }

      if (resolvedPath != null && resolvedPath.isNotEmpty) {
        final key = 'file:$resolvedPath';
        final cached = getCachedSync(key);
        if (cached != null) {
          storeResolved(cached);
          return cached;
        }
        final extracted = await _extractFile(resolvedPath, fallback: fallback);
        if (extracted != null) {
          storeResolved(extracted, resolvedKey: key);
          return extracted;
        }
      }
    }

    return fallback;
  }

  Future<AmbientPalette?> _extractFile(
    String path, {
    required AmbientPalette fallback,
  }) async {
    if (fileExtractorOverride != null) {
      try {
        return await fileExtractorOverride!(path);
      } catch (_) {
        return null;
      }
    }
    return ArtworkPaletteExtractor.extractFromFile(path, fallback: fallback);
  }

  Future<AmbientPalette?> _extractUrlOrPath(
    String url, {
    required AmbientPalette fallback,
  }) async {
    if (urlExtractorOverride != null) {
      try {
        return await urlExtractorOverride!(url);
      } catch (_) {
        return null;
      }
    }
    if (!_isHttpUrl(url)) {
      if (url.startsWith('/api/')) return null;
      return ArtworkPaletteExtractor.extractFromFile(url, fallback: fallback);
    }
    return ArtworkPaletteExtractor.extractFromImageProvider(
      NetworkImage(url),
      fallback: fallback,
    );
  }
}
