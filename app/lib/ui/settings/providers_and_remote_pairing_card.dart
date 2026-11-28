part of 'providers_and_remote_panel.dart';

extension _ProvidersAndRemotePairingExt on _ProvidersAndRemotePanelState {
  Widget _buildRemotePairingCard(ConnectionMode mode) {
    final isExpanded = _expandedSection == 'remote';
    final isRemoteActive = mode != ConnectionMode.localOrUsbDac;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: isRemoteActive
              ? _ProvidersAndRemotePanelState._activeRowBg
              : _ProvidersAndRemotePanelState._cardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          child: InkWell(
            key: const Key('row_remote_pairing_toggle'),
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: LuminaTokens.glassRowHoverBg,
            focusColor: LuminaTokens.focusRing.withValues(alpha: 0.16),
            onTap: () => _toggleExpand('remote'),
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
                  color: isRemoteActive
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
                      color: LuminaTokens.glassPillBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                      border: Border.all(color: LuminaTokens.glassPillBorder),
                    ),
                    child: const Icon(
                      Icons.router_outlined,
                      size: 16,
                      color: LuminaTokens.glassTextPrimary,
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
                    color: _ProvidersAndRemotePanelState._cardBg,
                    borderRadius: BorderRadius.circular(
                      LuminaTokens.glassCardRadius,
                    ),
                    border: Border.all(
                      color: _ProvidersAndRemotePanelState._cardBorder,
                    ),
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
                              _updateState(() {
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
                              _updateState(() {
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
                              _updateState(() {
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
                              message: '帶入伺服器位址 ${srv.httpBaseUrl}',
                              child: ActionChip(
                                backgroundColor: LuminaTokens.glassPillBg,
                                side: const BorderSide(
                                  color: LuminaTokens.glassPillBorder,
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
                              _updateState(() {
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
                              _updateState(() {
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
