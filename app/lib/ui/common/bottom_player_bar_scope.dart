import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Exposes the docked bottom player bar clearance (in scaled logical pixels
/// matching [HomeScreen]'s coordinate space) so popovers and context menus can
/// clamp cleanly above the player bar without overlapping it.
class BottomPlayerBarScope extends InheritedWidget {
  final ValueListenable<double> clearanceListenable;

  const BottomPlayerBarScope({
    super.key,
    required this.clearanceListenable,
    required super.child,
  });

  /// Returns the live clearance listenable if [context] is inside [HomeScreen],
  /// or `null` in isolated widget tests without a docked player bar.
  static ValueListenable<double>? listenableOf(BuildContext context) {
    final element =
        context.getElementForInheritedWidgetOfExactType<BottomPlayerBarScope>();
    final widget = element?.widget;
    return widget is BottomPlayerBarScope ? widget.clearanceListenable : null;
  }

  /// Non-listening O(1) lookup suitable inside button/menu handlers.
  /// Returns `0.0` outside [HomeScreen].
  static double clearanceOf(BuildContext context) =>
      listenableOf(context)?.value ?? 0.0;

  @override
  bool updateShouldNotify(covariant BottomPlayerBarScope oldWidget) =>
      !identical(oldWidget.clearanceListenable, clearanceListenable);
}
