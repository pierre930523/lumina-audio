import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:material_ui/material_ui.dart';

class _TestMockAudioService extends MockAudioService {
  bool failNextExternalPromote = false;

  void addMockAlbumTrack(TrackInfo track) {
    queue.add(track);
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    final base = await super.getAlbumDetail(albumId);
    if (base == null || albumId != 'alb-dsotm' || base.versions.isEmpty) {
      return base;
    }
    final primary = base.versions.first;
    final trk1 = queue.where((t) => t.id == 'trk-001').firstOrNull;
    final trk2 = queue.where((t) => t.id == 'trk-002').firstOrNull;
    final fixedTracks = primary.tracks
        .map(
          (t) => t.id == 'trk-001'
              ? AlbumVersionTrackInfo(
                  id: t.id,
                  title: t.title,
                  discNumber: t.discNumber,
                  trackNumber: t.trackNumber,
                  durationMs: t.durationMs,
                  codec: t.codec,
                  sampleRateHz: t.sampleRateHz,
                  bitDepth: t.bitDepth,
                  externalTrackId:
                      trk1?.filePath ?? '/mock/pink_floyd/time.flac',
                  isDsd: t.isDsd,
                  preference: trk1?.preference ?? t.preference,
                )
              : t,
        )
        .toList();
    if (!fixedTracks.any((t) => t.id == 'trk-002')) {
      fixedTracks.add(
        AlbumVersionTrackInfo(
          id: 'trk-002',
          title: trk2?.title ?? 'Money',
          discNumber: 1,
          trackNumber: 2,
          durationMs: trk2?.duration.inMilliseconds ?? 232000,
          codec: trk2?.format.codec.name ?? 'dsf',
          sampleRateHz: trk2?.format.sampleRateHz ?? 2822400,
          bitDepth: trk2?.format.bitDepth ?? 1,
          externalTrackId: trk2?.filePath ?? '/mock/pink_floyd/money.dsf',
          isDsd: trk2?.format.isDsd ?? true,
          preference: trk2?.preference ?? 0,
        ),
      );
    }
    final updatedPrimary = primary.copyWith(
      provider: 'local',
      trackCount: fixedTracks.length,
      tracks: fixedTracks,
    );
    return base.copyWith(
      versions: [updatedPrimary, ...base.versions.skip(1)],
    );
  }

  @override
  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) {
    if (failNextExternalPromote) {
      throw StateError('無法從串流平台取得專輯曲目');
    }
    return super.promoteExternalToLibrary(id, ingestBatch: ingestBatch);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Album play and Smart Playlist play skip banned tracks; direct click on banned track plays it',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final svc = _TestMockAudioService();
      addTearDown(svc.dispose);

      final scaleCtrl = UiScaleController(
        initialHomeLayoutPreset: HomeLayoutPreset.classic,
      );
      addTearDown(scaleCtrl.dispose);

      // Ban the first track of alb-dsotm (trk-001) while keeping trk-002 neutral.
      await svc.setEntityPreference('track', 'trk-001', -1);

      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();

      // 1. Open Albums tab and play alb-dsotm via card hover play button.
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('album_card_alb-dsotm'));
      expect(card, findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(card));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('album_card_play_alb-dsotm')));
      await tester.pumpAndSettle();
      // Banned trk-001 was skipped; trk-002 starts playing.
      expect(svc.currentState.track?.id, 'trk-002');
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();

      // 2. Open Smart Playlists ('sp-all') and play: banned trk-001 is excluded.
      await tester.tap(find.byKey(const Key('nav_tab_smart_playlists')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('smart_playlist_item_sp-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_play_smart_playlist')));
      await tester.pumpAndSettle();
      expect(svc.currentState.track?.id, isNot('trk-001'));
      expect(svc.queue.any((t) => t.id == 'trk-001'), isFalse);

      // 3. Open AlbumDetail for alb-dsotm and click the banned track directly -> MUST play!
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('album_card_alb-dsotm')));
      await tester.pumpAndSettle();
      expect(find.text('已封鎖'), findsWidgets);
      await tester.tap(find.byKey(const Key('album_track_0')));
      await tester.pumpAndSettle();
      expect(svc.currentState.track?.id, 'trk-001');
      expect(svc.currentState.status, PlaybackStatus.playing);
    },
  );

  testWidgets(
    'Tri-state preference button cycles states & Focus preference facet filters results',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final svc = _TestMockAudioService();
      addTearDown(svc.dispose);

      await tester.pumpWidget(LuminaApp(audioService: svc));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('capsule_nav_library')));
      await tester.pumpAndSettle();

      // Cycle trk-002 from 0 -> 1 (Favorite)
      await tester.tap(find.byKey(const Key('btn_track_pref_trk-002')));
      await tester.pumpAndSettle();
      expect(
        svc.queue.firstWhere((t) => t.id == 'trk-002').preference,
        1,
      );

      // Open Focus drawer and select Favorite preference bucket.
      await tester.tap(find.byKey(const Key('btn_focus_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('focus_bucket_preference_favorite')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('queue_track_trk-002')), findsOneWidget);
      expect(find.byKey(const Key('queue_track_trk-001')), findsNothing);

      // Save Focus query as a Smart Playlist from Tracks view!
      await tester.tap(
        find.byKey(const Key('btn_save_focus_as_smart_playlist')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_smart_playlist_name')),
        '最愛無損精選',
      );
      await tester.tap(find.byKey(const Key('btn_save_smart_playlist')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('smart_playlists_view')), findsOneWidget);
      expect(find.text('最愛無損精選'), findsWidgets);
    },
  );

  testWidgets(
    'Dynamic Bookmarks save, update, restore route/Focus/view state, and re-query new items',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final svc = _TestMockAudioService();
      addTearDown(svc.dispose);

      await tester.pumpWidget(LuminaApp(audioService: svc));
      await tester.pumpAndSettle();

      // Go to Tracks view, apply Focus (96kHz+ or Favorite), and save as Bookmark.
      await tester.tap(find.byKey(const Key('capsule_nav_library')));
      await tester.pumpAndSettle();
      await svc.setEntityPreference('track', 'trk-001', 1);
      await tester.tap(find.byKey(const Key('btn_focus_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('focus_bucket_preference_favorite')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_topbar_bookmarks')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_save_current_bookmark')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_new_bookmark_name')),
        '我的喜愛曲目',
      );
      await tester.tap(find.byKey(const Key('btn_confirm_new_bookmark')));
      await tester.pumpAndSettle();
      expect(find.text('我的喜愛曲目'), findsOneWidget);

      // Update active bookmark directly from dialog
      expect(find.byKey(const Key('btn_update_current_bookmark')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_update_current_bookmark')));
      await tester.pumpAndSettle();

      // Navigate away to Home
      await tester.tap(find.byKey(const Key('capsule_nav_home')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);

      // Simulate a new favorite track added later in DB
      await svc.setEntityPreference('track', 'trk-003', 1);

      // Click bookmark -> restores Library view + Focus query dynamically showing trk-003!
      await tester.tap(find.byKey(const Key('btn_topbar_bookmarks')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的喜愛曲目'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_queue_list')), findsOneWidget);
      expect(find.byKey(const Key('queue_track_trk-001')), findsOneWidget);
      expect(find.byKey(const Key('queue_track_trk-003')), findsOneWidget);
    },
  );

  testWidgets(
    'External Listen Later item stays isolated from library until promoted, and updates badge/tabs',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final svc = _TestMockAudioService();
      addTearDown(svc.dispose);

      // Add an external streaming album to Listen Later directly (e.g. from search/streaming)
      final added = await svc.addToListenLater(
        sourceKind: 'external',
        entityType: 'album',
        providerId: 'qobuz',
        externalId: 'qb-ext-100',
        title: 'External Jazz Gem',
        artistName: 'Bill Evans',
        albumTitle: 'External Jazz Gem',
        trackCount: 1,
        metadataJson: jsonEncode({
          'tracks': [
            {
              'external_track_id': 'qb-trk-1',
              'title': 'Waltz for Debby',
              'artist_name': 'Bill Evans',
              'disc_number': 1,
              'track_number': 1,
              'duration_ms': 240000,
              'codec': 'flac',
              'sample_rate_hz': 96000,
              'bit_depth': 24,
            },
          ],
        }),
      );
      expect(added, isNotNull);

      // Verify external Listen Later item did NOT pollute main library albums
      final albumsBefore = await svc.getAlbums();
      expect(
        albumsBefore.any((a) => a.title == 'External Jazz Gem'),
        isFalse,
      );

      final scaleCtrl = UiScaleController(
        initialHomeLayoutPreset: HomeLayoutPreset.classic,
      );
      addTearDown(scaleCtrl.dispose);

      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();

      // Sidebar badge shows pending count = 1
      expect(find.byKey(const Key('sidebar_listen_later_badge')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('sidebar_listen_later_badge')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );

      // Navigate to Listen Later
      await tester.tap(find.byKey(const Key('nav_tab_listen_later')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('listen_later_view')), findsOneWidget);
      expect(find.text('External Jazz Gem'), findsOneWidget);

      // Edit note
      await tester.tap(find.byKey(Key('btn_listen_later_note_${added!.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(Key('input_listen_later_note_${added.id}')),
        '週末必聽黑膠母帶',
      );
      await tester.tap(find.byKey(const Key('btn_save_listen_later_note')));
      await tester.pumpAndSettle();
      expect(find.text('週末必聽黑膠母帶'), findsOneWidget);

      // Promote to library -> moves to Listened tab & adds to library!
      await tester.tap(find.byKey(Key('btn_listen_later_promote_${added.id}')));
      await tester.pumpAndSettle();

      final albumsAfter = await svc.getAlbums();
      expect(
        albumsAfter.any((a) => a.title == 'External Jazz Gem'),
        isTrue,
      );

      // Switch to Listened tab and verify item is there with '已收編' badge
      await tester.tap(find.byKey(const Key('listen_later_tab_listened')));
      await tester.pumpAndSettle();
      expect(find.text('External Jazz Gem'), findsOneWidget);
      expect(find.text('已收編'), findsOneWidget);
    },
  );

  testWidgets(
    'GeneralSettingsPanel renders Listen Later auto-mark toggle',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final svc = _TestMockAudioService();
      addTearDown(svc.dispose);
      final scaleCtrl = UiScaleController();
      addTearDown(scaleCtrl.dispose);

      await tester.pumpWidget(
        LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('switch_auto_mark_listen_later')),
        findsOneWidget,
      );
    },
  );
}
