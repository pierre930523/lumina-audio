part of 'streaming_login_dialog.dart';

extension _StreamingLoginTidalFormExt on _StreamingLoginDialogState {
  Widget _buildTidalForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTabBar(const [
          'Token / Refresh Token 登入',
          'OAuth 2.0 PKCE 瀏覽器登入',
          'Device Code 裝置登入',
        ]),
        const SizedBox(height: LuminaTokens.spaceMd),
        if (_selectedTab == 0) ...[
          _buildHelperNote(
            '可貼上 Tidal Access Token 直接驗證，或只貼 Refresh Token 並於下方「進階 / 自訂 Client ID (BYOK)」'
            '填入對應 Client ID 與 Client Secret 自動換發登入（若將 o2_refresh 權杖直接貼於第一欄亦可自動識別；'
            '系統會自動去除 Authorization: / Bearer 前綴）。',
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_tidal_access_token'),
            controller: _tidalAccessTokenCtrl,
            enabled: !_submitting,
            minLines: 2,
            maxLines: 4,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Tidal Access Token（若已填 Refresh Token + Client ID 可留空）',
              hintText: 'eyJhbGciOi... 或 Bearer eyJhbGciOi...',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          TextField(
            key: const Key('input_tidal_refresh_token'),
            controller: _tidalRefreshTokenCtrl,
            enabled: !_submitting,
            minLines: 1,
            maxLines: 2,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Tidal Refresh Token（可單獨搭配 BYOK Client ID / Secret 換發登入）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ] else if (_selectedTab == 1) ...[
          _buildHelperNote(
            '點擊下方按鈕將自動開啟系統瀏覽器並監聽本機 127.0.0.1 回呼完成 Tidal OAuth 2.0 PKCE 授權；'
            '若瀏覽器未自動導向，亦可於下方展開手動授權碼備援。',
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          _buildCollapsibleToggle(
            toggleKey: const Key('tidal_manual_code_toggle'),
            expanded: _showTidalManualFallback,
            title: '手動授權碼備援（Code + Verifier）',
            onTap: () => _updateState(
              () => _showTidalManualFallback = !_showTidalManualFallback,
            ),
          ),
          if (_showTidalManualFallback) ...[
            const SizedBox(height: LuminaTokens.spaceXs),
            TextField(
              key: const Key('input_tidal_manual_code'),
              controller: _tidalManualCodeCtrl,
              enabled: !_submitting,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
              ),
              decoration: LuminaSettingsStyles.inputDecoration(
                labelText: '授權回傳碼（code，選填）',
                borderRadius: LuminaTokens.radiusSm,
              ),
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            TextField(
              key: const Key('input_tidal_manual_verifier'),
              controller: _tidalManualVerifierCtrl,
              enabled: !_submitting,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
              ),
              decoration: LuminaSettingsStyles.inputDecoration(
                labelText: 'PKCE code_verifier（選填）',
                borderRadius: LuminaTokens.radiusSm,
              ),
            ),
          ],
        ] else ...[
          _buildHelperNote(
            '使用 Tidal Device Authorization 流程，將顯示驗證網址與一次性代碼，於任意瀏覽器確認授權即可完成登入。',
          ),
        ],
        if (_hasRememberedTidalByok &&
            _tidalClientIdCtrl.text.trim().isNotEmpty) ...[
          const SizedBox(height: LuminaTokens.spaceSm),
          Container(
            key: const Key('tidal_remembered_byok_badge'),
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceSm,
              vertical: LuminaTokens.spaceXs,
            ),
            decoration: BoxDecoration(
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              border: Border.all(color: LuminaTokens.glassPillBorder),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.key_outlined,
                  size: 16,
                  color: LuminaTokens.glassTextPrimary,
                ),
                const SizedBox(width: LuminaTokens.spaceXs),
                Expanded(
                  child: Text(
                    '已載入本機 DPAPI 記憶的 Client ID（${maskSecretForLog(_tidalClientIdCtrl.text)}），可直接貼入 Refresh Token 登入',
                    style: const TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('btn_clear_tidal_byok'),
                  onPressed: _submitting ? null : _clearRememberedTidalByok,
                  child: const Text(
                    '清除記憶',
                    style: TextStyle(
                      color: LuminaTokens.statusError,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: LuminaTokens.spaceSm),
        _buildCollapsibleToggle(
          toggleKey: const Key('tidal_byok_toggle'),
          expanded: _showByokAdvanced,
          title: '進階 / 自訂 Client ID (BYOK)',
          onTap: () => _updateState(() {
            _showByokAdvanced = !_showByokAdvanced;
            if (_showByokAdvanced) {
              _tidalByokFromMemoryOnly = false;
            }
          }),
        ),
        if (_showByokAdvanced) ...[
          const SizedBox(height: LuminaTokens.spaceXs),
          TextField(
            key: const Key('input_tidal_client_id'),
            controller: _tidalClientIdCtrl,
            enabled: !_submitting,
            onChanged: (_) => _tidalByokFromMemoryOnly = false,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: _selectedTab == 0
                  ? 'Tidal Client ID（使用 Refresh Token 登入時必填）'
                  : 'Tidal Client ID（必填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          TextField(
            key: const Key('input_tidal_client_secret'),
            controller: _tidalClientSecretCtrl,
            enabled: !_submitting,
            obscureText: true,
            onChanged: (_) => _tidalByokFromMemoryOnly = false,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 12.5,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Tidal Client Secret（選填，部分客戶端需提供）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceXs),
          InkWell(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            onTap: _submitting
                ? null
                : () => _updateState(
                    () => _rememberTidalByok = !_rememberTidalByok,
                  ),
            child: Row(
              children: [
                Checkbox(
                  key: const Key('chk_tidal_remember_byok'),
                  value: _rememberTidalByok,
                  onChanged: _submitting
                      ? null
                      : (v) => _updateState(
                          () => _rememberTidalByok = v ?? true,
                        ),
                ),
                const Expanded(
                  child: Text(
                    '記住此 Client ID / Client Secret 於本機（Windows DPAPI 加密，登出帳號時仍保留）',
                    style: TextStyle(
                      color: LuminaTokens.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
