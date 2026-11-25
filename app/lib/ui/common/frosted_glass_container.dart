import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme/lumina_tokens.dart';

/// Translucent dark frosted-glass container that conditionally applies a
/// clipped [BackdropFilter] only when [enableBackdropBlur] is true and
/// [blurSigma] > 0.
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
  });

  @override
  Widget build(BuildContext context) {
    final Widget paddedChild =
        padding != null ? Padding(padding: padding!, child: child) : child;

    final bool useBlur = enableBackdropBlur && blurSigma > 0.0;
    final bool hasShadow = boxShadow != null && boxShadow!.isNotEmpty;

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        border: border,
        borderRadius: borderRadius,
        boxShadow: useBlur ? null : boxShadow,
      ),
      child: paddedChild,
    );

    if (useBlur) {
      final blurred = BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
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
    final bool enabled = widget.onTap != null;
    final Color effectiveBg;
    final Color effectiveBorder;
    final Color effectiveIconColor;

    if (!enabled) {
      effectiveBg = LuminaTokens.glassPillBg.withValues(alpha: 0.04);
      effectiveBorder = LuminaTokens.glassSidebarBorder;
      effectiveIconColor = LuminaTokens.textDisabled;
    } else if (widget.selected) {
      effectiveBg = _hovered
          ? LuminaTokens.glassPillHoverBg
          : LuminaTokens.glassNavActiveBg;
      effectiveBorder =
          _focused ? LuminaTokens.focusRing : LuminaTokens.glassCoverRim;
      effectiveIconColor = widget.iconColor ?? LuminaTokens.glassTextPrimary;
    } else {
      effectiveBg = _hovered
          ? LuminaTokens.glassPillHoverBg
          : LuminaTokens.glassPillBg;
      effectiveBorder =
          _focused ? LuminaTokens.focusRing : LuminaTokens.glassPillBorder;
      effectiveIconColor = widget.iconColor ??
          (_hovered
              ? LuminaTokens.glassTextPrimary
              : LuminaTokens.glassTextSecondary);
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
