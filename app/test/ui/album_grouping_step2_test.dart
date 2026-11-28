import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/album_layout_settings_controller.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/albums/albums_and_credits_view.dart';
import 'package:lumina_app/ui/settings/library_settings_panel.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

Widget _wrapApp(Widget child) {
  return MaterialApp(
    theme: LuminaTokens.buildDarkTheme(),
    home: Scaffold(body: child),
  );
}

AlbumVersionTrackInfo _trk(
  String id,
  String title,
  int disc,
  int num,
  String path, {
  String codec = 'flac',
  int sr = 96000,
  int bits = 24,
}) => AlbumVersionTrackInfo(
  id: id,
  title: title,
  discNumber: disc,
  trackNumber: num,
  durationMs: 200000,
  codec: codec,
  sampleRateHz: sr,
  bitDepth: bits,
  externalTrackId: path,
);

List<CanonicalAlbumDetail> _buildSeededGroups() {
  return [
    CanonicalAlbumDetail(
      id: 'grp-dsotm',
      title: 'Dark Side of the Moon',
      artistName: 'Pink Floyd',
      releaseYear: 1973,
      primaryVersionId: 'ver-hires',
      versions: [
        AlbumVersionInfo(
          id: 'ver-hires',
          provider: 'local',
          externalAlbumId: '/music/dsotm-hires',
          editionLabel: '24-bit Hi-Res Master',
          codec: 'flac',
          sampleRateHz: 96000,
          bitDepth: 24,
          isPrimary: true,
          qualityScore: 810.0,
          discCount: 2,
          trackCount: 4,
          tracks: [
            _trk('t-hr-1', 'Speak to Me', 1, 1, '/music/dsotm/CD1/01.flac'),
            _trk('t-hr-2', 'Breathe', 1, 2, '/music/dsotm/CD1/02.flac'),
            _trk('t-hr-3', 'Money (Live)', 2, 1, '/music/dsotm/CD2/01.flac'),
            _trk('t-hr-4', 'Eclipse (Live)', 2, 2, '/music/dsotm/CD2/02.flac'),
          ],
        ),
        AlbumVersionInfo(
          id: 'ver-cd',
          provider: 'local',
          externalAlbumId: '/music/dsotm-cd',
          editionLabel: '16-bit CD Rip',
          codec: 'flac',
          sampleRateHz: 44100,
          bitDepth: 16,
          qualityScore: 680.0,
          discCount: 1,
          trackCount: 1,
          manualGroupId: 'grp-dsotm',
          tracks: [
            _trk('t-cd-1', 'Time (CD)', 1, 1, '/music/dsotm-cd/01.flac', sr: 44100, bits: 16),
          ],
        ),
        AlbumVersionInfo(
          id: 'ver-mp3-hidden',
          provider: 'local',
          externalAlbumId: '/music/dsotm-mp3',
          editionLabel: 'MP3 Legacy',
          codec: 'mp3',
          sampleRateHz: 44100,
          bitDepth: 16,
          isHidden: true,
          qualityScore: 310.0,
          discCount: 1,
          trackCount: 1,
          tracks: [
            _trk('t-mp3-1', 'Time (MP3)', 1, 1, '/music/dsotm-mp3/01.mp3', codec: 'mp3', sr: 44100, bits: 16),
          ],
        ),
      ],
    ),
    CanonicalAlbumDetail(
      id: 'grp-wall-d1',
      title: 'The Wall - Disc 1',
      artistName: 'Pink Floyd',
      releaseYear: 1979,
      primaryVersionId: 'ver-wall-d1',
      versions: [
        AlbumVersionInfo(
          id: 'ver-wall-d1',
          provider: 'local',
          externalAlbumId: '/music/wall-d1',
          editionLabel: 'CD1',
          codec: 'flac',
          sampleRateHz: 44100,
          bitDepth: 16,
          isPrimary: true,
          qualityScore: 680.0,
          discCount: 1,
          trackCount: 1,
          tracks: [
            _trk('t-w1', 'In the Flesh?', 1, 1, '/music/wall-d1/01.flac', sr: 44100, bits: 16),
          ],
        ),
      ],
    ),
    CanonicalAlbumDetail(
      id: 'grp-wall-d2',
      title: 'The Wall - Disc 2',
      artistName: 'Pink Floyd',
      releaseYear: 1979,
      primaryVersionId: 'ver-wall-d2',
      versions: [
        AlbumVersionInfo(
          id: 'ver-wall-d2',
          provider: 'local',
          externalAlbumId: '/music/wall-d2',
          editionLabel: 'CD2',
          codec: 'flac',
          sampleRateHz: 44100,
          bitDepth: 16,
          isPrimary: true,
          qualityScore: 680.0,
          discCount: 1,
          trackCount: 1,
          tracks: [
            _trk('t-w2', 'Hey You', 1, 1, '/music/wall-d2/01.flac', sr: 44100, bits: 16),
          ],
        ),
      ],
    ),
  ];
}

void main() {
  group('Step 2 Models JSON Parity', () {
    test('CanonicalAlbumSummary & AlbumVersionOpResult match Rust DTO keys', () {
      final summary = CanonicalAlbumSummary.fromJson(const {
        'id': 'grp-1',
        'group_id': 'grp-1',
        'version_id': 'ver-1',
        'primary_version_id': 'ver-1',
        'title': 'Kind of Blue',
        'artist': 'Miles Davis',
        'release_year': 1959,
        'track_count': 5,
        'disc_count': 2,
        'version_count': 2,
        'hidden_version_count': 1,
        'is_primary': true,
        'is_primary_locked': true,
        'is_hidden': false,
        'is_manual_group': true,
        'quality_score': 820.5,
        'edition_label': '24/192 Master',
        'provider': 'local',
        'codec': 'flac',
        'sample_rate_hz': 192000,
        'bit_depth': 24,
        'is_dsd': false,
      });

      expect(summary.effectiveGroupId, 'grp-1');
      expect(summary.selectionKey, 'ver-1');
      expect(summary.totalVersionCount, 3);
      expect(summary.isPrimary, isTrue);
      expect(summary.isPrimaryLocked, isTrue);
      expect(summary.isManualGroup, isTrue);
      expect(summary.discCount, 2);

      final op = AlbumVersionOpResult.fromJson(const {
        'affected_group_ids': ['grp-1'],
        'affected_version_ids': ['ver-1', 'ver-2'],
        'primary_version_id': 'ver-1',
        'moved_tracks': 8,
        'pruned_versions': 1,
        'pruned_albums': 1,
      });
      expect(op.hasChanges, isTrue);
      expect(op.movedTracks, 8);
      expect(op.prunedAlbums, 1);

      expect(SplitTargetMode.sameGroup.toJson(), 'same_group');
      expect(SplitTargetMode.newGroup.toJson(), 'new_group');
      expect(
        const DiscMappingEntry(versionId: 'v1', discStart: 2).toJson(),
        const {'version_id': 'v1', 'disc_start': 2},
      );
    });
  });

  group('Step 2 Album Main List UX', () {
    testWidgets('shows version count badge and expands hidden/alternate versions on toggle', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final svc = MockAudioService()..seedAlbumGroups(_buildSeededGroups());
      final cache = LibraryIndexCache();
      final layoutCtrl = AlbumLayoutSettingsController();
      addTearDown(() {
        svc.dispose();
        cache.dispose();
        layoutCtrl.dispose();
      });

      await tester.pumpWidget(
        _wrapApp(
          AlbumsAndCreditsView(
            audioService: svc,
            libraryCache: cache,
            layoutController: layoutCtrl,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Default mode shows 1 primary card per group + '3 版本' badge on grp-dsotm.
      expect(find.byKey(const Key('album_version_count_badge_ver-hires')), findsOneWidget);
      expect(find.text('3 版本'), findsOneWidget);
      expect(find.byKey(const Key('album_hidden_badge_ver-mp3-hidden')), findsNothing);

      // Toggle Show Hidden ON -> expands primary, secondary, and hidden versions with badges.
      await tester.tap(find.byKey(const Key('toggle_show_hidden_albums')));
      await tester.pumpAndSettle();

      expect(layoutCtrl.showHiddenAlbums, isTrue);
      expect(find.byKey(const Key('album_primary_badge_ver-hires')), findsOneWidget);
      expect(find.byKey(const Key('album_secondary_badge_ver-cd')), findsOneWidget);
      expect(find.byKey(const Key('album_hidden_badge_ver-mp3-hidden')), findsOneWidget);
    });

    testWidgets('LibrarySettingsPanel Show Hidden switch syncs with AlbumLayoutSettingsController', (
      tester,
    ) async {
      final svc = MockAudioService();
      final libSettings = LibrarySettingsController();
      final layoutCtrl = AlbumLayoutSettingsController();
      var changedCount = 0;
      addTearDown(() {
        svc.dispose();
        libSettings.dispose();
        layoutCtrl.dispose();
      });

      await tester.pumpWidget(
        _wrapApp(
          LibrarySettingsPanel(
            audioService: svc,
            settingsController: libSettings,
            albumLayoutController: layoutCtrl,
            onLibraryChanged: () => changedCount++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key('switch_settings_show_hidden_albums'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(layoutCtrl.showHiddenAlbums, isTrue);
      expect(changedCount, greaterThanOrEqualTo(1));
    });

    testWidgets('multi-select toolbar: merge dialog, group as alternate, and hide', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final svc = MockAudioService()..seedAlbumGroups(_buildSeededGroups());
      final cache = LibraryIndexCache();
      final layoutCtrl = AlbumLayoutSettingsController();
      addTearDown(() {
        svc.dispose();
        cache.dispose();
        layoutCtrl.dispose();
      });

      await tester.pumpWidget(
        _wrapApp(
          AlbumsAndCreditsView(
            audioService: svc,
            libraryCache: cache,
            layoutController: layoutCtrl,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Enter multi-select and select The Wall Disc 1 + Disc 2.
      await tester.tap(find.byKey(const Key('btn_album_multi_select')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('album_card_grp-wall-d1')));
      await tester.tap(find.byKey(const Key('album_card_grp-wall-d2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('album_selection_bar')), findsOneWidget);
      expect(find.text('已選取 2 項'), findsOneWidget);

      // Open Merge Dialog, reorder discs, and confirm merge.
      await tester.tap(find.byKey(const Key('btn_selection_merge')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dialog_merge_albums')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_merge_move_up_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_merge_albums')));
      await tester.pumpAndSettle();

      // Disc 2 group pruned; merged album now has 2 tracks across 2 discs.
      final albumsAfterMerge = await svc.getAlbums(limit: 100);
      expect(albumsAfterMerge.length, 2);
      final mergedDetail = await svc.getAlbumDetail('grp-wall-d1');
      expect(mergedDetail?.versions.first.tracks.length, 2);

      // Now group remaining 2 albums as alternate versions.
      await tester.tap(find.byKey(const Key('btn_album_multi_select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('album_card_grp-dsotm')));
      await tester.tap(find.byKey(const Key('album_card_grp-wall-d1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_selection_group')));
      await tester.pumpAndSettle();

      final albumsAfterGroup = await svc.getAlbums(limit: 100);
      expect(albumsAfterGroup.length, 1);
      expect(albumsAfterGroup.first.totalVersionCount, 4);

      // Hide selected version via selection bar.
      await tester.tap(find.byKey(const Key('btn_album_multi_select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('album_card_grp-dsotm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_selection_toggle_hide')));
      await tester.pumpAndSettle();

      final detailAfterHide = await svc.getAlbumDetail('grp-dsotm');
      final hiResAfterHide =
          detailAfterHide!.versions.firstWhere((v) => v.id == 'ver-hires');
      expect(hiResAfterHide.isHidden, isTrue);
    });
  });

  group('Step 2 Album Detail Versions Section & Split Dialog', () {
    testWidgets('set primary lock, reset lock, toggle hidden, reset grouping, ungroup, and split (3 modes)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final svc = MockAudioService()..seedAlbumGroups(_buildSeededGroups());
      final cache = LibraryIndexCache();
      addTearDown(() {
        svc.dispose();
        cache.dispose();
      });

      await tester.pumpWidget(
        _wrapApp(
          AlbumDetailPage(
            albumId: 'grp-dsotm',
            audioService: svc,
            libraryCache: cache,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('album_versions_section')), findsOneWidget);
      expect(find.byKey(const Key('badge_primary_ver-hires')), findsOneWidget);
      expect(find.byKey(const Key('badge_manual_lock_ver-cd')), findsOneWidget);
      expect(find.byKey(const Key('badge_hidden_ver-mp3-hidden')), findsOneWidget);

      // 1. Set secondary 16-bit CD Rip as locked primary.
      await tester.tap(find.byKey(const Key('btn_version_menu_ver-cd')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('設為主版本'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('badge_primary_ver-cd')), findsOneWidget);
      var detail = await svc.getAlbumDetail('grp-dsotm');
      expect(detail?.isPrimaryLocked, isTrue);
      expect(detail?.primaryVersionId, 'ver-cd');

      // 2. Reset primary lock -> auto-reverts to highest-scoring 24-bit Hi-Res.
      await tester.tap(find.byKey(const Key('btn_version_menu_ver-cd')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消主版本鎖定'));
      await tester.pumpAndSettle();

      detail = await svc.getAlbumDetail('grp-dsotm');
      expect(detail?.isPrimaryLocked, isFalse);
      expect(detail?.primaryVersionId, 'ver-hires');

      // 3. Reset manual grouping lock on ver-cd.
      await tester.tap(find.byKey(const Key('btn_version_menu_ver-cd')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重置手動分組鎖定'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('badge_manual_lock_ver-cd')), findsNothing);

      // 4. Open Split Dialog on 2-disc ver-hires and verify all 3 modes + destination toggle.
      await tester.tap(find.byKey(const Key('btn_version_menu_ver-hires')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拆分此專輯'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dialog_split_album')), findsOneWidget);

      // Verify folder mode and manual mode render cleanly, then split by disc into SameGroup.
      await tester.tap(find.byKey(const Key('chip_split_mode_folder')));
      await tester.pumpAndSettle();
      expect(find.text('CD1'), findsOneWidget);
      expect(find.text('CD2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chip_split_mode_manual')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chk_split_track_t-hr-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('chip_split_mode_disc')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chip_split_target_same_group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_confirm_split_album')));
      await tester.pumpAndSettle();

      detail = await svc.getAlbumDetail('grp-dsotm');
      expect(detail!.versions.length, 4);

      // 5. Ungroup ver-cd into standalone album.
      await tester.tap(find.byKey(const Key('btn_version_menu_ver-cd')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出成為獨立專輯'));
      await tester.pumpAndSettle();

      detail = await svc.getAlbumDetail('grp-dsotm');
      expect(detail!.versions.any((v) => v.id == 'ver-cd'), isFalse);
    });
  });
}
