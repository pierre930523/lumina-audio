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

  Future<void> _loadRememberedTidalByok(TidalProvider tidal) async {
    final byok = await tidal.readRememberedByok();
    if (!mounted || byok == null) return;
    setState(() {
      _hasRememberedTidalByok = true;
      if (_tidalClientIdCtrl.text.trim().isEmpty &&
          _tidalClientSecretCtrl.text.trim().isEmpty) {
        _tidalClientIdCtrl.text = byok.clientId;
        _tidalClientSecretCtrl.text = byok.clientSecret;
        _tidalByokFromMemoryOnly = true;
      }
    });
  }

  Future<void> _clearRememberedTidalByok() async {
    final p = widget.provider;
    if (p is TidalProvider) {
      await p.clearRememberedByok();
    }
    if (!mounted) return;
    setState(() {
      _hasRememberedTidalByok = false;
      _tidalByokFromMemoryOnly = false;
      _tidalClientIdCtrl.clear();
      _tidalClientSecretCtrl.clear();
    });
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

  Future<void> _authenticateWithParams(Map<String, dynamic> params) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
      _progressMessage = '正在連線至 ${widget.provider.meta.name} 伺服器驗證...';
    });

    try {
      await widget.streamingManager.authenticateProvider(
        _kind,
        params,
        onProgress: (msg) {
          if (!mounted) return;
          setState(() {
            _progressMessage = msg;
          });
        },
      );
      if (!mounted) return;
      if (widget.provider.authState == StreamingAuthState.connected) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _submitting = false;
          _errorMessage = widget.provider.lastError ?? '驗證未完成';
        });
      }
    } on StreamingException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        _errorMessage = e.isCancelled ? null : e.message;
        if (!e.isCancelled &&
            _kind == 'tidal' &&
            !_showByokAdvanced &&
            e.message.contains('Client ID')) {
          _showByokAdvanced = true;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        _errorMessage = e.toString();
      });
    }
  }

  Map<String, dynamic>? _collectPlanBFallbackParams() {
    switch (_kind) {
      case 'youtube_music':
        final clientId = _ytClientIdCtrl.text.trim();
        if (clientId.isEmpty) return null;
        final clientSecret = _ytClientSecretCtrl.text.trim();
        return <String, dynamic>{
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        };
      case 'tidal':
        if (_tidalByokFromMemoryOnly && !_showByokAdvanced) return null;
        final clientId = _tidalClientIdCtrl.text.trim();
        if (clientId.isEmpty) return null;
        final clientSecret = _tidalClientSecretCtrl.text.trim();
        return <String, dynamic>{
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        };
      case 'deezer':
        final appId = _deezerAppIdCtrl.text.trim();
        final appSecret = _deezerAppSecretCtrl.text.trim();
        if (appId.isEmpty || appSecret.isEmpty) return null;
        return <String, dynamic>{
          'app_id': appId,
          'app_secret': appSecret,
        };
      case 'apple_music':
        final devToken = _appleDevTokenCtrl.text.trim();
        if (devToken.isEmpty) return null;
        return <String, dynamic>{'developer_token': devToken};
      default:
        return null;
    }
  }

  Future<void> _submitWebViewLogin() async {
    if (_submitting) return;
    final detectedName = _detectedBrowser?.displayName;
    setState(() {
      _submitting = true;
      _submittingWebView = true;
      _errorMessage = null;
      _nonChromiumBrowserNotice = null;
      _progressMessage = detectedName != null
          ? '正在啟動 $detectedName 登入視窗...'
          : '正在啟動本地系統瀏覽器登入視窗...';
    });

    try {
      await widget.streamingManager.authenticateWithLocalBrowser(
        _kind,
        clearSession: widget.provider.authState == StreamingAuthState.error ||
            widget.provider.authState == StreamingAuthState.authRequired,
        fallbackParams: _collectPlanBFallbackParams(),
        onProgress: (msg) {
          if (!mounted) return;
          setState(() {
            _progressMessage = msg;
          });
        },
      );
      if (!mounted) return;
      if (widget.provider.authState == StreamingAuthState.connected) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _submitting = false;
          _submittingWebView = false;
          _progressMessage = null;
          _errorMessage = widget.provider.lastError ?? '驗證未完成';
        });
      }
    } on StreamingException catch (e) {
      if (!mounted) return;
      final isNonChromiumMsg = e.message.contains('非 Chromium') ||
          (_detectedBrowser != null && !_detectedBrowser!.isChromium);
      setState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        if (e.isCancelled) {
          _errorMessage = null;
          _nonChromiumBrowserNotice = null;
        } else {
          if (e.isWebViewUnavailable) {
            _showManualTokenSection = true;
          }
          if (e.isWebViewUnavailable && isNonChromiumMsg) {
            _nonChromiumBrowserNotice = e.message;
            _errorMessage = null;
          } else {
            _errorMessage = e.message;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submittingWebView = false;
        _progressMessage = null;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _submitPrimary() async {
    switch (_kind) {
      case 'youtube_music':
        if (_selectedTab == 0) {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'cookie',
            'cookie': _ytCookieCtrl.text.trim(),
          });
        } else {
          final secret = _ytClientSecretCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'oauth_device',
            'client_id': _ytClientIdCtrl.text.trim(),
            if (secret.isNotEmpty) 'client_secret': secret,
          });
        }
        return;
      case 'tidal':
        final clientId = _tidalClientIdCtrl.text.trim();
        final clientSecret = _tidalClientSecretCtrl.text.trim();
        if (_selectedTab == 0) {
          final refreshToken = _tidalRefreshTokenCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'access_token',
            'access_token': _tidalAccessTokenCtrl.text.trim(),
            if (refreshToken.isNotEmpty) 'refresh_token': refreshToken,
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'remember_byok': _rememberTidalByok,
          });
          return;
        }
        if (clientId.isEmpty && !_showByokAdvanced) {
          setState(() {
            _showByokAdvanced = true;
          });
        }
        if (_selectedTab == 1) {
          final code = _tidalManualCodeCtrl.text.trim();
          final verifier = _tidalManualVerifierCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'pkce',
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            if (code.isNotEmpty) 'code': code,
            if (verifier.isNotEmpty) 'code_verifier': verifier,
            'remember_byok': _rememberTidalByok,
          });
        } else {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'device_code',
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'remember_byok': _rememberTidalByok,
          });
        }
        return;
      case 'qobuz':
        final appId = _qobuzAppIdCtrl.text.trim();
        final appSecret = _qobuzAppSecretCtrl.text.trim();
        if (appId.isEmpty && !_showByokAdvanced) {
          setState(() {
            _showByokAdvanced = true;
          });
        }
        if (_selectedTab == 0) {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'credentials',
            'email': _qobuzEmailCtrl.text.trim(),
            'password': _qobuzPasswordCtrl.text,
            'app_id': appId,
            if (appSecret.isNotEmpty) 'app_secret': appSecret,
          });
        } else {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'token',
            'user_auth_token': _qobuzTokenCtrl.text.trim(),
            'app_id': appId,
            if (appSecret.isNotEmpty) 'app_secret': appSecret,
          });
        }
        return;
      case 'deezer':
        if (_selectedTab == 0) {
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'arl',
            'arl': _deezerArlCtrl.text.trim(),
          });
        } else {
          final code = _deezerCodeCtrl.text.trim();
          await _authenticateWithParams(<String, dynamic>{
            'mode': 'oauth',
            'app_id': _deezerAppIdCtrl.text.trim(),
            'app_secret': _deezerAppSecretCtrl.text.trim(),
            if (code.isNotEmpty) 'code': code,
          });
        }
        return;
      case 'apple_music':
        await _authenticateWithParams(<String, dynamic>{
          'mode': 'musickit_tokens',
          'developer_token': _appleDevTokenCtrl.text.trim(),
          'music_user_token': _appleUserTokenCtrl.text.trim(),
        });
        return;
      default:
        return;
    }
  }

  void _handleCancelPressed() {
    if (_submitting || widget.streamingManager.isAuthenticating(_kind)) {
      widget.streamingManager.cancelLogin(_kind);
      return;
    }
    Navigator.of(context).pop(false);
  }

  void _handleCloseDialog() {
    if (_submitting || widget.streamingManager.isAuthenticating(_kind)) {
      widget.streamingManager.cancelLogin(_kind);
    }
    Navigator.of(context).pop(false);
  }

  ({String? url, String? code}) _parseDeviceCodeProgress(String? msg) {
    if (msg == null || msg.isEmpty) return (url: null, code: null);
    final urlMatch = RegExp(r'https?://[^\s]+').firstMatch(msg);
    final codeMatch = RegExp(r'(?:代碼|驗證碼)：([^\s]+)').firstMatch(msg);
    return (
      url: urlMatch?.group(0),
      code: codeMatch?.group(1),
    );
  }

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
                          !(widget.provider as QobuzProvider).hasAppSecret) ...[
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
                        toggleKey: const Key('btn_toggle_manual_token_section'),
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
                    : (_) => setState(() {
                          _selectedTab = i;
                          _errorMessage = null;
                        }),
              ),
          ],
        ),
      ),
    );
  }

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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: 'Google OAuth Client Secret（選填）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
      ],
    );
  }

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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            onTap: () => setState(
              () => _showTidalManualFallback = !_showTidalManualFallback,
            ),
          ),
          if (_showTidalManualFallback) ...[
            const SizedBox(height: LuminaTokens.spaceXs),
            TextField(
              key: const Key('input_tidal_manual_code'),
              controller: _tidalManualCodeCtrl,
              enabled: !_submitting,
              style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
              style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
              border: Border.all(
                color: LuminaTokens.glassPillBorder,
              ),
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
          onTap: () => setState(() {
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
                : () => setState(
                    () => _rememberTidalByok = !_rememberTidalByok,
                  ),
            child: Row(
              children: [
                Checkbox(
                  key: const Key('chk_tidal_remember_byok'),
                  value: _rememberTidalByok,
                  onChanged: _submitting
                      ? null
                      : (v) => setState(
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: '密碼（將以 MD5 雜湊安全傳送至 Qobuz API）',
              borderRadius: LuminaTokens.radiusSm,
            ).copyWith(
              suffixIcon: IconButton(
                tooltip: _obscureQobuzPassword ? '顯示密碼' : '隱藏密碼',
                onPressed: () => setState(
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
          onTap: () => setState(() => _showByokAdvanced = !_showByokAdvanced),
        ),
        if (_showByokAdvanced) ...[
          const SizedBox(height: LuminaTokens.spaceXs),
          TextField(
            key: const Key('input_qobuz_app_id'),
            controller: _qobuzAppIdCtrl,
            enabled: !_submitting,
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
            style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
            decoration: LuminaSettingsStyles.inputDecoration(
              labelText: '手動 OAuth code（選填，留空則自動開啟瀏覽器）',
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
      ],
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
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
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
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 12.5),
          decoration: LuminaSettingsStyles.inputDecoration(
            labelText: 'Apple Music-User-Token',
            borderRadius: LuminaTokens.radiusSm,
          ),
        ),
      ],
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
