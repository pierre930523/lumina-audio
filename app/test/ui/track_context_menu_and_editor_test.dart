import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/album_layout_settings_controller.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/listen_later_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/common/track_context_menu.dart';
import 'package:lumina_app/ui/common/track_info_editor_dialog.dart';
import 'package:lumina_app/ui/library/library_track_row.dart';
import 'package:lumina_app/ui/settings/library_album_visibility_card.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';

Widget _wrapTestApp(Widget child) {
  return MaterialApp(
    theme: LuminaTokens.buildDarkTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets(
    'Single-track context menu: header quick actions, file info, show in folder, tags, ban',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = MockAudioService();
      addTearDown(audio.dispose);
      final ll = ListenLaterController(audio);
      addTearDown(ll.dispose);
      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);
      final track = audio.queue[1]; // trk-002 (not currently playing trk-001)
      int? lastPref;

      await tester.pumpWidget(
        _wrapTestApp(
          Center(
            child: LibraryTrackRow(
              track: track,
              isPlayingTrack: false,
              multiSelectMode: false,
              isSelected: false,
              audioService: audio,
              libraryCache: cache,
              onTap: () {},
              onToggleSelect: () {},
              onPlay: () {},
              onAddToQueue: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open via trailing `...` button.
      await tester.tap(find.byKey(Key('btn_track_more_${track.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('track_context_menu')), findsOneWidget);
      expect(find.byKey(const Key('btn_ctx_play_next')), findsOneWidget);
      expect(find.byKey(const Key('btn_ctx_add_to_playlist')), findsOneWidget);
      expect(find.byKey(const Key('btn_ctx_listen_later')), findsOneWidget);
      expect(find.text('新增至標籤'), findsOneWidget);
      expect(find.text('檢視檔案資訊...'), findsOneWidget);
      expect(find.text('前往資料夾'), findsOneWidget);
      expect(find.text('編輯...'), findsOneWidget);
      expect(find.text('封鎖這首曲目'), findsOneWidget);

      // 1. Tap Play Next on context menu for a fresh track -> inserts at index 1.
      final freshTrack = audio.queue[2].copyWith(
        id: 'trk-play-next-fresh',
        title: 'Fresh Play Next Track',
      );
      await tester.tap(find.byKey(const Key('btn_ctx_play_next')));
      await tester.pumpAndSettle();

      // 2. Open directly via showTrackContextMenu for freshTrack -> Play Next moves it to index 1!
      final thirdTrack = audio.queue[2];
      await tester.pumpWidget(
        _wrapTestApp(
          Builder(
            builder: (ctx) => Column(
              children: [
                ElevatedButton(
                  key: const Key('btn_open_fresh_ctx'),
                  onPressed: () => showTrackContextMenu(
                    context: ctx,
                    audioService: audio,
                    track: freshTrack,
                    anchorContext: ctx,
                    libraryCache: cache,
                    listenLaterController: ll,
                  ),
                  child: const Text('Open Fresh'),
                ),
                ElevatedButton(
                  key: const Key('btn_open_third_ctx'),
                  onPressed: () => showTrackContextMenu(
                    context: ctx,
                    audioService: audio,
                    track: thirdTrack,
                    anchorContext: ctx,
                    libraryCache: cache,
                    listenLaterController: ll,
                    onPreferenceChanged: (p) => lastPref = p,
                  ),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('btn_open_fresh_ctx')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_ctx_play_next')));
      await tester.pumpAndSettle();
      expect(audio.queue[1].id, freshTrack.id);

      // 3. Add to Playlist creates new static playlist and inserts track.
      await tester.tap(find.byKey(const Key('btn_open_third_ctx')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_ctx_add_to_playlist')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('field_new_playlist_name')),
        '深夜試音歌單',
      );
      await tester.tap(find.byKey(const Key('btn_create_playlist_and_add')));
      await tester.pumpAndSettle();
      final pls = await audio.listStaticPlaylists();
      expect(pls.any((p) => p.name == '深夜試音歌單'), isTrue);

      // 4. Add to Listen Later adds item cleanly.
      await tester.tap(find.byKey(const Key('btn_open_third_ctx')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_ctx_listen_later')));
      await tester.pumpAndSettle();
      expect(
        ll.allItems.any((it) => it.entityType == 'track' && it.entityId == thirdTrack.id),
        isTrue,
      );

      // 5. View File Info modal renders technical specs & full path.
      await tester.tap(find.byKey(const Key('btn_open_third_ctx')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_track_file_info')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_file_info_dialog')), findsOneWidget);
      expect(find.textContaining('FLAC'), findsWidgets);
      expect(find.textContaining('192 kHz'), findsOneWidget);
      expect(find.textContaining('24-bit'), findsOneWidget);
      await tester.tap(find.text('關閉'));
      await tester.pumpAndSettle();

      // 6. Show in Folder triggers revealTrackFolder.
      await tester.tap(find.byKey(const Key('btn_open_third_ctx')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_track_show_in_folder')));
      await tester.pumpAndSettle();
      expect(audio.mockRevealedTrackPaths, isNotEmpty);

      // 7. Ban This Track sets preference = -1.
      await tester.tap(find.byKey(const Key('btn_open_third_ctx')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu_track_ban')));
      await tester.pumpAndSettle();
      expect(lastPref, -1);
      expect(
        audio.queue.firstWhere((t) => t.id == thirdTrack.id).preference,
        -1,
      );
    },
  );

  testWidgets(
    'TrackInfoEditorDialog covers all 3 tabs: options, policy, user edits & restore, and 2-step trash delete',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 860));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = MockAudioService();
      addTearDown(audio.dispose);
      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);
      final track = audio.queue.first;
      var deletedCallbackFired = false;

      await tester.pumpWidget(
        _wrapTestApp(
          Builder(
            builder: (ctx) => ElevatedButton(
              key: const Key('btn_open_editor'),
              onPressed: () => showTrackInfoEditorDialog(
                context: ctx,
                audioService: audio,
                track: track,
                libraryCache: cache,
                onTrackDeleted: () => deletedCallbackFired = true,
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('btn_open_editor')));
      await tester.pumpAndSettle();

      // Tab 1: Visibility hide/unhide + rescan + reidentify + reanalyze.
      expect(find.byKey(const Key('track_info_editor_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('switch_track_editor_hidden')));
      await tester.pumpAndSettle();
      expect(audio.mockHiddenTrackIds.contains(track.id), isTrue);
      expect(
        (await audio.getLibraryTracksFiltered(includeHidden: false))
            .any((t) => t.id == track.id),
        isFalse,
      );
      expect(
        (await audio.getLibraryTracksFiltered(includeHidden: true))
            .any((t) => t.id == track.id),
        isTrue,
      );

      await tester.tap(find.byKey(const Key('btn_track_rescan')));
      await tester.pumpAndSettle();
      expect(audio.mockRescanCounts[track.id], 1);

      await tester.tap(find.byKey(const Key('btn_track_reidentify')));
      await tester.pumpAndSettle();
      expect(audio.mockReidentifyCounts[track.id], 1);

      await tester.tap(find.byKey(const Key('btn_track_reanalyze')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_waveform_preview')), findsOneWidget);
      expect(find.text('音訊檔案完整'), findsOneWidget);

      // Tab 2: Metadata policy switches cleanly.
      await tester.tap(find.byKey(const Key('tab_track_policy')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('policy_option_cloud')));
      await tester.pumpAndSettle();
      final policyInfo = await audio.getTrackFileInfo(track.id);
      expect(policyInfo?.metaPolicy, MetadataPolicy.cloud);

      // Tab 3: Edit form incl. year & lyrics writes to user_edits_json + Restore reverts.
      await tester.tap(find.byKey(const Key('tab_track_edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('field_edit_track_title')),
        'Time (Custom Edit)',
      );
      await tester.enterText(
        find.byKey(const Key('field_edit_track_year')),
        '2024',
      );
      await tester.enterText(
        find.byKey(const Key('field_edit_track_lyrics')),
        'Edited custom lyrics line',
      );
      await tester.tap(find.byKey(const Key('btn_save_track_edits')));
      await tester.pumpAndSettle();

      final editedInfo = await audio.getTrackFileInfo(track.id);
      expect(editedInfo?.hasUserEdits, isTrue);
      expect(editedInfo?.effectiveLayer.title, 'Time (Custom Edit)');
      expect(editedInfo?.effectiveLayer.releaseYear, 2024);
      expect(editedInfo?.effectiveLayer.lyrics, 'Edited custom lyrics line');
      expect(editedInfo?.fileLayer?.title, 'Time');

      await tester.tap(find.byKey(const Key('btn_restore_original_tags')));
      await tester.pumpAndSettle();
      final restoredInfo = await audio.getTrackFileInfo(track.id);
      expect(restoredInfo?.hasUserEdits, isFalse);
      expect(restoredInfo?.effectiveLayer.title, 'Time');

      // Back to Tab 1 -> Delete Track -> Move to Trash requires mandatory 2nd confirmation.
      await tester.tap(find.byKey(const Key('tab_track_options')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('btn_track_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_track_delete')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('track_delete_mode_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('btn_delete_move_to_trash')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('track_delete_trash_confirm_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('btn_confirm_trash_delete')));
      await tester.pumpAndSettle();
      expect(audio.mockDeletedTrackModes[track.id], TrackDeleteMode.moveToTrash);
      expect(deletedCallbackFired, isTrue);
    },
  );

  testWidgets(
    'AlbumDetailPage track row exposes trailing ... and right-click context menu',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = MockAudioService();
      addTearDown(audio.dispose);
      final ll = ListenLaterController(audio);
      addTearDown(ll.dispose);
      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);
      final albums = await audio.getAlbums(includeHidden: false);
      final albumId = albums.first.id;

      await tester.pumpWidget(
        _wrapTestApp(
          AlbumDetailPage(
            albumId: albumId,
            audioService: audio,
            listenLaterController: ll,
            libraryCache: cache,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trailing `...` button exists on track row 0.
      final moreBtn = find.byKey(const Key('album_track_more_0'));
      expect(moreBtn, findsOneWidget);
      await tester.tap(moreBtn);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_context_menu')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      // Secondary right-click on album track row also opens the context menu.
      final rowFinder = find.byKey(const Key('album_track_0'));
      final center = tester.getCenter(rowFinder);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.addPointer(location: center);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.down(center);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('track_context_menu')), findsOneWidget);
    },
  );

  testWidgets(
    'Settings LibraryAlbumVisibilityCard shows 顯示隱藏項目 label and updates layout controller',
    (tester) async {
      final layout = AlbumLayoutSettingsController();
      addTearDown(layout.dispose);

      await tester.pumpWidget(
        _wrapTestApp(
          LibraryAlbumVisibilityCard(
            albumLayoutController: layout,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('顯示隱藏項目'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('switch_settings_show_hidden_albums')),
      );
      await tester.pumpAndSettle();
      expect(layout.showHiddenItems, isTrue);
      expect(layout.showHiddenAlbums, isTrue);
    },
  );
}
