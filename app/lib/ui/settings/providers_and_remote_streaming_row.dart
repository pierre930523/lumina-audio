part of 'providers_and_remote_panel.dart';

extension _ProvidersAndRemoteStreamingRowExt on _ProvidersAndRemotePanelState {
  Widget _buildStreamingProviderRow(StreamingProviderMeta meta) {
    final kind = meta.kind;
    final provider = _streamingManager.providerFor(kind);
    final authState = provider?.authState ?? StreamingAuthState.disconnected;
    final isAuthenticating =
        _streamingManager.isAuthenticating(kind) ||
        authState == StreamingAuthState.authenticating;
    final isConnected =
        !isAuthenticating && authState == StreamingAuthState.connected;
    final isAuthRequired =
        !isAuthenticating &&
        (authState == StreamingAuthState.authRequired ||
            _streamingManager.isAuthRequired(kind));
    final isError =
        !isAuthenticating &&
        (authState == StreamingAuthState.error || isAuthRequired);
    final isInUse = _selectedActiveProvider == kind && isConnected;
    final isSyncing = _syncingKinds.contains(kind);
    final info = provider?.accountInfo;

    final String? subtitleText;
    final Color subtitleColor;
    if (isAuthenticating) {
      subtitleText = _streamingManager.progressMessageFor(kind) ?? '連線中...';
      subtitleColor = LuminaTokens.glassTextPrimary;
    } else if (isConnected) {
      final accountLabel = info != null
          ? ((info.planTier != null && info.planTier!.isNotEmpty)
                ? '${info.displayName} • ${info.planTier}'
                : info.displayName)
          : '已登入就緒';
      subtitleText = isInUse ? '$accountLabel • 使用中' : accountLabel;
      subtitleColor = isInUse
          ? LuminaTokens.textSecondary
          : LuminaTokens.statusSuccess;
    } else if (isError) {
      subtitleText =
          _streamingManager.authErrorFor(kind) ??
          provider?.lastError ??
          '授權驗證失敗，請重新登入';
      subtitleColor = LuminaTokens.statusError;
    } else {
      subtitleText = null;
      subtitleColor = LuminaTokens.textMuted;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
      child: Material(
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
          onTap: isAuthenticating
              ? null
              : () => _openStreamingLoginDialog(meta),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceMd,
              vertical: LuminaTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(
                color: isInUse
                    ? LuminaTokens.glassCoverRim
                    : (isError
                          ? LuminaTokens.statusError.withValues(alpha: 0.5)
                          : _ProvidersAndRemotePanelState._cardBorder),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final infoColumn = Row(
                  children: [
                    meta.buildBadge(
                      boxSize: 28,
                      borderRadius: LuminaTokens.radiusSm,
                      overrideBackground: isInUse
                          ? meta.badgeColor
                          : LuminaTokens.glassPillBg,
                      glyphOpacity: isInUse ? 1.0 : 0.88,
                    ),
                    const SizedBox(width: LuminaTokens.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              if (isConnected || isError) ...[
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: isConnected
                                        ? LuminaTokens.statusSuccess
                                        : LuminaTokens.statusError,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  meta.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isInUse || isConnected
                                        ? LuminaTokens.textPrimary
                                        : LuminaTokens.textSecondary,
                                    fontSize: 14.5,
                                    fontWeight: isInUse
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (subtitleText != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitleText,
                                maxLines: isError ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: subtitleColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );

                final compactBtnStyle = LuminaSettingsStyles.outlinedButtonStyle()
                    .copyWith(
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
                    );

                final Widget trailingActions;
                if (isAuthenticating) {
                  trailingActions = Wrap(
                    spacing: LuminaTokens.spaceXs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: LuminaTokens.glassTextPrimary,
                        ),
                      ),
                      const Text(
                        '連線中...',
                        style: TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      TextButton(
                        key: Key('btn_cancel_signin_$kind'),
                        onPressed: () => _streamingManager.cancelLogin(kind),
                        style: TextButton.styleFrom(
                          foregroundColor: LuminaTokens.statusError,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(
                            horizontal: LuminaTokens.spaceSm,
                          ),
                        ),
                        child: const Text('取消'),
                      ),
                    ],
                  );
                } else if (isConnected) {
                  trailingActions = Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OutlinedButton(
                        key: Key('btn_sync_$kind'),
                        onPressed: isSyncing
                            ? null
                            : () => _syncStreamingProvider(kind, meta.name),
                        style: compactBtnStyle,
                        child: Text(
                          isSyncing ? '同步中' : '同步',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      OutlinedButton(
                        key: Key('btn_settings_$kind'),
                        onPressed: () => _openStreamingLoginDialog(meta),
                        style: compactBtnStyle,
                        child: const Text(
                          '設定',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      OutlinedButton(
                        key: Key('btn_logout_$kind'),
                        onPressed: () =>
                            _logoutStreamingProvider(kind, meta.name),
                        style: compactBtnStyle,
                        child: const Text(
                          '登出',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      Tooltip(
                        message: isInUse
                            ? '${meta.name}（目前主要串流來源）'
                            : '將 ${meta.name} 設為主要串流來源',
                        child: Semantics(
                          label: '將 ${meta.name} 設為主要串流來源',
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
                                _status = '已將主要串流來源切換為 ${meta.name}';
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
                  );
                } else if (isError) {
                  trailingActions = FilledButton(
                    key: Key('btn_relogin_$kind'),
                    onPressed: () => _openStreamingLoginDialog(meta),
                    style: LuminaSettingsStyles.filledButtonStyle(
                      backgroundColor: LuminaTokens.statusError,
                      foregroundColor: LuminaTokens.onAccentDark,
                      padding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceSm,
                        vertical: LuminaTokens.spaceXs,
                      ),
                    ),
                    child: const Text(
                      '重新登入',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                } else {
                  trailingActions = TextButton(
                    key: Key('btn_signin_$kind'),
                    onPressed: () => _openStreamingLoginDialog(meta),
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceSm,
                      ),
                    ),
                    child: const Text(
                      '登入',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }

                if (constraints.maxWidth < 460 &&
                    (isConnected || isAuthenticating)) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      infoColumn,
                      const SizedBox(height: LuminaTokens.spaceXs),
                      Align(
                        alignment: Alignment.centerRight,
                        child: trailingActions,
                      ),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: infoColumn),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    trailingActions,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
