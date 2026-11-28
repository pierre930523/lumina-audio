import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/audio_output_info.dart';
import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../services/audio_service.dart';
import '../common/audio_quality_badge.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'quality_badge.dart';
import 'signal_node_tile.dart';
import 'signal_path_telemetry_section.dart';

class SignalPathModal extends StatefulWidget {
  final AudioService audioService;

  const SignalPathModal({
    super.key,
    required this.audioService,
  });

  static Future<void> show(BuildContext context, AudioService audioService) {
    return showDialog<void>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
          child: FrostedGlassContainer(
            blurSigma: LuminaTokens.glassDialogBlur,
            color: LuminaTokens.glassDialogBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
            border: Border.all(color: LuminaTokens.glassCardBorder),
            child: SignalPathModal(audioService: audioService),
          ),
        ),
      ),
    );
  }

  @override
  State<SignalPathModal> createState() => _SignalPathModalState();
}

class _SignalPathModalState extends State<SignalPathModal> {
  final GlideScrollController _scrollController = GlideScrollController();
  AudioEngineOutputInfoModel _outputInfo = const AudioEngineOutputInfoModel();
  bool _showDetails = true;
  bool _loadingInfo = false;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<SignalPath>? _spSub;
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    _refreshOutputInfo();
    _spSub = widget.audioService.signalPathStream.listen((_) {
      _refreshOutputInfo();
    });
    _posSub = widget.audioService.positionStream.listen((_) {
      final now = DateTime.now();
      if (now.difference(_lastRefresh).inMilliseconds >= 750) {
        _refreshOutputInfo();
      }
    });
  }

  @override
  void dispose() {
    _spSub?.cancel();
    _posSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshOutputInfo() async {
    if (_loadingInfo || !mounted) return;
    _loadingInfo = true;
    _lastRefresh = DateTime.now();
    try {
      final info = await widget.audioService.getOutputInfo();
      if (!mounted) return;
      setState(() {
        _outputInfo = info;
      });
    } finally {
      _loadingInfo = false;
    }
  }

  static Color _statusColor(String status) {
    switch (status) {
      case 'BIT-PERFECT':
      case 'PCM UNMODIFIED':
      case 'DSD NATIVE':
      case 'DSD DoP':
        return LuminaTokens.accentPurpleText;
      case 'NOT BIT-PERFECT':
      case 'DSD TO PCM':
        return LuminaTokens.statusWarning;
      case 'EXCLUSIVE MODE UNAVAILABLE':
        return LuminaTokens.statusError;
      default:
        return LuminaTokens.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SignalPath>(
      stream: widget.audioService.signalPathStream,
      initialData: widget.audioService.currentSignalPath,
      builder: (context, snapshot) {
        final signalPath = snapshot.data ?? widget.audioService.currentSignalPath;
        final descriptionColor =
            QualityBadge.textColorForQuality(signalPath.overallQuality);
        final strictOn = widget.audioService.isStrictBitPerfect;
        final dsdMode = widget.audioService.dsdOutputMode;
        final ver = _outputInfo.verification;
        final out = _outputInfo.output;
        final statusColor = _statusColor(ver.status);

        return SmoothScrollWrapper(
          controller: _scrollController,
          child: SingleChildScrollView(
            key: const PageStorageKey<String>('signal_path_modal_scroll'),
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceLg,
            LuminaTokens.spaceMd + 4,
            LuminaTokens.spaceLg,
            LuminaTokens.spaceLg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StreamBuilder<PlaybackState>(
                    stream: widget.audioService.stateStream,
                    initialData: widget.audioService.currentState,
                    builder: (context, stateSnap) {
                      final currentTrack =
                          (stateSnap.data ?? widget.audioService.currentState)
                              .track;
                      return AudioQualityBadge(
                        track: currentTrack,
                        buttonKey: const Key('signal_path_modal_quality_badge'),
                      );
                    },
                  ),
                  const SizedBox(width: LuminaTokens.spaceSm),
                  const Expanded(
                    child: Text(
                      '音訊訊號路徑',
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    key: const Key('verification_status_badge'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: statusColor.withValues(alpha: 0.65),
                      ),
                    ),
                    child: Text(
                      ver.status,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: LuminaTokens.space2xs),
                  IconButton(
                    tooltip: '關閉音訊訊號路徑',
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    style: IconButton.styleFrom(
                      foregroundColor: LuminaTokens.textSecondary,
                      hoverColor: LuminaTokens.glassRowHoverBg,
                      focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                      ),
                    ).copyWith(
                      mouseCursor: const WidgetStatePropertyAll(
                        SystemMouseCursors.click,
                      ),
                      side: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.focused)
                            ? const BorderSide(
                                color: LuminaTokens.focusRing,
                                width: 1.5,
                              )
                            : const BorderSide(
                                color: Colors.transparent,
                                width: 1.5,
                              ),
                      ),
                    ),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: LuminaTokens.spaceXs),
              Text(
                signalPath.description,
                key: const Key('signal_path_description'),
                style: TextStyle(
                  color: descriptionColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (out.degradationReason != null &&
                  out.degradationReason!.isNotEmpty) ...[
                const SizedBox(height: LuminaTokens.spaceXs),
                Container(
                  key: const Key('degradation_banner'),
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: LuminaTokens.spaceSm,
                    vertical: LuminaTokens.spaceXs,
                  ),
                  decoration: BoxDecoration(
                    color: LuminaTokens.statusWarning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: LuminaTokens.statusWarning.withValues(alpha: 0.6),
                    ),
                  ),
                  child: Text(
                    '降級通知：${out.degradationReason}',
                    style: const TextStyle(
                      color: LuminaTokens.statusWarning,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: LuminaTokens.spaceMd),
              for (var i = 0; i < signalPath.nodes.length; i++)
                SignalNodeTile(
                  node: signalPath.nodes[i],
                  isLast: i == signalPath.nodes.length - 1,
                ),
              const SizedBox(height: LuminaTokens.spaceXs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceMd,
                  vertical: LuminaTokens.spaceSm,
                ),
                decoration: BoxDecoration(
                  color: LuminaTokens.glassCardBg,
                  borderRadius: BorderRadius.circular(
                    LuminaTokens.glassCardRadius,
                  ),
                  border: Border.all(color: LuminaTokens.glassCardBorder),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '一鍵旁通 DSP（直出模式）',
                                style: TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                strictOn
                                    ? 'Strict Mode 已鎖定硬旁通'
                                    : (signalPath.dspBypassed
                                          ? '所有音效處理已停用（Zero Gain Lossless）'
                                          : '停用以獲得完全未修飾的位元串流'),
                                style: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          key: const Key('dsp_bypass_switch'),
                          value: signalPath.dspBypassed,
                          mouseCursor: strictOn
                              ? SystemMouseCursors.basic
                              : SystemMouseCursors.click,
                          onChanged: strictOn
                              ? null
                              : (_) async {
                                  await widget.audioService.toggleDspBypass();
                                  await _refreshOutputInfo();
                                },
                        ),
                      ],
                    ),
                    const Divider(
                      color: LuminaTokens.glassCardDivider,
                      height: 16,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Strict Bit-Perfect Mode（嚴格位元直出）',
                                style: TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                strictOn
                                    ? '已停用軟體音量（固定 1.0x）、EQ 與所有 DSP，請使用 DAC 硬體音量'
                                    : '啟用 WASAPI Exclusive / ASIO 原生整數直出並停用所有 DSP',
                                style: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          key: const Key('strict_bit_perfect_switch'),
                          value: strictOn,
                          mouseCursor: SystemMouseCursors.click,
                          onChanged: (value) async {
                            await widget.audioService.setStrictBitPerfect(value);
                            if (mounted) setState(() {});
                            await _refreshOutputInfo();
                          },
                        ),
                      ],
                    ),
                    const Divider(
                      color: LuminaTokens.glassCardDivider,
                      height: 16,
                    ),
                    Row(
                      children: [
                        const Text(
                          'DSD 輸出模式',
                          style: TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        Expanded(
                          child: Wrap(
                            spacing: LuminaTokens.space2xs + 2,
                            runSpacing: LuminaTokens.space2xs,
                            alignment: WrapAlignment.end,
                            children: DsdOutputModeOption.values.map((opt) {
                              final selected = dsdMode == opt;
                              final keyName = switch (opt) {
                                DsdOutputModeOption.auto => 'dsd_mode_auto',
                                DsdOutputModeOption.nativeDsd => 'dsd_mode_native',
                                DsdOutputModeOption.dop => 'dsd_mode_dop',
                                DsdOutputModeOption.dsdToPcm => 'dsd_mode_pcm',
                              };
                              return ChoiceChip(
                                key: Key(keyName),
                                label: Text(
                                  opt.shortLabel,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: selected
                                        ? Colors.white
                                        : LuminaTokens.glassTextSecondary,
                                  ),
                                ),
                                selected: selected,
                                showCheckmark: false,
                                selectedColor:
                                    LuminaTokens.glassSegmentSelectedBg,
                                backgroundColor:
                                    LuminaTokens.glassSegmentTrackBg,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusSm,
                                  ),
                                ),
                                side: BorderSide(
                                  color: selected
                                      ? LuminaTokens.glassSegmentSelectedBorder
                                      : LuminaTokens.glassSegmentTrackBorder,
                                ),
                                visualDensity: VisualDensity.compact,
                                onSelected: (_) async {
                                  await widget.audioService.setDsdOutputMode(opt);
                                  if (mounted) setState(() {});
                                  await _refreshOutputInfo();
                                },
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              SignalPathTelemetrySection(
                outputInfo: _outputInfo,
                statusColor: statusColor,
                showDetails: _showDetails,
                onToggleDetails: () =>
                    setState(() => _showDetails = !_showDetails),
              ),
            ],
          ),
          ),
        );
      },
    );
  }
}
