import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'glide_inertia_engine.dart';
import 'glide_scroll_controller.dart';
import 'glide_scroll_helpers.dart';
import 'plain_scroll_glide_adapter.dart';
import 'scroll_velocity_scope.dart';

export 'glide_inertia_engine.dart';
export 'glide_scroll_controller.dart';
export 'scroll_velocity_scope.dart';

/// Tracks which [ScrollController] already has an ancestor [SmoothScrollWrapper]
/// or [LuminaDesktopScrollScope] so `LuminaDesktopScrollBehavior.buildScrollbar`
/// never double-wraps it.
class _SmoothScrollOwnerScope extends InheritedWidget {
  final ScrollController controller;

  const _SmoothScrollOwnerScope({
    required this.controller,
    required super.child,
  });

  static bool isControllerOwned(
    BuildContext context,
    ScrollController controller,
  ) {
    var owned = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is _SmoothScrollOwnerScope &&
          identical(widget.controller, controller)) {
        owned = true;
        return false;
      }
      return true;
    });
    return owned;
  }

  @override
  bool updateShouldNotify(covariant _SmoothScrollOwnerScope oldWidget) {
    return !identical(oldWidget.controller, controller);
  }
}

abstract class _SmoothScrollHostState<T extends StatefulWidget> extends State<T>
    with SingleTickerProviderStateMixin {
  PlainScrollControllerGlideAdapter? _plainAdapter;

  void syncScrollHost({
    required ScrollController controller,
    required bool isDesktop,
    required AxisDirection axisDirection,
    required double damping,
    required double speedMultiplier,
  }) {
    if (!isDesktop || controller is GlideScrollController) {
      _plainAdapter?.dispose();
      _plainAdapter = null;
      return;
    }
    if (_plainAdapter == null ||
        !identical(_plainAdapter!.controller, controller)) {
      _plainAdapter?.dispose();
      _plainAdapter = PlainScrollControllerGlideAdapter(
        controller: controller,
        vsync: this,
        initialAxisDirection: axisDirection,
        damping: damping,
        speedMultiplier: speedMultiplier,
      );
    } else {
      _plainAdapter!.updateAxisDirection(axisDirection);
    }
  }

  Widget buildHostedChild(
    BuildContext context, {
    required ScrollController controller,
    required bool isDesktop,
    required double speedMultiplier,
    required Widget child,
  }) {
    if (!isDesktop) {
      return child;
    }

    final glideController = controller is GlideScrollController
        ? controller
        : null;
    final velocityListenable =
        glideController?.velocityListenable ??
        _plainAdapter!.velocityTracker.listenable;

    return _SmoothScrollOwnerScope(
      controller: controller,
      child: ScrollVelocityScope(
        velocityListenable: velocityListenable,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerSignal: (event) {
            final dpr = resolvePhysicalDevicePixelRatio(context);
            final isShift = HardwareKeyboard.instance.isShiftPressed;
            if (glideController != null) {
              glideController.recordPointerSignal(
                event,
                devicePixelRatio: dpr,
                isShiftPressed: isShift,
                speedMultiplier: speedMultiplier,
              );
            } else {
              _plainAdapter?.handlePointerSignal(
                event,
                devicePixelRatio: dpr,
                isShiftPressed: isShift,
              );
            }
          },
          onPointerPanZoomStart: (event) {
            if (glideController != null) {
              glideController.handlePointerPanZoomStart(event);
            } else {
              _plainAdapter?.handlePointerPanZoomStart(event);
            }
          },
          onPointerPanZoomUpdate: (event) {
            if (glideController != null) {
              glideController.handlePointerPanZoomUpdate(event);
            } else {
              _plainAdapter?.handlePointerPanZoomUpdate(event);
            }
          },
          onPointerPanZoomEnd: (event) {
            if (glideController != null) {
              glideController.handlePointerPanZoomEnd(event);
            } else {
              _plainAdapter?.handlePointerPanZoomEnd(event);
            }
          },
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _plainAdapter?.dispose();
    _plainAdapter = null;
    super.dispose();
  }
}

/// Wraps any [ScrollView] to provide desktop Glide Inertia smooth scrolling,
/// trackpad auto-bypass, and [ScrollVelocityScope] real-time speed broadcast.
class SmoothScrollWrapper extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  final double scrollSpeed;
  final Duration animationDuration;
  final Curve curve;
  final double? damping;
  @visibleForTesting
  final bool? forceDesktop;

  const SmoothScrollWrapper({
    super.key,
    required this.controller,
    required this.child,
    this.scrollSpeed = 1.0,
    this.animationDuration = const Duration(milliseconds: 200),
    this.curve = Curves.easeOutCubic,
    this.damping,
    this.forceDesktop,
  });

  /// Returns `true` if an ancestor [SmoothScrollWrapper] or
  /// [LuminaDesktopScrollScope] already manages [controller].
  static bool isControllerManagedByAncestor(
    BuildContext context,
    ScrollController controller,
  ) {
    return _SmoothScrollOwnerScope.isControllerOwned(context, controller);
  }

  @override
  State<SmoothScrollWrapper> createState() => _SmoothScrollWrapperState();
}

class _SmoothScrollWrapperState
    extends _SmoothScrollHostState<SmoothScrollWrapper> {
  bool get _isDesktop =>
      isLuminaDesktopPlatform(forceDesktop: widget.forceDesktop);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SmoothScrollWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    syncScrollHost(
      controller: widget.controller,
      isDesktop: _isDesktop,
      axisDirection: AxisDirection.down,
      damping: widget.damping ?? GlideInertiaEngine.defaultDamping,
      speedMultiplier: widget.scrollSpeed,
    );
  }

  @override
  Widget build(BuildContext context) {
    return buildHostedChild(
      context,
      controller: widget.controller,
      isDesktop: _isDesktop,
      speedMultiplier: widget.scrollSpeed,
      child: widget.child,
    );
  }
}

/// Hosts global Glide Inertia wheel smoothing, trackpad bypass, and
/// [ScrollVelocityScope] for scrollables configured by `LuminaDesktopScrollBehavior`.
class LuminaDesktopScrollScope extends StatefulWidget {
  final ScrollController controller;
  final AxisDirection axisDirection;
  final Widget child;
  @visibleForTesting
  final bool? forceDesktop;

  const LuminaDesktopScrollScope({
    super.key,
    required this.controller,
    required this.axisDirection,
    required this.child,
    this.forceDesktop,
  });

  @override
  State<LuminaDesktopScrollScope> createState() =>
      _LuminaDesktopScrollScopeState();
}

class _LuminaDesktopScrollScopeState
    extends _SmoothScrollHostState<LuminaDesktopScrollScope> {
  bool get _isDesktop =>
      isLuminaDesktopPlatform(forceDesktop: widget.forceDesktop);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant LuminaDesktopScrollScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    syncScrollHost(
      controller: widget.controller,
      isDesktop: _isDesktop,
      axisDirection: widget.axisDirection,
      damping: GlideInertiaEngine.defaultDamping,
      speedMultiplier: 1.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    return buildHostedChild(
      context,
      controller: widget.controller,
      isDesktop: _isDesktop,
      speedMultiplier: 1.0,
      child: widget.child,
    );
  }
}
