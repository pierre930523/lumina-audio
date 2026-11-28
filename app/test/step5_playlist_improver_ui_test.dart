import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/smart_playlist_service.dart';
import 'package:lumina_app/ui/playlists/smart_playlists_view.dart';
import 'package:material_ui/material_ui.dart';

/// MockAudioService subclass that guarantees duplicate + repair + upgrade
/// suggestions appear together in the Playlist Improver report for full UI
/// filter, checkbox, apply, and snapshot revert verification.
class _ImproverTestAudioService extends MockAudioService {
  bool _upgradedApplied = false;

  static const PlaylistTrackSummary _lossyTrack = PlaylistTrackSummary(
    trackId: 'trk-lossy-1',
    versionId: 'ver-lossy',
    canonicalAlbumId: 'alb-dsotm',
    title: 'Time',
    artistName: 'Pink Floyd',
    albumTitle: 'The Dark Side of the Moon',
    providerId: 'local',
    codec: 'mp3',
    sampleRateHz: 44100,
    bitDepth: 16,
    durationMs: 245000,
    qualityScore: 220.0,
    fileStatus: 'ok',
    filePath: r'D:\Music\Time.mp3',
  );

  static const PlaylistTrackSummary _hiresTrack = PlaylistTrackSummary(
    trackId: 'trk-hires-1',
    versionId: 'ver-hires',
    canonicalAlbumId: 'alb-dsotm',
    title: 'Time',
    artistName: 'Pink Floyd',
    albumTitle: 'The Dark Side of the Moon',
    providerId: 'local',
    codec: 'flac',
    sampleRateHz: 96000,
    bitDepth: 24,
    durationMs: 245000,
    qualityScore: 760.0,
    fileStatus: 'ok',
    filePath: r'D:\Music\Time_24_96.flac',
  );

  @override
  Future<PlaylistImprovementReport?> analyzePlaylistImprovements(
    String playlistId,
  ) async {
    final base = await super.analyzePlaylistImprovements(playlistId);
    if (base == null || _upgradedApplied) return base;
    final upg = PlaylistImprovementSuggestion(
      suggestionId: 'upg:0:trk-hires-1',
      kind: PlaylistImprovementKind.upgrade,
      position: 0,
      rawEntry: _lossyTrack.filePath!,
      currentTrack: _lossyTrack,
      candidateTrack: _hiresTrack,
      reason: '找到 24-bit / 96 kHz 無損母帶版本',
      confidence: 0.98,
    );
    return PlaylistImprovementReport(
      playlistId: base.playlistId,
      playlistName: base.playlistName,
      totalItems: base.totalItems,
      duplicateCount: base.duplicateCount,
      repairCount: base.repairCount,
      upgradeCount: base.upgradeCount + 1,
      suggestions: <PlaylistImprovementSuggestion>[...base.suggestions, upg],
    );
  }

  @override
  Future<ApplyPlaylistImprovementsResult?> applyPlaylistImprovements(
    String playlistId,
    ApplyPlaylistImprovementsRequest req,
  ) async {
    final hadUpgrade = req.suggestionIds.contains('upg:0:trk-hires-1');
    final filteredReq = ApplyPlaylistImprovementsRequest(
      suggestionIds: req.suggestionIds
          .where((id) => id != 'upg:0:trk-hires-1')
          .toList(growable: false),
      applyKinds: req.applyKinds,
      reason: req.reason,
    );
    final res = await super.applyPlaylistImprovements(playlistId, filteredReq);
    if (res == null) return null;
    if (hadUpgrade) _upgradedApplied = true;
    return ApplyPlaylistImprovementsResult(
      playlistId: res.playlistId,
      snapshotId: res.snapshotId,
      duplicatesRemoved: res.duplicatesRemoved,
      tracksRepaired: res.tracksRepaired,
      tracksUpgraded: res.tracksUpgraded + (hadUpgrade ? 1 : 0),
      finalTrackCount: res.finalTrackCount,
    );
  }

  @override
  Future<RevertPlaylistSnapshotResult?> revertPlaylistSnapshot(
    String snapshotId,
  ) async {
    final res = await super.revertPlaylistSnapshot(snapshotId);
    if (res != null) _upgradedApplied = false;
    return res;
  }
}

void main() {
  testWidgets(
    'SmartPlaylistsView defaults to Smart Playlists and switches to Static Playlists with create flow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = _ImproverTestAudioService();
      final smartService = SmartPlaylistService(audio);
      addTearDown(() {
        smartService.dispose();
        audio.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartPlaylistsView(
              audioService: audio,
              playlistService: smartService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('smart_playlists_view')), findsOneWidget);
      expect(find.byKey(const Key('btn_create_smart_playlist')), findsOneWidget);
      expect(find.byKey(const Key('static_playlists_pane')), findsNothing);

      await tester.tap(find.byKey(const Key('tab_static_playlists')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('static_playlists_pane')), findsOneWidget);
      expect(find.byKey(const Key('static_playlist_item_pl-demo-1')), findsOneWidget);
      expect(find.byKey(const Key('btn_improve_static_playlist')), findsOneWidget);
      expect(find.byKey(const Key('btn_static_playlist_snapshots')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_create_static_playlist')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_static_playlist_name')),
        '試音清單 A',
      );
      await tester.tap(
        find.byKey(const Key('btn_confirm_create_static_playlist')),
      );
      await tester.pumpAndSettle();

      expect(find.text('試音清單 A'), findsWidgets);
    },
  );

  testWidgets(
    'Playlist Improver dialog filters duplicate/repair/upgrade, toggles checkboxes, applies & reverts snapshot',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = _ImproverTestAudioService();
      final smartService = SmartPlaylistService(audio);
      addTearDown(() {
        smartService.dispose();
        audio.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartPlaylistsView(
              audioService: audio,
              playlistService: smartService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('tab_static_playlists')));
      await tester.pumpAndSettle();

      expect(find.textContaining('共 3 首'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_improve_static_playlist')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('playlist_improver_dialog')), findsOneWidget);
      expect(find.text('全部 (3)'), findsOneWidget);
      expect(find.text('重複去重 (1)'), findsOneWidget);
      expect(find.text('失效修復 (1)'), findsOneWidget);
      expect(find.text('音質升級 (1)'), findsOneWidget);
      expect(find.text('+Δ540 品質分'), findsOneWidget);

      // Filter to upgrade only and toggle its checkbox off then back on
      await tester.tap(find.byKey(const Key('improver_filter_upgrade')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('improver_checkbox_upg:0:trk-hires-1')), findsOneWidget);
      expect(find.text('移除重複（保留位置 #1）'), findsNothing);

      await tester.tap(find.byKey(const Key('improver_checkbox_upg:0:trk-hires-1')));
      await tester.pumpAndSettle();
      expect(find.text('已選取 2 / 3 項變更'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_improver_select_all')));
      await tester.pumpAndSettle();
      expect(find.text('已選取 3 / 3 項變更'), findsOneWidget);

      // Clear all visible then re-select all via All tab
      await tester.tap(find.byKey(const Key('btn_improver_clear_all')));
      await tester.pumpAndSettle();
      expect(find.text('已選取 2 / 3 項變更'), findsOneWidget);

      await tester.tap(find.byKey(const Key('improver_filter_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_improver_select_all')));
      await tester.pumpAndSettle();
      expect(find.text('已選取 3 / 3 項變更'), findsOneWidget);

      // Apply selected changes (auto-creates snapshot)
      await tester.tap(find.byKey(const Key('btn_apply_playlist_improvements')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('playlist_improver_dialog')), findsNothing);
      expect(find.textContaining('共 2 首'), findsOneWidget);
      expect(find.text('復原歷史 (1)'), findsOneWidget);

      // Open Snapshot History dialog and one-click revert
      await tester.tap(find.byKey(const Key('btn_static_playlist_snapshots')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('playlist_snapshots_dialog')), findsOneWidget);
      final revertBtn = find.text('一鍵復原');
      expect(revertBtn, findsOneWidget);

      await tester.tap(revertBtn);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('playlist_snapshots_dialog')), findsNothing);
      expect(find.textContaining('共 3 首'), findsOneWidget);
    },
  );
}
