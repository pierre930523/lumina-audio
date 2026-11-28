import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/streaming/secure_credential_store.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/streaming/yt_dlp_service.dart';
import '../theme/lumina_tokens.dart';
import 'settings_widgets.dart';
import 'streaming_login_dialog.dart';
import 'third_party_licenses_dialog.dart';

part 'providers_and_remote_yt_dlp_card.dart';
part 'providers_and_remote_streaming_row.dart';
part 'providers_and_remote_network_card.dart';
part 'providers_and_remote_pairing_card.dart';

class ProvidersAndRemotePanel extends StatefulWidget {
  final AudioService audioService;
  final StreamingManager? streamingManager;
  final YtDlpService? ytDlpService;
  final VoidCallback? onProvidersChanged;

  const ProvidersAndRemotePanel({
    super.key,
    required this.audioService,
    this.streamingManager,
    this.ytDlpService,
    this.onProvidersChanged,
  });

  @override
  State<ProvidersAndRemotePanel> createState() =>
      _ProvidersAndRemotePanelState();
}

class _ProvidersAndRemotePanelState extends State<ProvidersAndRemotePanel> {
  static const _activeRowBg = LuminaTokens.glassCardActiveBg;
  static const _cardBg = LuminaTokens.glassCardBg;
  static const _cardBorder = LuminaTokens.glassCardBorder;
  static const _activeIndicator = LuminaTokens.glassSwitchOnTrack;

  final _webdavUriCtrl = TextEditingController();
  final _smbUriCtrl = TextEditingController();
  final _remoteUrlCtrl = TextEditingController(text: 'http://127.0.0.1:9888');
  final _remotePinCtrl = TextEditingController();
  final _wanUrlCtrl = TextEditingController(text: 'https://lumina.example.com');

  late final StreamingManager _streamingManager;
  late final bool _ownsStreamingManager;
  late final YtDlpService _ytDlpService;

  PairingInitiateInfo? _hostPairInfo;
  List<DiscoveredServerInfo> _lanServers = const [];
  List<ProviderStatusInfo> _providers = const [];
  final Set<String> _syncingKinds = <String>{};
  String? _status;
  bool _statusIsError = false;

  String? _expandedSection;
  String? _selectedActiveProvider;

  void _updateState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    _ownsStreamingManager = widget.streamingManager == null;
    _streamingManager =
        widget.streamingManager ??
        StreamingManager(
          credentialStore: Platform.environment.containsKey('FLUTTER_TEST')
              ? MemorySecureCredentialStore()
              : null,
        );
    _ytDlpService = widget.ytDlpService ?? YtDlpService.instance;
    final skipAutoProbeInTest =
        widget.ytDlpService == null &&
        Platform.environment.containsKey('FLUTTER_TEST');
    if (!_ytDlpService.isInitialized && !skipAutoProbeInTest) {
      unawaited(_ytDlpService.initialize());
    }
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
      final isStreaming = StreamingProviderMeta.isStreamingKind(
        _selectedActiveProvider!,
      );
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

  Future<void> _checkAndUpdateYtDlp() async {
    final result = await _ytDlpService.checkAndUpdateYtDlp();
    if (!mounted) return;
    setState(() {
      _statusIsError = result.isFailed;
      _status = result.message;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(result.message),
            duration: const Duration(seconds: 3),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.audioService.connectionMode;

    return SettingsScrollBody(
      panelKey: const Key('providers_and_remote_panel'),
      maxWidth: 740,
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
                          ? LuminaTokens.statusError.withValues(alpha: 0.14)
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

            const SizedBox(height: LuminaTokens.spaceMd),
            _buildYtDlpEngineCard(),

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
    );
  }
}
