import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/ingestion_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

/// Self-contained Settings card for "Clean Up Library (清理曲庫)" with read-only
/// preview counts, offline-root protection notice, per-category checkboxes, and
/// frosted-glass confirmation dialog before executing cleanup.
class LibraryCleanupCard extends StatefulWidget {
  final AudioService audioService;
  final VoidCallback? onLibraryChanged;

  const LibraryCleanupCard({
    super.key,
    required this.audioService,
    this.onLibraryChanged,
  });

  @override
  State<LibraryCleanupCard> createState() => _LibraryCleanupCardState();
}

class _LibraryCleanupCardState extends State<LibraryCleanupCard> {
  LibraryCleanupPreview _preview = const LibraryCleanupPreview();
  bool _loadingPreview = false;
  bool _executing = false;
  bool _removeMissingTracks = true;
  bool _removeEmptyAlbums = true;
  bool _removeOrphanArtists = true;
  bool _removeOrphanArtworkCache = true;
  String? _resultSummary;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPreview());
  }

  @override
  void didUpdateWidget(covariant LibraryCleanupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.audioService, widget.audioService)) {
      unawaited(_loadPreview());
    }
  }

  Future<void> _loadPreview() async {
    if (!mounted) return;
    setState(() => _loadingPreview = true);
    try {
      final preview = await widget.audioService.previewLibraryCleanup();
      if (!mounted) return;
      setState(() => _preview = preview);
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _loadingPreview = false);
      }
    }
  }

  LibraryCleanupOptions get _effectiveOptions => LibraryCleanupOptions(
    removeMissingTracks:
        _removeMissingTracks && _preview.missingTracksCount > 0,
    removeEmptyAlbums:
        _removeEmptyAlbums && _preview.emptyAlbumsAndVersionsTotal > 0,
    removeOrphanArtists:
        _removeOrphanArtists && _preview.orphanArtistsCount > 0,
    removeOrphanArtworkCache:
        _removeOrphanArtworkCache && _preview.orphanArtworkFilesCount > 0,
  );

  bool get _canExecute =>
      !_loadingPreview && !_executing && _effectiveOptions.hasAnySelected;

  Future<void> _confirmAndExecute() async {
    final opts = _effectiveOptions;
    if (!opts.hasAnySelected) return;

    final summaryLines = <String>[
      if (opts.removeMissingTracks)
        '• 遺失曲目（僅限在線資料夾）：${_preview.missingTracksCount} 首',
      if (opts.removeEmptyAlbums)
        '• 空專輯版本與空專輯：${_preview.emptyAlbumVersionsCount} 個版本 / ${_preview.emptyAlbumsCount} 張專輯',
      if (opts.removeOrphanArtists)
        '• 孤立藝術家：${_preview.orphanArtistsCount} 位',
      if (opts.removeOrphanArtworkCache)
        '• 未引用的本機封面快取：${_preview.orphanArtworkFilesCount} 個檔案（${_preview.formattedArtworkBytes}）',
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (dialogCtx) => Dialog(
        key: const Key('dialog_confirm_library_cleanup'),
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
                    '確認執行清理曲庫？',
                    style: TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceXs),
                  const Text(
                    '此操作僅移除資料庫無效紀錄與未引用封面快取，不會刪除您的本機音訊檔案，亦不會清除目前離線資料夾中的曲目。',
                    style: TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceSm),
                  Container(
                    padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                    decoration: BoxDecoration(
                      color: LuminaTokens.glassPillBg,
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      border: Border.all(color: LuminaTokens.glassCardBorder),
                    ),
                    child: Text(
                      summaryLines.join('\n'),
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 12.5,
                        height: 1.55,
                      ),
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceLg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('btn_cancel_library_cleanup'),
                        onPressed: () => Navigator.of(dialogCtx).pop(false),
                        style: TextButton.styleFrom(
                          foregroundColor: LuminaTokens.glassTextSecondary,
                        ),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: LuminaTokens.spaceXs),
                      FilledButton(
                        key: const Key('btn_confirm_library_cleanup'),
                        onPressed: () => Navigator.of(dialogCtx).pop(true),
                        style: LuminaSettingsStyles.filledButtonStyle(),
                        child: const Text('確認清理'),
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
      _executing = true;
      _resultSummary = null;
    });
    try {
      final result = await widget.audioService.executeLibraryCleanup(opts);
      if (!mounted) return;
      widget.onLibraryChanged?.call();
      await _loadPreview();
      if (!mounted) return;
      setState(() {
        _resultSummary =
            '清理完成：移除 ${result.removedTracks} 首遺失曲目、'
            '${result.removedAlbumVersions} 個空版本、'
            '${result.removedAlbums} 張空專輯、'
            '${result.removedArtists} 位孤立藝術家、'
            '${result.removedArtworkFiles} 個未引用封面快取。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resultSummary = '清理曲庫時發生錯誤，請稍後再試。';
      });
    } finally {
      if (mounted) {
        setState(() => _executing = false);
      }
    }
  }

  Widget _buildCategoryCheckbox({
    required Key checkboxKey,
    required String title,
    required String subtitle,
    required String countLabel,
    required int count,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final enabled = count > 0 && !_executing;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        hoverColor: LuminaTokens.glassRowHoverBg,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: LuminaTokens.spaceXs,
            horizontal: LuminaTokens.spaceXs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    key: checkboxKey,
                    value: enabled && value,
                    onChanged: enabled ? (v) => onChanged(v == true) : null,
                    activeColor: LuminaTokens.glassSwitchOnTrack,
                    checkColor: LuminaTokens.onAccentDark,
                    side: BorderSide(
                      color: enabled
                          ? LuminaTokens.glassPillBorder
                          : LuminaTokens.glassSidebarBorder,
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: enabled
                            ? LuminaTokens.textPrimary
                            : LuminaTokens.textMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceSm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: count > 0
                      ? LuminaTokens.glassPillBg
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                  border: Border.all(
                    color: count > 0
                        ? LuminaTokens.glassPillBorder
                        : LuminaTokens.glassCardDivider,
                  ),
                ),
                child: Text(
                  countLabel,
                  style: TextStyle(
                    color: count > 0
                        ? LuminaTokens.glassTextPrimary
                        : LuminaTokens.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsGroupCard(
      key: const Key('library_cleanup_section'),
      title: '清理曲庫',
      description:
          '預覽並選擇性移除已刪除的遺失檔案紀錄、0 曲目空專輯、孤立藝術家與未引用本機封面快取。所有離線的外接硬碟或 NAS 資料夾均受到保護。',
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _loadingPreview
                        ? '正在計算可清理項目...'
                        : (_preview.totalCleanableCount == 0
                              ? '曲庫狀態良好，目前沒有需要清理的項目'
                              : '偵測到 ${_preview.totalCleanableCount} 個可清理項目'),
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('btn_refresh_cleanup_preview'),
                    onPressed: (_loadingPreview || _executing)
                        ? null
                        : _loadPreview,
                    icon: const Icon(Icons.refresh_rounded, size: 15),
                    label: const Text('重新預覽'),
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      minimumSize: const Size(0, 30),
                    ),
                  ),
                ],
              ),
              if (_preview.offlineRoots.isNotEmpty) ...[
                const SizedBox(height: LuminaTokens.spaceXs),
                Container(
                  key: const Key('cleanup_offline_roots_banner'),
                  padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                  decoration: BoxDecoration(
                    color: LuminaTokens.statusWarning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(
                      color: LuminaTokens.statusWarning.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        size: 16,
                        color: LuminaTokens.statusWarning,
                      ),
                      const SizedBox(width: LuminaTokens.spaceXs),
                      Expanded(
                        child: Text(
                          '已保護 ${_preview.offlineRoots.length} 個離線根目錄（不會誤刪其曲目）：${_preview.offlineRoots.join('、')}',
                          style: const TextStyle(
                            color: LuminaTokens.statusWarning,
                            fontSize: 11.5,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: LuminaTokens.spaceXs),
              _buildCategoryCheckbox(
                checkboxKey: const Key('chk_cleanup_missing_tracks'),
                title: '已不存在的遺失檔案（僅限在線資料夾）',
                subtitle: '僅清理目前可存取資料夾中磁碟檔案已刪除的曲目紀錄。',
                countLabel: '${_preview.missingTracksCount} 首',
                count: _preview.missingTracksCount,
                value: _removeMissingTracks,
                onChanged: (v) => setState(() => _removeMissingTracks = v),
              ),
              _buildCategoryCheckbox(
                checkboxKey: const Key('chk_cleanup_empty_albums'),
                title: '空專輯版本與空專輯',
                subtitle: '清理旗下已無任何有效曲目的專輯版本與標準專輯。',
                countLabel:
                    '${_preview.emptyAlbumVersionsCount} 版本 / ${_preview.emptyAlbumsCount} 專輯',
                count: _preview.emptyAlbumsAndVersionsTotal,
                value: _removeEmptyAlbums,
                onChanged: (v) => setState(() => _removeEmptyAlbums = v),
              ),
              _buildCategoryCheckbox(
                checkboxKey: const Key('chk_cleanup_orphan_artists'),
                title: '孤立藝術家',
                subtitle: '移除不再關聯任何專輯、曲目或演職人員名單的藝術家紀錄。',
                countLabel: '${_preview.orphanArtistsCount} 位',
                count: _preview.orphanArtistsCount,
                value: _removeOrphanArtists,
                onChanged: (v) => setState(() => _removeOrphanArtists = v),
              ),
              _buildCategoryCheckbox(
                checkboxKey: const Key('chk_cleanup_orphan_artwork'),
                title: '未引用的本機封面快取檔案',
                subtitle: '刪除快取目錄中已無資料庫關聯的殘留封面圖片檔案。',
                countLabel:
                    '${_preview.orphanArtworkFilesCount} 檔 (${_preview.formattedArtworkBytes})',
                count: _preview.orphanArtworkFilesCount,
                value: _removeOrphanArtworkCache,
                onChanged: (v) => setState(() => _removeOrphanArtworkCache = v),
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_execute_library_cleanup'),
                    onPressed: _canExecute ? _confirmAndExecute : null,
                    style: LuminaSettingsStyles.filledButtonStyle(),
                    icon: _executing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: LuminaTokens.onAccentDark,
                            ),
                          )
                        : const Icon(Icons.cleaning_services_rounded, size: 16),
                    label: const Text('清理已勾選項目'),
                  ),
                ],
              ),
              if (_resultSummary != null) ...[
                const SizedBox(height: LuminaTokens.spaceSm),
                Container(
                  key: const Key('cleanup_result_banner'),
                  padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                  decoration: BoxDecoration(
                    color: LuminaTokens.statusSuccess.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(
                      color: LuminaTokens.statusSuccess.withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    _resultSummary!,
                    style: const TextStyle(
                      color: LuminaTokens.statusSuccess,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
