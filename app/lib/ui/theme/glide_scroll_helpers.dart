import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Returns `true` when Glide Inertia smooth scrolling should be active
/// (non-web desktop platforms: Windows, macOS, Linux, or forced in tests).
bool isLuminaDesktopPlatform({bool? forceDesktop}) {
  if (forceDesktop != null) return forceDesktop;
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

/// Computes an effective monotonic timestamp for pointer events, falling back
/// to [SchedulerBinding.instance.currentSystemFrameTimeStamp] when synthetic
/// events carry `Duration.zero`.
Duration resolvePointerEventTimestamp(
  PointerEvent event, {
  required bool hasSeenNonZeroTimestamp,
}) {
  if (event.timeStamp != Duration.zero || hasSeenNonZeroTimestamp) {
    return event.timeStamp;
  }
  return SchedulerBinding.instance.currentSystemFrameTimeStamp;
}

/// Resolves the physical device pixel ratio of the hosting [FlutterView] rather
/// than the UI-scaled `MediaQuery.devicePixelRatio`, ensuring Windows 125%/150%
/// DPI scaling (`100 / 1.5 = 66.6667`) recovers exact integer hardware ticks.
double resolvePhysicalDevicePixelRatio(BuildContext context) {
  return View.maybeOf(context)?.devicePixelRatio ??
      MediaQuery.maybeDevicePixelRatioOf(context) ??
      1.0;
}

class PendingPointerSignalMetadata {
  final PointerScrollEvent event;
  final double devicePixelRatio;
  final bool isShiftPressed;
  final double speedMultiplier;
  final Duration effectiveTimestamp;

  const PendingPointerSignalMetadata({
    required this.event,
    required this.devicePixelRatio,
    required this.isShiftPressed,
    required this.speedMultiplier,
    required this.effectiveTimestamp,
  });
}

/// Manages frame-accurate `Ticker` delta stepping, avoiding the 1-frame initial
/// dead tick caused by `Ticker` starting with `elapsed == Duration.zero`.
class GlideTickerStepper {
  final TickerProvider vsync;
  final void Function(double dtSeconds) onStep;

  Ticker? _ticker;
  Duration? _lastElapsed;
  Duration _startSystemTimestamp = Duration.zero;

  GlideTickerStepper({required this.vsync, required this.onStep});

  bool get isActive => _ticker?.isActive ?? false;

  void start() {
    _ticker ??= vsync.createTicker(_handleTick);
    if (_ticker!.isActive) return;
    _lastElapsed = null;
    _startSystemTimestamp =
        SchedulerBinding.instance.currentSystemFrameTimeStamp;
    _ticker!.start();
  }

  void stop() {
    _ticker?.stop();
    _lastElapsed = null;
  }

  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _lastElapsed = null;
  }

  void _handleTick(Duration elapsed) {
    final double dtSeconds;
    if (_lastElapsed == null) {
      _lastElapsed = elapsed;
      if (elapsed > Duration.zero) {
        dtSeconds = elapsed.inMicroseconds / 1000000.0;
      } else {
        final frameDelta =
            SchedulerBinding.instance.currentSystemFrameTimeStamp -
            _startSystemTimestamp;
        if (frameDelta > Duration.zero &&
            frameDelta <= const Duration(milliseconds: 50)) {
          dtSeconds = frameDelta.inMicroseconds / 1000000.0;
        } else if (frameDelta > const Duration(milliseconds: 50)) {
          dtSeconds = 1.0 / 60.0;
        } else {
          dtSeconds = 0.0;
        }
      }
    } else {
      final delta = elapsed - _lastElapsed!;
      _lastElapsed = elapsed;
      dtSeconds = delta.isNegative ? 0.0 : delta.inMicroseconds / 1000000.0;
    }
    onStep(dtSeconds);
  }
}
