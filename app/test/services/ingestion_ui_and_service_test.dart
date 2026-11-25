import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
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
  group('MockAudioService & CoordinatingAudioService ingestion parity', () {
    test('watched roots, skipped files, overrides, scan stream & ingest work', () async {
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

      final events = <ScanProgressEvent>[];
      final sub = facade.scanProgressStream.listen(events.add);
      addTearDown(sub.cancel);

      final scanId = await facade.startDirectoryScan(r'C:\Music\HiRes');
      expect(scanId, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.length, greaterThanOrEqualTo(2));
      expect(events.first.state, ScanLifecycleState.discovering);
      expect(events.last.state, ScanLifecycleState.completed);

      final added = await facade.addWatchedRoot(
        r'\\nas\music',
        watchMode: WatchMode.nasPolling,
        pollIntervalSec: 600,
      );
      expect(added, isNotNull);
      expect(added!.watchMode, WatchMode.nasPolling);
      expect((await facade.listWatchedRoots()).length, 1);
      expect(await facade.removeWatchedRoot(r'\\nas\music'), isTrue);
      expect(await facade.listWatchedRoots(), isEmpty);

      mock.seedSkippedFiles(const [
        SkippedFileRecord(
          id: 'sk-1',
          providerId: 'local',
          filePath: r'C:\Music\bad.flac',
          reason: SkipReason.corruptHeader,
          detail: 'invalid header',
          firstSeenAt: '2026-11-25T00:00:00Z',
          lastSeenAt: '2026-11-25T00:01:00Z',
        ),
        SkippedFileRecord(
          id: 'sk-2',
          providerId: 'local',
          filePath: r'C:\Music\album.iso',
          reason: SkipReason.unsplitCueOrIso,
          detail: 'unsplit iso',
          firstSeenAt: '2026-11-25T00:00:00Z',
          lastSeenAt: '2026-11-25T00:01:00Z',
        ),
      ]);
      expect((await facade.getSkippedFiles()).length, 2);
      expect(await facade.dismissSkippedFile('sk-1'), isTrue);
      expect((await facade.getSkippedFiles()).length, 1);
      expect((await facade.getSkippedFiles(includeDismissed: true)).length, 2);
      final retry = await facade.retrySkippedFile('sk-2');
      expect(retry['status'], 'imported');
      expect(await facade.getSkippedFiles(), isEmpty);

      expect(
        await facade.setMetadataOverride(
          'album',
          'alb-1',
          'title',
          'Overridden Title',
        ),
        isTrue,
      );
      final ovs = await facade.getMetadataOverrides('album', 'alb-1');
      expect(ovs.length, 1);
      expect(ovs.single.fieldName, 'title');
      expect((await facade.getAlbumDetail('alb-1'))?.title, 'Overridden Title');
      expect(await facade.clearMetadataOverride('album', 'alb-1', 'title'), isTrue);
      expect(await facade.getMetadataOverrides('album', 'alb-1'), isEmpty);

      final batch = ExternalCatalogIngestBatch.fromStreamingCatalog(
        'qobuz',
        StreamingCatalog(
          tracks: const [
            TrackInfo(
              id: 'qobuz:123',
              title: 'Blue in Green',
              artist: 'Miles Davis',
              album: 'Kind of Blue',
              duration: Duration(seconds: 327),
              format: AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 192000,
                bitDepth: 24,
                channels: 2,
              ),
              filePath: 'https://expiring.qobuz.cdn/never_leak.flac?exp=999',
            ),
          ],
        ),
      );
      final ingestRes = await facade.ingestExternalCatalog(batch);
      expect(ingestRes['albums_ingested'], 1);
      expect(ingestRes['tracks_ingested'], 1);
      expect(mock.ingestedExternalBatches.length, 1);
    });
  });

  group('LibrarySettingsPanel ingestion UI', () {
    testWidgets(
      'renders live scan progress, watched root badges, and skipped files quarantine (Retry & Dismiss)',
      (tester) async {
        final mock = MockAudioService();
        final settings = LibrarySettingsController();
        settings.addOrUpdateFolder(r'\\nas\lossless', 12);
        await mock.addWatchedRoot(
          r'\\nas\lossless',
          watchMode: WatchMode.nasPolling,
        );
        mock.seedSkippedFiles(const [
          SkippedFileRecord(
            id: 'sk-corrupt',
            providerId: 'local',
            filePath: r'C:\Music\broken.flac',
            reason: SkipReason.corruptHeader,
            detail: 'truncated frame',
            firstSeenAt: '2026-11-25T10:00:00Z',
            lastSeenAt: '2026-11-25T10:05:00Z',
          ),
          SkippedFileRecord(
            id: 'sk-iso',
            providerId: 'local',
            filePath: r'C:\Music\sacd.iso',
            reason: SkipReason.unsplitCueOrIso,
            detail: 'SACD ISO not split',
            firstSeenAt: '2026-11-25T10:00:00Z',
            lastSeenAt: '2026-11-25T10:06:00Z',
          ),
        ]);
        addTearDown(mock.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibrarySettingsPanel(
                audioService: mock,
                settingsController: settings,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Watched root badge shows NAS Polling for UNC path.
        expect(find.byKey(const Key(r'watch_badge_\\nas\lossless')), findsOneWidget);
        expect(find.text('NAS Polling'), findsOneWidget);

        // Emit live scan progress event and verify progress card renders.
        mock.emitScanProgress(
          const ScanProgressEvent(
            scanId: 'scan-live-1',
            rootPath: r'D:\Music',
            state: ScanLifecycleState.probing,
            scanned: 40,
            added: 35,
            updated: 3,
            skipped: 2,
            totalEstimated: 100,
            currentPath: r'D:\Music\Track40.flac',
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('ingestion_scan_progress_card')), findsOneWidget);
        expect(find.textContaining('已掃描 40 · 新增 35 · 更新 3 · 略過 2'), findsOneWidget);

        // Scroll to skipped files quarantine section.
        final skippedSection = find.byKey(const Key('skipped_files_section'));
        await tester.ensureVisible(skippedSection);
        await tester.pumpAndSettle();
        expect(skippedSection, findsOneWidget);
        expect(find.byKey(const Key('skipped_file_sk-corrupt')), findsOneWidget);
        expect(find.byKey(const Key('skipped_file_sk-iso')), findsOneWidget);
        expect(find.text(SkipReason.corruptHeader.displayLabel), findsOneWidget);

        // Retry first skipped file -> imported & removed from list.
        await tester.ensureVisible(find.byKey(const Key('btn_retry_skipped_sk-corrupt')));
        await tester.tap(find.byKey(const Key('btn_retry_skipped_sk-corrupt')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('skipped_file_sk-corrupt')), findsNothing);
        expect(find.byKey(const Key('skipped_file_sk-iso')), findsOneWidget);

        // Dismiss second skipped file -> hidden from list.
        await tester.ensureVisible(find.byKey(const Key('btn_dismiss_skipped_sk-iso')));
        await tester.tap(find.byKey(const Key('btn_dismiss_skipped_sk-iso')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('skipped_file_sk-iso')), findsNothing);
      },
    );
  });

  group('AlbumDetailPage non-destructive metadata override dialog', () {
    testWidgets(
      'saves and clears UserEdit overrides for album title and artist_name',
      (tester) async {
        final mock = MockAudioService();
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

        expect(find.text('The Dark Side of the Moon'), findsOneWidget);
        expect(find.byKey(const Key('album_override_badge')), findsNothing);

        await tester.tap(find.byKey(const Key('btn_edit_album_metadata')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('input_override_album_title')),
          'DSOTM (2026 Remaster)',
        );
        await tester.enterText(
          find.byKey(const Key('input_override_album_artist')),
          'Pink Floyd Official',
        );
        await tester.tap(find.byKey(const Key('btn_save_album_metadata')));
        await tester.pumpAndSettle();

        expect(find.text('DSOTM (2026 Remaster)'), findsOneWidget);
        expect(find.text('Pink Floyd Official'), findsWidgets);
        expect(find.byKey(const Key('album_override_badge')), findsOneWidget);

        // Clear overrides via dialog.
        await tester.tap(find.byKey(const Key('btn_edit_album_metadata')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_clear_album_metadata')));
        await tester.pumpAndSettle();

        expect(find.text('The Dark Side of the Moon'), findsOneWidget);
        expect(find.byKey(const Key('album_override_badge')), findsNothing);
      },
    );
  });
}
