part of '../ffi_audio_service.dart';

typedef _TrackActBytesAllocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _TrackActBytesAllocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _TrackActBytesFreeNative =
    ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _TrackActBytesFreeDart = void Function(ffi.Pointer<ffi.Uint8>, int);
typedef _TrackActStringFreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _TrackActStringFreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _TrackActStrPtrNative =
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>);
typedef _TrackActStrPtrDart =
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>);
typedef _TrackActStrStrPtrNative =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
    );
typedef _TrackActStrStrPtrDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
    );
typedef _TrackActStrI32PtrNative =
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _TrackActStrI32PtrDart =
    ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Uint8>, int);
typedef _TrackActU32I32PtrNative =
    ffi.Pointer<ffi.Uint8> Function(ffi.Uint32, ffi.Int32);
typedef _TrackActU32I32PtrDart =
    ffi.Pointer<ffi.Uint8> Function(int, int);

T _trackActWithUtf8<T>(
  ffi.DynamicLibrary dylib,
  String value,
  T Function(ffi.Pointer<ffi.Uint8>) fn,
) {
  final alloc = dylib
      .lookupFunction<_TrackActBytesAllocNative, _TrackActBytesAllocDart>(
        'lumina_bytes_alloc',
      );
  final freeBytes = dylib
      .lookupFunction<_TrackActBytesFreeNative, _TrackActBytesFreeDart>(
        'lumina_bytes_free',
      );
  final encoded = utf8.encode(value);
  final ptr = alloc(encoded.length);
  try {
    final view = ptr.asTypedList(encoded.length + 1);
    view.setAll(0, encoded);
    view[encoded.length] = 0;
    return fn(ptr);
  } finally {
    freeBytes(ptr, encoded.length);
  }
}

String? _trackActTakeString(
  ffi.DynamicLibrary dylib,
  ffi.Pointer<ffi.Uint8> ptr,
) {
  if (ptr == ffi.nullptr) return null;
  final strFree = dylib
      .lookupFunction<_TrackActStringFreeNative, _TrackActStringFreeDart>(
        'lumina_string_free',
      );
  try {
    var len = 0;
    while (ptr[len] != 0) {
      len++;
    }
    if (len == 0) return '';
    return utf8.decode(ptr.asTypedList(len));
  } finally {
    strFree(ptr);
  }
}

_TrackActStrPtrDart _lookupTrackStrPtr(
  ffi.DynamicLibrary dylib,
  String op,
) => switch (op) {
  'file_info' => dylib.lookupFunction<_TrackActStrPtrNative, _TrackActStrPtrDart>(
    'lumina_library_get_track_file_info',
  ),
  'rescan' => dylib.lookupFunction<_TrackActStrPtrNative, _TrackActStrPtrDart>(
    'lumina_library_rescan_track',
  ),
  _ => dylib.lookupFunction<_TrackActStrPtrNative, _TrackActStrPtrDart>(
    'lumina_library_reanalyze_track',
  ),
};

_TrackActStrStrPtrDart _lookupTrackStrStrPtr(
  ffi.DynamicLibrary dylib,
  String op,
) => switch (op) {
  'reidentify' =>
    dylib.lookupFunction<_TrackActStrStrPtrNative, _TrackActStrStrPtrDart>(
      'lumina_library_reidentify_track',
    ),
  _ => dylib.lookupFunction<_TrackActStrStrPtrNative, _TrackActStrStrPtrDart>(
    'lumina_library_delete_track',
  ),
};

_TrackActStrI32PtrDart _lookupTrackStrI32Ptr(
  ffi.DynamicLibrary dylib,
  String op,
) => switch (op) {
  'set_hidden' =>
    dylib.lookupFunction<_TrackActStrI32PtrNative, _TrackActStrI32PtrDart>(
      'lumina_library_set_track_hidden',
    ),
  _ => dylib.lookupFunction<_TrackActStrI32PtrNative, _TrackActStrI32PtrDart>(
    'lumina_library_get_album_detail_filtered',
  ),
};

String? _trackActInvokeStr(String dylibPath, String op, String arg0) {
  final dylib = ffi.DynamicLibrary.open(dylibPath);
  final fn = _lookupTrackStrPtr(dylib, op);
  return _trackActWithUtf8(
    dylib,
    arg0,
    (p0) => _trackActTakeString(dylib, fn(p0)),
  );
}

String? _trackActInvokeStrStr(
  String dylibPath,
  String op,
  String arg0,
  String arg1,
) {
  final dylib = ffi.DynamicLibrary.open(dylibPath);
  final fn = _lookupTrackStrStrPtr(dylib, op);
  return _trackActWithUtf8(
    dylib,
    arg0,
    (p0) => _trackActWithUtf8(
      dylib,
      arg1,
      (p1) => _trackActTakeString(dylib, fn(p0, p1)),
    ),
  );
}

String? _trackActInvokeStrBool(
  String dylibPath,
  String op,
  String arg0,
  bool flag,
) {
  final dylib = ffi.DynamicLibrary.open(dylibPath);
  final fn = _lookupTrackStrI32Ptr(dylib, op);
  return _trackActWithUtf8(
    dylib,
    arg0,
    (p0) => _trackActTakeString(dylib, fn(p0, flag ? 1 : 0)),
  );
}

String? _trackActInvokeLimitBool(
  String dylibPath,
  int limit,
  bool includeHidden,
) {
  final dylib = ffi.DynamicLibrary.open(dylibPath);
  final fn = dylib
      .lookupFunction<_TrackActU32I32PtrNative, _TrackActU32I32PtrDart>(
        'lumina_library_get_tracks_filtered',
      );
  return _trackActTakeString(dylib, fn(limit, includeHidden ? 1 : 0));
}

mixin _FfiTrackActionsMixin on _FfiAudioServiceBase {
  bool get _useRemoteTrackActions =>
      _remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac;

  Map<String, dynamic>? _decodeTrackActionMap(String? raw) {
    if (_disposed || raw == null || raw.isEmpty || raw == 'null') return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  void _notifyTrackMutation() {
    if (_disposed) return;
    unawaited(_reloadTracksFromNativeAsync());
    if (!_libraryReloadedController.isClosed) {
      _libraryReloadedController.add(null);
    }
  }

  @override
  Future<TrackFileInfo?> getTrackFileInfo(String trackId) async {
    if (_useRemoteTrackActions) return _remoteClient!.getTrackFileInfo(trackId);
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.getTrackFileInfo(trackId);
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStr(dylibPath, 'file_info', trackId),
    );
    final map = _decodeTrackActionMap(raw);
    return map != null ? TrackFileInfo.fromJson(map) : null;
  }

  @override
  Future<TrackVisibilityResult?> setTrackHidden(
    String trackId,
    bool isHidden,
  ) async {
    if (_useRemoteTrackActions) {
      return _remoteClient!.setTrackHidden(trackId, isHidden);
    }
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.setTrackHidden(trackId, isHidden);
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStrBool(dylibPath, 'set_hidden', trackId, isHidden),
    );
    final map = _decodeTrackActionMap(raw);
    if (map == null) return null;
    _notifyTrackMutation();
    return TrackVisibilityResult.fromJson(map);
  }

  @override
  Future<TrackFileInfo?> rescanTrack(String trackId) async {
    if (_useRemoteTrackActions) return _remoteClient!.rescanTrack(trackId);
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.rescanTrack(trackId);
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStr(dylibPath, 'rescan', trackId),
    );
    final map = _decodeTrackActionMap(raw);
    if (map == null) return null;
    _notifyTrackMutation();
    return TrackFileInfo.fromJson(map);
  }

  @override
  Future<ReidentifyTrackResult?> reidentifyTrack(String trackId) async {
    if (_useRemoteTrackActions) return _remoteClient!.reidentifyTrack(trackId);
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.reidentifyTrack(trackId);
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStrStr(dylibPath, 'reidentify', trackId, '{}'),
    );
    final map = _decodeTrackActionMap(raw);
    if (map == null) return null;
    _notifyTrackMutation();
    return ReidentifyTrackResult.fromJson(map);
  }

  @override
  Future<TrackAnalysisResult?> reanalyzeTrack(String trackId) async {
    if (_useRemoteTrackActions) return _remoteClient!.reanalyzeTrack(trackId);
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.reanalyzeTrack(trackId);
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStr(dylibPath, 'reanalyze', trackId),
    );
    final map = _decodeTrackActionMap(raw);
    if (map == null) return null;
    _notifyTrackMutation();
    return TrackAnalysisResult.fromJson(map);
  }

  @override
  Future<DeleteTrackResult?> deleteTrack(
    String trackId, {
    TrackDeleteMode mode = TrackDeleteMode.libraryOnly,
  }) async {
    if (_useRemoteTrackActions) {
      return _remoteClient!.deleteTrack(trackId, mode: mode);
    }
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.deleteTrack(trackId, mode: mode);
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStrStr(
        dylibPath,
        'delete',
        trackId,
        jsonEncode(<String, dynamic>{'mode': mode.toJson()}),
      ),
    );
    final map = _decodeTrackActionMap(raw);
    if (map == null) return null;
    _notifyTrackMutation();
    return DeleteTrackResult.fromJson(map);
  }

  @override
  Future<List<TrackInfo>> getLibraryTracksFiltered({
    int limit = 200,
    bool includeHidden = false,
  }) async {
    if (_useRemoteTrackActions) {
      return _remoteClient!.getLibraryTracksFiltered(
        limit: limit,
        includeHidden: includeHidden,
      );
    }
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.getLibraryTracksFiltered(
        limit: limit,
        includeHidden: includeHidden,
      );
    }
    final effectiveLimit = limit > 0
        ? limit
        : _FfiAudioServiceBase._libraryTracksReloadLimit;
    final raw = await Isolate.run(
      () => _trackActInvokeLimitBool(dylibPath, effectiveLimit, includeHidden),
    );
    if (_disposed) return const <TrackInfo>[];
    return _ffiParseTrackListJson(raw);
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetailFiltered(
    String albumId, {
    bool includeHidden = false,
  }) async {
    if (_useRemoteTrackActions) {
      return _remoteClient!.getAlbumDetailFiltered(
        albumId,
        includeHidden: includeHidden,
      );
    }
    final dylibPath = _dylibPath;
    if (!isNativeBound || dylibPath == null) {
      return _delegate.getAlbumDetailFiltered(
        albumId,
        includeHidden: includeHidden,
      );
    }
    final raw = await Isolate.run(
      () => _trackActInvokeStrBool(
        dylibPath,
        'album_detail_filtered',
        albumId,
        includeHidden,
      ),
    );
    final map = _decodeTrackActionMap(raw);
    if (map == null) return null;
    final detail = CanonicalAlbumDetail.fromJson(map);
    final nonEmptyVersions = detail.versions
        .where((v) => v.tracks.isNotEmpty)
        .toList(growable: false);
    if (nonEmptyVersions.isEmpty) return null;
    if (nonEmptyVersions.length == detail.versions.length) return detail;
    return detail.copyWith(versions: nonEmptyVersions);
  }

  @override
  Future<bool> revealTrackFolder(String filePath) async {
    if (_useRemoteTrackActions) return false;
    if (!isNativeBound) return _delegate.revealTrackFolder(filePath);
    return revealFileInFolder(filePath);
  }
}
