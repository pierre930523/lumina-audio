import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/escape_dismiss_registry.dart';
import '../theme/lumina_tokens.dart';
import 'bottom_player_bar_scope.dart';
import 'frosted_glass_container.dart';

part 'lumina_context_menu_layout.dart';

/// Signature for an optional custom header rendered at the top of a
/// [showLuminaContextMenu] popup. [closeMenu] dismisses the menu cleanly and
/// resolves its future with an optional result.
typedef LuminaContextMenuHeaderBuilder<T> = Widget Function(
  BuildContext context,
  void Function([T? result]) closeMenu,
);

/// Base entry type for [showLuminaContextMenu].
sealed class LuminaContextMenuEntry<T> {
  const LuminaContextMenuEntry();
}

/// Interactive row entry inside a Lumina Liquid Glass context menu.
class LuminaContextMenuAction<T> extends LuminaContextMenuEntry<T> {
  final Key? key;
  final T value;
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final Color? textColor;
  final bool selected;
  final bool enabled;
  final bool destructive;
  final Widget? trailing;

  const LuminaContextMenuAction({
    this.key,
    required this.value,
    required this.label,
    this.icon,
    this.iconColor,
    this.textColor,
    this.selected = false,
    this.enabled = true,
    this.destructive = false,
    this.trailing,
  });
}

/// Horizontal hairline divider between grouped menu sections.
class LuminaContextMenuDivider<T> extends LuminaContextMenuEntry<T> {
  final double height;

  const LuminaContextMenuDivider({this.height = 8.0});
}

/// Muted section heading label inside grouped menus.
class LuminaContextMenuSectionLabel<T> extends LuminaContextMenuEntry<T> {
  final String label;

  const LuminaContextMenuSectionLabel(this.label);
}

/// Shows a scale-invariant, viewport-clamped Liquid Glass context menu in the
/// root [Overlay].
///
/// Handles the coordinate space conversion caused by [UiScaleScope]'s
/// `Transform.scale` around [MaterialApp]:
/// - When [globalPosition] is supplied (e.g. from `onSecondaryTapUp`), it is
///   converted into the root overlay's local coordinate space via
///   `overlayBox.globalToLocal(globalPosition)`.
/// - When anchoring to a button widget via [anchorContext] (or [context]), the
///   target bounds are resolved with `ancestor: overlayBox`.
///
/// Near viewport edges or the docked bottom player bar (from
/// [BottomPlayerBarScope]), the menu automatically flips left / up instead of
/// clipping or overlapping the player bar.
Future<T?> showLuminaContextMenu<T>({
  required BuildContext context,
  Offset? globalPosition,
  BuildContext? anchorContext,
  required List<LuminaContextMenuEntry<T>> entries,
  LuminaContextMenuHeaderBuilder<T>? headerBuilder,
  double? width,
  double minWidth = 200.0,
  double maxWidth = 300.0,
  double edgeMargin = 12.0,
  double anchorGap = 4.0,
  bool preferAnchorRightAlign = true,
  bool avoidBottomPlayerBar = true,
  double? bottomInsetOverride,
  Key? menuKey,
}) {
  if (!context.mounted) return Future<T?>.value(null);
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final overlayRender = overlay?.context.findRenderObject();
  if (overlay == null ||
      overlayRender is! RenderBox ||
      !overlayRender.attached ||
      !overlayRender.hasSize) {
    return Future<T?>.value(null);
  }

  final isPointAnchor = globalPosition != null;
  final Rect? initialAnchorRect;
  final BuildContext? resolvedAnchorCtx =
      isPointAnchor ? null : (anchorContext ?? context);

  if (globalPosition != null) {
    final localPoint = overlayRender.globalToLocal(globalPosition);
    initialAnchorRect = Rect.fromLTWH(localPoint.dx, localPoint.dy, 0.0, 0.0);
  } else {
    initialAnchorRect = _resolveAnchorRect(resolvedAnchorCtx!, overlayRender);
    if (initialAnchorRect == null) {
      return Future<T?>.value(null);
    }
  }

  final bottomClearanceListenable = avoidBottomPlayerBar
      ? BottomPlayerBarScope.listenableOf(context)
      : null;

  final completer = Completer<T?>();
  late final OverlayEntry entry;
  var closed = false;

  void close([T? result]) {
    if (closed) return;
    closed = true;
    entry.remove();
    entry.dispose();
    if (!completer.isCompleted) {
      completer.complete(result);
    }
  }

  entry = OverlayEntry(
    builder: (_) => _LuminaContextMenuOverlay<T>(
      overlayState: overlay,
      anchorContext: resolvedAnchorCtx,
      initialAnchorRect: initialAnchorRect!,
      isPointAnchor: isPointAnchor,
      entries: entries,
      headerBuilder: headerBuilder,
      width: width,
      minWidth: minWidth,
      maxWidth: maxWidth,
      edgeMargin: edgeMargin,
      anchorGap: anchorGap,
      preferAnchorRightAlign: preferAnchorRightAlign,
      avoidBottomPlayerBar: avoidBottomPlayerBar,
      bottomClearanceListenable: bottomClearanceListenable,
      bottomInsetOverride: bottomInsetOverride,
      menuKey: menuKey,
      onClose: close,
    ),
  );

  overlay.insert(entry);
  return completer.future;
}

Rect? _resolveAnchorRect(BuildContext targetContext, RenderBox overlayBox) {
  if (!targetContext.mounted) return null;
  final render = targetContext.findRenderObject();
  if (render is! RenderBox || !render.attached || !render.hasSize) {
    return null;
  }
  final topLeft = render.localToGlobal(Offset.zero, ancestor: overlayBox);
  final bottomRight = render.localToGlobal(
    render.size.bottomRight(Offset.zero),
    ancestor: overlayBox,
  );
  return Rect.fromPoints(topLeft, bottomRight);
}
