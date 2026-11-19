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
    final accent = QualityBadge.colorForQuality(widget.quality);
    final labelColor = QualityBadge.textColorForQuality(widget.quality);
    final interactive = widget.onTap != null;

    final badge = Semantics(
      button: interactive,
      label: '訊號路徑品質：${widget.quality.label}',
      child: Padding(
        padding: const EdgeInsets.all(1),
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
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            splashColor: accent.withValues(alpha: 0.22),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: accent.withValues(
                  alpha: _hovered ? 0.28 : (_focused ? 0.24 : 0.18),
                ),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : accent.withValues(alpha: _hovered ? 0.88 : 0.68),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    key: const Key('quality_badge_dot'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.quality.label,
                    style: TextStyle(
                      color: labelColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      height: 1.25,
                    ),
                  ),
                ],
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
