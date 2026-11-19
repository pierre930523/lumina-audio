import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/album_layout_settings_controller.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/albums/album_collection_card.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _RedesignTestAudioService extends MockAudioService {
  final List<CanonicalAlbumSummary> albumsList;
  final Map<String, CanonicalAlbumDetail> detailsById;
  final Map<String, String> coverFilesById;
  bool unmodifiableQueue = false;

  _RedesignTestAudioService({
    required this.albumsList,
    this.detailsById = const {},
    this.coverFilesById = const {},
  });

  @override
  List<TrackInfo> get queue =>
      unmodifiableQueue ? List<TrackInfo>.unmodifiable(super.queue) : super.queue;

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) async {
    return albumsList;
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    return detailsById[albumId] ?? await super.getAlbumDetail(albumId);
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    final file = coverFilesById[trackId];
    if (file != null) {
      return {
        'found': true,
        'cache_path': file,
        'mime_type': 'image/png',
        'source_kind': 'embedded',
        'width': 1200,
        'height': 1200,
      };
    }
    return super.getArtwork(trackId, path: path, maxDim: maxDim);
  }
}

List<CanonicalAlbumSummary> _sampleAlbums({int count = 4}) {
  return List<CanonicalAlbumSummary>.generate(
    count,
    (i) => CanonicalAlbumSummary(
      id: 'alb-${i + 1}',
      title: 'Symphony Album ${i + 1}',
      artist: 'Artist ${i + 1}',
      year: 2020 + i,
    ),
  );
}

CanonicalAlbumDetail _sampleDetail(String albumId, int index) {
  return CanonicalAlbumDetail(
    id: albumId,
    title: 'Symphony Album $index',
    artistName: 'Artist $index',
    releaseYear: 2020 + index - 1,
    versions: [
      AlbumVersionInfo(
        id: 'ver-$albumId',
        provider: 'local',
        externalAlbumId: 'ext-$albumId',
        editionLabel: 'Studio Master',
        codec: 'flac',
        sampleRateHz: 96000,
        bitDepth: 24,
        tracks: [
          AlbumVersionTrackInfo(
            id: 'trk-$albumId-1',
            title: 'Movement I ($albumId)',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 210000,
            codec: 'flac',
            sampleRateHz: 96000,
            bitDepth: 24,
            externalTrackId: '/music/$albumId/01.flac',
          ),
          AlbumVersionTrackInfo(
            id: 'trk-$albumId-2',
            title: 'Movement II ($albumId)',
            discNumber: 1,
            trackNumber: 2,
            durationMs: 185000,
            codec: 'flac',
            sampleRateHz: 96000,
            bitDepth: 24,
            externalTrackId: '/music/$albumId/02.flac',
          ),
        ],
      ),
    ],
    credits: [
      AlbumCreditInfo(
        artistId: 'art-$index',
        artistName: 'Artist $index',
        role: '主創藝術家',
        albumId: albumId,
        albumTitle: 'Symphony Album $index',
      ),
    ],
  );
}

void main() {
  group('AlbumLayoutSettingsController persistence & math', () {
    test('saves and reloads all fields via prefsFileOverride and recovers from corrupt JSON', () async {
      final tmpDir = Directory.systemTemp.createTempSync('lumina_layout_prefs_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final prefsFile = File(
        '${tmpDir.path}${Platform.pathSeparator}album_layout_prefs.json',
      );

      final ctrl = AlbumLayoutSettingsController(prefsFileOverride: prefsFile);
      addTearDown(ctrl.dispose);
      expect(ctrl.coverTargetExtent, 192.0);
      expect(ctrl.activeCoverPreset, AlbumCoverSizePreset.standard);
      expect(ctrl.spacingPreset, AlbumGridSpacingPreset.medium);
      expect(ctrl.viewMode, AlbumViewMode.grid);
      expect(ctrl.showCardContainer, isFalse);

      ctrl.setCoverTargetExtent(250.0);
      ctrl.setSpacingPreset(AlbumGridSpacingPreset.wide);
      ctrl.setViewMode(AlbumViewMode.list);
      ctrl.setShowCardContainer(true);

      expect(prefsFile.existsSync(), isTrue);

      final reloaded = AlbumLayoutSettingsController(
        prefsFileOverride: prefsFile,
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();

      expect(reloaded.coverTargetExtent, 250.0);
      expect(reloaded.activeCoverPreset, AlbumCoverSizePreset.large);
      expect(reloaded.spacingPreset, AlbumGridSpacingPreset.wide);
      expect(reloaded.spacing, 28.0);
      expect(reloaded.viewMode, AlbumViewMode.list);
      expect(reloaded.showCardContainer, isTrue);

      // Reset persists defaults
      reloaded.resetToDefaults();
      final afterReset = AlbumLayoutSettingsController(
        prefsFileOverride: prefsFile,
      );
      addTearDown(afterReset.dispose);
      await afterReset.load();
      expect(afterReset.coverTargetExtent, 192.0);
      expect(afterReset.spacingPreset, AlbumGridSpacingPreset.medium);
      expect(afterReset.viewMode, AlbumViewMode.grid);
      expect(afterReset.showCardContainer, isFalse);

      // Corrupt JSON keeps defaults gracefully
      prefsFile.writeAsStringSync('{corrupt_json:::');
      final corruptCtrl = AlbumLayoutSettingsController(
        prefsFileOverride: prefsFile,
      );
      addTearDown(corruptCtrl.dispose);
      await corruptCtrl.load();
      expect(corruptCtrl.coverTargetExtent, 192.0);
      expect(corruptCtrl.spacingPreset, AlbumGridSpacingPreset.medium);
      expect(corruptCtrl.viewMode, AlbumViewMode.grid);
      expect(corruptCtrl.showCardContainer, isFalse);
    });
  });

  group('Frameless Card, Hover FX, GPU Throttling & Stop Propagation', () {
    testWidgets(
      'defaults to frameless minimalist style with transparent outer container and 1px subtle cover border',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 2),
        );
        addTearDown(svc.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              backgroundColor: LuminaTokens.canvasBg,
              body: AlbumsAndCreditsView(audioService: svc),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final surfaceFinder = find.byKey(const Key('album_surface_alb-1'));
        expect(surfaceFinder, findsOneWidget);
        final surface = tester.widget<Container>(surfaceFinder);
        expect(surface.color, Colors.transparent);
        expect(surface.padding, EdgeInsets.zero);
        expect(surface.decoration, isNull);

        // Grid view maintains >= 24px horizontal & top padding so hover ambient glows stay unclipped
        final grid = tester.widget<GridView>(
          find.byKey(const Key('album_grid_view')),
        );
        final pad = grid.padding! as EdgeInsets;
        expect(pad.left, greaterThanOrEqualTo(24.0));
        expect(pad.right, greaterThanOrEqualTo(24.0));
        expect(pad.top, greaterThanOrEqualTo(24.0));

        // Cover artwork has 1px white @ 8% border even when unhovered
        final artworkContainer = tester
            .widgetList<Container>(
              find.descendant(
                of: find.byKey(const Key('album_card_alb-1')),
                matching: find.byType(Container),
              ),
            )
            .where(
              (w) => w.key.toString().contains('artwork_container_'),
            )
            .first;
        final boxDec = artworkContainer.decoration! as BoxDecoration;
        final border = boxDec.border! as Border;
        expect(border.top.width, 1.0);
        expect(border.top.color, Colors.white.withValues(alpha: 0.08));
      },
    );

    testWidgets(
      'Apple Music Hover FX mounts 32x32 ImageFiltered glow + frosted BackdropFilter buttons on hover, highlights Play on hover, and unmounts to 0 on exit',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tmpDir = Directory.systemTemp.createTempSync('lumina_fx_art_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File(
          '${tmpDir.path}${Platform.pathSeparator}cover_fx.png',
        )..writeAsBytesSync(_valid1x1Png);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 1),
          coverFilesById: {'alb-1': imgFile.path},
        );
        addTearDown(svc.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              backgroundColor: LuminaTokens.canvasBg,
              body: AlbumsAndCreditsView(audioService: svc),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Idle assertions: zero BackdropFilter, zero ImageFiltered, exactly 1 Image
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.byType(Image), findsOneWidget);

        // Hover over cover center
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('album_card_alb-1'))),
        );
        await tester.pumpAndSettle();

        // Outer card remains transparent (never grey card box on hover)
        final hoveredSurface = tester.widget<Container>(
          find.byKey(const Key('album_surface_alb-1')),
        );
        expect(hoveredSurface.color, Colors.transparent);

        // ImageFiltered ambient glow mounts with 32x32 low-res Image copy
        final glowFilterFinder = find.byType(ImageFiltered);
        expect(glowFilterFinder, findsOneWidget);
        final glowImgFinder = find.descendant(
          of: glowFilterFinder,
          matching: find.byType(Image),
        );
        expect(glowImgFinder, findsOneWidget);
        final glowImg = tester.widget<Image>(glowImgFinder);
        expect(glowImg.filterQuality, FilterQuality.low);
        expect(glowImg.image, isA<ResizeImage>());
        final resized = glowImg.image as ResizeImage;
        expect(resized.width, 32);
        expect(resized.height, 32);

        // Frosted BackdropFilter Play & More buttons mount cleanly
        final playBtnFinder = find.byKey(const Key('album_card_play_alb-1'));
        final moreBtnFinder = find.byKey(const Key('album_card_more_alb-1'));
        expect(playBtnFinder, findsOneWidget);
        expect(moreBtnFinder, findsOneWidget);
        expect(
          find.descendant(
            of: playBtnFinder,
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: moreBtnFinder,
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );

        // Hover Play button specifically -> ScaleTransition scales to 1.08 and color -> accentBlue
        await mouse.moveTo(tester.getCenter(playBtnFinder));
        await tester.pumpAndSettle();

        final playScale = tester.widget<ScaleTransition>(
          find.descendant(
            of: playBtnFinder,
            matching: find.byType(ScaleTransition),
          ),
        );
        expect(playScale.scale.value, closeTo(1.08, 0.001));

        final playBgContainer = tester.widget<Container>(
          find.descendant(
            of: playBtnFinder,
            matching: find.byType(Container),
          ),
        );
        final playDec = playBgContainer.decoration! as BoxDecoration;
        expect(playDec.color, LuminaTokens.accentBlue);

        final playIcon = tester.widget<Icon>(
          find.descendant(of: playBtnFinder, matching: find.byType(Icon)),
        );
        expect(playIcon.color, LuminaTokens.onAccentDark);

        // Move mouse away and settle -> BackdropFilter & ImageFiltered unmount back to 0
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();

        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.byType(Image), findsOneWidget);
      },
    );

    testWidgets(
      'stop-propagation: Play and More buttons do not navigate to AlbumDetailPage, while cover/text opens detail',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 1),
          detailsById: {'alb-1': _sampleDetail('alb-1', 1)},
        )..unmodifiableQueue = true;
        addTearDown(svc.dispose);

        final openedDetails = <String>[];
        final openedArtists = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              backgroundColor: LuminaTokens.canvasBg,
              body: AlbumsAndCreditsView(
                audioService: svc,
                onOpenAlbumDetail: openedDetails.add,
                onOpenArtist: openedArtists.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('album_card_alb-1'))),
        );
        await tester.pumpAndSettle();

        // 1. Tap Play button -> plays album without opening detail
        await tester.tap(find.byKey(const Key('album_card_play_alb-1')));
        await tester.pumpAndSettle();
        expect(svc.currentState.status, PlaybackStatus.playing);
        expect(svc.currentState.track?.id, 'trk-alb-1-1');
        expect(openedDetails, isEmpty);

        // 2. Tap More button -> opens popup menu without opening detail
        await tester.tap(find.byKey(const Key('album_card_more_alb-1')));
        await tester.pumpAndSettle();
        expect(openedDetails, isEmpty);
        expect(find.text('播放專輯'), findsOneWidget);
        expect(find.text('加入播放佇列'), findsOneWidget);
        expect(find.text('檢視專輯詳情'), findsOneWidget);
        expect(find.text('前往藝術家'), findsOneWidget);

        // Tap '前往藝術家' inside popup menu
        await tester.tap(find.text('前往藝術家'));
        await tester.pumpAndSettle();
        expect(openedArtists, ['Artist 1']);
        expect(openedDetails, isEmpty);

        // Open More menu again and tap '加入播放佇列' -> shows confirmation without opening detail
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('album_card_alb-1'))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('album_card_more_alb-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('加入播放佇列'));
        await tester.pumpAndSettle();
        expect(find.textContaining('加入播放佇列'), findsOneWidget);
        expect(openedDetails, isEmpty);

        // 3. Re-hover and tap cover center -> opens detail
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('album_card_alb-1'))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('album_card_alb-1')));
        await tester.pumpAndSettle();
        expect(openedDetails, ['alb-1']);

        // 4. Tap title text -> also opens detail
        await tester.tap(find.text('Symphony Album 1'));
        await tester.pumpAndSettle();
        expect(openedDetails, ['alb-1', 'alb-1']);
      },
    );

    testWidgets(
      'tapping cover in standalone AlbumsAndCreditsView pushes AlbumDetailPage while Play/More do not',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 1),
          detailsById: {'alb-1': _sampleDetail('alb-1', 1)},
        );
        addTearDown(svc.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              backgroundColor: LuminaTokens.canvasBg,
              body: AlbumsAndCreditsView(audioService: svc),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('album_card_alb-1'))),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('album_card_play_alb-1')));
        await tester.pumpAndSettle();
        expect(find.byType(AlbumDetailPage), findsNothing);
        expect(svc.currentState.status, PlaybackStatus.playing);

        await tester.tap(find.byKey(const Key('album_card_alb-1')));
        await tester.pumpAndSettle();
        expect(find.byType(AlbumDetailPage), findsOneWidget);
      },
    );

    testWidgets(
      'single-card rebuild isolation: hovering one card does not rebuild sibling cards',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 4),
        );
        addTearDown(svc.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              backgroundColor: LuminaTokens.canvasBg,
              body: AlbumsAndCreditsView(audioService: svc),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final siblingCardFinder = find.byKey(const Key('album_card_alb-2'));
        final siblingCardBefore = tester.widget<AlbumCollectionCard>(
          siblingCardFinder,
        );
        final siblingArtBefore = tester.widget<AlbumArtworkView>(
          find.descendant(
            of: siblingCardFinder,
            matching: find.byType(AlbumArtworkView),
          ),
        );

        // Each card is isolated in a RepaintBoundary
        expect(
          find.descendant(
            of: siblingCardFinder,
            matching: find.byType(RepaintBoundary),
          ),
          findsWidgets,
        );

        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);

        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('album_card_alb-1'))),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 110));
        await tester.pumpAndSettle();

        expect(
          identical(
            tester.widget<AlbumCollectionCard>(siblingCardFinder),
            siblingCardBefore,
          ),
          isTrue,
        );
        expect(
          identical(
            tester.widget<AlbumArtworkView>(
              find.descendant(
                of: siblingCardFinder,
                matching: find.byType(AlbumArtworkView),
              ),
            ),
            siblingArtBefore,
          ),
          isTrue,
        );

        // Hover FX mounted ONLY inside alb-1, zero inside alb-2
        expect(
          find.descendant(
            of: find.byKey(const Key('album_card_alb-1')),
            matching: find.byType(ImageFiltered),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: siblingCardFinder,
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: siblingCardFinder,
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
      },
    );
  });

  group('Layout Settings Popover & List Mode Integration', () {
    testWidgets(
      'popover updates columns, presets, slider, spacing, Grid<->List mode, card container, and reset live',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 8),
          detailsById: {'alb-1': _sampleDetail('alb-1', 1)},
        );
        addTearDown(svc.dispose);

        final layoutCtrl = AlbumLayoutSettingsController();
        addTearDown(layoutCtrl.dispose);

        final openedDetails = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              backgroundColor: LuminaTokens.canvasBg,
              body: AlbumsAndCreditsView(
                audioService: svc,
                layoutController: layoutCtrl,
                onOpenAlbumDetail: openedDetails.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Open layout settings popover
        await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_layout_popover')), findsOneWidget);

        int currentCols() {
          final grid = tester.widget<GridView>(
            find.byKey(const Key('album_grid_view')),
          );
          final del =
              grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
          return del.crossAxisCount;
        }

        double currentSpacing() {
          final grid = tester.widget<GridView>(
            find.byKey(const Key('album_grid_view')),
          );
          final del =
              grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
          return del.crossAxisSpacing;
        }

        final standardCols = currentCols();
        expect(currentSpacing(), 18.0);

        // Compact preset -> more columns
        await tester.tap(find.byKey(const Key('preset_cover_compact')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_layout_popover')), findsOneWidget);
        expect(currentCols(), greaterThan(standardCols));

        // Large preset -> fewer columns
        await tester.tap(find.byKey(const Key('preset_cover_large')));
        await tester.pumpAndSettle();
        expect(currentCols(), lessThan(standardCols));

        // Slider adjustment updates extent live
        final sliderFinder = find.byKey(const Key('slider_album_cover_size'));
        await tester.drag(sliderFinder, const Offset(-120, 0));
        await tester.pumpAndSettle();
        expect(layoutCtrl.coverTargetExtent, lessThan(248.0));

        // Spacing presets: narrow (10.0) & wide (28.0)
        await tester.tap(find.byKey(const Key('preset_spacing_narrow')));
        await tester.pumpAndSettle();
        expect(currentSpacing(), 10.0);

        await tester.tap(find.byKey(const Key('preset_spacing_wide')));
        await tester.pumpAndSettle();
        expect(currentSpacing(), 28.0);

        // Toggle card container ON
        await tester.tap(find.byKey(const Key('switch_album_card_container')));
        await tester.pumpAndSettle();
        expect(layoutCtrl.showCardContainer, isTrue);
        final cardContainer = tester.widget<Container>(
          find.byKey(const Key('album_surface_alb-1')),
        );
        expect(cardContainer.padding, const EdgeInsets.all(10));
        expect(
          (cardContainer.decoration! as BoxDecoration).color,
          LuminaTokens.cardBg,
        );

        // Switch to List View
        await tester.tap(find.byKey(const Key('view_mode_list')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_list_view')), findsOneWidget);
        expect(find.byKey(const Key('album_grid_view')), findsNothing);
        expect(find.byType(AlbumCollectionListTile), findsWidgets);

        // Dismiss popover via barrier tap
        await tester.tapAt(const Offset(20, 200));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_layout_popover')), findsNothing);

        // In list view, Play does not open detail, row tap opens detail
        await tester.tap(find.byKey(const Key('album_card_play_alb-1')));
        await tester.pumpAndSettle();
        expect(svc.currentState.status, PlaybackStatus.playing);
        expect(openedDetails, isEmpty);

        await tester.tap(find.text('Symphony Album 1'));
        await tester.pumpAndSettle();
        expect(openedDetails, ['alb-1']);

        // Re-open popover, reset to defaults, and dismiss via Escape key
        await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_album_layout_reset')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_grid_view')), findsOneWidget);
        expect(layoutCtrl.coverTargetExtent, 192.0);
        expect(layoutCtrl.spacingPreset, AlbumGridSpacingPreset.medium);
        expect(layoutCtrl.showCardContainer, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_layout_popover')), findsNothing);
      },
    );

    testWidgets(
      'renders AlbumsAndCreditsView and layout popover at 100% and 150% UI scale with zero overflow exceptions',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _RedesignTestAudioService(
          albumsList: _sampleAlbums(count: 6),
        );
        addTearDown(svc.dispose);
        final scaleCtrl = UiScaleController();
        addTearDown(scaleCtrl.dispose);

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('nav_tab_albums')));
        await tester.pumpAndSettle();

        for (final scale in const [1.0, 1.5]) {
          scaleCtrl.setScale(scale);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // Open popover at this scale
          await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('album_layout_popover')), findsOneWidget);
          expect(tester.takeException(), isNull);

          // Switch to card container ON and List mode at this scale
          final cardSwitch = find.byKey(const Key('switch_album_card_container'));
          await tester.ensureVisible(cardSwitch);
          await tester.pumpAndSettle();
          await tester.tap(cardSwitch);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final listModeBtn = find.byKey(const Key('view_mode_list'));
          await tester.ensureVisible(listModeBtn);
          await tester.pumpAndSettle();
          await tester.tap(listModeBtn);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // Reset back to frameless grid and close popover
          final resetBtn = find.byKey(const Key('btn_album_layout_reset'));
          await tester.ensureVisible(resetBtn);
          await tester.pumpAndSettle();
          await tester.tap(resetBtn);
          await tester.pumpAndSettle();

          final closeBtn = find.byKey(const Key('btn_album_layout_close'));
          await tester.ensureVisible(closeBtn);
          await tester.pumpAndSettle();
          await tester.tap(closeBtn);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  });

  group('AlbumArtworkView onArtworkResolved callback', () {
    testWidgets(
      'invokes onArtworkResolved safely when resolved synchronously via LibraryIndexCache',
      (tester) async {
        final tmpDir = Directory.systemTemp.createTempSync('lumina_art_cb_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File(
          '${tmpDir.path}${Platform.pathSeparator}sync_cover.png',
        )..writeAsBytesSync(_valid1x1Png);

        final cache = LibraryIndexCache();
        cache.setArtworkPathSync('alb-sync', imgFile.path);

        String? resolvedPath;
        String? resolvedUrl;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumArtworkView(
                album: const CanonicalAlbumSummary(
                  id: 'alb-sync',
                  title: 'Sync Album',
                  artist: 'Sync Artist',
                ),
                size: 160,
                libraryCache: cache,
                onArtworkResolved: (cachePath, coverUrl) {
                  resolvedPath = cachePath;
                  resolvedUrl = coverUrl;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(resolvedPath, imgFile.path);
        expect(resolvedUrl, isNull);
      },
    );
  });
}
