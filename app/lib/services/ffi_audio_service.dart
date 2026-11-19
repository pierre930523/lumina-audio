import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import '../models/audio_format.dart';
import '../models/audio_output_info.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/signal_path.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'mock_audio_service.dart';
import 'per_device_playback_tracker.dart';
import 'server_audio_service.dart';

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

class FfiAudioService implements AudioService {
  final MockAudioService _delegate;
  final PerDevicePlaybackTracker _tracker = PerDevicePlaybackTracker();
  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _signalPathController =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  ffi.DynamicLibrary? _dylib;
  _LuminaVoidIntDart? _initFn;
  _LuminaVoidIntDart? _initHeadlessFn;
  _LuminaVoidIntDart? _shutdownFn;
  _LuminaBytesAllocDart? _bytesAllocFn;
  _LuminaBytesFreeDart? _bytesFreeFn;
  _LuminaStringFreeDart? _stringFreeFn;
  _LuminaStrIntDart? _libInitFn;
  _LuminaStrPtrDart? _libScanDirFn;
  _LuminaLimitPtrDart? _libGetTracksFn;
  _LuminaSearchDart? _libSearchFn;
  _LuminaStrIntDart? _playFn;
  _LuminaVoidIntDart? _pauseFn;
  _LuminaVoidIntDart? _stopFn;
  _LuminaSeekDart? _seekFn;
  _LuminaSetVolumeDart? _setVolumeFn;
  _LuminaVoidIntDart? _getStateFn;
  _LuminaVoidU64Dart? _getPositionFn;
  _LuminaVoidU64Dart? _getDurationFn;
  _LuminaVoidPtrDart? _signalPathGetFn;
  _LuminaVoidIntDart? _toggleBypassFn;
  _LuminaVoidPtrDart? _lastErrorMsgFn;

  // Extended M7c–M10 optional C-ABI bindings
  _LuminaLimitPtrDart? _getAlbumsFn;
  _LuminaStrPtrDart? _getAlbumDetailFn;
  _LuminaStrPtrDart? _getArtistDetailFn;
  _LuminaStrPtrDart? _enrichCreditsFn;
  _LuminaVoidPtrDart? _deduplicateFn;
  _LuminaVoidPtrDart? _profileListFn;
  _LuminaStrPtrDart? _profileCreateFn;
  _LuminaStrStrIntDart? _profileUpdateFn;
  _LuminaStrIntDart? _profileDeleteFn;
  _LuminaStrIntDart? _profileSwitchFn;
  _LuminaVoidPtrDart? _audioListDevicesFn;
  _LuminaStrI32IntDart? _audioSelectDeviceFn;
  _LuminaVoidPtrDart? _audioGetOutputInfoFn;
  _LuminaVoidPtrDart? _audioListDeviceCapsFn;
  _LuminaIntToIntDart? _audioSetStrictModeFn;
  _LuminaIntToIntDart? _audioSetDsdModeFn;
  _LuminaU32ToIntDart? _audioSetBufferFramesFn;
  _LuminaVoidPtrDart? _dspGetConfigFn;
  _LuminaStrIntDart? _dspSetConfigFn;
  _LuminaStrPtrDart? _dspImportAutoeqFn;
  _LuminaStrStrIntDart? _providerConfigureFn;
  _LuminaStrPtrDart? _providerSyncFn;
  _LuminaVoidPtrDart? _tidalPkceStartFn;
  _LuminaStrPtrDart? _tidalPkceCompleteFn;
  _LuminaVoidPtrDart? _zoneListFn;
  _LuminaVoidPtrDart? _zoneDiscoverFn;
  _LuminaStrIntDart? _zoneGroupFn;
  _LuminaStrFloatIntDart? _zoneSetVolumeFn;
  _LuminaStrPtrDart? _zoneSyncStatusFn;
  _LuminaServerStartDart? _serverStartFn;
  _LuminaVoidU16Dart? _serverGetPortFn;

  // Features F11-F13 FFI function pointers
  _LuminaVoidIntDart? _playbackResumeFn;
  _LuminaVoidPtrDart? _playbackGetStateJsonFn;
  _LuminaVoidIntDart? _playbackReconnectDeviceFn;
  _LuminaArtworkGetDart? _artworkGetFn;
  _LuminaStrStrIntDart? _artworkSetUserCoverFn;
  _LuminaStrIntDart? _artworkClearUserCoverFn;
  _LuminaLibraryRescanTagsDart? _libraryRescanTagsFn;
  _LuminaStrPtrDart? _lyricsGetFn;
  _LuminaStrStrIntDart? _lyricsSetUserFileFn;
  _LuminaStrIntDart? _lyricsClearUserFileFn;

  List<LyricLine> _currentLyrics = const [];

  ServerAudioService? _remoteClient;
  ConnectionMode _connectionMode = ConnectionMode.localOrUsbDac;

  late PlaybackState _state;
  late SignalPath _signalPath;
  List<TrackInfo> _queue = [];
  int _currentIndex = 0;
  Timer? _positionTimer;
  String? _lastError;
  bool _isReroutingDevice = false;
  Duration? _pendingResumePosition;
  bool _strictBitPerfect = false;
  double _savedNormalVolume = 0.85;
  DsdOutputModeOption _dsdOutputMode = DsdOutputModeOption.auto;
  bool _systemOutputActive = true;
  int _preferredBufferFrames = 512;

  @override
  String? get lastError => _lastError;

  @override
  bool get isSystemOutputActive {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.isSystemOutputActive;
    }
    if (!isNativeBound) return _delegate.isSystemOutputActive;
    return _systemOutputActive;
  }

  @override
  int get preferredBufferFrames =>
      !isNativeBound ? _delegate.preferredBufferFrames : _preferredBufferFrames;

  @override
  String? get activeDeviceId {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.activeDeviceId;
    }
    if (!isNativeBound) return _delegate.activeDeviceId;
    return _tracker.activeDeviceId;
  }

  @override
  Map<String, PlaybackState> get devicePlaybackStates {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.devicePlaybackStates;
    }
    if (!isNativeBound) return _delegate.devicePlaybackStates;
    return _tracker.snapshotDevices(_state);
  }

  @override
  Map<String, PlaybackState> get zonePlaybackStates {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.zonePlaybackStates;
    }
    if (!isNativeBound) return _delegate.zonePlaybackStates;
    return _tracker.snapshotZones(activeLocalState: _state);
  }

  FfiAudioService({
    MockAudioService? fallback,
    bool headless = false,
    String? databasePath,
  }) : _delegate = fallback ?? MockAudioService() {
    _state = _delegate.currentState;
    _signalPath = _delegate.currentSignalPath;
    _queue = List<TrackInfo>.from(_delegate.queue);
    _tryLoadNativeLibrary(headless: headless, databasePath: databasePath);
  }

  void _tryLoadNativeLibrary({required bool headless, String? databasePath}) {
    try {
      final libName = Platform.isWindows
          ? 'core_ffi.dll'
          : (Platform.isMacOS ? 'libcore_ffi.dylib' : 'libcore_ffi.so');
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final candidates = [
        '$exeDir${Platform.pathSeparator}$libName',
        libName,
        '../target/debug/$libName',
        '../target/release/$libName',
        'target/debug/$libName',
        'target/release/$libName',
      ];
      for (final path in candidates) {
        if (File(path).existsSync()) {
          _dylib = ffi.DynamicLibrary.open(path);
          break;
        }
      }
      final dylib = _dylib;
      if (dylib == null) {
        return;
      }

      _initFn = dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_init',
      );
      _initHeadlessFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_init_headless',
      );
      _shutdownFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_shutdown',
      );
      _bytesAllocFn = dylib
          .lookupFunction<_LuminaBytesAllocNative, _LuminaBytesAllocDart>(
        'lumina_bytes_alloc',
      );
      _bytesFreeFn = dylib
          .lookupFunction<_LuminaBytesFreeNative, _LuminaBytesFreeDart>(
        'lumina_bytes_free',
      );
      _stringFreeFn = dylib
          .lookupFunction<_LuminaStringFreeNative, _LuminaStringFreeDart>(
        'lumina_string_free',
      );
      _libInitFn = dylib
          .lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_init',
      );
      _libScanDirFn = dylib
          .lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_scan_dir',
      );
      _libGetTracksFn = dylib
          .lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>(
        'lumina_library_get_tracks',
      );
      _libSearchFn = dylib
          .lookupFunction<_LuminaSearchNative, _LuminaSearchDart>(
        'lumina_library_search',
      );
      _playFn = dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_playback_play',
      );
      _pauseFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_playback_pause',
      );
      _stopFn = dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_playback_stop',
      );
      _seekFn = dylib.lookupFunction<_LuminaSeekNative, _LuminaSeekDart>(
        'lumina_playback_seek',
      );
      _setVolumeFn = dylib
          .lookupFunction<_LuminaSetVolumeNative, _LuminaSetVolumeDart>(
        'lumina_playback_set_volume',
      );
      _getStateFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_playback_get_state',
      );
      _getPositionFn = dylib
          .lookupFunction<_LuminaVoidU64Native, _LuminaVoidU64Dart>(
        'lumina_playback_get_position_ms',
      );
      _getDurationFn = dylib
          .lookupFunction<_LuminaVoidU64Native, _LuminaVoidU64Dart>(
        'lumina_playback_get_duration_ms',
      );
      _signalPathGetFn = dylib
          .lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_signal_path_get',
      );
      _toggleBypassFn = dylib
          .lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>(
        'lumina_signal_path_toggle_dsp_bypass',
      );

      F? tryLookup<F>(F Function() lookup) {
        try {
          return lookup();
        } catch (_) {
          return null;
        }
      }

      _lastErrorMsgFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_last_error_message'));

      _getAlbumsFn = tryLookup(() => dylib.lookupFunction<_LuminaLimitPtrNative, _LuminaLimitPtrDart>('lumina_library_get_albums'));
      _getAlbumDetailFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_get_album_detail'));
      _getArtistDetailFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_get_artist_detail'));
      _enrichCreditsFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_library_enrich_credits'));
      _deduplicateFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_library_deduplicate'));
      _profileListFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_profile_list'));
      _profileCreateFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_profile_create'));
      _profileUpdateFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_profile_update'));
      _profileDeleteFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_profile_delete'));
      _profileSwitchFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_profile_switch'));
      _audioListDevicesFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_audio_list_devices'));
      _audioSelectDeviceFn = tryLookup(() => dylib.lookupFunction<_LuminaStrI32IntNative, _LuminaStrI32IntDart>('lumina_audio_select_device'));
      _audioGetOutputInfoFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_audio_get_output_info'));
      _audioListDeviceCapsFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_audio_list_device_capabilities'));
      _audioSetStrictModeFn = tryLookup(() => dylib.lookupFunction<_LuminaIntToIntNative, _LuminaIntToIntDart>('lumina_audio_set_strict_mode'));
      _audioSetDsdModeFn = tryLookup(() => dylib.lookupFunction<_LuminaIntToIntNative, _LuminaIntToIntDart>('lumina_audio_set_dsd_mode'));
      _audioSetBufferFramesFn = tryLookup(() => dylib.lookupFunction<_LuminaU32ToIntNative, _LuminaU32ToIntDart>('lumina_audio_set_buffer_frames'));
      _dspGetConfigFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_dsp_get_config'));
      _dspSetConfigFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_dsp_set_config'));
      _dspImportAutoeqFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_dsp_import_autoeq'));
      _providerConfigureFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_provider_configure'));
      _providerSyncFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_provider_sync'));
      _tidalPkceStartFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_provider_tidal_pkce_start'));
      _tidalPkceCompleteFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_provider_tidal_pkce_complete'));
      _zoneListFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_zone_list'));
      _zoneDiscoverFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_zone_discover'));
      _zoneGroupFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_zone_group'));
      _zoneSetVolumeFn = tryLookup(() => dylib.lookupFunction<_LuminaStrFloatIntNative, _LuminaStrFloatIntDart>('lumina_zone_set_volume'));
      _zoneSyncStatusFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_zone_sync_status'));
      _serverStartFn = tryLookup(() => dylib.lookupFunction<_LuminaServerStartNative, _LuminaServerStartDart>('lumina_server_start'));
      _serverGetPortFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidU16Native, _LuminaVoidU16Dart>('lumina_server_get_port'));

      _playbackResumeFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>('lumina_playback_resume'));
      _playbackGetStateJsonFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>('lumina_playback_get_state_json'));
      _playbackReconnectDeviceFn = tryLookup(() => dylib.lookupFunction<_LuminaVoidIntNative, _LuminaVoidIntDart>('lumina_playback_reconnect_device'));
      _artworkGetFn = tryLookup(() => dylib.lookupFunction<_LuminaArtworkGetNative, _LuminaArtworkGetDart>('lumina_artwork_get'));
      _artworkSetUserCoverFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_artwork_set_user_cover'));
      _artworkClearUserCoverFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_artwork_clear_user_cover'));
      _libraryRescanTagsFn = tryLookup(() => dylib.lookupFunction<_LuminaLibraryRescanTagsNative, _LuminaLibraryRescanTagsDart>('lumina_library_rescan_tags'));
      _lyricsGetFn = tryLookup(() => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>('lumina_lyrics_get'));
      _lyricsSetUserFileFn = tryLookup(() => dylib.lookupFunction<_LuminaStrStrIntNative, _LuminaStrStrIntDart>('lumina_lyrics_set_user_file'));
      _lyricsClearUserFileFn = tryLookup(() => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>('lumina_lyrics_clear_user_file'));

      final initRc = headless ? _initHeadlessFn!() : _initFn!();
      if (initRc != 0) {
        _dylib = null;
        return;
      }

      final dbPath = databasePath ??
          '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_desktop_library.db';
      _withNativeUtf8(dbPath, (ptr) => _libInitFn!(ptr));
      _setVolumeFn?.call(_state.volume);
      _reloadTracksFromNative();
      _refreshSignalPath();
      _syncNativeDevicesAndZones();
    } catch (_) {
      _dylib = null;
    }
  }

  void _syncNativeDevicesAndZones() {
    if (!isNativeBound) return;
    if (_audioListDevicesFn != null) {
      final raw = _takeRustString(_audioListDevicesFn!());
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _tracker.syncActiveFromDevices(
            decoded.whereType<Map<String, dynamic>>().map(AudioDeviceInfo.fromJson).toList(),
          );
        }
      }
    }
    if (_zoneListFn != null) {
      final raw = _takeRustString(_zoneListFn!());
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _tracker.syncZones(
            decoded.whereType<Map<String, dynamic>>().map(AudioZoneInfo.fromJson).toList(),
            activeLocalState: _state,
          );
        }
      }
    }
  }

  @override
  bool get isNativeBound => _dylib != null;

  @override
  ConnectionMode get connectionMode => _connectionMode;

  @override
  String? get activeServerUrl => _remoteClient?.activeServerUrl;

  @override
  Stream<PlaybackState> get stateStream =>
      isNativeBound ? _stateController.stream : _delegate.stateStream;

  @override
  Stream<SignalPath> get signalPathStream =>
      isNativeBound ? _signalPathController.stream : _delegate.signalPathStream;

  @override
  Stream<Duration> get positionStream =>
      isNativeBound ? _positionController.stream : _delegate.positionStream;

  @override
  PlaybackState get currentState =>
      isNativeBound ? _state : _delegate.currentState;

  @override
  SignalPath get currentSignalPath =>
      isNativeBound ? _signalPath : _delegate.currentSignalPath;

  @override
  List<LyricLine> get currentLyrics {
    if (_currentLyrics.isNotEmpty) return _currentLyrics;
    if (!isNativeBound) return _delegate.currentLyrics;
    return const [];
  }

  @override
  List<TrackInfo> get queue => isNativeBound ? _queue : _delegate.queue;

  R _withNativeUtf8<R>(String value, R Function(ffi.Pointer<ffi.Uint8>) fn) {
    final encoded = utf8.encode(value);
    final ptr = _bytesAllocFn!(encoded.length);
    try {
      final view = ptr.asTypedList(encoded.length + 1);
      view.setAll(0, encoded);
      view[encoded.length] = 0;
      return fn(ptr);
    } finally {
      _bytesFreeFn!(ptr, encoded.length);
    }
  }

  String? _takeRustString(ffi.Pointer<ffi.Uint8> ptr) {
    if (ptr == ffi.nullptr) {
      return null;
    }
    try {
      final bytes = <int>[];
      var offset = 0;
      while (true) {
        final b = ptr[offset];
        if (b == 0) {
          break;
        }
        bytes.add(b);
        offset++;
      }
      return utf8.decode(bytes);
    } finally {
      _stringFreeFn?.call(ptr);
    }
  }

  AudioCodec _parseCodec(String? raw) => switch (raw?.toLowerCase()) {
    'flac' => AudioCodec.flac,
    'alac' => AudioCodec.alac,
    'wav' => AudioCodec.wav,
    'aiff' => AudioCodec.aiff,
    'aac' => AudioCodec.aac,
    'mp3' => AudioCodec.mp3,
    'opus' => AudioCodec.opus,
    'dsf' => AudioCodec.dsf,
    'dsdiff' => AudioCodec.dsdiff,
    _ => AudioCodec.flac,
  };

  SignalQuality _parseQuality(String? raw) => switch (raw?.toLowerCase()) {
    'lossless' => SignalQuality.lossless,
    'enhanced' => SignalQuality.enhanced,
    _ => SignalQuality.highQuality,
  };

  List<TrackInfo> _parseTrackListJson(String? rawJson) {
    if (rawJson == null || rawJson.isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      return const [];
    }
    final tracks = <TrackInfo>[];
    for (final item in decoded) {
      if (item is Map<String, dynamic>) {
        tracks.add(
          TrackInfo(
            id: item['id']?.toString() ?? '',
            title: item['title']?.toString() ?? '未知曲目',
            artist: item['artist_name']?.toString() ?? item['artist']?.toString() ?? '未知藝術家',
            album: item['album']?.toString() ?? '未知專輯',
            duration: Duration(
              milliseconds: (item['duration_ms'] as num?)?.toInt() ?? 0,
            ),
            format: AudioFormat(
              codec: _parseCodec(item['codec']?.toString()),
              sampleRateHz: (item['sample_rate_hz'] as num?)?.toInt() ?? 44100,
              bitDepth: (item['bit_depth'] as num?)?.toInt() ?? 16,
              channels: (item['channels'] as num?)?.toInt() ?? 2,
              isDsd: item['is_dsd'] == true,
            ),
            providerName: 'Local Library',
            filePath: item['file_path']?.toString(),
            albumArtist: item['album_artist']?.toString(),
            genre: item['genre']?.toString(),
            year: (item['year'] as num?)?.toInt(),
            trackNumber: (item['track_number'] as num?)?.toInt(),
            discNumber: (item['disc_number'] as num?)?.toInt(),
            composer: item['composer']?.toString(),
            coverUrl: item['cover_url']?.toString(),
            artworkCacheKey: item['artwork_cache_key']?.toString(),
            hasLyrics: item['has_lyrics'] == true,
          ),
        );
      }
    }
    return tracks;
  }

  void _reloadTracksFromNative() {
    if (!isNativeBound) return;
    final ptr = _libGetTracksFn!(200);
    final raw = _takeRustString(ptr);
    final parsed = _parseTrackListJson(raw);
    if (parsed.isNotEmpty) {
      _queue = parsed;
      if (_currentIndex >= _queue.length) {
        _currentIndex = 0;
      }
      _state = _state.copyWith(track: _queue[_currentIndex]);
    }
  }

  void _refreshSignalPath() {
    if (!isNativeBound) return;
    final raw = _takeRustString(_signalPathGetFn!());
    if (raw == null) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return;

    final overall = _parseQuality(decoded['overall_quality']?.toString());
    final bypassed = decoded['dsp_bypassed'] == true;
    final rawNodes = decoded['nodes'] as List<dynamic>? ?? const [];
    final nodes = <SignalPathNode>[];
    for (final n in rawNodes) {
      if (n is Map<String, dynamic>) {
        final stage = n['stage']?.toString() ?? 'Stage';
        final detail = n['detail']?.toString() ?? '';
        final q = _parseQuality(n['quality']?.toString());
        nodes.add(
          SignalPathNode(
            title: stage,
            subtitle: stage,
            detail: detail,
            quality: q,
          ),
        );
      }
    }

    _signalPath = SignalPath(
      overallQuality: overall,
      description: overall.description,
      nodes: nodes,
      dspBypassed: bypassed,
    );
    if (!_signalPathController.isClosed) {
      _signalPathController.add(_signalPath);
    }
  }

  void _emitState(PlaybackState nextState) {
    _state = nextState;
    _tracker.updateActiveDeviceState(_state, queueIndex: _currentIndex);
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
    if (!_positionController.isClosed) {
      _positionController.add(_state.position);
    }
  }

  List<LyricLine> _parseLyricsJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map<String, dynamic> || decoded['found'] != true) {
        return const [];
      }
      final rawLines = decoded['lines'] as List<dynamic>? ?? const [];
      final lines = <LyricLine>[];
      for (final l in rawLines) {
        if (l is Map<String, dynamic>) {
          final words = <LyricWord>[];
          if (l['words'] is List) {
            for (final w in l['words']) {
              if (w is Map<String, dynamic>) {
                words.add(
                  LyricWord(
                    text: w['text']?.toString() ?? '',
                    start: Duration(milliseconds: (w['start_ms'] as num?)?.toInt() ?? 0),
                    end: Duration(milliseconds: (w['end_ms'] as num?)?.toInt() ?? 0),
                  ),
                );
              }
            }
          }
          final startMs = (l['start_ms'] as num?)?.toInt();
          final endMs = (l['end_ms'] as num?)?.toInt();
          lines.add(
            LyricLine(
              start: Duration(milliseconds: startMs ?? 0),
              end: Duration(milliseconds: endMs ?? 0),
              text: l['text']?.toString() ?? '',
              words: words,
              isSynced: startMs != null || words.isNotEmpty,
            ),
          );
        }
      }
      return lines;
    } catch (_) {
      return const [];
    }
  }

  void _loadLyricsForTrack(TrackInfo target) {
    _currentLyrics = const [];
    if (!isNativeBound) {
      _currentLyrics = _delegate.currentLyrics;
      return;
    }
    if (_lyricsGetFn != null) {
      final targetPayload = jsonEncode({
        'track_id': target.id,
        'file_path': ?target.filePath,
      });
      final ptr = _withNativeUtf8(targetPayload, (p) => _lyricsGetFn!(p));
      final raw = _takeRustString(ptr);
      if (raw != null) {
        _currentLyrics = _parseLyricsJson(raw);
      }
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!isNativeBound) {
        _positionTimer?.cancel();
        return;
      }
      if (_playbackGetStateJsonFn != null) {
        final raw = _takeRustString(_playbackGetStateJsonFn!());
        if (raw != null) {
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            final stateCode = (json['state_code'] as num?)?.toInt() ?? 1;
            final posMs = (json['position_ms'] as num?)?.toInt() ?? 0;
            final durMs = (json['duration_ms'] as num?)?.toInt() ?? 0;
            final seekEpoch = (json['seek_epoch'] as num?)?.toInt() ?? _state.seekEpoch;
            final isSeeking = json['is_seeking'] == true;
            final deviceLost = json['device_lost'] == true;
            final lastErr = json['last_error']?.toString();
            final clockSrc = json['clock_source']?.toString() ?? _state.clockSource;
            final status = PlaybackStatus.fromCode(stateCode);

            final updatedTrack = _state.track != null && durMs > 0
                ? _state.track!.copyWith(duration: Duration(milliseconds: durMs))
                : _state.track;

            if (status == PlaybackStatus.stopped || status == PlaybackStatus.error) {
              if (_isReroutingDevice) return;
              if (lastErr != null && lastErr.isNotEmpty) {
                _lastError = lastErr;
              }
              _positionTimer?.cancel();
            }

            _emitState(
              _state.copyWith(
                status: status,
                track: updatedTrack,
                position: Duration(milliseconds: posMs),
                seekEpoch: seekEpoch,
                isSeeking: isSeeking,
                deviceLost: deviceLost,
                lastError: lastErr,
                clockSource: clockSrc,
              ),
            );
            return;
          } catch (_) {}
        }
      }

      final stateCode = _getStateFn!();
      final posMs = _getPositionFn!();
      final durMs = _getDurationFn!();
      final updatedTrack = _state.track != null && durMs > 0
          ? _state.track!.copyWith(duration: Duration(milliseconds: durMs))
          : _state.track;

      if (stateCode == 0 || stateCode == 1 || stateCode == 4) {
        if (_isReroutingDevice) {
          return;
        }
        if (stateCode == 4 && _lastErrorMsgFn != null) {
          final errMsg = _takeRustString(_lastErrorMsgFn!());
          if (errMsg != null && errMsg.isNotEmpty) {
            _lastError = errMsg;
          }
        }
        _positionTimer?.cancel();
        _emitState(
          _state.copyWith(
            status: PlaybackStatus.fromCode(stateCode),
            track: updatedTrack,
            position: Duration(milliseconds: posMs),
          ),
        );
      } else {
        _emitState(
          _state.copyWith(
            status: PlaybackStatus.fromCode(stateCode),
            track: updatedTrack,
            position: Duration(milliseconds: posMs),
          ),
        );
      }
    });
  }

  @override
  Future<int> scanDirectory(String path) async {
    if (!isNativeBound) {
      return _delegate.scanDirectory(path);
    }
    final ptr = _withNativeUtf8(path, (p) => _libScanDirFn!(p));
    final raw = _takeRustString(ptr);
    _reloadTracksFromNative();
    _emitState(_state);
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return (decoded['tracks_count'] as num?)?.toInt() ?? _queue.length;
      }
    }
    return _queue.length;
  }

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    if (!isNativeBound) {
      return _delegate.searchLibrary(query);
    }
    final q = query.trim();
    if (q.isEmpty) {
      return List<TrackInfo>.from(_queue);
    }
    final ptr = _withNativeUtf8(q, (p) => _libSearchFn!(p, 50));
    final raw = _takeRustString(ptr);
    final parsed = _parseTrackListJson(raw);
    if (parsed.isNotEmpty || _queue.any((t) => t.filePath != null)) {
      return parsed;
    }
    return _delegate.searchLibrary(q);
  }

  @override
  Future<void> play({TrackInfo? track}) async {
    _currentLyrics = const [];
    if (!isNativeBound) {
      return _delegate.play(track: track);
    }
    final target = track ?? _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
    if (target == null) return;

    final idx = _queue.indexWhere((t) => t.id == target.id);
    if (idx >= 0) {
      _currentIndex = idx;
    }

    final payload = jsonEncode({
      'id': target.id,
      'title': target.title,
      'artist': target.artist,
      'album': target.album,
      if (target.duration.inMilliseconds > 0)
        'duration_ms': target.duration.inMilliseconds,
      'codec': target.format.codec.name,
      'sample_rate_hz': target.format.sampleRateHz,
      'bit_depth': target.format.bitDepth,
      'channels': target.format.channels,
      'is_dsd': target.format.isDsd,
      if (target.filePath != null && target.filePath!.isNotEmpty)
        'file_path': target.filePath,
      'source': target.providerName,
    });
    final resumePos = track == null ? _pendingResumePosition : null;
    _pendingResumePosition = null;
    final rc = _withNativeUtf8(payload, (p) => _playFn!(p));
    if (rc != 0) {
      final errMsg = _lastErrorMsgFn != null
          ? _takeRustString(_lastErrorMsgFn!())
          : null;
      _lastError = (errMsg != null && errMsg.isNotEmpty)
          ? errMsg
          : 'Playback failed (code $rc)';
      _positionTimer?.cancel();
      _emitState(
        _state.copyWith(
          status: PlaybackStatus.stopped,
          track: target,
          position: Duration.zero,
        ),
      );
      return;
    }

    if (resumePos != null && resumePos > Duration.zero) {
      _seekFn!(resumePos.inMilliseconds);
    }

    _lastError = null;
    final durMs = _getDurationFn!();
    final syncedTrack = durMs > 0
        ? TrackInfo(
            id: target.id,
            title: target.title,
            artist: target.artist,
            album: target.album,
            duration: Duration(milliseconds: durMs),
            albumArtUrl: target.albumArtUrl,
            format: target.format,
            providerName: target.providerName,
            filePath: target.filePath,
          )
        : target;

    _emitState(
      _state.copyWith(
        status: PlaybackStatus.playing,
        track: syncedTrack,
        position: Duration(milliseconds: _getPositionFn!()),
      ),
    );
    _refreshSignalPath();
    _loadLyricsForTrack(syncedTrack);
    _startPositionTimer();
  }

  @override
  Future<void> pause() async {
    _positionTimer?.cancel();
    if (!isNativeBound) {
      return _delegate.pause();
    }
    _pauseFn!();
    _emitState(_state.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> resume() async {
    if (!isNativeBound) {
      return _delegate.resume();
    }
    if (_playbackResumeFn != null) {
      _playbackResumeFn!();
    } else {
      _playFn!(ffi.nullptr);
    }
    _emitState(_state.copyWith(status: PlaybackStatus.playing));
    _startPositionTimer();
  }

  @override
  Future<void> togglePlayPause() async {
    if (currentState.status == PlaybackStatus.playing) {
      await pause();
    } else if (currentState.status == PlaybackStatus.paused) {
      await resume();
    } else {
      await play();
    }
  }

  @override
  Future<void> reconnectDevice() async {
    if (!isNativeBound) {
      return _delegate.reconnectDevice();
    }
    if (_playbackReconnectDeviceFn != null) {
      _playbackReconnectDeviceFn!();
    }
    _emitState(_state.copyWith(deviceLost: false));
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    if (!isNativeBound) {
      return _delegate.getPlaybackState();
    }
    if (_playbackGetStateJsonFn != null) {
      final raw = _takeRustString(_playbackGetStateJsonFn!());
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return {
      'state_code': _state.status.code,
      'state_name': _state.status.name,
      'position_ms': _state.position.inMilliseconds,
      'duration_ms': _state.track?.duration.inMilliseconds ?? 0,
      'clock_source': _state.clockSource,
      'seek_epoch': _state.seekEpoch,
      'is_seeking': _state.isSeeking,
      'dsp_bypassed': _signalPath.dspBypassed,
      'strict_bit_perfect': _strictBitPerfect,
      'volume': _state.volume,
      'last_error': _state.lastError,
      'device_lost': _state.deviceLost,
      'current_track_id': _state.track?.id,
    };
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    if (!isNativeBound) {
      return _delegate.getArtwork(trackId, path: path, maxDim: maxDim);
    }
    if (_artworkGetFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final ptr = _withNativeUtf8(
        targetPayload,
        (p) => _artworkGetFn!(p, maxDim),
      );
      final raw = _takeRustString(ptr);
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return _delegate.getArtwork(trackId, path: path, maxDim: maxDim);
  }

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    if (!isNativeBound) {
      return _delegate.setUserCover(trackId, imagePath, path: path);
    }
    if (_artworkSetUserCoverFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = _withNativeUtf8(
        targetPayload,
        (pTarget) => _withNativeUtf8(
          imagePath,
          (pImage) => _artworkSetUserCoverFn!(pTarget, pImage),
        ),
      );
      return rc == 0;
    }
    return _delegate.setUserCover(trackId, imagePath, path: path);
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    if (!isNativeBound) {
      return _delegate.clearUserCover(trackId, path: path);
    }
    if (_artworkClearUserCoverFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = _withNativeUtf8(
        targetPayload,
        (pTarget) => _artworkClearUserCoverFn!(pTarget),
      );
      return rc == 0;
    }
    return _delegate.clearUserCover(trackId, path: path);
  }

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) async {
    if (!isNativeBound) {
      return _delegate.rescanTags(directory: directory, force: force);
    }
    if (_libraryRescanTagsFn != null) {
      final dirStr = directory ?? '';
      final ptr = dirStr.isNotEmpty
          ? _withNativeUtf8(dirStr, (p) => _libraryRescanTagsFn!(p, force ? 1 : 0))
          : _libraryRescanTagsFn!(ffi.nullptr, force ? 1 : 0);
      final raw = _takeRustString(ptr);
      _reloadTracksFromNative();
      _emitState(_state);
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return _delegate.rescanTags(directory: directory, force: force);
  }

  @override
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  }) async {
    if (!isNativeBound) {
      return _delegate.getLyrics(trackId, path: path);
    }
    if (_lyricsGetFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final ptr = _withNativeUtf8(targetPayload, (p) => _lyricsGetFn!(p));
      final raw = _takeRustString(ptr);
      if (raw != null) {
        try {
          return jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    return _delegate.getLyrics(trackId, path: path);
  }

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) async {
    if (!isNativeBound) {
      return _delegate.setUserLyrics(trackId, filePath, path: path);
    }
    if (_lyricsSetUserFileFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = _withNativeUtf8(
        targetPayload,
        (pTarget) => _withNativeUtf8(
          filePath,
          (pFile) => _lyricsSetUserFileFn!(pTarget, pFile),
        ),
      );
      if (rc == 0 && _state.track?.id == trackId) {
        _loadLyricsForTrack(_state.track!);
      }
      return rc == 0;
    }
    return _delegate.setUserLyrics(trackId, filePath, path: path);
  }

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) async {
    if (!isNativeBound) {
      return _delegate.clearUserLyrics(trackId, path: path);
    }
    if (_lyricsClearUserFileFn != null) {
      final targetPayload = jsonEncode({
        'track_id': trackId,
        'file_path': ?path,
      });
      final rc = _withNativeUtf8(
        targetPayload,
        (pTarget) => _lyricsClearUserFileFn!(pTarget),
      );
      if (rc == 0 && _state.track?.id == trackId) {
        _currentLyrics = const [];
      }
      return rc == 0;
    }
    return _delegate.clearUserLyrics(trackId, path: path);
  }

  @override
  Future<void> stop() async {
    _positionTimer?.cancel();
    _pendingResumePosition = null;
    if (!isNativeBound) {
      return _delegate.stop();
    }
    _stopFn!();
    _emitState(
      _state.copyWith(status: PlaybackStatus.stopped, position: Duration.zero),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    if (!isNativeBound) {
      return _delegate.seek(position);
    }
    final ms = position.inMilliseconds.clamp(0, 1 << 30);
    _seekFn!(ms);
    _emitState(_state.copyWith(position: Duration(milliseconds: ms)));
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!isNativeBound) {
      return _delegate.setVolume(volume);
    }
    final clamped = volume.clamp(0.0, 1.0);
    _savedNormalVolume = clamped;
    if (_strictBitPerfect) {
      _setVolumeFn!(1.0);
      _emitState(_state.copyWith(volume: 1.0, isMuted: false));
      return;
    }
    _setVolumeFn!(clamped);
    _emitState(_state.copyWith(volume: clamped, isMuted: clamped == 0.0));
  }

  @override
  Future<void> toggleMute() async {
    if (!isNativeBound) {
      return _delegate.toggleMute();
    }
    if (_strictBitPerfect) {
      return;
    }
    final nextMuted = !_state.isMuted;
    _setVolumeFn!(nextMuted ? 0.0 : _state.volume);
    _emitState(_state.copyWith(isMuted: nextMuted));
  }

  @override
  Future<void> next() async {
    if (!isNativeBound) {
      return _delegate.next();
    }
    if (_queue.isEmpty) return;
    _currentIndex = (_currentIndex + 1) % _queue.length;
    await play(track: _queue[_currentIndex]);
  }

  @override
  Future<void> previous() async {
    if (!isNativeBound) {
      return _delegate.previous();
    }
    if (_queue.isEmpty) return;
    _currentIndex = (_currentIndex - 1 + _queue.length) % _queue.length;
    await play(track: _queue[_currentIndex]);
  }

  @override
  Future<void> toggleDspBypass() async {
    if (!isNativeBound) {
      return _delegate.toggleDspBypass();
    }
    _toggleBypassFn!();
    _refreshSignalPath();
  }

  @override
  void setSimulatedQuality(SignalQuality quality) {
    if (!isNativeBound) {
      _delegate.setSimulatedQuality(quality);
      return;
    }
    final nextSignalPath = SignalPath(
      overallQuality: quality,
      description: quality.description,
      nodes: _signalPath.nodes,
      dspBypassed: quality == SignalQuality.lossless,
    );
    _signalPath = nextSignalPath;
    if (!_signalPathController.isClosed) {
      _signalPathController.add(_signalPath);
    }
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getAlbums(limit: limit);
    }
    if (!isNativeBound || _getAlbumsFn == null) {
      return _delegate.getAlbums(limit: limit);
    }
    final raw = _takeRustString(_getAlbumsFn!(limit));
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(CanonicalAlbumSummary.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getAlbumDetail(albumId);
    }
    if (!isNativeBound || _getAlbumDetailFn == null) {
      return _delegate.getAlbumDetail(albumId);
    }
    final raw = _withNativeUtf8(
      albumId,
      (p) => _takeRustString(_getAlbumDetailFn!(p)),
    );
    if (raw == null || raw == 'null') return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return CanonicalAlbumDetail.fromJson(decoded);
    }
    return null;
  }

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getArtistDetail(artistId);
    }
    if (!isNativeBound || _getArtistDetailFn == null) {
      return _delegate.getArtistDetail(artistId);
    }
    final raw = _withNativeUtf8(
      artistId,
      (p) => _takeRustString(_getArtistDetailFn!(p)),
    );
    if (raw == null || raw == 'null') return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return ArtistDetailInfo.fromJson(decoded);
    }
    return null;
  }

  @override
  Future<int> deduplicateLibrary() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.deduplicateLibrary();
    }
    if (!isNativeBound || _deduplicateFn == null) {
      return _delegate.deduplicateLibrary();
    }
    final raw = _takeRustString(_deduplicateFn!());
    if (raw == null) return 0;
    final decoded = jsonDecode(raw);
    return (decoded is Map ? (decoded['merged_albums'] as num?)?.toInt() : null) ?? 0;
  }

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.enrichLibraryCredits(
        musicBrainzBaseUrl: musicBrainzBaseUrl,
        discogsBaseUrl: discogsBaseUrl,
      );
    }
    if (!isNativeBound || _enrichCreditsFn == null) {
      return _delegate.enrichLibraryCredits(
        musicBrainzBaseUrl: musicBrainzBaseUrl,
        discogsBaseUrl: discogsBaseUrl,
      );
    }
    final payload = jsonEncode({
      'musicbrainz_base_url': ?musicBrainzBaseUrl,
      'discogs_base_url': ?discogsBaseUrl,
    });
    final raw = _withNativeUtf8(
      payload,
      (p) => _takeRustString(_enrichCreditsFn!(p)),
    );
    if (raw == null) return const {};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  Future<DspPipelineConfigModel> getDspConfig() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getDspConfig();
    }
    if (!isNativeBound || _dspGetConfigFn == null) {
      return _delegate.getDspConfig();
    }
    final raw = _takeRustString(_dspGetConfigFn!());
    if (raw == null) return const DspPipelineConfigModel();
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return DspPipelineConfigModel.fromJson(decoded);
    }
    return const DspPipelineConfigModel();
  }

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.setDspConfig(config);
      return;
    }
    if (!isNativeBound || _dspSetConfigFn == null) {
      await _delegate.setDspConfig(config);
      return;
    }
    _withNativeUtf8(jsonEncode(config.toJson()), (p) => _dspSetConfigFn!(p));
    _refreshSignalPath();
  }

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.importAutoEqProfile(autoEqTxt);
    }
    if (!isNativeBound || _dspImportAutoeqFn == null) {
      return _delegate.importAutoEqProfile(autoEqTxt);
    }
    final raw = _withNativeUtf8(
      autoEqTxt,
      (p) => _takeRustString(_dspImportAutoeqFn!(p)),
    );
    _refreshSignalPath();
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PeqBandModel.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listAudioDevices();
    }
    if (!isNativeBound || _audioListDevicesFn == null) {
      return _delegate.listAudioDevices();
    }
    final raw = _takeRustString(_audioListDevicesFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final devs = decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioDeviceInfo.fromJson)
          .toList();
      _tracker.syncActiveFromDevices(devs);
      return devs;
    }
    return const [];
  }

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.setDeviceVolume(deviceId, volume);
      return;
    }
    if (!isNativeBound) {
      await _delegate.setDeviceVolume(deviceId, volume);
      return;
    }
    if (deviceId == activeDeviceId) {
      await setVolume(volume);
      return;
    }
    _tracker.setDeviceVolume(deviceId, volume);
  }

  @override
  Future<void> toggleDevicePlayPause(String deviceId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.toggleDevicePlayPause(deviceId);
      return;
    }
    if (!isNativeBound) {
      await _delegate.toggleDevicePlayPause(deviceId);
      return;
    }
    if (deviceId == activeDeviceId) {
      await togglePlayPause();
      return;
    }
    await selectAudioDevice(deviceId);
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else {
      final track = _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
      if (track != null) {
        await play(track: track);
      }
    }
  }

  @override
  Future<void> toggleZonePlayPause(String zoneId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.toggleZonePlayPause(zoneId);
      return;
    }
    if (!isNativeBound) {
      await _delegate.toggleZonePlayPause(zoneId);
      return;
    }
    final zones = await listZones();
    final z = zones.where((item) => item.id == zoneId).firstOrNull;
    final isPlaying = zonePlaybackStates[zoneId]?.status == PlaybackStatus.playing;
    if (z == null || !z.backend.startsWith('network_')) {
      await togglePlayPause();
      _tracker.updateZoneAction(
        zoneId,
        _state.status == PlaybackStatus.playing ? 'play' : 'pause',
        track: _state.track,
      );
      return;
    }
    await castToZone(zoneId, isPlaying ? 'pause' : 'play');
  }

  @override
  Future<void> selectAudioDevice(String? deviceId, {int backendIndex = -1}) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.selectAudioDevice(deviceId, backendIndex: backendIndex);
      return;
    }
    if (!isNativeBound || _audioSelectDeviceFn == null) {
      await _delegate.selectAudioDevice(deviceId, backendIndex: backendIndex);
      return;
    }

    final trimmed = deviceId?.trim();
    final selectingSystem =
        trimmed == null || trimmed.isEmpty || trimmed == AudioService.systemOutputId;
    final nativeId = selectingSystem ? '' : trimmed;

    _isReroutingDevice = true;
    try {
      final rc = _withNativeUtf8(
        nativeId,
        (p) => _audioSelectDeviceFn!(p, backendIndex),
      );
      if (rc != 0) {
        final errMsg = _lastErrorMsgFn != null
            ? _takeRustString(_lastErrorMsgFn!())
            : null;
        _lastError = (errMsg != null && errMsg.isNotEmpty)
            ? errMsg
            : 'Failed to select audio device (code $rc)';
        final rustState = _getStateFn?.call();
        if (rustState == 4) {
          _positionTimer?.cancel();
          _emitState(
            _state.copyWith(
              status: PlaybackStatus.error,
              lastError: _lastError,
            ),
          );
        }
      } else {
        _lastError = null;
        final prevStrict = _strictBitPerfect;
        final isSharedSelection =
            backendIndex == 2 || nativeId.startsWith('wasapi-shared::');
        if (isSharedSelection && _strictBitPerfect) {
          // Rust select_output_device already cleared strict_bit_perfect and restored
          // normal DSP/volume in a single RerouteOutput; sync Dart state without re-triggering.
          _strictBitPerfect = false;
        }
        final rustSnap = await getPlaybackState();
        final rustStrict = rustSnap?['strict_bit_perfect'] == true;
        final rustVol = (rustSnap?['volume'] as num?)?.toDouble();
        _strictBitPerfect = isSharedSelection ? false : rustStrict;

        if (selectingSystem) {
          _systemOutputActive = true;
          final devs = await listAudioDevices();
          final osDef =
              devs.where((d) => d.isDefault).firstOrNull ?? devs.firstOrNull;
          if (osDef != null) {
            _tracker.switchDevice(
              nextDeviceId: osDef.id,
              currentState: _state,
              currentQueueIndex: _currentIndex,
            );
            _tracker.updateActiveDeviceState(_state, queueIndex: _currentIndex);
          }
        } else {
          _systemOutputActive = false;
          if (_state.track == null) {
            final res = _tracker.switchDevice(
              nextDeviceId: nativeId,
              currentState: _state,
              currentQueueIndex: _currentIndex,
            );
            if (res.switched) {
              _currentIndex = res.queueIndex.clamp(
                0,
                _queue.isEmpty ? 0 : _queue.length - 1,
              );
              _pendingResumePosition = res.restoredState.position > Duration.zero
                  ? res.restoredState.position
                  : null;
              final effVol = (prevStrict && !_strictBitPerfect && rustVol != null)
                  ? rustVol
                  : res.restoredState.volume;
              _setVolumeFn?.call(
                res.restoredState.isMuted ? 0.0 : effVol,
              );
              _emitState(
                res.restoredState.copyWith(
                  volume: effVol,
                  isMuted: effVol == 0.0,
                ),
              );
            } else if (prevStrict && !_strictBitPerfect && rustVol != null) {
              _emitState(_state.copyWith(volume: rustVol, isMuted: rustVol == 0.0));
            }
          } else {
            // Mid-playback reroute: Rust RerouteOutput kept the active track playing/paused
            // on the newly initialized backend. Keep UI synchronized with Rust engine state.
            _tracker.switchDevice(
              nextDeviceId: nativeId,
              currentState: _state,
              currentQueueIndex: _currentIndex,
            );
            final rustCode = _getStateFn?.call() ?? _state.status.code;
            final posMs = _getPositionFn?.call() ?? _state.position.inMilliseconds;
            final syncedStatus = PlaybackStatus.fromCode(rustCode);
            final effVol = rustVol ?? _state.volume;
            _emitState(
              _state.copyWith(
                status: syncedStatus,
                position: Duration(milliseconds: posMs),
                volume: effVol,
                isMuted: effVol == 0.0,
                deviceLost: false,
                lastError: null,
              ),
            );
            if (syncedStatus == PlaybackStatus.playing) {
              _startPositionTimer();
            } else {
              _positionTimer?.cancel();
            }
          }
        }
        _refreshSignalPath();
      }
    } finally {
      _isReroutingDevice = false;
    }
  }

  @override
  Future<List<AudioZoneInfo>> listZones() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listZones();
    }
    if (!isNativeBound || _zoneListFn == null) {
      return _delegate.listZones();
    }
    final raw = _takeRustString(_zoneListFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final zones = decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioZoneInfo.fromJson)
          .toList();
      _tracker.syncZones(zones, activeLocalState: _state);
      return zones;
    }
    return const [];
  }

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.discoverZones(
        ssdpAddr: ssdpAddr,
        airplayAddrs: airplayAddrs,
        clockSyncAddr: clockSyncAddr,
      );
    }
    if (!isNativeBound || _zoneDiscoverFn == null) {
      return _delegate.discoverZones(
        ssdpAddr: ssdpAddr,
        airplayAddrs: airplayAddrs,
        clockSyncAddr: clockSyncAddr,
      );
    }
    final raw = _takeRustString(_zoneDiscoverFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final zones = decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioZoneInfo.fromJson)
          .toList();
      _tracker.syncZones(zones, activeLocalState: _state);
      return zones;
    }
    return const [];
  }

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.groupZones(groupId, zoneIds);
      return;
    }
    if (!isNativeBound || _zoneGroupFn == null) {
      await _delegate.groupZones(groupId, zoneIds);
      return;
    }
    _withNativeUtf8(
      jsonEncode({'group_id': groupId, 'zone_ids': zoneIds}),
      (p) => _zoneGroupFn!(p),
    );
  }

  @override
  Future<void> setZoneVolume(String zoneId, double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.setZoneVolume(zoneId, clamped);
      return;
    }
    if (!isNativeBound || _zoneSetVolumeFn == null) {
      await _delegate.setZoneVolume(zoneId, clamped);
      return;
    }
    _withNativeUtf8(zoneId, (p) => _zoneSetVolumeFn!(p, clamped));
    _tracker.setZoneVolume(zoneId, clamped);
    if (zoneId == 'zone-local') {
      await setVolume(clamped);
    }
  }

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.syncZoneClock(zoneId, clockAddr: clockAddr);
    }
    if (!isNativeBound || _zoneSyncStatusFn == null) {
      return _delegate.syncZoneClock(zoneId, clockAddr: clockAddr);
    }
    final input = clockAddr == null
        ? zoneId
        : jsonEncode({'zone_id': zoneId, 'clock_addr': clockAddr});
    final raw = _withNativeUtf8(
      input,
      (p) => _takeRustString(_zoneSyncStatusFn!(p)),
    );
    if (raw == null) {
      return ClockSyncMeasurementModel(
        zoneId: zoneId,
        offsetUs: 0,
        rttUs: 0,
        driftPpm: 0.0,
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return ClockSyncMeasurementModel.fromJson(zoneId, decoded);
    }
    return ClockSyncMeasurementModel(
      zoneId: zoneId,
      offsetUs: 0,
      rttUs: 0,
      driftPpm: 0.0,
    );
  }

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.castToZone(zoneId, action, mediaUri: mediaUri);
    }
    _tracker.updateZoneAction(
      zoneId,
      action,
      track: _state.track ?? (_queue.isNotEmpty ? _queue.first : null),
    );
    return _delegate.castToZone(zoneId, action, mediaUri: mediaUri);
  }

  @override
  Future<List<ProviderStatusInfo>> listProviders() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listProviders();
    }
    return _delegate.listProviders();
  }

  @override
  Future<bool> configureProvider(String kind, Map<String, dynamic> config) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.configureProvider(kind, config);
    }
    if (kind == 'apple_music' ||
        kind == 'youtube_music' ||
        config['disconnect'] == true ||
        !isNativeBound ||
        _providerConfigureFn == null) {
      return _delegate.configureProvider(kind, config);
    }
    final rc = _withNativeUtf8(
      kind,
      (kp) => _withNativeUtf8(
        jsonEncode(config),
        (cp) => _providerConfigureFn!(kp, cp),
      ),
    );
    await _delegate.configureProvider(kind, config);
    return rc == 0;
  }

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.startTidalPkce();
    }
    if (!isNativeBound || _tidalPkceStartFn == null) {
      return _delegate.startTidalPkce();
    }
    final raw = _takeRustString(_tidalPkceStartFn!());
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return TidalPkceStartInfo.fromJson(decoded);
    }
    return null;
  }

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.completeTidalPkce(code, codeVerifier);
    }
    if (!isNativeBound || _tidalPkceCompleteFn == null) {
      return _delegate.completeTidalPkce(code, codeVerifier);
    }
    final raw = _withNativeUtf8(
      jsonEncode({'code': code, 'code_verifier': codeVerifier}),
      (p) => _takeRustString(_tidalPkceCompleteFn!(p)),
    );
    return raw != null;
  }

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.syncProvider(kind);
    }
    if (kind == 'apple_music' ||
        kind == 'youtube_music' ||
        !isNativeBound ||
        _providerSyncFn == null) {
      final res = await _delegate.syncProvider(kind);
      for (final t in _delegate.queue) {
        if (!_queue.any((q) => q.id == t.id)) {
          _queue.add(t);
        }
      }
      return res;
    }
    final raw = _withNativeUtf8(
      kind,
      (p) => _takeRustString(_providerSyncFn!(p)),
    );
    _reloadTracksFromNative();
    if (raw == null) return const {};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const {};
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.listProfiles();
    }
    if (!isNativeBound || _profileListFn == null) {
      return _delegate.listProfiles();
    }
    final raw = _takeRustString(_profileListFn!());
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final list = decoded
          .whereType<Map<String, dynamic>>()
          .map(UserProfileInfo.fromJson)
          .toList();
      if (list.isEmpty) {
        await createProfile('預設聆聽者');
        return listProfiles();
      }
      return list;
    }
    return const [];
  }

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.createProfile(name, avatarColor: avatarColor);
    }
    if (!isNativeBound || _profileCreateFn == null) {
      return _delegate.createProfile(name, avatarColor: avatarColor);
    }
    final raw = _withNativeUtf8(
      jsonEncode({'name': name, 'avatar_color': avatarColor}),
      (p) => _takeRustString(_profileCreateFn!(p)),
    );
    if (raw != null) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return UserProfileInfo.fromJson(decoded);
      }
    }
    return UserProfileInfo(id: 'local', name: name, avatarColor: avatarColor);
  }

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.updateProfile(
        profileId,
        name: name,
        avatarColor: avatarColor,
        isDefault: isDefault,
      );
    }
    if (!isNativeBound || _profileUpdateFn == null) {
      return _delegate.updateProfile(
        profileId,
        name: name,
        avatarColor: avatarColor,
        isDefault: isDefault,
      );
    }
    final rc = _withNativeUtf8(
      profileId,
      (idp) => _withNativeUtf8(
        jsonEncode({
          'name': ?name,
          'avatar_color': ?avatarColor,
          'is_default': ?isDefault,
        }),
        (jp) => _profileUpdateFn!(idp, jp),
      ),
    );
    return rc == 0;
  }

  @override
  Future<void> switchProfile(String profileId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      await _remoteClient!.switchProfile(profileId);
      return;
    }
    if (!isNativeBound || _profileSwitchFn == null) {
      await _delegate.switchProfile(profileId);
      return;
    }
    _withNativeUtf8(profileId, (p) => _profileSwitchFn!(p));
  }

  @override
  Future<bool> deleteProfile(String profileId) async {
    if (_remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.deleteProfile(profileId);
    }
    if (!isNativeBound || _profileDeleteFn == null) {
      return _delegate.deleteProfile(profileId);
    }
    return _withNativeUtf8(profileId, (p) => _profileDeleteFn!(p)) == 0;
  }

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() async {
    if (!isNativeBound || _serverStartFn == null || _serverGetPortFn == null) {
      return _delegate.initiateHostPairing();
    }
    var port = _serverGetPortFn!();
    if (port == 0) {
      _serverStartFn!(0, 1);
      port = _serverGetPortFn!();
    }
    if (port > 0) {
      final svc = ServerAudioService(baseUrl: 'http://127.0.0.1:$port');
      return svc.initiateHostPairing();
    }
    return _delegate.initiateHostPairing();
  }

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) {
    return MdnsDiscoveryClient.discover(
      targetHost: multicastHost,
      port: port,
      timeout: timeout,
    );
  }

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) async {
    _remoteClient?.dispose();
    final remote = ServerAudioService(
      baseUrl: baseUrl,
      allowSelfSignedTls: allowSelfSignedTls,
      mode: baseUrl.startsWith('https://')
          ? ConnectionMode.wanRemote
          : ConnectionMode.lanRemote,
    );
    final tok = await remote.pairAndConnectRemote(
      baseUrl: baseUrl,
      pin: pin,
      deviceName: deviceName,
      allowSelfSignedTls: allowSelfSignedTls,
    );
    if (tok != null) {
      _remoteClient = remote;
      _connectionMode = remote.connectionMode;
    } else {
      remote.dispose();
    }
    return tok;
  }

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) async {
    _remoteClient?.dispose();
    final remote = ServerAudioService(
      baseUrl: httpsBaseUrl,
      bearerToken: bearerToken,
      allowSelfSignedTls: allowSelfSignedTls,
      mode: ConnectionMode.wanRemote,
    );
    final ok = await remote.connectWanDirect(
      httpsBaseUrl: httpsBaseUrl,
      bearerToken: bearerToken,
      pin: pin,
      allowSelfSignedTls: allowSelfSignedTls,
    );
    if (ok) {
      _remoteClient = remote;
      _connectionMode = ConnectionMode.wanRemote;
    } else {
      remote.dispose();
    }
    return ok;
  }

  @override
  bool get isStrictBitPerfect =>
      !isNativeBound ? _delegate.isStrictBitPerfect : _strictBitPerfect;

  @override
  DsdOutputModeOption get dsdOutputMode =>
      !isNativeBound ? _delegate.dsdOutputMode : _dsdOutputMode;

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async {
    if (!isNativeBound || _audioGetOutputInfoFn == null) {
      return _delegate.getOutputInfo();
    }
    final raw = _takeRustString(_audioGetOutputInfoFn!());
    if (raw == null || raw.isEmpty) {
      return const AudioEngineOutputInfoModel();
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final info = AudioEngineOutputInfoModel.fromJson(decoded);
      if (info.output.bufferSizeFrames > 0) {
        _preferredBufferFrames = info.output.bufferSizeFrames;
      }
      return info;
    }
    return const AudioEngineOutputInfoModel();
  }

  @override
  Future<bool> setBufferFrames(int frames) async {
    if (!isNativeBound || _audioSetBufferFramesFn == null) {
      return _delegate.setBufferFrames(frames);
    }
    final rc = _audioSetBufferFramesFn!(frames);
    if (rc != 0) {
      final errMsg =
          _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
      _lastError = errMsg ?? 'Failed to set buffer frames (code $rc)';
      return false;
    }
    _lastError = null;
    _preferredBufferFrames = frames;
    _refreshSignalPath();
    return true;
  }

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async {
    if (!isNativeBound || _audioListDeviceCapsFn == null) {
      return _delegate.listDeviceCapabilities();
    }
    final raw = _takeRustString(_audioListDeviceCapsFn!());
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AudioDeviceCapabilitiesModel.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<void> setStrictBitPerfect(bool enabled) async {
    if (!isNativeBound || _audioSetStrictModeFn == null) {
      await _delegate.setStrictBitPerfect(enabled);
      return;
    }
    if (!_strictBitPerfect && enabled) {
      _savedNormalVolume = _state.volume;
    }
    final rc = _audioSetStrictModeFn!(enabled ? 1 : 0);
    if (rc != 0) {
      final errMsg = _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
      _lastError = errMsg ?? 'Strict Mode switch failed (code $rc)';
    } else {
      _lastError = null;
      _strictBitPerfect = enabled;
      if (enabled) {
        _emitState(_state.copyWith(volume: 1.0, isMuted: false));
      } else {
        _emitState(
          _state.copyWith(
            volume: _savedNormalVolume,
            isMuted: _savedNormalVolume == 0.0,
          ),
        );
      }
      _refreshSignalPath();
    }
  }

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) async {
    if (!isNativeBound || _audioSetDsdModeFn == null) {
      await _delegate.setDsdOutputMode(mode);
      return;
    }
    final rc = _audioSetDsdModeFn!(mode.ffiCode);
    if (rc != 0) {
      final errMsg = _lastErrorMsgFn != null ? _takeRustString(_lastErrorMsgFn!()) : null;
      _lastError = errMsg ?? 'DSD mode switch failed (code $rc)';
    } else {
      _lastError = null;
      _dsdOutputMode = mode;
      _refreshSignalPath();
    }
  }

  @override
  Future<void> switchToLocalMode() async {
    await _remoteClient?.switchToLocalMode();
    _remoteClient?.dispose();
    _remoteClient = null;
    _connectionMode = ConnectionMode.localOrUsbDac;
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _remoteClient?.dispose();
    if (isNativeBound) {
      _shutdownFn?.call();
    }
    _stateController.close();
    _signalPathController.close();
    _positionController.close();
    _delegate.dispose();
  }
}


