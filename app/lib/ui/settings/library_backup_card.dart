import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../common/library_export_dialog.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

/// Settings card for SQLite WAL online hot backup, scheduled retention,
/// SHA-256 verified restore (with automatic `pre_restore` safety backup),
/// and quick entry to Catalog / Audio Export.
class LibraryBackupCard extends StatefulWidget {
  final AudioService audioService;
  final VoidCallback? onLibraryChanged;

  const LibraryBackupCard({
    super.key,
    required this.audioService,
    this.onLibraryChanged,
  });

  @override
  State<LibraryBackupCard> createState() => _LibraryBackupCardState();
}

class _LibraryBackupCardState extends State<LibraryBackupCard> {
  final TextEditingController _dirCtrl = TextEditingController();
  final TextEditingController _maxKeepCtrl = TextEditingController(text: '10');

  BackupSettings _settings = const BackupSettings();
  BackupScheduleMode _scheduleMode = BackupScheduleMode.off;
  List<BackupHistoryRecord> _history = const <BackupHistoryRecord>[];
  bool _loading = false;
  bool _busy = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAll());
  }

  @override
  void didUpdateWidget(covariant LibraryBackupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      unawaited(_loadAll());
    }
  }

  @override
  void dispose() {
    _dirCtrl.dispose();
    _maxKeepCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>(<Future<dynamic>>[
        widget.audioService.getBackupSettings(),
        widget.audioService.listBackupHistory(),
      ]);
      if (!mounted) return;
      final settings = results[0] as BackupSettings?;
      setState(() {
        if (settings != null) {
          _settings = settings;
          _dirCtrl.text = settings.backupDir;
          _scheduleMode = settings.scheduleMode;
          _maxKeepCtrl.text = settings.maxKeep.toString();
        }
        _history = results[1] as List<BackupHistoryRecord>;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSettings() async {
    if (_busy) return;
    final clampedKeep = (int.tryParse(_maxKeepCtrl.text.trim()) ?? 10).clamp(1, 100);
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final updated = await widget.audioService.updateBackupSettings(
        backupDir: _dirCtrl.text.trim(),
        scheduleMode: _scheduleMode,
        maxKeep: clampedKeep,
      );
      if (!mounted) return;
      setState(() {
        if (updated != null) {
          _settings = updated;
          _dirCtrl.text = updated.backupDir;
          _scheduleMode = updated.scheduleMode;
          _maxKeepCtrl.text = updated.maxKeep.toString();
          _statusIsError = false;
          _statusMessage = '已儲存備份設定（保留上限 ${updated.maxKeep} 份）。';
        } else {
          _statusIsError = true;
          _statusMessage = '儲存備份設定失敗，請稍後再試。';
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createBackupNow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final record = await widget.audioService.createLibraryBackup(
        triggerMode: BackupTriggerMode.manual,
      );
      if (!mounted) return;
      final history = await widget.audioService.listBackupHistory();
      if (!mounted) return;
      setState(() {
        _history = history;
        _statusIsError = record == null;
        _statusMessage = record != null
            ? '已建立熱備份（SHA-256: ${_shortHash(record.sha256)} · ${_fmtBytes(record.sizeBytes)}）。'
            : '建立熱備份失敗，請確認備份目錄權限。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmAndRestore(BackupHistoryRecord record) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (dialogCtx) => Dialog(
        key: const Key('dialog_confirm_backup_restore'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: FrostedGlassContainer(
            blurSigma: LuminaTokens.glassDialogBlur,
            color: LuminaTokens.glassDialogBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
            border: Border.all(color: LuminaTokens.glassCardBorder),
            padding: const EdgeInsets.all(LuminaTokens.spaceLg),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '確認還原曲庫備份？',
                    style: TextStyle(color: LuminaTokens.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: LuminaTokens.spaceXs),
                  Text(
                    '系統將先自動建立一份「還原前 (pre_restore)」安全備份，驗證 SHA-256 校驗碼 (${_shortHash(record.sha256)})，並重新連線 SQLite 資料庫與重新載入曲庫。',
                    style: const TextStyle(color: LuminaTokens.textSecondary, fontSize: 12.5, height: 1.45),
                  ),
                  const SizedBox(height: LuminaTokens.spaceLg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('btn_cancel_backup_restore'),
                        onPressed: () => Navigator.of(dialogCtx).pop(false),
                        style: TextButton.styleFrom(foregroundColor: LuminaTokens.glassTextSecondary),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: LuminaTokens.spaceXs),
                      FilledButton(
                        key: const Key('btn_confirm_backup_restore'),
                        onPressed: () => Navigator.of(dialogCtx).pop(true),
                        style: LuminaSettingsStyles.filledButtonStyle(),
                        child: const Text('確認還原'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final result = await widget.audioService.restoreLibraryBackup(record.backupPath);
      if (!mounted) return;
      final history = await widget.audioService.listBackupHistory();
      if (!mounted) return;
      if (result != null) widget.onLibraryChanged?.call();
      setState(() {
        _history = history;
        _statusIsError = result == null;
        _statusMessage = result != null
            ? '已還原備份 ${result.restoredBackupId} 並重新載入曲庫。'
            : '備份還原失敗，檔案可能已損毀或校驗失敗。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _shortHash(String hash) => hash.length > 12 ? hash.substring(0, 12) : hash;

  String _triggerLabel(BackupTriggerMode mode) => switch (mode) {
    BackupTriggerMode.manual => '手動',
    BackupTriggerMode.scheduled => '排程',
    BackupTriggerMode.preRestore => '還原前',
  };

  String _fmtBytes(int bytes) => bytes < 1024
      ? '$bytes B'
      : (bytes < 1024 * 1024
            ? '${(bytes / 1024).toStringAsFixed(1)} KB'
            : '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB');

  Widget _buildHistoryTile(BackupHistoryRecord r) {
    final canRestore = r.status == 'completed' && r.existsOnDisk && !_busy;
    return Container(
      key: Key('backup_history_row_${r.id}'),
      margin: const EdgeInsets.only(top: LuminaTokens.spaceXs),
      padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceSm, vertical: LuminaTokens.spaceXs),
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: LuminaTokens.glassNavActiveBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
              border: Border.all(color: LuminaTokens.glassPillBorder),
            ),
            child: Text(
              _triggerLabel(r.triggerMode),
              style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.createdAt.replaceFirst('T', ' ').split('.').first,
                  style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtBytes(r.sizeBytes)} · SHA-256 ${_shortHash(r.sha256)}'
                  '${r.status != 'completed' ? ' · ${r.status}' : ''}',
                  style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceSm),
          OutlinedButton(
            key: Key('btn_restore_backup_${r.id}'),
            onPressed: canRestore ? () => _confirmAndRestore(r) : null,
            style: LuminaSettingsStyles.outlinedButtonStyle(),
            child: const Text('還原', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const hPad = LuminaTokens.spaceMd + LuminaTokens.space2xs;
    final bannerColor = _statusIsError ? LuminaTokens.statusError : LuminaTokens.statusSuccess;
    return SettingsGroupCard(
      key: const Key('library_backup_card'),
      title: '資料庫熱備份、還原與匯出',
      description: '使用 SQLite WAL 線上快照建立一致性備份（含 SHA-256 校驗清單），並支援一鍵還原與曲庫清冊 / 音檔同步匯出。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(hPad, LuminaTokens.spaceXs, hPad, LuminaTokens.spaceSm),
          child: TextField(
            key: const Key('input_backup_dir'),
            controller: _dirCtrl,
            enabled: !_busy,
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: '備份存放目錄（留空使用預設路徑）',
              hintText: _settings.resolvedBackupDir.isNotEmpty
                  ? _settings.resolvedBackupDir
                  : '預設 AppData backups 資料夾',
            ),
          ),
        ),
        SettingsDropdownRow<BackupScheduleMode>(
          title: '自動排程備份',
          subtitle: '依設定週期於背景自動建立資料庫快照。',
          dropdownKey: const Key('dropdown_backup_schedule'),
          value: _scheduleMode,
          items: const <DropdownMenuItem<BackupScheduleMode>>[
            DropdownMenuItem(value: BackupScheduleMode.off, child: Text('關閉')),
            DropdownMenuItem(value: BackupScheduleMode.daily, child: Text('每日')),
            DropdownMenuItem(value: BackupScheduleMode.weekly, child: Text('每週')),
          ],
          onChanged: (mode) {
            if (mode != null && !_busy) setState(() => _scheduleMode = mode);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(hPad, LuminaTokens.spaceXs, hPad, LuminaTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: TextField(
                      key: const Key('input_backup_max_keep'),
                      controller: _maxKeepCtrl,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
                      decoration: LuminaSettingsStyles.inputDecoration(labelText: '保留份數上限', hintText: '10'),
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  OutlinedButton(
                    key: const Key('btn_save_backup_settings'),
                    onPressed: _busy ? null : _saveSettings,
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    child: const Text('儲存設定'),
                  ),
                ],
              ),
              const SizedBox(height: LuminaTokens.spaceMd),
              Wrap(
                spacing: LuminaTokens.spaceSm,
                runSpacing: LuminaTokens.spaceXs,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_create_backup_now'),
                    onPressed: _busy ? null : _createBackupNow,
                    style: LuminaSettingsStyles.filledButtonStyle(),
                    icon: const Icon(Icons.backup_rounded, size: 16),
                    label: const Text('立即建立熱備份'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_open_library_export'),
                    onPressed: () => LibraryExportDialog.show(context, audioService: widget.audioService),
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    icon: const Icon(Icons.ios_share_rounded, size: 16),
                    label: const Text('匯出曲庫清冊 / 音檔'),
                  ),
                ],
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: LuminaTokens.spaceSm),
                Container(
                  key: const Key('backup_status_banner'),
                  padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                  decoration: BoxDecoration(
                    color: bannerColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(color: bannerColor.withValues(alpha: 0.45)),
                  ),
                  child: Text(_statusMessage!, style: TextStyle(color: bannerColor, fontSize: 12)),
                ),
              ],
              const SizedBox(height: LuminaTokens.spaceMd),
              Text(
                _loading
                    ? '正在載入備份歷史紀錄...'
                    : (_history.isEmpty ? '尚無備份紀錄，可點擊「立即建立熱備份」建立第一份快照。' : '備份歷史紀錄（${_history.length} 筆）'),
                style: const TextStyle(color: LuminaTokens.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              for (final record in _history) _buildHistoryTile(record),
            ],
          ),
        ),
      ],
    );
  }
}
