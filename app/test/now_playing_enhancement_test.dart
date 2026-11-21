import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/lyric.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/shaders/mesh_fluid_painter.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/lyrics/lyrics_view.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/now_playing/now_playing_layout.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/now_playing/spectrum_visualizer.dart';
import 'package:lumina_app/ui/signal_path/quality_badge.dart';
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
  ihdr.add([8, 6, 0, 0, 0]);
  writeChunk(out, 'IHDR', ihdr.toBytes());

  final rawScanlines = BytesBuilder();
  final rowBytes = width * 4;
  for (var y = 0; y < height; y++) {
    rawScanlines.addByte(0);
    final start = y * rowBytes;
    rawScanlines.add(rgba.sublist(start, start + rowBytes));
  }
  writeChunk(out, 'IDAT', zlib.encode(rawScanlines.toBytes()));
  writeChunk(out, 'IEND', const []);
  return out.toBytes();
}

String _writeSolidPng(
  Directory dir,
  String name, {
  required int r,
  required int g,
  required int b,
}) {
  final file = File('${dir.path}${Platform.pathSeparator}$name.png');
  file.writeAsBytesSync(
    _encodeRgbaPng(32, 32, _solidRgba(32, 32, r: r, g: g, b: b)),
  );
  return file.path;
}

double _hueDistance(double h1, double h2) {
  final diff = (h1 - h2).abs() % 360.0;
  return diff > 180.0 ? 360.0 - diff : diff;
}

TrackInfo _makeTrack({
  required String id,
  required String title,
  String artist = 'Test Artist',
  String album = 'Test Album',
  String? coverUrl,
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
    artworkCacheKey: artworkCacheKey,
  );
}

class _LongLyricsMockAudioService extends MockAudioService {
  final List<LyricLine> _longLyrics = List.generate(
    32,
    (i) => LyricLine(
      start: Duration(seconds: i * 4),
      end: Duration(seconds: (i + 1) * 4),
      text: 'Synchronized lyric line number ${i + 1} for scroll testing',
    ),
  );

  final Map<String, String> coverPathsByTrackId = {};

  @override
  List<LyricLine> get currentLyrics => _longLyrics;

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 600,
  }) async {
    final cp = coverPathsByTrackId[trackId];
    if (cp != null) {
      return {'found': true, 'cache_path': cp};
    }
    return {'found': false};
  }
}

MeshFluidBgPainter _bgPainter(WidgetTester tester) {
  final customPaint = tester.widget<CustomPaint>(
    find.byKey(const Key('now_playing_ambient_bg')),
  );
  return customPaint.painter! as MeshFluidBgPainter;
}

void main() {
  group('NowPlayingViewController & Overlay State Persistence', () {
    test('persists mode and lyricsFontScale to JSON and recovers from corrupt JSON', () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'lumina_np_ctrl_test_',
      );
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      final prefsFile = File(
        '${tempDir.path}${Platform.pathSeparator}now_playing_view_prefs.json',
      );

      final ctrl1 = NowPlayingViewController(prefsFileOverride: prefsFile);
      expect(ctrl1.mode, NowPlayingViewMode.split);
      expect(ctrl1.lyricsFontScale, 1.0);
      expect(ctrl1.lyricsSettingsExpanded, isFalse);
      expect(ctrl1.signalPathShowDetails, isTrue);

      var notifyCount = 0;
      ctrl1.addListener(() => notifyCount++);

      ctrl1.setMode(NowPlayingViewMode.cover);
      ctrl1.setLyricsFontScale(2.5); // clamps to 1.6
      ctrl1.setLyricsFontScale(0.2); // clamps to 0.7
      ctrl1.setLyricsFontScale(1.25);
      expect(notifyCount, 4);

      // Scroll offset setters must NOT trigger notifyListeners.
      ctrl1.saveLyricsScrollOffset('trk-1', 145.5);
      ctrl1.saveQueueScrollOffset(88.0);
      expect(notifyCount, 4);
      expect(ctrl1.lyricsScrollOffsetFor('trk-1'), 145.5);
      expect(ctrl1.queueScrollOffset, 88.0);

      ctrl1.dispose();

      // Reload in fresh controller
      final ctrl2 = NowPlayingViewController(prefsFileOverride: prefsFile);
      await ctrl2.load();
      expect(ctrl2.mode, NowPlayingViewMode.cover);
      expect(ctrl2.lyricsFontScale, closeTo(1.25, 0.001));
      ctrl2.dispose();

      // Corrupt JSON falls back safely to defaults
      prefsFile.writeAsStringSync('{not valid json!!');
      final ctrl3 = NowPlayingViewController(prefsFileOverride: prefsFile);
      await ctrl3.load();
      expect(ctrl3.mode, NowPlayingViewMode.split);
      expect(ctrl3.lyricsFontScale, 1.0);
      ctrl3.dispose();
    });

    testWidgets(
      'collapse & re-expand preserves mode, toolbar state, font scale, offset, and lyrics scroll offset',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        final service = _LongLyricsMockAudioService();
        final viewController = NowPlayingViewController();
        addTearDown(() {
          service.dispose();
          viewController.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(
            audioService: service,
            nowPlayingController: viewController,
          ),
        );
        await tester.pumpAndSettle();

        // Expand Now Playing overlay
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

        // Scroll lyrics list down
        await tester.drag(
          find.byKey(const Key('lyrics_list_view')),
          const Offset(0, -180),
        );
        await tester.pumpAndSettle();
        final savedScrollBefore = viewController.lyricsScrollOffsetFor(
          service.currentState.track?.id,
        );
        expect(savedScrollBefore, greaterThan(40.0));

        // Expand lyrics settings toolbar and adjust font scale & offset
        await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_lyrics_font_up')));
        await tester.pumpAndSettle();
        expect(find.text('110%'), findsOneWidget);

        await tester.tap(find.byKey(const Key('btn_lyrics_offset_plus')));
        await tester.pumpAndSettle();
        expect(find.text('+0.5s'), findsOneWidget);

        // Switch to lyrics mode, then cover mode
        await tester.tap(find.byKey(const Key('btn_now_playing_mode_lyrics')));
        await tester.pumpAndSettle();
        expect(viewController.mode, NowPlayingViewMode.lyrics);

        await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
        await tester.pumpAndSettle();
        expect(viewController.mode, NowPlayingViewMode.cover);

        // Collapse overlay -> verify hidden from hit/finder tree
        await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
        expect(find.byKey(const Key('workspace_stage')), findsOneWidget);

        // Re-expand -> still in cover mode!
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
        expect(viewController.mode, NowPlayingViewMode.cover);

        // Switch to lyrics mode -> toolbar state, 110%, +0.5s, and scroll offset preserved
        await tester.tap(find.byKey(const Key('btn_now_playing_mode_lyrics')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btn_lyrics_font_up')), findsOneWidget);
        expect(find.text('110%'), findsOneWidget);
        expect(find.text('+0.5s'), findsOneWidget);

        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('lyrics_list_view')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(scrollable.position.pixels, closeTo(savedScrollBefore, 2.0));
      },
    );
  });

  group('Dynamic Cover Palette & Smooth Ambient Shader Transition', () {
    testWidgets(
      'no-cover fallback, crimson -> teal PNG transition with 300ms midpoint, and updates in lyricsFull mode',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        final tempDir = Directory.systemTemp.createTempSync(
          'lumina_np_palette_test_',
        );
        addTearDown(() {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          if (tempDir.existsSync()) {
            try {
              tempDir.deleteSync(recursive: true);
            } catch (_) {
              // Ignore transient Windows file-lock after Image.file decode.
            }
          }
        });

        final crimsonPath = _writeSolidPng(
          tempDir,
          'crimson',
          r: 220,
          g: 20,
          b: 40,
        );
        final tealPath = _writeSolidPng(
          tempDir,
          'teal',
          r: 20,
          g: 185,
          b: 165,
        );

        final service = _LongLyricsMockAudioService();
        final noCoverTrack = _makeTrack(
          id: 'trk-nocover',
          title: 'Silent Horizons',
          album: 'No Cover Album',
        );
        final crimsonTrack = _makeTrack(
          id: 'trk-crimson',
          title: 'Crimson Tide',
          album: 'Crimson Album',
          coverUrl: crimsonPath,
        );
        final tealTrack = _makeTrack(
          id: 'trk-teal',
          title: 'Teal Horizon',
          album: 'Teal Album',
          coverUrl: tealPath,
        );

        final paletteService = ArtworkPaletteService();
        final viewController = NowPlayingViewController();
        addTearDown(() {
          service.dispose();
          viewController.dispose();
        });

        Future<void> waitForFilePaletteCached(String filePath) async {
          final key = paletteService.cacheKeyFor(resolvedCachePath: filePath);
          for (var i = 0; i < 80; i++) {
            await tester.pump();
            if (paletteService.getCachedSync(key) != null) {
              await tester.pump();
              return;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
        }

        await service.play(track: noCoverTrack);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: service,
                controller: viewController,
                paletteService: paletteService,
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final expectedFallback = AmbientPalette.fallbackFor(noCoverTrack);
        expect(_bgPainter(tester).colorA, expectedFallback.colorA);

        // Switch to crimson cover track and let extraction + 650ms transition finish
        await service.play(track: crimsonTrack);
        await waitForFilePaletteCached(crimsonPath);
        await tester.pumpAndSettle();

        final crimsonPainter = _bgPainter(tester);
        final crimsonHue = HSLColor.fromColor(crimsonPainter.colorA).hue;
        expect(_hueDistance(crimsonHue, 355.0), lessThan(22.0));

        // Switch to teal cover track -> extract PNG -> verify smooth midpoint at ~300ms
        await service.play(track: tealTrack);
        await waitForFilePaletteCached(tealPath);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final midColorA = _bgPainter(tester).colorA;
        expect(midColorA, isNot(equals(crimsonPainter.colorA)));

        await tester.pumpAndSettle();
        final tealPainter = _bgPainter(tester);
        final tealHue = HSLColor.fromColor(tealPainter.colorA).hue;
        expect(_hueDistance(tealHue, 173.0), lessThan(22.0));
        expect(midColorA, isNot(equals(tealPainter.colorA)));

        // Switch to pure lyricsFull mode (AlbumArtworkView is NOT mounted) and swap back to crimson
        viewController.setMode(NowPlayingViewMode.lyrics);
        await tester.pumpAndSettle();
        expect(find.byType(AlbumArtworkView), findsNothing);

        // Clear cache so lyricsFull mode genuinely runs fresh extraction without AlbumArtworkView
        paletteService.clearCache();
        await service.play(track: crimsonTrack);
        await waitForFilePaletteCached(crimsonPath);
        await tester.pumpAndSettle();
        final lyricsModeHue = HSLColor.fromColor(_bgPainter(tester).colorA).hue;
        expect(_hueDistance(lyricsModeHue, 355.0), lessThan(22.0));
      },
    );

    testWidgets(
      'rapid switching A -> 120ms -> B -> 120ms -> C settles cleanly on C without stale overwrite',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        final service = _LongLyricsMockAudioService();
        final trackA = _makeTrack(
          id: 'trk-a',
          title: 'Track A',
          album: 'Album A',
          coverUrl: 'https://mem.local/a',
        );
        final trackB = _makeTrack(
          id: 'trk-b',
          title: 'Track B',
          album: 'Album B',
          coverUrl: 'https://mem.local/b',
        );
        final trackC = _makeTrack(
          id: 'trk-c',
          title: 'Track C',
          album: 'Album C',
          coverUrl: 'https://mem.local/c',
        );

        const paletteA = AmbientPalette(
          colorA: Color(0xFF3E121A),
          colorB: Color(0xFF381628),
          colorC: Color(0xFF281018),
          colorD: Color(0xFF140A0D),
        );
        const paletteB = AmbientPalette(
          colorA: Color(0xFF3B2B10),
          colorB: Color(0xFF332112),
          colorC: Color(0xFF241B0E),
          colorD: Color(0xFF120D08),
        );
        const paletteC = AmbientPalette(
          colorA: Color(0xFF103835),
          colorB: Color(0xFF132E3C),
          colorC: Color(0xFF0E2528),
          colorD: Color(0xFF081414),
        );

        final bCompleter = Completer<AmbientPalette?>();
        final paletteService = ArtworkPaletteService(
          urlExtractorOverride: (url) async {
            if (url == 'https://mem.local/a') return paletteA;
            if (url == 'https://mem.local/b') return bCompleter.future;
            if (url == 'https://mem.local/c') return paletteC;
            return null;
          },
        );
        final viewController = NowPlayingViewController();
        addTearDown(() {
          if (!bCompleter.isCompleted) {
            bCompleter.complete(paletteB);
          }
          service.dispose();
          viewController.dispose();
        });

        await service.play(track: trackA);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: service,
                controller: viewController,
                paletteService: paletteService,
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(_bgPainter(tester).colorA, paletteA.colorA);

        // Rapid skip to B (slow extraction), wait 120ms, then skip to C (fast extraction)
        await service.play(track: trackB);
        await tester.pump(const Duration(milliseconds: 120));

        await service.play(track: trackC);
        await tester.pump(const Duration(milliseconds: 120));

        // Now complete B's stale async extraction AFTER C has already started
        bCompleter.complete(paletteB);
        await tester.pumpAndSettle();

        final finalPainter = _bgPainter(tester);
        expect(finalPainter.colorA, paletteC.colorA);
        expect(finalPainter.colorB, paletteC.colorB);
        expect(finalPainter.colorC, paletteC.colorC);
        expect(finalPainter.colorD, paletteC.colorD);
      },
    );

    testWidgets(
      'isVisible: false prevents ambient animation ticks and snaps palette cleanly',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        final service = _LongLyricsMockAudioService();
        final trackA = _makeTrack(
          id: 'trk-vis-a',
          title: 'Visible A',
          coverUrl: 'https://mem.local/vis-a',
        );
        final trackB = _makeTrack(
          id: 'trk-vis-b',
          title: 'Visible B',
          coverUrl: 'https://mem.local/vis-b',
        );
        const paletteA = AmbientPalette(
          colorA: Color(0xFF3E121A),
          colorB: Color(0xFF381628),
          colorC: Color(0xFF281018),
          colorD: Color(0xFF140A0D),
        );
        const paletteB = AmbientPalette(
          colorA: Color(0xFF103835),
          colorB: Color(0xFF132E3C),
          colorC: Color(0xFF0E2528),
          colorD: Color(0xFF081414),
        );

        final paletteService = ArtworkPaletteService(
          urlExtractorOverride: (url) async {
            if (url == 'https://mem.local/vis-a') return paletteA;
            if (url == 'https://mem.local/vis-b') return paletteB;
            return null;
          },
        );
        addTearDown(service.dispose);

        await service.play(track: trackA);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: service,
                paletteService: paletteService,
                isVisible: false,
                enableAmbientMotion: true,
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(_bgPainter(tester).time, 0.0);
        expect(_bgPainter(tester).colorA, paletteA.colorA);

        // Switching track while hidden snaps cleanly without animating
        await service.play(track: trackB);
        await tester.pump();
        await tester.pump();
        expect(_bgPainter(tester).colorA, paletteB.colorA);
        expect(_bgPainter(tester).time, 0.0);
      },
    );
  });

  group('Adaptive Layout Metrics & Live Window Resize', () {
    test('NowPlayingLayoutMetrics.compute handles all key breakpoints and tiny bounds safely', () {
      // 1920x1080
      final split1080 = NowPlayingLayoutMetrics.compute(
        width: 1920,
        height: 1024,
        mode: NowPlayingViewMode.split,
      );
      expect(split1080.arrangement, NowPlayingStageArrangement.splitTwoColumn);
      expect(split1080.leftFlex, 5);
      expect(split1080.rightFlex, 6);
      expect(split1080.coverSide, greaterThanOrEqualTo(400));

      final cover1080 = NowPlayingLayoutMetrics.compute(
        width: 1920,
        height: 1024,
        mode: NowPlayingViewMode.cover,
      );
      expect(cover1080.arrangement, NowPlayingStageArrangement.coverVertical);
      expect(cover1080.shadowBlur, 36.0);
      expect(cover1080.shadowSpread, 2.0);
      expect(cover1080.shadowOffsetY, 14.0);

      // 1280x800
      final split800 = NowPlayingLayoutMetrics.compute(
        width: 1280,
        height: 744,
        mode: NowPlayingViewMode.split,
      );
      expect(split800.arrangement, NowPlayingStageArrangement.splitTwoColumn);

      // 1280x800 @ 150% -> ~853x477 stage
      final cover150 = NowPlayingLayoutMetrics.compute(
        width: 853.3,
        height: 477.3,
        mode: NowPlayingViewMode.cover,
      );
      expect(cover150.arrangement, NowPlayingStageArrangement.coverVertical);
      expect(cover150.coverSide, greaterThanOrEqualTo(220.0));

      final split150 = NowPlayingLayoutMetrics.compute(
        width: 853.3,
        height: 477.3,
        mode: NowPlayingViewMode.split,
      );
      expect(split150.arrangement, NowPlayingStageArrangement.splitTwoColumn);
      expect(split150.leftFlex, 5);
      expect(split150.rightFlex, 5);

      // 800x600 @ 150% -> ~533x344 stage
      final coverTight = NowPlayingLayoutMetrics.compute(
        width: 533.3,
        height: 344.0,
        mode: NowPlayingViewMode.cover,
      );
      expect(coverTight.arrangement, NowPlayingStageArrangement.coverVertical);
      expect(coverTight.compactMetadata, isTrue);

      final splitTight = NowPlayingLayoutMetrics.compute(
        width: 533.3,
        height: 344.0,
        mode: NowPlayingViewMode.split,
      );
      expect(splitTight.arrangement, NowPlayingStageArrangement.splitCompactHeader);

      // 700x700 -> wide split
      final split700 = NowPlayingLayoutMetrics.compute(
        width: 700,
        height: 700,
        mode: NowPlayingViewMode.split,
      );
      expect(split700.arrangement, NowPlayingStageArrangement.splitTwoColumn);

      // 600x720 & 420x680 -> splitNarrowStacked
      for (final sz in [const Size(600, 720), const Size(420, 680)]) {
        final m = NowPlayingLayoutMetrics.compute(
          width: sz.width,
          height: sz.height,
          mode: NowPlayingViewMode.split,
        );
        expect(m.arrangement, NowPlayingStageArrangement.splitNarrowStacked);
        expect(m.coverSide, greaterThanOrEqualTo(124.0));
      }

      // 900x280 -> coverLandscapeRow
      final coverLand = NowPlayingLayoutMetrics.compute(
        width: 900,
        height: 280,
        mode: NowPlayingViewMode.cover,
      );
      expect(coverLand.arrangement, NowPlayingStageArrangement.coverLandscapeRow);
      expect(coverLand.coverSide, greaterThanOrEqualTo(150.0));

      // Lyrics wide vs compact
      final lyricsFull = NowPlayingLayoutMetrics.compute(
        width: 1000,
        height: 600,
        mode: NowPlayingViewMode.lyrics,
      );
      expect(lyricsFull.arrangement, NowPlayingStageArrangement.lyricsFull);

      final lyricsCompact = NowPlayingLayoutMetrics.compute(
        width: 600,
        height: 600,
        mode: NowPlayingViewMode.lyrics,
      );
      expect(
        lyricsCompact.arrangement,
        NowPlayingStageArrangement.lyricsCompactHeader,
      );

      // Pathological tiny bounds must never throw
      for (final mode in NowPlayingViewMode.values) {
        final tiny = NowPlayingLayoutMetrics.compute(
          width: 60,
          height: 40,
          mode: mode,
        );
        expect(tiny.minCoverSide, lessThanOrEqualTo(tiny.coverSide));
        expect(tiny.coverSide, lessThanOrEqualTo(tiny.maxCoverSide));
        expect(tiny.maxMetaHeight, greaterThanOrEqualTo(0.0));
      }
    });

    testWidgets(
      'live window resize (1440x900 -> 620x720 -> 720x380 -> 1440x900) keeps 1:1 cover, zero overflows, and generous cover sizing',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(tester.view.reset);

        final service = _LongLyricsMockAudioService();
        final scaleCtrl = UiScaleController();
        addTearDown(() {
          service.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(audioService: service, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // 1. 1440x900 Split
        var coverSize = tester.getSize(
          find.descendant(
            of: find.byKey(const Key('now_playing_overlay')),
            matching: find.byType(AlbumArtworkView),
          ),
        );
        expect(coverSize.width, closeTo(coverSize.height, 0.5));
        expect(coverSize.width, greaterThanOrEqualTo(220.0));

        // 2. Resize to 620x720 -> splitNarrowStacked with >= 120px 1:1 square cover
        tester.view.physicalSize = const Size(620, 720);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        coverSize = tester.getSize(
          find.descendant(
            of: find.byKey(const Key('now_playing_overlay')),
            matching: find.byType(AlbumArtworkView),
          ),
        );
        expect(coverSize.width, closeTo(coverSize.height, 0.5));
        expect(coverSize.width, greaterThanOrEqualTo(120.0));

        // 3. Resize to 720x380 & switch to Cover -> coverLandscapeRow (>= 150px square, zero Scrollable, QualityBadge visible)
        tester.view.physicalSize = const Size(720, 380);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.descendant(
            of: find.byKey(const Key('now_playing_overlay')),
            matching: find.byType(Scrollable),
          ),
          findsNothing,
        );
        expect(find.byType(QualityBadge), findsOneWidget);
        coverSize = tester.getSize(
          find.descendant(
            of: find.byKey(const Key('now_playing_overlay')),
            matching: find.byType(AlbumArtworkView),
          ),
        );
        expect(coverSize.width, closeTo(coverSize.height, 0.5));
        expect(coverSize.width, greaterThanOrEqualTo(150.0));

        // 4. 1280x800 @ 150% scale in Cover mode -> >= 220px square cover
        tester.view.physicalSize = const Size(1280, 800);
        scaleCtrl.setScale(1.5);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        coverSize = tester.getSize(
          find.descendant(
            of: find.byKey(const Key('now_playing_overlay')),
            matching: find.byType(AlbumArtworkView),
          ),
        );
        expect(coverSize.width, closeTo(coverSize.height, 0.5));
        expect(coverSize.width, greaterThanOrEqualTo(220.0));

        // 5. Restore to 1440x900 @ 100%
        scaleCtrl.setScale(1.0);
        tester.view.physicalSize = const Size(1440, 900);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Fullscreen Now Playing & Lyrics UI/UX Enhancements', () {
    testWidgets(
      'FloatingCapsuleMiniPlayer hides track info and removes top border when isNowPlayingExpanded is true',
      (tester) async {
        final mockService = MockAudioService();

        // 1. Collapsed state: track title is visible, container has elevated background & top border
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FloatingCapsuleMiniPlayer(
                audioService: mockService,
                showLyrics: false,
                isNowPlayingExpanded: false,
                onToggleLyrics: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('capsule_track_title')), findsOneWidget);
        expect(find.text('Time'), findsOneWidget);
        var capsuleContainer = tester.widget<Container>(
          find.byKey(const Key('liquid_glass_capsule')),
        );
        var decor = capsuleContainer.decoration as BoxDecoration;
        expect(decor.color, isNot(equals(Colors.transparent)));
        expect(decor.border, isNotNull);

        // 2. Expanded state: track info hidden, transparent background, no top border
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FloatingCapsuleMiniPlayer(
                audioService: mockService,
                showLyrics: false,
                isNowPlayingExpanded: true,
                onToggleLyrics: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('capsule_track_title')), findsNothing);
        expect(find.text('Time'), findsNothing);
        capsuleContainer = tester.widget<Container>(
          find.byKey(const Key('liquid_glass_capsule')),
        );
        decor = capsuleContainer.decoration as BoxDecoration;
        expect(decor.color, equals(Colors.transparent));
        expect(decor.border, isNull);
      },
    );

    testWidgets(
      'LyricsView renders ShaderMask, collapses settings pill by default, toggles on click, and auto-collapses',
      (tester) async {
        final lyrics = [
          const LyricLine(
            start: Duration(seconds: 0),
            end: Duration(seconds: 4),
            text: 'First line of the song',
          ),
          const LyricLine(
            start: Duration(seconds: 4),
            end: Duration(seconds: 8),
            text: 'Second line of the song',
          ),
          const LyricLine(
            start: Duration(seconds: 8),
            end: Duration(seconds: 12),
            text: 'Third line of the song',
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: LyricsView(
                  lyrics: lyrics,
                  currentPosition: const Duration(seconds: 5),
                  centered: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Verifies ShaderMask with BlendMode.dstIn wraps the lyrics list
        expect(
          find.descendant(
            of: find.byKey(const Key('lyrics_list_view')),
            matching: find.byWidgetPredicate(
              (w) => w is ShaderMask && w.blendMode == BlendMode.dstIn,
            ),
          ),
          findsOneWidget,
        );

        // 2. Default state: collapsed pill toggle button
        expect(
          find.byKey(const Key('btn_lyrics_toolbar_toggle')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsNothing);

        // 3. Tapping the pill toggle expands the toolbar
        await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_toggle')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('btn_lyrics_font_down')), findsOneWidget);
        expect(find.byKey(const Key('btn_lyrics_toolbar_close')), findsOneWidget);

        // 4. Tapping the close button collapses it back
        await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_close')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('btn_lyrics_toolbar_toggle')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsNothing);

        // 5. Expand again and verify auto-collapse after 4.5 seconds
        await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsOneWidget);

        // Advance timer past 4.5s
        await tester.pump(const Duration(milliseconds: 4600));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('btn_lyrics_toolbar_toggle')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsNothing);
      },
    );

    testWidgets(
      'NowPlayingOverlay mounts DynamicWaveformBar, desktop window captions, and toggles mode on cover tap',
      (tester) async {
        final mockService = MockAudioService();
        final controller = NowPlayingViewController();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: mockService,
                controller: controller,
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. SpectrumVisualizerWidget is removed from NowPlayingOverlay
        expect(find.byType(SpectrumVisualizerWidget), findsNothing);

        // 2. Desktop window caption buttons are mounted
        expect(find.byKey(const Key('btn_window_minimize')), findsOneWidget);
        expect(find.byKey(const Key('btn_window_maximize')), findsOneWidget);
        expect(find.byKey(const Key('btn_window_close')), findsOneWidget);

        // 3. Switch to Cover mode -> tap cover toggles to Split mode
        controller.setMode(NowPlayingViewMode.cover);
        await tester.pumpAndSettle();
        expect(controller.mode, NowPlayingViewMode.cover);
        await tester.tap(find.byType(AlbumArtworkView));
        await tester.pumpAndSettle();
        expect(controller.mode, NowPlayingViewMode.split);

        // 4. Tap cover in Split mode toggles back to Cover mode
        await tester.tap(find.byType(AlbumArtworkView));
        await tester.pumpAndSettle();
        expect(controller.mode, NowPlayingViewMode.cover);
      },
    );
  });
}
