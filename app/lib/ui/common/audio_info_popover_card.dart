part of 'audio_info_popover.dart';

/// Compact frosted-glass technical readout overlay triggered from
/// [AudioQualityBadge].
class AudioInfoPopover extends StatefulWidget {
  final AudioService audioService;
  final TrackInfo? track;
  final AudioQualityTier? tierOverride;
  final int? overrideBitrateKbps;
  final UiScaleController? scaleController;
  final VoidCallback? onClose;
  final VoidCallback? onOpenSignalPath;
  final double? maxWidth;
  final double? maxHeight;

  const AudioInfoPopover({
    super.key,
    required this.audioService,
    this.track,
    this.tierOverride,
    this.overrideBitrateKbps,
    this.scaleController,
    this.onClose,
    this.onOpenSignalPath,
    this.maxWidth,
    this.maxHeight,
  });

  @override
  State<AudioInfoPopover> createState() => _AudioInfoPopoverState();
}

class _AudioInfoPopoverState extends State<AudioInfoPopover> {
  String _outputDeviceLabel = '';
  bool _loadingDevice = false;
  StreamSubscription<SignalPath>? _signalPathSub;

  @override
  void initState() {
    super.initState();
    _outputDeviceLabel = _resolveFallbackOutputDevice();
    _loadOutputDevice();
    _signalPathSub = widget.audioService.signalPathStream.listen((_) {
      _loadOutputDevice();
    });
  }

  @override
  void didUpdateWidget(covariant AudioInfoPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioService != widget.audioService ||
        oldWidget.scaleController != widget.scaleController) {
      _signalPathSub?.cancel();
      _outputDeviceLabel = _resolveFallbackOutputDevice();
      _loadOutputDevice();
      _signalPathSub = widget.audioService.signalPathStream.listen((_) {
        _loadOutputDevice();
      });
    }
  }

  @override
  void dispose() {
    _signalPathSub?.cancel();
    super.dispose();
  }

  String _resolveFallbackOutputDevice() {
    if (widget.audioService.isSystemOutputActive) {
      return '系統預設輸出';
    }
    final nodes = widget.audioService.currentSignalPath.nodes;
    if (nodes.isNotEmpty) {
      final last = nodes.last;
      if (last.subtitle.trim().isNotEmpty) {
        return last.subtitle.trim();
      }
    }
    return widget.audioService.connectionMode.label;
  }

  Future<void> _loadOutputDevice() async {
    if (_loadingDevice || !mounted) return;
    _loadingDevice = true;
    try {
      if (widget.audioService.isSystemOutputActive) {
        if (!mounted) return;
        setState(() => _outputDeviceLabel = '系統預設輸出');
        return;
      }

      List<AudioDeviceInfo> devices = const [];
      try {
        devices = await widget.audioService.listAudioDevices();
      } catch (_) {}

      final activeId =
          widget.audioService.activeDeviceId ??
          widget.scaleController?.lastOutputDeviceId;
      final activeDev =
          devices.where((d) => d.id == activeId).firstOrNull ??
          devices.where((d) => d.isDefault).firstOrNull ??
          devices.firstOrNull;

      String? resolved;
      if (activeDev != null && activeDev.name.trim().isNotEmpty) {
        resolved = formatAudioOutputDeviceLabel(
          backend: activeDev.backend,
          deviceName: activeDev.name,
        );
      }

      if (resolved == null) {
        try {
          final info = await widget.audioService.getOutputInfo();
          final out = info.output;
          if (out.selectedDevice.trim().isNotEmpty) {
            resolved = formatAudioOutputDeviceLabel(
              backend: out.audioApi.isNotEmpty ? out.audioApi : out.outputMode,
              deviceName: out.selectedDevice,
            );
          }
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _outputDeviceLabel = resolved ?? _resolveFallbackOutputDevice();
      });
    } finally {
      _loadingDevice = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final primaryText =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final secondaryText =
        isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;
    final dividerColor =
        isDark ? LuminaTokens.glassCardDivider : glass.glassBorder;
    final popoverBg =
        isDark ? LuminaTokens.audioInfoPopoverBg : glass.menuBg;
    final popoverBorder =
        isDark ? LuminaTokens.audioInfoPopoverBorder : glass.glassBorderStrong;
    final popoverShadow = isDark
        ? const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ]
        : glass.glassShadow;

    final resolvedWidth = widget.maxWidth != null
        ? math.min(284.0, widget.maxWidth!)
        : 284.0;
    final resolvedMaxHeight = widget.maxHeight;

    return StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.audioService.currentState;
        final track = widget.track ?? state.track;
        final tier = widget.tierOverride ?? getAudioQualityTier(track);
        final style = AudioQualityBadgeStyle.forTier(tier, isDark: isDark);

        final codecText = track != null
            ? formatAudioCodecName(track.format)
            : '—';
        final sampleSpecText = track != null
            ? formatAudioSampleSpec(track.format)
            : '—';
        final bitrateText = track != null
            ? formatAudioBitrateLabel(
                track,
                overrideBitrateKbps: widget.overrideBitrateKbps,
              )
            : '—';
        final tierValueColor = tier == AudioQualityTier.hiRes
            ? style.textColor
            : primaryText;

        final body = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: style.textColor,
                    boxShadow: style.glowColor != null
                        ? [
                            BoxShadow(
                              color: style.glowColor!,
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '音訊品質詳情',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: secondaryText,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AudioQualityBadge(
                  tier: tier,
                  buttonKey: const Key('audio_info_popover_tier_badge'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(color: dividerColor, height: 1),
            const SizedBox(height: 9),
            _SpecRow(
              label: '等級',
              value: tier.displayName,
              valueColor: tierValueColor,
            ),
            const SizedBox(height: 6),
            _SpecRow(label: '格式', value: codecText),
            const SizedBox(height: 6),
            _SpecRow(label: '取樣規格', value: sampleSpecText),
            const SizedBox(height: 6),
            _SpecRow(label: '即時串流率', value: bitrateText),
            const SizedBox(height: 6),
            _SpecRow(
              label: '當前輸出裝置',
              value: _outputDeviceLabel,
              maxLines: 2,
            ),
            if (widget.onOpenSignalPath != null) ...[
              const SizedBox(height: 10),
              Divider(color: dividerColor, height: 1),
              const SizedBox(height: 6),
              _SignalPathActionButton(
                onTap: () {
                  widget.onClose?.call();
                  widget.onOpenSignalPath!();
                },
              ),
            ],
          ],
        );

        return Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: resolvedWidth,
              maxHeight: resolvedMaxHeight ?? double.infinity,
            ),
            child: FrostedGlassContainer(
              key: const Key('audio_info_popover'),
              width: resolvedWidth,
              blurSigma: LuminaTokens.audioInfoPopoverBlur,
              color: popoverBg,
              borderRadius: BorderRadius.circular(
                LuminaTokens.audioInfoPopoverRadius,
              ),
              border: Border.all(
                color: popoverBorder,
                width: 1,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              boxShadow: popoverShadow,
              child: resolvedMaxHeight != null
                  ? SingleChildScrollView(child: body)
                  : body,
            ),
          ),
        );
      },
    );
  }
}

class _SpecRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final int maxLines;

  const _SpecRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final labelColor =
        isDark ? LuminaTokens.glassTextTertiary : glass.textTertiary;
    final defaultValueColor =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: labelColor,
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? defaultValueColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.3,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _SignalPathActionButton extends StatefulWidget {
  final VoidCallback onTap;

  const _SignalPathActionButton({required this.onTap});

  @override
  State<_SignalPathActionButton> createState() =>
      _SignalPathActionButtonState();
}

class _SignalPathActionButtonState extends State<_SignalPathActionButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final hoverBg = isDark ? LuminaTokens.glassRowHoverBg : glass.pillBg;
    final focusColor = isDark ? LuminaTokens.focusRing : glass.accent;
    final primaryText =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final secondaryText =
        isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;
    final tertiaryText =
        isDark ? LuminaTokens.glassTextTertiary : glass.textTertiary;

    return Semantics(
      button: true,
      label: '檢視完整訊號路徑',
      child: InkWell(
        key: const Key('btn_open_signal_path_from_popover'),
        onTap: widget.onTap,
        onHover: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onFocusChange: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: AnimatedContainer(
          duration: LuminaTokens.focusDuration,
          curve: LuminaTokens.motionCurve,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered ? hoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? focusColor : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '檢視完整訊號路徑',
                style: TextStyle(
                  color: _hovered ? primaryText : secondaryText,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 15,
                color: _hovered ? primaryText : tertiaryText,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
