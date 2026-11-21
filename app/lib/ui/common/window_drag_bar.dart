import 'package:material_ui/material_ui.dart';

import '../../services/desktop_window_controller.dart';

/// Reusable full-width 2-layer window title bar and drag area.
///
/// Architecture:
/// - Fixed standard title bar height (default 48.0 px).
/// - Bottom layer (Layer 0): Spans 100% width and full height using
///   `GestureDetector(behavior: HitTestBehavior.opaque, onPanStart: ..., onDoubleTap: ...)`.
///   Note: We deliberately do NOT use `Listener(onPointerDown: ... startDragging())` because
///   firing `startDragging()` on pointer-down enters Windows modal drag and starves Flutter of
///   subsequent pointer events, preventing `onDoubleTap` from triggering.
/// - Top layer (Layer 1): Interactive widgets (buttons, menus, captions).
///   Non-interactive text (e.g. window title) should be wrapped in `IgnorePointer` so dragging
///   the title area seamlessly activates the underlying drag layer.
class WindowDragBar extends StatelessWidget {
  /// Standard desktop title bar height (48.0 px).
  static const double kDefaultHeight = 48.0;

  final double height;
  final Widget? child;
  final Color? backgroundColor;
  final Border? border;
  final EdgeInsetsGeometry padding;
  final DesktopWindowController? controller;

  const WindowDragBar({
    super.key,
    this.height = kDefaultHeight,
    this.child,
    this.backgroundColor,
    this.border,
    this.padding = EdgeInsets.zero,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveController = controller ?? DesktopWindowController.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: effectiveController.isFullScreenNotifier,
      builder: (context, isFullScreen, _) {
        return Container(
          height: height,
          decoration: BoxDecoration(
            color: backgroundColor,
            border: border,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Layer 0: Full-coverage drag & double-tap maximize interceptor
              // Disabled in fullscreen mode.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: isFullScreen
                    ? null
                    : (_) => effectiveController.startDragging(),
                onDoubleTap: isFullScreen
                    ? null
                    : () => effectiveController.toggleMaximize(),
                child: const ColoredBox(color: Colors.transparent),
              ),
              // Layer 1: Interactive controls and widgets
              if (child != null)
                Padding(
                  padding: padding,
                  child: child!,
                ),
            ],
          ),
        );
      },
    );
  }
}
