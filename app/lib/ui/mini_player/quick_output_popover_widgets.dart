part of 'quick_output_popover.dart';

class _QuickOutputDeviceRow extends StatelessWidget {
  final AudioDeviceInfo dev;
  final bool isSelected;
  final PlaybackState? devState;
  final String? subtitle;
  final VoidCallback onSelect;
  final VoidCallback onTogglePlayPause;
  final ValueChanged<double> onVolumeChanged;

  const _QuickOutputDeviceRow({
    required this.dev,
    required this.isSelected,
    required this.devState,
    required this.subtitle,
    required this.onSelect,
    required this.onTogglePlayPause,
    required this.onVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isPlaying = devState?.status == PlaybackStatus.playing;
    final devVol = (devState?.volume ?? 0.85).clamp(0.0, 1.0);

    return InkWell(
      key: Key('quick_output_dev_${dev.id}'),
      onTap: onSelect,
      mouseCursor: SystemMouseCursors.click,
      hoverColor: LuminaTokens.glassRowHoverBg,
      focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
      child: Container(
        color: isSelected
            ? LuminaTokens.glassNavActiveBg
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.volume_up_outlined,
                  size: 16,
                  color: isSelected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dev.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : LuminaTokens.glassTextPrimary,
                          fontSize: 13,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          key: Key('quick_output_state_${dev.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('quick_output_play_${dev.id}'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: isSelected
                        ? Colors.white
                        : LuminaTokens.glassTextSecondary,
                    hoverColor: LuminaTokens.glassPillHoverBg,
                    focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
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
                  tooltip: isPlaying ? '暫停' : '播放',
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  onPressed: onTogglePlayPause,
                ),
                if (isSelected)
                  const ExcludeSemantics(
                    child: Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
              ],
            ),
            if (isSelected || devState != null)
              SizedBox(
                height: 22,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbColor: Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    overlayColor: LuminaTokens.glassPillHoverBg,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: LuminaTokens.spaceLg),
                      Expanded(
                        child: Semantics(
                          label: '${dev.name} 音量',
                          slider: true,
                          value: '${(devVol * 100).round()}%',
                          child: Slider(
                            key: Key('quick_output_vol_${dev.id}'),
                            value: devVol,
                            activeColor: LuminaTokens.glassTextPrimary,
                            inactiveColor: LuminaTokens.glassTrackUnplayed,
                            mouseCursor: SystemMouseCursors.click,
                            onChanged: onVolumeChanged,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${(devVol * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DriverSegmentButton extends StatefulWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DriverSegmentButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_DriverSegmentButton> createState() => _DriverSegmentButtonState();
}

class _DriverSegmentButtonState extends State<_DriverSegmentButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.label} 驅動程式',
      child: InkWell(
        onTap: widget.onTap,
        onHover: (v) {
          if (_hovered != v) setState(() => _hovered = v);
        },
        onFocusChange: (v) {
          if (_focused != v) setState(() => _focused = v);
        },
        mouseCursor: SystemMouseCursors.click,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: LuminaTokens.focusDuration,
          curve: LuminaTokens.motionCurve,
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? LuminaTokens.glassSegmentSelectedBg
                : (_hovered
                      ? LuminaTokens.glassRowHoverBg
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused
                  ? LuminaTokens.focusRing
                  : (widget.selected
                        ? LuminaTokens.glassSegmentSelectedBorder
                        : Colors.transparent),
              width: 1,
            ),
          ),
          child: Text(
            widget.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: widget.selected
                  ? Colors.white
                  : LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
