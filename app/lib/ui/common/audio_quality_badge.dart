import 'package:material_ui/material_ui.dart';

import '../../models/audio_quality_tier.dart';
import '../../models/playback_state.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';

/// Immutable visual styling specification for a single [AudioQualityTier].
///
/// Exposed so both [AudioQualityBadge] and secondary spec capsules (e.g. Now
/// Playing cover-underneath pill) stay visually synchronized with the active
/// quality tier.
class AudioQualityBadgeStyle {
  final String label;
  final Color borderColor;
  final Color textColor;
  final Color backgroundColor;
  final Color? glowColor;
  final double glowBlur;
  final List<BoxShadow> boxShadow;

  const AudioQualityBadgeStyle({
    required this.label,
    required this.borderColor,
    required this.textColor,
    required this.backgroundColor,
    this.glowColor,
    this.glowBlur = 0.0,
    this.boxShadow = const [],
  });

  static const AudioQualityBadgeStyle hiRes = AudioQualityBadgeStyle(
    label: 'Hi-Res',
    borderColor: LuminaTokens.badgeHiResBorder,
    textColor: LuminaTokens.badgeHiResText,
    backgroundColor: LuminaTokens.badgeHiResBg,
    glowColor: LuminaTokens.badgeHiResGlow,
    glowBlur: LuminaTokens.badgeHiResGlowBlur,
    boxShadow: [
      BoxShadow(
        color: LuminaTokens.badgeHiResGlow,
        blurRadius: LuminaTokens.badgeHiResGlowBlur,
      ),
    ],
  );

  static const AudioQualityBadgeStyle lossless = AudioQualityBadgeStyle(
    label: 'LOSSLESS',
    borderColor: LuminaTokens.badgeLosslessBorder,
    textColor: LuminaTokens.badgeLosslessText,
    backgroundColor: LuminaTokens.badgeLosslessBg,
    glowColor: LuminaTokens.badgeLosslessGlow,
    glowBlur: LuminaTokens.badgeLosslessGlowBlur,
    boxShadow: [
      BoxShadow(
        color: LuminaTokens.badgeLosslessGlow,
        blurRadius: LuminaTokens.badgeLosslessGlowBlur,
      ),
    ],
  );

  static const AudioQualityBadgeStyle hqLossy = AudioQualityBadgeStyle(
    label: 'HQ',
    borderColor: LuminaTokens.badgeHqBorder,
    textColor: LuminaTokens.badgeHqText,
    backgroundColor: LuminaTokens.badgeHqBg,
  );

  static const AudioQualityBadgeStyle standard = AudioQualityBadgeStyle(
    label: 'SD',
    borderColor: LuminaTokens.badgeStandardBorder,
    textColor: LuminaTokens.badgeStandardText,
    backgroundColor: LuminaTokens.badgeStandardBg,
  );

  static const AudioQualityBadgeStyle hiResLight = AudioQualityBadgeStyle(
    label: 'Hi-Res',
    borderColor: Color(0xA69A6B00),
    textColor: Color(0xFF8A5E00),
    backgroundColor: Color(0x18B47D00),
    glowColor: Color(0x24B47D00),
    glowBlur: 6.0,
    boxShadow: [
      BoxShadow(color: Color(0x24B47D00), blurRadius: 6.0),
    ],
  );

  static const AudioQualityBadgeStyle losslessLight = AudioQualityBadgeStyle(
    label: 'LOSSLESS',
    borderColor: Color(0x520F172A),
    textColor: Color(0xFF0F172A),
    backgroundColor: Color(0x0E0F172A),
  );

  static const AudioQualityBadgeStyle hqLossyLight = AudioQualityBadgeStyle(
    label: 'HQ',
    borderColor: Color(0x380F172A),
    textColor: Color(0xFF334155),
    backgroundColor: Color(0x0A0F172A),
  );

  static const AudioQualityBadgeStyle standardLight = AudioQualityBadgeStyle(
    label: 'SD',
    borderColor: Color(0x280F172A),
    textColor: Color(0xFF475569),
    backgroundColor: Colors.transparent,
  );

  static AudioQualityBadgeStyle forTier(
    AudioQualityTier tier, {
    bool isDark = true,
  }) => switch (tier) {
    AudioQualityTier.hiRes => isDark ? hiRes : hiResLight,
    AudioQualityTier.lossless => isDark ? lossless : losslessLight,
    AudioQualityTier.hqLossy => isDark ? hqLossy : hqLossyLight,
    AudioQualityTier.standard => isDark ? standard : standardLight,
  };
}

/// Reusable 4-tier Frosted Glass micro slim-border capsule badge.
///
/// Smoothly animates colors, borders, glow, and label when switching tracks.
class AudioQualityBadge extends StatefulWidget {
  final AudioQualityTier? tier;
  final TrackInfo? track;
  final VoidCallback? onTap;
  final bool isActive;
  final Key? buttonKey;
  final String? tooltip;

  const AudioQualityBadge({
    super.key,
    this.tier,
    this.track,
    this.onTap,
    this.isActive = false,
    this.buttonKey = const Key('quality_badge_button'),
    this.tooltip,
  });

  AudioQualityTier get effectiveTier => tier ?? getAudioQualityTier(track);

  @override
  State<AudioQualityBadge> createState() => _AudioQualityBadgeState();
}

class _AudioQualityBadgeState extends State<AudioQualityBadge> {
  bool _hovered = false;
  bool _focused = false;

  Color _resolveBackground(AudioQualityBadgeStyle style, bool interactive) {
    if (!interactive && !widget.isActive) {
      return style.backgroundColor;
    }
    if (widget.isActive) {
      return Color.alphaBlend(
        style.textColor.withValues(alpha: 0.14),
        style.backgroundColor,
      );
    }
    if (_hovered) {
      return Color.alphaBlend(
        style.textColor.withValues(alpha: 0.10),
        style.backgroundColor,
      );
    }
    if (_focused) {
      return Color.alphaBlend(
        style.textColor.withValues(alpha: 0.08),
        style.backgroundColor,
      );
    }
    return style.backgroundColor;
  }

  Color _resolveBorder(AudioQualityBadgeStyle style, LuminaGlassTheme glass) {
    if (_focused) {
      return glass.isDark ? LuminaTokens.focusRing : glass.accent;
    }
    if (widget.isActive) return style.textColor;
    return style.borderColor;
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final resolvedTier = widget.effectiveTier;
    final style = AudioQualityBadgeStyle.forTier(
      resolvedTier,
      isDark: glass.isDark,
    );
    final interactive = widget.onTap != null;
    final radius = BorderRadius.circular(LuminaTokens.qualityBadgeRadius);

    final badge = Semantics(
      button: interactive,
      selected: widget.isActive,
      label: '音質等級：${resolvedTier.displayName}（${style.label}）',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: widget.buttonKey,
          onTap: widget.onTap,
          onHover: (hovered) {
            if (interactive && _hovered != hovered) {
              setState(() => _hovered = hovered);
            }
          },
          onFocusChange: (focused) {
            if (interactive && _focused != focused) {
              setState(() => _focused = focused);
            }
          },
          mouseCursor: interactive
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          borderRadius: radius,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          splashColor: style.textColor.withValues(alpha: 0.16),
          child: AnimatedContainer(
            duration: LuminaTokens.qualityBadgeTransitionDuration,
            curve: Curves.ease,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
            decoration: BoxDecoration(
              color: _resolveBackground(style, interactive),
              borderRadius: radius,
              border: Border.all(
                color: _resolveBorder(style, glass),
                width: 1,
              ),
              boxShadow: style.boxShadow,
            ),
            child: AnimatedSwitcher(
              duration: LuminaTokens.qualityBadgeTransitionDuration,
              switchInCurve: Curves.ease,
              switchOutCurve: Curves.ease,
              child: Text(
                style.label,
                key: ValueKey<AudioQualityTier>(resolvedTier),
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: style.textColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (!interactive && widget.tooltip == null) {
      return badge;
    }

    return Tooltip(
      message: widget.tooltip ?? '檢視音質與輸出詳情（${resolvedTier.displayName}）',
      child: badge,
    );
  }
}
