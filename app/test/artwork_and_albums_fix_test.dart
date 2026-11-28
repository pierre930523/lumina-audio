import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/home/home_dashboard_view.dart';
import 'package:material_ui/material_ui.dart';

// Valid 1x1 transparent PNG bytes for testing real Image.file rendering without mock network.
final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _ArtworkTestAudioService extends MockAudioService {
  final Map<String, String> resolvedFilesById = {};
  final List<({String id, int maxDim})> artworkRequests = [];
  CanonicalAlbumDetail? customDetail;
  List<CanonicalAlbumSummary>? customAlbums;

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async {
    return customAlbums ??
        await super.getAlbums(limit: limit, includeHidden: includeHidden);
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    return customDetail ?? await super.getAlbumDetail(albumId);
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    artworkRequests.add((id: trackId, maxDim: maxDim));
    final file = resolvedFilesById[trackId];
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

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    resolvedFilesById[trackId] = imagePath;
    return super.setUserCover(trackId, imagePath, path: path);
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    resolvedFilesById.remove(trackId);
    return super.clearUserCover(trackId, path: path);
  }
}

void main() {
  group('AudioFormat unified formatting helper', () {
    test('formats standard, hi-res, and DSD formats consistently', () {
      expect(
        AudioFormat.formatLabel(
          codec: 'flac',
          sampleRateHz: 44100,
          bitDepth: 16,
        ),
        'FLAC 44.1 kHz / 16-bit',
      );
      expect(
        AudioFormat.formatLabel(
          codec: 'alac',
          sampleRateHz: 88200,
          bitDepth: 24,
        ),
        'ALAC 88.2 kHz / 24-bit',
      );
      expect(
        AudioFormat.formatLabel(
          codec: 'wav',
          sampleRateHz: 96000,
          bitDepth: 24,
        ),
        'WAV 96 kHz / 24-bit',
      );
      expect(
        AudioFormat.formatLabel(
          codec: 'dsf',
          sampleRateHz: 2822400,
          bitDepth: 1,
          isDsd: true,
        ),
        'DSD64',
      );

      const ver = AlbumVersionInfo(
        id: 'v1',
        provider: 'local',
        externalAlbumId: 'ext-1',
        editionLabel: 'Standard',
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
      );
      expect(ver.formatSummary, 'FLAC 44.1 kHz / 16-bit');

      const trk = AlbumVersionTrackInfo(
        id: 't1',
        title: 'Track 1',
        discNumber: 1,
        trackNumber: 1,
        durationMs: 180000,
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
        externalTrackId: '/music/01.flac',
      );
      expect(trk.formatSummary, 'FLAC 44.1 kHz / 16-bit');
    });
  });

  group('Track sorting and duplicate track number fix', () {
    test('sorts by discNumber + trackNumber and prevents duplicate 1s on multi-disc', () {
      const version = AlbumVersionInfo(
        id: 'v-multi',
        provider: 'local',
        externalAlbumId: 'ext-multi',
        editionLabel: '2CD Edition',
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
        tracks: [
          AlbumVersionTrackInfo(
            id: 'd2t1',
            title: 'Disc 2 Opener',
            discNumber: 2,
            trackNumber: 1,
            durationMs: 120000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/d2_01.flac',
          ),
          AlbumVersionTrackInfo(
            id: 'd1t2',
            title: 'Disc 1 Second',
            discNumber: 1,
            trackNumber: 2,
            durationMs: 130000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/d1_02.flac',
          ),
          AlbumVersionTrackInfo(
            id: 'd1t1',
            title: 'Disc 1 Opener',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 110000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/d1_01.flac',
          ),
        ],
      );

      final entries = version.orderedTrackEntries;
      expect(entries.map((e) => e.track.id).toList(), ['d1t1', 'd1t2', 'd2t1']);
      expect(entries.map((e) => e.displayNumber).toList(), ['1-1', '1-2', '2-1']);
      expect(entries.map((e) => e.showDiscHeader).toList(), [true, false, true]);
    });

    test('deduplicates repeated track numbers on the same disc', () {
      const version = AlbumVersionInfo(
        id: 'v-dup',
        provider: 'local',
        externalAlbumId: 'ext-dup',
        editionLabel: 'Standard Edition',
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
        tracks: [
          AlbumVersionTrackInfo(
            id: 't1',
            title: 'Prologue ~ Flaptors Attack',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 60000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/01_prologue.flac',
          ),
          AlbumVersionTrackInfo(
            id: 't2',
            title: 'Castle In The Sky',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 180000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/02_castle.flac',
          ),
          AlbumVersionTrackInfo(
            id: 't3',
            title: 'The Girl Who Fell from the Sky',
            discNumber: 1,
            trackNumber: 2,
            durationMs: 200000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: '/music/03_girl.flac',
          ),
        ],
      );

      final entries = version.orderedTrackEntries;
      expect(entries.map((e) => e.displayNumber).toList(), ['1', '2', '3']);
    });
  });

  group('AlbumArtworkView full-res clarity and cover resolution', () {
    testWidgets('requests maxDim: 0, uses FilterQuality.high + isAntiAlias, and omits cacheWidth/Height', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('lumina_art_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final imgFile = File('${tmpDir.path}${Platform.pathSeparator}cover.png')
        ..writeAsBytesSync(_valid1x1Png);

      final service = _ArtworkTestAudioService();
      addTearDown(service.dispose);
      service.resolvedFilesById['alb-cover'] = imgFile.path;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumArtworkView(
              album: const CanonicalAlbumSummary(
                id: 'alb-cover',
                title: 'Cover Album',
                artist: 'Artist',
                coverUrl: '/api/v1/library/artwork/alb-cover',
              ),
              size: 160,
              audioService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(service.artworkRequests, isNotEmpty);
      expect(service.artworkRequests.first.id, 'alb-cover');
      expect(service.artworkRequests.first.maxDim, 0);

      final imgFinder = find.byType(Image);
      expect(imgFinder, findsOneWidget);
      final imgWidget = tester.widget<Image>(imgFinder);
      expect(imgWidget.fit, BoxFit.cover);
      expect(imgWidget.filterQuality, FilterQuality.high);
      expect(imgWidget.isAntiAlias, isTrue);
      expect(imgWidget.image, isA<FileImage>());
      expect(find.byIcon(Icons.album_rounded), findsNothing);
      expect(find.byIcon(Icons.music_note_rounded), findsNothing);
    });

    testWidgets('falls back to gradient+note placeholder only when no cover exists', (
      tester,
    ) async {
      final service = _ArtworkTestAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumArtworkView(
              album: const CanonicalAlbumSummary(
                id: 'alb-empty',
                title: 'No Cover',
                artist: 'Artist',
              ),
              size: 140,
              audioService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });
  });

  group('Home, Albums Grid, and AlbumDetailPage integration', () {
    testWidgets('HomeDashboardView renders real album cover images in Recent Activity', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('lumina_home_art_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final imgFile = File('${tmpDir.path}${Platform.pathSeparator}home_cover.png')
        ..writeAsBytesSync(_valid1x1Png);

      final service = _ArtworkTestAudioService();
      addTearDown(service.dispose);
      service.customAlbums = const [
        CanonicalAlbumSummary(
          id: 'alb-home-1',
          title: 'The Dark Side of the Moon',
          artist: 'Pink Floyd',
          year: 1973,
        ),
        CanonicalAlbumSummary(
          id: 'alb-home-2',
          title: 'Untagged Album',
          artist: 'Unknown',
        ),
      ];
      service.resolvedFilesById['alb-home-1'] = imgFile.path;

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeDashboardView(
              audioService: service,
              onOpenAlbums: () {},
              onOpenLibrary: () {},
              onOpenCredits: () {},
              onOpenDsp: () {},
              onOpenZones: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('AlbumsAndCreditsView shows real cover cards, removes inline detail, and opens AlbumDetailPage on tap at 100% and 150%', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('lumina_grid_art_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final imgFile = File('${tmpDir.path}${Platform.pathSeparator}grid_cover.png')
        ..writeAsBytesSync(_valid1x1Png);

      final service = _ArtworkTestAudioService();
      addTearDown(service.dispose);
      service.resolvedFilesById['alb-dsotm'] = imgFile.path;
      service.customDetail = const CanonicalAlbumDetail(
        id: 'alb-dsotm',
        title: 'Castle in the Sky',
        artistName: '久石讓',
        releaseYear: 1986,
        versions: [
          AlbumVersionInfo(
            id: 'ver-1',
            provider: 'local',
            externalAlbumId: 'loc-1',
            editionLabel: 'Standard Edition',
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            tracks: [
              AlbumVersionTrackInfo(
                id: 't1',
                title: 'Prologue ~ Flaptors Attack',
                discNumber: 1,
                trackNumber: 1,
                durationMs: 65000,
                codec: 'flac',
                sampleRateHz: 44100,
                bitDepth: 16,
                externalTrackId: '/music/01.flac',
              ),
              AlbumVersionTrackInfo(
                id: 't2',
                title: 'Castle In The Sky',
                discNumber: 1,
                trackNumber: 1,
                durationMs: 185000,
                codec: 'flac',
                sampleRateHz: 44100,
                bitDepth: 16,
                externalTrackId: '/music/02.flac',
              ),
            ],
          ),
        ],
      );

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
              body: AlbumsAndCreditsView(audioService: service),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('album_grid_view')), findsOneWidget);
        expect(find.byKey(const Key('canonical_album_detail')), findsNothing);
        expect(find.byType(Image), findsOneWidget);

        // Tap album card -> opens AlbumDetailPage directly
        await tester.tap(find.byKey(const Key('album_card_alb-dsotm')));
        await tester.pumpAndSettle();

        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(find.byKey(const Key('album_detail_back_btn')), findsOneWidget);
        expect(find.text('FLAC 44.1 kHz / 16-bit'), findsWidgets);

        // Duplicate track '1' resolved to '1' and '2'
        expect(find.text('1'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byKey(const Key('album_detail_back_btn')));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('AlbumDetailPage setUserCover and clearUserCover refresh cover immediately', (
      tester,
    ) async {
      final tmpDir = Directory.systemTemp.createTempSync('lumina_detail_cov_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final customImg = File('${tmpDir.path}${Platform.pathSeparator}custom.png')
        ..writeAsBytesSync(_valid1x1Png);

      final service = _ArtworkTestAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumDetailPage(
              albumId: 'alb-dsotm',
              audioService: service,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially no cover -> placeholder
      expect(find.byType(Image), findsNothing);

      // Set external cover via More Options menu
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_set_album_cover')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_album_cover_path')),
        customImg.path,
      );
      await tester.tap(find.text('設定'));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);

      // Clear cover via More Options menu -> returns to placeholder
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_clear_album_cover')));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });
  });
}
