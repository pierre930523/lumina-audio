import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/visualizer_lifecycle_coordinator.dart';

class MockVisualizerEngineBridge implements VisualizerEngineBridge {
  int setEnabledCallCount = 0;
  int isEnabledCallCount = 0;
  int getBandsCallCount = 0;
  int lastSetEnabledValue = -1;
  int isEnabledState = 0;

  final Float32List mockBandsData = Float32List(64);

  @override
  int setVisualizerEnabled(int enabled) {
    setEnabledCallCount++;
    lastSetEnabledValue = enabled;
    isEnabledState = enabled;
    return 0;
  }

  @override
  int isVisualizerEnabled() {
    isEnabledCallCount++;
    return isEnabledState;
  }

  @override
  int getVisualizerBands(ffi.Pointer<ffi.Float> outPtr, int maxCount) {
    getBandsCallCount++;
    if (outPtr.address == 0 || maxCount < 64) return 0;
    final view = outPtr.asTypedList(64);
    view.setAll(0, mockBandsData);
    return 64;
  }

  @override
  ffi.Pointer<ffi.Float>? allocateBandsBuffer() => null;

  @override
  void freeBandsBuffer(ffi.Pointer<ffi.Float> ptr) {}
}

void main() {
  group('VisualizerLifecycleCoordinator - 4-Factor Truth Table & State Machine', () {
    late MockVisualizerEngineBridge mockBridge;

    setUp(() {
      mockBridge = MockVisualizerEngineBridge();
    });

    test('16-state truth table: isActive is true ONLY when all 4 factors match (1, 1, 1, 0)', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      for (int i = 0; i < 16; i++) {
        final enabled = (i & 8) != 0;
        final isPlaying = (i & 4) != 0;
        final isVisible = (i & 2) != 0;
        final isMinimized = (i & 1) != 0;

        coordinator.updateFactors(
          enabled: enabled,
          isPlaying: isPlaying,
          isVisible: isVisible,
          isMinimized: isMinimized,
        );

        final expectedActive = enabled && isPlaying && isVisible && !isMinimized;
        expect(
          coordinator.isActive,
          equals(expectedActive),
          reason: 'State (enabled=$enabled, isPlaying=$isPlaying, isVisible=$isVisible, isMinimized=$isMinimized) must be $expectedActive',
        );

        if (expectedActive) {
          expect(coordinator.isTickerRunning, isTrue);
          expect(mockBridge.lastSetEnabledValue, equals(1));
        } else {
          expect(coordinator.isTickerRunning, isFalse);
          if (mockBridge.setEnabledCallCount > 0) {
            expect(mockBridge.lastSetEnabledValue, equals(0));
          }
        }
      }

      coordinator.dispose();
    });

    test('transitions: deactivating any of the 4 factors stops ticker, resets amplitude, and calls bridge(0)', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      // 1. Arm active
      coordinator.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coordinator.isActive, isTrue);
      expect(mockBridge.lastSetEnabledValue, equals(1));

      // Pause audio
      coordinator.updateFactors(isPlaying: false);
      expect(coordinator.isActive, isFalse);
      expect(coordinator.isTickerRunning, isFalse);
      expect(mockBridge.lastSetEnabledValue, equals(0));
      expect(coordinator.currentAmplitude, equals(0.0));

      // Re-arm
      coordinator.updateFactors(isPlaying: true);
      expect(coordinator.isActive, isTrue);
      expect(mockBridge.lastSetEnabledValue, equals(1));

      // Collapse overlay
      coordinator.updateFactors(isVisible: false);
      expect(coordinator.isActive, isFalse);
      expect(mockBridge.lastSetEnabledValue, equals(0));

      // Re-arm
      coordinator.updateFactors(isVisible: true);
      expect(coordinator.isActive, isTrue);

      // Minimize window
      coordinator.updateFactors(isMinimized: true);
      expect(coordinator.isActive, isFalse);
      expect(mockBridge.lastSetEnabledValue, equals(0));

      // Re-arm
      coordinator.updateFactors(isMinimized: false);
      expect(coordinator.isActive, isTrue);

      // Disable setting
      coordinator.updateFactors(enabled: false);
      expect(coordinator.isActive, isFalse);
      expect(mockBridge.lastSetEnabledValue, equals(0));

      coordinator.dispose();
    });

    test('convenience setter methods (setSettingEnabled, setPlaying, setVisible, setMinimized) work equivalently', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      coordinator.setSettingEnabled(true);
      coordinator.setPlaying(true);
      coordinator.setVisible(true);
      coordinator.setMinimized(false);

      expect(coordinator.isActive, isTrue);
      expect(mockBridge.lastSetEnabledValue, equals(1));

      coordinator.setPlaying(false);
      expect(coordinator.isActive, isFalse);
      expect(mockBridge.lastSetEnabledValue, equals(0));

      coordinator.dispose();
    });

    test('didChangeAppLifecycleState sets isMinimized true for hidden/paused and false for resumed', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      coordinator.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coordinator.isActive, isTrue);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(coordinator.isMinimized, isTrue);
      expect(coordinator.isActive, isFalse);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(coordinator.isMinimized, isFalse);
      expect(coordinator.isActive, isTrue);

      coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(coordinator.isMinimized, isTrue);
      expect(coordinator.isActive, isFalse);

      coordinator.dispose();
    });

    test('tick increments tickerCount and reads bands from bridge when active, zero overhead when inactive', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      // When inactive, tick does nothing (0 instructions, 0 FFI calls)
      coordinator.tick();
      expect(coordinator.tickerCount, equals(0));
      expect(mockBridge.getBandsCallCount, equals(0));

      // Activate
      coordinator.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);

      // Provide mock spectrum data
      for (int i = 0; i < 64; i++) {
        mockBridge.mockBandsData[i] = i == 10 ? 0.85 : 0.05;
      }

      coordinator.tick();
      expect(coordinator.tickerCount, equals(1));
      expect(mockBridge.getBandsCallCount, equals(1));
      expect(coordinator.currentAmplitude, closeTo(0.85, 0.001));

      final bands = coordinator.bandsNotifier.value;
      expect(bands.length, equals(64));
      expect(bands[10], closeTo(0.85, 0.001));
      expect(bands[0], closeTo(0.05, 0.001));

      // Deactivate and verify complete quiescence
      coordinator.updateFactors(isPlaying: false);
      final initialGetBands = mockBridge.getBandsCallCount;
      coordinator.tick();
      coordinator.tick();
      coordinator.tick();
      expect(mockBridge.getBandsCallCount, equals(initialGetBands)); // 0 FFI calls
      expect(coordinator.tickerCount, equals(1)); // 0 ticker increments
      expect(coordinator.bandsNotifier.value.every((b) => b == 0.0), isTrue);

      coordinator.dispose();
    });

    test('rapid flapping / burst toggles does not leak or leave dangling state', () {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: false,
      );

      // Arm factors so isPlaying controls active state
      coordinator.updateFactors(enabled: true, isVisible: true, isMinimized: false);

      for (int i = 0; i < 50; i++) {
        coordinator.updateFactors(isPlaying: i % 2 == 0);
      }

      coordinator.updateFactors(isPlaying: false);
      expect(coordinator.isActive, isFalse);
      expect(coordinator.isTickerRunning, isFalse);
      expect(mockBridge.lastSetEnabledValue, equals(0));

      coordinator.dispose();
    });

    test('periodic polling timer runs and stops on deactivate', () async {
      final coordinator = VisualizerLifecycleCoordinator(
        bridge: mockBridge,
        enablePollingTimer: true,
      );

      coordinator.updateFactors(enabled: true, isPlaying: true, isVisible: true, isMinimized: false);
      expect(coordinator.isActive, isTrue);

      // Allow a few 16ms timer intervals
      await Future<void>.delayed(const Duration(milliseconds: 65));
      expect(coordinator.tickerCount, greaterThanOrEqualTo(2));
      final ticksAtStop = coordinator.tickerCount;

      coordinator.updateFactors(isPlaying: false);
      expect(coordinator.isActive, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(coordinator.tickerCount, equals(ticksAtStop)); // Completely halted

      coordinator.dispose();
    });
  });
}
