part of 'streaming_login_dialog.dart';

extension _StreamingLoginWidgetsExt on _StreamingLoginDialogState {
  Widget _buildConnectedAccountBanner(StreamingAccountInfo account) {
    final detail = (account.planTier != null && account.planTier!.isNotEmpty)
        ? '${account.displayName} • ${account.planTier}'
        : account.displayName;
    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.statusSuccess.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusSuccess.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 18,
            color: LuminaTokens.statusSuccess,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Text(
              '目前登入：$detail',
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const Key('btn_dialog_logout'),
            onPressed: _submitting
                ? null
                : () async {
                    await widget.streamingManager.logoutProvider(_kind);
                    if (mounted) {
                      Navigator.of(context).pop(false);
                    }
                  },
            child: const Text(
              '登出',
              style: TextStyle(
                color: LuminaTokens.statusError,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(List<String> labels) {
    return DecoratedBox(
      decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var i = 0; i < labels.length; i++)
              LuminaSettingsStyles.frostedSegmentChip(
                key: Key('login_tab_${_kind}_$i'),
                label: labels[i],
                selected: _selectedTab == i,
                disabled: _submitting,
                onSelected: _submitting
                    ? null
                    : (_) => _updateState(() {
                        _selectedTab = i;
                        _errorMessage = null;
                      }),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebViewPrimaryCard() {
    final meta = widget.provider.meta;
    final detected = _detectedBrowser;
    final String description;
    final String idleLabel;
    final String busyLabel;

    if (detected != null && detected.isChromium) {
      description =
          '將使用系統預設瀏覽器（${detected.displayName}）開啟獨立工作階段登入 ${meta.name}，'
          '自動擷取憑證並以 DPAPI 加密，結束後清除暫存資料。';
      idleLabel = '使用 ${detected.displayName} 自動登入';
      busyLabel = '${detected.displayName} 授權中...';
    } else if (detected != null && !detected.isChromium) {
      description =
          '偵測到系統預設瀏覽器為 ${detected.displayName}（非 Chromium 核心）。'
          '點擊下方按鈕將於 ${detected.displayName} 開啟 ${meta.name} 官方登入頁，並展開一步憑證綁定指引。';
      idleLabel = '開啟 ${detected.displayName} 並完成授權';
      busyLabel = '正在開啟 ${detected.displayName}...';
    } else {
      description =
          '將啟動系統預設瀏覽器（Brave / Google Chrome / Microsoft Edge）登入 ${meta.name}，'
          '自動擷取憑證並以 DPAPI 加密，結束後清除暫存資料。';
      idleLabel = '開啟系統瀏覽器自動登入';
      busyLabel = '系統瀏覽器授權中...';
    }

    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceMd),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            description,
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          FilledButton.icon(
            key: const Key('btn_webview_auto_login'),
            onPressed: _submitting ? null : _submitWebViewLogin,
            style: LuminaSettingsStyles.filledButtonStyle(),
            icon: _submittingWebView
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: LuminaTokens.onAccentDark,
                    ),
                  )
                : const Icon(Icons.open_in_browser_rounded, size: 18),
            label: Text(_submittingWebView ? busyLabel : idleLabel),
          ),
        ],
      ),
    );
  }

  Widget _buildNonChromiumAssistedBanner(String message) {
    return Container(
      key: const Key('non_chromium_assisted_banner'),
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.glassCoverRim),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: LuminaTokens.glassTextPrimary,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQobuzMissingSecretNotice() {
    return Container(
      key: const Key('qobuz_missing_secret_notice'),
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.statusWarning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusWarning.withValues(alpha: 0.55),
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: LuminaTokens.statusWarning,
          ),
          SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Text(
              QobuzProvider.missingAppSecretNotice,
              style: TextStyle(
                color: Color(0xFFFDE68A),
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppleMusicDrmNoticeCard() {
    return Container(
      key: const Key('apple_music_drm_notice'),
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.statusWarning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusWarning.withValues(alpha: 0.55),
        ),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: LuminaTokens.statusWarning,
          ),
          SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Windows FairPlay DRM 誠實說明',
                  style: TextStyle(
                    color: LuminaTokens.statusWarning,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  AppleMusicProvider.windowsFairPlayDrmNotice,
                  style: TextStyle(
                    color: Color(0xFFFDE68A),
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCollapsibleToggle({
    required Key toggleKey,
    required bool expanded,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: toggleKey,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Icon(
              expanded
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.keyboard_arrow_right_rounded,
              size: 18,
              color: LuminaTokens.glassTextPrimary,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHelperNote(String text) {
    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: LuminaTokens.textSecondary,
          fontSize: 12,
          height: 1.45,
        ),
      ),
    );
  }

  Widget _buildProgressCard(String msg) {
    final parsed = _parseDeviceCodeProgress(msg);
    return Container(
      key: const Key('login_dialog_progress'),
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.glassCoverRim),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: LuminaTokens.glassTextPrimary,
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceXs),
              Expanded(
                child: Text(
                  msg,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
          if (parsed.code != null || parsed.url != null) ...[
            const SizedBox(height: LuminaTokens.spaceXs),
            Wrap(
              spacing: LuminaTokens.spaceXs,
              runSpacing: LuminaTokens.spaceXs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (parsed.code != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: LuminaTokens.glassPillBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: LuminaTokens.glassPillBorder),
                    ),
                    child: SelectableText(
                      parsed.code!,
                      key: const Key('login_dialog_device_code'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                if (parsed.code != null)
                  OutlinedButton.icon(
                    key: const Key('btn_copy_device_code'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: parsed.code!));
                    },
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('複製代碼'),
                  ),
                if (parsed.url != null)
                  OutlinedButton.icon(
                    key: const Key('btn_open_device_url'),
                    onPressed: () async {
                      try {
                        await openSystemBrowser(parsed.url!);
                      } catch (_) {}
                    },
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                    label: const Text('開啟驗證頁面'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorBox(String message) {
    return Container(
      key: const Key('login_dialog_error'),
      padding: const EdgeInsets.all(LuminaTokens.spaceSm),
      decoration: BoxDecoration(
        color: LuminaTokens.statusError.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.statusError),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: SelectableText(
              message,
              style: const TextStyle(
                color: Color(0xFFFECACA),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
