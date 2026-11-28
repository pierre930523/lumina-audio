import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'glide_inertia_engine.dart';
import 'glide_scroll_helpers.dart';
import 'scroll_velocity_scope.dart';

export 'glide_scroll_helpers.dart' show isLuminaDesktopPlatform;

/// Desktop-tuned [ScrollController] implementing the Glide Inertia Profile
/// (`damping = 9.5`, `wheelMultiplier = 1.15`, `stopThreshold = 0.35`) directly
/// inside [ScrollPosition.pointerScroll] so mouse wheel scrolling exhibits
/// **zero 1-frame snap** while automatically bypassing trackpad gestures.
class GlideScrollController extends ScrollController {
  final double damping;
  final double wheelMultiplier;
  final double stopThreshold;
  @visibleForTesting
  final bool? forceDesktop;

  final ScrollVelocityTracker _velocityTracker = ScrollVelocityTracker();
  final List<_GlideScrollPosition> _glidePositions = <_GlideScrollPosition>[];

  PendingPointerSignalMetadata? _pendingSignal;
  int _pendingSignalGeneration = 0;
  bool _hasSeenNonZeroPointerTimestamp = false;
  bool _isDisposed = false;

  GlideScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
    this.damping = GlideInertiaEngine.defaultDamping,
    this.wheelMultiplier = GlideInertiaEngine.defaultWheelMultiplier,
    this.stopThreshold = GlideInertiaEngine.defaultStopThreshold,
    this.forceDesktop,
  }) : assert(
         damping >= GlideInertiaEngine.minAllowedDamping && damping.isFinite,
         'damping must never be < ${GlideInertiaEngine.minAllowedDamping}',
       );

  bool get isDesktopEnabled =>
      isLuminaDesktopPlatform(forceDesktop: forceDesktop);

  /// Real-time scroll speed in `px/ms` (`ValueListenable<double>`).
  ValueListenable<double> get velocityListenable => _velocityTracker.listenable;

  /// Current real-time scroll speed in `px/ms`.
  double get currentVelocity => _velocityTracker.velocity;

  /// Whether current scroll speed exceeds `1.8 px/ms`.
  bool get isHighSpeed =>
      _velocityTracker.velocity > ScrollVelocityScope.highSpeedThreshold;

  /// Records pointer signal metadata from a wrapping `Listener` right before
  /// [PointerSignalResolver] dispatches `position.pointerScroll(delta)`.
  void recordPointerSignal(
    PointerSignalEvent event, {
    required double devicePixelRatio,
    required bool isShiftPressed,
    double speedMultiplier = 1.0,
  }) {
    if (_isDisposed || !isDesktopEnabled) return;
    if (event is PointerScrollInertiaCancelEvent) {
      handleScrollInertiaCancel();
      return;
    }
    if (event is! PointerScrollEvent) return;

    if (event.timeStamp != Duration.zero) {
      _hasSeenNonZeroPointerTimestamp = true;
    }
    final effectiveTs = resolvePointerEventTimestamp(
      event,
      hasSeenNonZeroTimestamp: _hasSeenNonZeroPointerTimestamp,
    );

    final gen = ++_pendingSignalGeneration;
    _pendingSignal = PendingPointerSignalMetadata(
      event: event,
      devicePixelRatio: devicePixelRatio,
      isShiftPressed: isShiftPressed,
      speedMultiplier: speedMultiplier,
      effectiveTimestamp: effectiveTs,
    );
    scheduleMicrotask(() {
      if (_pendingSignalGeneration == gen) {
        _pendingSignal = null;
      }
    });
  }

  /// Stops active wheel glide and syncs velocity when trackpad pan/zoom starts.
  void handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    if (_isDisposed || !isDesktopEnabled) return;
    for (final pos in _glidePositions) {
      pos.interruptGlideForExternalScroll();
    }
    if (event.timeStamp != Duration.zero) {
      _hasSeenNonZeroPointerTimestamp = true;
    }
  }

  /// Syncs wheel state and updates trackpad pan/zoom velocity in `px/ms`.
  void handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_isDisposed || !isDesktopEnabled) return;
    for (final pos in _glidePositions) {
      pos.interruptGlideForExternalScroll();
    }
    if (event.timeStamp != Duration.zero) {
      _hasSeenNonZeroPointerTimestamp = true;
    }
    final effectiveTs = resolvePointerEventTimestamp(
      event,
      hasSeenNonZeroTimestamp: _hasSeenNonZeroPointerTimestamp,
    );
    final axisDelta =
        _glidePositions.isNotEmpty &&
            _glidePositions.first.axis == Axis.horizontal
        ? event.panDelta.dx
        : event.panDelta.dy;
    _velocityTracker.recordDisplacement(axisDelta, timestamp: effectiveTs);
  }

  /// Handles end of a trackpad pan/zoom sequence.
  void handlePointerPanZoomEnd(PointerPanZoomEndEvent event) {
    if (_isDisposed || !isDesktopEnabled) return;
    final stillFlinging = _glidePositions.any((p) => p.isCurrentlyScrolling);
    if (!stillFlinging) {
      _velocityTracker.reset();
    }
  }

  /// Stops wheel glide when OS trackpad inertia cancellation arrives.
  void handleScrollInertiaCancel() {
    if (_isDisposed) return;
    for (final pos in _glidePositions) {
      pos.interruptGlideForExternalScroll();
    }
    _velocityTracker.reset();
  }

  PendingPointerSignalMetadata? _consumePendingSignal() {
    final pending = _pendingSignal;
    _pendingSignal = null;
    return pending;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    if (!isDesktopEnabled) {
      return super.createScrollPosition(physics, context, oldPosition);
    }
    return _GlideScrollPosition(
      controller: this,
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pendingSignal = null;
    _glidePositions.clear();
    _velocityTracker.dispose();
    super.dispose();
  }
}

class _GlideScrollActivity extends ScrollActivity {
  late final GlideTickerStepper _stepper;
  final double Function() _readVelocityPxPerSec;

  _GlideScrollActivity(
    super.delegate,
    this._readVelocityPxPerSec, {
    required TickerProvider vsync,
    required void Function(double dtSeconds) onStep,
  }) {
    _stepper = GlideTickerStepper(vsync: vsync, onStep: onStep);
  }

  void start() => _stepper.start();
  void stopTicker() => _stepper.stop();

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => _readVelocityPxPerSec();

  @override
  void dispose() {
    _stepper.dispose();
    super.dispose();
  }
}

class _GlideScrollPosition extends ScrollPositionWithSingleContext {
  final GlideScrollController controller;
  final GlideInertiaEngine _engine;
  final TrackpadHeuristicTracker _trackpadTracker = TrackpadHeuristicTracker();

  _GlideScrollActivity? _glideActivity;
  double? _lastObservedPixels;

  _GlideScrollPosition({
    required this.controller,
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  }) : _engine = GlideInertiaEngine(
         damping: controller.damping,
         wheelMultiplier: controller.wheelMultiplier,
         stopThreshold: controller.stopThreshold,
         initialOffset: initialPixels ?? 0.0,
       ) {
    controller._glidePositions.add(this);
    if (hasPixels) {
      _lastObservedPixels = pixels;
      _engine.syncTo(pixels);
    }
  }

  bool get isCurrentlyScrolling => activity?.isScrolling ?? false;

  void interruptGlideForExternalScroll() {
    final glide = _glideActivity;
    if (glide != null) {
      _glideActivity = null;
      glide.stopTicker();
    }
    if (hasPixels) {
      _engine.syncTo(
        pixels,
        minExtent: hasContentDimensions ? minScrollExtent : null,
        maxExtent: hasContentDimensions ? maxScrollExtent : null,
      );
      _lastObservedPixels = pixels;
    }
  }

  @override
  void absorb(ScrollPosition other) {
    super.absorb(other);
    if (other is _GlideScrollPosition) {
      other._glideActivity?.stopTicker();
      other._glideActivity = null;
    }
    if (hasPixels) {
      _lastObservedPixels = pixels;
      _engine.syncTo(pixels);
    }
  }

  @override
  void applyNewDimensions() {
    super.applyNewDimensions();
    if (hasContentDimensions) {
      _engine.updateBounds(
        minExtent: minScrollExtent,
        maxExtent: maxScrollExtent,
      );
    }
  }

  @override
  void beginActivity(ScrollActivity? newActivity) {
    final oldGlide = _glideActivity;
    if (oldGlide != null && !identical(newActivity, oldGlide)) {
      _glideActivity = null;
      oldGlide.stopTicker();
      if (hasPixels) {
        _engine.syncTo(
          pixels,
          minExtent: hasContentDimensions ? minScrollExtent : null,
          maxExtent: hasContentDimensions ? maxScrollExtent : null,
        );
        _lastObservedPixels = pixels;
      }
    }
    super.beginActivity(newActivity);
    if (newActivity != null && !newActivity.isScrolling) {
      controller._velocityTracker.reset();
    }
  }

  @override
  double setPixels(double newPixels) {
    final overscroll = super.setPixels(newPixels);
    _recordExternalVelocityIfNeeded();
    return overscroll;
  }

  @override
  void forcePixels(double value) {
    super.forcePixels(value);
    _recordExternalVelocityIfNeeded();
  }

  @override
  void jumpTo(double value) {
    super.jumpTo(value);
    if (hasPixels) {
      _engine.syncTo(
        pixels,
        minExtent: hasContentDimensions ? minScrollExtent : null,
        maxExtent: hasContentDimensions ? maxScrollExtent : null,
      );
      _lastObservedPixels = pixels;
    }
    controller._velocityTracker.reset();
  }

  @override
  void pointerScroll(double delta) {
    final metadata = controller._consumePendingSignal();
    if (delta == 0.0) {
      interruptGlideForExternalScroll();
      controller._velocityTracker.reset();
      super.pointerScroll(0.0);
      return;
    }

    final event = metadata?.event;
    final dpr = metadata?.devicePixelRatio ?? context.devicePixelRatio;
    final isShift =
        metadata?.isShiftPressed ?? HardwareKeyboard.instance.isShiftPressed;
    final timestamp =
        metadata?.effectiveTimestamp ??
        SchedulerBinding.instance.currentSystemFrameTimeStamp;

    final shouldBypass = _trackpadTracker.shouldBypass(
      isTrackpadKind: event?.kind == PointerDeviceKind.trackpad,
      rawDx: event?.scrollDelta.dx ?? 0.0,
      rawDy: event != null ? event.scrollDelta.dy : delta,
      devicePixelRatio: dpr,
      isShiftPressed: isShift,
      timestamp: timestamp,
    );

    if (shouldBypass) {
      interruptGlideForExternalScroll();
      final beforePixels = pixels;
      super.pointerScroll(delta);
      final moved = pixels - beforePixels;
      _engine.syncTo(
        pixels,
        minExtent: hasContentDimensions ? minScrollExtent : null,
        maxExtent: hasContentDimensions ? maxScrollExtent : null,
      );
      _lastObservedPixels = pixels;
      controller._velocityTracker.recordDisplacement(
        moved,
        timestamp: SchedulerBinding.instance.currentSystemFrameTimeStamp,
      );
      return;
    }

    final speedMultiplier = metadata?.speedMultiplier ?? 1.0;
    final minExt = hasContentDimensions ? minScrollExtent : 0.0;
    final maxExt = hasContentDimensions ? maxScrollExtent : 0.0;
    final hasMotion = _engine.addWheelDelta(
      delta * speedMultiplier,
      deltaMode: WheelDeltaMode.pixel,
      viewportDimension: hasViewportDimension ? viewportDimension : 0.0,
      currentPosition: pixels,
      minExtent: minExt,
      maxExtent: maxExt,
    );

    if (!hasMotion) {
      if ((_engine.current - pixels).abs() > 1e-6) {
        forcePixels(_engine.current);
      }
      _glideActivity?.stopTicker();
      _glideActivity = null;
      goIdle();
      controller._velocityTracker.reset();
      return;
    }

    if (_glideActivity == null || !identical(activity, _glideActivity)) {
      final nextActivity = _GlideScrollActivity(
        this,
        () => _engine.signedVelocityPxPerMs * 1000.0,
        vsync: context.vsync,
        onStep: _onGlideStep,
      );
      _glideActivity = nextActivity;
      beginActivity(nextActivity);
      nextActivity.start();
    }
  }

  void _onGlideStep(double dtSeconds) {
    final activeGlide = _glideActivity;
    if (activeGlide == null || !identical(activity, activeGlide) || !hasPixels) {
      return;
    }
    if (hasContentDimensions) {
      _engine.updateBounds(
        minExtent: minScrollExtent,
        maxExtent: maxScrollExtent,
      );
    }
    final nextPixels = _engine.step(dtSeconds);
    if ((nextPixels - pixels).abs() > 1e-6) {
      setPixels(nextPixels);
      _lastObservedPixels = pixels;
    }
    controller._velocityTracker.setDirectVelocity(_engine.velocityPxPerMs);
    if (!_engine.isActive) {
      _glideActivity = null;
      activeGlide.stopTicker();
      goIdle();
      controller._velocityTracker.reset();
    }
  }

  void _recordExternalVelocityIfNeeded() {
    if (!hasPixels) return;
    final prev = _lastObservedPixels;
    _lastObservedPixels = pixels;
    if (identical(activity, _glideActivity)) return;

    final activityVel = activity?.velocity ?? 0.0;
    if (activityVel.abs() > 1e-3) {
      controller._velocityTracker.recordActivityVelocityPxPerSec(activityVel);
      return;
    }
    if (prev != null && (activity?.isScrolling ?? false)) {
      controller._velocityTracker.recordDisplacement(
        pixels - prev,
        timestamp: SchedulerBinding.instance.currentSystemFrameTimeStamp,
      );
    }
  }

  @override
  void dispose() {
    _glideActivity?.stopTicker();
    _glideActivity = null;
    controller._glidePositions.remove(this);
    super.dispose();
  }
}
