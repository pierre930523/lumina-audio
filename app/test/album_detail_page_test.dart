import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:material_ui/material_ui.dart';

import 'album_detail_redesign_test.dart' as redesign_suite;

class _TestAudioService extends MockAudioService {
  CanonicalAlbumDetail? customDetail;

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    if (customDetail != null) return customDetail;
    return super.getAlbumDetail(albumId);
  }
}

CanonicalAlbumDetail _sampleAlbum() {
  final tracks = List<AlbumVersionTrackInfo>.generate(
    25,
    (i) => AlbumVersionTrackInfo(
      id: 'trk-$i',
      title: 'Track Title ${i + 1}',
      discNumber: 1,
      trackNumber: i + 1,
      durationMs: 240000,
      codec: 'flac',
      sampleRateHz: 48000,
      bitDepth: 24,
      externalTrackId: '/music/t$i.flac',
    ),
  );

  return CanonicalAlbumDetail(
    id: 'alb-test-1',
    title: 'A Night at the Symphony',
    artistName: 'Sample Orchestra',
    releaseYear: 2024,
    versions: [
      AlbumVersionInfo(
        id: 'ver-1',
        provider: 'local',
        externalAlbumId: 'loc-1',
        editionLabel: 'Hi-Res Edition',
        codec: 'flac',
        sampleRateHz: 48000,
        bitDepth: 24,
        tracks: tracks,
      ),
    ],
  );
}

void main() {
  group('AlbumDetailPage Integration & Redesign Suite Forwarding', () {
    redesign_suite.main();
  });

  group('AlbumDetailPage Specific Interaction & Single-Anchor Navigation Tests', () {
    testWidgets(
      'when showInlineBackButton is false, no duplicate back button bar is rendered',
      (tester) async {
        final service = _TestAudioService()..customDetail = _sampleAlbum();
        addTearDown(service.dispose);

        bool backPressed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-test-1',
                audioService: service,
                onBack: () => backPressed = true,
                showInlineBackButton: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('album_detail_back_btn')), findsNothing);
        expect(backPressed, isFalse);
        expect(find.byKey(const Key('album_hero_title')), findsOneWidget);
        expect(find.byKey(const Key('album_cover_view')), findsOneWidget);
      },
    );

    testWidgets(
      'when showInlineBackButton is true, back button is rendered and clickable',
      (tester) async {
        final service = _TestAudioService()..customDetail = _sampleAlbum();
        addTearDown(service.dispose);

        bool backPressed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-test-1',
                audioService: service,
                onBack: () => backPressed = true,
                showInlineBackButton: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final backBtn = find.byKey(const Key('album_detail_back_btn'));
        expect(backBtn, findsOneWidget);
        await tester.tap(backBtn);
        await tester.pumpAndSettle();
        expect(backPressed, isTrue);
      },
    );

    testWidgets(
      'reports title and scroll offset for sticky header in HomeScreen top bar',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = _TestAudioService()..customDetail = _sampleAlbum();
        addTearDown(service.dispose);

        String? reportedTitle;
        double? reportedOffset;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-test-1',
                audioService: service,
                showInlineBackButton: false,
                onTitleChanged: (title) => reportedTitle = title,
                onScrollOffsetChanged: (offset) => reportedOffset = offset,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(reportedTitle, 'A Night at the Symphony');

        // Scroll down
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
        await tester.pumpAndSettle();

        expect(reportedOffset, isNotNull);
        expect(reportedOffset!, greaterThan(200.0));
      },
    );

    testWidgets(
      'tracklist hover turns track number into play button with smooth 30ms transition',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = _TestAudioService()..customDetail = _sampleAlbum();
        addTearDown(service.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-test-1',
                audioService: service,
                showInlineBackButton: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final track0Row = find.byKey(const Key('album_track_0'));
        expect(track0Row, findsOneWidget);

        // Before hover: track number '1' is shown, hover play button is not present
        expect(find.byKey(const Key('track_number_0')), findsOneWidget);
        expect(find.byKey(const Key('track_hover_play_0')), findsNothing);

        // Move pointer to hover over track 0
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);

        await gesture.moveTo(tester.getCenter(track0Row));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // On hover: track number turns into play button
        expect(find.byKey(const Key('track_hover_play_0')), findsOneWidget);

        // Move pointer away
        await gesture.moveTo(const Offset(10, 10));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Returns to track number
        expect(find.byKey(const Key('track_number_0')), findsOneWidget);
        expect(find.byKey(const Key('track_hover_play_0')), findsNothing);
      },
    );

    testWidgets(
      'preserves all existing keys (album_hero_title, btn_play_album, album_cover_view, etc.)',
      (tester) async {
        final service = _TestAudioService()..customDetail = _sampleAlbum();
        addTearDown(service.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-test-1',
                audioService: service,
                showInlineBackButton: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('album_hero_title')), findsOneWidget);
        expect(find.byKey(const Key('btn_play_album')), findsOneWidget);
        expect(find.byKey(const Key('album_cover_view')), findsOneWidget);
        expect(find.byKey(const Key('album_unified_metadata_row')), findsOneWidget);
        expect(find.byKey(const Key('album_hero_artist')), findsOneWidget);
        expect(find.byKey(const Key('btn_add_album_to_queue')), findsOneWidget);
      },
    );
  });
}
