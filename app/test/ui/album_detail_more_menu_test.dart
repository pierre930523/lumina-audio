import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/listen_later_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _MenuSpyAudioService extends MockAudioService {
  int startTagRescanCalls = 0;

  @override
  Future<String> startTagRescan({String? directory, bool force = false}) async {
    startTagRescanCalls++;
    return super.startTagRescan(directory: directory, force: force);
  }
}

final Uint8List _tinyPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

CanonicalAlbumDetail _multiVersionDetail() {
  return CanonicalAlbumDetail(
    id: 'alb-multi',
    title: 'Kind of Blue',
    artistName: 'Miles Davis',
    releaseYear: 1959,
    primaryVersionId: 'ver-1',
    isPrimaryLocked: false,
    versions: const <AlbumVersionInfo>[
      AlbumVersionInfo(
        id: 'ver-1',
        provider: 'local',
        externalAlbumId: 'loc-1',
        codec: 'FLAC',
        sampleRateHz: 96000,
        bitDepth: 24,
        editionLabel: '24-bit 96kHz',
        isPrimary: true,
        tracks: <AlbumVersionTrackInfo>[
          AlbumVersionTrackInfo(
            id: 'trk-m1',
            title: 'So What',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 562000,
            codec: 'FLAC',
            sampleRateHz: 96000,
            bitDepth: 24,
            externalTrackId: '/music/so_what.flac',
          ),
          AlbumVersionTrackInfo(
            id: 'trk-m2',
            title: 'Freddie Freeloader',
            discNumber: 1,
            trackNumber: 2,
            durationMs: 586000,
            codec: 'FLAC',
            sampleRateHz: 96000,
            bitDepth: 24,
            externalTrackId: '/music/freddie.flac',
          ),
        ],
      ),
      AlbumVersionInfo(
        id: 'ver-2',
        provider: 'qobuz',
        externalAlbumId: 'qb-2',
        codec: 'FLAC',
        sampleRateHz: 192000,
        bitDepth: 24,
        editionLabel: 'Qobuz 192kHz',
        isPrimary: false,
        tracks: <AlbumVersionTrackInfo>[
          AlbumVersionTrackInfo(
            id: 'trk-q1',
            title: 'So What (Qobuz)',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 562000,
            codec: 'FLAC',
            sampleRateHz: 192000,
            bitDepth: 24,
            externalTrackId: 'qobuz:qb-1',
          ),
        ],
      ),
    ],
  );
}

void main() {
  testWidgets(
    'AlbumDetail top bar keeps only Play, Add to Queue, and More Options with grouped actions',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final audio = _MenuSpyAudioService();
      audio.seedAlbumGroups(<CanonicalAlbumDetail>[_multiVersionDetail()]);
      audio.setMockAlbumAssets(
        'ver-1',
        const <AlbumAssetRecord>[
          AlbumAssetRecord(
            id: 'pdf-1',
            albumVersionId: 'ver-1',
            assetKind: AlbumAssetKind.pdf,
            sourceKind: AlbumAssetSourceKind.file,
            role: AlbumAssetRole.booklet,
            filePath: '/music/booklet.pdf',
            mimeType: 'application/pdf',
            fileSize: 1024,
            displayName: 'Booklet.pdf',
          ),
          AlbumAssetRecord(
            id: 'img-1',
            albumVersionId: 'ver-1',
            assetKind: AlbumAssetKind.image,
            sourceKind: AlbumAssetSourceKind.file,
            role: AlbumAssetRole.front,
            mimeType: 'image/png',
            fileSize: 64,
            displayName: 'Front.png',
          ),
        ],
        bytesByAssetId: <String, Uint8List>{'img-1': _tinyPng},
      );
      final listenLater = ListenLaterController(audio);
      addTearDown(() {
        listenLater.dispose();
        audio.dispose();
      });

      var openedArtist = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            const scale = 1.25;
            final scaledSize = mq.size / scale;
            return MediaQuery(
              data: mq.copyWith(
                size: scaledSize,
                devicePixelRatio: mq.devicePixelRatio * scale,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: scaledSize.width,
                    height: scaledSize.height,
                    child: child,
                  ),
                ),
              ),
            );
          },
          home: Scaffold(
            body: AlbumDetailPage(
              albumId: 'alb-multi',
              audioService: audio,
              listenLaterController: listenLater,
              onOpenArtist: (name) => openedArtist = name,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top bar keeps ONLY Play Album, Add to Queue, and More Options ('...'),
      // plus tag-pill wrap shortcut btn_album_manage_tags.
      expect(find.byKey(const Key('btn_play_album')), findsOneWidget);
      expect(find.byKey(const Key('btn_add_album_to_queue')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_more_options')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_manage_tags')), findsOneWidget);

      // Legacy inline action buttons are NOT rendered directly in the Hero bar.
      expect(find.byKey(const Key('btn_album_detail_preference')), findsNothing);
      expect(
        find.byKey(const Key('btn_album_detail_listen_later')),
        findsNothing,
      );
      expect(find.byKey(const Key('btn_album_digital_booklet')), findsNothing);
      expect(find.byKey(const Key('btn_set_album_cover')), findsNothing);
      expect(find.byKey(const Key('btn_clear_album_cover')), findsNothing);
      expect(find.byKey(const Key('btn_edit_album_metadata')), findsNothing);

      // 1. Open '...' dropdown -> grouped sections appear inside viewport under scale
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('album_more_options_menu')), findsOneWidget);
      expect(find.text('收藏與瀏覽'), findsOneWidget);
      expect(find.text('喜好設定'), findsOneWidget);
      expect(find.text('詮釋資料與封面'), findsOneWidget);
      expect(find.text('曲庫與版本'), findsOneWidget);
      expect(
        find.byKey(const Key('btn_album_detail_listen_later')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('btn_album_menu_open_artist')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_digital_booklet')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_artwork_gallery')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_pref_love')), findsOneWidget);
      expect(find.byKey(const Key('btn_edit_album_metadata')), findsOneWidget);
      expect(find.byKey(const Key('btn_set_album_cover')), findsOneWidget);
      expect(find.byKey(const Key('btn_clear_album_cover')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_rescan_tags')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_version_ungroup')), findsOneWidget);
      expect(find.byKey(const Key('btn_album_version_split')), findsOneWidget);

      // Verify scaled menu fits inside viewport without overflow errors.
      final menuRect = tester.getRect(
        find.byKey(const Key('album_more_options_menu')),
      );
      expect(menuRect.left, greaterThanOrEqualTo(0.0));
      expect(menuRect.top, greaterThanOrEqualTo(0.0));
      expect(menuRect.right, lessThanOrEqualTo(1280.0));
      expect(menuRect.bottom, lessThanOrEqualTo(900.0));

      // 2. Listen Later action
      await tester.tap(find.byKey(const Key('btn_album_detail_listen_later')));
      await tester.pumpAndSettle();
      expect(listenLater.isSaved(entityType: 'album', entityId: 'alb-multi'), isTrue);

      // 3. Preference Love action via '...' menu
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_album_pref_love')));
      await tester.pumpAndSettle();
      final lovedDetail = await audio.getAlbumDetail('alb-multi');
      expect(lovedDetail?.preference, equals(1));

      // 4. Rescan Tags action via '...' menu
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_album_rescan_tags')));
      await tester.pumpAndSettle();
      expect(audio.startTagRescanCalls, equals(1));

      // 5. Open Artist action via '...' menu
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_album_menu_open_artist')));
      await tester.pumpAndSettle();
      expect(openedArtist, equals('Miles Davis'));
    },
  );
}
