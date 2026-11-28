part of 'providers_and_remote_panel.dart';

extension _ProvidersAndRemoteNetworkExt on _ProvidersAndRemotePanelState {
  Widget _buildSingleFieldForm({
    required Key inputKey,
    required Key buttonKey,
    required TextEditingController controller,
    required String labelText,
    required String buttonLabel,
    required VoidCallback onSubmit,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = TextField(
          key: inputKey,
          controller: controller,
          onSubmitted: (_) => onSubmit(),
          style: const TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: 12.5,
          ),
          decoration: LuminaSettingsStyles.inputDecoration(
            labelText: labelText,
            borderRadius: LuminaTokens.radiusSm,
          ),
        );
        final button = FilledButton(
          key: buttonKey,
          onPressed: onSubmit,
          style: LuminaSettingsStyles.filledButtonStyle(),
          child: Text(buttonLabel),
        );
        if (constraints.maxWidth < 420) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              const SizedBox(height: LuminaTokens.spaceXs),
              Align(alignment: Alignment.centerRight, child: button),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: field),
            const SizedBox(width: LuminaTokens.spaceSm),
            button,
          ],
        );
      },
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceXs),
      child: Row(
        children: [
          Icon(icon, size: 15, color: LuminaTokens.textSecondary),
          const SizedBox(width: LuminaTokens.spaceXs),
          Text(
            label,
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderItem({
    required String kind,
    required String name,
    required Color badgeColor,
    required Widget iconGlyph,
    required Widget Function() formBuilder,
  }) {
    final statusInfo = _statusFor(kind);
    final isConfigured =
        statusInfo?.isOnline == true || statusInfo?.isConfigured == true;
    final isInUse = _selectedActiveProvider == kind && isConfigured;
    final isExpanded = _expandedSection == kind;

    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: isInUse
                ? _ProvidersAndRemotePanelState._activeRowBg
                : _ProvidersAndRemotePanelState._cardBg,
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            child: InkWell(
              key: Key('provider_row_$kind'),
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: LuminaTokens.glassRowHoverBg,
              focusColor: LuminaTokens.focusRing.withValues(alpha: 0.16),
              onTap: () => _toggleExpand(kind),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceMd,
                  vertical: LuminaTokens.spaceSm,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    LuminaTokens.glassCardRadius,
                  ),
                  border: Border.all(
                    color: isInUse
                        ? LuminaTokens.glassCoverRim
                        : _ProvidersAndRemotePanelState._cardBorder,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: isInUse ? badgeColor : LuminaTokens.glassPillBg,
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        border: isInUse
                            ? null
                            : Border.all(
                                color: isConfigured
                                    ? LuminaTokens.glassCoverRim
                                    : _ProvidersAndRemotePanelState._cardBorder,
                              ),
                      ),
                      child: Center(
                        child: Opacity(
                          opacity: isInUse ? 1.0 : 0.88,
                          child: iconGlyph,
                        ),
                      ),
                    ),
                    const SizedBox(width: LuminaTokens.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            style: TextStyle(
                              color: isInUse
                                  ? LuminaTokens.textPrimary
                                  : LuminaTokens.textSecondary,
                              fontSize: 14.5,
                              fontWeight: isInUse
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          if (isInUse)
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Text(
                                '使用中',
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          else if (isConfigured)
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Text(
                                '已登入就緒',
                                style: TextStyle(
                                  color: LuminaTokens.glassTextPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!isConfigured)
                      Tooltip(
                        message: isExpanded ? '收合 $name 設定' : '登入 $name',
                        child: TextButton(
                          key: Key('btn_signin_$kind'),
                          onPressed: () => _toggleExpand(kind),
                          style: TextButton.styleFrom(
                            foregroundColor: LuminaTokens.textSecondary,
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(
                              horizontal: LuminaTokens.spaceSm,
                            ),
                          ),
                          child: Text(
                            isExpanded ? '收合' : '登入',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      )
                    else ...[
                      IconButton(
                        key: Key('btn_logout_$kind'),
                        tooltip: '登出帳號',
                        visualDensity: VisualDensity.compact,
                        style: LuminaSettingsStyles.iconButtonStyle(),
                        onPressed: () => _disconnectProvider(kind, name),
                        icon: const Icon(
                          Icons.logout_rounded,
                          size: 18,
                          color: LuminaTokens.textSecondary,
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.space2xs),
                      Tooltip(
                        message: isInUse
                            ? '$name（目前主要串流來源）'
                            : '將 $name 設為主要串流來源',
                        child: Semantics(
                          label: '將 $name 設為主要串流來源',
                          selected: isInUse,
                          button: true,
                          child: InkWell(
                            key: Key('btn_activate_provider_$kind'),
                            borderRadius: BorderRadius.circular(
                              LuminaTokens.radiusPill,
                            ),
                            mouseCursor: SystemMouseCursors.click,
                            hoverColor: LuminaTokens.glassPillHoverBg,
                            focusColor: LuminaTokens.focusRing.withValues(
                              alpha: 0.24,
                            ),
                            onTap: () {
                              _updateState(() {
                                _statusIsError = false;
                                _selectedActiveProvider = kind;
                                _status = '已將主要串流來源切換為 $name';
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(
                                LuminaTokens.spaceXs,
                              ),
                              child: isInUse
                                  ? Container(
                                      width: 18,
                                      height: 18,
                                      decoration: const BoxDecoration(
                                        color: _ProvidersAndRemotePanelState
                                            ._activeIndicator,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Container(
                                          width: 6,
                                          height: 6,
                                          decoration: const BoxDecoration(
                                            color: LuminaTokens.onAccentDark,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: LuminaTokens.glassPillBorder,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: LuminaTokens.motionCurve,
            child: isExpanded
                ? Container(
                    margin: const EdgeInsets.fromLTRB(
                      LuminaTokens.spaceSm,
                      LuminaTokens.space2xs,
                      LuminaTokens.spaceSm,
                      LuminaTokens.spaceXs,
                    ),
                    padding: const EdgeInsets.all(LuminaTokens.spaceMd),
                    decoration: BoxDecoration(
                      color: _ProvidersAndRemotePanelState._cardBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.glassCardRadius,
                      ),
                      border: Border.all(
                        color: _ProvidersAndRemotePanelState._cardBorder,
                      ),
                    ),
                    child: formBuilder(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
