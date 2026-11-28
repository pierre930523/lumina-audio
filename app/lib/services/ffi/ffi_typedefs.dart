part of '../ffi_audio_service.dart';

typedef LuminaVisualizerSetEnabledNative = ffi.Int32 Function(ffi.Int32);
typedef LuminaVisualizerSetEnabledDart = int Function(int);

typedef LuminaVisualizerIsEnabledNative = ffi.Int32 Function();
typedef LuminaVisualizerIsEnabledDart = int Function();

typedef LuminaVisualizerGetBandsNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Float>,
  ffi.Uint32,
);
typedef LuminaVisualizerGetBandsDart = int Function(
  ffi.Pointer<ffi.Float>,
  int,
);

typedef _LuminaVoidIntNative = ffi.Int32 Function();
typedef _LuminaVoidIntDart = int Function();

typedef _LuminaIntToIntNative = ffi.Int32 Function(ffi.Int32);
typedef _LuminaIntToIntDart = int Function(int);

typedef _LuminaU32ToIntNative = ffi.Int32 Function(ffi.Uint32);
typedef _LuminaU32ToIntDart = int Function(int);

typedef _LuminaStrIntNative = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>);
typedef _LuminaStrIntDart = int Function(ffi.Pointer<ffi.Uint8>);

typedef _LuminaStrPtrNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStrPtrDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
);

typedef _LuminaVoidPtrNative = ffi.Pointer<ffi.Uint8> Function();
typedef _LuminaVoidPtrDart = ffi.Pointer<ffi.Uint8> Function();

typedef _LuminaLimitPtrNative = ffi.Pointer<ffi.Uint8> Function(ffi.Uint32);
typedef _LuminaLimitPtrDart = ffi.Pointer<ffi.Uint8> Function(int);

typedef _LuminaSearchNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
);
typedef _LuminaSearchDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

typedef _LuminaBytesAllocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _LuminaBytesAllocDart = ffi.Pointer<ffi.Uint8> Function(int);

typedef _LuminaBytesFreeNative = ffi.Void Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
);
typedef _LuminaBytesFreeDart = void Function(ffi.Pointer<ffi.Uint8>, int);

typedef _LuminaStringFreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _LuminaStringFreeDart = void Function(ffi.Pointer<ffi.Uint8>);

typedef _LuminaSetVolumeNative = ffi.Int32 Function(ffi.Float);
typedef _LuminaSetVolumeDart = int Function(double);

typedef _LuminaSeekNative = ffi.Int32 Function(ffi.Uint64);
typedef _LuminaSeekDart = int Function(int);

typedef _LuminaSeekAtEpochNative = ffi.Int32 Function(
  ffi.Uint64,
  ffi.Uint64,
);
typedef _LuminaSeekAtEpochDart = int Function(int, int);

typedef _LuminaPlayAsyncNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint64,
);
typedef _LuminaPlayAsyncDart = int Function(ffi.Pointer<ffi.Uint8>, int);

typedef _LuminaCancelPendingNative = ffi.Int32 Function(ffi.Uint64);
typedef _LuminaCancelPendingDart = int Function(int);

typedef _LuminaSkipToStandbyAtEpochNative = ffi.Int32 Function(ffi.Uint64);
typedef _LuminaSkipToStandbyAtEpochDart = int Function(int);

typedef _LuminaVoidU64Native = ffi.Uint64 Function();
typedef _LuminaVoidU64Dart = int Function();

typedef _LuminaStrStrIntNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStrStrIntDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);

typedef _LuminaStrI32IntNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
);
typedef _LuminaStrI32IntDart = int Function(ffi.Pointer<ffi.Uint8>, int);

typedef _LuminaStrFloatIntNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Float,
);
typedef _LuminaStrFloatIntDart = int Function(ffi.Pointer<ffi.Uint8>, double);

typedef _LuminaServerStartNative = ffi.Int32 Function(ffi.Uint16, ffi.Int32);
typedef _LuminaServerStartDart = int Function(int, int);

typedef _LuminaVoidU16Native = ffi.Uint16 Function();
typedef _LuminaVoidU16Dart = int Function();

typedef _LuminaArtworkGetNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
);
typedef _LuminaArtworkGetDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

typedef _LuminaLibraryRescanTagsNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
);
typedef _LuminaLibraryRescanTagsDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

// Phase 3 Streaming Refresh & Network Epoch C-ABI callback typedefs
typedef _LuminaStreamRefreshCbNative = ffi.Void Function(
  ffi.Uint64,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStreamSetRefreshCbNative = ffi.Int32 Function(
  ffi.Pointer<ffi.NativeFunction<_LuminaStreamRefreshCbNative>>,
);
typedef _LuminaStreamSetRefreshCbDart = int Function(
  ffi.Pointer<ffi.NativeFunction<_LuminaStreamRefreshCbNative>>,
);

typedef _LuminaStreamCompleteRefreshNative = ffi.Int32 Function(
  ffi.Uint64,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStreamCompleteRefreshDart = int Function(
  int,
  ffi.Pointer<ffi.Uint8>,
);

typedef _LuminaNetworkEpochCbNative = ffi.Void Function(ffi.Uint64);
typedef _LuminaNetworkSetEpochCbNative = ffi.Int32 Function(
  ffi.Pointer<ffi.NativeFunction<_LuminaNetworkEpochCbNative>>,
);
typedef _LuminaNetworkSetEpochCbDart = int Function(
  ffi.Pointer<ffi.NativeFunction<_LuminaNetworkEpochCbNative>>,
);

// Phase 4 L2 Cache C-ABI typedefs
typedef _LuminaL2CacheInitNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint64,
  ffi.Uint64,
);
typedef _LuminaL2CacheInitDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  int,
  int,
);

typedef _LuminaL2TotalBytesNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint64>,
);
typedef _LuminaL2TotalBytesDart = int Function(ffi.Pointer<ffi.Uint64>);

// Layer 1 Ingestion C-ABI typedefs
typedef _LuminaScanProgressCbNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _LuminaSetScanProgressCbNative = ffi.Int32 Function(
  ffi.Pointer<ffi.NativeFunction<_LuminaScanProgressCbNative>>,
);
typedef _LuminaSetScanProgressCbDart = int Function(
  ffi.Pointer<ffi.NativeFunction<_LuminaScanProgressCbNative>>,
);

typedef _LuminaWatchAddNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Uint32,
);
typedef _LuminaWatchAddDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  int,
);

typedef _LuminaIntToPtrNative = ffi.Pointer<ffi.Uint8> Function(ffi.Int32);
typedef _LuminaIntToPtrDart = ffi.Pointer<ffi.Uint8> Function(int);

typedef _LuminaStr4IntNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStr4IntDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);

typedef _LuminaStr3IntNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStr3IntDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);

typedef _LuminaStr2PtrNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _LuminaStr2PtrDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);

typedef _LuminaStrI32PtrNative = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
);
typedef _LuminaStrI32PtrDart = ffi.Pointer<ffi.Uint8> Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

class _FfiVisualizerEngineBridge implements VisualizerEngineBridge {
  final FfiAudioService _service;
  _FfiVisualizerEngineBridge(this._service);

  @override
  int setVisualizerEnabled(int enabled) {
    return _service._visualizerSetEnabledFn?.call(enabled) ?? 0;
  }

  @override
  int isVisualizerEnabled() {
    return _service._visualizerIsEnabledFn?.call() ?? 0;
  }

  @override
  int getVisualizerBands(ffi.Pointer<ffi.Float> outPtr, int maxCount) {
    return _service._visualizerGetBandsFn?.call(outPtr, maxCount) ?? 0;
  }

  @override
  ffi.Pointer<ffi.Float>? allocateBandsBuffer() {
    if (_service._bytesAllocFn != null) {
      return _service._bytesAllocFn!(64 * ffi.sizeOf<ffi.Float>())
          .cast<ffi.Float>();
    }
    return null;
  }

  @override
  void freeBandsBuffer(ffi.Pointer<ffi.Float> ptr) {
    if (_service._bytesFreeFn != null) {
      _service._bytesFreeFn!(
        ptr.cast<ffi.Uint8>(),
        64 * ffi.sizeOf<ffi.Float>(),
      );
    }
  }
}
