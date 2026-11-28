import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

final Uint8List _tinyPngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

MockAudioService _createMockWithAlbum({
  required String albumId,
  required String versionId,
  required List<AlbumAssetRecord> assets,
}) {
  final mock = MockAudioService();
  mock.seedAlbumGroups(<CanonicalAlbumDetail>[
    CanonicalAlbumDetail(
      id: albumId,
      title: 'Step 5 Assets Album',
      artistName: 'Lumina Ensemble',
      releaseYear: 2026,
      primaryVersionId: versionId,
      versions: <AlbumVersionInfo>[
        AlbumVersionInfo(
          id: versionId,
          provider: 'local',
          externalAlbumId: 'ext-$versionId',
          codec: 'FLAC',
          sampleRateHz: 96000,
          bitDepth: 24,
          isDsd: false,
          editionLabel: '',
          isPrimary: true,
          tracks: const <AlbumVersionTrackInfo>[
            AlbumVersionTrackInfo(
              id: 'trk-s5-1',
              title: 'Overture',
              discNumber: 1,
              trackNumber: 1,
              durationMs: 240000,
              codec: 'FLAC',
              sampleRateHz: 96000,
              bitDepth: 24,
              externalTrackId: '/music/overture.flac',
            ),
          ],
        ),
      ],
    ),
  ]);
  final bytesMap = <String, Uint8List>{
    for (final a in assets.where((e) => e.assetKind == AlbumAssetKind.image))
      a.id: _tinyPngBytes,
  };
  mock.setMockAlbumAssets(versionId, assets, bytesByAssetId: bytesMap);
  return mock;
}

Widget _wrapAlbumDetail(MockAudioService mock, String albumId) {
  return MaterialApp(
    theme: LuminaTokens.buildDarkTheme(),
    home: Scaffold(
      body: AlbumDetailPage(
        albumId: albumId,
        audioService: mock,
        showInlineBackButton: false,
      ),
    ),
  );
}

void main() {
  testWidgets('hides PDF digital booklet button when album has no PDFs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final mock = _createMockWithAlbum(
      albumId: 'alb-no-pdf',
      versionId: 'ver-no-pdf',
      assets: const <AlbumAssetRecord>[],
    );
    addTearDown(mock.dispose);

    await tester.pumpWidget(_wrapAlbumDetail(mock, 'alb-no-pdf'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('btn_album_more_options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('btn_album_digital_booklet')), findsNothing);
    expect(find.byKey(const Key('album_cover_gallery_badge')), findsNothing);
  });

  testWidgets('shows PDF digital booklet button and opens single PDF directly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final mock = _createMockWithAlbum(
      albumId: 'alb-single-pdf',
      versionId: 'ver-single-pdf',
      assets: const <AlbumAssetRecord>[
        AlbumAssetRecord(
          id: 'pdf-1',
          albumVersionId: 'ver-single-pdf',
          assetKind: AlbumAssetKind.pdf,
          sourceKind: AlbumAssetSourceKind.file,
          role: AlbumAssetRole.booklet,
          filePath: '/music/Scans/Digital_Booklet.pdf',
          mimeType: 'application/pdf',
          fileSize: 524288,
          displayName: 'Digital Booklet.pdf',
        ),
      ],
    );
    addTearDown(mock.dispose);

    await tester.pumpWidget(_wrapAlbumDetail(mock, 'alb-single-pdf'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('btn_album_more_options')));
    await tester.pumpAndSettle();

    final bookletBtn = find.byKey(const Key('btn_album_digital_booklet'));
    expect(bookletBtn, findsOneWidget);
    expect(find.text('數位小冊子'), findsOneWidget);

    await tester.tap(bookletBtn);
    await tester.pumpAndSettle();

    expect(mock.lastOpenedPdfAsset?.id, 'pdf-1');
  });

  testWidgets('opens PDF picker dialog when multiple PDF booklets exist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final mock = _createMockWithAlbum(
      albumId: 'alb-multi-pdf',
      versionId: 'ver-multi-pdf',
      assets: const <AlbumAssetRecord>[
        AlbumAssetRecord(
          id: 'pdf-1',
          albumVersionId: 'ver-multi-pdf',
          assetKind: AlbumAssetKind.pdf,
          sourceKind: AlbumAssetSourceKind.file,
          role: AlbumAssetRole.booklet,
          mimeType: 'application/pdf',
          fileSize: 204800,
          displayName: 'Booklet EN.pdf',
          sortOrder: 0,
        ),
        AlbumAssetRecord(
          id: 'pdf-2',
          albumVersionId: 'ver-multi-pdf',
          assetKind: AlbumAssetKind.pdf,
          sourceKind: AlbumAssetSourceKind.file,
          role: AlbumAssetRole.booklet,
          mimeType: 'application/pdf',
          fileSize: 307200,
          displayName: 'Booklet JP.pdf',
          sortOrder: 1,
        ),
      ],
    );
    addTearDown(mock.dispose);

    await tester.pumpWidget(_wrapAlbumDetail(mock, 'alb-multi-pdf'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('btn_album_more_options')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_album_digital_booklet')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('album_pdf_picker_dialog')), findsOneWidget);
    expect(find.text('Booklet EN.pdf'), findsOneWidget);
    expect(find.text('Booklet JP.pdf'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pdf_picker_item_pdf-2')));
    await tester.pumpAndSettle();

    expect(mock.lastOpenedPdfAsset?.id, 'pdf-2');
    expect(find.byKey(const Key('album_pdf_picker_dialog')), findsNothing);
  });

  testWidgets(
    'clicking cover opens gallery lightbox with role badge, resolution, and arrow-key navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final mock = _createMockWithAlbum(
        albumId: 'alb-gallery',
        versionId: 'ver-gallery',
        assets: const <AlbumAssetRecord>[
          AlbumAssetRecord(
            id: 'img-front',
            albumVersionId: 'ver-gallery',
            assetKind: AlbumAssetKind.image,
            sourceKind: AlbumAssetSourceKind.file,
            role: AlbumAssetRole.front,
            mimeType: 'image/png',
            width: 1400,
            height: 1400,
            fileSize: 512000,
            displayName: 'cover.png',
            sortOrder: 0,
          ),
          AlbumAssetRecord(
            id: 'img-back',
            albumVersionId: 'ver-gallery',
            assetKind: AlbumAssetKind.image,
            sourceKind: AlbumAssetSourceKind.file,
            role: AlbumAssetRole.back,
            mimeType: 'image/png',
            width: 1200,
            height: 1200,
            fileSize: 400000,
            displayName: 'back.png',
            sortOrder: 1,
          ),
          AlbumAssetRecord(
            id: 'img-media',
            albumVersionId: 'ver-gallery',
            assetKind: AlbumAssetKind.image,
            sourceKind: AlbumAssetSourceKind.file,
            role: AlbumAssetRole.media,
            mimeType: 'image/png',
            width: 1000,
            height: 1000,
            fileSize: 320000,
            displayName: 'disc1.png',
            sortOrder: 2,
          ),
        ],
      );
      addTearDown(mock.dispose);

      await tester.pumpWidget(_wrapAlbumDetail(mock, 'alb-gallery'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('album_cover_gallery_badge')), findsOneWidget);
      expect(find.text('3 張圖片'), findsOneWidget);

      await tester.tap(find.byKey(const Key('album_cover_view')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('album_asset_gallery_lightbox')),
        findsOneWidget,
      );
      expect(find.text('封面 Front'), findsOneWidget);
      expect(find.text('1400 × 1400'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.byKey(const Key('lightbox_thumbnail_strip')), findsOneWidget);

      // Right arrow -> Back Cover
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('封底 Back'), findsOneWidget);
      expect(find.text('1200 × 1200'), findsOneWidget);
      expect(find.text('2 / 3'), findsOneWidget);

      // Right arrow -> Media
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('光碟 Media'), findsOneWidget);
      expect(find.text('1000 × 1000'), findsOneWidget);
      expect(find.text('3 / 3'), findsOneWidget);

      // Left arrow -> Back Cover
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('封底 Back'), findsOneWidget);
      expect(find.text('2 / 3'), findsOneWidget);

      // Click thumbnail 0 -> Front Cover
      await tester.tap(find.byKey(const Key('lightbox_thumb_0')));
      await tester.pumpAndSettle();
      expect(find.text('封面 Front'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);

      // Escape closes lightbox
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('album_asset_gallery_lightbox')),
        findsNothing,
      );
    },
  );
}
