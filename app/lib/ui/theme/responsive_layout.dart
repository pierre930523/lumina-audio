import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Viewport width classification for Lumina Audio desktop/responsive layouts.
enum LuminaSizeClass { compact, medium, expanded, wide }

/// Clamped overlay positioning geometry returned by [LuminaResponsive.computeClampedPopover].
class PopoverClampResult {
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;
  final double width;
  final double maxHeight;

  const PopoverClampResult({
    required this.targetAnchor,
    required this.followerAnchor,
    required this.offset,
    required this.width,
    required this.maxHeight,
  });
}

/// Shared responsive breakpoints, spacing helpers, and viewport-clamped popover
/// geometry calculations for Lumina Audio.
abstract final class LuminaResponsive {
  static const double compactMaxWidth = 640.0;
  static const double desktopSidebarMinWidth = 840.0;
  static const double mediumMaxWidth = 960.0;
  static const double expandedMaxWidth = 1440.0;

  static LuminaSizeClass sizeClassForWidth(double width) {
    if (width < compactMaxWidth) return LuminaSizeClass.compact;
    if (width < mediumMaxWidth) return LuminaSizeClass.medium;
    if (width < expandedMaxWidth) return LuminaSizeClass.expanded;
    return LuminaSizeClass.wide;
  }

  static bool showDesktopSidebar(double width) =>
      width >= desktopSidebarMinWidth;

  static double sidebarWidth(double width) {
    if (width >= expandedMaxWidth) return 228.0;
    if (width >= 1000.0) return 216.0;
    return 196.0;
  }

  static double contentHorizontalPadding(double width) {
    if (width >= expandedMaxWidth) return 28.0;
    if (width >= mediumMaxWidth) return 22.0;
    if (width >= compactMaxWidth) return 16.0;
    return 12.0;
  }

  static double settingsRailWidth(double width) =>
      width >= 1100.0 ? 224.0 : 210.0;

  static double settingsContentHorizontalPadding(double width) {
    if (width >= 1100.0) return 40.0;
    if (width >= 760.0) return 24.0;
    return 14.0;
  }

  /// Computes a [CompositedTransformFollower]-compatible anchor/offset/size
  /// tuple that keeps an anchored popover completely within [overlaySize]
  /// margins across monitor DPI switches, window resizes, and narrow viewports.
  static PopoverClampResult computeClampedPopover({
    required Size overlaySize,
    required Offset? targetTopLeft,
    required Size? targetSize,
    required double preferredWidth,
    required double preferredMaxHeight,
    bool preferAbove = false,
    double anchorGap = 8.0,
    double edgeMargin = 12.0,
    double topInset = 0.0,
    double bottomInset = 0.0,
  }) {
    final maxAllowedWidth = math.max(
      180.0,
      overlaySize.width - edgeMargin * 2,
    );
    final width = math.min(preferredWidth, maxAllowedWidth);
    final usableTop = math.min(topInset + edgeMargin, overlaySize.height);
    final usableBottom = math.max(
      usableTop,
      overlaySize.height - bottomInset - edgeMargin,
    );
    final usableHeight = math.max(0.0, usableBottom - usableTop);
    final fallbackMaxHeight = math.min(
      preferredMaxHeight,
      usableHeight > 0.0 ? usableHeight : math.max(120.0, overlaySize.height - edgeMargin * 2),
    );

    if (targetTopLeft == null || targetSize == null) {
      return PopoverClampResult(
        targetAnchor: preferAbove ? Alignment.topRight : Alignment.bottomRight,
        followerAnchor:
            preferAbove ? Alignment.bottomRight : Alignment.topRight,
        offset: Offset(0, preferAbove ? -anchorGap : anchorGap),
        width: width,
        maxHeight: fallbackMaxHeight,
      );
    }

    final targetRight = targetTopLeft.dx + targetSize.width;
    final rawLeft = targetRight - width;
    final maxLeft = math.max(
      edgeMargin,
      overlaySize.width - width - edgeMargin,
    );
    final clampedLeft = rawLeft.clamp(edgeMargin, maxLeft).toDouble();
    final dx = clampedLeft - rawLeft;

    final targetTop = targetTopLeft.dy;
    final targetBottom = targetTop + targetSize.height;
    final spaceBelow = usableBottom - (targetBottom + anchorGap);
    final spaceAbove = (targetTop - anchorGap) - usableTop;

    final placeBelow = preferAbove
        ? (spaceAbove < 200.0 && spaceBelow > spaceAbove)
        : (spaceBelow >= 200.0 || spaceBelow >= spaceAbove);

    final minHeight = math.min(120.0, usableHeight);

    if (placeBelow) {
      final rawTop = targetBottom + anchorGap;
      final maxTop = math.max(usableTop, usableBottom - minHeight);
      final clampedTop = rawTop.clamp(usableTop, maxTop).toDouble();
      final dy = anchorGap + (clampedTop - rawTop);
      final availableHeight = math.max(0.0, usableBottom - clampedTop);
      final maxHeight = math.min(preferredMaxHeight, availableHeight);
      return PopoverClampResult(
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: Offset(dx, dy),
        width: width,
        maxHeight: maxHeight,
      );
    }

    final rawBottom = targetTop - anchorGap;
    final maxBottom = usableBottom;
    final minBottom = math.min(maxBottom, usableTop + minHeight);
    final clampedBottom = rawBottom.clamp(minBottom, maxBottom).toDouble();
    final dy = -anchorGap + (clampedBottom - rawBottom);
    final availableHeight = math.max(0.0, clampedBottom - usableTop);
    final maxHeight = math.min(preferredMaxHeight, availableHeight);
    return PopoverClampResult(
      targetAnchor: Alignment.topRight,
      followerAnchor: Alignment.bottomRight,
      offset: Offset(dx, dy),
      width: width,
      maxHeight: maxHeight,
    );
  }
}
