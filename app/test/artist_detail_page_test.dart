import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/artists/artist_detail_page.dart';
import 'package:material_ui/material_ui.dart';

import 'artist_detail_redesign_test.dart' as artist_redesign_suite;

class _TestArtistAudioService extends MockAudioService {
  List<CanonicalAlbumSummary> customAlbums = const [];
  List<TrackInfo> customTracks = const [];

  @override
  List<TrackInfo> get queue => customTracks.isNotEmpty ? customTracks : super.queue;

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async {
    if (customAlbums.isNotEmpty) return customAlbums.take(limit).toList();
    return super.getAlbums(limit: limit, includeHidden: includeHidden);
  }
}

List<TrackInfo> _buildTestTracks(int count, {String artist = 'Test Artist'}) {
  return List<TrackInfo>.generate(count, (i) {
    return TrackInfo(
      id: 'artist-trk-$i',
      title: 'Artist Song ${i + 1}',
      artist: artist,
      album: 'Artist Album ${i % 2}',
      duration: Duration(minutes: 3, seconds: i * 15),
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
    );
  });
}

List<CanonicalAlbumSummary> _buildTestAlbums(int count, {String artist = 'Test Artist'}) {
  return List<CanonicalAlbumSummary>.generate(count, (i) {
    return CanonicalAlbumSummary(
      id: 'artist-alb-$i',
      title: 'Artist Album $i',
      artist: artist,
      year: 2020 + i,
    );
  });
}

void main() {
  group('ArtistDetailPage Integration & Redesign Suite Forwarding', () {
    artist_redesign_suite.main();
  });

  group('ArtistDetailPage Specific Interaction & Single-Anchor Navigation Tests', () {
    testWidgets(
      'when showInlineBackButton is false, no duplicate back button or duplicate title bar appears',
      (tester) async {
        final svc = _TestArtistAudioService()
          ..customTracks = _buildTestTracks(3, artist: '坂本龍一')
          ..customAlbums = _buildTestAlbums(2, artist: '坂本龍一');
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: svc.customAlbums, tracks: svc.customTracks);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '坂本龍一',
                audioService: svc,
                libraryCache: cache,
                showInlineBackButton: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('artist_detail_back_btn')), findsNothing);
        expect(find.byKey(const Key('artist_hero_title')), findsOneWidget);
        expect(find.byKey(const Key('artist_hero_name')), findsOneWidget);
      },
    );

    testWidgets(
      'when showInlineBackButton is true, back button is rendered and clickable',
      (tester) async {
        final svc = _TestArtistAudioService()
          ..customTracks = _buildTestTracks(2, artist: '坂本龍一')
          ..customAlbums = _buildTestAlbums(1, artist: '坂本龍一');
        addTearDown(svc.dispose);

        bool backPressed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '坂本龍一',
                audioService: svc,
                showInlineBackButton: true,
                onBack: () => backPressed = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final backBtn = find.byKey(const Key('artist_detail_back_btn'));
        expect(backBtn, findsOneWidget);
        await tester.tap(backBtn);
        await tester.pumpAndSettle();
        expect(backPressed, isTrue);
      },
    );

    testWidgets(
      'maintains _ArtistGradientAvatar as default without flashing',
      (tester) async {
        final svc = _TestArtistAudioService()
          ..customTracks = _buildTestTracks(2, artist: '坂本龍一')
          ..customAlbums = _buildTestAlbums(1, artist: '坂本龍一');
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: svc.customAlbums, tracks: svc.customTracks);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '坂本龍一',
                audioService: svc,
                libraryCache: cache,
                useAlbumArtworkAsAvatar: false,
              ),
            ),
          ),
        );

        // Frame 0 synchronous gradient avatar check
        expect(find.byKey(const Key('artist_hero_gradient_fallback')), findsOneWidget);
        expect(find.byKey(const Key('artist_hero_avatar_text')), findsOneWidget);
        expect(find.text('坂本龍一'), findsWidgets);

        await tester.pumpAndSettle();
        expect(find.byKey(const Key('artist_hero_gradient_fallback')), findsOneWidget);
      },
    );

    testWidgets(
      'preserves all existing keys (artist_hero_name, artist_detail_scroll_view, etc.)',
      (tester) async {
        final svc = _TestArtistAudioService()
          ..customTracks = _buildTestTracks(2, artist: '坂本龍一')
          ..customAlbums = _buildTestAlbums(2, artist: '坂本龍一');
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: svc.customAlbums, tracks: svc.customTracks);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '坂本龍一',
                audioService: svc,
                libraryCache: cache,
                showInlineBackButton: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('artist_hero_name')), findsOneWidget);
        expect(find.byKey(const Key('artist_hero_title')), findsOneWidget);
        expect(find.byKey(const Key('artist_detail_scroll_view')), findsOneWidget);
        expect(find.byKey(const Key('artist_hero_avatar')), findsOneWidget);
        expect(find.byKey(const Key('btn_artist_play_all')), findsOneWidget);
        expect(find.byKey(const Key('artist_hero_track_stats')), findsOneWidget);
      },
    );

    testWidgets(
      'artist tracklist hover turns track number into play button with smooth 30ms transition',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _TestArtistAudioService()
          ..customTracks = _buildTestTracks(3, artist: '坂本龍一')
          ..customAlbums = _buildTestAlbums(1, artist: '坂本龍一');
        addTearDown(svc.dispose);

        final cache = LibraryIndexCache()
          ..seedSync(albums: svc.customAlbums, tracks: svc.customTracks);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtistDetailPage(
                artistName: '坂本龍一',
                audioService: svc,
                libraryCache: cache,
                showInlineBackButton: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final track0Row = find.byKey(const Key('artist_track_0'));
        expect(track0Row, findsOneWidget);

        // Before hover: number is shown
        expect(find.byKey(const Key('artist_track_num_0')), findsOneWidget);
        expect(find.byKey(const Key('artist_track_hover_play')), findsNothing);

        // Hover over track
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);

        await gesture.moveTo(tester.getCenter(track0Row));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Hover: play button icon appears
        expect(find.byKey(const Key('artist_track_hover_play')), findsOneWidget);

        // Hover out
        await gesture.moveTo(const Offset(10, 10));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Returns to number
        expect(find.byKey(const Key('artist_track_num_0')), findsOneWidget);
        expect(find.byKey(const Key('artist_track_hover_play')), findsNothing);
      },
    );
  });
}
