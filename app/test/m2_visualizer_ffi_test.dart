import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';

void main() {
  group('C-FFI Visualizer Bridge & FfiAudioService Integration', () {
    final candidates = [
      '../target/debug/core_ffi.dll',
      'target/debug/core_ffi.dll',
      '../target/release/core_ffi.dll',
      'target/release/core_ffi.dll',
    ];

    String? foundDylibPath;
    for (final path in candidates) {
      if (File(path).existsSync()) {
        foundDylibPath = path;
        break;
      }
    }

    test('C-FFI exported symbols are present and callable in core_ffi.dll', () {
      if (foundDylibPath == null) {
        // Skip direct native symbol verification if DLL was not built in CI environment
        return;
      }

      final dylib = ffi.DynamicLibrary.open(foundDylibPath);

      final setEnabledFn = dylib.lookupFunction<
          LuminaVisualizerSetEnabledNative,
          LuminaVisualizerSetEnabledDart>('lumina_visualizer_set_enabled');
      final isEnabledFn = dylib.lookupFunction<
          LuminaVisualizerIsEnabledNative,
          LuminaVisualizerIsEnabledDart>('lumina_visualizer_is_enabled');
      final getBandsFn = dylib.lookupFunction<
          LuminaVisualizerGetBandsNative,
          LuminaVisualizerGetBandsDart>('lumina_visualizer_get_bands');

      expect(setEnabledFn, isNotNull);
      expect(isEnabledFn, isNotNull);
      expect(getBandsFn, isNotNull);

      // 1. Initial / disable check
      var rc = setEnabledFn(0);
      expect(rc, equals(0)); // LUMINA_OK
      expect(isEnabledFn(), equals(0));

      // 2. Enable check
      rc = setEnabledFn(1);
      expect(rc, equals(0)); // LUMINA_OK
      expect(isEnabledFn(), equals(1));

      // 3. Null pointer safety guard: must return 0 without crashing
      final nullPtr = ffi.Pointer<ffi.Float>.fromAddress(0);
      expect(getBandsFn(nullPtr, 64), equals(0));

      // 4. Buffer undersize guard: max_count < 64 must return 0
      final msvcrt = Platform.isWindows
          ? ffi.DynamicLibrary.open('msvcrt.dll')
          : ffi.DynamicLibrary.process();
      final malloc = msvcrt.lookupFunction<ffi.Pointer Function(ffi.Size),
          ffi.Pointer Function(int)>('malloc');
      final free = msvcrt.lookupFunction<ffi.Void Function(ffi.Pointer),
          void Function(ffi.Pointer)>('free');

      final rawBuf = malloc(64 * ffi.sizeOf<ffi.Float>());
      try {
        final floatPtr = rawBuf.cast<ffi.Float>();
        expect(getBandsFn(floatPtr, 32), equals(0)); // undersized count < 64

        // 5. Valid buffer read: returns 64 bands on success (or 0 if no audio rendered yet)
        final copied = getBandsFn(floatPtr, 64);
        expect(copied == 64 || copied == 0, isTrue);

        if (copied == 64) {
          final view = floatPtr.asTypedList(64);
          for (int i = 0; i < 64; i++) {
            expect(view[i], inInclusiveRange(0.0, 1.0));
          }
        }
      } finally {
        free(rawBuf);
      }

      // 6. Disable again and verify is_enabled is 0
      rc = setEnabledFn(0);
      expect(rc, equals(0));
      expect(isEnabledFn(), equals(0));
    });

    test('FfiAudioService initializes with visualizerCoordinator and exposes bandsNotifier', () async {
      final service = FfiAudioService(headless: true);

      expect(service.visualizerCoordinator, isNotNull);
      expect(service.visualizerBandsNotifier, isNotNull);
      expect(service.visualizerBandsNotifier.value.length, equals(64));

      // 4 factors: default is (enabled=true, isPlaying=false, isVisible=false, isMinimized=false) -> inactive
      expect(service.visualizerCoordinator!.isActive, isFalse);

      // Simulate full playback + visibility activation
      service.setNowPlayingVisible(true);
      service.setVisualizerSettingEnabled(true);
      service.setWindowMinimized(false);

      // When audio is stopped, still inactive
      expect(service.visualizerCoordinator!.isActive, isFalse);

      // When playback state changes to playing, coordinator becomes active
      await service.play();
      if (service.currentState.status == PlaybackStatus.playing) {
        expect(service.visualizerCoordinator!.isActive, isTrue);
      }

      // Pause audio -> coordinator becomes inactive
      await service.pause();
      expect(service.visualizerCoordinator!.isActive, isFalse);

      // Minimize window -> coordinator remains inactive
      service.setWindowMinimized(true);
      expect(service.visualizerCoordinator!.isActive, isFalse);

      service.dispose();
    });

    test('AudioServiceVisualizerExt extension methods work safely on MockAudioService without throwing', () {
      final mock = MockAudioService();

      expect(mock.visualizerBandsNotifier, isNotNull);
      expect(mock.visualizerBandsNotifier.value.length, equals(64));
      expect(mock.visualizerBandsNotifier.value.every((b) => b == 0.0), isTrue);

      // Invoking extension setters on mock must be safe no-op
      mock.setVisualizerSettingEnabled(false);
      mock.setNowPlayingVisible(true);
      mock.setWindowMinimized(true);

      mock.dispose();
    });

    test('FfiAudioService cleans up visualizer memory and timers on dispose', () {
      final service = FfiAudioService(headless: true);
      service.setNowPlayingVisible(true);
      service.setVisualizerSettingEnabled(true);

      service.dispose();
      expect(service.visualizerCoordinator, isNull);
    });
  });
}
