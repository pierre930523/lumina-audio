import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:flutter/foundation.dart';

import '../../models/audio_format.dart';
import '../../models/stream_source_spec.dart';

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

/// Wire-compatible persistent record matching Rust `core_db::L1StreamUrlRecord`
/// and the `l1_stream_urls` SQLite schema 1:1.
@immutable
class L1StreamCacheRecord {
  final String providerId;
  final String trackId;
  final String qualityKey;
  final String streamType;
  final String urlOrManifest;
  final String headersJson;
  final String? mimeType;
  final int? bitrateBps;
  final int? contentLength;
  final int? initRangeEnd;
  final int? indexRangeStart;
  final int? indexRangeEnd;
  final int expireAt;
  final int networkEpoch;
  final int updatedAt;
  final String? extraJson;

  const L1StreamCacheRecord({
    required this.providerId,
    required this.trackId,
    required this.qualityKey,
    required this.streamType,
    required this.urlOrManifest,
    this.headersJson = '{}',
    this.mimeType,
    this.bitrateBps,
    this.contentLength,
    this.initRangeEnd,
    this.indexRangeStart,
    this.indexRangeEnd,
    required this.expireAt,
    this.networkEpoch = 1,
    required this.updatedAt,
    this.extraJson,
  });

  StreamKey get key => StreamKey(providerId, trackId, qualityKey);

  factory L1StreamCacheRecord.fromJson(Map<String, dynamic> json) {
    return L1StreamCacheRecord(
      providerId: json['provider_id']?.toString() ?? '',
      trackId: json['track_id']?.toString() ?? '',
      qualityKey: json['quality_key']?.toString() ?? 'default',
      streamType: json['stream_type']?.toString() ?? 'direct_range',
      urlOrManifest: json['url_or_manifest']?.toString() ?? '',
      headersJson: json['headers_json']?.toString() ?? '{}',
      mimeType: json['mime_type']?.toString(),
      bitrateBps: (json['bitrate_bps'] as num?)?.toInt(),
      contentLength: (json['content_length'] as num?)?.toInt(),
      initRangeEnd: (json['init_range_end'] as num?)?.toInt(),
      indexRangeStart: (json['index_range_start'] as num?)?.toInt(),
      indexRangeEnd: (json['index_range_end'] as num?)?.toInt(),
      expireAt: (json['expire_at'] as num?)?.toInt() ?? 0,
      networkEpoch: (json['network_epoch'] as num?)?.toInt() ?? 1,
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      extraJson: json['extra_json']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider_id': providerId,
    'track_id': trackId,
    'quality_key': qualityKey,
    'stream_type': streamType,
    'url_or_manifest': urlOrManifest,
    'headers_json': headersJson,
    if (mimeType != null) 'mime_type': mimeType,
    if (bitrateBps != null) 'bitrate_bps': bitrateBps,
    if (contentLength != null) 'content_length': contentLength,
    if (initRangeEnd != null) 'init_range_end': initRangeEnd,
    if (indexRangeStart != null) 'index_range_start': indexRangeStart,
    if (indexRangeEnd != null) 'index_range_end': indexRangeEnd,
    'expire_at': expireAt,
    'network_epoch': networkEpoch,
    'updated_at': updatedAt,
    if (extraJson != null) 'extra_json': extraJson,
  };

  static L1StreamCacheRecord? fromSpec(
    StreamSourceSpec spec, {
    required int expireAt,
    required int networkEpoch,
    required int updatedAt,
  }) {
    final extra = <String, dynamic>{};
    if (spec.audioFormat != null) {
      extra['audio_format'] = <String, dynamic>{
        'codec': spec.audioFormat!.codec.name,
        'sample_rate_hz': spec.audioFormat!.sampleRateHz,
        'bit_depth': spec.audioFormat!.bitDepth,
        'channels': spec.audioFormat!.channels,
      };
    }
    if (spec.loudness != null) {
      extra['loudness'] = spec.loudness!.toJson();
    }
    if (spec.albumLoudness != null) {
      extra['album_loudness'] = spec.albumLoudness!.toJson();
    }

    switch (spec) {
      case DirectRangeSpec():
        if (spec.hintExtension != null) {
          extra['hint_extension'] = spec.hintExtension;
        }
        if (spec.isPreviewOnly) extra['is_preview_only'] = true;
        if (spec.notice != null) extra['notice'] = spec.notice;
        if (spec.externalWebUrl != null) {
          extra['external_web_url'] = spec.externalWebUrl;
        }
        return L1StreamCacheRecord(
          providerId: spec.key.providerId,
          trackId: spec.key.trackId,
          qualityKey: spec.key.qualityKey,
          streamType: spec.kind,
          urlOrManifest: spec.url,
          headersJson: jsonEncode(spec.headers),
          mimeType: spec.mimeType,
          bitrateBps: spec.bitrateBps,
          contentLength: spec.contentLength,
          initRangeEnd: spec.initRangeEnd,
          indexRangeStart: spec.indexRangeStart,
          indexRangeEnd: spec.indexRangeEnd,
          expireAt: expireAt,
          networkEpoch: networkEpoch,
          updatedAt: updatedAt,
          extraJson: extra.isEmpty ? null : jsonEncode(extra),
        );
      case SegmentedManifestSpec():
        extra['format'] = spec.format.wireValue;
        return L1StreamCacheRecord(
          providerId: spec.key.providerId,
          trackId: spec.key.trackId,
          qualityKey: spec.key.qualityKey,
          streamType: spec.kind,
          urlOrManifest: spec.manifestUrlOrXml,
          headersJson: jsonEncode(spec.headers),
          mimeType: spec.mimeType,
          bitrateBps: spec.bitrateBps,
          expireAt: expireAt,
          networkEpoch: networkEpoch,
          updatedAt: updatedAt,
          extraJson: jsonEncode(extra),
        );
      case EncryptedRangeSpec():
        if (spec.hintExtension != null) {
          extra['hint_extension'] = spec.hintExtension;
        }
        extra['cipher'] = spec.cipher.toJson();
        return L1StreamCacheRecord(
          providerId: spec.key.providerId,
          trackId: spec.key.trackId,
          qualityKey: spec.key.qualityKey,
          streamType: spec.kind,
          urlOrManifest: spec.url,
          headersJson: jsonEncode(spec.headers),
          mimeType: spec.mimeType,
          bitrateBps: spec.bitrateBps,
          contentLength: spec.contentLength,
          expireAt: expireAt,
          networkEpoch: networkEpoch,
          updatedAt: updatedAt,
          extraJson: jsonEncode(extra),
        );
      case LocalFileSpec():
      case ExternalBackendSpec():
        return null;
    }
  }

  StreamSourceSpec? toSpec() {
    if (providerId.isEmpty || trackId.isEmpty || urlOrManifest.isEmpty) {
      return null;
    }
    final headers = _decodeHeaders(headersJson);
    final extra = _decodeExtra(extraJson);
    final audioFormat = _decodeAudioFormat(extra['audio_format']);
    final loudness = _decodeLoudness(extra['loudness']);
    final albumLoudness = _decodeLoudness(extra['album_loudness']);

    switch (streamType) {
      case 'direct_range':
        return DirectRangeSpec(
          key: key,
          url: urlOrManifest,
          headers: headers,
          contentLength: contentLength,
          bitrateBps: bitrateBps,
          mimeType: mimeType,
          hintExtension: extra['hint_extension']?.toString(),
          expireAt: expireAt,
          initRangeEnd: initRangeEnd,
          indexRangeStart: indexRangeStart,
          indexRangeEnd: indexRangeEnd,
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: audioFormat,
          isPreviewOnly: extra['is_preview_only'] == true,
          notice: extra['notice']?.toString(),
          externalWebUrl: extra['external_web_url']?.toString(),
        );
      case 'segmented_manifest':
        final rawFmt = extra['format']?.toString() ?? 'dash';
        final fmt = rawFmt == 'hls' ? ManifestFormat.hls : ManifestFormat.dash;
        return SegmentedManifestSpec(
          key: key,
          manifestUrlOrXml: urlOrManifest,
          format: fmt,
          headers: headers,
          bitrateBps: bitrateBps,
          mimeType: mimeType,
          expireAt: expireAt,
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: audioFormat,
        );
      case 'encrypted_range':
        final rawCipher = extra['cipher'];
        final StreamCipher cipher;
        if (rawCipher is Map) {
          cipher = StreamCipher.fromJson(Map<String, dynamic>.from(rawCipher));
        } else {
          cipher = DeezerBlowfishCipher(trackId: trackId);
        }
        return EncryptedRangeSpec(
          key: key,
          url: urlOrManifest,
          headers: headers,
          contentLength: contentLength,
          bitrateBps: bitrateBps,
          mimeType: mimeType,
          hintExtension: extra['hint_extension']?.toString(),
          cipher: cipher,
          expireAt: expireAt,
          loudness: loudness,
          albumLoudness: albumLoudness,
          audioFormat: audioFormat,
        );
      default:
        return null;
    }
  }

  static Map<String, String> _decodeHeaders(String raw) {
    if (raw.trim().isEmpty) return const <String, String>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map) return const <String, String>{};
      final out = <String, String>{};
      parsed.forEach((k, v) {
        final ks = k?.toString();
        if (ks != null && ks.isNotEmpty && v != null) {
          out[ks] = v.toString();
        }
      });
      return Map<String, String>.unmodifiable(out);
    } catch (_) {
      return const <String, String>{};
    }
  }

  static Map<String, dynamic> _decodeExtra(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) return parsed;
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static AudioFormat? _decodeAudioFormat(dynamic raw) {
    if (raw is! Map) return null;
    final codecName = raw['codec']?.toString().trim().toLowerCase() ?? '';
    final codec = AudioCodec.values.where((c) => c.name == codecName).firstOrNull;
    if (codec == null) return null;
    final sr = (raw['sample_rate_hz'] as num?)?.toInt() ?? 44100;
    final bd = (raw['bit_depth'] as num?)?.toInt() ?? 16;
    final ch = (raw['channels'] as num?)?.toInt() ?? 2;
    return AudioFormat(codec: codec, sampleRateHz: sr, bitDepth: bd, channels: ch);
  }

  static NormalizedLoudness? _decodeLoudness(dynamic raw) {
    if (raw is! Map) return null;
    return NormalizedLoudness.fromJson(Map<String, dynamic>.from(raw));
  }
}

/// In-memory L1 cache entry stored in [L1StreamCache].
@immutable
class L1CacheEntry {
  final StreamSourceSpec spec;
  final int expireAt;
  final int networkEpoch;
  final int updatedAt;

  const L1CacheEntry({
    required this.spec,
    required this.expireAt,
    required this.networkEpoch,
    required this.updatedAt,
  });
}

/// Pluggable persistence backend for [L1StreamCache].
abstract interface class L1StreamCachePersistence {
  Future<List<L1StreamCacheRecord>> loadUnexpired(int nowSec);
  Future<void> upsert(L1StreamCacheRecord record);
  Future<void> delete({
    required String providerId,
    required String trackId,
    String? qualityKey,
  });
}

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

/// Multi-platform L1 direct-URL / manifest cache backed by an O(1) in-memory
/// [LinkedHashMap] hydrated at startup from SQLite WAL (`l1_stream_urls`).
///
/// Strictly enforces [ProviderCapabilities.supportsL1UrlCache] (automatically
/// skipping Apple Music and Local tracks) and subtracts each platform's
/// [ProviderCapabilities.defaultL1SafetyMarginSec] on write.
class L1StreamCache {
  static const int _minUsableSeconds = 5;
  static const int _fallbackYtmRawTtlSec = 21600; // 6 hours
  static const int _fallbackOtherRawTtlSec = 600; // 10 minutes

  final L1StreamCachePersistence? _persistence;
  final DateTime Function() _clock;
  final int maxMemoryEntries;

  final LinkedHashMap<StreamKey, L1CacheEntry> _entries =
      LinkedHashMap<StreamKey, L1CacheEntry>();

  int _networkEpoch;
  bool _hydrated = false;
  Future<void>? _hydrateFuture;

  L1StreamCache({
    this._persistence,
    DateTime Function()? clock,
    int initialNetworkEpoch = 1,
    this.maxMemoryEntries = 512,
  }) : _clock = clock ?? DateTime.now,
       _networkEpoch = initialNetworkEpoch < 1 ? 1 : initialNetworkEpoch;

  int get networkEpoch => _networkEpoch;
  bool get isHydrated => _hydrated;
  int get length => _entries.length;

  int get _nowSec => _clock().millisecondsSinceEpoch ~/ 1000;

  /// Advances `network_epoch` (invalidates entries for platforms declaring
  /// `ProviderCapabilities.needsNetworkEpochReset == true`).
  int bumpNetworkEpoch() {
    _networkEpoch++;
    return _networkEpoch;
  }

  /// Monotonically synchronizes `network_epoch` with an external source (e.g.
  /// Rust `NetworkMonitor` NIC/VPN transition events).
  int syncNetworkEpoch(int newEpoch) {
    if (newEpoch > _networkEpoch) {
      _networkEpoch = newEpoch;
    }
    return _networkEpoch;
  }

  /// Hydrates unexpired SQLite rows into the in-memory HashMap once on startup.
  /// Concurrent calls share the same Future.
  Future<void> hydrate() {
    if (_hydrated) return Future<void>.value();
    final inFlight = _hydrateFuture;
    if (inFlight != null) return inFlight;

    final future = _doHydrate();
    _hydrateFuture = future;
    return future.whenComplete(() {
      if (identical(_hydrateFuture, future)) {
        _hydrateFuture = null;
      }
    });
  }

  Future<void> _doHydrate() async {
    final persistence = _persistence;
    if (persistence == null) {
      _hydrated = true;
      return;
    }
    try {
      final nowSec = _nowSec;
      final rows = await persistence.loadUnexpired(nowSec);
      for (final row in rows) {
        if (row.expireAt <= nowSec) continue;
        final spec = row.toSpec();
        if (spec == null) continue;
        if (_entries.containsKey(row.key)) continue;
        if (_entries.length >= maxMemoryEntries) break;
        _entries[row.key] = L1CacheEntry(
          spec: spec,
          expireAt: row.expireAt,
          networkEpoch: row.networkEpoch,
          updatedAt: row.updatedAt,
        );
      }
      _hydrated = true;
    } catch (_) {
      // Non-fatal: keep running with empty memory cache; allow retry if desired.
    }
  }

  /// O(1) in-memory lookup guarded by [ProviderCapabilities.supportsL1UrlCache],
  /// expiry timestamp, and `network_epoch`.
  StreamSourceSpec? get(StreamKey key, ProviderCapabilities capabilities) {
    if (!capabilities.supportsL1UrlCache) return null;
    final entry = _entries[key];
    if (entry == null) return null;

    final nowSec = _nowSec;
    if (nowSec >= entry.expireAt) {
      _entries.remove(key);
      _deleteFromPersistence(key.providerId, key.trackId, key.qualityKey);
      return null;
    }
    if (capabilities.needsNetworkEpochReset &&
        entry.networkEpoch != _networkEpoch) {
      return null;
    }
    return entry.spec;
  }

  /// Checks whether [spec] matches [failedUrl] for CAS conditional eviction.
  static bool specMatchesUrl(StreamSourceSpec spec, String failedUrl) {
    final trimmed = failedUrl.trim();
    if (trimmed.isEmpty) return true;
    return switch (spec) {
      DirectRangeSpec() => spec.url == trimmed,
      EncryptedRangeSpec() => spec.url == trimmed,
      SegmentedManifestSpec() =>
        spec.manifestUrlOrXml == trimmed ||
            spec.manifestUrlOrXml.contains(trimmed),
      LocalFileSpec() || ExternalBackendSpec() => false,
    };
  }

  /// Compare-And-Swap (CAS) conditional eviction for HTTP 403/410 recovery.
  ///
  /// Only evicts [key] if the currently cached entry matches [failedUrl]. If
  /// another caller already refreshed [key] to a newer URL, preserves the fresh
  /// entry and returns `(evicted: false, currentSpec: current)`.
  ({bool evicted, StreamSourceSpec? currentSpec}) compareAndEvict(
    StreamKey key,
    ProviderCapabilities capabilities,
    String failedUrl,
  ) {
    if (!capabilities.supportsL1UrlCache) {
      return (evicted: false, currentSpec: null);
    }
    final current = get(key, capabilities);
    if (current == null) {
      if (_entries.containsKey(key)) {
        evict(key);
      }
      return (evicted: false, currentSpec: null);
    }
    if (specMatchesUrl(current, failedUrl)) {
      evict(key);
      return (evicted: true, currentSpec: null);
    }
    return (evicted: false, currentSpec: current);
  }

  /// Non-mutating alias for O(1) cache inspection.
  StreamSourceSpec? peek(StreamKey key, ProviderCapabilities capabilities) =>
      get(key, capabilities);

  /// Stores [spec] in memory and asynchronously writes through to SQLite when
  /// [ProviderCapabilities.supportsL1UrlCache] is `true`.
  ///
  /// Subtracts [ProviderCapabilities.defaultL1SafetyMarginSec] when computing
  /// the stored `expire_at`.
  void put(StreamSourceSpec spec, ProviderCapabilities capabilities) {
    if (!capabilities.supportsL1UrlCache) return;
    if (spec is LocalFileSpec || spec is ExternalBackendSpec) return;

    final rawUrl = switch (spec) {
      DirectRangeSpec() => spec.url,
      EncryptedRangeSpec() => spec.url,
      _ => null,
    };
    if (rawUrl != null && _isLoopbackUrl(rawUrl)) return;

    final nowSec = _nowSec;
    final int? rawExpireAt = switch (spec) {
      DirectRangeSpec() => spec.expireAt,
      SegmentedManifestSpec() => spec.expireAt,
      EncryptedRangeSpec() => spec.expireAt,
      _ => null,
    };

    final effectiveRawExpireAt = (rawExpireAt != null && rawExpireAt > 0)
        ? rawExpireAt
        : nowSec +
              (spec.key.providerId == 'youtube_music'
                  ? _fallbackYtmRawTtlSec
                  : _fallbackOtherRawTtlSec);

    final safeExpireAt =
        effectiveRawExpireAt - capabilities.defaultL1SafetyMarginSec;
    if (safeExpireAt <= nowSec + _minUsableSeconds) {
      return;
    }

    if (!_entries.containsKey(spec.key) && _entries.length >= maxMemoryEntries) {
      _entries.remove(_entries.keys.first);
    }

    final entry = L1CacheEntry(
      spec: spec,
      expireAt: safeExpireAt,
      networkEpoch: _networkEpoch,
      updatedAt: nowSec,
    );
    _entries[spec.key] = entry;

    final record = L1StreamCacheRecord.fromSpec(
      spec,
      expireAt: safeExpireAt,
      networkEpoch: _networkEpoch,
      updatedAt: nowSec,
    );
    if (record != null && _persistence != null) {
      unawaited(_persistence.upsert(record).catchError((_) {}));
    }
  }

  /// Evicts an exact [StreamKey] from memory and SQLite.
  void evict(StreamKey key) {
    _entries.remove(key);
    _deleteFromPersistence(key.providerId, key.trackId, key.qualityKey);
  }

  /// Evicts all quality variants for `(providerId, trackId)` from memory and SQLite.
  void evictTrack(String providerId, String trackId) {
    _entries.removeWhere(
      (k, _) => k.providerId == providerId && k.trackId == trackId,
    );
    _deleteFromPersistence(providerId, trackId, null);
  }

  /// Clears all cached entries belonging to [providerId].
  void clearProvider(String providerId) {
    final matchingTracks = <String>{};
    _entries.removeWhere((k, _) {
      if (k.providerId == providerId) {
        matchingTracks.add(k.trackId);
        return true;
      }
      return false;
    });
    for (final tid in matchingTracks) {
      _deleteFromPersistence(providerId, tid, null);
    }
  }

  void clearMemory() {
    _entries.clear();
  }

  void _deleteFromPersistence(
    String providerId,
    String trackId,
    String? qualityKey,
  ) {
    final persistence = _persistence;
    if (persistence == null) return;
    unawaited(
      persistence
          .delete(
            providerId: providerId,
            trackId: trackId,
            qualityKey: qualityKey,
          )
          .catchError((_) {}),
    );
  }

  static bool _isLoopbackUrl(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }
}
