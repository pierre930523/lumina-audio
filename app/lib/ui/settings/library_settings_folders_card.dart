part of 'library_settings_panel.dart';

extension _LibrarySettingsFoldersCardExt on _LibrarySettingsPanelState {
  Widget _buildFoldersAndScanCard(
    LibrarySettingsController ctrl,
    List<MusicFolderEntry> folders,
  ) {
    return SettingsGroupCard(
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
                  onPressed: _isScanning ? null : _pickAndFillFolder,
                  icon: const Icon(
                    Icons.create_new_folder_outlined,
                    size: 17,
                  ),
                  label: const Text('瀏覽'),
                  style: LuminaSettingsStyles.outlinedButtonStyle().copyWith(
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
        ValueListenableBuilder<ScanProgressEvent?>(
          valueListenable: _scanProgressNotifier,
          builder: (context, progress, _) {
            if (progress == null) return const SizedBox.shrink();
            return _buildScanProgressCard(progress);
          },
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
        const Divider(color: _LibrarySettingsPanelState._dividerColor, height: 1),
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
                        onPressed: _isScanning ? null : _rescanAllFolders,
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 15,
                        ),
                        label: const Text('全部重新掃描'),
                        style: TextButton.styleFrom(
                          foregroundColor: LuminaTokens.glassTextPrimary,
                          disabledForegroundColor: LuminaTokens.textDisabled,
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
                        color: LuminaTokens.glassPillBg,
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        border: Border.all(
                          color: LuminaTokens.glassCardBorder,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.folder_outlined,
                            color: LuminaTokens.glassTextPrimary,
                            size: 18,
                          ),
                          const SizedBox(
                            width: LuminaTokens.spaceSm,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                          const SizedBox(width: LuminaTokens.spaceXs),
                          _buildWatchModeBadge(
                            f.path,
                            _watchedRootsByPath[
                                LibrarySettingsPanel.normalizeFolderPathKey(
                              f.path,
                            )],
                          ),
                          IconButton(
                            tooltip: '重新掃描此資料夾',
                            visualDensity: VisualDensity.compact,
                            style: LuminaSettingsStyles.iconButtonStyle(),
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
                            style: LuminaSettingsStyles.iconButtonStyle(),
                            onPressed: () {
                              ctrl.removeFolder(f.path);
                              unawaited(
                                widget.audioService
                                    .removeWatchedRoot(f.path)
                                    .then((_) => _loadWatchedRoots()),
                              );
                              _updateState(() {
                                final next =
                                    Map<String, WatchedRootRecord>.from(
                                      _watchedRootsByPath,
                                    )..remove(
                                      LibrarySettingsPanel
                                          .normalizeFolderPathKey(f.path),
                                    );
                                _watchedRootsByPath = next;
                                _actionStatus = '已移除資料夾「${f.path}」';
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
    );
  }
}
