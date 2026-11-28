part of 'library_settings_panel.dart';

extension _LibrarySettingsQuarantineWidgetsExt on _LibrarySettingsPanelState {
  Future<void> _handleRescanAllSkipped() async {
    if (_rescanningSkipped || _skippedFiles.isEmpty) return;
    _updateState(() => _rescanningSkipped = true);
    try {
      final result = await widget.audioService.rescanAllSkippedFiles();
      if (!mounted) return;
      await _loadSkippedFiles();
      if (result.resolved > 0 || result.removedMissing > 0) {
        widget.onLibraryChanged?.call();
      }
      if (!mounted) return;
      _updateState(() {
        _actionStatus =
            '已重新掃描 ${result.total} 個略過檔案：'
            '成功匯入 ${result.resolved}、移除已刪除 ${result.removedMissing}、'
            '仍略過 ${result.stillSkipped}';
      });
    } finally {
      if (mounted) {
        _updateState(() => _rescanningSkipped = false);
      }
    }
  }

  Color _skipReasonBadgeColor(SkipReason reason) => switch (reason) {
    SkipReason.corruptHeader ||
    SkipReason.permissionDenied => LuminaTokens.statusError,
    SkipReason.unsupportedFormat ||
    SkipReason.unsplitCueOrIso ||
    SkipReason.garbledTags => LuminaTokens.statusWarning,
    SkipReason.ioError => LuminaTokens.textSecondary,
  };

  Widget _buildSkipReasonBadge(SkippedFileRecord item) {
    final accent = _skipReasonBadgeColor(item.reason);
    return Container(
      key: Key('skipped_reason_badge_${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Text(
        item.reason.displayLabel,
        style: TextStyle(
          color: accent,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildSkippedFilesCard() {
    return SettingsGroupCard(
      key: const Key('skipped_files_section'),
      title: '已略過的檔案 (${_skippedFiles.length})',
      description: '掃描時因格式不支援、標頭損毀、權限不足或 I/O 錯誤而略過的檔案清單，不影響其餘曲目入庫。',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceMd + LuminaTokens.space2xs,
            LuminaTokens.spaceXs,
            LuminaTokens.spaceMd + LuminaTokens.space2xs,
            LuminaTokens.spaceMd,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: LuminaTokens.spaceXs,
                runSpacing: LuminaTokens.space2xs,
                children: [
                  Text(
                    _skippedFiles.isEmpty
                        ? '目前沒有被隔離的略過檔案'
                        : '共 ${_skippedFiles.length} 個已略過項目',
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_skippedFiles.isNotEmpty)
                        OutlinedButton.icon(
                          key: const Key('btn_rescan_all_skipped_files'),
                          onPressed: _rescanningSkipped
                              ? null
                              : _handleRescanAllSkipped,
                          icon: _rescanningSkipped
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: LuminaTokens.glassTextPrimary,
                                  ),
                                )
                              : const Icon(Icons.replay_rounded, size: 15),
                          label: const Text(
                            '全部重新掃描',
                            style: TextStyle(fontSize: 12),
                          ),
                          style: LuminaSettingsStyles.outlinedButtonStyle(),
                        ),
                      const SizedBox(width: LuminaTokens.spaceXs),
                      TextButton.icon(
                        key: const Key('btn_refresh_skipped_files'),
                        onPressed: _loadingSkipped ? null : _loadSkippedFiles,
                        icon: const Icon(Icons.refresh_rounded, size: 15),
                        label: const Text('重新整理'),
                        style: TextButton.styleFrom(
                          foregroundColor: LuminaTokens.glassTextPrimary,
                          minimumSize: const Size(0, 30),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              for (final item in _skippedFiles)
                Padding(
                  padding: const EdgeInsets.only(
                    top: LuminaTokens.spaceXs,
                  ),
                  child: Container(
                    key: Key('skipped_file_${item.id}'),
                    padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                    decoration: BoxDecoration(
                      color: LuminaTokens.glassPillBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                      border: Border.all(
                        color: LuminaTokens.glassCardBorder,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: _skipReasonBadgeColor(item.reason),
                        ),
                        const SizedBox(width: LuminaTokens.spaceSm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSkipReasonBadge(item),
                              const SizedBox(height: 4),
                              Text(
                                item.filePath,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (item.detail.isNotEmpty ||
                                  item.lastSeenAt.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    [
                                      if (item.detail.isNotEmpty) item.detail,
                                      if (item.lastSeenAt.isNotEmpty)
                                        item.lastSeenAt,
                                    ].join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: LuminaTokens.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        TextButton(
                          key: Key('btn_retry_skipped_${item.id}'),
                          onPressed: () => _handleRetrySkipped(item),
                          style: TextButton.styleFrom(
                            foregroundColor: LuminaTokens.glassTextPrimary,
                            minimumSize: const Size(0, 30),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                          ),
                          child: const Text('重試'),
                        ),
                        TextButton(
                          key: Key('btn_dismiss_skipped_${item.id}'),
                          onPressed: () => _handleDismissSkipped(item),
                          style: TextButton.styleFrom(
                            foregroundColor: LuminaTokens.textMuted,
                            minimumSize: const Size(0, 30),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                          ),
                          child: const Text('忽略'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScanProgressCard(ScanProgressEvent progress) {
    final total = progress.totalEstimated;
    final double? fraction = progress.state == ScanLifecycleState.completed
        ? 1.0
        : (total != null && total > 0
              ? (progress.scanned / total).clamp(0.0, 1.0)
              : null);
    final stateLabel = switch (progress.state) {
      ScanLifecycleState.idle => '待命',
      ScanLifecycleState.discovering => '探索目錄中',
      ScanLifecycleState.probing => '解析音訊標頭',
      ScanLifecycleState.persisting => '寫入資料庫',
      ScanLifecycleState.watching => '即時監控中',
      ScanLifecycleState.completed => '掃描完成',
      ScanLifecycleState.failed => '掃描失敗',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LuminaTokens.spaceMd + LuminaTokens.space2xs,
        0,
        LuminaTokens.spaceMd + LuminaTokens.space2xs,
        LuminaTokens.spaceSm,
      ),
      child: Container(
        key: const Key('ingestion_scan_progress_card'),
        padding: const EdgeInsets.all(LuminaTokens.spaceSm),
        decoration: BoxDecoration(
          color: LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(color: LuminaTokens.glassCardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '$stateLabel · ${progress.rootPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  total != null && total > 0
                      ? '${progress.scanned} / $total'
                      : '${progress.scanned}',
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 4,
                backgroundColor: LuminaTokens.glassCardDivider,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  LuminaTokens.glassSwitchOnTrack,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '已掃描 ${progress.scanned} · 新增 ${progress.added} · 更新 ${progress.updated} · 略過 ${progress.skipped}',
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 11.5,
              ),
            ),
            if (progress.currentPath != null &&
                progress.currentPath!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  progress.currentPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWatchModeBadge(String folderPath, WatchedRootRecord? watched) {
    final mode = watched?.watchMode ??
        LibrarySettingsController.inferWatchModeForPath(folderPath);
    final isOffline = watched != null && !watched.isOnline;
    final label = isOffline
        ? 'Offline'
        : switch (mode) {
            WatchMode.nativeOs => 'OS Native',
            WatchMode.nasPolling => 'NAS Polling',
            WatchMode.manual => 'Manual',
          };
    final accentColor = isOffline
        ? const Color(0xFFE57373)
        : (mode == WatchMode.nasPolling
              ? const Color(0xFF64B5F6)
              : LuminaTokens.statusSuccess);

    return Container(
      key: Key('watch_badge_$folderPath'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: accentColor.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accentColor,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildStatusBanner(String text) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceMd,
          vertical: LuminaTokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: LuminaTokens.statusSuccess.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: LuminaTokens.statusSuccess.withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.check_circle_outline_rounded,
              color: LuminaTokens.statusSuccess,
              size: 18,
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: LuminaTokens.statusSuccess,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
