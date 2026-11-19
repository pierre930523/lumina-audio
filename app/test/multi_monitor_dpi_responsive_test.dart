import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/media_sources_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/playback_controls.dart';
import 'package:lumina_app/ui/signal_path/quality_badge.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _ResponsiveTestAudioService extends MockAudioService {
  final String coverFilePath;
  late final List<CanonicalAlbumSummary> _albums;

  _ResponsiveTestAudioService(this.coverFilePath) {
    _albums = [
      for (var i = 1; i <= 8; i++)
        CanonicalAlbumSummary(
          id: 'alb-0$i',
          title: 'Reference Album $i',
          artist: i <= 3 ? 'Pink Floyd' : 'Studio Ensemble $i',
          year: 1970 + i,
        ),
    ];
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) async {
    return _albums.take(limit).toList();
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    return {
      'found': true,
      'cache_path': coverFilePath,
      'mime_type': 'image/png',
      'source_kind': 'embedded',
      'width': 1200,
      'height': 1200,
    };
  }
}

Future<void> _setMonitorMetrics(
  WidgetTester tester, {
  required Size physicalSize,
  required double dpr,
}) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = physicalSize;
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason:
        'Unexpected exception at ${physicalSize.width.toInt()}x${physicalSize.height.toInt()} @ ${dpr}x',
  );
}

Size _logicalSize(Size physicalSize, double dpr) =>
    Size(physicalSize.width / dpr, physicalSize.height / dpr);

void _assertRectInsideViewport(
  WidgetTester tester,
  Finder finder,
  Size logicalViewport,
  String label,
) {
  expect(finder, findsOneWidget, reason: '[$label] Widget must exist');
  final rect = tester.getRect(finder);
  expect(
    rect.left,
    greaterThanOrEqualTo(-0.5),
    reason: '[$label] Left clipped: $rect in $logicalViewport',
  );
  expect(
    rect.top,
    greaterThanOrEqualTo(-0.5),
    reason: '[$label] Top clipped: $rect in $logicalViewport',
  );
  expect(
    rect.right,
    lessThanOrEqualTo(logicalViewport.width + 0.5),
    reason: '[$label] Right clipped: $rect in $logicalViewport',
  );
  expect(
    rect.bottom,
    lessThanOrEqualTo(logicalViewport.height + 0.5),
    reason: '[$label] Bottom clipped: $rect in $logicalViewport',
  );
}

void _assertNoOverlapWithCapsule(
  WidgetTester tester,
  Finder stageFinder,
  String label,
) {
  final capsuleFinder = find.byKey(const Key('liquid_glass_capsule'));
  expect(capsuleFinder, findsOneWidget, reason: '[$label] Capsule missing');
  expect(stageFinder, findsOneWidget, reason: '[$label] Stage missing');
  final capsuleRect = tester.getRect(capsuleFinder);
  final stageRect = tester.getRect(stageFinder);
  expect(
    stageRect.bottom,
    lessThanOrEqualTo(capsuleRect.top + 0.5),
    reason:
        '[$label] Stage bottom (${stageRect.bottom}) overlapped capsule top (${capsuleRect.top})',
  );
}

void _assertNoShrinkWrapScrollViews(WidgetTester tester, String label) {
  for (final sv in tester.widgetList<ScrollView>(find.byType(ScrollView))) {
    expect(
      sv.shrinkWrap,
      isFalse,
      reason: '[$label] ScrollView ${sv.key} must not use shrinkWrap: true',
    );
  }
}

int? _decodedCacheWidth(Image img) {
  final provider = img.image;
  return provider is ResizeImage ? provider.width : null;
}

List<({AlbumArtworkView view, Image image})> _findDecodedThumbnails(
  WidgetTester tester,
) {
  final results = <({AlbumArtworkView view, Image image})>[];
  final artworkFinder = find.byWidgetPredicate(
    (w) => w is AlbumArtworkView && !w.fullResolution,
  );
  for (final element in artworkFinder.evaluate()) {
    final view = element.widget as AlbumArtworkView;
    final imgFinder = find.descendant(
      of: find.byWidget(view),
      matching: find.byType(Image),
    );
    if (imgFinder.evaluate().isNotEmpty) {
      results.add((view: view, image: tester.widget<Image>(imgFinder.first)));
    }
  }
  return results;
}

Future<void> _navigateToZones(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
  await tester.pumpAndSettle();
  final zonesRailFinder = find.byKey(const Key('nav_tab_zones'));
  if (zonesRailFinder.evaluate().isNotEmpty) {
    await tester.ensureVisible(zonesRailFinder);
    await tester.tap(zonesRailFinder);
    await tester.pumpAndSettle();
  } else {
    // Narrow compact settings menu dropdown
    final selectorFinder = find.byWidgetPredicate(
      (w) => w is DropdownButtonFormField || w is DropdownButton,
    );
    if (selectorFinder.evaluate().isNotEmpty) {
      await tester.tap(selectorFinder.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('輸出與音區').last);
      await tester.pumpAndSettle();
    } else {
      await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_popover_open_zones')));
      await tester.pumpAndSettle();
    }
  }
}

void main() {
  late Directory tempDir;
  late String coverFilePath;

  setUp(() {
    MediaSourcesController.instance.resetForTest();
    tempDir = Directory.systemTemp.createTempSync('lumina_multi_dpi_');
    final coverFile = File('${tempDir.path}\\cover.png');
    coverFile.writeAsBytesSync(_valid1x1Png);
    coverFilePath = coverFile.path;
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets(
    'Scenario 1: 1920x1080 @ 100% (dpr=1.0) renders all primary views & centered controls cleanly',
    (tester) async {
      addTearDown(tester.view.reset);
      final svc = _ResponsiveTestAudioService(coverFilePath);
      final scaleCtrl = UiScaleController();
      addTearDown(() {
        svc.dispose();
        scaleCtrl.dispose();
      });

      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(1920, 1080),
        dpr: 1.0,
      );
      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('我的音樂資料庫'), findsOneWidget);
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('workspace_stage')),
        '1080p Home',
      );
      _assertNoShrinkWrapScrollViews(tester, '1080p Home');

      // Dead-center Play/Pause
      final capsuleRect = tester.getRect(
        find.byKey(const Key('liquid_glass_capsule')),
      );
      final playCenter = tester.getCenter(find.byKey(const Key('btn_play_pause')));
      expect((playCenter.dx - capsuleRect.center.dx).abs(), lessThan(1.0));
      expect(find.byType(QualityBadge), findsOneWidget);

      // Albums
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('workspace_stage')),
        '1080p Albums',
      );

      // Library
      await tester.tap(find.byKey(const Key('nav_tab_library')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Output & Zones
      await _navigateToZones(tester);
      expect(find.byKey(const Key('output_zone_panel')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Now Playing Split / Lyrics / Cover
      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('now_playing_overlay')),
        '1080p NowPlaying Split',
      );
      await tester.tap(find.byKey(const Key('btn_now_playing_mode_lyrics')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Scenario 2: 2560x1440 @ 125% (dpr=1.25) scales MediaQuery & artwork cacheWidth cleanly',
    (tester) async {
      addTearDown(tester.view.reset);
      final svc = _ResponsiveTestAudioService(coverFilePath);
      final scaleCtrl = UiScaleController();
      addTearDown(() {
        svc.dispose();
        scaleCtrl.dispose();
      });

      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(2560, 1440),
        dpr: 1.25,
      );
      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.getSize(find.byType(HomeScreen)), const Size(2048, 1152));
      expect(find.text('我的音樂資料庫'), findsOneWidget);
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('workspace_stage')),
        '1440p@125 Home',
      );

      final thumbs = _findDecodedThumbnails(tester);
      expect(thumbs, isNotEmpty);
      for (final item in thumbs) {
        final expected = (item.view.size * 1.25).ceil().clamp(128, 2048);
        expect(_decodedCacheWidth(item.image), expected);
      }

      // Now Playing & Zones
      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('now_playing_overlay')),
        '1440p@125 NowPlaying',
      );
      await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
      await tester.pumpAndSettle();

      await _navigateToZones(tester);
      expect(find.byKey(const Key('output_zone_panel')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Scenario 3: 3840x2160 @ 150% & 200% plus UiScaleController 1.25x prevents double-scaling',
    (tester) async {
      addTearDown(tester.view.reset);
      final svc = _ResponsiveTestAudioService(coverFilePath);
      final scaleCtrl = UiScaleController();
      addTearDown(() {
        svc.dispose();
        scaleCtrl.dispose();
      });

      // 4K @ 150%
      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(3840, 2160),
        dpr: 1.5,
      );
      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(HomeScreen)), const Size(2560, 1440));
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('workspace_stage')),
        '4K@150 Home',
      );

      // 4K @ 200%
      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(3840, 2160),
        dpr: 2.0,
      );
      expect(tester.getSize(find.byType(HomeScreen)), const Size(1920, 1080));

      // Combined UiScaleController 1.25x on 4K @ 200% -> HomeScreen logical 1536x864,
      // effective DPR 2.0 * 1.25 = 2.5 (no double-scaling!).
      scaleCtrl.setScale(1.25);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(HomeScreen)), const Size(1536, 864));

      final thumbs = _findDecodedThumbnails(tester);
      expect(thumbs, isNotEmpty);
      for (final item in thumbs) {
        final expectedNoDouble = (item.view.size * 2.5).ceil().clamp(128, 2048);
        final wrongDoubleScaled =
            (item.view.size * 2.5 * 1.25).ceil().clamp(128, 2048);
        expect(_decodedCacheWidth(item.image), expectedNoDouble);
        if (expectedNoDouble != 2048) {
          expect(_decodedCacheWidth(item.image), isNot(wrongDoubleScaled));
        }
      }

      // Open popovers & Now Playing at combined scale
      await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quick_output_popover')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      _assertNoOverlapWithCapsule(
        tester,
        find.byKey(const Key('now_playing_overlay')),
        '4K@200+1.25x NowPlaying',
      );
    },
  );

  testWidgets(
    'Scenario 4: High-Res -> Low-Res monitor drag keeps popovers inside viewport and carousel non-empty',
    (tester) async {
      addTearDown(tester.view.reset);
      final svc = _ResponsiveTestAudioService(coverFilePath);
      final scaleCtrl = UiScaleController();
      addTearDown(() {
        svc.dispose();
        scaleCtrl.dispose();
      });

      const sequence = [
        (size: Size(3840, 2160), dpr: 2.0),
        (size: Size(2560, 1440), dpr: 1.25),
        (size: Size(1920, 1080), dpr: 1.0),
        (size: Size(1280, 720), dpr: 1.5),
        (size: Size(1280, 720), dpr: 2.0),
      ];

      await _setMonitorMetrics(
        tester,
        physicalSize: sequence.first.size,
        dpr: sequence.first.dpr,
      );
      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();

      // Test Home carousel pagination across high -> low -> high transitions
      // Start at narrow 1280x720@2.0 (logical 640x360, maxCols=3), advance carousel twice,
      // then move to 4K@2.0 (1920x1080, maxCols=6) and down through all 5 monitors.
      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(1280, 720),
        dpr: 2.0,
      );
      final nextBtn = find.byTooltip('下一頁活動');
      expect(nextBtn, findsOneWidget);
      await tester.ensureVisible(nextBtn);
      await tester.pumpAndSettle();
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();

      for (final step in sequence) {
        await _setMonitorMetrics(tester, physicalSize: step.size, dpr: step.dpr);
        final cardFinder = find.descendant(
          of: find.byKey(const Key('home_recent_activity_card')),
          matching: find.byWidgetPredicate(
            (w) => w.key?.toString().contains('home_recent_album_') ?? false,
          ),
        );
        expect(
          cardFinder,
          findsWidgets,
          reason:
              'Carousel became empty after monitor drag to ${step.size}@${step.dpr}',
        );
      }

      // Reset to 4K @ 2.0 and drag with Quick Output Popover open
      await _setMonitorMetrics(
        tester,
        physicalSize: sequence.first.size,
        dpr: sequence.first.dpr,
      );
      await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
      await tester.pumpAndSettle();
      for (final step in sequence) {
        await _setMonitorMetrics(tester, physicalSize: step.size, dpr: step.dpr);
        _assertRectInsideViewport(
          tester,
          find.byKey(const Key('quick_output_popover')),
          _logicalSize(step.size, step.dpr),
          'QuickOutput@${step.size.width.toInt()}x${step.size.height.toInt()}@${step.dpr}',
        );
      }
      await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
      await tester.pumpAndSettle();

      // Drag with Quick Queue Popover open
      await _setMonitorMetrics(
        tester,
        physicalSize: sequence.first.size,
        dpr: sequence.first.dpr,
      );
      await tester.tap(find.byKey(const Key('btn_quick_queue_popover')));
      await tester.pumpAndSettle();
      for (final step in sequence) {
        await _setMonitorMetrics(tester, physicalSize: step.size, dpr: step.dpr);
        _assertRectInsideViewport(
          tester,
          find.byKey(const Key('quick_queue_popover')),
          _logicalSize(step.size, step.dpr),
          'QuickQueue@${step.size.width.toInt()}x${step.size.height.toInt()}@${step.dpr}',
        );
        _assertNoShrinkWrapScrollViews(
          tester,
          'QuickQueue@${step.size}@${step.dpr}',
        );
      }
      await tester.tap(find.byKey(const Key('btn_quick_queue_popover')));
      await tester.pumpAndSettle();

      // Drag on Albums with album_layout_popover open
      await _setMonitorMetrics(
        tester,
        physicalSize: sequence.first.size,
        dpr: sequence.first.dpr,
      );
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
      await tester.pumpAndSettle();
      for (final step in sequence) {
        await _setMonitorMetrics(tester, physicalSize: step.size, dpr: step.dpr);
        // Crossing the 840px desktop/compact threshold rebuilds the workspace
        // subtree; reopen the layout popover if it closed on mode swap so we
        // also verify viewport clamping at compact 1280x720@2.0 (640x360).
        if (find.byKey(const Key('album_layout_popover')).evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
          await tester.pumpAndSettle();
        }
        _assertRectInsideViewport(
          tester,
          find.byKey(const Key('album_layout_popover')),
          _logicalSize(step.size, step.dpr),
          'AlbumLayoutPopover@${step.size.width.toInt()}x${step.size.height.toInt()}@${step.dpr}',
        );
      }
      await tester.tap(find.byKey(const Key('btn_album_layout_close')));
      await tester.pumpAndSettle();

      // Drag with Now Playing open across all 5 monitor states
      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      for (final step in sequence) {
        await _setMonitorMetrics(tester, physicalSize: step.size, dpr: step.dpr);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('now_playing_overlay')),
          'NowPlaying@${step.size}@${step.dpr}',
        );
      }
    },
  );

  testWidgets(
    'Scenario 5: Low-Res -> High-Res monitor drag transitions sidebar, expands album grid columns, and increases artwork cacheWidth with DPR',
    (tester) async {
      addTearDown(tester.view.reset);
      final svc = _ResponsiveTestAudioService(coverFilePath);
      final scaleCtrl = UiScaleController();
      addTearDown(() {
        svc.dispose();
        scaleCtrl.dispose();
      });

      // Start on compact low-res (1280x720 @ 2.0 => 640x360) -> compact nav strip
      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(1280, 720),
        dpr: 2.0,
      );
      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is ChoiceChip && w.key == const Key('nav_tab_home'),
        ),
        findsOneWidget,
      );
      expect(find.text('我的音樂資料庫'), findsNothing);

      // Navigate to Albums
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();

      // Sequence: 1280x720@1.0 -> 1920x1080@1.0 -> 2560x1440@1.25 -> 3840x2160@2.0
      int countFirstRowColumns() {
        final cards = find.byWidgetPredicate(
          (w) => w.key?.toString().contains('album_card_') ?? false,
        );
        final rects = cards
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .toList();
        if (rects.isEmpty) return 0;
        final firstTop = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
        return rects.where((r) => (r.top - firstTop).abs() < 4.0).length;
      }

      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(1280, 720),
        dpr: 1.0,
      );
      expect(find.text('我的音樂資料庫'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is ChoiceChip && w.key == const Key('nav_tab_home'),
        ),
        findsNothing,
      );
      final cols1280 = countFirstRowColumns();
      final thumbs1x = _findDecodedThumbnails(tester);
      expect(thumbs1x, isNotEmpty);
      final cacheWidth1280At1x = _decodedCacheWidth(thumbs1x.first.image)!;

      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(1920, 1080),
        dpr: 1.0,
      );
      final cols1920 = countFirstRowColumns();
      expect(cols1920, greaterThanOrEqualTo(cols1280));

      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(2560, 1440),
        dpr: 1.25,
      );
      final cols2048 = countFirstRowColumns();
      expect(cols2048, greaterThan(cols1280));
      final thumbs125x = _findDecodedThumbnails(tester);
      expect(thumbs125x, isNotEmpty);
      expect(
        _decodedCacheWidth(thumbs125x.first.image)!,
        greaterThan(cacheWidth1280At1x),
      );

      await _setMonitorMetrics(
        tester,
        physicalSize: const Size(3840, 2160),
        dpr: 2.0,
      );
      final thumbs2x = _findDecodedThumbnails(tester);
      expect(thumbs2x, isNotEmpty);
      final expected2x =
          (thumbs2x.first.view.size * 2.0).ceil().clamp(128, 2048);
      expect(_decodedCacheWidth(thumbs2x.first.image), expected2x);
      expect(
        _decodedCacheWidth(thumbs2x.first.image)!,
        greaterThan(_decodedCacheWidth(thumbs125x.first.image)!),
      );
    },
  );

  testWidgets(
    'Scenario 6: Maximize / Restore / Manual resize sequence across Home, Albums, Now Playing (Split/Lyrics/Cover), Library, and Output & Zones',
    (tester) async {
      addTearDown(tester.view.reset);
      final svc = _ResponsiveTestAudioService(coverFilePath);
      final scaleCtrl = UiScaleController();
      addTearDown(() {
        svc.dispose();
        scaleCtrl.dispose();
      });

      const resizeSteps = [
        Size(1280, 720),
        Size(1920, 1080),
        Size(1280, 720),
        Size(620, 520),
        Size(980, 420),
        Size(480, 420),
        Size(1440, 900),
      ];

      await _setMonitorMetrics(
        tester,
        physicalSize: resizeSteps.first,
        dpr: 1.0,
      );
      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();

      for (final size in resizeSteps) {
        final label = '${size.width.toInt()}x${size.height.toInt()}';

        // 1. Home
        await _setMonitorMetrics(tester, physicalSize: size, dpr: 1.0);
        await tester.ensureVisible(find.byKey(const Key('nav_tab_home')));
        await tester.tap(find.byKey(const Key('nav_tab_home')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('workspace_stage')),
          '$label Home',
        );
        _assertNoShrinkWrapScrollViews(tester, '$label Home');

        // 2. Albums
        await tester.ensureVisible(find.byKey(const Key('nav_tab_albums')));
        await tester.tap(find.byKey(const Key('nav_tab_albums')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('workspace_stage')),
          '$label Albums',
        );
        _assertNoShrinkWrapScrollViews(tester, '$label Albums');

        // 3. Library
        await tester.ensureVisible(find.byKey(const Key('nav_tab_library')));
        await tester.tap(find.byKey(const Key('nav_tab_library')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('workspace_stage')),
          '$label Library',
        );
        _assertNoShrinkWrapScrollViews(tester, '$label Library');

        // 4. Output & Zones
        await _navigateToZones(tester);
        expect(find.byKey(const Key('output_zone_panel')), findsOneWidget);
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('workspace_stage')),
          '$label Zones',
        );

        // 5. Now Playing (Split -> Lyrics -> Cover -> Collapse)
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('now_playing_overlay')),
          '$label NowPlaying Split',
        );
        expect(find.byType(PlaybackControls), findsOneWidget);

        await tester.tap(find.byKey(const Key('btn_now_playing_mode_lyrics')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('now_playing_overlay')),
          '$label NowPlaying Lyrics',
        );

        await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _assertNoOverlapWithCapsule(
          tester,
          find.byKey(const Key('now_playing_overlay')),
          '$label NowPlaying Cover',
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('now_playing_overlay')),
            matching: find.byType(Scrollable),
          ),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('btn_now_playing_mode_split')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
        await tester.pumpAndSettle();
      }
    },
  );
}
