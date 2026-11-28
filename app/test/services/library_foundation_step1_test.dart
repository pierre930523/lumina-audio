import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/settings/library_settings_panel.dart';

class _MemStore implements SecureCredentialStore {
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

void main() {
  group('MockAudioService & CoordinatingAudioService Step 1 parity', () {
    test('3-layer metadata resolution, revert, batch rescan & cleanup', () async {
      final mock = MockAudioService();
      final manager = StreamingManager(
        credentialStore: _MemStore(),
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

      // Default global policy is 'file'.
      expect(await facade.getDefaultMetadataPolicy(), MetadataPolicy.file);

      mock.seedEntityMetadataLayers(
        'album',
        'alb-dsotm',
        fileMeta: const {'title': 'DSOTM (File Tag)', 'artist_name': 'Pink Floyd (File)'},
        cloudMeta: const {'title': 'DSOTM (Cloud MB)', 'artist_name': 'Pink Floyd (Cloud)'},
      );

      // Under global 'file' + album 'inherit', file layer wins.
      var detail = await facade.getAlbumDetail('alb-dsotm');
      expect(detail?.title, 'DSOTM (File Tag)');
      expect(detail?.metaPolicy, MetadataPolicy.inherit);
      expect(detail?.hasUserEdits, isFalse);

      // Switch global policy to 'cloud' -> album with 'inherit' resolves cloud.
      expect(await facade.setDefaultMetadataPolicy(MetadataPolicy.cloud), isTrue);
      expect(await facade.getDefaultMetadataPolicy(), MetadataPolicy.cloud);
      detail = await facade.getAlbumDetail('alb-dsotm');
      expect(detail?.title, 'DSOTM (Cloud MB)');

      // Per-album policy 'file' overrides global 'cloud'.
      expect(
        await facade.setEntityMetaPolicy('album', 'alb-dsotm', MetadataPolicy.file),
        isTrue,
      );
      detail = await facade.getAlbumDetail('alb-dsotm');
      expect(detail?.title, 'DSOTM (File Tag)');
      expect(detail?.metaPolicy, MetadataPolicy.file);

      // User edits override both file and cloud.
      expect(
        await facade.setEntityUserEdits('album', 'alb-dsotm', const {
          'title': 'DSOTM (User Custom)',
        }),
        isTrue,
      );
      detail = await facade.getAlbumDetail('alb-dsotm');
      expect(detail?.title, 'DSOTM (User Custom)');
      expect(detail?.hasUserEdits, isTrue);

      // Revert clears user edits and falls back to resolved layer.
      expect(await facade.revertEntityToFileMeta('album', 'alb-dsotm'), isTrue);
      detail = await facade.getAlbumDetail('alb-dsotm');
      expect(detail?.title, 'DSOTM (File Tag)');
      expect(detail?.hasUserEdits, isFalse);

      // Batch rescan skipped files.
      mock.seedSkippedFiles(const [
        SkippedFileRecord(
          id: 'sk-1',
          providerId: 'local',
          filePath: r'C:\Music\fixed.flac',
          reason: SkipReason.corruptHeader,
          detail: 'header fixed',
          firstSeenAt: '2026-11-26T00:00:00Z',
          lastSeenAt: '2026-11-26T00:01:00Z',
        ),
        SkippedFileRecord(
          id: 'sk-2',
          providerId: 'local',
          filePath: r'C:\Music\gone.flac',
          reason: SkipReason.ioError,
          detail: 'not found',
          firstSeenAt: '2026-11-26T00:00:00Z',
          lastSeenAt: '2026-11-26T00:01:00Z',
        ),
        SkippedFileRecord(
          id: 'sk-3',
          providerId: 'local',
          filePath: r'C:\Music\unsupported.ape',
          reason: SkipReason.unsupportedFormat,
          detail: 'unsupported',
          firstSeenAt: '2026-11-26T00:00:00Z',
          lastSeenAt: '2026-11-26T00:01:00Z',
        ),
      ]);
      final batchRes = await facade.rescanAllSkippedFiles();
      expect(batchRes.total, 3);
      expect(batchRes.resolved, 1);
      expect(batchRes.removedMissing, 1);
      expect(batchRes.stillSkipped, 1);
      expect((await facade.getSkippedFiles()).length, 1);

      // Cleanup preview & selective execution.
      mock.seedCleanupPreview(const LibraryCleanupPreview(
        missingTracksCount: 4,
        emptyAlbumVersionsCount: 2,
        emptyAlbumsCount: 1,
        orphanArtistsCount: 3,
        orphanArtworkFilesCount: 5,
        orphanArtworkBytes: 20480,
        offlineRoots: [r'E:\OfflineDrive'],
        onlineRootsChecked: [r'C:\Music'],
      ));
      final preview = await facade.previewLibraryCleanup();
      expect(preview.missingTracksCount, 4);
      expect(preview.offlineRoots, [r'E:\OfflineDrive']);

      final execRes = await facade.executeLibraryCleanup(
        const LibraryCleanupOptions(
          removeMissingTracks: true,
          removeEmptyAlbums: false,
          removeOrphanArtists: true,
          removeOrphanArtworkCache: true,
        ),
      );
      expect(execRes.removedTracks, 4);
      expect(execRes.removedAlbums, 0);
      expect(execRes.removedArtists, 3);
      expect(execRes.removedArtworkFiles, 5);
      expect(execRes.skippedOfflineRoots, [r'E:\OfflineDrive']);
    });
  });

  group('AlbumDetailPage policy toggle & revert to file tags', () {
    testWidgets('edits policy, saves user edits, and reverts to file tags', (
      tester,
    ) async {
      final mock = MockAudioService();
      mock.seedEntityMetadataLayers(
        'album',
        'alb-dsotm',
        fileMeta: const {'title': 'Local File Title', 'artist_name': 'File Artist'},
        cloudMeta: const {'title': 'Cloud MB Title', 'artist_name': 'Cloud Artist'},
      );
      addTearDown(mock.dispose);

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumDetailPage(
              albumId: 'alb-dsotm',
              audioService: mock,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Local File Title'), findsOneWidget);
      expect(find.byKey(const Key('album_policy_badge')), findsNothing);

      // Open Edit Metadata dialog via More Options and switch policy to cloud only.
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_edit_album_metadata')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('album_meta_policy_selector')), findsOneWidget);
      expect(find.text('還原為原始檔案標籤（清除手動編輯）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chip_album_meta_policy_cloud')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_save_album_metadata')));
      await tester.pumpAndSettle();

      expect(find.text('Cloud MB Title'), findsOneWidget);
      expect(find.byKey(const Key('album_policy_badge')), findsOneWidget);
      expect(find.byKey(const Key('album_override_badge')), findsNothing);

      // Add manual edit -> overrides cloud, then revert -> clears manual edit.
      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_edit_album_metadata')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_override_album_title')),
        'Manual Custom Title',
      );
      await tester.tap(find.byKey(const Key('btn_save_album_metadata')));
      await tester.pumpAndSettle();
      expect(find.text('Manual Custom Title'), findsOneWidget);
      expect(find.byKey(const Key('album_override_badge')), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_album_more_options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_edit_album_metadata')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_clear_album_metadata')));
      await tester.pumpAndSettle();
      expect(find.text('Cloud MB Title'), findsOneWidget);
      expect(find.byKey(const Key('album_override_badge')), findsNothing);
    });
  });

  group('LibrarySettingsPanel Step 1 UI', () {
    testWidgets(
      'global policy toggle, skipped files badges + batch rescan, and library cleanup confirm flow',
      (tester) async {
        final mock = MockAudioService();
        final settings = LibrarySettingsController();
        var libraryChangedCount = 0;
        mock.seedSkippedFiles(const [
          SkippedFileRecord(
            id: 'sk-err',
            providerId: 'local',
            filePath: r'C:\Music\bad.flac',
            reason: SkipReason.corruptHeader,
            detail: 'truncated',
            firstSeenAt: '2026-11-26T00:00:00Z',
            lastSeenAt: '2026-11-26T00:05:00Z',
          ),
          SkippedFileRecord(
            id: 'sk-unsup',
            providerId: 'local',
            filePath: r'C:\Music\old.ape',
            reason: SkipReason.unsupportedFormat,
            detail: 'APE not supported',
            firstSeenAt: '2026-11-26T00:00:00Z',
            lastSeenAt: '2026-11-26T00:06:00Z',
          ),
        ]);
        mock.seedCleanupPreview(const LibraryCleanupPreview(
          missingTracksCount: 3,
          emptyAlbumVersionsCount: 1,
          emptyAlbumsCount: 1,
          orphanArtistsCount: 0,
          orphanArtworkFilesCount: 2,
          orphanArtworkBytes: 4096,
          offlineRoots: [r'Z:\OfflineNAS'],
          onlineRootsChecked: [r'C:\Music'],
        ));
        addTearDown(mock.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibrarySettingsPanel(
                audioService: mock,
                settingsController: settings,
                onLibraryChanged: () => libraryChangedCount++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Global metadata policy card: switch from file to cloud.
        final policySection = find.byKey(const Key('metadata_policy_section'));
        await tester.ensureVisible(policySection);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chip_global_meta_policy_cloud')));
        await tester.pumpAndSettle();
        expect(await mock.getDefaultMetadataPolicy(), MetadataPolicy.cloud);
        expect(libraryChangedCount, greaterThanOrEqualTo(1));

        // 2. Clean Up Library card: preview counts, offline banner, checkbox toggle, confirm dialog.
        final cleanupSection = find.byKey(const Key('library_cleanup_section'));
        await tester.ensureVisible(cleanupSection);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cleanup_offline_roots_banner')), findsOneWidget);
        expect(find.textContaining('3 首'), findsOneWidget);
        expect(find.textContaining('1 版本 / 1 專輯'), findsOneWidget);

        // Uncheck empty albums before executing.
        final emptyChk = find.byKey(const Key('chk_cleanup_empty_albums'));
        await tester.ensureVisible(emptyChk);
        await tester.tap(emptyChk);
        await tester.pumpAndSettle();

        final execBtn = find.byKey(const Key('btn_execute_library_cleanup'));
        await tester.ensureVisible(execBtn);
        await tester.tap(execBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('dialog_confirm_library_cleanup')), findsOneWidget);
        await tester.tap(find.byKey(const Key('btn_confirm_library_cleanup')));
        await tester.pumpAndSettle();

        expect(mock.lastCleanupOptions?.removeMissingTracks, isTrue);
        expect(mock.lastCleanupOptions?.removeEmptyAlbums, isFalse);
        expect(mock.lastCleanupOptions?.removeOrphanArtists, isFalse);
        expect(mock.lastCleanupOptions?.removeOrphanArtworkCache, isTrue);
        expect(find.byKey(const Key('cleanup_result_banner')), findsOneWidget);

        // 3. Skipped files: badges + one-click batch rescan.
        final skippedSection = find.byKey(const Key('skipped_files_section'));
        await tester.ensureVisible(skippedSection);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('skipped_reason_badge_sk-err')), findsOneWidget);
        expect(find.byKey(const Key('skipped_reason_badge_sk-unsup')), findsOneWidget);

        final rescanAllBtn = find.byKey(const Key('btn_rescan_all_skipped_files'));
        await tester.ensureVisible(rescanAllBtn);
        await tester.tap(rescanAllBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('skipped_file_sk-err')), findsNothing);
        expect(find.byKey(const Key('skipped_file_sk-unsup')), findsOneWidget);
      },
    );
  });
}
