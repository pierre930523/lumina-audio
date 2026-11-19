import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:material_ui/material_ui.dart';

class _TestAlbumAudioService extends MockAudioService {
  CanonicalAlbumDetail? customDetail;
  int getAlbumDetailCalls = 0;

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    getAlbumDetailCalls++;
    if (customDetail != null) return customDetail;
    return super.getAlbumDetail(albumId);
  }
}

CanonicalAlbumDetail _buildSampleHiResAlbumDetail() {
  final tracks = List<AlbumVersionTrackInfo>.generate(
    27,
    (i) => AlbumVersionTrackInfo(
      id: 'trk-hires-${i + 1}',
      title: 'Symphonic Movement No. ${i + 1}',
      discNumber: i < 14 ? 1 : 2,
      trackNumber: i < 14 ? (i + 1) : (i - 13),
      // 27 tracks * 244,444ms ~= 6,600,000ms = 110 minutes (1小時 50分)
      durationMs: i == 26 ? 244456 : 244444,
      codec: 'flac',
      sampleRateHz: 48000,
      bitDepth: 24,
      externalTrackId: '/music/movement_${i + 1}.flac',
    ),
  );

  return CanonicalAlbumDetail(
    id: 'alb-hires-27',
    title: 'The Complete Studio Symphonic Anthology (Deluxe Remastered Edition)',
    artistName: 'Joe Hisaishi & Orchestra',
    releaseYear: 2024,
    editorialBio: '完整收錄雙碟 27 首交響樂母帶錄音。',
    versions: [
      AlbumVersionInfo(
        id: 'ver-hires-1',
        provider: 'local',
        externalAlbumId: 'loc-hires-27',
        editionLabel: '24-bit Studio Master',
        codec: 'flac',
        sampleRateHz: 48000,
        bitDepth: 24,
        tracks: tracks,
      ),
    ],
    credits: const [
      AlbumCreditInfo(
        artistId: 'art-jh',
        artistName: 'Joe Hisaishi & Orchestra',
        role: '作曲 / 指揮',
        albumId: 'alb-hires-27',
      ),
    ],
  );
}

void main() {
  group('AlbumDetailPage Unified Metadata Formatting', () {
    test('formats >= 1 hour and < 1 hour unified metadata strings accurately', () {
      final album27 = _buildSampleHiResAlbumDetail();
      expect(
        AlbumDetailPage.formatUnifiedMetadata(album27.versions.first),
        '1小時 50分 · FLAC · 48 kHz · 24-bit · 27 首',
      );

      const shortVersionWithSec = AlbumVersionInfo(
        id: 'v-short-1',
        provider: 'local',
        externalAlbumId: 'ext-s1',
        editionLabel: 'Standard',
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
        tracks: [
          AlbumVersionTrackInfo(
            id: 't1',
            title: 'Part 1',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 1500000, // 25m
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/1.flac',
          ),
          AlbumVersionTrackInfo(
            id: 't2',
            title: 'Part 2',
            discNumber: 1,
            trackNumber: 2,
            durationMs: 1035000, // 17m 15s -> total 42m 15s
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/2.flac',
          ),
        ],
      );
      expect(
        AlbumDetailPage.formatUnifiedMetadata(shortVersionWithSec),
        '42分 15秒 · FLAC · 44.1 kHz · 16-bit · 2 首',
      );

      const shortVersionExactMin = AlbumVersionInfo(
        id: 'v-short-2',
        provider: 'qobuz',
        externalAlbumId: 'ext-s2',
        editionLabel: 'Hi-Res',
        codec: 'alac',
        sampleRateHz: 96000,
        bitDepth: 24,
        tracks: [
          AlbumVersionTrackInfo(
            id: 't1',
            title: 'Full Suite',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 2520000, // 42m 00s
            codec: 'alac',
            sampleRateHz: 96000,
            bitDepth: 24,
            externalTrackId: '/music/suite.m4a',
          ),
        ],
      );
      expect(
        AlbumDetailPage.formatUnifiedMetadata(shortVersionExactMin),
        '42分 · ALAC · 96 kHz · 24-bit · 1 首',
      );
    });
  });

  group('AlbumDetailPage Modern Desktop Layout & Smoothness', () {
    testWidgets(
      'renders Hero synchronously on frame 0 from LibraryIndexCache with zero blank flash',
      (tester) async {
        final service = _TestAlbumAudioService();
        addTearDown(service.dispose);
        final detail = _buildSampleHiResAlbumDetail();
        service.customDetail = detail;

        final cache = LibraryIndexCache();
        cache.putAlbumDetailSync(detail);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: detail.id,
                audioService: service,
                libraryCache: cache,
                onBack: () {},
              ),
            ),
          ),
        );
        // Check on frame 0 BEFORE pumpAndSettle():
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byKey(const Key('album_hero_title')), findsOneWidget);
        expect(find.text(detail.title), findsWidgets);
        expect(find.byKey(const Key('album_hero_artist')), findsOneWidget);
        expect(find.byKey(const Key('btn_play_album')), findsOneWidget);
        expect(find.text('播放專輯'), findsOneWidget);
        expect(
          find.text('1小時 50分 · FLAC · 48 kHz · 24-bit · 27 首'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Hero and track artist names show pointer cursor + hover underline and fire onOpenArtist on tap',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final service = _TestAlbumAudioService();
        addTearDown(service.dispose);
        final detail = _buildSampleHiResAlbumDetail();
        service.customDetail = detail;

        final openedArtists = <String>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: detail.id,
                audioService: service,
                onBack: () {},
                onOpenArtist: openedArtists.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final heroArtistFinder = find.byKey(const Key('album_hero_artist'));
        expect(heroArtistFinder, findsOneWidget);

        // Before hover: no underline
        Text heroArtistText = tester.widget<Text>(
          find.descendant(
            of: heroArtistFinder,
            matching: find.byType(Text),
          ),
        );
        expect(heroArtistText.style?.decoration, TextDecoration.none);

        // Hover over Hero artist name
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(heroArtistFinder));
        await tester.pump();

        heroArtistText = tester.widget<Text>(
          find.descendant(
            of: heroArtistFinder,
            matching: find.byType(Text),
          ),
        );
        expect(heroArtistText.style?.decoration, TextDecoration.underline);
        expect(heroArtistText.style?.color, const Color(0xFF7B92F8));

        // Tap Hero artist name -> triggers onOpenArtist
        await tester.tap(heroArtistFinder);
        await tester.pump();
        expect(openedArtists, ['Joe Hisaishi & Orchestra']);

        // Hover and tap Track 0 artist link
        final trackArtistFinder = find.byKey(
          const Key('album_track_artist_0'),
        );
        expect(trackArtistFinder, findsOneWidget);
        await gesture.moveTo(tester.getCenter(trackArtistFinder));
        await tester.pump();

        final trackArtistText = tester.widget<Text>(
          find.descendant(
            of: trackArtistFinder,
            matching: find.byType(Text),
          ),
        );
        expect(trackArtistText.style?.decoration, TextDecoration.underline);

        await tester.tap(trackArtistFinder);
        await tester.pump();
        expect(
          openedArtists,
          ['Joe Hisaishi & Orchestra', 'Joe Hisaishi & Orchestra'],
        );
      },
    );

    testWidgets(
      'uses single CustomScrollView with zero shrinkWrap, preserves scroll offset, and highlights playing track',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final service = _TestAlbumAudioService();
        addTearDown(service.dispose);
        final detail = _buildSampleHiResAlbumDetail();
        service.customDetail = detail;

        double latestOffset = 0.0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: detail.id,
                audioService: service,
                onBack: () {},
                onScrollOffsetChanged: (offset) => latestOffset = offset,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Single CustomScrollView and strictly zero shrinkWrap ScrollViews
        expect(find.byType(CustomScrollView), findsOneWidget);
        expect(find.byType(AlbumArtworkView), findsOneWidget);
        final scrollViews = tester.widgetList<ScrollView>(
          find.byType(ScrollView),
        );
        for (final sv in scrollViews) {
          expect(sv.shrinkWrap, isFalse);
        }

        // Click '播放專輯' -> starts playing first track and shows playing highlight icon
        await tester.tap(find.byKey(const Key('btn_play_album')));
        await tester.pumpAndSettle();

        expect(service.currentState.status, PlaybackStatus.playing);
        expect(service.currentState.track?.id, 'trk-hires-1');
        expect(
          find.byKey(const Key('track_playing_icon_trk-hires-1')),
          findsOneWidget,
        );

        // Tap track index 1 -> playing highlight moves to trk-hires-2
        await tester.tap(find.byKey(const Key('album_track_1')));
        await tester.pumpAndSettle();

        expect(service.currentState.track?.id, 'trk-hires-2');
        expect(
          find.byKey(const Key('track_playing_icon_trk-hires-1')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('track_playing_icon_trk-hires-2')),
          findsOneWidget,
        );

        // Scroll down and verify scroll offset callback + restoration
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -320),
        );
        await tester.pumpAndSettle();
        expect(latestOffset, greaterThan(200.0));
      },
    );

    testWidgets(
      'renders cleanly at 100% and 150% UI scale without layout overflow',
      (tester) async {
        final service = _TestAlbumAudioService();
        addTearDown(service.dispose);
        service.customDetail = _buildSampleHiResAlbumDetail();

        for (final scale in [1.0, 1.5]) {
          tester.view.devicePixelRatio = scale;
          tester.view.physicalSize = const Size(1280, 900);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: AlbumDetailPage(
                  albumId: 'alb-hires-27',
                  audioService: service,
                  onBack: () {},
                  onOpenArtist: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('btn_play_album')), findsOneWidget);
          expect(
            find.byKey(const Key('album_unified_metadata_row')),
            findsOneWidget,
          );
        }
      },
    );
  });
}
