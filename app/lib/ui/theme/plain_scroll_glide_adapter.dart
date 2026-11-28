import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'glide_inertia_engine.dart';
import 'glide_scroll_helpers.dart';
import 'scroll_velocity_scope.dart';

/// Adapts a plain [ScrollController] (when not using `GlideScrollController`) to
/// the Glide Inertia Profile with synchronous 1-frame snap prevention via
/// [ScrollPosition.correctPixels].
class PlainScrollControllerGlideAdapter {
  final ScrollController controller;
  final double speedMultiplier;
  final GlideInertiaEngine _engine;
  final TrackpadHeuristicTracker _trackpadTracker = TrackpadHeuristicTracker();
  final ScrollVelocityTracker velocityTracker = ScrollVelocityTracker();
  late final GlideTickerStepper _stepper;

  AxisDirection _axisDirection;
  bool _hasSeenNonZeroTimestamp = false;
  bool _isApplyingGlideJump = false;
  bool _isDisposed = false;

  ScrollPosition? _armedPosition;
  double _armedOldPixels = 0.0;
  double _armedDelta = 0.0;
  int _armedGeneration = 0;

  double? _lastObservedPixels;
  bool _expectingBypassedPointerScroll = false;
  int _bypassGeneration = 0;

  ScrollPosition? _observedPositionForScrolling;

  PlainScrollControllerGlideAdapter({
    required this.controller,
    required TickerProvider vsync,
    required AxisDirection initialAxisDirection,
    required double damping,
    required this.speedMultiplier,
  }) : _axisDirection = initialAxisDirection,
       _engine = GlideInertiaEngine(
         damping: damping,
         initialOffset: controller.hasClients && controller.positions.length == 1
             ? controller.position.pixels
             : 0.0,
       ) {
    _stepper = GlideTickerStepper(vsync: vsync, onStep: _onGlideStep);
    controller.addListener(_onControllerChanged);
    _syncScrollingObserver();
    if (controller.hasClients && controller.positions.length == 1) {
      _lastObservedPixels = controller.position.pixels;
    }
  }

  void updateAxisDirection(AxisDirection direction) {
    _axisDirection = direction;
  }

  void handlePointerSignal(
    PointerSignalEvent event, {
    required double devicePixelRatio,
    required bool isShiftPressed,
  }) {
    if (_isDisposed) return;
    if (event is PointerScrollInertiaCancelEvent) {
      _stopAndSync();
      velocityTracker.reset();
      return;
    }
    if (event is! PointerScrollEvent) return;
    if (!controller.hasClients || controller.positions.length != 1) return;

    final pos = controller.position;
    _syncScrollingObserver();
    if (event.timeStamp != Duration.zero) {
      _hasSeenNonZeroTimestamp = true;
    }
    final ts = resolvePointerEventTimestamp(
      event,
      hasSeenNonZeroTimestamp: _hasSeenNonZeroTimestamp,
    );

    final shouldBypass = _trackpadTracker.shouldBypass(
      isTrackpadKind: event.kind == PointerDeviceKind.trackpad,
      rawDx: event.scrollDelta.dx,
      rawDy: event.scrollDelta.dy,
      devicePixelRatio: devicePixelRatio,
      isShiftPressed: isShiftPressed,
      timestamp: ts,
    );

    if (shouldBypass) {
      _stopAndSync();
      final gen = ++_bypassGeneration;
      _expectingBypassedPointerScroll = true;
      scheduleMicrotask(() {
        if (_bypassGeneration == gen) {
          _expectingBypassedPointerScroll = false;
        }
      });
      return;
    }

    final resolvedDelta = _resolveAxisDelta(
      event,
      pos: pos,
      isShiftPressed: isShiftPressed,
    );
    if (resolvedDelta == 0.0) return;

    _armedPosition = pos;
    _armedOldPixels = pos.pixels;
    _armedDelta = resolvedDelta;
    final gen = ++_armedGeneration;
    scheduleMicrotask(() {
      if (_armedGeneration == gen) {
        _armedPosition = null;
      }
    });
  }

  void handlePointerPanZoomStart(PointerPanZoomStartEvent event) {
    if (_isDisposed) return;
    _stopAndSync();
    if (event.timeStamp != Duration.zero) {
      _hasSeenNonZeroTimestamp = true;
    }
  }

  void handlePointerPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_isDisposed) return;
    _stopAndSync();
    if (event.timeStamp != Duration.zero) {
      _hasSeenNonZeroTimestamp = true;
    }
    final ts = resolvePointerEventTimestamp(
      event,
      hasSeenNonZeroTimestamp: _hasSeenNonZeroTimestamp,
    );
    final axis = axisDirectionToAxis(_axisDirection);
    final delta = axis == Axis.horizontal ? event.panDelta.dx : event.panDelta.dy;
    velocityTracker.recordDisplacement(delta, timestamp: ts);
  }

  void handlePointerPanZoomEnd(PointerPanZoomEndEvent event) {
    if (_isDisposed) return;
    if (!controller.hasClients || controller.positions.length != 1) {
      velocityTracker.reset();
      return;
    }
    if (!controller.position.isScrollingNotifier.value) {
      velocityTracker.reset();
    }
  }

  double _resolveAxisDelta(
    PointerScrollEvent event, {
    required ScrollPosition pos,
    required bool isShiftPressed,
  }) {
    final flipAxes = isShiftPressed && event.kind == PointerDeviceKind.mouse;
    final effectiveAxis = flipAxes ? flipAxis(pos.axis) : pos.axis;
    final raw = effectiveAxis == Axis.horizontal
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    return axisDirectionIsReversed(pos.axisDirection) ? -raw : raw;
  }

  void _syncScrollingObserver() {
    final nextPos = controller.hasClients && controller.positions.length == 1
        ? controller.position
        : null;
    if (identical(_observedPositionForScrolling, nextPos)) return;
    _observedPositionForScrolling?.isScrollingNotifier.removeListener(
      _onScrollingNotifierChanged,
    );
    _observedPositionForScrolling = nextPos;
    nextPos?.isScrollingNotifier.addListener(_onScrollingNotifierChanged);
  }

  void _onScrollingNotifierChanged() {
    if (_isDisposed || _isApplyingGlideJump || _expectingBypassedPointerScroll) {
      return;
    }
    final pos = _observedPositionForScrolling;
    if (pos != null && !pos.isScrollingNotifier.value && !_stepper.isActive) {
      velocityTracker.reset();
    }
  }

  void _onControllerChanged() {
    if (_isDisposed || _isApplyingGlideJump) return;
    if (!controller.hasClients || controller.positions.length != 1) return;

    _syncScrollingObserver();
    final pos = controller.position;
    final armedPos = _armedPosition;
    if (armedPos != null && identical(armedPos, pos)) {
      _armedPosition = null;
      final actualStep = pos.pixels - _armedOldPixels;
      if (actualStep.abs() > 1e-6) {
        pos.correctPixels(_armedOldPixels);
        _lastObservedPixels = _armedOldPixels;

        final delta = actualStep.sign == _armedDelta.sign || _armedDelta == 0.0
            ? _armedDelta
            : actualStep;
        final hasMotion = _engine.addWheelDelta(
          delta * speedMultiplier,
          deltaMode: WheelDeltaMode.pixel,
          viewportDimension: pos.hasViewportDimension
              ? pos.viewportDimension
              : 0.0,
          currentPosition: _armedOldPixels,
          minExtent: pos.hasContentDimensions ? pos.minScrollExtent : 0.0,
          maxExtent: pos.hasContentDimensions ? pos.maxScrollExtent : 0.0,
        );
        if (hasMotion) {
          _stepper.start();
        }
      }
      return;
    }

    _stepper.stop();
    _engine.syncTo(
      pos.pixels,
      minExtent: pos.hasContentDimensions ? pos.minScrollExtent : null,
      maxExtent: pos.hasContentDimensions ? pos.maxScrollExtent : null,
    );
    final prev = _lastObservedPixels;
    _lastObservedPixels = pos.pixels;

    if (_expectingBypassedPointerScroll) {
      _expectingBypassedPointerScroll = false;
      if (prev != null) {
        velocityTracker.recordDisplacement(
          pos.pixels - prev,
          timestamp: SchedulerBinding.instance.currentSystemFrameTimeStamp,
        );
      }
      return;
    }

    if (pos.isScrollingNotifier.value && prev != null) {
      velocityTracker.recordDisplacement(
        pos.pixels - prev,
        timestamp: SchedulerBinding.instance.currentSystemFrameTimeStamp,
      );
    } else if (!pos.isScrollingNotifier.value) {
      velocityTracker.reset();
    }
  }

  void _onGlideStep(double dtSeconds) {
    if (_isDisposed ||
        !controller.hasClients ||
        controller.positions.length != 1) {
      _stepper.stop();
      return;
    }
    final pos = controller.position;
    if (pos.hasContentDimensions) {
      _engine.updateBounds(
        minExtent: pos.minScrollExtent,
        maxExtent: pos.maxScrollExtent,
      );
    }
    final nextPixels = _engine.step(dtSeconds);
    if ((nextPixels - pos.pixels).abs() > 1e-6) {
      _isApplyingGlideJump = true;
      try {
        pos.jumpTo(nextPixels);
      } finally {
        _isApplyingGlideJump = false;
      }
      _lastObservedPixels = pos.pixels;
    }
    velocityTracker.setDirectVelocity(_engine.velocityPxPerMs);
    if (!_engine.isActive) {
      _stepper.stop();
      velocityTracker.reset();
    }
  }

  void _stopAndSync() {
    _armedPosition = null;
    _stepper.stop();
    if (controller.hasClients && controller.positions.length == 1) {
      final pos = controller.position;
      _engine.syncTo(
        pos.pixels,
        minExtent: pos.hasContentDimensions ? pos.minScrollExtent : null,
        maxExtent: pos.hasContentDimensions ? pos.maxScrollExtent : null,
      );
      _lastObservedPixels = pos.pixels;
    }
  }

  void dispose() {
    _isDisposed = true;
    _armedPosition = null;
    _observedPositionForScrolling?.isScrollingNotifier.removeListener(
      _onScrollingNotifierChanged,
    );
    _observedPositionForScrolling = null;
    controller.removeListener(_onControllerChanged);
    _stepper.dispose();
    velocityTracker.dispose();
  }
}
