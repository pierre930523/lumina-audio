part of 'output_zone_panel.dart';

class _OutputDevicesHeader extends StatelessWidget {
  final bool refreshing;
  final VoidCallback onRefresh;

  const _OutputDevicesHeader({
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: LuminaTokens.spaceSm,
      runSpacing: LuminaTokens.spaceXs,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '音訊輸出裝置',
              style: TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(height: LuminaTokens.space2xs),
            Text(
              '選擇此裝置要啟用的實體輸出介面（WASAPI Exclusive / WASAPI Shared / ASIO）',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
        Tooltip(
          message: '重新整理並偵測實體音訊輸出裝置',
          child: OutlinedButton.icon(
            key: const Key('btn_refresh_audio_devices'),
            onPressed: refreshing ? null : onRefresh,
            style: LuminaSettingsStyles.outlinedButtonStyle(),
            icon: Icon(
              Icons.refresh_rounded,
              size: 17,
              color: refreshing
                  ? LuminaTokens.textDisabled
                  : LuminaTokens.textSecondary,
            ),
            label: Text(
              refreshing ? '重新整理中...' : '重新整理裝置清單',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _OutputErrorBanner extends StatelessWidget {
  final String errorMessage;
  final VoidCallback onRetry;

  const _OutputErrorBanner({
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '音訊裝置錯誤：$errorMessage',
      child: Container(
        key: const Key('output_device_error_banner'),
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceMd,
          vertical: LuminaTokens.spaceSm,
        ),
        decoration: BoxDecoration(
          color: LuminaTokens.statusError.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: LuminaTokens.statusError.withValues(alpha: 0.45),
          ),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: LuminaTokens.statusError,
              size: 18,
            ),
            const SizedBox(width: LuminaTokens.spaceSm),
            Expanded(
              child: Text(
                errorMessage,
                style: const TextStyle(
                  color: Color(0xFFFECACA),
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            Tooltip(
              message: '重新偵測音訊輸出裝置並重試連線',
              child: TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: LuminaTokens.textPrimary,
                  backgroundColor: LuminaTokens.statusError.withValues(
                    alpha: 0.16,
                  ),
                  side: BorderSide(
                    color: LuminaTokens.statusError.withValues(alpha: 0.55),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: LuminaTokens.spaceSm,
                    vertical: LuminaTokens.spaceXs,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                  ),
                ),
                child: const Text(
                  '重新偵測',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputDevicesGrid extends StatelessWidget {
  final List<_OutputCardEntry> cards;
  final AudioService audioService;
  final AudioEngineOutputInfoModel outputInfo;
  final String? activatingCardKey;
  final ValueChanged<_OutputCardEntry> onOpenSettings;
  final ValueChanged<_OutputCardEntry> onActivate;

  const _OutputDevicesGrid({
    required this.cards,
    required this.audioService,
    required this.outputInfo,
    required this.activatingCardKey,
    required this.onOpenSettings,
    required this.onActivate,
  });

  Widget _buildCard(_OutputCardEntry entry, double cardPadding) {
    return _OutputDeviceCard(
      entry: entry,
      active: _isOutputCardActive(audioService, entry),
      audioService: audioService,
      outputInfo: outputInfo,
      isActivating: activatingCardKey == entry.cardKey,
      iconData: _iconForOutputEntry(entry),
      cardPadding: cardPadding,
      onOpenSettings: () => onOpenSettings(entry),
      onActivate: () => onActivate(entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: const Key('output_devices_grid'),
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isTwoCol = width >= 560;
        final isWide = width >= 720;
        final gap = isWide ? LuminaTokens.spaceMd : LuminaTokens.spaceSm;
        final cardPadding = isWide
            ? LuminaTokens.spaceMd
            : LuminaTokens.spaceSm;

        if (!isTwoCol) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) SizedBox(height: gap),
                _buildCard(cards[i], cardPadding),
              ],
            ],
          );
        }

        final rows = <Widget>[];
        for (var i = 0; i < cards.length; i += 2) {
          final left = cards[i];
          final right = i + 1 < cards.length ? cards[i + 1] : null;
          if (i > 0) rows.add(SizedBox(height: gap));
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildCard(left, cardPadding)),
                  SizedBox(width: gap),
                  Expanded(
                    child: right != null
                        ? _buildCard(right, cardPadding)
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

class _OutputDeviceCard extends StatelessWidget {
  final _OutputCardEntry entry;
  final bool active;
  final AudioService audioService;
  final AudioEngineOutputInfoModel outputInfo;
  final bool isActivating;
  final IconData iconData;
  final double cardPadding;
  final VoidCallback onOpenSettings;
  final VoidCallback onActivate;

  const _OutputDeviceCard({
    required this.entry,
    required this.active,
    required this.audioService,
    required this.outputInfo,
    required this.isActivating,
    required this.iconData,
    required this.cardPadding,
    required this.onOpenSettings,
    required this.onActivate,
  });

  @override
  Widget build(BuildContext context) {
    final cap = entry.capability;
    final pbState = audioService.currentState;
    final isPlaying = active && pbState.status == PlaybackStatus.playing;
    final isPaused = active && pbState.status == PlaybackStatus.paused;

    final title = entry.isSystemOutput ? 'System Output' : cap.name;
    final subtitle = entry.isSystemOutput
        ? '跟隨 Windows 預設 · ${cap.name} (${cap.interfaceLabel})'
        : cap.interfaceLabel;

    final statusLabel = isPlaying
        ? (pbState.track != null ? '正在播放 · ${pbState.track!.title}' : '正在播放')
        : (isPaused ? '已暫停 · 使用中' : '使用中');

    final showBitPerfectBadge =
        active &&
        !cap.isSharedMode &&
        outputInfo.verification.status == 'BIT-PERFECT';

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 136),
      child: Container(
        key: Key('output_card_${entry.cardKey}'),
        padding: EdgeInsets.all(cardPadding),
        decoration: BoxDecoration(
          color: active
              ? _OutputZonePanelState._activeCardBg
              : _OutputZonePanelState._inactiveCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          border: Border.all(
            color: active
                ? _OutputZonePanelState._activeCardBorder
                : _OutputZonePanelState._inactiveCardBorder,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: active
                        ? LuminaTokens.glassNavActiveBg
                        : LuminaTokens.glassPillBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    border: Border.all(
                      color: active
                          ? LuminaTokens.glassCoverRim
                          : LuminaTokens.glassSidebarBorder,
                    ),
                  ),
                  child: Icon(
                    iconData,
                    color: active
                        ? LuminaTokens.textPrimary
                        : LuminaTokens.textSecondary,
                    size: 21,
                  ),
                ),
                const SizedBox(width: LuminaTokens.spaceSm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: LuminaTokens.space2xs),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: LuminaTokens.spaceMd),
            Row(
              children: [
                if (active) ...[
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isPlaying
                                ? LuminaTokens.statusSuccess
                                : LuminaTokens.glassTextSecondary,
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        Flexible(
                          child: Text(
                            statusLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isPlaying
                                  ? LuminaTokens.statusSuccess
                                  : LuminaTokens.textSecondary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (showBitPerfectBadge) ...[
                          const SizedBox(width: LuminaTokens.spaceXs),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LuminaTokens.spaceXs,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: LuminaTokens.hiResGoldBg,
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusSm,
                              ),
                              border: Border.all(
                                color: LuminaTokens.hiResGoldBorder,
                              ),
                            ),
                            child: const Text(
                              'BIT-PERFECT',
                              style: TextStyle(
                                color: LuminaTokens.hiResGoldText,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    key: Key('btn_device_settings_${entry.cardKey}'),
                    tooltip: '裝置設定',
                    visualDensity: VisualDensity.compact,
                    style: LuminaSettingsStyles.iconButtonStyle(
                      foregroundColor: LuminaTokens.textPrimary,
                    ),
                    onPressed: onOpenSettings,
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: LuminaTokens.textPrimary,
                      size: 20,
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: Text(
                      entry.isSystemOutput
                          ? '動態跟隨作業系統預設輸出'
                          : (cap.isSharedMode
                                ? '系統混音器模式'
                                : (cap.backend == 'windows_asio'
                                      ? '硬體原生 ASIO 通道'
                                      : '獨佔位元直出通道')),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  Tooltip(
                    message:
                        '啟用 ${entry.isSystemOutput ? 'System Output' : cap.name}',
                    child: FilledButton(
                      key: Key('btn_activate_device_${entry.cardKey}'),
                      onPressed: isActivating ? null : onActivate,
                      style: LuminaSettingsStyles.filledButtonStyle(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceMd,
                          vertical: LuminaTokens.spaceXs,
                        ),
                        minimumSize: const Size(64, 34),
                      ),
                      child: Text(
                        isActivating ? '啟用中...' : '啟用',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
