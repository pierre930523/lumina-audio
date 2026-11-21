import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Abstract bridge interface between the Dart lifecycle coordinator and
/// the native audio engine C-FFI exports (`lumina_visualizer_*`).
abstract class VisualizerEngineBridge {
  /// Enables (1) or disables (0) the audio engine visualizer tap and FFT worker.
  int setVisualizerEnabled(int enabled);

  /// Returns whether the audio engine tap is currently active (1 = enabled, 0 = disabled).
  int isVisualizerEnabled();

  /// Copies up to [maxCount] (typically 64) normalized [0.0, 1.0] spectrum band
  /// magnitudes into [outPtr]. Returns the number of bands actually copied.
  int getVisualizerBands(ffi.Pointer<ffi.Float> outPtr, int maxCount);

  /// Optional allocator for native 64-float buffer via engine or custom heap.
  ffi.Pointer<ffi.Float>? allocateBandsBuffer() => null;

  /// Optional deallocator for native 64-float buffer.
  void freeBandsBuffer(ffi.Pointer<ffi.Float> ptr) {}
}

/// 4-Factor Lifecycle Coordinator for the audio visualizer.
///
/// State rule:
/// `isActive == enabled && isPlaying && isVisible && !isMinimized`
///
/// Quiescence Guarantee:
/// When [isActive] is false, 0 timer ticks occur, 0 FFI calls are performed,
/// and the engine tap is disabled, consuming true zero CPU/GPU overhead.
class VisualizerLifecycleCoordinator with WidgetsBindingObserver {
  bool enabled;
  bool isPlaying;
  bool isVisible;
  bool isMinimized;

  final VisualizerEngineBridge? bridge;
  final bool enablePollingTimer;
  final ffi.Pointer<ffi.Float> Function()? bufferAllocator;
  final void Function(ffi.Pointer<ffi.Float>)? bufferDeallocator;

  Timer? _pollTimer;
  ffi.Pointer<ffi.Float>? _nativeBuffer;
  final ValueNotifier<Float32List> _bandsNotifier =
      ValueNotifier<Float32List>(Float32List(64));
  bool _isTicking = false;
  bool _isDecayingOnPause = false;

  int tickerCount = 0;
  bool isTickerRunning = false;
  double currentAmplitude = 0.0;

  bool get isDecayingOnPause => _isDecayingOnPause;

  VisualizerLifecycleCoordinator({
    this.enabled = true,
    this.isPlaying = false,
    this.isVisible = false,
    this.isMinimized = false,
    this.bridge,
    bool? enablePollingTimer,
    this.bufferAllocator,
    this.bufferDeallocator,
  }) : enablePollingTimer = enablePollingTimer ?? (bridge != null) {
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}

    // Evaluate initial state if constructed with active factors
    if (isActive) {
      _start();
    }
  }

  bool get isActive => enabled && isPlaying && isVisible && !isMinimized;

  ValueListenable<Float32List> get bandsNotifier => _bandsNotifier;

  void updateFactors({
    bool? enabled,
    bool? isPlaying,
    bool? isVisible,
    bool? isMinimized,
  }) {
    final prevActive = isActive;
    if (enabled != null) this.enabled = enabled;
    if (isPlaying != null) this.isPlaying = isPlaying;
    if (isVisible != null) this.isVisible = isVisible;
    if (isMinimized != null) this.isMinimized = isMinimized;

    final nextActive = isActive;
    if (prevActive != nextActive) {
      if (nextActive) {
        _isDecayingOnPause = false;
        _start();
      } else {
        if (enablePollingTimer &&
            isPlaying == false &&
            this.enabled &&
            this.isVisible &&
            !this.isMinimized &&
            _bandsNotifier.value.any((b) => b > 0.001)) {
          _startPauseDecay();
        } else {
          _isDecayingOnPause = false;
          _stop();
        }
      }
    } else if (nextActive && _isDecayingOnPause) {
      _isDecayingOnPause = false;
      _start();
    } else if (!nextActive && _isDecayingOnPause) {
      if (!this.enabled || !this.isVisible || this.isMinimized) {
        _isDecayingOnPause = false;
        _stop();
      }
    }
  }

  void setSettingEnabled(bool enabled) => updateFactors(enabled: enabled);
  void setPlaying(bool isPlaying) => updateFactors(isPlaying: isPlaying);
  void setVisible(bool isVisible) => updateFactors(isVisible: isVisible);
  void setMinimized(bool isMinimized) => updateFactors(isMinimized: isMinimized);

  void _start() {
    _isDecayingOnPause = false;
    isTickerRunning = true;
    bridge?.setVisualizerEnabled(1);
    _ensureBuffer();
    _pollTimer?.cancel();
    if (enablePollingTimer) {
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 16), // ~60Hz
        (_) {
          if (_isTicking) return;
          _isTicking = true;
          try {
            if (_isDecayingOnPause) {
              _tickDecay();
            } else {
              tick();
            }
          } finally {
            _isTicking = false;
          }
        },
      );
    }
  }

  void _startPauseDecay() {
    _isDecayingOnPause = true;
    isTickerRunning = false;
    bridge?.setVisualizerEnabled(0);
    _pollTimer?.cancel();
    if (enablePollingTimer) {
      _pollTimer = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) {
          if (_isTicking) return;
          _isTicking = true;
          try {
            if (_isDecayingOnPause) {
              _tickDecay();
            } else {
              tick();
            }
          } finally {
            _isTicking = false;
          }
        },
      );
    }
  }

  void _tickDecay() {
    if (!_isDecayingOnPause) return;
    final current = _bandsNotifier.value;
    var hasAudible = false;
    final decayed = Float32List(64);
    double maxAmp = 0.0;
    for (int i = 0; i < 64; i++) {
      final v = current[i] * 0.88;
      if (v > 0.001) {
        decayed[i] = v;
        hasAudible = true;
        if (v > maxAmp) {
          maxAmp = v;
        }
      } else {
        decayed[i] = 0.0;
      }
    }
    currentAmplitude = maxAmp;
    _bandsNotifier.value = decayed;
    if (!hasAudible) {
      _isDecayingOnPause = false;
      _stop();
    }
  }

  @visibleForTesting
  void tickDecay() => _tickDecay();

  void _stop() {
    _isDecayingOnPause = false;
    isTickerRunning = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    bridge?.setVisualizerEnabled(0);
    currentAmplitude = 0.0;
    _bandsNotifier.value = Float32List(64);
  }

  void tick() {
    if (!isTickerRunning) return;
    tickerCount++;

    final b = bridge;
    final buf = _nativeBuffer;
    if (b != null && buf != null) {
      final copied = b.getVisualizerBands(buf, 64);
      if (copied == 64) {
        final raw = buf.asTypedList(64);
        final list = Float32List.fromList(raw);
        double maxAmp = 0.0;
        for (int i = 0; i < 64; i++) {
          if (list[i] > maxAmp) {
            maxAmp = list[i];
          }
        }
        currentAmplitude = maxAmp;
        _bandsNotifier.value = list;
      }
    }
  }

  void reset() {
    _stop();
    _pollTimer?.cancel();
    _pollTimer = null;
    tickerCount = 0;
    isTickerRunning = false;
    currentAmplitude = 0.0;
    _bandsNotifier.value = Float32List(64);
  }

  void _ensureBuffer() {
    if (_nativeBuffer != null) return;

    if (bridge != null) {
      final allocated = bridge!.allocateBandsBuffer();
      if (allocated != null) {
        _nativeBuffer = allocated;
        return;
      }
    }

    if (bufferAllocator != null) {
      _nativeBuffer = bufferAllocator!();
      return;
    }

    try {
      _nativeBuffer = calloc<ffi.Float>(64);
    } catch (_) {}
  }

  void _freeBuffer() {
    final buf = _nativeBuffer;
    if (buf == null) return;
    _nativeBuffer = null;

    if (bridge != null) {
      bridge!.freeBandsBuffer(buf);
      return;
    }

    if (bufferDeallocator != null) {
      bufferDeallocator!(buf);
      return;
    }

    try {
      calloc.free(buf);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final minimized = (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused);
    updateFactors(isMinimized: minimized);
  }

  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _stop();
    _bandsNotifier.dispose();
    _freeBuffer();
  }
}
