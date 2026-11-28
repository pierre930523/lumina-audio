part of 'track_info_editor_dialog.dart';

extension _TrackInfoEditorOptionsTab on _TrackInfoEditorDialogState {
  Widget _buildOptionsTab() {
    final info = _fileInfo;
    final isHidden = info?.isHidden ?? false;
    final isLocal = info?.isLocalFile ?? !AudioService.isStreamingTrackId(widget.track.id);
    final peaks = info?.waveformPeaks ?? const <double>[];

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 6, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionBox(
            title: '可見性',
            children: [
              SwitchListTile(
                key: const Key('switch_track_editor_hidden'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  '隱藏此曲目',
                  style: TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: const Text(
                  '啟用後，曲庫列表、專輯詳情、Focus 與搜尋將隱藏此曲目（可於設定開啟「顯示隱藏項目」檢視）',
                  style: TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
                ),
                value: isHidden,
                onChanged: _busy ? null : _toggleHidden,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SectionBox(
            title: '您的檔案',
            children: [
              _ActionTile(
                key: const Key('btn_track_rescan'),
                icon: Icons.refresh_rounded,
                title: '重新掃描曲目',
                subtitle: '從音訊檔案重新讀取內嵌標籤與封面（保留手動編輯欄位）',
                enabled: !_busy && isLocal,
                onTap: _runRescan,
              ),
              const Divider(height: 1, color: LuminaTokens.borderSubtle),
              _ActionTile(
                key: const Key('btn_track_reidentify'),
                icon: Icons.auto_awesome_rounded,
                title: '重新識別曲目',
                subtitle: '從 MusicBrainz / Discogs 雲端補齊詮釋資料（絕不覆蓋手動編輯）',
                enabled: !_busy,
                onTap: _runReidentify,
              ),
              const Divider(height: 1, color: LuminaTokens.borderSubtle),
              _ActionTile(
                key: const Key('btn_track_reanalyze'),
                icon: Icons.graphic_eq_rounded,
                title: '重新分析曲目',
                subtitle: '執行音訊損毀檢查、ReplayGain / LUFS 響度與 64 段波形峰値計算',
                enabled: !_busy && isLocal,
                onTap: _runReanalyze,
              ),
              if (info != null &&
                  (info.corruptionStatus != TrackCorruptionStatus.unchecked ||
                      peaks.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: _buildAnalysisSummaryCard(info, peaks),
                ),
              const Divider(height: 1, color: LuminaTokens.borderSubtle),
              _ActionTile(
                key: const Key('btn_track_delete'),
                icon: Icons.delete_outline_rounded,
                title: '刪除曲目',
                subtitle: '從曲庫移除此曲目，或將本地音訊檔案移至系統資源回收桶',
                destructive: true,
                enabled: !_busy,
                onTap: _confirmDeleteTrack,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisSummaryCard(TrackFileInfo info, List<double> peaks) {
    final isOk = info.corruptionStatus == TrackCorruptionStatus.ok;
    final statusColor = isOk
        ? LuminaTokens.statusSuccess
        : (info.corruptionStatus == TrackCorruptionStatus.unchecked
              ? LuminaTokens.textMuted
              : LuminaTokens.statusError);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: LuminaTokens.cardBg.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: LuminaTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isOk ? Icons.verified_rounded : Icons.warning_amber_rounded,
                size: 15,
                color: statusColor,
              ),
              const SizedBox(width: 6),
              Text(
                info.corruptionStatus.displayLabel,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (info.integratedLufs != null)
                Text(
                  '${info.integratedLufs!.toStringAsFixed(1)} LUFS · ${(info.truePeakDb ?? 0).toStringAsFixed(1)} dBTP',
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
          if (peaks.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              width: double.infinity,
              child: CustomPaint(
                key: const Key('track_waveform_preview'),
                painter: _TrackWaveformPainter(peaks),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggleHidden(bool nextHidden) async {
    _setBusyAndStatus(busy: true);
    try {
      final res = await widget.audioService.setTrackHidden(
        widget.track.id,
        nextHidden,
      );
      final updated = await widget.audioService.getTrackFileInfo(
        widget.track.id,
      );
      if (!mounted) return;
      _setBusyAndStatus(
        busy: false,
        fileInfo: updated,
        status: res == null
            ? '更新隱藏狀態失敗'
            : (res.isHidden ? '已隱藏此曲目' : '已取消隱藏此曲目'),
        isError: res == null,
      );
      if (res != null) _emitTrackUpdated(updated);
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '更新隱藏狀態失敗：$e', isError: true);
    }
  }

  Future<void> _runRescan() async {
    _setBusyAndStatus(busy: true);
    try {
      final info = await widget.audioService.rescanTrack(widget.track.id);
      if (!mounted) return;
      _setBusyAndStatus(
        busy: false,
        fileInfo: info,
        syncForm: true,
        status: info != null ? '已重新掃描檔案標籤與封面' : '重新掃描失敗',
        isError: info == null,
      );
      if (info != null) _emitTrackUpdated(info);
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '重新掃描失敗：$e', isError: true);
    }
  }

  Future<void> _runReidentify() async {
    _setBusyAndStatus(busy: true);
    try {
      final res = await widget.audioService.reidentifyTrack(widget.track.id);
      final updated =
          res?.fileInfo ??
          await widget.audioService.getTrackFileInfo(widget.track.id);
      if (!mounted) return;
      _setBusyAndStatus(
        busy: false,
        fileInfo: updated,
        syncForm: true,
        status: res == null
            ? '重新識別失敗'
            : (res.matched
                  ? '已透過 ${res.source ?? "雲端資料庫"} 更新識別資料（保留手動編輯）'
                  : (res.message ?? '找不到匹配的雲端曲目記錄')),
        isError: res == null,
      );
      if (res != null && res.matched) _emitTrackUpdated(updated);
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '重新識別失敗：$e', isError: true);
    }
  }

  Future<void> _runReanalyze() async {
    _setBusyAndStatus(busy: true);
    try {
      final res = await widget.audioService.reanalyzeTrack(widget.track.id);
      final updated = await widget.audioService.getTrackFileInfo(
        widget.track.id,
      );
      if (!mounted) return;
      _setBusyAndStatus(
        busy: false,
        fileInfo: updated,
        status: res == null
            ? '分析音訊失敗'
            : '分析完成：${res.corruptionStatus.displayLabel}',
        isError: res == null || res.corruptionStatus == TrackCorruptionStatus.corrupt,
      );
      if (res != null) _emitTrackUpdated(updated);
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '分析音訊失敗：$e', isError: true);
    }
  }

  Future<void> _confirmDeleteTrack() async {
    final isLocal = _fileInfo?.isLocalFile ?? !AudioService.isStreamingTrackId(widget.track.id);
    final chosenMode = await showDialog<TrackDeleteMode>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => AlertDialog(
        key: const Key('track_delete_mode_dialog'),
        backgroundColor: LuminaTokens.cardBg,
        title: const Text(
          '刪除曲目',
          style: TextStyle(color: LuminaTokens.textPrimary, fontSize: 16),
        ),
        content: Text(
          '請選擇要從曲庫移除「${widget.track.title}」的方式：',
          style: const TextStyle(color: LuminaTokens.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          OutlinedButton(
            key: const Key('btn_delete_library_only'),
            onPressed: () => Navigator.of(ctx).pop(TrackDeleteMode.libraryOnly),
            child: const Text('僅從曲庫移除（保留檔案）'),
          ),
          if (isLocal)
            FilledButton(
              key: const Key('btn_delete_move_to_trash'),
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.statusError,
                foregroundColor: LuminaTokens.onAccentDark,
              ),
              onPressed: () => Navigator.of(ctx).pop(TrackDeleteMode.moveToTrash),
              child: const Text('移至資源回收桶'),
            ),
        ],
      ),
    );
    if (!mounted || chosenMode == null) return;

    if (chosenMode == TrackDeleteMode.moveToTrash) {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierColor: LuminaTokens.scrimBg,
        builder: (ctx) => AlertDialog(
          key: const Key('track_delete_trash_confirm_dialog'),
          backgroundColor: LuminaTokens.cardBg,
          title: const Text(
            '再次確認：移至系統資源回收桶',
            style: TextStyle(color: LuminaTokens.statusError, fontSize: 16),
          ),
          content: Text(
            '此動作將從曲庫刪除記錄，並把磁碟檔案：\n${_fileInfo?.filePath ?? widget.track.filePath ?? ""}\n移至系統資源回收桶。確定繼續？',
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('返回'),
            ),
            FilledButton(
              key: const Key('btn_confirm_trash_delete'),
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.statusError,
                foregroundColor: LuminaTokens.onAccentDark,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('確定移至資源回收桶'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }

    _setBusyAndStatus(busy: true);
    try {
      final res = await widget.audioService.deleteTrack(
        widget.track.id,
        mode: chosenMode,
      );
      if (!mounted) return;
      if (res != null && res.deletedFromLibrary) {
        if (widget.libraryCache != null) {
          unawaited(widget.libraryCache!.refresh(widget.audioService));
        }
        widget.onTrackDeleted?.call();
        Navigator.of(context).pop();
      } else {
        _setBusyAndStatus(
          busy: false,
          status: res?.warning ?? '刪除曲目失敗',
          isError: true,
        );
      }
    } catch (e) {
      _setBusyAndStatus(busy: false, status: '刪除曲目失敗：$e', isError: true);
    }
  }
}

class _SectionBox extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SectionBox({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LuminaTokens.cardElevatedBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: LuminaTokens.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: LuminaTokens.accentBlue,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final bool destructive;
  final VoidCallback onTap;

  const _ActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? LuminaTokens.textDisabled
        : (destructive ? LuminaTokens.statusError : LuminaTokens.textPrimary);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(icon, color: color, size: 19),
      title: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
      ),
      onTap: enabled ? onTap : null,
    );
  }
}

class _TrackWaveformPainter extends CustomPainter {
  final List<double> peaks;

  _TrackWaveformPainter(this.peaks);

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0 || size.height <= 0) return;
    final barPaint = Paint()
      ..color = LuminaTokens.accentBlue.withValues(alpha: 0.85)
      ..strokeCap = StrokeCap.round;
    final step = size.width / peaks.length;
    barPaint.strokeWidth = math.max(1.5, step * 0.55);
    final midY = size.height / 2;
    for (var i = 0; i < peaks.length; i++) {
      final amp = peaks[i].clamp(0.05, 1.0);
      final halfH = (size.height * 0.45) * amp;
      final x = (i + 0.5) * step;
      canvas.drawLine(Offset(x, midY - halfH), Offset(x, midY + halfH), barPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TrackWaveformPainter oldDelegate) =>
      oldDelegate.peaks != peaks;
}
