import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../settings/settings_styles.dart';
import '../theme/lumina_tokens.dart';
import 'frosted_glass_container.dart';

enum _ExportMode { catalog, audio }

/// Reusable Frosted Glass dialog for CSV/JSON Catalog Export and async
/// Audio + relative `.m3u8` Sync Export with live progress & cancellation.
class LibraryExportDialog extends StatefulWidget {
  final AudioService audioService;
  final CatalogExportSource initialSource;
  final String? defaultPlaylistName;

  const LibraryExportDialog({
    super.key,
    required this.audioService,
    this.initialSource = const CatalogExportFocusQuerySource(FocusQuery()),
    this.defaultPlaylistName,
  });

  static Future<void> show(
    BuildContext context, {
    required AudioService audioService,
    CatalogExportSource initialSource = const CatalogExportFocusQuerySource(
      FocusQuery(),
    ),
    String? defaultPlaylistName,
  }) => showDialog<void>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) => LibraryExportDialog(
      audioService: audioService,
      initialSource: initialSource,
      defaultPlaylistName: defaultPlaylistName,
    ),
  );

  @override
  State<LibraryExportDialog> createState() => _LibraryExportDialogState();
}

class _LibraryExportDialogState extends State<LibraryExportDialog> {
  _ExportMode _mode = _ExportMode.catalog;
  CatalogExportFormat _format = CatalogExportFormat.csv;
  bool _utf8Bom = true;
  bool _generateM3u8 = true;
  bool _runningCatalog = false;
  bool _startingAudio = false;
  bool _cancellingAudio = false;
  CatalogExportResult? _catalogResult;
  AudioExportProgress? _audioProgress;
  String? _catalogError;
  String? _audioError;
  Timer? _pollTimer;

  late final TextEditingController _catalogPathCtrl = TextEditingController();
  late final TextEditingController _audioDirCtrl = TextEditingController();
  late final TextEditingController _playlistNameCtrl = TextEditingController(
    text: (widget.defaultPlaylistName?.trim().isNotEmpty == true)
        ? widget.defaultPlaylistName!.trim()
        : 'export.m3u8',
  );

  @override
  void dispose() {
    _pollTimer?.cancel();
    _catalogPathCtrl.dispose();
    _audioDirCtrl.dispose();
    _playlistNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _runCatalogExport() async {
    if (_runningCatalog) return;
    setState(() {
      _runningCatalog = true;
      _catalogError = null;
    });
    try {
      final res = await widget.audioService.exportCatalog(
        CatalogExportRequest(
          source: widget.initialSource,
          format: _format,
          outputPath: _catalogPathCtrl.text.trim(),
          includeHeaders: true,
          utf8Bom: _utf8Bom,
        ),
      );
      if (!mounted) return;
      setState(() {
        if (res == null) {
          _catalogError = '清冊匯出失敗，請檢查輸出路徑或稍後再試。';
        } else {
          _catalogResult = res;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _catalogError = '清冊匯出發生錯誤：$e');
    } finally {
      if (mounted) setState(() => _runningCatalog = false);
    }
  }

  Future<void> _runAudioExport() async {
    if (_startingAudio) return;
    final destDir = _audioDirCtrl.text.trim();
    if (destDir.isEmpty) {
      setState(() => _audioError = '請輸入目標匯出資料夾路徑。');
      return;
    }
    _pollTimer?.cancel();
    setState(() {
      _startingAudio = true;
      _audioError = null;
    });
    try {
      final rawName = _playlistNameCtrl.text.trim();
      final progress = await widget.audioService.startAudioExport(
        AudioExportRequest(
          source: widget.initialSource,
          destinationDir: destDir,
          generateM3u8: _generateM3u8,
          playlistFilename: rawName.isEmpty ? null : rawName,
        ),
      );
      if (!mounted) return;
      if (progress == null) {
        setState(() => _audioError = '無法啟動音檔同步匯出作業。');
        return;
      }
      setState(() => _audioProgress = progress);
      if (progress.status == AudioExportStatus.running) _startPolling(progress.jobId);
    } catch (e) {
      if (mounted) setState(() => _audioError = '啟動同步匯出失敗：$e');
    } finally {
      if (mounted) setState(() => _startingAudio = false);
    }
  }

  void _startPolling(String jobId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      final latest = await widget.audioService.getAudioExportProgress(jobId);
      if (!mounted) {
        _pollTimer?.cancel();
        return;
      }
      if (latest == null) return;
      setState(() => _audioProgress = latest);
      if (latest.status != AudioExportStatus.running) _pollTimer?.cancel();
    });
  }

  Future<void> _cancelAudioExport() async {
    final job = _audioProgress;
    if (job == null || _cancellingAudio) return;
    setState(() => _cancellingAudio = true);
    try {
      await widget.audioService.cancelAudioExport(job.jobId);
      final latest = await widget.audioService.getAudioExportProgress(job.jobId);
      if (mounted && latest != null) setState(() => _audioProgress = latest);
      _pollTimer?.cancel();
    } finally {
      if (mounted) setState(() => _cancellingAudio = false);
    }
  }

  String _fmtBytes(int b) => b < 1024
      ? '$b B'
      : (b < 1048576 ? '${(b / 1024).toStringAsFixed(1)} KB' : '${(b / 1048576).toStringAsFixed(2)} MB');

  String _audioStatusLabel(AudioExportStatus s) => switch (s) {
    AudioExportStatus.running => '同步匯出中...',
    AudioExportStatus.completed => '同步匯出完成',
    AudioExportStatus.cancelled => '已取消同步匯出',
    AudioExportStatus.failed => '同步匯出失敗',
  };

  Widget _glassCheckbox({
    required Key key,
    required bool value,
    required ValueChanged<bool?> onChanged,
    required String label,
  }) => CheckboxListTile(
    key: key,
    value: value,
    onChanged: onChanged,
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    activeColor: LuminaTokens.glassSwitchOnTrack,
    checkColor: LuminaTokens.onAccentDark,
    title: Text(label, style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5)),
  );

  Widget _buildCatalogTab() {
    final res = _catalogResult;
    final preview = res?.content?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('匯出格式', style: TextStyle(color: LuminaTokens.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(width: LuminaTokens.spaceSm),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LuminaSettingsStyles.frostedSegmentChip(
                    key: const Key('chip_export_format_csv'),
                    label: 'CSV',
                    selected: _format == CatalogExportFormat.csv,
                    onSelected: (_) => setState(() => _format = CatalogExportFormat.csv),
                  ),
                  const SizedBox(width: 4),
                  LuminaSettingsStyles.frostedSegmentChip(
                    key: const Key('chip_export_format_json'),
                    label: 'JSON',
                    selected: _format == CatalogExportFormat.json,
                    onSelected: (_) => setState(() => _format = CatalogExportFormat.json),
                  ),
                ],
              ),
            ),
          ],
        ),
        _glassCheckbox(
          key: const Key('chk_export_utf8_bom'),
          value: _utf8Bom,
          onChanged: (v) => setState(() => _utf8Bom = v == true),
          label: '加入 UTF-8 BOM 檔頭（確保 Excel 正確顯示中文）',
        ),
        TextField(
          key: const Key('input_catalog_output_path'),
          controller: _catalogPathCtrl,
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
          decoration: LuminaSettingsStyles.inputDecoration(
            labelText: '輸出檔案路徑（選填）',
            hintText: '留空將直接回傳預覽內容，例如 D:\\Exports\\catalog.csv',
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceMd),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('btn_run_catalog_export'),
            onPressed: _runningCatalog ? null : _runCatalogExport,
            style: LuminaSettingsStyles.filledButtonStyle(),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: const Text('開始匯出清冊'),
          ),
        ),
        if (_catalogError != null)
          Padding(
            padding: const EdgeInsets.only(top: LuminaTokens.spaceSm),
            child: Text(_catalogError!, style: const TextStyle(color: LuminaTokens.statusError, fontSize: 12)),
          ),
        if (res != null)
          Container(
            key: const Key('catalog_export_result'),
            margin: const EdgeInsets.only(top: LuminaTokens.spaceSm),
            padding: const EdgeInsets.all(LuminaTokens.spaceSm),
            decoration: BoxDecoration(
              color: LuminaTokens.statusSuccess.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              border: Border.all(color: LuminaTokens.statusSuccess.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '匯出完成：共 ${res.rowCount} 首曲目（${res.format.wireName.toUpperCase()} · ${_fmtBytes(res.sizeBytes)}）',
                  style: const TextStyle(color: LuminaTokens.statusSuccess, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                if (res.outputPath.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('檔案路徑：${res.outputPath}', style: const TextStyle(color: LuminaTokens.textSecondary, fontSize: 11.5)),
                  ),
                if (preview != null && preview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      preview.length > 260 ? '${preview.substring(0, 260)}...' : preview,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAudioTab() {
    final p = _audioProgress;
    final isRunning = p?.status == AudioExportStatus.running;
    final done = p == null ? 0 : p.copiedTracks + p.skippedTracks + p.failedTracks;
    final ratio = (p != null && p.totalTracks > 0) ? (done / p.totalTracks).clamp(0.0, 1.0) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('input_audio_export_dir'),
          controller: _audioDirCtrl,
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
          decoration: LuminaSettingsStyles.inputDecoration(
            labelText: '目標同步資料夾（DAP / SD 卡 / 本機目錄）',
            hintText: '例如 E:\\DAP_Music\\Favorites',
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        TextField(
          key: const Key('input_audio_playlist_name'),
          controller: _playlistNameCtrl,
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
          decoration: LuminaSettingsStyles.inputDecoration(labelText: '播放清單檔名（.m3u8）', hintText: 'export.m3u8'),
        ),
        _glassCheckbox(
          key: const Key('chk_audio_generate_m3u8'),
          value: _generateM3u8,
          onChanged: (v) => setState(() => _generateM3u8 = v == true),
          label: '產生相對路徑 .m3u8 播放清單',
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (isRunning) ...[
              OutlinedButton(
                key: const Key('btn_cancel_audio_export'),
                onPressed: _cancellingAudio ? null : _cancelAudioExport,
                style: LuminaSettingsStyles.outlinedButtonStyle(),
                child: const Text('取消匯出'),
              ),
              const SizedBox(width: LuminaTokens.spaceXs),
            ],
            FilledButton.icon(
              key: const Key('btn_run_audio_export'),
              onPressed: (_startingAudio || isRunning) ? null : _runAudioExport,
              style: LuminaSettingsStyles.filledButtonStyle(),
              icon: const Icon(Icons.drive_file_move_rounded, size: 16),
              label: const Text('開始同步匯出'),
            ),
          ],
        ),
        if (_audioError != null)
          Padding(
            padding: const EdgeInsets.only(top: LuminaTokens.spaceSm),
            child: Text(_audioError!, style: const TextStyle(color: LuminaTokens.statusError, fontSize: 12)),
          ),
        if (p != null)
          Container(
            key: const Key('audio_export_progress_panel'),
            margin: const EdgeInsets.only(top: LuminaTokens.spaceSm),
            padding: const EdgeInsets.all(LuminaTokens.spaceSm),
            decoration: BoxDecoration(
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_audioStatusLabel(p.status), style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: p.status == AudioExportStatus.completed ? 1.0 : ratio,
                  backgroundColor: LuminaTokens.glassCardDivider,
                  color: LuminaTokens.glassSwitchOnTrack,
                ),
                const SizedBox(height: 6),
                Text(
                  '已複製 ${p.copiedTracks} 首 · 略過 ${p.skippedTracks} 首 · 失敗 ${p.failedTracks} 首（共 ${p.totalTracks} 首，${_fmtBytes(p.bytesCopied)}）',
                  style: const TextStyle(color: LuminaTokens.textSecondary, fontSize: 11.5),
                ),
                if (p.currentFile != null && p.currentFile!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('目前檔案：${p.currentFile}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11)),
                  ),
                if (p.m3u8Path != null && p.m3u8Path!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('.m3u8 清單：${p.m3u8Path}', style: const TextStyle(color: LuminaTokens.statusSuccess, fontSize: 11.5)),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('library_export_dialog'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '匯出曲庫清冊與音檔同步',
                          style: TextStyle(color: LuminaTokens.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: LuminaSettingsStyles.iconButtonStyle(),
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                  const SizedBox(height: LuminaTokens.spaceSm),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
                    child: Row(
                      children: [
                        Expanded(
                          child: LuminaSettingsStyles.frostedSegmentChip(
                            key: const Key('tab_export_catalog'),
                            label: '清冊匯出 (CSV / JSON)',
                            selected: _mode == _ExportMode.catalog,
                            onSelected: (_) => setState(() => _mode = _ExportMode.catalog),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: LuminaSettingsStyles.frostedSegmentChip(
                            key: const Key('tab_export_audio'),
                            label: '音檔同步匯出 (Audio + .m3u8)',
                            selected: _mode == _ExportMode.audio,
                            onSelected: (_) => setState(() => _mode = _ExportMode.audio),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceMd),
                  if (_mode == _ExportMode.catalog) _buildCatalogTab() else _buildAudioTab(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
