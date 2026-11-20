import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

Uint8List _solidRgba(
  int width,
  int height, {
  required int r,
  required int g,
  required int b,
  int a = 255,
}) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    final o = i * 4;
    bytes[o] = r;
    bytes[o + 1] = g;
    bytes[o + 2] = b;
    bytes[o + 3] = a;
  }
  return bytes;
}

Uint8List _encodeRgbaPng(int width, int height, Uint8List rgba) {
  int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : (crc >>> 1);
      }
    }
    return crc ^ 0xFFFFFFFF;
  }

  void writeUint32BE(BytesBuilder out, int value) {
    out.addByte((value >> 24) & 0xFF);
    out.addByte((value >> 16) & 0xFF);
    out.addByte((value >> 8) & 0xFF);
    out.addByte(value & 0xFF);
  }

  void writeChunk(BytesBuilder out, String type, List<int> data) {
    final typeAndData = <int>[...type.codeUnits, ...data];
    writeUint32BE(out, data.length);
    out.add(typeAndData);
    writeUint32BE(out, crc32(typeAndData));
  }

  final out = BytesBuilder();
  out.add([137, 80, 78, 71, 13, 10, 26, 10]);

  final ihdr = BytesBuilder();
  writeUint32BE(ihdr, width);
  writeUint32BE(ihdr, height);
  ihdr.add([8, 6, 0, 0, 0]); // 8-bit RGBA
  writeChunk(out, 'IHDR', ihdr.toBytes());

  final rawScanlines = BytesBuilder();
  final rowBytes = width * 4;
  for (var y = 0; y < height; y++) {
    rawScanlines.addByte(0); // Filter type 0 (None)
    final start = y * rowBytes;
    rawScanlines.add(rgba.sublist(start, start + rowBytes));
  }
  writeChunk(out, 'IDAT', zlib.encode(rawScanlines.toBytes()));
  writeChunk(out, 'IEND', const []);
  return out.toBytes();
}

double _hueDistance(double h1, double h2) {
  final diff = (h1 - h2).abs() % 360.0;
  return diff > 180.0 ? 360.0 - diff : diff;
}

TrackInfo _makeTrack({
  required String id,
  required String title,
  String artist = 'Miles Davis',
  String album = 'Kind of Blue',
  String? coverUrl,
  String? albumArtUrl,
  String? artworkCacheKey,
}) {
  return TrackInfo(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: const Duration(minutes: 4),
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 96000,
      bitDepth: 24,
      channels: 2,
    ),
    coverUrl: coverUrl,
    albumArtUrl: albumArtUrl,
    artworkCacheKey: artworkCacheKey,
  );
}

class _PaletteTestAudioService extends MockAudioService {
  final Map<String, String> cachePathsById = {};
  final List<({String id, int maxDim})> artworkRequests = [];

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    artworkRequests.add((id: trackId, maxDim: maxDim));
    final cachePath = cachePathsById[trackId];
    if (cachePath != null) {
      return {
        'found': true,
        'cache_path': cachePath,
        'mime_type': 'image/png',
      };
    }
    return {'found': false};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AmbientPalette', () {
    test('fallbackFor handles null and deterministic non-null selection', () {
      expect(
        AmbientPalette.fallbackFor(null),
        AmbientPalette.defaultFallback,
      );

      final trackA = _makeTrack(
        id: 't1',
        title: 'So What',
        album: 'Kind of Blue',
      );
      final trackASameMeta = _makeTrack(
        id: 't99',
        title: '  so what ',
        album: 'kind of blue',
      );
      final first = AmbientPalette.fallbackFor(trackA);
      expect(first, AmbientPalette.fallbackFor(trackASameMeta));

      final seenPalettes = <AmbientPalette>{};
      for (var i = 0; i < 40; i++) {
        final t = _makeTrack(
          id: 'track_$i',
          title: 'Track Title $i',
          album: 'Album Name ${i * 7}',
        );
        final p = AmbientPalette.fallbackFor(t);
        seenPalettes.add(p);
        for (final color in p.colors) {
          expect(color.computeLuminance(), lessThanOrEqualTo(0.08));
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.textSecondary, color),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
      expect(seenPalettes.length, 4);
    });

    test('lerp, equality, hashCode, and colors getter', () {
      const a = AmbientPalette(
        colorA: Color(0xFF102030),
        colorB: Color(0xFF203040),
        colorC: Color(0xFF304050),
        colorD: Color(0xFF081018),
      );
      const b = AmbientPalette(
        colorA: Color(0xFF304050),
        colorB: Color(0xFF405060),
        colorC: Color(0xFF506070),
        colorD: Color(0xFF182028),
      );
      const aCopy = AmbientPalette(
        colorA: Color(0xFF102030),
        colorB: Color(0xFF203040),
        colorC: Color(0xFF304050),
        colorD: Color(0xFF081018),
      );

      expect(a, equals(aCopy));
      expect(a.hashCode, equals(aCopy.hashCode));
      expect(a, isNot(equals(b)));
      expect(a.colors, [a.colorA, a.colorB, a.colorC, a.colorD]);

      expect(AmbientPalette.lerp(a, b, 0.0), a);
      expect(AmbientPalette.lerp(a, b, 1.0), b);
      expect(AmbientPalette.lerp(a, b, -0.5), a);
      expect(AmbientPalette.lerp(a, b, 1.5), b);

      final mid = AmbientPalette.lerp(a, b, 0.5);
      expect(mid.colorA, Color.lerp(a.colorA, b.colorA, 0.5));
      expect(mid.colorB, Color.lerp(a.colorB, b.colorB, 0.5));
      expect(mid.colorC, Color.lerp(a.colorC, b.colorC, 0.5));
      expect(mid.colorD, Color.lerp(a.colorD, b.colorD, 0.5));
    });
  });

  group('ArtworkPaletteExtractor', () {
    test('red, blue, and teal RGBA covers produce distinct hue-aligned palettes', () {
      final redRgba = _solidRgba(32, 32, r: 225, g: 30, b: 40);
      final blueRgba = _solidRgba(32, 32, r: 30, g: 90, b: 235);
      final tealRgba = _solidRgba(32, 32, r: 15, g: 185, b: 170);

      final redPalette = ArtworkPaletteExtractor.extractFromRgba(redRgba, 32, 32);
      final bluePalette = ArtworkPaletteExtractor.extractFromRgba(blueRgba, 32, 32);
      final tealPalette = ArtworkPaletteExtractor.extractFromRgba(tealRgba, 32, 32);

      expect(redPalette, isNot(equals(bluePalette)));
      expect(bluePalette, isNot(equals(tealPalette)));
      expect(redPalette, isNot(equals(tealPalette)));

      final redHue = HSLColor.fromColor(redPalette.colorA).hue;
      final blueHue = HSLColor.fromColor(bluePalette.colorA).hue;
      final tealHue = HSLColor.fromColor(tealPalette.colorA).hue;

      expect(_hueDistance(redHue, 357.0), lessThan(20.0));
      expect(_hueDistance(blueHue, 222.0), lessThan(20.0));
      expect(_hueDistance(tealHue, 175.0), lessThan(20.0));

      // Single-hue cover synthesizes secondary (+28 deg) & tertiary (-26 deg).
      final secHue = HSLColor.fromColor(bluePalette.colorB).hue;
      final terHue = HSLColor.fromColor(bluePalette.colorC).hue;
      expect(_hueDistance(secHue, (blueHue + 28.0) % 360.0), lessThan(6.0));
      expect(
        _hueDistance(terHue, ((blueHue - 26.0) % 360.0 + 360.0) % 360.0),
        lessThan(6.0),
      );
    });

    test('multi-color cover selects primary, secondary, and tertiary >= 35 deg apart', () {
      const width = 32;
      const height = 32;
      final rgba = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final o = (y * width + x) * 4;
          if (y < 18) {
            // Dominant crimson (~355 deg)
            rgba[o] = 220;
            rgba[o + 1] = 30;
            rgba[o + 2] = 45;
          } else if (y < 26) {
            // Secondary deep blue (~225 deg)
            rgba[o] = 30;
            rgba[o + 1] = 100;
            rgba[o + 2] = 225;
          } else {
            // Tertiary emerald green (~145 deg)
            rgba[o] = 35;
            rgba[o + 1] = 195;
            rgba[o + 2] = 100;
          }
          rgba[o + 3] = 255;
        }
      }

      final palette = ArtworkPaletteExtractor.extractFromRgba(rgba, width, height);
      final hA = HSLColor.fromColor(palette.colorA).hue;
      final hB = HSLColor.fromColor(palette.colorB).hue;
      final hC = HSLColor.fromColor(palette.colorC).hue;

      expect(_hueDistance(hA, 355.0), lessThan(20.0));
      expect(_hueDistance(hB, 225.0), lessThan(20.0));
      expect(_hueDistance(hC, 145.0), lessThan(20.0));
    });

    test('extreme covers enforce luminance caps, WCAG AA contrast, and black floor', () {
      final extremes = <String, Uint8List>{
        'pure_white': _solidRgba(32, 32, r: 255, g: 255, b: 255),
        'pure_black': _solidRgba(32, 32, r: 0, g: 0, b: 0),
        'neon_yellow': _solidRgba(32, 32, r: 255, g: 255, b: 0),
        'neon_magenta': _solidRgba(32, 32, r: 255, g: 0, b: 255),
      };

      for (final entry in extremes.entries) {
        final palette = ArtworkPaletteExtractor.extractFromRgba(
          entry.value,
          32,
          32,
        );

        expect(
          palette.colorA.computeLuminance(),
          lessThanOrEqualTo(0.095),
          reason: '${entry.key} colorA luminance',
        );
        expect(
          palette.colorB.computeLuminance(),
          lessThanOrEqualTo(0.085),
          reason: '${entry.key} colorB luminance',
        );
        expect(
          palette.colorC.computeLuminance(),
          lessThanOrEqualTo(0.065),
          reason: '${entry.key} colorC luminance',
        );
        expect(
          palette.colorD.computeLuminance(),
          lessThanOrEqualTo(0.025),
          reason: '${entry.key} colorD luminance',
        );

        for (final c in palette.colors) {
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.textSecondary, c),
            greaterThanOrEqualTo(4.5),
            reason: '${entry.key} contrast vs textSecondary for $c',
          );
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.textPrimary, c),
            greaterThanOrEqualTo(7.0),
            reason: '${entry.key} contrast vs textPrimary for $c',
          );
          expect(
            HSLColor.fromColor(c).lightness,
            greaterThanOrEqualTo(0.049),
            reason: '${entry.key} lightness floor for $c',
          );
        }
      }

      final blackPalette = ArtworkPaletteExtractor.extractFromRgba(
        extremes['pure_black']!,
        32,
        32,
      );
      for (final c in blackPalette.colors) {
        expect(c, isNot(equals(const Color(0xFF000000))));
        expect(HSLColor.fromColor(c).lightness, greaterThanOrEqualTo(0.05));
      }
    });

    test('achromatic grayscale cover yields cool-slate low-saturation palette', () {
      final grayRgba = _solidRgba(32, 32, r: 128, g: 128, b: 128);
      final palette = ArtworkPaletteExtractor.extractFromRgba(grayRgba, 32, 32);

      for (final c in palette.colors) {
        final hsl = HSLColor.fromColor(c);
        expect(hsl.saturation, lessThanOrEqualTo(0.141));
        expect(c.computeLuminance(), lessThanOrEqualTo(0.095));
      }
    });

    test('transparent pixels are ignored and all-transparent returns fallback', () {
      final allTransparent = _solidRgba(16, 16, r: 255, g: 0, b: 0, a: 0);
      const customFallback = AmbientPalette(
        colorA: Color(0xFF211834),
        colorB: Color(0xFF1D223C),
        colorC: Color(0xFF162834),
        colorD: Color(0xFF0D0F16),
      );

      expect(
        ArtworkPaletteExtractor.extractFromRgba(
          allTransparent,
          16,
          16,
          fallback: customFallback,
        ),
        customFallback,
      );

      final semiTransparent = _solidRgba(16, 16, r: 255, g: 255, b: 0, a: 127);
      expect(
        ArtworkPaletteExtractor.extractFromRgba(semiTransparent, 16, 16),
        AmbientPalette.defaultFallback,
      );

      // Mix transparent black pixels (a=0) with opaque green pixels (a=255).
      final mixed = Uint8List(16 * 16 * 4);
      for (var i = 0; i < 16 * 16; i++) {
        final o = i * 4;
        if (i < 128) {
          mixed[o] = 0;
          mixed[o + 1] = 0;
          mixed[o + 2] = 0;
          mixed[o + 3] = 0;
        } else {
          mixed[o] = 20;
          mixed[o + 1] = 210;
          mixed[o + 2] = 85;
          mixed[o + 3] = 255;
        }
      }
      final mixedPalette = ArtworkPaletteExtractor.extractFromRgba(mixed, 16, 16);
      final hue = HSLColor.fromColor(mixedPalette.colorA).hue;
      expect(_hueDistance(hue, 140.0), lessThan(20.0));
    });

    test('extractFromEncodedBytes, extractFromFile, and extractFromImageProvider decode real PNG bytes', () async {
      final pngBytes = _encodeRgbaPng(
        8,
        8,
        _solidRgba(8, 8, r: 20, g: 180, b: 195),
      );

      final decodedPalette = await ArtworkPaletteExtractor.extractFromEncodedBytes(
        pngBytes,
      );
      expect(decodedPalette, isNotNull);
      expect(
        _hueDistance(HSLColor.fromColor(decodedPalette!.colorA).hue, 185.0),
        lessThan(20.0),
      );
      expect(decodedPalette.colorA.computeLuminance(), lessThanOrEqualTo(0.095));

      // Invalid / empty bytes return null safely.
      expect(
        await ArtworkPaletteExtractor.extractFromEncodedBytes(Uint8List(0)),
        isNull,
      );
      expect(
        await ArtworkPaletteExtractor.extractFromEncodedBytes(
          Uint8List.fromList([1, 2, 3, 4]),
        ),
        isNull,
      );

      // File extraction on real temp PNG file.
      final tempDir = Directory.systemTemp.createTempSync('lumina_palette_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final pngFile = File('${tempDir.path}${Platform.pathSeparator}cover.png');
      await pngFile.writeAsBytes(pngBytes);

      final filePalette = await ArtworkPaletteExtractor.extractFromFile(pngFile.path);
      expect(filePalette, decodedPalette);
      expect(
        await ArtworkPaletteExtractor.extractFromFile('${tempDir.path}${Platform.pathSeparator}missing.png'),
        isNull,
      );

      // ImageProvider extraction via MemoryImage.
      final providerPalette = await ArtworkPaletteExtractor.extractFromImageProvider(
        MemoryImage(pngBytes),
      );
      expect(providerPalette, decodedPalette);
    });
  });

  group('ArtworkPaletteService', () {
    test('caches palettes, enforces 128-entry LRU eviction, and clears cleanly', () {
      final service = ArtworkPaletteService();
      expect(service.maxEntries, 128);

      for (var i = 0; i < 128; i++) {
        service.putCachedSync(
          'key_$i',
          AmbientPalette(
            colorA: Color(0xFF101010 + i),
            colorB: const Color(0xFF1A1A2E),
            colorC: const Color(0xFF16213E),
            colorD: const Color(0xFF0B0F17),
          ),
        );
      }
      expect(service.cacheLength, 128);

      // Touch key_0 so it becomes MRU; inserting key_128 & key_129 evicts key_1 & key_2.
      expect(service.getCachedSync('key_0'), isNotNull);

      service.putCachedSync('key_128', AmbientPalette.defaultFallback);
      service.putCachedSync('key_129', AmbientPalette.defaultFallback);

      expect(service.cacheLength, 128);
      expect(service.getCachedSync('key_0'), isNotNull);
      expect(service.getCachedSync('key_1'), isNull);
      expect(service.getCachedSync('key_2'), isNull);
      expect(service.getCachedSync('key_128'), isNotNull);
      expect(service.getCachedSync('key_129'), isNotNull);

      service.clearCache();
      expect(service.cacheLength, 0);
    });

    test('deduplicates concurrent in-flight resolvePalette calls', () async {
      final completer = Completer<AmbientPalette?>();
      var extractCalls = 0;

      final service = ArtworkPaletteService(
        fileExtractorOverride: (path) {
          extractCalls++;
          return completer.future;
        },
      );

      final track = _makeTrack(id: 't1', title: 'Track 1');
      final f1 = service.resolvePalette(
        track: track,
        resolvedCachePath: '/covers/album_a.png',
      );
      final f2 = service.resolvePalette(
        track: track,
        resolvedCachePath: '/covers/album_a.png',
      );

      expect(extractCalls, 1);

      const expected = AmbientPalette(
        colorA: Color(0xFF2B193D),
        colorB: Color(0xFF3A1F4B),
        colorC: Color(0xFF1B2438),
        colorD: Color(0xFF0E0B14),
      );
      completer.complete(expected);

      final results = await Future.wait([f1, f2]);
      expect(results[0], expected);
      expect(results[1], expected);
      expect(extractCalls, 1);
    });

    test('shares cached palette across tracks on the same album and preserves maxDim 0', () async {
      final tempDir = Directory.systemTemp.createTempSync('lumina_svc_album_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final coverFile = File('${tempDir.path}${Platform.pathSeparator}kind_of_blue.png');
      await coverFile.writeAsBytes(
        _encodeRgbaPng(8, 8, _solidRgba(8, 8, r: 30, g: 110, b: 220)),
      );

      final audioService = _PaletteTestAudioService();
      audioService.cachePathsById['alb_1'] = coverFile.path;
      audioService.cachePathsById['t1'] = coverFile.path;

      final libraryCache = LibraryIndexCache();
      final track1 = _makeTrack(id: 't1', title: 'So What', album: 'Kind of Blue');
      final track2 = _makeTrack(id: 't2', title: 'Freddie Freeloader', album: 'Kind of Blue');
      libraryCache.seedSync(
        albums: const [
          CanonicalAlbumSummary(
            id: 'alb_1',
            title: 'Kind of Blue',
            artist: 'Miles Davis',
          ),
        ],
        tracks: [track1, track2],
      );

      var fileOverrideCalls = 0;
      const expectedPalette = AmbientPalette(
        colorA: Color(0xFF152942),
        colorB: Color(0xFF1B2447),
        colorC: Color(0xFF102A3A),
        colorD: Color(0xFF0A0E17),
      );

      final service = ArtworkPaletteService(
        fileExtractorOverride: (path) async {
          fileOverrideCalls++;
          expect(path, coverFile.path);
          return expectedPalette;
        },
      );

      final p1 = await service.resolvePalette(
        track: track1,
        audioService: audioService,
        libraryCache: libraryCache,
      );
      expect(p1, expectedPalette);
      expect(fileOverrideCalls, 1);
      expect(audioService.artworkRequests, isNotEmpty);
      expect(
        audioService.artworkRequests.every((r) => r.maxDim == 0),
        isTrue,
      );

      // Resolving another track on the same album reuses the cached palette without extra decoding or getArtwork calls.
      final requestsBeforeSecondTrack = audioService.artworkRequests.length;
      final p2 = await service.resolvePalette(
        track: track2,
        audioService: audioService,
        libraryCache: libraryCache,
      );
      expect(p2, expectedPalette);
      expect(fileOverrideCalls, 1);
      expect(audioService.artworkRequests.length, requestsBeforeSecondTrack);
      expect(
        service.getCachedSync(service.cacheKeyFor(resolvedCachePath: coverFile.path)),
        expectedPalette,
      );
      expect(
        service.getCachedSync(service.cacheKeyFor(track: track2)),
        expectedPalette,
      );
    });

    test('supports urlExtractorOverride and returns fallbackFor on missing or failing artwork', () async {
      final service = ArtworkPaletteService(
        fileExtractorOverride: (_) async => null,
        urlExtractorOverride: (url) async {
          if (url.contains('ok')) {
            return const AmbientPalette(
              colorA: Color(0xFF1E3246),
              colorB: Color(0xFF28244A),
              colorC: Color(0xFF15303A),
              colorD: Color(0xFF0C1018),
            );
          }
          return null;
        },
      );

      final trackWithUrl = _makeTrack(
        id: 't_url',
        title: 'Stream Track',
        album: 'Stream Album',
        coverUrl: 'https://cdn.example.com/ok.jpg',
      );
      final urlPalette = await service.resolvePalette(track: trackWithUrl);
      expect(urlPalette.colorA, const Color(0xFF1E3246));

      final missingTrack = _makeTrack(
        id: 't_missing',
        title: 'No Cover Track',
        album: 'No Cover Album',
      );
      final fallback = await service.resolvePalette(
        track: missingTrack,
        resolvedCachePath: '/does/not/exist.png',
      );
      expect(fallback, AmbientPalette.fallbackFor(missingTrack));

      final audioService = _PaletteTestAudioService();
      final uncachedFallback = await service.resolvePalette(
        track: missingTrack,
        audioService: audioService,
      );
      expect(uncachedFallback, AmbientPalette.fallbackFor(missingTrack));
      expect(audioService.artworkRequests.single.maxDim, 0);
    });
  });
}
