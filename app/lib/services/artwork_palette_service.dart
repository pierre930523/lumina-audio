import 'dart:async';
import 'dart:collection';

import 'package:material_ui/material_ui.dart';

import '../models/playback_state.dart';
import 'artwork_palette/ambient_palette.dart';
import 'artwork_palette/artwork_palette_extractor.dart';
import 'audio_service.dart';
import 'library_index_cache.dart';

export 'artwork_palette/ambient_palette.dart';
export 'artwork_palette/artwork_palette_extractor.dart';

/// Service resolving and LRU-caching [AmbientPalette]s for playing tracks.
class ArtworkPaletteService {
  static const int defaultMaxEntries = 128;

  final int maxEntries;
  final Future<AmbientPalette?> Function(String path)? fileExtractorOverride;
  final Future<AmbientPalette?> Function(String url)? urlExtractorOverride;

  final LinkedHashMap<String, AmbientPalette> _cache =
      LinkedHashMap<String, AmbientPalette>();
  final Map<String, Future<AmbientPalette>> _inFlight = {};

  ArtworkPaletteService({
    this.maxEntries = defaultMaxEntries,
    this.fileExtractorOverride,
    this.urlExtractorOverride,
  }) : assert(maxEntries > 0);

  static bool _isHttpUrl(String value) =>
      value.startsWith('http://') || value.startsWith('https://');

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String? _albumKeyForTrack(TrackInfo? track) {
    if (track == null) return null;
    final album = track.album.trim().toLowerCase();
    if (album.isEmpty) return null;
    final artist = track.effectiveAlbumArtist.trim().toLowerCase();
    return 'album:$artist|$album';
  }

  /// Computes a stable cache key for [resolvedCachePath], [resolvedCoverUrl], or [track].
  String cacheKeyFor({
    TrackInfo? track,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) {
    final cp = resolvedCachePath?.trim();
    if (cp != null && cp.isNotEmpty) {
      return 'file:$cp';
    }
    final cu = resolvedCoverUrl?.trim();
    if (cu != null && cu.isNotEmpty) {
      return 'url:$cu';
    }
    if (track != null) {
      final ack = track.artworkCacheKey?.trim();
      if (ack != null && ack.isNotEmpty) {
        return 'art:$ack';
      }
      final directUrl = _firstNonEmpty([track.coverUrl, track.albumArtUrl]);
      if (directUrl != null) {
        return _isHttpUrl(directUrl) ? 'url:$directUrl' : 'file:$directUrl';
      }
      final albumKey = _albumKeyForTrack(track);
      if (albumKey != null) {
        return albumKey;
      }
      final id = track.id.trim();
      if (id.isNotEmpty) {
        return 'track:$id';
      }
      return 'title:${track.title.trim().toLowerCase()}';
    }
    return 'default';
  }

  /// Synchronous LRU lookup; promotes hit to most-recently-used.
  AmbientPalette? getCachedSync(String key) {
    final hit = _cache.remove(key);
    if (hit == null) return null;
    _cache[key] = hit;
    return hit;
  }

  /// Inserts or updates [key] in the bounded LRU cache.
  void putCachedSync(String key, AmbientPalette palette) {
    if (key.isEmpty) return;
    _cache.remove(key);
    _cache[key] = palette;
    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  int get cacheLength => _cache.length;

  void clearCache() {
    _cache.clear();
    _inFlight.clear();
  }

  /// Resolves an [AmbientPalette] for [track] or explicit artwork path/URL,
  /// deduplicating in-flight work and preserving `maxDim: 0` on disk queries.
  Future<AmbientPalette> resolvePalette({
    TrackInfo? track,
    AudioService? audioService,
    LibraryIndexCache? libraryCache,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) {
    final syncHit = _lookupSync(
      track: track,
      libraryCache: libraryCache,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    );
    if (syncHit != null) {
      return Future.value(syncHit);
    }

    final primaryKey = cacheKeyFor(
      track: track,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    );
    final existing = _inFlight[primaryKey];
    if (existing != null) {
      return existing;
    }

    final future = _resolveImpl(
      track: track,
      audioService: audioService,
      libraryCache: libraryCache,
      resolvedCachePath: resolvedCachePath,
      resolvedCoverUrl: resolvedCoverUrl,
    ).whenComplete(() {
      _inFlight.remove(primaryKey);
    });

    _inFlight[primaryKey] = future;
    return future;
  }

  AmbientPalette? _lookupSync({
    TrackInfo? track,
    LibraryIndexCache? libraryCache,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) {
    final cp = resolvedCachePath?.trim();
    if (cp != null && cp.isNotEmpty) {
      return getCachedSync('file:$cp');
    }
    final cu = resolvedCoverUrl?.trim();
    if (cu != null && cu.isNotEmpty) {
      return getCachedSync('url:$cu');
    }
    if (track == null) return null;

    final ack = track.artworkCacheKey?.trim();
    if (ack != null && ack.isNotEmpty) {
      final hit = getCachedSync('art:$ack');
      if (hit != null) return hit;
    }

    final directUrl = _firstNonEmpty([track.coverUrl, track.albumArtUrl]);
    if (directUrl != null) {
      final directKey =
          _isHttpUrl(directUrl) ? 'url:$directUrl' : 'file:$directUrl';
      return getCachedSync(directKey);
    }

    if (track.id.trim().isNotEmpty) {
      final hit = getCachedSync('track:${track.id.trim()}');
      if (hit != null) return hit;
    }

    final canonicalAlbumId = libraryCache?.resolveAlbumIdForTrack(track);
    if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty) {
      final hit = getCachedSync('canonical_album:$canonicalAlbumId');
      if (hit != null) return hit;
    }

    final albumKey = _albumKeyForTrack(track);
    if (albumKey != null) {
      final hit = getCachedSync(albumKey);
      if (hit != null) return hit;
    }

    return null;
  }

  Future<AmbientPalette> _resolveImpl({
    TrackInfo? track,
    AudioService? audioService,
    LibraryIndexCache? libraryCache,
    String? resolvedCachePath,
    String? resolvedCoverUrl,
  }) async {
    final fallback = AmbientPalette.fallbackFor(track);
    final canonicalAlbumId =
        track != null ? libraryCache?.resolveAlbumIdForTrack(track) : null;

    void storeResolved(
      AmbientPalette palette, {
      String? resolvedKey,
    }) {
      if (resolvedKey != null && resolvedKey.isNotEmpty) {
        putCachedSync(resolvedKey, palette);
      }
      if (track != null) {
        final ack = track.artworkCacheKey?.trim();
        if (ack != null && ack.isNotEmpty) {
          putCachedSync('art:$ack', palette);
        }
        if (track.id.trim().isNotEmpty) {
          putCachedSync('track:${track.id.trim()}', palette);
        }
        if (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty) {
          putCachedSync('canonical_album:$canonicalAlbumId', palette);
        }
        final albumKey = _albumKeyForTrack(track);
        if (albumKey != null) {
          putCachedSync(albumKey, palette);
        }
      }
    }

    // 1. Explicit local file path.
    final cp = resolvedCachePath?.trim();
    if (cp != null && cp.isNotEmpty) {
      final extracted = await _extractFile(cp, fallback: fallback);
      if (extracted != null) {
        storeResolved(extracted, resolvedKey: 'file:$cp');
        return extracted;
      }
      final cu = resolvedCoverUrl?.trim();
      if (cu != null && cu.isNotEmpty) {
        final urlExtracted = await _extractUrlOrPath(cu, fallback: fallback);
        if (urlExtracted != null) {
          storeResolved(urlExtracted, resolvedKey: 'url:$cu');
          return urlExtracted;
        }
      }
      return fallback;
    }

    // 2. Explicit cover URL.
    final cu = resolvedCoverUrl?.trim();
    if (cu != null && cu.isNotEmpty) {
      final extracted = await _extractUrlOrPath(cu, fallback: fallback);
      if (extracted != null) {
        storeResolved(extracted, resolvedKey: 'url:$cu');
        return extracted;
      }
      return fallback;
    }

    if (track == null) return fallback;

    // 3. Direct URL or local file path on TrackInfo.
    final directUrl = _firstNonEmpty([track.coverUrl, track.albumArtUrl]);
    if (directUrl != null && !directUrl.startsWith('/api/')) {
      final directKey =
          _isHttpUrl(directUrl) ? 'url:$directUrl' : 'file:$directUrl';
      final cachedDirect = getCachedSync(directKey);
      if (cachedDirect != null) {
        storeResolved(cachedDirect);
        return cachedDirect;
      }
      final extracted = _isHttpUrl(directUrl)
          ? await _extractUrlOrPath(directUrl, fallback: fallback)
          : await _extractFile(directUrl, fallback: fallback);
      if (extracted != null) {
        storeResolved(extracted, resolvedKey: directKey);
        return extracted;
      }
    }

    // 4. Synchronous path from LibraryIndexCache.
    if (libraryCache != null) {
      final syncPath = _firstNonEmpty([
        track.id.isNotEmpty ? libraryCache.getArtworkPathSync(track.id) : null,
        (canonicalAlbumId != null && canonicalAlbumId.isNotEmpty)
            ? libraryCache.getArtworkPathSync(canonicalAlbumId)
            : null,
      ]);
      if (syncPath != null) {
        final key = 'file:$syncPath';
        final cached = getCachedSync(key);
        if (cached != null) {
          storeResolved(cached);
          return cached;
        }
        final extracted = await _extractFile(syncPath, fallback: fallback);
        if (extracted != null) {
          storeResolved(extracted, resolvedKey: key);
          return extracted;
        }
      }
    }

    // 5. Asynchronous artwork resolution preserving full-res disk contract (maxDim: 0).
    if (audioService != null) {
      String? resolvedPath;
      if (libraryCache != null) {
        if (canonicalAlbumId != null &&
            canonicalAlbumId.isNotEmpty &&
            !libraryCache.hasArtworkCached(canonicalAlbumId)) {
          try {
            resolvedPath = await libraryCache.resolveArtworkPath(
              audioService,
              canonicalAlbumId,
              maxDim: 0,
            );
          } catch (_) {}
        }
        if ((resolvedPath == null || resolvedPath.isEmpty) &&
            track.id.isNotEmpty &&
            !libraryCache.hasArtworkCached(track.id)) {
          try {
            resolvedPath = await libraryCache.resolveArtworkPath(
              audioService,
              track.id,
              path: track.filePath,
              maxDim: 0,
            );
          } catch (_) {}
        }
      } else if (track.id.isNotEmpty) {
        try {
          final res = await audioService.getArtwork(
            track.id,
            path: track.filePath,
            maxDim: 0,
          );
          if (res != null && res['found'] == true) {
            final candidate = res['cache_path']?.toString();
            if (candidate != null && candidate.isNotEmpty) {
              resolvedPath = candidate;
            }
          }
        } catch (_) {}
      }

      if (resolvedPath != null && resolvedPath.isNotEmpty) {
        final key = 'file:$resolvedPath';
        final cached = getCachedSync(key);
        if (cached != null) {
          storeResolved(cached);
          return cached;
        }
        final extracted = await _extractFile(resolvedPath, fallback: fallback);
        if (extracted != null) {
          storeResolved(extracted, resolvedKey: key);
          return extracted;
        }
      }
    }

    return fallback;
  }

  Future<AmbientPalette?> _extractFile(
    String path, {
    required AmbientPalette fallback,
  }) async {
    if (fileExtractorOverride != null) {
      try {
        return await fileExtractorOverride!(path);
      } catch (_) {
        return null;
      }
    }
    return ArtworkPaletteExtractor.extractFromFile(path, fallback: fallback);
  }

  Future<AmbientPalette?> _extractUrlOrPath(
    String url, {
    required AmbientPalette fallback,
  }) async {
    if (urlExtractorOverride != null) {
      try {
        return await urlExtractorOverride!(url);
      } catch (_) {
        return null;
      }
    }
    if (!_isHttpUrl(url)) {
      if (url.startsWith('/api/')) return null;
      return ArtworkPaletteExtractor.extractFromFile(url, fallback: fallback);
    }
    return ArtworkPaletteExtractor.extractFromImageProvider(
      NetworkImage(url),
      fallback: fallback,
    );
  }
}
