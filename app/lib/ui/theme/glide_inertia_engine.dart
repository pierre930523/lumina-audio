import 'dart:math' as math;

/// Wheel scroll delta unit matching standard DOM/desktop WheelEvent modes.
enum WheelDeltaMode {
  pixel(0),
  line(1),
  page(2);

  final int code;
  const WheelDeltaMode(this.code);

  static WheelDeltaMode fromCode(int mode) => switch (mode) {
    1 => WheelDeltaMode.line,
    2 => WheelDeltaMode.page,
    _ => WheelDeltaMode.pixel,
  };
}

/// Normalizes a wheel delta into logical pixels according to [deltaMode].
///
/// - `0` ([WheelDeltaMode.pixel]): `delta`
/// - `1` ([WheelDeltaMode.line]): `delta * 40.0`
/// - `2` ([WheelDeltaMode.page]): `delta * viewportDimension`
double normalizeWheelDelta(
  double delta, {
  WheelDeltaMode deltaMode = WheelDeltaMode.pixel,
  double viewportDimension = 0.0,
}) {
  return switch (deltaMode) {
    WheelDeltaMode.pixel => delta,
    WheelDeltaMode.line => delta * 40.0,
    WheelDeltaMode.page => delta * viewportDimension,
  };
}

/// Pure-Dart heuristic detector for bypassing trackpad / non-wheel scroll signals
/// to prevent double inertia when the OS/trackpad already provides smoothing.
class TrackpadHeuristicTracker {
  static const double fineDeltaThreshold = 40.0;
  static const Duration fineWindow = Duration(milliseconds: 120);
  static const double fractionalEpsilon = 1e-3;
  static const int minFineConsecutiveCount = 2;

  Duration? _lastFineTimestamp;
  int _fineConsecutiveCount = 0;

  int get fineConsecutiveCount => _fineConsecutiveCount;

  /// Evaluates whether the incoming scroll event should bypass the Glide engine
  /// and fall back to native 1:1 scrolling.
  ///
  /// Bypasses when ANY of:
  /// a) [isTrackpadKind] is true (`PointerDeviceKind.trackpad`),
  /// b) horizontal [rawDx] is non-zero when Shift is NOT held,
  /// c) [deltaMode] is [WheelDeltaMode.pixel] (`0`) and physical pixel delta
  ///    `rawDy * devicePixelRatio` has a fractional remainder `> 1e-3`,
  /// d) consecutive fine vertical events (`0 < rawDy.abs() < 40.0`) occur
  ///    within `<= 120ms` of a previous `< 40.0` event (`count >= 2`).
  bool shouldBypass({
    required bool isTrackpadKind,
    required double rawDx,
    required double rawDy,
    required double devicePixelRatio,
    required bool isShiftPressed,
    required Duration timestamp,
    WheelDeltaMode deltaMode = WheelDeltaMode.pixel,
  }) {
    final absDy = rawDy.abs();
    final isFineVertical = absDy > 0.0 && absDy < fineDeltaThreshold;
    final bool fineBypass = _recordFineStreak(isFineVertical, timestamp);

    if (isTrackpadKind) {
      return true;
    }

    if (rawDx.abs() > 0.0 && !isShiftPressed) {
      return true;
    }

    if (deltaMode == WheelDeltaMode.pixel) {
      final effectiveDpr = devicePixelRatio > 0.0 ? devicePixelRatio : 1.0;
      final physDy = rawDy * effectiveDpr;
      if ((physDy - physDy.roundToDouble()).abs() > fractionalEpsilon) {
        return true;
      }
    }

    return fineBypass;
  }

  bool _recordFineStreak(bool isFineVertical, Duration timestamp) {
    if (!isFineVertical) {
      _fineConsecutiveCount = 0;
      _lastFineTimestamp = null;
      return false;
    }

    final prev = _lastFineTimestamp;
    if (prev != null) {
      final elapsed = timestamp - prev;
      if (!elapsed.isNegative && elapsed <= fineWindow) {
        _fineConsecutiveCount += 1;
      } else {
        _fineConsecutiveCount = 1;
      }
    } else {
      _fineConsecutiveCount = 1;
    }
    _lastFineTimestamp = timestamp;
    return _fineConsecutiveCount >= minFineConsecutiveCount;
  }

  void reset() {
    _lastFineTimestamp = null;
    _fineConsecutiveCount = 0;
  }
}

/// Pure-Dart exponential damping physics kernel implementing the Glide Inertia
/// Profile (`damping = 9.5`, `wheelMultiplier = 1.15`, `stopThreshold = 0.35`).
class GlideInertiaEngine {
  static const double defaultDamping = 9.5;
  static const double minAllowedDamping = 7.0;
  static const double minRecommendedDamping = 8.5;
  static const double maxRecommendedDamping = 10.5;
  static const double defaultWheelMultiplier = 1.15;
  static const double defaultStopThreshold = 0.35;
  static const double maxFrameDtSeconds = 0.05;
  static const double highSpeedThresholdPxPerMs = 1.8;

  final double damping;
  final double wheelMultiplier;
  final double stopThreshold;
  final double maxDt;

  double _current;
  double _target;
  double _minExtent;
  double _maxExtent;
  double _signedVelocityPxPerMs = 0.0;
  bool _isActive = false;

  GlideInertiaEngine({
    double damping = defaultDamping,
    this.wheelMultiplier = defaultWheelMultiplier,
    this.stopThreshold = defaultStopThreshold,
    this.maxDt = maxFrameDtSeconds,
    double initialOffset = 0.0,
    double minExtent = 0.0,
    double maxExtent = 0.0,
  }) : assert(
         damping >= minAllowedDamping && damping.isFinite,
         'damping must be finite and never < $minAllowedDamping',
       ),
       damping = damping < minAllowedDamping ? minAllowedDamping : damping,
       _current = initialOffset,
       _target = initialOffset,
       _minExtent = minExtent,
       _maxExtent = math.max(minExtent, maxExtent);

  double get current => _current;
  double get target => _target;
  double get minExtent => _minExtent;
  double get maxExtent => _maxExtent;

  /// Unsigned instantaneous glide speed in `px/ms`.
  double get velocityPxPerMs => _signedVelocityPxPerMs.abs();

  /// Signed instantaneous glide velocity in `px/ms`.
  double get signedVelocityPxPerMs => _signedVelocityPxPerMs;

  bool get isActive => _isActive;
  bool get isHighSpeed => velocityPxPerMs > highSpeedThresholdPxPerMs;

  /// Synchronizes `current` and `target` to [offset] and stops motion.
  void syncTo(double offset, {double? minExtent, double? maxExtent}) {
    if (minExtent != null) {
      _minExtent = minExtent;
    }
    if (maxExtent != null) {
      _maxExtent = math.max(_minExtent, maxExtent);
    }
    final clamped = (minExtent != null || maxExtent != null)
        ? offset.clamp(_minExtent, _maxExtent).toDouble()
        : offset;
    _current = clamped;
    _target = clamped;
    _signedVelocityPxPerMs = 0.0;
    _isActive = false;
  }

  /// Updates `[minExtent, maxExtent]` and strictly clamps [target] (and
  /// [current] if extents shrank) within bounds.
  void updateBounds({required double minExtent, required double maxExtent}) {
    _minExtent = minExtent;
    _maxExtent = math.max(minExtent, maxExtent);
    _target = _target.clamp(_minExtent, _maxExtent).toDouble();
    _current = _current.clamp(_minExtent, _maxExtent).toDouble();
    if ((_target - _current).abs() < stopThreshold) {
      _current = _target;
      _signedVelocityPxPerMs = 0.0;
      _isActive = false;
    }
  }

  /// Normalizes [delta] via [deltaMode], scales by [wheelMultiplier], applies
  /// Reverse Direction Braking, and clamps [target] within `[minExtent, maxExtent]`.
  ///
  /// Returns `true` when remaining distance `>= stopThreshold`.
  bool addWheelDelta(
    double delta, {
    WheelDeltaMode deltaMode = WheelDeltaMode.pixel,
    double viewportDimension = 0.0,
    double? currentPosition,
    double? minExtent,
    double? maxExtent,
  }) {
    if (minExtent != null) {
      _minExtent = minExtent;
    }
    if (maxExtent != null) {
      _maxExtent = math.max(_minExtent, maxExtent);
    }
    if (currentPosition != null) {
      if (!_isActive || (currentPosition - _current).abs() > 1.0) {
        _current = currentPosition.clamp(_minExtent, _maxExtent).toDouble();
        if (!_isActive) {
          _target = _current;
        }
      }
    }

    final normalized = normalizeWheelDelta(
      delta,
      deltaMode: deltaMode,
      viewportDimension: viewportDimension,
    );
    final scaledDelta = normalized * wheelMultiplier;
    if (!scaledDelta.isFinite || scaledDelta == 0.0) {
      return _isActive;
    }

    final remaining = _target - _current;
    if (remaining.abs() > 1e-6 &&
        scaledDelta != 0.0 &&
        scaledDelta.sign != remaining.sign) {
      _target = (_current + scaledDelta)
          .clamp(_minExtent, _maxExtent)
          .toDouble();
    } else {
      _target = (_target + scaledDelta)
          .clamp(_minExtent, _maxExtent)
          .toDouble();
    }

    if ((_target - _current).abs() < stopThreshold) {
      _current = _target;
      _signedVelocityPxPerMs = 0.0;
      _isActive = false;
      return false;
    }

    _isActive = true;
    return true;
  }

  /// Advances the exponential damping step by [dtSeconds] (clamped to
  /// `[0.0, maxDt]`), updating [current] and [velocityPxPerMs].
  ///
  /// Snaps `current = target` and resets velocity to `0` once
  /// `(target - current).abs() < stopThreshold`.
  double step(double dtSeconds) {
    final dt = dtSeconds.isFinite
        ? dtSeconds.clamp(0.0, maxDt).toDouble()
        : 0.0;
    final diff = _target - _current;
    if (diff.abs() < stopThreshold) {
      _current = _target;
      _signedVelocityPxPerMs = 0.0;
      _isActive = false;
      return _current;
    }

    if (dt <= 0.0) {
      _isActive = true;
      return _current;
    }

    final prev = _current;
    final factor = 1.0 - math.exp(-damping * dt);
    _current = (prev + diff * factor).clamp(_minExtent, _maxExtent).toDouble();

    if ((_target - _current).abs() < stopThreshold) {
      _current = _target;
      _signedVelocityPxPerMs = 0.0;
      _isActive = false;
      return _current;
    }

    _signedVelocityPxPerMs = (_current - prev) / (dt * 1000.0);
    _isActive = true;
    return _current;
  }

  /// Immediately stops gliding and resets velocity to `0`.
  void stop({double? snapToOffset}) {
    if (snapToOffset != null) {
      _current = snapToOffset;
      _target = snapToOffset;
    } else {
      _target = _current;
    }
    _signedVelocityPxPerMs = 0.0;
    _isActive = false;
  }
}
