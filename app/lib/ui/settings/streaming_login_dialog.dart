import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/streaming_models.dart';
import '../../services/streaming/local_browser_auth_service.dart';
import '../../services/streaming/oauth_helper.dart';
import '../../services/streaming/providers/apple_music_provider.dart';
import '../../services/streaming/providers/qobuz_provider.dart';
import '../../services/streaming/providers/tidal_provider.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/streaming/streaming_provider.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';

part 'streaming_login_auth_actions.dart';
part 'streaming_login_tidal_form.dart';
part 'streaming_login_provider_forms.dart';
part 'streaming_login_widgets.dart';

class StreamingLoginDialog extends StatefulWidget {
  final StreamingProvider provider;
  final StreamingManager streamingManager;

  const StreamingLoginDialog({
    super.key,
    required this.provider,
    required this.streamingManager,
  });

  static Future<bool?> show(
    BuildContext context,
    StreamingProvider provider,
    StreamingManager streamingManager,
  ) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StreamingLoginDialog(
        provider: provider,
        streamingManager: streamingManager,
      ),
    );
  }

  @override
  State<StreamingLoginDialog> createState() => _StreamingLoginDialogState();
}

class _StreamingLoginDialogState extends State<StreamingLoginDialog> {
  int _selectedTab = 0;
  bool _submitting = false;
  bool _submittingWebView = false;
  bool _showManualTokenSection = false;
  bool _showByokAdvanced = false;
  bool _showTidalManualFallback = false;
  String? _progressMessage;
  String? _errorMessage;
  String? _nonChromiumBrowserNotice;
  DetectedDefaultBrowser? _detectedBrowser;

  // YouTube Music
  final _ytCookieCtrl = TextEditingController();
  final _ytClientIdCtrl = TextEditingController();
  final _ytClientSecretCtrl = TextEditingController();

  // Tidal
  final _tidalAccessTokenCtrl = TextEditingController();
  final _tidalRefreshTokenCtrl = TextEditingController();
  final _tidalClientIdCtrl = TextEditingController();
  final _tidalClientSecretCtrl = TextEditingController();
  final _tidalManualCodeCtrl = TextEditingController();
  final _tidalManualVerifierCtrl = TextEditingController();

  // Qobuz
  final _qobuzEmailCtrl = TextEditingController();
  final _qobuzPasswordCtrl = TextEditingController();
  final _qobuzTokenCtrl = TextEditingController();
  final _qobuzAppIdCtrl = TextEditingController();
  final _qobuzAppSecretCtrl = TextEditingController();

  // Deezer
  final _deezerArlCtrl = TextEditingController();
  final _deezerAppIdCtrl = TextEditingController();
  final _deezerAppSecretCtrl = TextEditingController();
  final _deezerCodeCtrl = TextEditingController();

  // Apple Music
  final _appleDevTokenCtrl = TextEditingController();
  final _appleUserTokenCtrl = TextEditingController();

  bool _obscureQobuzPassword = true;
  bool _rememberTidalByok = true;
  bool _hasRememberedTidalByok = false;
  bool _tidalByokFromMemoryOnly = false;

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    _detectedBrowser = widget.streamingManager.detectLocalDefaultBrowser();
    if ((widget.provider.authState == StreamingAuthState.error ||
            widget.provider.authState == StreamingAuthState.authRequired) &&
        widget.provider.lastError != null &&
        widget.provider.lastError!.trim().isNotEmpty) {
      _errorMessage = widget.provider.lastError;
    }
    if (widget.provider.kind == 'tidal' && widget.provider is TidalProvider) {
      _loadRememberedTidalByok(widget.provider as TidalProvider);
    }
  }

  @override
  void dispose() {
    _ytCookieCtrl.dispose();
    _ytClientIdCtrl.dispose();
    _ytClientSecretCtrl.dispose();
    _tidalAccessTokenCtrl.dispose();
    _tidalRefreshTokenCtrl.dispose();
    _tidalClientIdCtrl.dispose();
    _tidalClientSecretCtrl.dispose();
    _tidalManualCodeCtrl.dispose();
    _tidalManualVerifierCtrl.dispose();
    _qobuzEmailCtrl.dispose();
    _qobuzPasswordCtrl.dispose();
    _qobuzTokenCtrl.dispose();
    _qobuzAppIdCtrl.dispose();
    _qobuzAppSecretCtrl.dispose();
    _deezerArlCtrl.dispose();
    _deezerAppIdCtrl.dispose();
    _deezerAppSecretCtrl.dispose();
    _deezerCodeCtrl.dispose();
    _appleDevTokenCtrl.dispose();
    _appleUserTokenCtrl.dispose();
    super.dispose();
  }

  String get _kind => widget.provider.kind;

  @override
  Widget build(BuildContext context) {
    final meta = widget.provider.meta;
    final account = widget.provider.accountInfo;
    final isConnected = widget.provider.authState == StreamingAuthState.connected;

    return PopScope<bool>(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop &&
            result != true &&
            (_submitting || widget.streamingManager.isAuthenticating(_kind))) {
          widget.streamingManager.cancelLogin(_kind);
        }
      },
      child: Dialog(
        key: Key('streaming_login_dialog_$_kind'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540, maxHeight: 720),
          child: FrostedGlassContainer(
            blurSigma: LuminaTokens.glassDialogBlur,
            color: LuminaTokens.glassDialogBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
            border: Border.all(color: LuminaTokens.glassCardBorder),
            padding: const EdgeInsets.all(LuminaTokens.spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    meta.buildBadge(boxSize: 34, borderRadius: 8),
                    const SizedBox(width: LuminaTokens.spaceSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${meta.name} 帳號驗證設定',
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            meta.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('btn_dialog_close'),
                      tooltip: '關閉視窗',
                      onPressed: _handleCloseDialog,
                      style: LuminaSettingsStyles.iconButtonStyle(),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isConnected && account != null) ...[
                          _buildConnectedAccountBanner(account),
                          const SizedBox(height: LuminaTokens.spaceSm),
                        ],
                        if (_kind == 'qobuz' &&
                            isConnected &&
                            widget.provider is QobuzProvider &&
                            !(widget.provider as QobuzProvider)
                                .hasAppSecret) ...[
                          _buildQobuzMissingSecretNotice(),
                          const SizedBox(height: LuminaTokens.spaceSm),
                        ],
                        if (_kind == 'apple_music') ...[
                          _buildAppleMusicDrmNoticeCard(),
                          const SizedBox(height: LuminaTokens.spaceMd),
                        ],
                        _buildWebViewPrimaryCard(),
                        const SizedBox(height: LuminaTokens.spaceMd),
                        _buildCollapsibleToggle(
                          toggleKey: const Key(
                            'btn_toggle_manual_token_section',
                          ),
                          expanded: _showManualTokenSection,
                          title: '進階／手動輸入 Token',
                          onTap: _submitting
                              ? () {}
                              : () => setState(() {
                                  _showManualTokenSection =
                                      !_showManualTokenSection;
                                }),
                        ),
                        if (_nonChromiumBrowserNotice != null) ...[
                          _buildNonChromiumAssistedBanner(
                            _nonChromiumBrowserNotice!,
                          ),
                          const SizedBox(height: LuminaTokens.spaceMd),
                        ],
                        if (_showManualTokenSection) ...[
                          const SizedBox(height: LuminaTokens.spaceSm),
                          _buildPlatformForm(),
                          const SizedBox(height: LuminaTokens.spaceMd),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                              key: const Key('btn_dialog_submit_login'),
                              onPressed: _submitting ? null : _submitPrimary,
                              style: LuminaSettingsStyles.filledButtonStyle(),
                              icon: (_submitting && !_submittingWebView)
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: LuminaTokens.onAccentDark,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.verified_user_outlined,
                                      size: 17,
                                    ),
                              label: Text(_primarySubmitLabel),
                            ),
                          ),
                        ],
                        if (_progressMessage != null) ...[
                          const SizedBox(height: LuminaTokens.spaceMd),
                          _buildProgressCard(_progressMessage!),
                        ],
                        if (_errorMessage != null) ...[
                          const SizedBox(height: LuminaTokens.spaceMd),
                          _buildErrorBox(_errorMessage!),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: LuminaTokens.spaceXs,
                  runSpacing: LuminaTokens.spaceXs,
                  children: [
                    OutlinedButton(
                      key: const Key('btn_dialog_cancel_login'),
                      onPressed: _handleCancelPressed,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _primarySubmitLabel {
    if (_submitting) return '驗證連線中...';
    return switch (_kind) {
      'tidal' when _selectedTab == 0 => '使用 Token 驗證登入',
      'tidal' when _selectedTab == 1 => '啟動瀏覽器 PKCE 授權',
      'tidal' => '請求 Tidal 裝置驗證碼',
      'youtube_music' when _selectedTab == 1 => '請求 Google 裝置驗證碼',
      'deezer' when _selectedTab == 1 => '啟動 Deezer OAuth 登入',
      'apple_music' => '使用 Token 驗證登入',
      _ => '驗證並登入',
    };
  }
}
