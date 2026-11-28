part of 'streaming_login_dialog.dart';

extension _StreamingLoginProviderFormsExt on _StreamingLoginDialogState {
  Widget _buildPlatformForm() => switch (_kind) {
    'youtube_music' => _buildYouTubeMusicForm(),
    'tidal' => _buildTidalForm(),
    'qobuz' => _buildQobuzForm(),
    'deezer' => _buildDeezerForm(),
    'apple_music' => _buildAppleMusicForm(),
    _ => const SizedBox.shrink(),
  };

  Widget _buildYouTubeMusicForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTabBar(const [
          '瀏覽器 Cookie (SAPISID)',
          'Google OAuth 裝置登入 (BYOK Client ID/Secret)',
        ]),
        const SizedBox(height: LuminaTokens.spaceMd),
        if (_selectedTab == 0) ...[
          _buildHelperNote(
            '請於瀏覽器開啟 music.youtube.com 登入後，複製 Request Header 中的 Cookie 字串'
            '（須包含 SAPISID 或 __Secure-3PAPISID），系統將即時計算 SAPISIDHASH 驗證帳號。',
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_ytm_cookie'),
            controller: _ytCookieCtrl,
            enabled: !_submitting,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'YouTube Music Cookie（須含 SAPISID）',
              hintText: 'SAPISID=...; __Secure-3PAPISID=...; ...',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ] else ...[
          _buildHelperNote(
            '請輸入您於 Google Cloud Console 建立的 TV / Limited Input Device OAuth 2.0 '
            'Client ID 與 Client Secret，點擊下方按鈕後將取得一次性裝置驗證碼。',
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_ytm_client_id'),
            controller: _ytClientIdCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Google OAuth Client ID（必填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_ytm_client_secret'),
            controller: _ytClientSecretCtrl,
            enabled: !_submitting,
            obscureText: true,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Google OAuth Client Secret（選填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQobuzForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTabBar(const [
          '帳號密碼登入',
          'User Auth Token',
        ]),
        const SizedBox(height: LuminaTokens.spaceMd),
        if (_selectedTab == 0) ...[
          TextField(
            key: const Key('input_qobuz_email'),
            controller: _qobuzEmailCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Qobuz 帳號 Email / 使用者名稱',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_qobuz_password'),
            controller: _qobuzPasswordCtrl,
            enabled: !_submitting,
            obscureText: _obscureQobuzPassword,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: '密碼（將以 MD5 雜湊安全傳送至 Qobuz API）',
              borderRadius: LuminaTokens.radiusSm,
            ).copyWith(
              suffixIcon: IconButton(
                tooltip: _obscureQobuzPassword ? '顯示密碼' : '隱藏密碼',
                onPressed: () => _updateState(
                  () => _obscureQobuzPassword = !_obscureQobuzPassword,
                ),
                icon: Icon(
                  _obscureQobuzPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: LuminaTokens.textMuted,
                ),
              ),
            ),
          ),
        ] else ...[
          TextField(
            key: const Key('input_qobuz_user_token'),
            controller: _qobuzTokenCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Qobuz user_auth_token',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
        const SizedBox(height: LuminaTokens.spaceSm),
        _buildCollapsibleToggle(
          toggleKey: const Key('qobuz_byok_toggle'),
          expanded: _showByokAdvanced,
          title: '進階 / 自訂 App ID & Secret',
          onTap: () =>
              _updateState(() => _showByokAdvanced = !_showByokAdvanced),
        ),
        if (_showByokAdvanced) ...[
          const SizedBox(height: LuminaTokens.spaceXs),
          TextField(
            key: const Key('input_qobuz_app_id'),
            controller: _qobuzAppIdCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Qobuz App ID（必填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          TextField(
            key: const Key('input_qobuz_app_secret'),
            controller: _qobuzAppSecretCtrl,
            enabled: !_submitting,
            obscureText: true,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Qobuz App Secret（解析 Hi-Res 串流簽章用）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDeezerForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTabBar(const [
          'ARL Session Token',
          'OAuth 2.0 (BYOK App ID/Secret)',
        ]),
        const SizedBox(height: LuminaTokens.spaceMd),
        if (_selectedTab == 0) ...[
          _buildHelperNote(
            '請貼上您瀏覽器登入 Deezer 後的 arl Cookie 值，系統將即時向 Deezer Gateway 驗證會員資格與無損權限。',
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_deezer_arl'),
            controller: _deezerArlCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Deezer ARL Cookie 金鑰',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ] else ...[
          _buildHelperNote(
            '使用 Deezer OAuth 2.0 應用程式授權（需自備 App ID 與 App Secret），系統將啟動本機回呼伺服器並開啟瀏覽器完成授權。',
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_deezer_app_id'),
            controller: _deezerAppIdCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Deezer App ID（必填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_deezer_app_secret'),
            controller: _deezerAppSecretCtrl,
            enabled: !_submitting,
            obscureText: true,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Deezer App Secret（必填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_deezer_code'),
            controller: _deezerCodeCtrl,
            enabled: !_submitting,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: '手動 OAuth code（選填，留空則自動開啟瀏覽器）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAppleMusicForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('input_apple_dev_token'),
          controller: _appleDevTokenCtrl,
          enabled: !_submitting,
          minLines: 1,
          maxLines: 3,
          style: const TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: 12.5,
          ),
          decoration: LuminaSettingsStyles.inputDecoration(
            labelText: 'Apple Music Developer Token (JWT，必填)',
            borderRadius: LuminaTokens.radiusSm,
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        OutlinedButton.icon(
          key: const Key('btn_apple_musickit_browser'),
          onPressed: _submitting
              ? null
              : () => _authenticateWithParams(<String, dynamic>{
                  'mode': 'musickit_browser',
                  'developer_token': _appleDevTokenCtrl.text.trim(),
                }),
          style: LuminaSettingsStyles.outlinedButtonStyle(activeHighlight: true),
          icon: const Icon(Icons.open_in_browser_rounded, size: 17),
          label: const Text('透過瀏覽器 MusicKit 授權'),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        const Text(
          '或手動輸入 Music-User-Token：',
          style: TextStyle(
            color: LuminaTokens.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceXs),
        TextField(
          key: const Key('input_apple_user_token'),
          controller: _appleUserTokenCtrl,
          enabled: !_submitting,
          style: const TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: 12.5,
          ),
          decoration: LuminaSettingsStyles.inputDecoration(
            labelText: 'Apple Music-User-Token',
            borderRadius: LuminaTokens.radiusSm,
          ),
        ),
      ],
    );
  }
}
