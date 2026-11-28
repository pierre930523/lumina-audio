import 'dart:async';
import 'dart:collection';

import '../../../models/stream_source_spec.dart';
import 'l1_cache_record.dart';

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
