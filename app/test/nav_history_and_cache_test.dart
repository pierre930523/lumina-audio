import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/artists/artist_detail_page.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _CountingAudioService extends MockAudioService {
  int albumDetailCalls = 0;
  int artworkCalls = 0;
  final Map<String, String> coverFiles = {};

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    albumDetailCalls++;
    final base = await super.getAlbumDetail(albumId);
    if (base == null) return null;
    // Give Album A 25 tracks so it is scrollable on a 900px desktop viewport.
    final manyTracks = List<AlbumVersionTrackInfo>.generate(
      25,
      (i) => AlbumVersionTrackInfo(
        id: '$albumId-trk-${i + 1}',
        title: '${base.title} Track ${i + 1}',
        discNumber: 1,
        trackNumber: i + 1,
        durationMs: 210000,
        codec: 'flac',
        sampleRateHz: 96000,
        bitDepth: 24,
        externalTrackId: 'ext-$albumId-${i + 1}',
      ),
    );
    return CanonicalAlbumDetail(
      id: base.id,
      title: base.title,
      artistName: base.artistName,
      releaseYear: base.releaseYear,
      editorialBio: base.editorialBio,
      coverUrl: base.coverUrl,
      credits: base.credits,
      versions: [
        AlbumVersionInfo(
          id: 'ver-$albumId',
          provider: 'local',
          externalAlbumId: 'loc-$albumId',
          editionLabel: '24-bit Studio Master',
          codec: 'flac',
          sampleRateHz: 96000,
          bitDepth: 24,
          tracks: manyTracks,
        ),
      ],
    );
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    artworkCalls++;
    final file = coverFiles[trackId];
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

void main() {
  group('NavEntry & NavHistoryController unit tests', () {
    test(
      'supports full Home -> Album A -> Artist X -> Album B -> < -> < -> < -> > -> > stack and scroll offsets',
      () {
        final controller = NavHistoryController();
        expect(controller.current.tab, HomeTab.home);
        expect(controller.canGoBack, isFalse);
        expect(controller.canGoForward, isFalse);

        // Save Home scroll offset
        controller.saveCurrentScrollOffset(120.0);

        // 1. Home -> Album A
        controller.push(NavEntry.album('alb-dsotm'));
        expect(controller.current.tab, HomeTab.albumDetail);
        expect(controller.current.albumId, 'alb-dsotm');
        expect(controller.canGoBack, isTrue);
        expect(controller.canGoForward, isFalse);
        final albumAEntryId = controller.current.effectiveId;
        controller.saveCurrentScrollOffset(380.0);

        // Duplicate push of same route is a no-op
        controller.push(NavEntry.album('alb-dsotm'));
        expect(controller.backStack.length, 1);

        // 2. Album A -> Artist X
        controller.push(NavEntry.artist(artistName: 'Pink Floyd'));
        expect(controller.current.tab, HomeTab.artistDetail);
        expect(controller.current.artistName, 'Pink Floyd');
        expect(controller.current.artistKey, 'pink floyd');
        final artistXEntryId = controller.current.effectiveId;
        controller.saveCurrentScrollOffset(540.0);

        // 3. Artist X -> Album B
        controller.push(NavEntry.album('alb-wall'));
        expect(controller.current.tab, HomeTab.albumDetail);
        expect(controller.current.albumId, 'alb-wall');
        expect(controller.backStack.length, 3);
        expect(controller.canGoForward, isFalse);

        // < (1): Album B -> Artist X
        final back1 = controller.goBack();
        expect(back1?.tab, HomeTab.artistDetail);
        expect(back1?.artistName, 'Pink Floyd');
        expect(controller.currentScrollOffset, 540.0);
        expect(controller.getScrollOffset(artistXEntryId), 540.0);
        expect(controller.canGoBack, isTrue);
        expect(controller.canGoForward, isTrue);

        // < (2): Artist X -> Album A
        final back2 = controller.goBack();
        expect(back2?.tab, HomeTab.albumDetail);
        expect(back2?.albumId, 'alb-dsotm');
        expect(controller.currentScrollOffset, 380.0);
        expect(controller.getScrollOffset(albumAEntryId), 380.0);
        expect(controller.canGoBack, isTrue);
        expect(controller.canGoForward, isTrue);

        // < (3): Album A -> Home
        final back3 = controller.goBack();
        expect(back3?.tab, HomeTab.home);
        expect(controller.currentScrollOffset, 120.0);
        expect(controller.canGoBack, isFalse);
        expect(controller.canGoForward, isTrue);

        // > (1): Home -> Album A
        final fwd1 = controller.goForward();
        expect(fwd1?.tab, HomeTab.albumDetail);
        expect(fwd1?.albumId, 'alb-dsotm');
        expect(controller.currentScrollOffset, 380.0);
        expect(controller.canGoBack, isTrue);
        expect(controller.canGoForward, isTrue);

        // > (2): Album A -> Artist X
        final fwd2 = controller.goForward();
        expect(fwd2?.tab, HomeTab.artistDetail);
        expect(fwd2?.artistName, 'Pink Floyd');
        expect(controller.currentScrollOffset, 540.0);
        expect(controller.canGoBack, isTrue);
        expect(controller.canGoForward, isTrue);
      },
    );
  });

  group('LibraryIndexCache & zero-flash synchronous artwork rendering', () {
    test(
      'normalizes artist keys case-insensitively, sorts albums newest-first, and deduplicates in-flight loads',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('lumina_cache_test_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File('${tmpDir.path}${Platform.pathSeparator}cover.png')
          ..writeAsBytesSync(_valid1x1Png);

        final service = _CountingAudioService();
        addTearDown(service.dispose);
        service.coverFiles['alb-dsotm'] = imgFile.path;

        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);

        await cache.prime(service);
        expect(cache.isPrimed, isTrue);

        // Case-insensitive lookup
        final entry1 = cache.getArtistSync('Pink Floyd');
        final entry2 = cache.getArtistSync('  pink floyd ');
        expect(entry1, isNotNull);
        expect(identical(entry1, entry2), isTrue);
        expect(entry1!.displayName, 'Pink Floyd');
        expect(entry1.totalTrackCount, 3);

        // Albums sorted newest-first (1979 The Wall before 1973 The Dark Side of the Moon)
        expect(entry1.albums.map((a) => a.id).toList(), [
          'alb-wall',
          'alb-dsotm',
        ]);

        // Deduplicated in-flight loadAlbumDetail
        final results = await Future.wait([
          cache.loadAlbumDetail(service, 'alb-dsotm'),
          cache.loadAlbumDetail(service, 'alb-dsotm'),
          cache.loadAlbumDetail(service, 'alb-dsotm'),
        ]);
        expect(results.first?.id, 'alb-dsotm');
        expect(service.albumDetailCalls, 1);
        expect(cache.getAlbumDetailSync('alb-dsotm')?.title,
            'The Dark Side of the Moon');

        // Deduplicated in-flight resolveArtworkPath
        final artPaths = await Future.wait([
          cache.resolveArtworkPath(service, 'alb-dsotm'),
          cache.resolveArtworkPath(service, 'alb-dsotm'),
        ]);
        expect(artPaths.first, imgFile.path);
        expect(service.artworkCalls, 1);
        expect(cache.getArtworkPathSync('alb-dsotm'), imgFile.path);

        // Invalidate clears cache and allows re-fetch
        cache.invalidateArtwork('alb-dsotm');
        expect(cache.getArtworkPathSync('alb-dsotm'), isNull);
        expect(cache.hasArtworkCached('alb-dsotm'), isFalse);
      },
    );

    testWidgets(
      'AlbumArtworkView renders Image.file synchronously on frame 0 with pre-warmed LibraryIndexCache (no placeholder flash)',
      (tester) async {
        final tmpDir = Directory.systemTemp.createTempSync('lumina_sync_art_');
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File('${tmpDir.path}${Platform.pathSeparator}sync.png')
          ..writeAsBytesSync(_valid1x1Png);

        final service = _CountingAudioService();
        addTearDown(service.dispose);
        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);

        // Pre-populate artwork cache synchronously
        cache.setArtworkPathSync('alb-sync', imgFile.path);

        // Pump ONLY frame 0 (no pumpAndSettle) to assert zero placeholder flash
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: UiScaleScope(
                scale: 1.5,
                child: AlbumArtworkView(
                  album: const CanonicalAlbumSummary(
                    id: 'alb-sync',
                    title: 'Sync Album',
                    artist: 'Artist',
                  ),
                  size: 160,
                  audioService: service,
                  libraryCache: cache,
                  fullResolution: false,
                  circular: true,
                ),
              ),
            ),
          ),
        );

        // Frame 0 already has Image (zero placeholder flash, zero getArtwork FFI call)
        expect(service.artworkCalls, 0);
        expect(find.byType(Image), findsOneWidget);
        expect(find.byType(ClipOval), findsOneWidget);

        final img = tester.widget<Image>(find.byType(Image));
        expect(img.gaplessPlayback, isTrue);
        expect(img.filterQuality, FilterQuality.high);
        expect(img.isAntiAlias, isTrue);
        expect(img.image, isA<ResizeImage>());
      },
    );
  });

  group('Full HomeScreen bidirectional navigation, history buttons & mouse side buttons', () {
    testWidgets(
      'navigates Home -> Album A -> Artist X -> Album B -> < -> < -> < -> > -> > with mouse side buttons and scroll restoration without interrupting playback',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final service = _CountingAudioService();
        addTearDown(service.dispose);
        final navController = NavHistoryController();
        addTearDown(navController.dispose);
        final libraryCache = LibraryIndexCache();
        addTearDown(libraryCache.dispose);

        await libraryCache.prime(service);
        await libraryCache.loadAlbumDetail(service, 'alb-dsotm');
        await libraryCache.loadAlbumDetail(service, 'alb-wall');

        // Start playback before navigating
        await service.play(track: service.queue.first);
        expect(service.currentState.status, PlaybackStatus.playing);

        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: const LuminaDesktopScrollBehavior(),
            theme: ThemeData.dark(useMaterial3: true),
            home: HomeScreen(
              audioService: service,
              libraryCache: libraryCache,
              navHistoryController: navController,
            ),
          ),
        );
        await tester.pumpAndSettle();

        IconButton backBtn() =>
            tester.widget<IconButton>(find.byKey(const Key('btn_nav_back')));
        IconButton fwdBtn() =>
            tester.widget<IconButton>(find.byKey(const Key('btn_nav_forward')));

        // Initially on Home: both < and > disabled
        expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
        expect(backBtn().onPressed, isNull);
        expect(fwdBtn().onPressed, isNull);

        // 1. Home -> Album A ('alb-dsotm') via recent album card
        final homeCard = find.byKey(const Key('home_recent_album_alb-dsotm'));
        expect(homeCard, findsOneWidget);
        await tester.tap(homeCard);
        await tester.pumpAndSettle();

        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(navController.current.tab, HomeTab.albumDetail);
        expect(navController.current.albumId, 'alb-dsotm');
        expect(backBtn().onPressed, isNotNull);
        expect(fwdBtn().onPressed, isNull);

        // Scroll down on Album A and verify offset is recorded
        final albumScroll = find.descendant(
          of: find.byType(AlbumDetailPage),
          matching: find.byType(CustomScrollView),
        );
        expect(albumScroll, findsOneWidget);
        await tester.drag(albumScroll, const Offset(0, -280));
        await tester.pumpAndSettle();
        final savedAlbumAOffset = navController.currentScrollOffset;
        expect(savedAlbumAOffset, greaterThan(100.0));

        // Scroll back near top or tap artist name in Hero (or track row artist)
        final trackArtist = find.byKey(const Key('album_track_artist_5'));
        final heroArtist = find.byKey(const Key('album_hero_artist'));
        if (heroArtist.evaluate().isNotEmpty &&
            tester.any(heroArtist.hitTestable())) {
          await tester.tap(heroArtist);
        } else {
          await tester.tap(trackArtist);
        }
        await tester.pumpAndSettle();

        // 2. Album A -> Artist X ('Pink Floyd')
        expect(find.byType(ArtistDetailPage), findsOneWidget);
        expect(navController.current.tab, HomeTab.artistDetail);
        expect(navController.current.artistName, 'Pink Floyd');
        expect(backBtn().onPressed, isNotNull);
        expect(fwdBtn().onPressed, isNull);

        // 3. Artist X -> Album B ('alb-wall')
        final wallCard = find.byKey(const Key('artist_album_card_alb-wall'));
        await tester.ensureVisible(wallCard);
        await tester.pumpAndSettle();
        await tester.tap(wallCard);
        await tester.pumpAndSettle();

        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(navController.current.tab, HomeTab.albumDetail);
        expect(navController.current.albumId, 'alb-wall');
        expect(backBtn().onPressed, isNotNull);
        expect(fwdBtn().onPressed, isNull);

        // 4. Tap < (1): Album B -> Artist X
        await tester.tap(find.byKey(const Key('btn_nav_back')));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistDetailPage), findsOneWidget);
        expect(navController.current.tab, HomeTab.artistDetail);
        expect(backBtn().onPressed, isNotNull);
        expect(fwdBtn().onPressed, isNotNull);

        // 5. Tap < (2): Artist X -> Album A (with scroll offset restored!)
        await tester.tap(find.byKey(const Key('btn_nav_back')));
        await tester.pumpAndSettle();
        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(navController.current.albumId, 'alb-dsotm');
        expect(
          navController.currentScrollOffset,
          closeTo(savedAlbumAOffset, 1.0),
        );
        final scrollableState = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(AlbumDetailPage),
            matching: find.byType(Scrollable),
          ),
        );
        expect(
          scrollableState.position.pixels,
          closeTo(savedAlbumAOffset, 1.0),
        );

        // 6. Tap < (3): Album A -> Home
        await tester.tap(find.byKey(const Key('btn_nav_back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
        expect(navController.current.tab, HomeTab.home);
        expect(backBtn().onPressed, isNull);
        expect(fwdBtn().onPressed, isNotNull);

        // 7. Tap > (1): Home -> Album A
        await tester.tap(find.byKey(const Key('btn_nav_forward')));
        await tester.pumpAndSettle();
        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(navController.current.albumId, 'alb-dsotm');

        // 8. Tap > (2): Album A -> Artist X
        await tester.tap(find.byKey(const Key('btn_nav_forward')));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistDetailPage), findsOneWidget);
        expect(navController.current.tab, HomeTab.artistDetail);

        // 9. Mouse side button kBackMouseButton -> back to Album A
        tester.binding.handlePointerEvent(
          const PointerDownEvent(
            pointer: 99,
            kind: PointerDeviceKind.mouse,
            position: Offset(400, 300),
            buttons: kBackMouseButton,
          ),
        );
        tester.binding.handlePointerEvent(
          const PointerUpEvent(
            pointer: 99,
            kind: PointerDeviceKind.mouse,
            position: Offset(400, 300),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(navController.current.albumId, 'alb-dsotm');

        // 10. Mouse side button kForwardMouseButton -> forward to Artist X
        tester.binding.handlePointerEvent(
          const PointerDownEvent(
            pointer: 100,
            kind: PointerDeviceKind.mouse,
            position: Offset(400, 300),
            buttons: kForwardMouseButton,
          ),
        );
        tester.binding.handlePointerEvent(
          const PointerUpEvent(
            pointer: 100,
            kind: PointerDeviceKind.mouse,
            position: Offset(400, 300),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ArtistDetailPage), findsOneWidget);
        expect(navController.current.tab, HomeTab.artistDetail);

        // Sidebar and bottom player bar remained mounted and playback never stopped
        expect(find.byType(FloatingCapsuleMiniPlayer), findsOneWidget);
        expect(service.currentState.status, PlaybackStatus.playing);
      },
    );
  });
}
