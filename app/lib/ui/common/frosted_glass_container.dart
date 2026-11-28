import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';

/// Translucent frosted-glass container that conditionally applies a clipped
/// [BackdropFilter] only when [enableBackdropBlur] is true and blur sigma > 0.
///
/// By default uses explicit [color], [blurSigma], and [border] (preserving all
/// dark-mode token assertions). Pass [useThemeSurface] or use
/// [FrostedGlassContainer.themed] to source surface/border/blur from
/// [LuminaGlassTheme.of].
class FrostedGlassContainer extends StatelessWidget {
  final Widget child;
  final double blurSigma;
  final Color color;
  final BoxBorder? border;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final List<BoxShadow>? boxShadow;
  final double? width;
  final double? height;
  final bool enableBackdropBlur;
  final bool useThemeSurface;
  final bool elevated;
  final bool _hasCustomColor;
  final bool _hasCustomBlur;

  const FrostedGlassContainer({
    super.key,
    required this.child,
    this.blurSigma = 16.0,
    this.color = const Color(0x12FFFFFF),
    this.border,
    this.borderRadius,
    this.padding,
    this.boxShadow,
    this.width,
    this.height,
    this.enableBackdropBlur = true,
    this.useThemeSurface = false,
    this.elevated = false,
  }) : _hasCustomColor = !useThemeSurface,
       _hasCustomBlur = !useThemeSurface;

  const FrostedGlassContainer.themed({
    super.key,
    required this.child,
    double? blurSigma,
    Color? color,
    this.border,
    this.borderRadius,
    this.padding,
    this.boxShadow,
    this.width,
    this.height,
    this.enableBackdropBlur = true,
    this.elevated = false,
  }) : blurSigma = blurSigma ?? 20.0,
       color = color ?? const Color(0x12FFFFFF),
       useThemeSurface = true,
       _hasCustomColor = color != null,
       _hasCustomBlur = blurSigma != null;

  @override
  Widget build(BuildContext context) {
    final LuminaGlassTheme? glass =
        useThemeSurface ? LuminaGlassTheme.of(context) : null;
    final Color effectiveColor = _hasCustomColor
        ? color
        : (elevated ? glass!.glassBgElevated : glass!.glassBg);
    final double effectiveBlur = _hasCustomBlur
        ? blurSigma
        : (elevated ? glass!.glassBlur : glass!.glassCardBlur);
    final BoxBorder? effectiveBorder = useThemeSurface
        ? (border ?? Border.all(color: glass!.glassBorder, width: 1.0))
        : border;

    final Widget paddedChild =
        padding != null ? Padding(padding: padding!, child: child) : child;

    final bool useBlur = enableBackdropBlur && effectiveBlur > 0.0;
    final bool hasShadow = boxShadow != null && boxShadow!.isNotEmpty;

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: effectiveColor,
        border: effectiveBorder,
        borderRadius: borderRadius,
        boxShadow: useBlur ? null : boxShadow,
      ),
      child: paddedChild,
    );

    if (useBlur) {
      final blurred = BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: effectiveBlur,
          sigmaY: effectiveBlur,
        ),
        child: content,
      );
      content = borderRadius != null
          ? ClipRRect(borderRadius: borderRadius!, child: blurred)
          : ClipRect(child: blurred);

      if (hasShadow) {
        content = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: boxShadow,
          ),
          child: content,
        );
      }
    }

    if (width != null || height != null) {
      content = SizedBox(width: width, height: height, child: content);
    }
    return content;
  }
}

/// Compact rounded-square frosted-glass icon button with hover highlight,
/// keyboard focus ring, [Tooltip], and accessible button [Semantics].
class FrostedGlassIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final double borderRadius;
  final bool selected;
  final bool enableBackdropBlur;
  final double blurSigma;
  final Color? iconColor;

  const FrostedGlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.size = 36.0,
    this.iconSize = 18.0,
    this.borderRadius = 10.0,
    this.selected = false,
    this.enableBackdropBlur = true,
    this.blurSigma = 16.0,
    this.iconColor,
  });

  @override
  State<FrostedGlassIconButton> createState() => _FrostedGlassIconButtonState();
}

class _FrostedGlassIconButtonState extends State<FrostedGlassIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final focusColor = isDark ? LuminaTokens.focusRing : glass.accent;
    final bool enabled = widget.onTap != null;
    final Color effectiveBg;
    final Color effectiveBorder;
    final Color effectiveIconColor;

    if (!enabled) {
      effectiveBg = isDark
          ? LuminaTokens.glassPillBg.withValues(alpha: 0.04)
          : glass.pillBg.withValues(alpha: 0.45);
      effectiveBorder = glass.sidebarBorder;
      effectiveIconColor = glass.textDisabled;
    } else if (widget.selected) {
      effectiveBg = _hovered
          ? glass.pillHoverBg
          : (isDark ? LuminaTokens.glassNavActiveBg : glass.glassBgActive);
      effectiveBorder = _focused ? focusColor : glass.glassBorderStrong;
      effectiveIconColor = widget.iconColor ?? glass.textPrimary;
    } else {
      effectiveBg = _hovered ? glass.pillHoverBg : glass.pillBg;
      effectiveBorder = _focused ? focusColor : glass.pillBorder;
      effectiveIconColor = widget.iconColor ??
          (_hovered ? glass.textPrimary : glass.textSecondary);
    }

    final radius = BorderRadius.circular(widget.borderRadius);

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        excludeFromSemantics: true,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor:
              enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (hovered) {
            if (_hovered != hovered) {
              setState(() => _hovered = hovered);
            }
          },
          onShowFocusHighlight: (focused) {
            if (_focused != focused) {
              setState(() => _focused = focused);
            }
          },
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: FrostedGlassContainer(
              width: widget.size,
              height: widget.size,
              blurSigma: widget.blurSigma,
              enableBackdropBlur: widget.enableBackdropBlur,
              borderRadius: radius,
              color: effectiveBg,
              border: Border.all(
                color: effectiveBorder,
                width: _focused ? 1.5 : 1.0,
              ),
              child: Center(
                child: Icon(
                  widget.icon,
                  size: widget.iconSize,
                  color: effectiveIconColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
