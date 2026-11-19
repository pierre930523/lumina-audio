import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/artists/artist_detail_page.dart';
import 'package:lumina_app/ui/artists/artists_view.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _ArtistTestAudioService extends MockAudioService {
  List<CanonicalAlbumSummary> customAlbums = const [];
  List<TrackInfo> customTracks = const [];
  final List<String> artworkCallIds = [];
  final List<SchedulerPhase> artworkCallPhases = [];
  final Map<String, String> mockArtworkById = {};
  int inFlightArtwork = 0;
  int maxConcurrentArtwork = 0;
  Completer<void>? artworkGate;

  @override
  List<TrackInfo> get queue =>
      customTracks.isNotEmpty ? customTracks : super.queue;

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) async {
    if (customAlbums.isNotEmpty) {
      return customAlbums.take(limit).toList();
    }
    return super.getAlbums(limit: limit);
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    artworkCallIds.add(trackId);
    artworkCallPhases.add(SchedulerBinding.instance.schedulerPhase);
    inFlightArtwork++;
    if (inFlightArtwork > maxConcurrentArtwork) {
      maxConcurrentArtwork = inFlightArtwork;
    }
    try {
      if (artworkGate != null) {
        await artworkGate!.future;
      }
      final file = mockArtworkById[trackId];
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
      return await super.getArtwork(trackId, path: path, maxDim: maxDim);
    } finally {
      inFlightArtwork--;
    }
  }
}

List<TrackInfo> _buildTracks(int count, {String artist = 'Pink Floyd'}) {
  return List<TrackInfo>.generate(count, (i) {
    final albumIdx = i % 3;
    return TrackInfo(
      id: 'trk-$i',
      title: 'Track Title ${i + 1}',
      artist: artist,
      album: 'Studio Album $albumIdx',
      duration: Duration(minutes: 3 + (i % 4), seconds: (i * 13) % 60),
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 96000,
        bitDepth: 24,
        channels: 2,
      ),
    );
  });
}

List<CanonicalAlbumSummary> _buildAlbums(
  int count, {
  String artist = 'Pink Floyd',
}) {
  return List<CanonicalAlbumSummary>.generate(count, (i) {
    return CanonicalAlbumSummary(
      id: 'alb-$i',
      title: 'Studio Album $i',
      artist: artist,
      year: 1967 + i,
    );
  });
}

void main() {
  group('ArtistDetailPage Redesign & Virtualized Sliver Architecture', () {
    testWidgets(
      'renders circular Hero gradient fallback with centered artist name by default even when album artwork exists in cache',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _ArtistTestAudioService()
          ..customTracks = _buildTracks(4, artist: '久石讓')
          ..customAlbums = _buildAlbums(2, artist: '久石讓');
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: svc.customAlbums, tracks: svc.customTracks);

        bool creditsTapped = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '久石讓',
                audioService: svc,
                libraryCache: cache,
                onOpenCredits: () => creditsTapped = true,
              ),
            ),
          ),
        );

        // Frame-0 synchronous render from LibraryIndexCache (before pumpAndSettle)
        final heroAvatarFinder = find.byKey(const Key('artist_hero_avatar'));
        expect(heroAvatarFinder, findsOneWidget);
        expect(
          find.byKey(const Key('artist_hero_gradient_fallback')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('artist_hero_avatar_text')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: heroAvatarFinder,
            matching: find.byType(Image),
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('artist_hero_title')), findsOneWidget);
        expect(find.text('全部曲目 4 首'), findsOneWidget);
        expect(find.byKey(const Key('btn_artist_play_all')), findsOneWidget);
        expect(
          find.byKey(const Key('btn_artist_open_credits')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('btn_artist_open_credits')));
        await tester.pump();
        expect(creditsTapped, isTrue);

        // Even after album artwork is populated in cache, default artist hero avatar
        // (useAlbumArtworkAsAvatar: false) keeps the gradient initial avatar and renders no Image.
        final tmpDir = Directory.systemTemp.createTempSync(
          'lumina_artist_hero_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File('${tmpDir.path}${Platform.pathSeparator}hero.png')
          ..writeAsBytesSync(_valid1x1Png);

        cache.setArtworkPathSync(
          svc.customAlbums.last.id,
          imgFile.path,
          notify: true,
        );
        await tester.pump();

        expect(
          find.byKey(const Key('artist_hero_gradient_fallback')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('artist_hero_avatar_text')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: heroAvatarFinder,
            matching: find.byType(Image),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'renders HD circular Image crop in artist_hero_avatar when useAlbumArtworkAsAvatar is true',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _ArtistTestAudioService()
          ..customTracks = _buildTracks(4, artist: '久石讓')
          ..customAlbums = _buildAlbums(2, artist: '久石讓');
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: svc.customAlbums, tracks: svc.customTracks);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '久石讓',
                audioService: svc,
                libraryCache: cache,
                useAlbumArtworkAsAvatar: true,
              ),
            ),
          ),
        );

        final tmpDir = Directory.systemTemp.createTempSync(
          'lumina_artist_hero_optin_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File('${tmpDir.path}${Platform.pathSeparator}hero.png')
          ..writeAsBytesSync(_valid1x1Png);

        cache.setArtworkPathSync(
          svc.customAlbums.last.id,
          imgFile.path,
          notify: true,
        );
        await tester.pump();

        final heroAvatarFinder = find.byKey(const Key('artist_hero_avatar'));
        expect(
          find.descendant(
            of: heroAvatarFinder,
            matching: find.byType(ClipOval),
          ),
          findsWidgets,
        );
        expect(
          find.descendant(
            of: heroAvatarFinder,
            matching: find.byType(Image),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'ArtistsView uses zero artwork FFI calls, ArtistDetailPage respects showInlineBackButton: false, and track artwork deduplicates via album cache with <=2 concurrent requests',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tmpDir = Directory.systemTemp.createTempSync(
          'lumina_artist_perf_',
        );
        addTearDown(() => tmpDir.deleteSync(recursive: true));
        final imgFile = File('${tmpDir.path}${Platform.pathSeparator}alb.png')
          ..writeAsBytesSync(_valid1x1Png);

        // 5 tracks all belonging to the same single album 'alb-0'
        final tracks = _buildTracks(5, artist: 'Joe Hisaishi').map((t) {
          return t.copyWith(album: 'Studio Album 0');
        }).toList();
        final albums = _buildAlbums(1, artist: 'Joe Hisaishi');

        final svc = _ArtistTestAudioService()
          ..customTracks = tracks
          ..customAlbums = albums
          ..mockArtworkById['alb-0'] = imgFile.path;
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: albums, tracks: tracks);
        addTearDown(cache.dispose);

        // 1. ArtistsView renders gradient avatars at 0 artwork FFI cost
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: ArtistsView(
                audioService: svc,
                libraryCache: cache,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AlbumArtworkView), findsNothing);
        expect(find.byType(Image), findsNothing);
        expect(svc.artworkCallIds, isEmpty);

        // 2. ArtistDetailPage hides inline back button when showInlineBackButton: false,
        // defers getArtwork past frame 0, and deduplicates all 5 tracks through alb-0!
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: 'Joe Hisaishi',
                audioService: svc,
                libraryCache: cache,
                onBack: () {},
                showInlineBackButton: false,
              ),
            ),
          ),
        );

        // Frame 0: no inline back button and getArtwork was deferred out of build/layout
        expect(find.byKey(const Key('artist_detail_back_btn')), findsNothing);
        expect(svc.artworkCallPhases, everyElement(SchedulerPhase.idle));

        await tester.pumpAndSettle();

        // All 5 track rows + album card deduplicated to a single 'alb-0' request!
        expect(svc.artworkCallIds, ['alb-0']);
        expect(cache.getArtworkPathSync('alb-0'), imgFile.path);
        // Track rows render Image from the album cache, while Hero avatar stays gradient.
        expect(
          find.descendant(
            of: find.byKey(const Key('artist_hero_avatar')),
            matching: find.byType(Image),
          ),
          findsNothing,
        );
        expect(find.byType(Image), findsWidgets);
      },
    );

    test(
      'LibraryIndexCache.resolveArtworkPath caps concurrent uncached getArtwork requests at 2',
      () async {
        final svc = _ArtistTestAudioService();
        addTearDown(svc.dispose);
        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);

        final gate = Completer<void>();
        svc.artworkGate = gate;

        final futures = List<Future<String?>>.generate(
          5,
          (i) => cache.resolveArtworkPath(svc, 'uncached-$i'),
        );

        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(svc.inFlightArtwork, 2);
        expect(svc.maxConcurrentArtwork, 2);

        gate.complete();
        await Future.wait(futures);

        expect(svc.maxConcurrentArtwork, 2);
        expect(svc.artworkCallIds.length, 5);
      },
    );

    testWidgets(
      'supports 播放全部, playing track highlight, 全部 X 首 inline toggle, and clickable middle-column album title',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tracks = _buildTracks(10);
        final albums = _buildAlbums(3);
        final svc = _ArtistTestAudioService()
          ..customTracks = tracks
          ..customAlbums = albums;
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: albums, tracks: tracks);

        String? openedAlbumId;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: 'Pink Floyd',
                audioService: svc,
                libraryCache: cache,
                onOpenAlbumDetail: (albumId) => openedAlbumId = albumId,
              ),
            ),
          ),
        );

        // Default preview shows 6 tracks (0..5), track 6 is not shown yet
        expect(find.byKey(const Key('artist_track_0')), findsOneWidget);
        expect(find.byKey(const Key('artist_track_5')), findsOneWidget);
        expect(find.byKey(const Key('artist_track_6')), findsNothing);
        expect(find.text('全部 10 首'), findsOneWidget);

        // Click '播放全部' -> plays first track and highlights active row
        await tester.tap(find.byKey(const Key('btn_artist_play_all')));
        await tester.pump();
        expect(svc.currentState.status, PlaybackStatus.playing);
        expect(svc.currentState.track?.id, 'trk-0');
        expect(
          find.byKey(const Key('artist_track_playing_indicator')),
          findsOneWidget,
        );

        // Hover and click middle-column album title on track 0 ('Studio Album 0' -> 'alb-0')
        final albumColFinder = find.byKey(const Key('artist_track_album_0'));
        expect(albumColFinder, findsOneWidget);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(albumColFinder));
        await tester.pump();

        await tester.tap(albumColFinder);
        await tester.pump();
        expect(openedAlbumId, 'alb-0');

        // Toggle '全部 10 首' -> expands inline to full virtualized SliverList
        await tester.tap(
          find.byKey(const Key('btn_artist_toggle_all_tracks')),
        );
        await tester.pump();
        expect(find.byKey(const Key('artist_track_6')), findsOneWidget);
        expect(find.byKey(const Key('artist_track_9')), findsOneWidget);

        // Toggle again -> collapses back to 6 preview rows cleanly
        await tester.tap(
          find.byKey(const Key('btn_artist_toggle_all_tracks')),
        );
        await tester.pump();
        expect(find.byKey(const Key('artist_track_5')), findsOneWidget);
        expect(find.byKey(const Key('artist_track_6')), findsNothing);
      },
    );

    testWidgets(
      'scrolls 50+ albums smoothly in SliverGrid with SliverGridDelegateWithMaxCrossAxisExtent, newest-first sorting, RepaintBoundary isolation, and zero shrinkWrap',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final albums = _buildAlbums(56);
        final tracks = _buildTracks(8);
        final svc = _ArtistTestAudioService()
          ..customAlbums = albums
          ..customTracks = tracks;
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: albums, tracks: tracks);

        String? tappedAlbumId;
        double lastScrollOffset = 0.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: 'Pink Floyd',
                audioService: svc,
                libraryCache: cache,
                onOpenAlbumDetail: (id) => tappedAlbumId = id,
                onScrollOffsetChanged: (offset) => lastScrollOffset = offset,
              ),
            ),
          ),
        );

        // Verify single CustomScrollView and SliverGrid with SliverGridDelegateWithMaxCrossAxisExtent
        expect(find.byType(CustomScrollView), findsOneWidget);
        final sliverGrid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        expect(
          sliverGrid.gridDelegate,
          isA<SliverGridDelegateWithMaxCrossAxisExtent>(),
        );

        // Strictly zero shrinkWrap ScrollViews
        final scrollViews = tester.widgetList<ScrollView>(
          find.byType(ScrollView),
        );
        for (final sv in scrollViews) {
          expect(sv.shrinkWrap, isFalse);
        }

        // Verify header count & newest-to-oldest release year ordering (alb-55 year 2022 first)
        expect(find.text('主專輯 (56)'), findsOneWidget);
        expect(
          find.byKey(const Key('artist_album_card_alb-55')),
          findsOneWidget,
        );
        expect(find.text('2022'), findsOneWidget);

        // Verify RepaintBoundary wraps track rows and album cards
        expect(
          find.ancestor(
            of: find.byKey(const Key('artist_track_0')),
            matching: find.byType(RepaintBoundary),
          ),
          findsWidgets,
        );
        expect(
          find.ancestor(
            of: find.byKey(const Key('artist_album_card_alb-55')),
            matching: find.byType(RepaintBoundary),
          ),
          findsWidgets,
        );

        // Tap newest album card -> triggers onOpenAlbumDetail
        await tester.tap(find.byKey(const Key('artist_album_card_alb-55')));
        await tester.pump();
        expect(tappedAlbumId, 'alb-55');

        // Scroll down through the 56-album SliverGrid smoothly
        for (var i = 0; i < 4; i++) {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -650),
          );
          await tester.pumpAndSettle();
        }
        expect(lastScrollOffset, greaterThan(500));

        // Older albums are now lazily built into the viewport while offscreen top ones are recycled
        expect(
          find.byKey(const Key('artist_album_card_alb-0')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders ArtistsView and ArtistDetailPage at 100% and 150% UI scale without layout overflow',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final albums = _buildAlbums(20);
        final tracks = _buildTracks(12);
        final svc = _ArtistTestAudioService()
          ..customAlbums = albums
          ..customTracks = tracks;
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: albums, tracks: tracks);
        final scaleCtrl = UiScaleController();
        addTearDown(scaleCtrl.dispose);

        for (final scale in [1.0, 1.5]) {
          scaleCtrl.setScale(scale);
          final logicalSize = Size(1400 / scale, 900 / scale);

          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(useMaterial3: true),
              home: MediaQuery(
                data: MediaQueryData(size: logicalSize),
                child: SizedBox(
                  width: logicalSize.width,
                  height: logicalSize.height,
                  child: Scaffold(
                    body: ArtistsView(
                      audioService: svc,
                      libraryCache: cache,
                      onOpenCredits: () {},
                      onOpenAlbumDetail: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          expect(
            find.byKey(const Key('artist_tile_Pink Floyd')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('artist_tile_Pink Floyd')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          expect(find.byKey(const Key('btn_artist_play_all')), findsOneWidget);
          expect(find.text('主專輯 (20)'), findsOneWidget);

          // Navigate back via local fallback back button
          await tester.tap(find.byKey(const Key('artist_detail_back_btn')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  });
}
