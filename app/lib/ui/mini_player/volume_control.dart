import 'package:material_ui/material_ui.dart';
import '../theme/lumina_tokens.dart';

class VolumeControl extends StatefulWidget {
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
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  bool _sliderHovered = false;

  @override
  Widget build(BuildContext context) {
    final lockedUnity = widget.lockedUnity;
    final effectiveVolume = lockedUnity
        ? 1.0
        : (widget.isMuted ? 0.0 : widget.volume.clamp(0.0, 1.0));
    final activeHover = !lockedUnity && _sliderHovered;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('btn_mute'),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          style: IconButton.styleFrom(
            foregroundColor: LuminaTokens.glassTextSecondary,
            disabledForegroundColor: LuminaTokens.accentPurpleText,
            backgroundColor: Colors.transparent,
            hoverColor: LuminaTokens.glassPillBg,
            focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
            shape: const CircleBorder(),
          ).copyWith(
            mouseCursor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
            ),
            side: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? const BorderSide(color: LuminaTokens.focusRing, width: 1.5)
                  : BorderSide.none,
            ),
          ),
          icon: Icon(
            lockedUnity
                ? Icons.lock_outline_rounded
                : (widget.isMuted || effectiveVolume == 0.0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded),
            size: lockedUnity ? 17 : 19,
          ),
          tooltip: lockedUnity
              ? 'DAC 硬體音量控制'
              : (widget.isMuted ? '取消靜音' : '靜音'),
          onPressed: lockedUnity ? null : widget.onToggleMute,
        ),
        MouseRegion(
          onEnter: (_) {
            if (!_sliderHovered) setState(() => _sliderHovered = true);
          },
          onExit: (_) {
            if (_sliderHovered) setState(() => _sliderHovered = false);
          },
          child: SizedBox(
            width: widget.sliderWidth,
            height: 22,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: activeHover ? 3.0 : 2.5,
                thumbShape: _VolumeGlowingThumbShape(
                  radius: activeHover ? 5.0 : 4.0,
                  color: lockedUnity
                      ? LuminaTokens.accentPurpleText
                      : LuminaTokens.glassTextPrimary,
                  glowAlpha: lockedUnity ? 0.0 : (activeHover ? 0.45 : 0.22),
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                overlayColor: LuminaTokens.glassTextPrimary.withValues(
                  alpha: 0.12,
                ),
                thumbColor: lockedUnity
                    ? LuminaTokens.accentPurpleText
                    : LuminaTokens.glassTextPrimary,
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
                      : LuminaTokens.glassTextPrimary,
                  inactiveColor: lockedUnity
                      ? LuminaTokens.textDisabled.withValues(alpha: 0.45)
                      : LuminaTokens.glassTrackUnplayed,
                  mouseCursor: lockedUnity
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.click,
                  onChanged: lockedUnity ? null : widget.onVolumeChanged,
                ),
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

class _VolumeGlowingThumbShape extends SliderComponentShape {
  final double radius;
  final Color color;
  final double glowAlpha;

  const _VolumeGlowingThumbShape({
    required this.radius,
    required this.color,
    required this.glowAlpha,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    if (glowAlpha > 0) {
      final glowPaint = Paint()
        ..color = Colors.white.withValues(alpha: glowAlpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
      canvas.drawCircle(center, radius + 1.5, glowPaint);
    }

    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, dotPaint);
  }
}
