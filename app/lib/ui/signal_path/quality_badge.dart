import 'package:material_ui/material_ui.dart';
import '../../models/signal_path.dart';
import '../theme/lumina_tokens.dart';

class QualityBadge extends StatefulWidget {
  final SignalQuality quality;
  final VoidCallback? onTap;

  const QualityBadge({
    super.key,
    required this.quality,
    this.onTap,
  });

  static Color colorForQuality(SignalQuality quality) => switch (quality) {
    SignalQuality.lossless => const Color(0xFFA855F7), // Purple
    SignalQuality.enhanced => const Color(0xFF10B981), // Green
    SignalQuality.highQuality => const Color(0xFFF59E0B), // Yellow/Amber
  };

  /// WCAG AA-compliant text color (>= 4.5:1 on dark surfaces) for each tier.
  static Color textColorForQuality(SignalQuality quality) => switch (quality) {
    SignalQuality.lossless => LuminaTokens.accentPurpleText,
    SignalQuality.enhanced => LuminaTokens.statusSuccess,
    SignalQuality.highQuality => LuminaTokens.statusWarning,
  };

  @override
  State<QualityBadge> createState() => _QualityBadgeState();
}

class _QualityBadgeState extends State<QualityBadge> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final interactive = widget.onTap != null;

    final badge = Semantics(
      button: interactive,
      label: '訊號路徑品質：${widget.quality.label}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('quality_badge_button'),
          onTap: widget.onTap,
          onHover: (v) {
            if (interactive && _hovered != v) {
              setState(() => _hovered = v);
            }
          },
          onFocusChange: (v) {
            if (interactive && _focused != v) {
              setState(() => _focused = v);
            }
          },
          mouseCursor: interactive
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          borderRadius: BorderRadius.circular(4),
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashColor: LuminaTokens.hiResGoldText.withValues(alpha: 0.22),
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _hovered
                  ? LuminaTokens.hiResGoldBorder.withValues(alpha: 0.20)
                  : (_focused
                        ? LuminaTokens.hiResGoldBorder.withValues(alpha: 0.16)
                        : LuminaTokens.hiResGoldBg),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _focused
                    ? LuminaTokens.focusRing
                    : LuminaTokens.hiResGoldBorder,
                width: 1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: LuminaTokens.hiResGoldGlow,
                  blurRadius: 10,
                ),
              ],
            ),
            child: const Text(
              'Hi-Res',
              style: TextStyle(
                color: LuminaTokens.hiResGoldText,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                height: 1.2,
              ),
            ),
          ),
        ),
      ),
    );

    if (!interactive) {
      return badge;
    }

    return Tooltip(
      message: '檢視音訊訊號路徑（${widget.quality.label}）',
      child: badge,
    );
  }
}
