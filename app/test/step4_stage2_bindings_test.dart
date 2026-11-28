import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/server_audio_service.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';

TrackInfo _track(
  String id, {
  int preference = 0,
  String artist = 'Artist A',
  String album = 'Album A',
}) => TrackInfo(
  id: id,
  title: 'Title $id',
  artist: artist,
  album: album,
  duration: const Duration(minutes: 3),
  format: const AudioFormat(
    codec: AudioCodec.flac,
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
  ),
  preference: preference,
);

class _RecordingPromoteMock extends MockAudioService {
  ExternalCatalogIngestBatch? lastPromoteBatch;

  @override
  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) async {
    lastPromoteBatch = ingestBatch;
    return super.promoteExternalToLibrary(id, ingestBatch: ingestBatch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 2 FFI & LibraryIndexCache', () {
    test('applyReloadedTracksRawForTest parses preference & excludes banned from default queue', () {
      final ffi = FfiAudioService(headless: true);
      addTearDown(ffi.dispose);
      final raw = jsonEncode([
        {
          'id': 'trk-ok',
          'title': 'Allowed',
          'artist_name': 'Artist',
          'album': 'Album',
          'duration_ms': 180000,
          'codec': 'flac',
          'sample_rate_hz': 96000,
          'bit_depth': 24,
          'channels': 2,
          'preference': 1,
          'album_group_id': 'grp-1',
        },
        {
          'id': 'trk-ban',
          'title': 'Banned',
          'artist_name': 'Artist',
          'album': 'Album',
          'duration_ms': 180000,
          'codec': 'flac',
          'sample_rate_hz': 96000,
          'bit_depth': 24,
          'channels': 2,
          'preference': -1,
          'album_group_id': 'grp-1',
        },
      ]);

      ffi.applyReloadedTracksRawForTest(raw);
      if (ffi.isNativeBound) {
        expect(ffi.libraryTracks.length, 2);
        expect(ffi.libraryTracks.first.preference, 1);
        expect(ffi.libraryTracks.first.albumGroupId, 'grp-1');
        expect(ffi.queue.map((t) => t.id), ['trk-ok']);
      }
    });

    test('LibraryIndexCache preserves artistId & preference across rebuilds', () {
      final cache = LibraryIndexCache();
      cache.seedSync(
        albums: const [
          CanonicalAlbumSummary(
            id: 'alb-1',
            title: 'Echoes',
            artist: 'Pink Floyd',
            trackCount: 2,
            preference: 0,
          ),
        ],
        tracks: [_track('t1', artist: 'Pink Floyd', album: 'Echoes')],
      );
      cache.putArtistDetailSync(
        const ArtistDetailInfo(
          id: 'art-pf',
          name: 'Pink Floyd',
          sortName: 'Pink Floyd',
          preference: 1,
        ),
      );
      expect(cache.getArtistSync('Pink Floyd')?.artistId, 'art-pf');
      expect(cache.getArtistSync('Pink Floyd')?.preference, 1);

      cache.seedFromQueueSync([
        _track('t1', artist: 'Pink Floyd', album: 'Echoes'),
      ]);
      expect(cache.getArtistSync('Pink Floyd')?.artistId, 'art-pf');
      expect(cache.getArtistSync('Pink Floyd')?.preference, 1);

      cache.updateEntityPreferenceSync('album', 'alb-1', -1);
      expect(cache.getAlbumSummarySync('alb-1')?.preference, -1);

      cache.updateEntityPreferenceSync('artist', 'art-pf', -1);
      expect(cache.getArtistSync('Pink Floyd')?.preference, -1);
    });
  });

  group('Stage 2 ServerAudioService REST Step 4', () {
    test('wires preference, bookmarks, smart playlists, listen later & filtered playQueue', () async {
      final requests = <(String, String, dynamic)>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      server.listen((req) async {
        final bodyStr = await utf8.decoder.bind(req).join();
        final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
        requests.add((req.method, req.uri.toString(), body));

        final path = req.uri.path;
        Object? response;
        if (req.method == 'PUT' && path == '/api/v1/library/preferences') {
          response = body;
        } else if (req.method == 'POST' && path == '/api/v1/library/bookmarks') {
          response = {
            'id': 'bm-1',
            'name': body['name'],
            'target_route': body['target_route'],
            'sort_order': 0,
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00Z',
          };
        } else if (req.method == 'POST' &&
            path == '/api/v1/library/bookmarks/reorder') {
          response = [];
        } else if (req.method == 'DELETE' &&
            path == '/api/v1/library/bookmarks/bm-1') {
          response = {'deleted': true};
        } else if (req.method == 'GET' &&
            path == '/api/v1/library/smart-playlists/sp-hires/evaluate') {
          response = {
            'playlist': {
              'id': 'sp-hires',
              'name': 'Hi-Res',
              'focus_query_json': '{}',
              'exclude_banned': true,
              'is_pinned': true,
              'is_system_seed': true,
              'created_at': '2026-01-01T00:00:00Z',
              'updated_at': '2026-01-01T00:00:00Z',
            },
            'total_matched': 1,
            'tracks': [
              {
                'id': 'trk-hi',
                'title': 'HiRes Track',
                'artist': 'Artist',
                'album': 'Album',
                'duration_ms': 200000,
                'codec': 'flac',
                'sample_rate_hz': 192000,
                'bit_depth': 24,
                'channels': 2,
                'preference': 1,
                'album_group_id': 'grp-hi',
              },
            ],
          };
        } else if (req.method == 'POST' &&
            path == '/api/v1/library/listen-later/ll-1/promote') {
          response = {
            'item': {
              'id': 'll-1',
              'source_kind': 'external',
              'entity_type': 'track',
              'provider_id': 'qobuz',
              'external_id': '999',
              'title': 'Track',
              'status': 'pending',
              'added_at': '2026-01-01T00:00:00Z',
              'promoted_entity_id': 'trk-999',
            },
            'promoted_entity_id': 'trk-999',
          };
        } else if (req.method == 'POST' &&
            (path == '/api/v1/queue/load' || path == '/api/v1/queue/enqueue')) {
          response = {
            'items': [],
            'current_index': 0,
            'repeat_mode': 'off',
            'shuffle': false,
            'queue_epoch': 1,
            'timestamp_ms': 1,
          };
        } else {
          response = [];
        }

        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(response));
        await req.response.close();
      });

      final client = ServerAudioService(
        baseUrl: 'http://127.0.0.1:${server.port}',
        wsAutoReconnect: false,
      );
      addTearDown(client.dispose);

      final pref = await client.setEntityPreference('track', 't1', -1);
      expect(pref?.preference, -1);

      final bm = await client.createBookmark(name: 'Jazz', targetRoute: '/albums');
      expect(bm?.id, 'bm-1');
      expect(await client.reorderBookmarks(['bm-1']), isTrue);
      expect(await client.deleteBookmark('bm-1'), isTrue);

      final eval = await client.evaluateSmartPlaylist('sp-hires');
      expect(eval?.tracks.single.preference, 1);
      expect(eval?.tracks.single.albumGroupId, 'grp-hi');

      final promoted = await client.promoteExternalToLibrary(
        'll-1',
        ingestBatch: const ExternalCatalogIngestBatch(provider: 'qobuz'),
      );
      expect(promoted?.promotedEntityId, 'trk-999');

      await client.playQueue([
        _track('t-ban', preference: -1),
        _track('t-ok', preference: 0),
      ]);
      final loadReq = requests.firstWhere((r) => r.$2 == '/api/v1/queue/load');
      final loadItems = loadReq.$3['items'] as List;
      expect(loadItems.length, 1);
      expect(loadItems.first['track_id'], 't-ok');

      final added = await client.enqueueTracks([
        _track('t-ban2', preference: -1),
        _track('t-ok2', preference: 1),
      ]);
      expect(added, 1);
    });
  });

  group('Stage 2 CoordinatingAudioService.promoteExternalToLibrary', () {
    test('hydrates track and embedded album batches and rejects empty album without provider tracks', () async {
      final inner = _RecordingPromoteMock();
      final streamingManager = StreamingManager(enableLiveWarmup: false);
      final coordinator = StreamingPlaybackCoordinator(
        audioService: inner,
        streamingManager: streamingManager,
      );
      final facade = CoordinatingAudioService(
        inner: inner,
        coordinator: coordinator,
      );
      addTearDown(() {
        facade.dispose();
        coordinator.dispose();
        streamingManager.dispose();
        inner.dispose();
      });

      final extTrack = await facade.addToListenLater(
        sourceKind: 'external',
        entityType: 'track',
        providerId: 'qobuz',
        externalId: 'qobuz:12345',
        title: 'Blue in Green',
        artistName: 'Miles Davis',
        albumTitle: 'Kind of Blue',
        metadataJson: jsonEncode({'duration_ms': 337000, 'track_number': 3}),
      );
      final promotedTrack = await facade.promoteExternalToLibrary(extTrack!.id);
      expect(promotedTrack, isNotNull);
      expect(inner.lastPromoteBatch?.provider, 'qobuz');
      expect(
        inner.lastPromoteBatch?.albums.single.tracks.single.externalTrackId,
        '12345',
      );

      final extAlbumWithTracks = await facade.addToListenLater(
        sourceKind: 'external',
        entityType: 'album',
        providerId: 'tidal',
        externalId: 'tidal:alb-9',
        title: 'Aja',
        artistName: 'Steely Dan',
        metadataJson: jsonEncode({
          'tracks': [
            {'id': 'tidal:trk-1', 'title': 'Black Cow', 'duration_ms': 310000},
          ],
        }),
      );
      final promotedAlbum = await facade.promoteExternalToLibrary(
        extAlbumWithTracks!.id,
      );
      expect(promotedAlbum, isNotNull);
      expect(inner.lastPromoteBatch?.albums.single.externalAlbumId, 'alb-9');
      expect(
        inner.lastPromoteBatch?.albums.single.tracks.single.externalTrackId,
        'trk-1',
      );

      final extEmptyAlbum = await facade.addToListenLater(
        sourceKind: 'external',
        entityType: 'album',
        providerId: 'qobuz',
        externalId: 'alb-empty',
        title: 'Missing Tracks Album',
        artistName: 'Unknown',
      );
      await expectLater(
        facade.promoteExternalToLibrary(extEmptyAlbum!.id),
        throwsA(isA<StateError>()),
      );
    });
  });
}
