import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// A [ValueNotifier] that ignores late [addListener]/[removeListener] calls
/// after disposal so parent-owned scroll controllers can be safely disposed
/// before descendant [ScrollCardEntrance] widgets unmount.
class SafeVelocityNotifier extends ValueNotifier<double> {
  bool _isDisposed = false;

  SafeVelocityNotifier([super.value = 0.0]);

  @override
  void addListener(VoidCallback listener) {
    if (_isDisposed) return;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_isDisposed) return;
    super.removeListener(listener);
  }

  @override
  set value(double newValue) {
    if (_isDisposed) return;
    super.value = newValue;
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    super.dispose();
  }
}

/// Tracks real-time scroll velocity in `px/ms` across both damped wheel glide
/// and native scrolling (trackpad pan/zoom, drag, scrollbar drag, ballistic).
class ScrollVelocityTracker {
  static const Duration _idleResetDelay = Duration(milliseconds: 90);

  final SafeVelocityNotifier notifier = SafeVelocityNotifier(0.0);

  Duration? _lastSampleTimestamp;
  Timer? _idleResetTimer;

  ValueListenable<double> get listenable => notifier;
  double get velocity => notifier.value;

  void setDirectVelocity(double pxPerMs, {bool scheduleIdleDecay = false}) {
    final sanitized = pxPerMs.isFinite && pxPerMs > 0.0 ? pxPerMs : 0.0;
    notifier.value = sanitized;
    if (sanitized == 0.0 || !scheduleIdleDecay) {
      _idleResetTimer?.cancel();
      _idleResetTimer = null;
    } else {
      _armIdleReset();
    }
  }

  void recordDisplacement(
    double deltaPixels, {
    required Duration timestamp,
    bool scheduleIdleDecay = true,
  }) {
    final absDelta = deltaPixels.abs();
    final prev = _lastSampleTimestamp;
    _lastSampleTimestamp = timestamp;
    if (absDelta <= 1e-6) {
      return;
    }
    if (prev == null) {
      if (scheduleIdleDecay) {
        _armIdleReset();
      }
      return;
    }
    final dtUs = (timestamp - prev).inMicroseconds;
    if (dtUs <= 0) {
      if (scheduleIdleDecay) {
        _armIdleReset();
      }
      return;
    }
    final dtMs = math.max(dtUs / 1000.0, 1.0);
    final instant = absDelta / dtMs;
    final blended = notifier.value > 0.0
        ? (notifier.value * 0.35 + instant * 0.65)
        : instant;
    notifier.value = blended;
    if (scheduleIdleDecay) {
      _armIdleReset();
    }
  }

  void recordActivityVelocityPxPerSec(
    double pxPerSec, {
    bool scheduleIdleDecay = false,
  }) {
    final speed = pxPerSec.isFinite ? pxPerSec.abs() / 1000.0 : 0.0;
    setDirectVelocity(speed, scheduleIdleDecay: scheduleIdleDecay);
  }

  void reset() {
    _idleResetTimer?.cancel();
    _idleResetTimer = null;
    _lastSampleTimestamp = null;
    notifier.value = 0.0;
  }

  void _armIdleReset() {
    _idleResetTimer?.cancel();
    _idleResetTimer = Timer(_idleResetDelay, () {
      _idleResetTimer = null;
      _lastSampleTimestamp = null;
      notifier.value = 0.0;
    });
  }

  void dispose() {
    _idleResetTimer?.cancel();
    _idleResetTimer = null;
    notifier.dispose();
  }
}

/// Broadcasts the current scroll speed (`px/ms`) to descendants via a stable
/// [ValueListenable] without triggering per-frame `InheritedWidget` rebuilds.
class ScrollVelocityScope extends InheritedWidget {
  static const double highSpeedThreshold = 1.8;

  final ValueListenable<double> velocityListenable;

  const ScrollVelocityScope({
    super.key,
    required this.velocityListenable,
    required super.child,
  });

  static ScrollVelocityScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScrollVelocityScope>();
  }

  static ValueListenable<double>? listenableOf(BuildContext context) {
    return maybeOf(context)?.velocityListenable;
  }

  /// Current real-time scroll speed in `px/ms` (`0.0` if no scope exists).
  static double velocityOf(BuildContext context) {
    return listenableOf(context)?.value ?? 0.0;
  }

  /// Returns `true` when real-time scroll speed exceeds [threshold] (`1.8 px/ms`).
  static bool isHighSpeedOf(
    BuildContext context, {
    double threshold = highSpeedThreshold,
  }) {
    return velocityOf(context) > threshold;
  }

  @override
  bool updateShouldNotify(covariant ScrollVelocityScope oldWidget) {
    return !identical(oldWidget.velocityListenable, velocityListenable);
  }
}

/// Applies a subtle 180ms fade + 8px vertical entrance when mounted during
/// gentle/idle scrolling (`<= 1.8 px/ms`), and bypasses instantaneously
/// (`opacity: 1.0`, `offset: Offset.zero`, `Duration.zero`) when scrolling
/// exceeds `1.8 px/ms` or `disableAnimations` is active.
class ScrollCardEntrance extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final double verticalOffset;
  final Curve curve;
  final double highSpeedThreshold;

  const ScrollCardEntrance({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 180),
    this.verticalOffset = 8.0,
    this.curve = Curves.easeOutCubic,
    this.highSpeedThreshold = ScrollVelocityScope.highSpeedThreshold,
  });

  @override
  State<ScrollCardEntrance> createState() => _ScrollCardEntranceState();
}

class _ScrollCardEntranceState extends State<ScrollCardEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
  ValueListenable<double>? _velocityListenable;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    _controller.addStatusListener(_handleAnimationStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final nextListenable = ScrollVelocityScope.listenableOf(context);

    if (!_initialized) {
      _initialized = true;
      _velocityListenable = nextListenable;
      final velocity = nextListenable?.value ?? 0.0;
      if (disableAnimations ||
          velocity > widget.highSpeedThreshold ||
          widget.duration == Duration.zero) {
        _snapToCompleted();
      } else {
        _velocityListenable?.addListener(_onVelocityChanged);
        _controller.forward();
      }
      return;
    }

    if (disableAnimations && _controller.value < 1.0) {
      _detachVelocityListener();
      _snapToCompleted();
      return;
    }

    if (!identical(_velocityListenable, nextListenable)) {
      _detachVelocityListener();
      _velocityListenable = nextListenable;
      if (_controller.isAnimating) {
        if ((nextListenable?.value ?? 0.0) > widget.highSpeedThreshold) {
          _snapToCompleted();
        } else {
          _velocityListenable?.addListener(_onVelocityChanged);
        }
      }
    }
  }

  @override
  void didUpdateWidget(covariant ScrollCardEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.curve != widget.curve) {
      _curved.curve = widget.curve;
    }
    if (oldWidget.duration != widget.duration && _controller.value < 1.0) {
      _controller.duration = widget.duration;
    }
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      _detachVelocityListener();
    }
  }

  void _onVelocityChanged() {
    final velocity = _velocityListenable?.value ?? 0.0;
    if (velocity > widget.highSpeedThreshold && _controller.value < 1.0) {
      _detachVelocityListener();
      _snapToCompleted();
    }
  }

  void _snapToCompleted() {
    _controller.duration = Duration.zero;
    _controller.value = 1.0;
  }

  void _detachVelocityListener() {
    _velocityListenable?.removeListener(_onVelocityChanged);
  }

  @override
  void dispose() {
    _detachVelocityListener();
    _controller.removeStatusListener(_handleAnimationStatus);
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: AnimatedBuilder(
        animation: _curved,
        child: widget.child,
        builder: (context, child) {
          final dy = _controller.value >= 1.0
              ? 0.0
              : widget.verticalOffset * (1.0 - _curved.value);
          return Transform.translate(
            offset: Offset(0.0, dy),
            child: child,
          );
        },
      ),
    );
  }
}
