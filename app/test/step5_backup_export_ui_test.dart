import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/common/library_export_dialog.dart';
import 'package:lumina_app/ui/settings/library_backup_card.dart';
import 'package:material_ui/material_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

void main() {
  testWidgets(
    'LibraryBackupCard saves settings, creates hot backup, renders history, and restores with libraryReloadedStream',
    (tester) async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      var reloadEvents = 0;
      final sub = service.libraryReloadedStream.listen((_) => reloadEvents++);
      addTearDown(sub.cancel);

      var onLibraryChangedCalls = 0;
      await tester.pumpWidget(
        _wrap(
          LibraryBackupCard(
            audioService: service,
            onLibraryChanged: () => onLibraryChangedCalls++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_backup_card')), findsOneWidget);

      // Update backup directory, schedule, and max keep then save
      await tester.enterText(
        find.byKey(const Key('input_backup_dir')),
        r'D:\LuminaBackups',
      );
      await tester.enterText(
        find.byKey(const Key('input_backup_max_keep')),
        '7',
      );
      await tester.tap(find.byKey(const Key('dropdown_backup_schedule')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每日').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_save_backup_settings')));
      await tester.pumpAndSettle();

      final saved = await service.getBackupSettings();
      expect(saved, isNotNull);
      expect(saved!.backupDir, r'D:\LuminaBackups');
      expect(saved.scheduleMode, BackupScheduleMode.daily);
      expect(saved.maxKeep, 7);

      // Create manual hot backup & verify history renders short SHA-256 + badge
      await tester.tap(find.byKey(const Key('btn_create_backup_now')));
      await tester.pumpAndSettle();

      final history = await service.listBackupHistory();
      expect(history, hasLength(1));
      final first = history.first;
      expect(find.byKey(Key('backup_history_row_${first.id}')), findsOneWidget);
      expect(find.text('手動'), findsOneWidget);
      expect(find.textContaining(first.sha256.substring(0, 12)), findsWidgets);

      // Tap restore -> verify confirmation dialog -> confirm -> verify reload stream fires
      await tester.tap(find.byKey(Key('btn_restore_backup_${first.id}')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('dialog_confirm_backup_restore')),
        findsOneWidget,
      );
      expect(find.textContaining('pre_restore'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_confirm_backup_restore')));
      await tester.pumpAndSettle();

      expect(reloadEvents, 1);
      expect(onLibraryChangedCalls, 1);
      expect(find.text('還原前'), findsOneWidget);
    },
  );

  testWidgets(
    'LibraryExportDialog executes CSV/JSON catalog export and async Audio + .m3u8 export',
    (tester) async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => FilledButton(
              key: const Key('btn_trigger_export'),
              onPressed: () => LibraryExportDialog.show(
                context,
                audioService: service,
                defaultPlaylistName: 'hires_sync.m3u8',
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_trigger_export')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library_export_dialog')), findsOneWidget);

      // 1. Run CSV catalog export
      await tester.enterText(
        find.byKey(const Key('input_catalog_output_path')),
        r'D:\Exports\library.csv',
      );
      await tester.tap(find.byKey(const Key('btn_run_catalog_export')));
      await tester.pumpAndSettle();

      final resultBox = find.byKey(const Key('catalog_export_result'));
      expect(resultBox, findsOneWidget);
      expect(find.descendant(of: resultBox, matching: find.textContaining('CSV')), findsOneWidget);
      expect(
        find.descendant(of: resultBox, matching: find.textContaining(r'D:\Exports\library.csv')),
        findsOneWidget,
      );

      // 2. Switch to JSON format and re-run
      await tester.tap(find.byKey(const Key('chip_export_format_json')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_run_catalog_export')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: resultBox, matching: find.textContaining('JSON')), findsOneWidget);

      // 3. Switch to Audio + .m3u8 sync export tab and run
      await tester.tap(find.byKey(const Key('tab_export_audio')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('input_audio_export_dir')),
        r'E:\DAP_Music',
      );
      await tester.tap(find.byKey(const Key('btn_run_audio_export')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audio_export_progress_panel')),
        findsOneWidget,
      );
      expect(find.text('同步匯出完成'), findsOneWidget);
      expect(find.textContaining('hires_sync.m3u8'), findsWidgets);
    },
  );
}
