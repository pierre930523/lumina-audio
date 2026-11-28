import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/library/library_browser_view.dart';
import 'package:lumina_app/ui/settings/library_settings_panel.dart';

class _MemCredStore implements SecureCredentialStore {
  final Map<String, String> _store = <String, String>{};
  @override
  Future<void> clearAll() async => _store.clear();
  @override
  Future<void> delete(String key) async => _store.remove(key);
  @override
  Future<String?> read(String key) async => _store[key];
  @override
  Future<void> write(String key, String plaintext) async =>
      _store[key] = plaintext;
}

class _MutableLibraryAudioService extends MockAudioService {
  List<CanonicalAlbumSummary> stubAlbums = const [];
  final Map<String, CanonicalAlbumDetail> stubDetails = {};
  final List<({String path, bool force})> directoryScanCalls = [];
  String artworkCachePath = '/tmp/old_cover.jpg';
  int artworkCallCount = 0;

  void replaceLocalQueue(List<TrackInfo> tracks) {
    queue
      ..clear()
      ..addAll(tracks);
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async => stubAlbums;

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async =>
      stubDetails[albumId];

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    artworkCallCount++;
    return <String, dynamic>{
      'found': true,
      'cache_path': artworkCachePath,
    };
  }

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    directoryScanCalls.add((path: path, force: force));
    return null;
  }
}

TrackInfo _localTrack({
  required String id,
  required String title,
  required String artist,
  required String album,
  String? filePath,
}) => TrackInfo(
  id: id,
  title: title,
  artist: artist,
  album: album,
  duration: const Duration(minutes: 3, seconds: 30),
  format: const AudioFormat(
    codec: AudioCodec.flac,
    sampleRateHz: 96000,
    bitDepth: 24,
    channels: 2,
  ),
  providerName: 'Local Library',
  filePath: filePath ?? 'C:/Music/$id.flac',
);

TrackInfo _streamingPodcastTrack() => const TrackInfo(
  id: 'podcast_rss:ep-99',
  title: 'Restored Podcast Episode',
  artist: 'Podcast Host',
  album: 'Daily Tech Show',
  duration: Duration(minutes: 42),
  format: AudioFormat(
    codec: AudioCodec.aac,
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
  ),
  providerName: 'Podcast',
);

CanonicalAlbumDetail _albumDetail({
  required String id,
  required String title,
  required String artist,
  required String trackTitle,
}) => CanonicalAlbumDetail(
  id: id,
  title: title,
  artistName: artist,
  releaseYear: 2024,
  versions: [
    AlbumVersionInfo(
      id: 'ver-$id',
      provider: 'local',
      externalAlbumId: 'loc-$id',
      editionLabel: 'FLAC 24-bit',
      codec: 'flac',
      sampleRateHz: 96000,
      bitDepth: 24,
      tracks: [
        AlbumVersionTrackInfo(
          id: 'trk-$id-1',
          title: trackTitle,
          discNumber: 1,
          trackNumber: 1,
          durationMs: 210000,
          codec: 'flac',
          sampleRateHz: 96000,
          bitDepth: 24,
          externalTrackId: 'C:/Music/$id/01.flac',
        ),
      ],
    ),
  ],
);

void main() {
  group('LibraryIndexCache refresh with CoordinatingAudioService & artwork invalidation', () {
    test(
      'refresh clears artworkPathCache and indexes local SQLite tracks instead of restored streaming playback queue',
      () async {
        final inner = _MutableLibraryAudioService();
        inner.replaceLocalQueue([
          _localTrack(
            id: 'loc-1',
            title: 'Old Track Tag',
            artist: 'Old Artist',
            album: 'Old Album',
          ),
        ]);
        inner.stubAlbums = const [
          CanonicalAlbumSummary(
            id: 'alb-1',
            title: 'Old Album',
            artist: 'Old Artist',
            trackCount: 1,
          ),
        ];

        final manager = StreamingManager(
          credentialStore: _MemCredStore(),
          enableLiveWarmup: false,
        );
        final autoplay = AutoplayController(providerLookup: (_) => null);
        final podcast = _streamingPodcastTrack();
        autoplay.setUserQueue([podcast], currentTrack: podcast, currentIndex: 0);

        final coordinator = StreamingPlaybackCoordinator(
          audioService: inner,
          streamingManager: manager,
          autoplayController: autoplay,
        );
        final facade = CoordinatingAudioService(
          inner: inner,
          coordinator: coordinator,
        );
        final cache = LibraryIndexCache();
        addTearDown(() async {
          cache.dispose();
          facade.dispose();
          coordinator.dispose();
          autoplay.dispose();
          await manager.disposeAsync();
          inner.dispose();
        });

        // Playback queue is the restored podcast episode, NOT the local library!
        expect(facade.queue.map((t) => t.id), ['podcast_rss:ep-99']);

        // Prime cache and populate artwork path cache with stale path.
        await cache.refresh(facade);
        final firstArtwork = await cache.resolveArtworkPath(facade, 'alb-1');
        expect(firstArtwork, '/tmp/old_cover.jpg');
        expect(cache.hasArtworkCached('alb-1'), isTrue);
        expect(cache.getArtistSync('Old Artist'), isNotNull);
        expect(cache.getArtistSync('Podcast Host'), isNull);

        // Simulate Force Rebuild updating SQLite tags and regenerating artwork on disk.
        inner.replaceLocalQueue([
          _localTrack(
            id: 'loc-1',
            title: 'Updated Track Tag',
            artist: 'Joe Hisaishi',
            album: 'Princess Mononoke',
          ),
        ]);
        inner.stubAlbums = const [
          CanonicalAlbumSummary(
            id: 'alb-1',
            title: 'Princess Mononoke',
            artist: 'Joe Hisaishi',
            trackCount: 1,
          ),
        ];
        inner.artworkCachePath = '/tmp/new_cover.jpg';
        final prevGen = cache.refreshGeneration;

        await cache.refresh(facade);

        // 1. Artwork cache was cleared and refreshGeneration incremented.
        expect(cache.refreshGeneration, greaterThan(prevGen));
        expect(cache.hasArtworkCached('alb-1'), isFalse);
        final secondArtwork = await cache.resolveArtworkPath(facade, 'alb-1');
        expect(secondArtwork, '/tmp/new_cover.jpg');
        expect(inner.artworkCallCount, 2);

        // 2. Updated local album/artist/track tags appear despite active podcast queue.
        expect(cache.getAlbumSummarySync('alb-1')?.title, 'Princess Mononoke');
        expect(cache.getArtistSync('Joe Hisaishi')?.tracks.first.title, 'Updated Track Tag');
        expect(cache.getArtistSync('Old Artist'), isNull);
        expect(cache.getArtistSync('Podcast Host'), isNull);
      },
    );
  });

  group('LibraryBrowserView refreshes from local library tracks', () {
    testWidgets(
      'displays local library tracks instead of Coordinator streaming queue and reloads on scan completion',
      (tester) async {
        final inner = _MutableLibraryAudioService();
        inner.replaceLocalQueue([
          _localTrack(
            id: 'loc-1',
            title: 'Before Rebuild Title',
            artist: 'Old Artist',
            album: 'Old Album',
          ),
        ]);
        final manager = StreamingManager(
          credentialStore: _MemCredStore(),
          enableLiveWarmup: false,
        );
        final autoplay = AutoplayController(providerLookup: (_) => null);
        final podcast = _streamingPodcastTrack();
        autoplay.setUserQueue([podcast], currentTrack: podcast, currentIndex: 0);
        final coordinator = StreamingPlaybackCoordinator(
          audioService: inner,
          streamingManager: manager,
          autoplayController: autoplay,
        );
        final facade = CoordinatingAudioService(
          inner: inner,
          coordinator: coordinator,
        );
        addTearDown(() async {
          facade.dispose();
          coordinator.dispose();
          autoplay.dispose();
          await manager.disposeAsync();
          inner.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: LibraryBrowserView(audioService: facade)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Before Rebuild Title'), findsOneWidget);
        expect(find.text('Restored Podcast Episode'), findsNothing);

        // Update inner local tracks and emit scan completion.
        inner.replaceLocalQueue([
          _localTrack(
            id: 'loc-1',
            title: 'After Rebuild Title',
            artist: 'Updated Artist',
            album: 'Updated Album',
          ),
        ]);
        inner.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'rebuild-42',
            rootPath: 'local',
            state: ScanLifecycleState.completed,
            scanned: 1,
            updated: 1,
            totalEstimated: 1,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('After Rebuild Title'), findsOneWidget);
        expect(find.text('Before Rebuild Title'), findsNothing);
      },
    );
  });

  group('AlbumDetailPage automatic reload on libraryCache refresh', () {
    testWidgets(
      'reloads updated album title, artist, and track tags when libraryCache refreshes',
      (tester) async {
        final service = _MutableLibraryAudioService();
        service.stubAlbums = const [
          CanonicalAlbumSummary(
            id: 'alb-mono',
            title: 'Stale Album Title',
            artist: 'Stale Artist',
            trackCount: 1,
          ),
        ];
        service.stubDetails['alb-mono'] = _albumDetail(
          id: 'alb-mono',
          title: 'Stale Album Title',
          artist: 'Stale Artist',
          trackTitle: 'Stale Track Name',
        );
        final cache = LibraryIndexCache();
        addTearDown(() {
          cache.dispose();
          service.dispose();
        });

        await tester.binding.setSurfaceSize(const Size(1280, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumDetailPage(
                albumId: 'alb-mono',
                audioService: service,
                libraryCache: cache,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Stale Album Title'), findsOneWidget);
        expect(find.text('Stale Artist'), findsWidgets);
        expect(find.text('Stale Track Name'), findsOneWidget);

        // Simulate Force Rebuild updating SQLite album & track metadata, then cache.refresh().
        service.stubAlbums = const [
          CanonicalAlbumSummary(
            id: 'alb-mono',
            title: 'Princess Mononoke OST',
            artist: 'Joe Hisaishi',
            trackCount: 1,
          ),
        ];
        service.stubDetails['alb-mono'] = _albumDetail(
          id: 'alb-mono',
          title: 'Princess Mononoke OST',
          artist: 'Joe Hisaishi',
          trackTitle: 'The Legend of Ashitaka',
        );

        await cache.refresh(service);
        await tester.pumpAndSettle();

        expect(find.text('Princess Mononoke OST'), findsOneWidget);
        expect(find.text('Joe Hisaishi'), findsWidgets);
        expect(find.text('The Legend of Ashitaka'), findsOneWidget);
        expect(find.text('Stale Album Title'), findsNothing);
        expect(find.text('Stale Artist'), findsNothing);
        expect(find.text('Stale Track Name'), findsNothing);
      },
    );
  });

  group('FfiAudioService _applyReloadedTracksRaw & >200 track preservation', () {
    test(
      'emits queueUpdatedStream and updates >200 libraryTracks even with restored active session',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('lumina_ffi_reload_');
        final dbPath = '${tempDir.path}${Platform.pathSeparator}reload.db';
        final ffiService = FfiAudioService(headless: true, databasePath: dbPath);
        addTearDown(() {
          ffiService.dispose();
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        });

        final restoredTrack = _streamingPodcastTrack();
        ffiService.setRestoredSessionForTest(restoredTrack);

        final emittedQueues = <List<TrackInfo>>[];
        final sub = ffiService.queueUpdatedStream.listen(emittedQueues.add);
        addTearDown(sub.cancel);

        // Build 260 tracks (> 200 old cap) to verify no truncation and stream notification.
        final rawPayload = jsonEncode(
          List.generate(
            260,
            (i) => <String, dynamic>{
              'id': 'trk-$i',
              'title': 'Updated Song $i',
              'artist': 'Artist ${i % 10}',
              'album': 'Album ${i % 5}',
              'duration_ms': 180000,
              'codec': 'flac',
              'sample_rate_hz': 96000,
              'bit_depth': 24,
              'file_path': 'C:/Music/song_$i.flac',
            },
          ),
        );

        ffiService.applyReloadedTracksRawForTest(rawPayload);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // 1. Listeners were notified even though _hasRestoredSession && _state.track != null.
        expect(emittedQueues, hasLength(1));
        expect(emittedQueues.first.length, 261); // restored active track + 260 local tracks
        // 2. Active restored track was NOT clobbered.
        expect(ffiService.currentState.track?.id, restoredTrack.id);
        // 3. Raw libraryTracks holds all 260 SQLite tracks without the streaming podcast track.
        expect(ffiService.libraryTracks.length, 260);
        expect(ffiService.libraryTracks.last.title, 'Updated Song 259');
      },
    );
  });

  group('LibrarySettingsPanel explicit rescan all folders uses force: true', () {
    testWidgets('tapping btn_rescan_all_folders passes force: true', (tester) async {
      final service = _MutableLibraryAudioService();
      addTearDown(service.dispose);
      final settings = LibrarySettingsController()
        ..addOrUpdateFolder(r'F:\CD', 655);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibrarySettingsPanel(
              audioService: service,
              settingsController: settings,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final btn = find.byKey(const Key('btn_rescan_all_folders'));
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pumpAndSettle();

      expect(service.directoryScanCalls, hasLength(1));
      expect(service.directoryScanCalls.first.path, r'F:\CD');
      expect(service.directoryScanCalls.first.force, isTrue);
    });
  });
}
