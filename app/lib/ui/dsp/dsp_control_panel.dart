import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../settings/settings_widgets.dart';
import '../theme/lumina_tokens.dart';

class DspControlPanel extends StatefulWidget {
  final AudioService audioService;

  const DspControlPanel({super.key, required this.audioService});

  @override
  State<DspControlPanel> createState() => _DspControlPanelState();
}

class _DspControlPanelState extends State<DspControlPanel> {
  final TextEditingController _autoeqController = TextEditingController();
  late DspPipelineConfigModel _config;
  late List<PeqBandModel> _tenBands;
  bool _loaded = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _tenBands = DspPipelineConfigModel.defaultTenBandIso();
    _config = DspPipelineConfigModel(peqBands: _tenBands);
    _load();
  }

  @override
  void dispose() {
    _autoeqController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cfg = await widget.audioService.getDspConfig();
    final padded = List<PeqBandModel>.from(
      cfg.peqBands.isNotEmpty
          ? cfg.peqBands
          : DspPipelineConfigModel.defaultTenBandIso(),
    );
    const defaults = [
      31.0,
      62.0,
      125.0,
      250.0,
      500.0,
      1000.0,
      2000.0,
      4000.0,
      8000.0,
      16000.0,
    ];
    while (padded.length < 10) {
      padded.add(
        PeqBandModel(frequencyHz: defaults[padded.length], gainDb: 0.0),
      );
    }
    if (!mounted) return;
    setState(() {
      _tenBands = padded.take(10).toList();
      _config = cfg.copyWith(peqBands: _tenBands);
      _loaded = true;
    });
  }

  Future<void> _applyDsp() async {
    final next = _config.copyWith(peqBands: _tenBands);
    await widget.audioService.setDspConfig(next);
    if (!mounted) return;
    setState(() {
      _config = next;
      _statusIsError = false;
      _statusMessage =
          next.bypass ? 'DSP 已旁通（位元精準直出）' : '已套用 64 位元浮點 DSP 設定';
    });
  }

  Future<void> _importAutoEq() async {
    final text = _autoeqController.text.trim();
    if (text.isEmpty) return;
    final bands = await widget.audioService.importAutoEqProfile(text);
    if (!mounted) return;
    setState(() {
      if (bands.isNotEmpty) {
        final padded = List<PeqBandModel>.from(bands);
        const defaults = [
          31.0,
          62.0,
          125.0,
          250.0,
          500.0,
          1000.0,
          2000.0,
          4000.0,
          8000.0,
          16000.0,
        ];
        while (padded.length < 10) {
          padded.add(
            PeqBandModel(frequencyHz: defaults[padded.length], gainDb: 0.0),
          );
        }
        _tenBands = padded.take(10).toList();
        _config = _config.copyWith(peqBands: _tenBands, bypass: false);
        _statusIsError = false;
        _statusMessage = '已匯入 ${bands.length} 組 AutoEQ PEQ 濾波頻段';
      } else {
        _statusIsError = true;
        _statusMessage = '未偵測到有效的 AutoEQ 濾波器設定行';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final strictBypassed = widget.audioService.isStrictBitPerfect;
    final primaryTextColor = strictBypassed
        ? LuminaTokens.textDisabled
        : LuminaTokens.textPrimary;
    final secondaryTextColor = strictBypassed
        ? LuminaTokens.textDisabled
        : LuminaTokens.textSecondary;
    final mutedTextColor = strictBypassed
        ? LuminaTokens.textDisabled
        : LuminaTokens.textMuted;

    return KeyedSubtree(
      key: const Key('dsp_control_panel'),
      child: SingleChildScrollView(
        key: const PageStorageKey<String>('dsp_control_panel_scroll'),
        padding: const EdgeInsets.fromLTRB(
          LuminaTokens.spaceLg,
          LuminaTokens.spaceMd,
          LuminaTokens.spaceLg,
          LuminaTokens.bottomScrollClearance,
        ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: LuminaTokens.spaceSm,
            runSpacing: LuminaTokens.spaceXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '64 位元浮點 DSP 音訊處理引擎',
                style: TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Tooltip(
                message: strictBypassed
                    ? '嚴格位元完美模式作用中，無法停用旁通'
                    : '切換 DSP 處理啟用或旁通直出',
                child: FilterChip(
                  key: const Key('switch_dsp_bypass'),
                  label: Text(
                    _config.bypass || strictBypassed
                        ? 'DSP 已旁通'
                        : 'DSP 處理啟用中',
                    style: TextStyle(
                      color: strictBypassed
                          ? LuminaTokens.textDisabled
                          : LuminaTokens.textPrimary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  selected: !_config.bypass && !strictBypassed,
                  surfaceTintColor: Colors.transparent,
                  selectedColor: LuminaTokens.glassSegmentSelectedBg,
                  backgroundColor: LuminaTokens.glassPillBg,
                  checkmarkColor: Colors.white,
                  side: BorderSide(
                    color: strictBypassed
                        ? LuminaTokens.glassCardDivider
                        : (!_config.bypass
                              ? LuminaTokens.glassSegmentSelectedBorder
                              : LuminaTokens.glassPillBorder),
                  ),
                  onSelected: strictBypassed
                      ? null
                      : (active) async {
                          setState(
                            () => _config = _config.copyWith(bypass: !active),
                          );
                          await _applyDsp();
                        },
                ),
              ),
              Tooltip(
                message: strictBypassed
                    ? '嚴格位元完美模式作用中，DSP 調整已停用'
                    : '立即將目前 DSP 參數寫入音訊引擎',
                child: FilledButton.icon(
                  key: const Key('btn_apply_dsp'),
                  onPressed: strictBypassed ? null : _applyDsp,
                  style: LuminaSettingsStyles.filledButtonStyle(),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('套用 DSP 設定'),
                ),
              ),
              if (_statusMessage != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _statusMessage!,
                    style: TextStyle(
                      color: _statusIsError
                          ? LuminaTokens.statusError
                          : LuminaTokens.statusSuccess,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
          if (strictBypassed) ...[
            const SizedBox(height: LuminaTokens.spaceSm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceSm,
                vertical: LuminaTokens.spaceXs,
              ),
              decoration: BoxDecoration(
                color: LuminaTokens.hiResGoldBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: LuminaTokens.hiResGoldBorder.withValues(alpha: 0.6),
                ),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 16,
                    color: LuminaTokens.hiResGoldText,
                  ),
                  SizedBox(width: LuminaTokens.spaceXs),
                  Expanded(
                    child: Text(
                      'Strict Bit-Perfect Mode 作用中：EQ / Crossfeed / ReplayGain / Limiter 已強制旁通；關閉嚴格模式可恢復即時 DSP。',
                      style: TextStyle(
                        color: LuminaTokens.hiResGoldText,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: LuminaTokens.spaceMd),
          Container(
            padding: const EdgeInsets.all(LuminaTokens.spaceMd),
            decoration: BoxDecoration(
              color: LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '10 段參數等化器（PEQ）',
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: strictBypassed
                        ? LuminaTokens.glassCardDivider
                        : LuminaTokens.glassTextPrimary,
                    inactiveTrackColor: strictBypassed
                        ? LuminaTokens.glassCardDivider
                        : LuminaTokens.glassTrackUnplayed,
                    thumbColor: strictBypassed
                        ? LuminaTokens.textDisabled
                        : Colors.white,
                    overlayColor: LuminaTokens.focusRing.withValues(alpha: 0.2),
                  ),
                  child: Column(
                    children: List.generate(10, (i) {
                      final band = _tenBands[i];
                      final freqLabel = band.frequencyHz >= 1000
                          ? '${(band.frequencyHz / 1000).toStringAsFixed(1)}k'
                          : '${band.frequencyHz.round()}Hz';
                      return Row(
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(
                              freqLabel,
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              key: Key('peq_band_$i'),
                              min: -12.0,
                              max: 12.0,
                              value: band.gainDb.clamp(-12.0, 12.0),
                              onChanged: strictBypassed
                                  ? null
                                  : (v) {
                                      setState(() {
                                        _tenBands[i] = band.copyWith(gainDb: v);
                                      });
                                    },
                            ),
                          ),
                          SizedBox(
                            width: 60,
                            child: Text(
                              '${band.gainDb >= 0 ? '+' : ''}${band.gainDb.toStringAsFixed(1)} dB',
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                color: primaryTextColor,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceMd),
          Container(
            padding: const EdgeInsets.all(LuminaTokens.spaceMd),
            decoration: BoxDecoration(
              color: LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const Key('switch_crossfeed'),
                    contentPadding: EdgeInsets.zero,
                    hoverColor: LuminaTokens.glassRowHoverBg,
                    title: Text(
                      'Bauer 聲學交叉饋送（耳機音場自然化）',
                      style: TextStyle(
                        color: primaryTextColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '分頻點 ${_config.crossfeedCutoffHz.round()} Hz • 饋送準位 ${_config.crossfeedFeedLevelDb.toStringAsFixed(1)} dB',
                      style: TextStyle(
                        color: mutedTextColor,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                    value: _config.crossfeedEnabled,
                    onChanged: strictBypassed
                        ? null
                        : (val) => setState(
                            () => _config = _config.copyWith(
                              crossfeedEnabled: val,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                Wrap(
                  spacing: LuminaTokens.spaceSm,
                  runSpacing: LuminaTokens.spaceXs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '播放音量標準化（ReplayGain）：',
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    MouseRegion(
                      cursor: strictBypassed
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceSm,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.glassPillBg,
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusSm,
                          ),
                          border: Border.all(
                            color: strictBypassed
                                ? LuminaTokens.glassCardDivider
                                : LuminaTokens.glassPillBorder,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<ReplayGainModeOption>(
                            key: const Key('dropdown_replaygain_mode'),
                            value: _config.replayGainMode,
                            dropdownColor: LuminaTokens.glassMenuBg,
                            focusColor: LuminaTokens.focusRing.withValues(
                              alpha: 0.18,
                            ),
                            iconEnabledColor: LuminaTokens.textSecondary,
                            iconDisabledColor: LuminaTokens.textDisabled,
                            style: TextStyle(
                              color: primaryTextColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            items: ReplayGainModeOption.values
                                .map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(m.label),
                                  ),
                                )
                                .toList(),
                            onChanged: strictBypassed
                                ? null
                                : (val) {
                                    if (val != null) {
                                      setState(
                                        () => _config = _config.copyWith(
                                          replayGainMode: val,
                                        ),
                                      );
                                    }
                                  },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: LuminaTokens.spaceMd),
          Container(
            padding: const EdgeInsets.all(LuminaTokens.spaceMd),
            decoration: BoxDecoration(
              color: LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '匯入 AutoEQ 耳機校正曲線檔（.txt）',
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                TextField(
                  key: const Key('autoeq_import_input'),
                  controller: _autoeqController,
                  enabled: !strictBypassed,
                  maxLines: 3,
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: 12,
                  ),
                  decoration: LuminaSettingsStyles.inputDecoration(
                    hintText:
                        '貼上 AutoEQ 格式文字，例如：\nPreamp: -4.5 dB\nFilter 1: ON PK Fc 105 Hz Gain 3.2 dB Q 0.71',
                    borderRadius: LuminaTokens.radiusSm,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                Tooltip(
                  message: strictBypassed
                      ? '嚴格位元完美模式作用中，AutoEQ 匯入已停用'
                      : '解析並套用貼上的 AutoEQ 濾波器參數',
                  child: FilledButton.icon(
                    key: const Key('btn_import_autoeq'),
                    onPressed: strictBypassed ? null : _importAutoEq,
                    style: LuminaSettingsStyles.filledButtonStyle(),
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: const Text('匯入 AutoEQ'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
