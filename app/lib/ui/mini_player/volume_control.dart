import 'package:material_ui/material_ui.dart';
import '../theme/lumina_tokens.dart';

class VolumeControl extends StatelessWidget {
  final double volume;
  final bool isMuted;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback onToggleMute;
  final double sliderWidth;
  final bool lockedUnity;

  const VolumeControl({
    super.key,
    required this.volume,
    required this.isMuted,
    required this.onVolumeChanged,
    required this.onToggleMute,
    this.sliderWidth = 84.0,
    this.lockedUnity = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveVolume = lockedUnity
        ? 1.0
        : (isMuted ? 0.0 : volume.clamp(0.0, 1.0));
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('btn_mute'),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          style: IconButton.styleFrom(
            foregroundColor: LuminaTokens.textSecondary,
            disabledForegroundColor: LuminaTokens.accentPurpleText,
            hoverColor: LuminaTokens.cardHoverBg,
            focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            ),
          ).copyWith(
            mouseCursor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
            ),
            side: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? const BorderSide(color: LuminaTokens.focusRing, width: 1.5)
                  : const BorderSide(color: Colors.transparent, width: 1.5),
            ),
          ),
          icon: Icon(
            lockedUnity
                ? Icons.lock_outline_rounded
                : (isMuted || effectiveVolume == 0.0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded),
            size: lockedUnity ? 18 : 20,
          ),
          tooltip: lockedUnity
              ? 'DAC 硬體音量控制'
              : (isMuted ? '取消靜音' : '靜音'),
          onPressed: lockedUnity ? null : onToggleMute,
        ),
        SizedBox(
          width: sliderWidth,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              overlayColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
              thumbColor: lockedUnity
                  ? LuminaTokens.accentPurpleText
                  : LuminaTokens.textPrimary,
              disabledThumbColor: LuminaTokens.accentPurpleText,
            ),
            child: Semantics(
              label: lockedUnity ? '軟體音量已鎖定為 1.0 倍' : '音量控制',
              slider: true,
              value: '${(effectiveVolume * 100).round()}%',
              child: Slider(
                key: const Key('volume_slider'),
                value: effectiveVolume,
                min: 0.0,
                max: 1.0,
                activeColor: lockedUnity
                    ? LuminaTokens.accentPurple
                    : LuminaTokens.textPrimary,
                inactiveColor: lockedUnity
                    ? LuminaTokens.textDisabled.withValues(alpha: 0.45)
                    : LuminaTokens.borderControl,
                mouseCursor: lockedUnity
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                onChanged: lockedUnity ? null : onVolumeChanged,
              ),
            ),
          ),
        ),
      ],
    );

    if (!lockedUnity) {
      return content;
    }

    return Tooltip(
      message: 'Strict Bit-Perfect 已鎖定軟體音量 1.0x（請使用 DAC 硬體音量旋鈕）',
      child: content,
    );
  }
}
