import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/audio_service.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/listen_later_playback_tracker.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/autoplay_controller.dart';
import 'package:lumina_app/services/streaming/autoplay_filter.dart';
import 'package:lumina_app/services/streaming/external_recommendations/local_library_track_matcher.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';

TrackInfo _trk(
  String id, {
  String title = 'Track',
  String artist = 'Artist',
  String album = 'Album',
  Duration duration = const Duration(seconds: 200),
  int preference = 0,
  String? albumGroupId,
  String? externalAlbumId,
  String providerName = 'Local Library',
  String? filePath,
  AudioFormat format = const AudioFormat(
    codec: AudioCodec.flac,
    sampleRateHz: 96000,
    bitDepth: 24,
    channels: 2,
  ),
}) => TrackInfo(
  id: id,
  title: title,
  artist: artist,
  album: album,
  duration: duration,
  format: format,
  providerName: providerName,
  filePath: filePath ?? '/music/$id.flac',
  preference: preference,
  albumGroupId: albumGroupId,
  externalAlbumId: externalAlbumId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Step 4 Models & Serialization', () {
    test('FocusFacet.preference wire name and bucket labels', () {
      expect(FocusFacet.preference.wireName, 'preference');
      expect(FocusFacet.fromJson('preference'), FocusFacet.preference);
      expect(FocusFacetBucket.preferenceBucketLabel('favorite'), '喜愛');
      expect(FocusFacetBucket.preferenceBucketLabel('neutral'), '普通');
      expect(FocusFacetBucket.preferenceBucketLabel('banned'), '已封鎖');
      expect(FocusFacetBucket.preferenceIntForBucket('favorite'), 1);
      expect(FocusFacetBucket.preferenceIntForBucket('neutral'), 0);
      expect(FocusFacetBucket.preferenceIntForBucket('banned'), -1);
    });

    test('TrackInfo preserves preference, albumGroupId, externalAlbumId', () {
      final t = _trk('t1', preference: -1, albumGroupId: 'grp-1', externalAlbumId: 'ext-9');
      final rt = TrackInfo.fromJson(t.toJson());
      expect(rt.preference, -1);
      expect(rt.albumGroupId, 'grp-1');
      expect(rt.externalAlbumId, 'ext-9');
      expect(TrackInfo.fromJson(const {'id': 't2', 'title': 'S'}).preference, 0);
    });

    test('Step4 models parse snake_case JSON accurately', () {
      final bm = BookmarkItem.fromJson(const {
        'id': 'bm-1',
        'name': 'Hi-Res Jazz',
        'target_route': 'tracks',
        'focus_query_json': '{"entity":"tracks","predicates":[]}',
        'view_state_json': '{"sort":"title"}',
        'sort_order': 2,
      });
      expect(bm.parseFocusQuery()?.entity, FocusEntity.tracks);
      expect(bm.parseViewState()?['sort'], 'title');

      final sp = SmartPlaylistItem.fromJson(const {
        'id': 'sp-1',
        'name': 'Favorites',
        'focus_query_json':
            '{"entity":"tracks","predicates":[{"facet":"preference","value":{"kind":"string","value":"favorite"},"mode":"include"}]}',
        'exclude_banned': 1,
        'limit_count': 50,
        'is_pinned': 1,
      });
      expect(sp.excludeBanned, isTrue);
      expect(sp.limitCount, 50);
      expect(sp.parseFocusQuery()?.predicates.single.facet, FocusFacet.preference);

      final ll = ListenLaterItem.fromJson(const {
        'id': 'll-1',
        'source_kind': 'external',
        'entity_type': 'album',
        'provider_id': 'qobuz',
        'external_id': 'qb-99',
        'title': 'Kind of Blue',
        'artist_name': 'Miles Davis',
        'track_count': 5,
        'status': 'pending',
      });
      expect(ll.isExternal && ll.isAlbum && ll.isPending, isTrue);
      expect(ll.trackCount, 5);
    });
  });

  group('Unified Queue API & Banned Filtering', () {
    test('filterQueueTracksForPlayback excludes banned unless explicitly selected', () {
      final t1 = _trk('t1', preference: -1);
      final t2 = _trk('t2');
      final t3 = _trk('t3', preference: -1);
      final t4 = _trk('t4', preference: 1);

      final filtered = filterQueueTracksForPlayback([t1, t2, t3, t4]);
      expect(filtered.tracks.map((t) => t.id).toList(), ['t2', 't4']);
      expect(filtered.startIndex, 0);

      final explicit = filterQueueTracksForPlayback([t1, t2, t3], explicitTrack: t1);
      expect(explicit.tracks.map((t) => t.id).toList(), ['t1', 't2']);
      expect(explicit.startIndex, 0);
    });

    test('MockAudioService playQueue, explicit play, next, enqueueTracks', () async {
      final mock = MockAudioService();
      addTearDown(mock.dispose);

      final b1 = _trk('b1', preference: -1);
      final n1 = _trk('n1');
      final b2 = _trk('b2', preference: -1);
      final f1 = _trk('f1', preference: 1);

      await mock.playQueue([b1, n1, b2, f1]);
      expect(mock.queue.map((t) => t.id).toList(), ['n1', 'f1']);
      expect(mock.currentState.track?.id, 'n1');

      // All-banned collection returns cleanly without throwing.
      await mock.playQueue([b1, b2]);
      expect(mock.currentState.track?.id, 'n1');

      // Direct click on banned track MUST still play!
      await mock.play(track: b1);
      expect(mock.currentState.track?.id, 'b1');
      expect(mock.currentState.status, PlaybackStatus.playing);

      // Explicit track in album keeps clicked banned track, drops other banned tracks.
      await mock.playQueue([b1, n1, b2, f1], explicitTrack: b1);
      expect(mock.queue.map((t) => t.id).toList(), ['b1', 'n1', 'f1']);
      expect(mock.currentState.track?.id, 'b1');

      await mock.next();
      expect(mock.currentState.track?.id, 'n1');

      final added = await mock.enqueueTracks([b2, _trk('n2')]);
      expect(added, 1);
      expect(mock.queue.any((t) => t.id == 'b2'), isFalse);
      expect(mock.queue.any((t) => t.id == 'n2'), isTrue);
    });

    test('CoordinatingAudioService + AutoplayController skip banned tracks & seeds', () async {
      final mock = MockAudioService();
      final sm = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
        enableLiveWarmup: false,
      );
      final ap = AutoplayController(
        providerLookup: (_) => null,
        allowBackgroundRefill: false,
      );
      final coord = StreamingPlaybackCoordinator(
        audioService: mock,
        streamingManager: sm,
        autoplayController: ap,
        debounceDelay: Duration.zero,
      );
      final svc = CoordinatingAudioService(
        inner: mock,
        coordinator: coord,
        disposeInner: false,
      );
      addTearDown(() {
        svc.dispose();
        coord.dispose();
        ap.dispose();
        sm.dispose();
        mock.dispose();
      });

      final banned = _trk('trk-b', preference: -1);
      final ok1 = _trk('trk-1');
      final ok2 = _trk('trk-2', preference: 1);

      await svc.playQueue([banned, ok1, ok2]);
      expect(ap.userQueue.map((t) => t.id).toList(), ['trk-1', 'trk-2']);
      expect(svc.currentState.track?.id, 'trk-1');

      expect(await svc.enqueueTracks([banned, _trk('trk-3')]), 1);
      expect(ap.userQueue.map((t) => t.id).toList(), ['trk-1', 'trk-2', 'trk-3']);

      await svc.setEntityPreference('track', 'trk-2', -1);
      expect(ap.peekNextTrack()?.id, 'trk-3');

      await svc.playQueue([banned], explicitTrack: banned);
      ap.onPlaybackProgress(banned, const Duration(seconds: 150));
      expect(ap.filter.seedPool.isEmpty, isTrue);
    });

    test('AutoplayFilter & LocalLibraryTrackMatcher reject banned tracks/artists', () async {
      final filter = AutoplayFilter();
      const bannedT = TrackMetadata(providerId: 'local', trackId: 'tb', title: 'No', artist: 'Good');
      const bannedA = TrackMetadata(providerId: 'local', trackId: 'ta', title: 'Any', artist: 'BadGuy');
      const okT = TrackMetadata(providerId: 'local', trackId: 'tok', title: 'Yes', artist: 'Good');
      const seed = TrackMetadata(providerId: 'local', trackId: 's', title: 'Seed', artist: 'S');

      filter.setBannedTrack(bannedT, true);
      filter.setBannedArtist('BadGuy', true);
      final filtered = filter.filterCandidates(
        candidates: const [bannedT, bannedA, okT],
        seed: seed,
        activeQueueTail: const [],
        now: DateTime(2026, 1, 1),
      );
      expect(filtered.map((t) => t.trackId).toList(), ['tok']);

      final matcher = LocalLibraryTrackMatcher(
        searchLibrary: (_) async => [
          _trk('loc-b', title: 'Time', artist: 'Pink Floyd', preference: -1),
          _trk('loc-ok', title: 'Time', artist: 'Pink Floyd', preference: 0),
        ],
      );
      final hit = await matcher.matchTrack(
        const TrackMatchQuery(title: 'Time', artist: 'Pink Floyd'),
      );
      expect(hit?.trackId, 'loc-ok');
    });
  });

  group('MockAudioService Step 4 CRUD, Smart Playlists & Listen Later', () {
    test('Smart playlists seed, exclude banned, and honor explicit banned filter', () async {
      final mock = MockAudioService();
      addTearDown(mock.dispose);

      final pls = await mock.listSmartPlaylists();
      expect(pls.map((p) => p.id).toList(), ['sp-hires', 'sp-lossless', 'sp-dsd', 'sp-all']);

      final before = (await mock.evaluateSmartPlaylist('sp-all'))!;
      final firstId = before.tracks.first.id;
      await mock.setEntityPreference('track', firstId, -1);

      final after = (await mock.evaluateSmartPlaylist('sp-all'))!;
      expect(after.tracks.any((t) => t.id == firstId), isFalse);
      expect(after.tracks.length, before.tracks.length - 1);

      final bannedPl = (await mock.createSmartPlaylist(
        name: 'Banned Review',
        focusQueryJson: jsonEncode({
          'entity': 'tracks',
          'predicates': [
            {
              'facet': 'preference',
              'value': {'kind': 'string', 'value': 'banned'},
              'mode': 'include',
            },
          ],
        }),
        excludeBanned: true,
        limitCount: 10,
      ))!;
      final bannedEval = (await mock.evaluateSmartPlaylist(bannedPl.id))!;
      expect(bannedEval.tracks.map((t) => t.id).toList(), [firstId]);
    });

    test('Bookmarks reorder & Listen Later external isolation + promote', () async {
      final mock = MockAudioService();
      addTearDown(mock.dispose);

      final b1 = (await mock.createBookmark(name: 'A', targetRoute: 'albums'))!;
      final b2 = (await mock.createBookmark(name: 'B', targetRoute: 'tracks'))!;
      await mock.reorderBookmarks([b2.id, b1.id]);
      expect((await mock.listBookmarks()).map((b) => b.id).toList(), [b2.id, b1.id]);

      final albumsBefore = (await mock.getAlbums()).length;
      final tracksBefore = mock.queue.length;

      final ext = (await mock.addToListenLater(
        sourceKind: 'external',
        entityType: 'album',
        providerId: 'qobuz',
        externalId: 'qb-42',
        title: 'A Love Supreme',
        artistName: 'John Coltrane',
        trackCount: 4,
      ))!;
      expect((await mock.getAlbums()).length, albumsBefore);
      expect(mock.queue.length, tracksBefore);

      final res = (await mock.promoteExternalToLibrary(
        ext.id,
        ingestBatch: const ExternalCatalogIngestBatch(
          provider: 'qobuz',
          albums: [
            ExternalAlbumIngest(
              externalAlbumId: 'qb-42',
              title: 'A Love Supreme',
              artistName: 'John Coltrane',
              tracks: [
                ExternalTrackIngest(
                  externalTrackId: 'qb-t1',
                  title: 'Acknowledgement',
                  artistName: 'John Coltrane',
                  durationMs: 462000,
                ),
              ],
            ),
          ],
        ),
      ))!;
      expect(res.item.isListened, isTrue);
      expect(res.promotedEntityId, isNotEmpty);
      expect((await mock.getAlbums()).length, albumsBefore + 1);
    });
  });

  group('ListenLaterPlaybackTracker', () {
    test('marks pending track listened strictly >70% and honors Settings toggle', () async {
      final mock = MockAudioService();
      final settings = LibrarySettingsController();
      final marked = <ListenLaterItem>[];
      final tracker = ListenLaterPlaybackTracker(
        audioService: mock,
        settings: settings,
        onAutoMarkedListened: marked.add,
      );
      addTearDown(() {
        tracker.dispose();
        settings.dispose();
        mock.dispose();
      });

      expect(settings.autoMarkListenLaterListened, isTrue);
      final t1 = _trk('ll-t1', duration: const Duration(seconds: 100));
      final item = (await mock.addToListenLater(
        sourceKind: 'library',
        entityType: 'track',
        entityId: t1.id,
        title: t1.title,
      ))!;

      await mock.play(track: t1);
      await mock.seek(const Duration(seconds: 70));
      await tracker.flushPendingChecks();
      expect((await mock.listListenLater(status: 'pending')).length, 1);

      await mock.seek(const Duration(seconds: 71));
      await tracker.flushPendingChecks();
      expect(await mock.listListenLater(status: 'pending'), isEmpty);
      expect(marked.single.id, item.id);

      settings.setAutoMarkListenLaterListened(false);
      final t2 = _trk('ll-t2', duration: const Duration(seconds: 100));
      await mock.addToListenLater(
        sourceKind: 'library',
        entityType: 'track',
        entityId: t2.id,
        title: t2.title,
      );
      await mock.play(track: t2);
      await mock.seek(const Duration(seconds: 95));
      await tracker.flushPendingChecks();
      expect((await mock.listListenLater(status: 'pending')).length, 1);
    });

    test('marks pending album listened when >50% distinct tracks cross 70%', () async {
      final mock = MockAudioService();
      final settings = LibrarySettingsController();
      final marked = <ListenLaterItem>[];
      final tracker = ListenLaterPlaybackTracker(
        audioService: mock,
        settings: settings,
        onAutoMarkedListened: marked.add,
      );
      addTearDown(() {
        tracker.dispose();
        settings.dispose();
        mock.dispose();
      });

      final llAlb = (await mock.addToListenLater(
        sourceKind: 'library',
        entityType: 'album',
        entityId: 'alb-tri',
        title: 'Trilogy',
        artistName: 'Tester',
        trackCount: 3,
      ))!;
      final t1 = _trk('tri-1', album: 'Trilogy', artist: 'Tester', albumGroupId: 'alb-tri', duration: const Duration(seconds: 100));
      final t2 = _trk('tri-2', album: 'Trilogy', artist: 'Tester', albumGroupId: 'alb-tri', duration: const Duration(seconds: 100));

      await mock.play(track: t1);
      await mock.seek(const Duration(seconds: 80));
      await tracker.flushPendingChecks();
      expect((await mock.listListenLater(status: 'pending')).length, 1);

      // Replay same track does not double count.
      await mock.stop();
      await mock.play(track: t1);
      await mock.seek(const Duration(seconds: 85));
      await tracker.flushPendingChecks();
      expect((await mock.listListenLater(status: 'pending')).length, 1);

      // 2/3 > 50% marks album listened.
      await mock.play(track: t2);
      await mock.seek(const Duration(seconds: 75));
      await tracker.flushPendingChecks();
      expect(await mock.listListenLater(status: 'pending'), isEmpty);
      expect(marked.single.id, llAlb.id);
    });

    test('matches external streaming track and album Listen Later items', () async {
      final mock = MockAudioService();
      final settings = LibrarySettingsController();
      final tracker = ListenLaterPlaybackTracker(
        audioService: mock,
        settings: settings,
      );
      addTearDown(() {
        tracker.dispose();
        settings.dispose();
        mock.dispose();
      });

      await mock.addToListenLater(
        sourceKind: 'external',
        entityType: 'track',
        providerId: 'qobuz',
        externalId: '98765',
        title: 'So What',
        artistName: 'Miles Davis',
      );
      await mock.addToListenLater(
        sourceKind: 'external',
        entityType: 'album',
        providerId: 'qobuz',
        externalId: 'alb-kob',
        title: 'Kind of Blue',
        artistName: 'Miles Davis',
        trackCount: 2,
      );

      final ext1 = _trk(
        'qobuz:98765',
        title: 'So What',
        artist: 'Miles Davis',
        album: 'Kind of Blue',
        providerName: 'Qobuz',
        filePath: '',
        externalAlbumId: 'alb-kob',
        duration: const Duration(seconds: 100),
      );
      final ext2 = ext1.copyWith(id: 'qobuz:98766', title: 'Freddie Freeloader');

      await mock.play(track: ext1);
      await mock.seek(const Duration(seconds: 80));
      await tracker.flushPendingChecks();
      final after1 = await mock.listListenLater(status: 'pending');
      expect(after1.length, 1);
      expect(after1.single.isAlbum, isTrue);

      await mock.play(track: ext2);
      await mock.seek(const Duration(seconds: 80));
      await tracker.flushPendingChecks();
      expect(await mock.listListenLater(status: 'pending'), isEmpty);
    });
  });
}
