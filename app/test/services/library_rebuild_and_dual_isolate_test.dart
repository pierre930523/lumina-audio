import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/server_audio_service.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/library/library_browser_view.dart';
import 'package:lumina_app/ui/settings/library_settings_panel.dart';

class _MemCredStore implements SecureCredentialStore {
  final Map<String, String> _m = <String, String>{};
  @override
  Future<void> clearAll() async => _m.clear();
  @override
  Future<void> delete(String key) async => _m.remove(key);
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String plaintext) async => _m[key] = plaintext;
}

class _SpyLibraryAudioService extends MockAudioService {
  List<CanonicalAlbumSummary> albums = const [];
  final Map<String, CanonicalAlbumDetail> details = {};
  final List<String> searchQueries = [];
  int rebuildCalls = 0;
  String nextRebuildScanId = 'rebuild-scan-1';

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async => albums;

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async =>
      details[albumId];

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    searchQueries.add(query);
    return super.searchLibrary(query);
  }

  @override
  Future<Map<String, dynamic>> forceRebuildLibrary({String? directory}) async {
    rebuildCalls++;
    return <String, dynamic>{'scan_id': nextRebuildScanId};
  }
}

AlbumVersionTrackInfo _track(String id, String title) => AlbumVersionTrackInfo(
  id: id,
  title: title,
  discNumber: 1,
  trackNumber: 1,
  durationMs: 180000,
  codec: 'flac',
  sampleRateHz: 96000,
  bitDepth: 24,
  externalTrackId: 'C:/Music/$id.flac',
);

void main() {
  group('Dual-isolate FFI worker routing', () {
    test('separates read/artwork ops from write/scan/rebuild ops with zero overlap', () {
      expect(
        FfiWorkerRouter.readOps.intersection(FfiWorkerRouter.writeOps),
        isEmpty,
      );

      for (final readOp in const [
        'get_tracks',
        'get_albums',
        'get_album_detail',
        'get_artist_detail',
        'search',
        'artwork_get',
        'watch_list',
        'skipped_files',
        'get_metadata_overrides',
        'get_lyrics',
        'list_profiles',
      ]) {
        expect(
          FfiWorkerRouter.laneForOp(readOp),
          FfiWorkerLane.read,
          reason: '$readOp must run on Read/Artwork isolate',
        );
      }

      for (final writeOp in const [
        'library_init',
        'scan_dir',
        'scan_start',
        'rescan_start',
        'force_rebuild_start',
        'rescan_tags',
        'deduplicate',
        'enrich_credits',
        'provider_sync',
        'watch_add',
        'watch_remove',
        'dismiss_skipped_file',
        'set_metadata_override',
        'clear_metadata_override',
        'set_user_cover',
        'clear_user_cover',
        'set_user_lyrics',
        'clear_user_lyrics',
      ]) {
        expect(
          FfiWorkerRouter.laneForOp(writeOp),
          FfiWorkerLane.write,
          reason: '$writeOp must run on Write/Scan isolate',
        );
      }
    });
  });

  group('Defensive track_count > 0 filtering in LibraryIndexCache', () {
    test('putAlbumDetailSync and loadAlbumDetail never cache 0-track albums or null trackCount bypasses', () async {
      final service = _SpyLibraryAudioService();
      addTearDown(service.dispose);
      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);

      const emptyVersion = AlbumVersionInfo(
        id: 'ver-empty',
        provider: 'local',
        externalAlbumId: 'loc-0',
        editionLabel: 'Empty',
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
        tracks: [],
      );

      // 1. Empty detail must NOT synthesize a summary with trackCount: null.
      cache.putAlbumDetailSync(
        const CanonicalAlbumDetail(
          id: 'alb-ghost',
          title: 'Ghost Album',
          artistName: 'Nobody',
          versions: [emptyVersion],
        ),
      );
      expect(cache.getAlbumDetailSync('alb-ghost'), isNull);
      expect(cache.getAlbumSummarySync('alb-ghost'), isNull);

      // 2. Valid detail populates summary with explicit trackCount > 0.
      cache.putAlbumDetailSync(
        CanonicalAlbumDetail(
          id: 'alb-real',
          title: 'Real Album',
          artistName: 'Real Artist',
          versions: [
            emptyVersion,
            AlbumVersionInfo(
              id: 'ver-real',
              provider: 'local',
              externalAlbumId: 'loc-1',
              editionLabel: '24-bit Master',
              codec: 'flac',
              sampleRateHz: 96000,
              bitDepth: 24,
              tracks: [_track('t1', 'Opening'), _track('t2', 'Finale')],
            ),
          ],
        ),
      );
      expect(cache.getAlbumDetailSync('alb-real')?.versions.length, 1);
      expect(cache.getAlbumSummarySync('alb-real')?.trackCount, 2);

      // 3. Re-putting an empty detail for an existing album evicts it cleanly.
      cache.putAlbumDetailSync(
        const CanonicalAlbumDetail(
          id: 'alb-real',
          title: 'Real Album',
          artistName: 'Real Artist',
          versions: [],
        ),
      );
      expect(cache.getAlbumDetailSync('alb-real'), isNull);
      expect(cache.getAlbumSummarySync('alb-real'), isNull);

      // 4. loadAlbumDetail returns null and evicts when all versions are empty.
      service.details['alb-empty-remote'] = const CanonicalAlbumDetail(
        id: 'alb-empty-remote',
        title: 'Empty Remote',
        artistName: 'Ghost',
        versions: [emptyVersion],
      );
      final loaded = await cache.loadAlbumDetail(service, 'alb-empty-remote');
      expect(loaded, isNull);
      expect(cache.getAlbumSummarySync('alb-empty-remote'), isNull);

      // 5. putAlbumSummarySync rejects trackCount <= 0.
      cache.putAlbumSummarySync(
        const CanonicalAlbumSummary(
          id: 'alb-zero',
          title: 'Zero',
          artist: 'Ghost',
          trackCount: 0,
        ),
      );
      expect(cache.getAlbumSummarySync('alb-zero'), isNull);
    });
  });

  group('Force Rebuild Library HTTP, Mock & Coordinator contracts', () {
    test('ServerAudioService posts to /api/v1/library/rebuild/start and returns scan_id', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      String? capturedPath;
      String? capturedMethod;
      Map<String, dynamic>? capturedBody;

      server.listen((req) async {
        capturedPath = req.uri.path;
        capturedMethod = req.method;
        final raw = await utf8.decoder.bind(req).join();
        if (raw.isNotEmpty) {
          capturedBody = jsonDecode(raw) as Map<String, dynamic>;
        }
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'scan_id': 'srv-rebuild-42'}));
        await req.response.close();
      });

      final client = ServerAudioService(
        baseUrl: 'http://127.0.0.1:${server.port}',
        wsAutoReconnect: false,
      );
      addTearDown(client.dispose);

      final res = await client.forceRebuildLibrary();
      expect(capturedMethod, 'POST');
      expect(capturedPath, '/api/v1/library/rebuild/start');
      expect(capturedBody?['force'], isTrue);
      expect(res['scan_id'], 'srv-rebuild-42');
    });

    test('CoordinatingAudioService forwards forceRebuildLibrary to inner AudioService', () async {
      final mock = MockAudioService();
      final manager = StreamingManager(
        credentialStore: _MemCredStore(),
        enableLiveWarmup: false,
      );
      final coordinator = StreamingPlaybackCoordinator(
        audioService: mock,
        streamingManager: manager,
      );
      final facade = CoordinatingAudioService(
        inner: mock,
        coordinator: coordinator,
      );
      addTearDown(() async {
        facade.dispose();
        coordinator.dispose();
        await manager.disposeAsync();
        mock.dispose();
      });

      final events = <ScanProgressEvent>[];
      final sub = facade.scanProgressStream.listen(events.add);
      addTearDown(sub.cancel);

      final res = await facade.forceRebuildLibrary();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(res['scan_id'], isA<String>());
      expect((res['scan_id'] as String).isNotEmpty, isTrue);
      expect(events.any((e) => e.state == ScanLifecycleState.completed), isTrue);
    });
  });

  group('LibrarySettingsPanel Force Rebuild UI & Windows path normalization', () {
    test('normalizeFolderPathKey matches Windows backslash vs Rust forward-slash paths', () {
      expect(
        LibrarySettingsPanel.normalizeFolderPathKey(r'C:\Users\Audio\HiRes\'),
        LibrarySettingsPanel.normalizeFolderPathKey('c:/users/audio/hires'),
      );
      expect(
        LibrarySettingsPanel.normalizeFolderPathKey(r'\\NAS\Lossless\'),
        LibrarySettingsPanel.normalizeFolderPathKey('//nas/lossless'),
      );
    });

    testWidgets(
      'matches Windows watched root badges and triggers Force Rebuild Library after confirmation',
      (tester) async {
        final service = _SpyLibraryAudioService();
        addTearDown(service.dispose);
        final settings = LibrarySettingsController()
          ..addOrUpdateFolder(r'D:\Music\HiRes', 24);
        // Rust stores forward-slash normalized root_path on Windows.
        await service.addWatchedRoot(
          'D:/Music/HiRes',
          watchMode: WatchMode.manual,
        );
        var refreshCount = 0;

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibrarySettingsPanel(
                audioService: service,
                settingsController: settings,
                onLibraryChanged: () => refreshCount++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Badge matches Rust's forward-slash root_path (Manual, not inferred OS Native).
        expect(find.byKey(const Key(r'watch_badge_D:\Music\HiRes')), findsOneWidget);
        expect(find.text('Manual'), findsOneWidget);

        // Tap Force Rebuild button -> opens confirmation dialog.
        final btn = find.byKey(const Key('btn_force_rebuild_library'));
        await tester.ensureVisible(btn);
        await tester.tap(btn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('dialog_force_rebuild_library')), findsOneWidget);
        expect(find.textContaining('播放清單'), findsWidgets);

        // Cancel does not trigger rebuild.
        await tester.tap(find.byKey(const Key('btn_cancel_force_rebuild')));
        await tester.pumpAndSettle();
        expect(service.rebuildCalls, 0);

        // Confirm triggers forceRebuildLibrary and reuses progress card.
        await tester.tap(btn);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_confirm_force_rebuild')));
        await tester.pump();
        expect(service.rebuildCalls, 1);

        service.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'rebuild-scan-1',
            rootPath: 'local',
            state: ScanLifecycleState.probing,
            scanned: 12,
            totalEstimated: 24,
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('ingestion_scan_progress_card')), findsOneWidget);

        service.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'rebuild-scan-1',
            rootPath: 'local',
            state: ScanLifecycleState.completed,
            scanned: 24,
            updated: 24,
            totalEstimated: 24,
          ),
        );
        await tester.pumpAndSettle();
        expect(refreshCount, 1);
        expect(find.textContaining('已完成強制全庫重掃與修復'), findsOneWidget);
      },
    );
  });

  group('AlbumsAndCreditsView live refresh & LibraryBrowserView search debounce', () {
    testWidgets('AlbumsAndCreditsView auto-refreshes when scan completes in background', (
      tester,
    ) async {
      final service = _SpyLibraryAudioService()
        ..albums = const [
          CanonicalAlbumSummary(
            id: 'alb-1',
            title: 'Initial Album',
            artist: 'Artist 1',
            trackCount: 5,
          ),
        ];
      addTearDown(service.dispose);
      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumsAndCreditsView(
              audioService: service,
              libraryCache: cache,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('album_card_alb-1')), findsOneWidget);
      expect(find.byKey(const Key('album_card_alb-2')), findsNothing);

      // Simulate background rebuild completing with a new album and a 0-track orphan.
      service.albums = const [
        CanonicalAlbumSummary(
          id: 'alb-1',
          title: 'Initial Album',
          artist: 'Artist 1',
          trackCount: 5,
        ),
        CanonicalAlbumSummary(
          id: 'alb-2',
          title: 'Rebuilt Album',
          artist: 'Artist 2',
          trackCount: 10,
        ),
        CanonicalAlbumSummary(
          id: 'alb-empty',
          title: 'Orphan Album',
          artist: 'Ghost',
          trackCount: 0,
        ),
      ];
      service.emitScanProgress(
        const ScanProgressEvent(
          scanId: 'bg-rebuild-99',
          rootPath: 'local',
          state: ScanLifecycleState.completed,
          scanned: 15,
          added: 10,
          totalEstimated: 15,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('album_card_alb-2')), findsOneWidget);
      expect(find.byKey(const Key('album_card_alb-empty')), findsNothing);
    });

    testWidgets('LibraryBrowserView debounces rapid search input by 200ms', (
      tester,
    ) async {
      final service = _SpyLibraryAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryBrowserView(audioService: service),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final input = find.byKey(const Key('library_search_input'));
      await tester.enterText(input, 'M');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(input, 'Mo');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(input, 'Mon');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(input, 'Money');
      await tester.pump(const Duration(milliseconds: 100));

      // Still within 200ms of last keystroke -> zero queries issued yet.
      expect(service.searchQueries, isEmpty);

      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();

      // Only the final settled query was dispatched.
      expect(service.searchQueries, ['Money']);
      expect(find.byKey(const Key('queue_track_trk-001')), findsNothing);
      expect(find.byKey(const Key('queue_track_trk-002')), findsOneWidget);
    });
  });
}
