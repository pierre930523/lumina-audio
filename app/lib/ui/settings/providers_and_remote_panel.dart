import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/streaming/secure_credential_store.dart';
import '../../services/streaming/streaming_manager.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';
import 'streaming_login_dialog.dart';

class ProvidersAndRemotePanel extends StatefulWidget {
  final AudioService audioService;
  final StreamingManager? streamingManager;
  final VoidCallback? onProvidersChanged;

  const ProvidersAndRemotePanel({
    super.key,
    required this.audioService,
    this.streamingManager,
    this.onProvidersChanged,
  });

  @override
  State<ProvidersAndRemotePanel> createState() =>
      _ProvidersAndRemotePanelState();
}

class _ProvidersAndRemotePanelState extends State<ProvidersAndRemotePanel> {
  static const _activeRowBg = LuminaTokens.cardElevatedBg;
  static const _cardBg = LuminaTokens.cardBg;
  static const _dividerColor = LuminaTokens.borderSubtle;
  static const _accentLavender = LuminaTokens.accentPurpleText;
  static const _accentBlue = LuminaTokens.accentBlue;

  final _webdavUriCtrl = TextEditingController();
  final _smbUriCtrl = TextEditingController();
  final _remoteUrlCtrl = TextEditingController(text: 'http://127.0.0.1:9888');
  final _remotePinCtrl = TextEditingController();
  final _wanUrlCtrl = TextEditingController(text: 'https://lumina.example.com');

  late final StreamingManager _streamingManager;
  late final bool _ownsStreamingManager;

  PairingInitiateInfo? _hostPairInfo;
  List<DiscoveredServerInfo> _lanServers = const [];
  List<ProviderStatusInfo> _providers = const [];
  final Set<String> _syncingKinds = <String>{};
  String? _status;
  bool _statusIsError = false;

  String? _expandedSection;
  String? _selectedActiveProvider;

  @override
  void initState() {
    super.initState();
    _ownsStreamingManager = widget.streamingManager == null;
    _streamingManager = widget.streamingManager ??
        StreamingManager(
          credentialStore: Platform.environment.containsKey('FLUTTER_TEST')
              ? MemorySecureCredentialStore()
              : null,
        );
    _streamingManager.addListener(_onStreamingChanged);
    _syncActiveStreamingSelection();
    _loadProviders();
  }

  @override
  void dispose() {
    _streamingManager.removeListener(_onStreamingChanged);
    if (_ownsStreamingManager) {
      _streamingManager.dispose();
    }
    _webdavUriCtrl.dispose();
    _smbUriCtrl.dispose();
    _remoteUrlCtrl.dispose();
    _remotePinCtrl.dispose();
    _wanUrlCtrl.dispose();
    super.dispose();
  }

  void _onStreamingChanged() {
    if (!mounted) return;
    _syncActiveStreamingSelection();
    setState(() {});
  }

  void _syncActiveStreamingSelection() {
    final connected = _streamingManager.connectedProviders;
    if (_selectedActiveProvider != null) {
      final isStreaming =
          StreamingProviderMeta.isStreamingKind(_selectedActiveProvider!);
      if (isStreaming &&
          !connected.any((p) => p.kind == _selectedActiveProvider)) {
        _selectedActiveProvider = null;
      }
    }
    _selectedActiveProvider ??= connected.firstOrNull?.kind;
  }

  Future<void> _loadProviders() async {
    final list = await widget.audioService.listProviders();
    if (!mounted) return;
    setState(() {
      _providers = list;
      _syncActiveStreamingSelection();
      _selectedActiveProvider ??= list
          .where(
            (p) =>
                !StreamingProviderMeta.isStreamingKind(p.kind) &&
                p.kind != 'local' &&
                (p.isOnline || p.isConfigured),
          )
          .firstOrNull
          ?.kind;
    });
  }

  ProviderStatusInfo? _statusFor(String kind) =>
      _providers.where((p) => p.kind == kind).firstOrNull;

  void _toggleExpand(String id) {
    setState(() {
      _expandedSection = _expandedSection == id ? null : id;
    });
  }

  Future<void> _openStreamingLoginDialog(StreamingProviderMeta meta) async {
    final provider = _streamingManager.providerFor(meta.kind);
    if (provider == null) return;
    final ok = await StreamingLoginDialog.show(
      context,
      provider,
      _streamingManager,
    );
    if (!mounted) return;
    if (ok == true && provider.authState == StreamingAuthState.connected) {
      _selectedActiveProvider = meta.kind;
      widget.onProvidersChanged?.call();
      setState(() {
        _statusIsError = false;
        final name = provider.accountInfo?.displayName ?? meta.name;
        _status = '已完成 ${meta.name} 驗證登入（$name）';
      });
    } else {
      _syncActiveStreamingSelection();
      widget.onProvidersChanged?.call();
      setState(() {});
    }
  }

  Future<void> _syncStreamingProvider(String kind, String displayName) async {
    if (_syncingKinds.contains(kind)) return;
    setState(() => _syncingKinds.add(kind));
    try {
      final catalog = await _streamingManager.syncProvider(kind);
      widget.onProvidersChanged?.call();
      if (!mounted) return;
      setState(() {
        _statusIsError = false;
        _status =
            '已完成 $displayName 曲庫同步（${catalog.tracks.length} 首曲目、${catalog.playlists.length} 個歌單）';
      });
    } on StreamingException catch (e) {
      if (!mounted) return;
      setState(() {
        _statusIsError = true;
        _status = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusIsError = true;
        _status = '$displayName 曲庫同步失敗：$e';
      });
    } finally {
      if (mounted) {
        setState(() => _syncingKinds.remove(kind));
      }
    }
  }

  Future<void> _logoutStreamingProvider(String kind, String displayName) async {
    await _streamingManager.logoutProvider(kind);
    await _loadProviders();
    widget.onProvidersChanged?.call();
    if (!mounted) return;
    setState(() {
      _syncActiveStreamingSelection();
      _statusIsError = false;
      _status = '已登出 $displayName';
    });
  }

  Future<void> _submitSingleTokenProvider({
    required String kind,
    required TextEditingController controller,
    required String emptyWarning,
    required Map<String, dynamic> Function(String value) payloadBuilder,
    required String successMessage,
    bool activateAfterLogin = true,
  }) async {
    final val = controller.text.trim();
    if (val.isEmpty) {
      setState(() {
        _statusIsError = true;
        _status = emptyWarning;
      });
      return;
    }
    final ok = await widget.audioService.configureProvider(
      kind,
      payloadBuilder(val),
    );
    if (!ok) {
      if (!mounted) return;
      setState(() {
        _statusIsError = true;
        _status = '$kind 驗證失敗，請確認授權權杖或位址格式';
      });
      return;
    }
    await _loadProviders();
    widget.onProvidersChanged?.call();
    if (!mounted) return;
    setState(() {
      _statusIsError = false;
      if (activateAfterLogin) {
        _selectedActiveProvider = kind;
      }
      _status = successMessage;
    });
  }

  Future<void> _disconnectProvider(String kind, String displayName) async {
    await widget.audioService.configureProvider(kind, {'disconnect': true});
    await _loadProviders();
    widget.onProvidersChanged?.call();
    if (!mounted) return;
    setState(() {
      if (_selectedActiveProvider == kind) {
        _selectedActiveProvider = _providers
            .where(
              (p) =>
                  !StreamingProviderMeta.isStreamingKind(p.kind) &&
                  p.kind != 'local' &&
                  (p.isOnline || p.isConfigured),
            )
            .firstOrNull
            ?.kind;
      }
      _statusIsError = false;
      _status = '已登出 $displayName';
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.audioService.connectionMode;

    return SingleChildScrollView(
      key: const Key('providers_and_remote_panel'),
      padding: const EdgeInsets.only(
        bottom: LuminaTokens.bottomScrollClearance,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: LuminaTokens.spaceMd),
                child: Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LuminaTokens.spaceMd,
                      vertical: LuminaTokens.spaceSm,
                    ),
                    decoration: BoxDecoration(
                      color: _statusIsError
                          ? LuminaTokens.statusErrorBg
                          : LuminaTokens.statusSuccess.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                      border: Border.all(
                        color: _statusIsError
                            ? LuminaTokens.statusError
                            : LuminaTokens.statusSuccess.withValues(
                                alpha: 0.45,
                              ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _statusIsError
                              ? Icons.error_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          color: _statusIsError
                              ? LuminaTokens.statusError
                              : LuminaTokens.statusSuccess,
                          size: 18,
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        Expanded(
                          child: Text(
                            _status!,
                            style: TextStyle(
                              color: _statusIsError
                                  ? const Color(0xFFFECACA)
                                  : LuminaTokens.statusSuccess,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Section 1: Streaming Services
            _buildSectionHeader(
              icon: Icons.library_music_outlined,
              label: '串流音樂服務',
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            ListenableBuilder(
              listenable: _streamingManager,
              builder: (context, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final meta in StreamingProviderMeta.streamingServices)
                      _buildStreamingProviderRow(meta),
                  ],
                );
              },
            ),

            const SizedBox(height: LuminaTokens.spaceLg),

            // Section 2: Network Shares
            _buildSectionHeader(
              icon: Icons.cloud_queue_rounded,
              label: '網路共享資料庫',
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            _buildProviderItem(
              kind: 'web_dav',
              name: 'WebDAV 遠端伺服器',
              badgeColor: const Color(0xFF0D9488),
              iconGlyph: const Icon(
                Icons.cloud_outlined,
                color: LuminaTokens.textPrimary,
                size: 15,
              ),
              formBuilder: () => _buildSingleFieldForm(
                inputKey: const Key('input_webdav_uri'),
                buttonKey: const Key('btn_save_webdav'),
                controller: _webdavUriCtrl,
                labelText: 'WebDAV 伺服器位址（http(s)://...）',
                buttonLabel: '儲存 WebDAV',
                onSubmit: () => _submitSingleTokenProvider(
                  kind: 'web_dav',
                  controller: _webdavUriCtrl,
                  emptyWarning: '請先輸入 WebDAV 伺服器位址',
                  payloadBuilder: (v) => {'uri': v},
                  successMessage: '已完成 WebDAV 遠端磁碟設定',
                  activateAfterLogin: false,
                ),
              ),
            ),
            _buildProviderItem(
              kind: 'smb',
              name: 'SMB / NAS 網路芳鄰',
              badgeColor: const Color(0xFFD97706),
              iconGlyph: const Icon(
                Icons.folder_shared_outlined,
                color: LuminaTokens.textPrimary,
                size: 15,
              ),
              formBuilder: () => _buildSingleFieldForm(
                inputKey: const Key('input_smb_uri'),
                buttonKey: const Key('btn_save_smb'),
                controller: _smbUriCtrl,
                labelText: 'SMB 網路芳鄰位址（smb://帳號:密碼@主機/共享目錄）',
                buttonLabel: '儲存 SMB',
                onSubmit: () => _submitSingleTokenProvider(
                  kind: 'smb',
                  controller: _smbUriCtrl,
                  emptyWarning: '請先輸入 SMB 網路芳鄰位址',
                  payloadBuilder: (v) => {'uri': v},
                  successMessage: '已完成 SMB 網路芳鄰設定',
                  activateAfterLogin: false,
                ),
              ),
            ),

            const SizedBox(height: LuminaTokens.spaceLg),

            // Section 3: Dual-Mode & Remote Core Pairing
            _buildSectionHeader(
              icon: Icons.hub_outlined,
              label: '雙模式切換與遠端核心配對',
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            _buildRemotePairingCard(mode),
          ],
        ),
      ),
    );
  }

  Widget _buildStreamingProviderRow(StreamingProviderMeta meta) {
    final kind = meta.kind;
    final provider = _streamingManager.providerFor(kind);
    final authState = provider?.authState ?? StreamingAuthState.disconnected;
    final isAuthenticating =
        _streamingManager.isAuthenticating(kind) ||
        authState == StreamingAuthState.authenticating;
    final isConnected = !isAuthenticating && authState == StreamingAuthState.connected;
    final isError = !isAuthenticating && authState == StreamingAuthState.error;
    final isInUse = _selectedActiveProvider == kind && isConnected;
    final isSyncing = _syncingKinds.contains(kind);
    final info = provider?.accountInfo;

    final String? subtitleText;
    final Color subtitleColor;
    if (isAuthenticating) {
      subtitleText = _streamingManager.progressMessageFor(kind) ?? '連線中...';
      subtitleColor = LuminaTokens.accentBlue;
    } else if (isConnected) {
      final accountLabel = info != null
          ? ((info.planTier != null && info.planTier!.isNotEmpty)
                ? '${info.displayName} • ${info.planTier}'
                : info.displayName)
          : '已登入就緒';
      subtitleText = isInUse ? '$accountLabel • 使用中' : accountLabel;
      subtitleColor = isInUse ? LuminaTokens.textSecondary : LuminaTokens.statusSuccess;
    } else if (isError) {
      subtitleText = provider?.lastError ?? '授權驗證失敗，請重新登入';
      subtitleColor = LuminaTokens.statusError;
    } else {
      subtitleText = null;
      subtitleColor = LuminaTokens.textMuted;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.space2xs),
      child: Material(
        color: isInUse ? _activeRowBg : Colors.transparent,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        child: InkWell(
          key: Key('provider_row_$kind'),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          mouseCursor: SystemMouseCursors.click,
          hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.6),
          focusColor: LuminaTokens.focusRing.withValues(alpha: 0.16),
          onTap: isAuthenticating ? null : () => _openStreamingLoginDialog(meta),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceMd,
              vertical: LuminaTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
              border: Border.all(
                color: isInUse
                    ? LuminaTokens.borderControl
                    : (isError
                          ? LuminaTokens.statusError.withValues(alpha: 0.5)
                          : Colors.transparent),
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
                          : LuminaTokens.cardElevatedBg,
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
                          color: LuminaTokens.accentBlue,
                        ),
                      ),
                      const Text(
                        '連線中...',
                        style: TextStyle(
                          color: LuminaTokens.accentBlue,
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
                            hoverColor: LuminaTokens.cardHoverBg,
                            focusColor: LuminaTokens.focusRing.withValues(
                              alpha: 0.24,
                            ),
                            onTap: () {
                              setState(() {
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
                                        color: _accentLavender,
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
                                          color: LuminaTokens.borderControl,
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
                      foregroundColor: LuminaTokens.accentBlue,
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
      padding: const EdgeInsets.only(bottom: LuminaTokens.space2xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: isInUse ? _activeRowBg : Colors.transparent,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
            child: InkWell(
              key: Key('provider_row_$kind'),
              borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.6),
              focusColor: LuminaTokens.focusRing.withValues(alpha: 0.16),
              onTap: () => _toggleExpand(kind),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceMd,
                  vertical: LuminaTokens.spaceSm,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  border: Border.all(
                    color: isInUse
                        ? LuminaTokens.borderControl
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: isInUse
                            ? badgeColor
                            : LuminaTokens.cardElevatedBg,
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        border: isInUse
                            ? null
                            : Border.all(
                                color: isConfigured
                                    ? LuminaTokens.borderControl
                                    : _dividerColor,
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
                                  color: LuminaTokens.accentBlue,
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
                            hoverColor: LuminaTokens.cardHoverBg,
                            focusColor: LuminaTokens.focusRing.withValues(
                              alpha: 0.24,
                            ),
                            onTap: () {
                              setState(() {
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
                                        color: _accentLavender,
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
                                          color: LuminaTokens.borderControl,
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
                      color: _cardBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusMd,
                      ),
                      border: Border.all(color: _dividerColor),
                    ),
                    child: formBuilder(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildRemotePairingCard(ConnectionMode mode) {
    final isExpanded = _expandedSection == 'remote';
    final isRemoteActive = mode != ConnectionMode.localOrUsbDac;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: isRemoteActive ? _activeRowBg : _cardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          child: InkWell(
            key: const Key('row_remote_pairing_toggle'),
            borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.6),
            focusColor: LuminaTokens.focusRing.withValues(alpha: 0.16),
            onTap: () => _toggleExpand('remote'),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceMd,
                vertical: LuminaTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                border: Border.all(
                  color: isRemoteActive ? _accentBlue : _dividerColor,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _accentBlue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                    ),
                    child: const Icon(
                      Icons.router_outlined,
                      size: 16,
                      color: _accentBlue,
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '遠端核心伺服器 / 區網與廣域連線',
                          style: TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '目前模式：${mode.label}',
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: isExpanded ? '收合遠端配對設定' : '展開遠端配對設定',
                    child: TextButton(
                      onPressed: () => _toggleExpand('remote'),
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.textSecondary,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceSm,
                        ),
                      ),
                      child: Text(
                        isExpanded ? '收合' : '設定配對',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
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
                  margin: const EdgeInsets.only(top: LuminaTokens.spaceXs),
                  padding: const EdgeInsets.all(LuminaTokens.spaceMd),
                  decoration: BoxDecoration(
                    color: _cardBg,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                    border: Border.all(color: _dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: LuminaTokens.spaceXs,
                        runSpacing: LuminaTokens.spaceXs,
                        children: [
                          OutlinedButton(
                            key: const Key('btn_switch_local_mode'),
                            onPressed: () async {
                              await widget.audioService.switchToLocalMode();
                              if (!mounted) return;
                              setState(() {
                                _statusIsError = false;
                                _status = '已切換至本機 / USB DAC 播放模式';
                              });
                            },
                            style: LuminaSettingsStyles.outlinedButtonStyle(),
                            child: const Text('本機 / USB DAC'),
                          ),
                          FilledButton.icon(
                            key: const Key('btn_generate_host_pin'),
                            onPressed: () async {
                              final info = await widget.audioService
                                  .initiateHostPairing();
                              if (!mounted) return;
                              setState(() {
                                _statusIsError = info == null;
                                _hostPairInfo = info;
                                _status = info != null
                                    ? '主機配對 PIN 碼已就緒：${info.pin}'
                                    : '無法啟動主機配對服務';
                              });
                            },
                            style: LuminaSettingsStyles.filledButtonStyle(),
                            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                            label: const Text('產生主機配對 PIN / QR'),
                          ),
                          OutlinedButton.icon(
                            key: const Key('btn_discover_lan_servers'),
                            onPressed: () async {
                              final found = await widget.audioService
                                  .discoverLanServers();
                              if (!mounted) return;
                              setState(() {
                                _statusIsError = false;
                                _lanServers = found;
                                if (found.isNotEmpty) {
                                  _remoteUrlCtrl.text = found.first.httpBaseUrl;
                                }
                                _status = '於區網內發現 ${found.length} 台核心伺服器';
                              });
                            },
                            style: LuminaSettingsStyles.outlinedButtonStyle(),
                            icon: const Icon(Icons.wifi_find_rounded, size: 16),
                            label: const Text('掃描區網 mDNS 核心'),
                          ),
                          ..._lanServers.map(
                            (srv) => Tooltip(
                              message:
                                  '帶入伺服器位址 ${srv.httpBaseUrl}',
                              child: ActionChip(
                                backgroundColor: LuminaTokens.cardElevatedBg,
                                side: const BorderSide(
                                  color: LuminaTokens.borderControl,
                                ),
                                labelStyle: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 12,
                                ),
                                label: Text(
                                  '${srv.serverName} (${srv.host}:${srv.port})',
                                ),
                                onPressed: () =>
                                    _remoteUrlCtrl.text = srv.httpBaseUrl,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_hostPairInfo != null) ...[
                        const SizedBox(height: LuminaTokens.spaceXs),
                        SelectableText(
                          '配對 PIN：${_hostPairInfo!.pin}  |  QR 碼：${_hostPairInfo!.qrPayload}',
                          key: const Key('host_pairing_qr_text'),
                          style: const TextStyle(
                            color: LuminaTokens.statusWarning,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      const SizedBox(height: LuminaTokens.spaceSm),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final hostField = TextField(
                            key: const Key('input_remote_host'),
                            controller: _remoteUrlCtrl,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 12,
                            ),
                            decoration: LuminaSettingsStyles.inputDecoration(
                              labelText: '區網伺服器網址（URL）',
                              borderRadius: LuminaTokens.radiusSm,
                            ),
                          );
                          final pinField = TextField(
                            key: const Key('input_remote_pin'),
                            controller: _remotePinCtrl,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 12,
                            ),
                            decoration: LuminaSettingsStyles.inputDecoration(
                              labelText: '6 位數配對 PIN 碼',
                              borderRadius: LuminaTokens.radiusSm,
                            ),
                          );
                          final pairBtn = FilledButton(
                            key: const Key('btn_pair_remote'),
                            onPressed: () async {
                              final tok = await widget.audioService
                                  .pairAndConnectRemote(
                                    baseUrl: _remoteUrlCtrl.text.trim(),
                                    pin: _remotePinCtrl.text.trim(),
                                  );
                              if (!mounted) return;
                              setState(() {
                                _statusIsError = tok == null;
                                _status = tok != null
                                    ? '已成功配對遠端核心伺服器'
                                    : '遠端伺服器配對失敗';
                              });
                            },
                            style: LuminaSettingsStyles.filledButtonStyle(),
                            child: const Text('配對區網連線'),
                          );
                          if (constraints.maxWidth < 460) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                hostField,
                                const SizedBox(height: LuminaTokens.spaceXs),
                                Row(
                                  children: [
                                    Expanded(child: pinField),
                                    const SizedBox(width: LuminaTokens.spaceXs),
                                    pairBtn,
                                  ],
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(flex: 2, child: hostField),
                              const SizedBox(width: LuminaTokens.spaceXs),
                              Expanded(child: pinField),
                              const SizedBox(width: LuminaTokens.spaceXs),
                              pairBtn,
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final wanField = TextField(
                            key: const Key('input_wan_url'),
                            controller: _wanUrlCtrl,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 12,
                            ),
                            decoration: LuminaSettingsStyles.inputDecoration(
                              labelText: '廣域網路直連網址（HTTPS / WSS）',
                              borderRadius: LuminaTokens.radiusSm,
                            ),
                          );
                          final wanBtn = FilledButton(
                            key: const Key('btn_connect_wan'),
                            onPressed: () async {
                              final ok = await widget.audioService
                                  .connectWanDirect(
                                    httpsBaseUrl: _wanUrlCtrl.text.trim(),
                                    pin: _remotePinCtrl.text.trim().length == 6
                                        ? _remotePinCtrl.text.trim()
                                        : null,
                                  );
                              if (!mounted) return;
                              setState(() {
                                _statusIsError = !ok;
                                _status = ok
                                    ? '已透過廣域網 HTTPS / WSS 連線'
                                    : '廣域網連線失敗';
                              });
                            },
                            style: LuminaSettingsStyles.filledButtonStyle(),
                            child: const Text('廣域網路連線'),
                          );
                          if (constraints.maxWidth < 420) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                wanField,
                                const SizedBox(height: LuminaTokens.spaceXs),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: wanBtn,
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: wanField),
                              const SizedBox(width: LuminaTokens.spaceXs),
                              wanBtn,
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
