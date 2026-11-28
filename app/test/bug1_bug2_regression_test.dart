import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/settings/library_settings_panel.dart';

class _RegressionAudioService extends MockAudioService {
  List<CanonicalAlbumSummary> customAlbums = const [];
  final Map<String, CanonicalAlbumDetail> customDetails = {};
  final List<String> startedScanPaths = [];
  final List<({String? directory, bool force})> startedTagRescans = [];
  int scanSeq = 0;

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async => customAlbums;

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async =>
      customDetails[albumId] ?? await super.getAlbumDetail(albumId);

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    startedScanPaths.add(path);
    return 'reg-scan-${++scanSeq}';
  }

  @override
  Future<String> startTagRescan({String? directory, bool force = false}) async {
    startedTagRescans.add((directory: directory, force: force));
    return 'reg-rescan-${++scanSeq}';
  }
}

AlbumVersionTrackInfo _sampleTrack(String id, String title, int num) {
  return AlbumVersionTrackInfo(
    id: id,
    title: title,
    discNumber: 1,
    trackNumber: num,
    durationMs: 180000,
    codec: 'flac',
    sampleRateHz: 44100,
    bitDepth: 16,
    externalTrackId: 'ext-$id',
  );
}

void main() {
  group('Bug 1 regressions: 0-track filtering & stale detail cache invalidation', () {
    test('CanonicalAlbumDetail.fromJson filters out 0-track versions', () {
      final detail = CanonicalAlbumDetail.fromJson({
        'album': {
          'id': 'alb-1',
          'title': 'Test Album',
          'artist_name': 'Test Artist',
          'release_year': 2024,
        },
        'versions': [
          {
            'version': {
              'id': 'ver-empty',
              'provider': 'local',
              'external_album_id': 'loc-empty',
              'edition_label': 'Empty Orphan Edition',
            },
            'tracks': [],
          },
          {
            'version': {
              'id': 'ver-valid',
              'provider': 'local',
              'external_album_id': 'loc-valid',
              'edition_label': 'Valid Edition',
            },
            'tracks': [
              {
                'id': 'trk-1',
                'title': 'Track 1',
                'disc_number': 1,
                'track_number': 1,
                'duration_ms': 120000,
                'external_track_id': 'C:/music/01.flac',
              },
            ],
          },
        ],
      });

      expect(detail.versions.length, 1);
      expect(detail.versions.single.id, 'ver-valid');
    });

    test('CanonicalAlbumSummary.fromJson parses optional track_count', () {
      final withCount = CanonicalAlbumSummary.fromJson({
        'id': 'alb-c',
        'title': 'Counted',
        'artist_name': 'Artist',
        'track_count': 5,
      });
      final withoutCount = CanonicalAlbumSummary.fromJson({
        'id': 'alb-n',
        'title': 'Legacy',
        'artist_name': 'Artist',
      });

      expect(withCount.trackCount, 5);
      expect(withoutCount.trackCount, isNull);
    });

    test(
      'LibraryIndexCache clears _albumDetailsById on refresh, skips trackCount == 0, and filters empty versions',
      () async {
        final service = _RegressionAudioService();
        addTearDown(service.dispose);
        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);

        const emptyVer = AlbumVersionInfo(
          id: 'ver-empty',
          provider: 'local',
          externalAlbumId: 'ext-e',
          editionLabel: 'Empty',
          codec: 'flac',
          sampleRateHz: 44100,
          bitDepth: 16,
          tracks: [],
        );
        final validVer = AlbumVersionInfo(
          id: 'ver-ok',
          provider: 'local',
          externalAlbumId: 'ext-ok',
          editionLabel: 'Valid',
          codec: 'flac',
          sampleRateHz: 44100,
          bitDepth: 16,
          tracks: [_sampleTrack('trk-1', 'Song A', 1)],
        );

        final detailWithMixedVersions = CanonicalAlbumDetail(
          id: 'alb-1',
          title: 'Album One',
          artistName: 'Artist One',
          versions: [emptyVer, validVer],
        );

        cache.putAlbumDetailSync(detailWithMixedVersions);
        expect(cache.getAlbumDetailSync('alb-1')?.versions.length, 1);
        expect(cache.getAlbumDetailSync('alb-1')?.versions.single.id, 'ver-ok');

        service.customDetails['alb-2'] = CanonicalAlbumDetail(
          id: 'alb-2',
          title: 'Album Two',
          artistName: 'Artist Two',
          versions: [emptyVer, validVer],
        );
        final loaded = await cache.loadAlbumDetail(service, 'alb-2');
        expect(loaded?.versions.length, 1);
        expect(loaded?.versions.single.id, 'ver-ok');

        // Refresh should clear cached details and skip trackCount == 0 albums.
        service.customAlbums = const [
          CanonicalAlbumSummary(
            id: 'alb-zero',
            title: 'Zero Tracks',
            artist: 'Ghost',
            trackCount: 0,
          ),
          CanonicalAlbumSummary(
            id: 'alb-2',
            title: 'Album Two',
            artist: 'Artist Two',
            trackCount: 1,
          ),
        ];
        await cache.refresh(service);

        expect(cache.albumDetailsById, isEmpty);
        expect(cache.albums.map((a) => a.id), ['alb-2']);
      },
    );

    testWidgets(
      'AlbumDetailPage skips empty versions and renders two local versions without duplicate widget keys',
      (tester) async {
        final service = _RegressionAudioService();
        addTearDown(service.dispose);

        service.customDetails['alb-multi-local'] = CanonicalAlbumDetail(
          id: 'alb-multi-local',
          title: 'Multi Local Edition',
          artistName: 'Studio Artist',
          versions: [
            const AlbumVersionInfo(
              id: 'ver-empty',
              provider: 'local',
              externalAlbumId: 'loc-0',
              editionLabel: 'Empty Orphan',
              codec: 'flac',
              sampleRateHz: 44100,
              bitDepth: 16,
              tracks: [],
            ),
            AlbumVersionInfo(
              id: 'ver-loc-1',
              provider: 'local',
              externalAlbumId: 'loc-1',
              editionLabel: '24-bit Vinyl Rip',
              codec: 'flac',
              sampleRateHz: 96000,
              bitDepth: 24,
              tracks: [_sampleTrack('t-1', 'Opening', 1)],
            ),
            AlbumVersionInfo(
              id: 'ver-loc-2',
              provider: 'local',
              externalAlbumId: 'loc-2',
              editionLabel: 'CD Standard',
              codec: 'flac',
              sampleRateHz: 44100,
              bitDepth: 16,
              tracks: [_sampleTrack('t-2', 'Opening (CD)', 1)],
            ),
          ],
        );

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-multi-local',
                audioService: service,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Empty Orphan'), findsNothing);
        expect(find.byKey(const Key('version_chip_local')), findsOneWidget);
        expect(
          find.byKey(const Key('version_chip_local_ver-loc-2')),
          findsOneWidget,
        );
        expect(find.text('目前採用版本：24-bit Vinyl Rip'), findsOneWidget);

        await tester.tap(find.byKey(const Key('version_chip_local_ver-loc-2')));
        await tester.pumpAndSettle();
        expect(find.text('目前採用版本：CD Standard'), findsOneWidget);
      },
    );

    testWidgets(
      'AlbumsAndCreditsView filters out trackCount == 0 albums',
      (tester) async {
        final service = _RegressionAudioService()
          ..customAlbums = const [
            CanonicalAlbumSummary(
              id: 'alb-zero',
              title: 'Empty Album',
              artist: 'Artist A',
              trackCount: 0,
            ),
            CanonicalAlbumSummary(
              id: 'alb-valid',
              title: 'Real Album',
              artist: 'Artist B',
              trackCount: 8,
            ),
          ];
        addTearDown(service.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumsAndCreditsView(audioService: service),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('album_card_alb-zero')), findsNothing);
        expect(find.byKey(const Key('album_card_alb-valid')), findsOneWidget);
      },
    );
  });

  group('Bug 2 regressions: non-blocking scan & scoped progress notifier', () {
    testWidgets(
      'LibrarySettingsPanel scans sequentially via startDirectoryScan, triggers startTagRescan, throttles progress, and refreshes once per scanId',
      (tester) async {
        final service = _RegressionAudioService();
        addTearDown(service.dispose);
        final settings = LibrarySettingsController()
          ..addOrUpdateFolder(r'D:\Music\A', 1)
          ..addOrUpdateFolder(r'D:\Music\B', 2);
        var libraryChangedCalls = 0;

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibrarySettingsPanel(
                audioService: service,
                settingsController: settings,
                onLibraryChanged: () => libraryChangedCalls++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Trigger rescan all folders -> first folder starts immediately, second waits for first scanId completion.
        await tester.tap(find.byKey(const Key('btn_rescan_all_folders')));
        await tester.pump();
        expect(service.startedScanPaths, [r'D:\Music\A']);

        // Emit rapid probing progress events within 200ms window: first renders immediately, middle throttled, last after 200ms.
        service.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'reg-scan-1',
            rootPath: r'D:\Music\A',
            state: ScanLifecycleState.probing,
            scanned: 1,
            totalEstimated: 10,
          ),
        );
        await tester.pump();
        expect(
          find.byKey(const Key('ingestion_scan_progress_card')),
          findsOneWidget,
        );
        expect(find.text('1 / 10'), findsOneWidget);

        service.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'reg-scan-1',
            rootPath: r'D:\Music\A',
            state: ScanLifecycleState.probing,
            scanned: 5,
            totalEstimated: 10,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        // Still throttled at 1 / 10 before 200ms elapses.
        expect(find.text('1 / 10'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 180));
        expect(find.text('5 / 10'), findsOneWidget);

        // Duplicate completed event with same scanId triggers onLibraryChanged only once, and starts folder B.
        const completedA = ScanProgressEvent(
          scanId: 'reg-scan-1',
          rootPath: r'D:\Music\A',
          state: ScanLifecycleState.completed,
          scanned: 10,
          added: 10,
          totalEstimated: 10,
        );
        service.emitScanProgress(completedA);
        service.emitScanProgress(completedA);
        await tester.pump();
        await tester.pump();

        expect(libraryChangedCalls, 1);
        expect(service.startedScanPaths, [r'D:\Music\A', r'D:\Music\B']);

        service.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'reg-scan-2',
            rootPath: r'D:\Music\B',
            state: ScanLifecycleState.completed,
            scanned: 4,
            added: 4,
            totalEstimated: 4,
          ),
        );
        await tester.pumpAndSettle();

        expect(libraryChangedCalls, 2);
        expect(find.byKey(const Key('scan_status_label')), findsOneWidget);

        // 2. Trigger non-blocking tag rescan button.
        await tester.ensureVisible(find.byKey(const Key('btn_rescan_tags')));
        await tester.tap(find.byKey(const Key('btn_rescan_tags')));
        await tester.pump();
        expect(service.startedTagRescans.length, 1);
        expect(service.startedTagRescans.single.force, isTrue);

        service.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'reg-rescan-3',
            rootPath: '',
            state: ScanLifecycleState.completed,
            scanned: 14,
            updated: 14,
            totalEstimated: 14,
          ),
        );
        await tester.pumpAndSettle();
        expect(libraryChangedCalls, 3);
      },
    );
  });
}
