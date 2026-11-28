import 'dart:convert';
import 'dart:ffi' as ffi;

import '../../../models/stream_source_spec.dart';
import 'l1_cache_record.dart';

typedef _L1LoadUnexpiredNative = ffi.Pointer<ffi.Uint8> Function(ffi.Uint64);
typedef _L1LoadUnexpiredDart = ffi.Pointer<ffi.Uint8> Function(int);

typedef _L1UpsertNative = ffi.Int32 Function(ffi.Pointer<ffi.Uint8>);
typedef _L1UpsertDart = int Function(ffi.Pointer<ffi.Uint8>);

typedef _L1DeleteNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);
typedef _L1DeleteDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
);

typedef _BytesAllocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _BytesAllocDart = ffi.Pointer<ffi.Uint8> Function(int);

typedef _BytesFreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _BytesFreeDart = void Function(ffi.Pointer<ffi.Uint8>, int);

typedef _StringFreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _StringFreeDart = void Function(ffi.Pointer<ffi.Uint8>);

/// Pure-Dart in-memory persistence adapter for deterministic unit tests
/// (including cold-restart hydration simulations without SQLite/FFI).
class InMemoryL1StreamCachePersistence implements L1StreamCachePersistence {
  final Map<StreamKey, L1StreamCacheRecord> _rows =
      <StreamKey, L1StreamCacheRecord>{};

  int loadCalls = 0;
  int upsertCalls = 0;
  int deleteCalls = 0;

  Map<StreamKey, L1StreamCacheRecord> get debugRows =>
      Map<StreamKey, L1StreamCacheRecord>.unmodifiable(_rows);

  @override
  Future<List<L1StreamCacheRecord>> loadUnexpired(int nowSec) async {
    loadCalls++;
    _rows.removeWhere((_, rec) => rec.expireAt <= nowSec);
    return _rows.values.toList(growable: false);
  }

  @override
  Future<void> upsert(L1StreamCacheRecord record) async {
    upsertCalls++;
    _rows[record.key] = record;
  }

  @override
  Future<void> delete({
    required String providerId,
    required String trackId,
    String? qualityKey,
  }) async {
    deleteCalls++;
    if (qualityKey != null && qualityKey.isNotEmpty) {
      _rows.remove(StreamKey(providerId, trackId, qualityKey));
    } else {
      _rows.removeWhere(
        (k, _) => k.providerId == providerId && k.trackId == trackId,
      );
    }
  }
}

/// Rust `core-ffi` SQLite WAL persistence adapter reusing `FfiAudioService`'s
/// loaded `core_ffi` library and `EngineState.db_pool`.
class FfiL1StreamCachePersistence implements L1StreamCachePersistence {
  final ffi.DynamicLibrary? Function() _libraryProvider;
  final Future<void> Function()? _waitDbReady;

  ffi.DynamicLibrary? _boundLib;
  _L1LoadUnexpiredDart? _loadFn;
  _L1UpsertDart? _upsertFn;
  _L1DeleteDart? _deleteFn;
  _BytesAllocDart? _bytesAllocFn;
  _BytesFreeDart? _bytesFreeFn;
  _StringFreeDart? _stringFreeFn;

  FfiL1StreamCachePersistence({
    required this._libraryProvider,
    this._waitDbReady,
  });

  bool _ensureBound() {
    final lib = _libraryProvider();
    if (lib == null) return false;
    if (identical(lib, _boundLib) && _loadFn != null) return true;
    try {
      _loadFn = lib.lookupFunction<_L1LoadUnexpiredNative, _L1LoadUnexpiredDart>(
        'lumina_l1_cache_load_unexpired',
      );
      _upsertFn = lib.lookupFunction<_L1UpsertNative, _L1UpsertDart>(
        'lumina_l1_cache_upsert',
      );
      _deleteFn = lib.lookupFunction<_L1DeleteNative, _L1DeleteDart>(
        'lumina_l1_cache_delete',
      );
      _bytesAllocFn = lib.lookupFunction<_BytesAllocNative, _BytesAllocDart>(
        'lumina_bytes_alloc',
      );
      _bytesFreeFn = lib.lookupFunction<_BytesFreeNative, _BytesFreeDart>(
        'lumina_bytes_free',
      );
      _stringFreeFn = lib.lookupFunction<_StringFreeNative, _StringFreeDart>(
        'lumina_string_free',
      );
      _boundLib = lib;
      return true;
    } catch (_) {
      return false;
    }
  }

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
    if (ptr == ffi.nullptr) return null;
    try {
      final bytes = <int>[];
      var offset = 0;
      while (true) {
        final b = ptr[offset];
        if (b == 0) break;
        bytes.add(b);
        offset++;
      }
      return utf8.decode(bytes);
    } finally {
      _stringFreeFn?.call(ptr);
    }
  }

  @override
  Future<List<L1StreamCacheRecord>> loadUnexpired(int nowSec) async {
    await _waitDbReady?.call();
    if (!_ensureBound()) return const <L1StreamCacheRecord>[];
    try {
      final raw = _takeRustString(_loadFn!(nowSec));
      if (raw == null || raw.trim().isEmpty) {
        return const <L1StreamCacheRecord>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <L1StreamCacheRecord>[];
      final out = <L1StreamCacheRecord>[];
      for (final item in decoded) {
        if (item is Map) {
          out.add(L1StreamCacheRecord.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      return out;
    } catch (_) {
      return const <L1StreamCacheRecord>[];
    }
  }

  @override
  Future<void> upsert(L1StreamCacheRecord record) async {
    await _waitDbReady?.call();
    if (!_ensureBound()) return;
    try {
      final encoded = jsonEncode(record.toJson());
      _withNativeUtf8(encoded, (ptr) => _upsertFn!(ptr));
    } catch (_) {
      // Non-fatal persistence failure; in-memory cache remains authoritative.
    }
  }

  @override
  Future<void> delete({
    required String providerId,
    required String trackId,
    String? qualityKey,
  }) async {
    await _waitDbReady?.call();
    if (!_ensureBound()) return;
    try {
      _withNativeUtf8(providerId, (pidPtr) {
        _withNativeUtf8(trackId, (tidPtr) {
          if (qualityKey != null && qualityKey.isNotEmpty) {
            _withNativeUtf8(qualityKey, (qkPtr) {
              _deleteFn!(pidPtr, tidPtr, qkPtr);
            });
          } else {
            _deleteFn!(pidPtr, tidPtr, ffi.nullptr);
          }
        });
      });
    } catch (_) {
      // Non-fatal persistence failure.
    }
  }
}
