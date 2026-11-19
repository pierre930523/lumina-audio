import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/library_settings_controller.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

class LibrarySettingsPanel extends StatefulWidget {
  final AudioService audioService;
  final LibrarySettingsController settingsController;
  final VoidCallback? onLibraryChanged;

  const LibrarySettingsPanel({
    super.key,
    required this.audioService,
    required this.settingsController,
    this.onLibraryChanged,
  });

  @override
  State<LibrarySettingsPanel> createState() => _LibrarySettingsPanelState();
}

class _LibrarySettingsPanelState extends State<LibrarySettingsPanel> {
  static const _dividerColor = LuminaTokens.borderSubtle;

  final TextEditingController _scanController = TextEditingController();
  late Set<String> _draftExcluded;
  bool _isScanning = false;
  String? _scanStatus;
  String? _actionStatus;

  @override
  void initState() {
    super.initState();
    _draftExcluded = Set<String>.from(
      widget.settingsController.excludedExtensions,
    );
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _scanPath(String rawPath) async {
    final path = rawPath.trim();
    if (path.isEmpty) return;
    setState(() => _isScanning = true);
    try {
      final count = await widget.audioService.scanDirectory(path);
      widget.settingsController.addOrUpdateFolder(path, count);
      widget.onLibraryChanged?.call();
      if (!mounted) return;
      setState(() {
        _scanStatus = '已掃描「$path」，收錄 $count 首曲目';
      });
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _pickAndFillFolder() async {
    final chosen = await widget.settingsController.pickFolderNative();
    if (!mounted || chosen == null || chosen.isEmpty) return;
    _scanController.text = chosen;
    await _scanPath(chosen);
  }

  Future<void> _rescanAllFolders() async {
    final folders = widget.settingsController.folders;
    if (folders.isEmpty) return;
    setState(() => _isScanning = true);
    try {
      var latestCount = 0;
      for (final f in folders) {
        latestCount = await widget.audioService.scanDirectory(f.path);
        widget.settingsController.addOrUpdateFolder(f.path, latestCount);
      }
      widget.onLibraryChanged?.call();
      if (!mounted) return;
      setState(() {
        _scanStatus = '已完成全部 ${folders.length} 個資料夾重新掃描（共 $latestCount 首）';
      });
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  bool get _hasExcludedChanges {
    final saved = widget.settingsController.excludedExtensions;
    if (saved.length != _draftExcluded.length) return true;
    return !saved.containsAll(_draftExcluded);
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.settingsController;
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) {
        final folders = ctrl.folders;
        return SingleChildScrollView(
          key: const Key('library_settings_panel'),
          padding: const EdgeInsets.only(
            bottom: LuminaTokens.bottomScrollClearance,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_actionStatus != null) ...[
                  _buildStatusBanner(_actionStatus!),
                  const SizedBox(height: LuminaTokens.spaceSm),
                ],

                // 1. Music Folders & Directory Scanning
                SettingsGroupCard(
                  title: '音樂資料夾與掃描',
                  description: '新增本機或 NAS 掛載的音樂資料夾路徑進行掃描入庫，並管理需要自動監控的資料夾根目錄。',
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        LuminaTokens.spaceMd + LuminaTokens.space2xs,
                        LuminaTokens.space2xs,
                        LuminaTokens.spaceMd + LuminaTokens.space2xs,
                        LuminaTokens.spaceMd,
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final scanField = TextField(
                            key: const Key('scan_directory_input'),
                            controller: _scanController,
                            onSubmitted: _scanPath,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 13,
                            ),
                            decoration: LuminaSettingsStyles.inputDecoration(
                              hintText: '輸入音樂資料夾路徑（例如 C:\\Music）',
                              borderRadius: LuminaTokens.radiusMd,
                            ),
                          );
                          final pickBtn = Tooltip(
                            message: '開啟系統資料夾選擇器',
                            child: OutlinedButton.icon(
                              key: const Key('btn_pick_folder'),
                              onPressed:
                                  _isScanning ? null : _pickAndFillFolder,
                              icon: const Icon(
                                Icons.create_new_folder_outlined,
                                size: 17,
                              ),
                              label: const Text('瀏覽'),
                              style: LuminaSettingsStyles.outlinedButtonStyle()
                                  .copyWith(
                                    shape: WidgetStatePropertyAll(
                                      RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          LuminaTokens.radiusPill,
                                        ),
                                      ),
                                    ),
                                  ),
                            ),
                          );
                          final scanBtn = Tooltip(
                            message: '掃描指定音樂資料夾並入庫',
                            child: FilledButton.icon(
                              key: const Key('btn_scan_directory'),
                              onPressed: _isScanning
                                  ? null
                                  : () => _scanPath(_scanController.text),
                              style: LuminaSettingsStyles.filledButtonStyle(),
                              icon: _isScanning
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: LuminaTokens.onAccentDark,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.folder_open_rounded,
                                      size: 18,
                                    ),
                              label: const Text('掃描資料夾'),
                            ),
                          );

                          if (constraints.maxWidth >= 560) {
                            return Row(
                              children: [
                                Expanded(child: scanField),
                                const SizedBox(width: LuminaTokens.spaceXs),
                                pickBtn,
                                const SizedBox(width: LuminaTokens.spaceXs),
                                scanBtn,
                              ],
                            );
                          }
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              scanField,
                              const SizedBox(height: LuminaTokens.spaceXs),
                              Wrap(
                                spacing: LuminaTokens.spaceXs,
                                runSpacing: LuminaTokens.spaceXs,
                                children: [pickBtn, scanBtn],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (_scanStatus != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          LuminaTokens.spaceMd + LuminaTokens.space2xs,
                          0,
                          LuminaTokens.spaceMd + LuminaTokens.space2xs,
                          LuminaTokens.spaceSm,
                        ),
                        child: Text(
                          _scanStatus!,
                          key: const Key('scan_status_label'),
                          style: const TextStyle(
                            color: LuminaTokens.statusSuccess,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    const Divider(color: _dividerColor, height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                        vertical: LuminaTokens.spaceSm,
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
                                '已設定的音樂資料夾 (${folders.length})',
                                style: const TextStyle(
                                  color: LuminaTokens.textSecondary,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (folders.isNotEmpty)
                                Tooltip(
                                  message: '重新掃描清單中所有音樂資料夾',
                                  child: TextButton.icon(
                                    key: const Key('btn_rescan_all_folders'),
                                    onPressed: _isScanning
                                        ? null
                                        : _rescanAllFolders,
                                    icon: const Icon(
                                      Icons.refresh_rounded,
                                      size: 15,
                                    ),
                                    label: const Text('全部重新掃描'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: LuminaTokens.accentBlue,
                                      disabledForegroundColor:
                                          LuminaTokens.textDisabled,
                                      minimumSize: const Size(0, 32),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: LuminaTokens.spaceXs,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (folders.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(
                                top: LuminaTokens.spaceXs,
                              ),
                              child: Text(
                                '尚未加入自訂資料夾。請輸入路徑或點擊「瀏覽」選擇音樂目錄開始掃描。',
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            )
                          else
                            for (final f in folders)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: LuminaTokens.spaceXs,
                                ),
                                child: Container(
                                  key: Key('folder_entry_${f.path}'),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: LuminaTokens.spaceSm,
                                    vertical: LuminaTokens.spaceXs,
                                  ),
                                  decoration: BoxDecoration(
                                    color: LuminaTokens.cardElevatedBg,
                                    borderRadius: BorderRadius.circular(
                                      LuminaTokens.radiusSm,
                                    ),
                                    border: Border.all(color: _dividerColor),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.folder_outlined,
                                        color: LuminaTokens.accentBlue,
                                        size: 18,
                                      ),
                                      const SizedBox(
                                        width: LuminaTokens.spaceSm,
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              f.path,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: LuminaTokens.textPrimary,
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            Text(
                                              '上次掃描：${f.lastTrackCount} 首曲目',
                                              style: const TextStyle(
                                                color: LuminaTokens.textMuted,
                                                fontSize: 11.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '重新掃描此資料夾',
                                        visualDensity: VisualDensity.compact,
                                        style: LuminaSettingsStyles
                                            .iconButtonStyle(),
                                        onPressed: _isScanning
                                            ? null
                                            : () => _scanPath(f.path),
                                        icon: Icon(
                                          Icons.refresh_rounded,
                                          size: 17,
                                          color: _isScanning
                                              ? LuminaTokens.textDisabled
                                              : LuminaTokens.textSecondary,
                                        ),
                                      ),
                                      IconButton(
                                        key: Key('btn_remove_folder_${f.path}'),
                                        tooltip: '從資料夾清單移除',
                                        visualDensity: VisualDensity.compact,
                                        style: LuminaSettingsStyles
                                            .iconButtonStyle(),
                                        onPressed: () {
                                          ctrl.removeFolder(f.path);
                                          setState(() {
                                            _actionStatus =
                                                '已移除資料夾「${f.path}」';
                                          });
                                        },
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 17,
                                          color: LuminaTokens.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),

                // 2. Import Settings (匯入)
                SettingsGroupCard(
                  title: '匯入',
                  children: [
                    SettingsSwitchRow(
                      key: const Key('switch_import_entire_folder'),
                      title: '拖入檔案時匯入整個資料夾',
                      subtitle:
                          '開啟後，拖入單個檔案會連帶匯入其所在資料夾並註冊為掃描根；預設只匯入該檔案。拖入資料夾始終匯入整個資料夾。',
                      value: ctrl.importEntireFolderOnDrop,
                      onChanged: ctrl.setImportEntireFolderOnDrop,
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_import_archives'),
                      title: '匯入壓縮包內的音樂',
                      subtitle:
                          '關閉時（預設）：拖入的 .zip 被忽略。開啟時：ZIP 內的音訊像普通曲目一樣入庫、播放，但壓縮包唯讀（不能改標籤或回寫封面）。僅支援 ZIP。',
                      value: ctrl.importArchives,
                      onChanged: ctrl.setImportArchives,
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_auto_import_archives'),
                      title: '掃描時自動匯入壓縮包',
                      subtitle:
                          '開啟後：掃描時自動發現並匯入音樂資料夾下的壓縮包。新放入的壓縮包不會被即時監控匯入，等下次掃描。',
                      helperNote: ctrl.importArchives
                          ? null
                          : '請先開啟上方的「匯入壓縮包內的音樂」。',
                      value: ctrl.autoImportArchivesOnScan,
                      onChanged: ctrl.importArchives
                          ? ctrl.setAutoImportArchivesOnScan
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),

                // 3. Playback Cache (播放快取)
                SettingsGroupCard(
                  title: '播放快取',
                  description: '壓縮包解壓和遠端音樂庫下載的曲目存在這裡。超過上限時先刪最久沒播放的。',
                  children: [
                    SettingsDropdownRow<int>(
                      title: '快取上限',
                      dropdownKey: const Key('dropdown_cache_limit'),
                      value: ctrl.cacheLimitGb,
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 GB')),
                        DropdownMenuItem(value: 2, child: Text('2 GB')),
                        DropdownMenuItem(value: 4, child: Text('4 GB')),
                        DropdownMenuItem(value: 8, child: Text('8 GB')),
                        DropdownMenuItem(value: 16, child: Text('16 GB')),
                        DropdownMenuItem(value: 0, child: Text('無上限')),
                      ],
                      onChanged: (v) {
                        if (v != null) ctrl.setCacheLimitGb(v);
                      },
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                        vertical: LuminaTokens.spaceSm,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '已用空間',
                              style: TextStyle(
                                color: LuminaTokens.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            ctrl.formattedCacheUsed,
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(width: LuminaTokens.spaceSm),
                          Tooltip(
                            message: '清除暫存的播放快取檔案',
                            child: OutlinedButton(
                              key: const Key('btn_clear_playback_cache'),
                              onPressed: () {
                                ctrl.clearCache();
                                setState(() => _actionStatus = '已清理播放快取空間');
                              },
                              style: LuminaSettingsStyles.outlinedButtonStyle(),
                              child: const Text(
                                '清理',
                                style: TextStyle(fontSize: 12.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),

                // 4. Duplicate Cleanup (重複項清理)
                SettingsGroupCard(
                  title: '重複項清理',
                  children: [
                    SettingsActionRow(
                      title: '查詢重複曲目與版本合併',
                      subtitle: '查詢庫中內容相同或疑似重複的曲目複製，按組審閱後批次移除。',
                      buttonLabel: '查詢重複項',
                      buttonKey: const Key('btn_find_duplicates'),
                      onPressed: () async {
                        final count =
                            await widget.audioService.deduplicateLibrary();
                        widget.onLibraryChanged?.call();
                        if (!mounted) return;
                        setState(() {
                          _actionStatus = '重複項檢查完成：已合併或整理 $count 組專輯/曲目紀錄';
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),

                // 5. Scan & Analysis (掃描與分析)
                SettingsGroupCard(
                  title: '掃描與分析',
                  children: [
                    SettingsActionRow(
                      title: '重新掃描中繼資料標籤',
                      subtitle: '強制對音樂庫內所有音訊檔案重新提取標籤中繼資料、內嵌歌詞與封面，更新 SQLite 快取。',
                      buttonLabel: '重新掃描標籤',
                      buttonKey: const Key('btn_rescan_tags'),
                      onPressed: () async {
                        setState(() => _isScanning = true);
                        try {
                          final res =
                              await widget.audioService.rescanTags(force: true);
                          widget.onLibraryChanged?.call();
                          if (!mounted) return;
                          setState(() {
                            final count =
                                res?['updated_count'] ??
                                res?['rescanned_count'] ??
                                '全部';
                            _actionStatus = '已完成標籤中繼資料重新掃描（更新 $count 筆）';
                          });
                        } finally {
                          if (mounted) setState(() => _isScanning = false);
                        }
                      },
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsActionRow(
                      title: '設定外部封面',
                      subtitle: '為目前播放或指定之曲目設定外部封面圖片（支援 JPG/PNG/WebP）。',
                      buttonLabel: '設定外部封面',
                      buttonKey: const Key('btn_set_user_cover'),
                      onPressed: () async {
                        final chosen = await ctrl.pickFolderNative();
                        if (chosen != null && chosen.isNotEmpty) {
                          final trk = widget.audioService.currentState.track;
                          if (trk != null) {
                            await widget.audioService.setUserCover(
                              trk.id,
                              chosen,
                              path: trk.filePath,
                            );
                            widget.onLibraryChanged?.call();
                            if (mounted) {
                              setState(() {
                                _actionStatus =
                                    '已為「${trk.title}」設定外部封面：$chosen';
                              });
                            }
                          }
                        }
                      },
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_rescan_on_startup'),
                      title: '啟動時重新掃描',
                      subtitle:
                          '開啟（預設）：每次啟動都增量掃描全部音樂資料夾。大型或網路音樂庫上這一步會明顯拖慢啟動；關閉後仍會即時監控資料夾變化，也隨時可以手動掃描。下次啟動生效。',
                      value: ctrl.rescanOnStartup,
                      onChanged: ctrl.setRescanOnStartup,
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_verify_db_integrity'),
                      title: '校驗資料庫完整性',
                      subtitle:
                          '開啟後，每次啟動先檢查資料庫完整性，版本升級後再做一次完整校驗；發現損壞會進入恢復介面。音樂庫較大或放在機械硬碟上時，每次啟動可能要多等幾分鐘。關閉（預設）時，只在執行中出現損壞跡象、或從備份恢復之後才檢查。下次啟動生效。',
                      value: ctrl.verifyDbIntegrity,
                      onChanged: ctrl.setVerifyDbIntegrity,
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsDropdownRow<String>(
                      title: '後臺任務速度',
                      subtitle:
                          '決定掃描、封面提取、音量分析與波形分析「每項任務」各用多少執行緒；兩項任務同時執行時執行緒數疊加。下次任務開始時生效，正在執行的任務不受影響。',
                      dropdownKey: const Key('dropdown_task_speed'),
                      value: ctrl.backgroundTaskSpeed,
                      items: const [
                        DropdownMenuItem(value: 'auto', child: Text('自動')),
                        DropdownMenuItem(value: 'low', child: Text('保守')),
                        DropdownMenuItem(value: 'balanced', child: Text('均衡')),
                        DropdownMenuItem(value: 'fast', child: Text('高速')),
                      ],
                      onChanged: (v) {
                        if (v != null) ctrl.setBackgroundTaskSpeed(v);
                      },
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                        vertical: LuminaTokens.spaceMd,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '排除的檔案型別',
                                      style: TextStyle(
                                        color: LuminaTokens.textPrimary,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(height: LuminaTokens.space2xs),
                                    Text(
                                      '勾選的型別掃描時跳過；已入庫的會被隱藏，取消勾選後恢復（「喜歡」與播放記錄保留）。只作用於磁碟上的檔案，壓縮包內的成員不受影響。',
                                      style: TextStyle(
                                        color: LuminaTokens.textMuted,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: LuminaTokens.spaceMd),
                              Tooltip(
                                message: _hasExcludedChanges
                                    ? '套用排除檔案型別篩選'
                                    : '沒有未儲存的副檔名篩選變更',
                                child: OutlinedButton(
                                  key: const Key('btn_apply_excluded_types'),
                                  onPressed: _hasExcludedChanges
                                      ? () {
                                          ctrl.applyExcludedExtensions(
                                            _draftExcluded,
                                          );
                                          widget.onLibraryChanged?.call();
                                          setState(() {
                                            _actionStatus =
                                                '已套用排除檔案型別篩選（${_draftExcluded.length} 項）';
                                          });
                                        }
                                      : null,
                                  style:
                                      LuminaSettingsStyles.outlinedButtonStyle(
                                        activeHighlight: _hasExcludedChanges,
                                      ),
                                  child: const Text(
                                    '應用',
                                    style: TextStyle(fontSize: 12.5),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: LuminaTokens.spaceSm),
                          Wrap(
                            spacing: LuminaTokens.spaceSm,
                            runSpacing: LuminaTokens.spaceXs,
                            children: [
                              for (final ext
                                  in LibrarySettingsController.allAudioExtensions)
                                Material(
                                  type: MaterialType.transparency,
                                  child: InkWell(
                                    key: Key('chk_ext_$ext'),
                                    borderRadius: BorderRadius.circular(
                                      LuminaTokens.radiusSm,
                                    ),
                                    mouseCursor: SystemMouseCursors.click,
                                    hoverColor: LuminaTokens.cardHoverBg
                                        .withValues(alpha: 0.6),
                                    focusColor: LuminaTokens.focusRing
                                        .withValues(alpha: 0.2),
                                    onTap: () {
                                      setState(() {
                                        if (_draftExcluded.contains(ext)) {
                                          _draftExcluded.remove(ext);
                                        } else {
                                          _draftExcluded.add(ext);
                                        }
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: LuminaTokens.space2xs,
                                        horizontal: LuminaTokens.spaceXs,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: Checkbox(
                                              value: _draftExcluded.contains(
                                                ext,
                                              ),
                                              onChanged: (checked) {
                                                setState(() {
                                                  if (checked == true) {
                                                    _draftExcluded.add(ext);
                                                  } else {
                                                    _draftExcluded.remove(ext);
                                                  }
                                                });
                                              },
                                              activeColor:
                                                  LuminaTokens.accentBlue,
                                              checkColor:
                                                  LuminaTokens.onAccentDark,
                                              side: const BorderSide(
                                                color:
                                                    LuminaTokens.borderControl,
                                                width: 1.5,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                            ),
                                          ),
                                          const SizedBox(
                                            width: LuminaTokens.spaceXs,
                                          ),
                                          Text(
                                            ext,
                                            style: const TextStyle(
                                              color: LuminaTokens.textSecondary,
                                              fontSize: 12.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsSwitchRow(
                      key: const Key('switch_merge_multi_disc'),
                      title: '合併多碟套裝',
                      subtitle:
                          '同一資料夾裡按碟分開命名的專輯（如「X, Disc 1: ...」「X (CD2)」）合成一張多碟專輯，按碟分段顯示。只改音樂庫裡的顯示，不改檔案；關閉後恢復成各自一張。早於本版本入庫的曲目，要等後臺整理完成後才會合併。',
                      value: ctrl.mergeMultiDiscSets,
                      onChanged: ctrl.setMergeMultiDiscSets,
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    SettingsActionRow(
                      title: '已從音樂庫移除 (${ctrl.removedTrackCount})',
                      subtitle:
                          '「僅從音樂庫移除」的曲目不會被重新掃描加入。恢復後，它們會在下一次掃描完成時回到音樂庫；播放歷史與播放清單歸屬不會恢復。',
                      buttonLabel: '全部恢復',
                      buttonKey: const Key('btn_restore_removed_tracks'),
                      onPressed: ctrl.removedTrackCount > 0
                          ? () {
                              ctrl.restoreRemovedTracks();
                              setState(() {
                                _actionStatus = '已將移除的曲目排入下次掃描恢復清單';
                              });
                            }
                          : () {
                              ctrl.restoreRemovedTracks();
                              setState(() {
                                _actionStatus = '目前已無已移除的待恢復曲目';
                              });
                            },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
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
