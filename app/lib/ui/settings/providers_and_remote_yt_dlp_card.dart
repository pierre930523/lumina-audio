part of 'providers_and_remote_panel.dart';

extension _ProvidersAndRemoteYtDlpExt on _ProvidersAndRemotePanelState {
  Widget _buildYtDlpEngineCard() {
    return ListenableBuilder(
      listenable: _ytDlpService,
      builder: (context, _) {
        final env = _ytDlpService.status;
        final ytDlpSummary = env.isYtDlpAvailable
            ? (env.ytDlpVersion != null && env.ytDlpVersion!.isNotEmpty
                  ? '${env.ytDlpSource.label} · ${env.ytDlpVersion}'
                  : env.ytDlpSource.label)
            : env.ytDlpSource.label;

        final String denoSummary;
        if (env.isDenoAvailable) {
          final ver = env.denoVersion?.trim();
          if (ver != null && ver.isNotEmpty) {
            final prefixed = ver.startsWith('v') || ver.startsWith('V')
                ? ver
                : 'v$ver';
            denoSummary = '已就緒 ($prefixed)';
          } else {
            denoSummary = '已就緒';
          }
        } else {
          denoSummary = '未偵測到';
        }

        final ffmpegSummary = env.isFfmpegAvailable ? '已就緒' : '未偵測到';

        final compactOutlined = LuminaSettingsStyles.outlinedButtonStyle()
            .copyWith(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceSm,
                  vertical: LuminaTokens.spaceXs,
                ),
              ),
              minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
            );

        return SettingsGroupCard(
          key: const Key('yt_dlp_engine_card'),
          title: '串流解析引擎 (yt-dlp)',
          children: [
            _buildEngineStatusRow(
              key: const Key('yt_dlp_status_row'),
              label: 'yt-dlp',
              value: ytDlpSummary,
              isReady: env.isYtDlpAvailable,
              tooltip: env.ytDlpPath,
            ),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            _buildEngineStatusRow(
              key: const Key('deno_status_row'),
              label: 'Deno 執行時期',
              value: denoSummary,
              isReady: env.isDenoAvailable,
              tooltip: env.denoPath,
            ),
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            _buildEngineStatusRow(
              key: const Key('ffmpeg_status_row'),
              label: 'FFmpeg 轉碼引擎',
              value: ffmpegSummary,
              isReady: env.isFfmpegAvailable,
              tooltip: env.ffmpegVersion != null
                  ? 'FFmpeg ${env.ffmpegVersion}'
                  : env.ffmpegPath,
            ),
            if (env.lastUpdateMessage != null &&
                env.lastUpdateMessage!.isNotEmpty) ...[
              const Divider(color: LuminaTokens.glassCardDivider, height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                  vertical: LuminaTokens.spaceXs,
                ),
                child: Text(
                  env.lastUpdateMessage!,
                  key: const Key('yt_dlp_update_feedback'),
                  style: TextStyle(
                    color: env.lastUpdateMessage!.startsWith('更新失敗')
                        ? LuminaTokens.statusError
                        : (env.isUpdating
                              ? LuminaTokens.glassTextPrimary
                              : LuminaTokens.statusSuccess),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
            const Divider(color: LuminaTokens.glassCardDivider, height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
                vertical: LuminaTokens.spaceSm,
              ),
              child: Wrap(
                spacing: LuminaTokens.spaceXs,
                runSpacing: LuminaTokens.spaceXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_check_update_yt_dlp'),
                    onPressed: env.isUpdating ? null : _checkAndUpdateYtDlp,
                    style: LuminaSettingsStyles.filledButtonStyle(
                      padding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceSm,
                        vertical: LuminaTokens.spaceXs,
                      ),
                      minimumSize: const Size(0, 34),
                    ),
                    icon: env.isUpdating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: LuminaTokens.textDisabled,
                            ),
                          )
                        : const Icon(
                            Icons.system_update_alt_rounded,
                            size: 16,
                          ),
                    label: Text(
                      env.isUpdating ? '更新中...' : '檢查並更新 yt-dlp',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_view_yt_dlp_licenses'),
                    onPressed: () => ThirdPartyLicensesDialog.show(
                      context,
                      ytDlpService: _ytDlpService,
                    ),
                    style: compactOutlined,
                    icon: const Icon(Icons.description_outlined, size: 15),
                    label: const Text(
                      '檢視開源授權',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEngineStatusRow({
    Key? key,
    required String label,
    required String value,
    required bool isReady,
    String? tooltip,
  }) {
    final valueWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: isReady
                ? LuminaTokens.statusSuccess
                : LuminaTokens.statusWarning,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isReady
                  ? LuminaTokens.textSecondary
                  : LuminaTokens.textMuted,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd + LuminaTokens.space2xs,
        vertical: LuminaTokens.spaceXs + 2,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceMd),
          Flexible(
            flex: 3,
            child: tooltip != null && tooltip.isNotEmpty
                ? Tooltip(message: tooltip, child: valueWidget)
                : valueWidget,
          ),
        ],
      ),
    );
  }
}
