import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';

/// Aggregated synchronous index record for an artist across albums and tracks.
@immutable
class ArtistIndexEntry {
  final String key;
  final String displayName;
  final List<CanonicalAlbumSummary> albums;
  final List<TrackInfo> tracks;
  final CanonicalAlbumSummary? representativeAlbum;
  final TrackInfo? representativeTrack;

  const ArtistIndexEntry({
    required this.key,
    required this.displayName,
    this.albums = const [],
    this.tracks = const [],
    this.representativeAlbum,
    this.representativeTrack,
  });

  int get albumCount => albums.length;
  int get trackCount => tracks.length;
  int get totalTrackCount => tracks.length;
}

/// Synchronous in-memory cache for library albums, album details, artist
/// aggregations, and verified artwork file paths with deduplicated in-flight
/// loading so detail views render on frame 0 without blank/black flashes.
class LibraryIndexCache extends ChangeNotifier {
  final Map<String, CanonicalAlbumSummary> _albumsById = {};
  final Map<String, CanonicalAlbumDetail> _albumDetailsById = {};
  final Map<String, ArtistIndexEntry> _artistsByKey = {};
  final Map<(String, int), String?> _artworkPathCache = {};

  static const int _maxConcurrentArtworkRequests = 2;

  final Map<String, Future<CanonicalAlbumDetail?>> _inFlightAlbumDetails = {};
  final Map<(String, int), Future<String?>> _inFlightArtwork = {};
  final Queue<Completer<void>> _artworkWaitQueue = Queue<Completer<void>>();
  int _activeArtworkRequests = 0;
  Future<void>? _refreshFuture;

  List<CanonicalAlbumSummary> _orderedAlbums = const [];
  List<ArtistIndexEntry> _orderedArtists = const [];
  final Map<String, CanonicalAlbumSummary> _albumByNormalizedTitle = {};
  final Map<String, CanonicalAlbumSummary> _albumByNormalizedTitleAndArtist = {};
  bool _isPrimed = false;

  static String normalizeArtistKey(String name) => name.trim().toLowerCase();

  static String _normalizeTitleKey(String title) => title.trim().toLowerCase();

  Map<String, CanonicalAlbumSummary> get albumsById =>
      UnmodifiableMapView(_albumsById);

  Map<String, CanonicalAlbumDetail> get albumDetailsById =>
      UnmodifiableMapView(_albumDetailsById);

  Map<String, ArtistIndexEntry> get artistsByKey =>
      UnmodifiableMapView(_artistsByKey);

  Map<(String, int), String?> get artworkPathCache =>
      UnmodifiableMapView(_artworkPathCache);

  List<CanonicalAlbumSummary> get albums => _orderedAlbums;

  List<ArtistIndexEntry> get artists => _orderedArtists;

  bool get isPrimed => _isPrimed;

  bool get isRefreshing => _refreshFuture != null;

  /// Primes the cache once using [audioService]. Subsequent calls before
  /// [refresh] return immediately (or await the active prime future).
  Future<void> prime(AudioService audioService) {
    if (_isPrimed) return Future.value();
    return refresh(audioService);
  }

  /// Refreshes albums and artist indices from [audioService], deduplicating
  /// concurrent refresh calls.
  Future<void> refresh(AudioService audioService) {
    final active = _refreshFuture;
    if (active != null) return active;

    final future = _doRefresh(audioService).whenComplete(() {
      _refreshFuture = null;
    });
    _refreshFuture = future;
    return future;
  }

  Future<void> _doRefresh(AudioService audioService) async {
    final fetchedAlbums = await audioService.getAlbums(limit: 500);
    final queueTracks = List<TrackInfo>.from(audioService.queue);
    _rebuildIndex(albums: fetchedAlbums, tracks: queueTracks);
    _isPrimed = true;
    notifyListeners();
  }

  /// Synchronously seeds albums, tracks, and optional album details into the
  /// in-memory index (useful for instant frame-0 rendering and tests).
  void seedSync({
    List<CanonicalAlbumSummary> albums = const [],
    List<TrackInfo> tracks = const [],
    List<CanonicalAlbumDetail> details = const [],
  }) {
    for (final d in details) {
      _albumDetailsById[d.id] = d;
    }
    _rebuildIndex(
      albums: albums.isNotEmpty ? albums : _orderedAlbums,
      tracks: tracks,
    );
    _isPrimed = true;
    notifyListeners();
  }

  /// Synchronously ensures queue tracks are indexed when [getAlbums] has not
  /// resolved yet, without overwriting previously fetched albums.
  void seedFromQueueSync(List<TrackInfo> tracks) {
    if (tracks.isEmpty && _isPrimed) return;
    _rebuildIndex(albums: _orderedAlbums, tracks: tracks);
    notifyListeners();
  }

  void _rebuildIndex({
    required List<CanonicalAlbumSummary> albums,
    required List<TrackInfo> tracks,
  }) {
    _albumsById.clear();
    _albumByNormalizedTitle.clear();
    _albumByNormalizedTitleAndArtist.clear();

    final dedupedAlbums = <CanonicalAlbumSummary>[];
    for (final album in albums) {
      if (album.id.isEmpty) continue;
      if (!_albumsById.containsKey(album.id)) {
        dedupedAlbums.add(album);
      }
      _albumsById[album.id] = album;

      final titleKey = _normalizeTitleKey(album.title);
      if (titleKey.isNotEmpty) {
        _albumByNormalizedTitle.putIfAbsent(titleKey, () => album);
        final artistKey = normalizeArtistKey(album.artist);
        if (artistKey.isNotEmpty) {
          _albumByNormalizedTitleAndArtist.putIfAbsent(
            '$artistKey|$titleKey',
            () => album,
          );
        }
        final aaKey = normalizeArtistKey(album.albumArtist ?? '');
        if (aaKey.isNotEmpty) {
          _albumByNormalizedTitleAndArtist.putIfAbsent(
            '$aaKey|$titleKey',
            () => album,
          );
        }
      }
    }
    _orderedAlbums = List.unmodifiable(dedupedAlbums);

    // Group tracks and albums by normalized artist key.
    final displayNames = <String, String>{};
    final tracksByArtist = <String, List<TrackInfo>>{};
    final albumsByArtist = <String, Map<String, CanonicalAlbumSummary>>{};

    for (final track in tracks) {
      final rawName = track.artist.trim();
      final key = normalizeArtistKey(rawName);
      if (key.isNotEmpty) {
        displayNames.putIfAbsent(key, () => rawName);
        tracksByArtist.putIfAbsent(key, () => []).add(track);
      }
    }

    for (final album in dedupedAlbums) {
      final primaryName = album.artist.trim();
      final primaryKey = normalizeArtistKey(primaryName);
      if (primaryKey.isNotEmpty) {
        displayNames.putIfAbsent(primaryKey, () => primaryName);
        albumsByArtist.putIfAbsent(primaryKey, () => {})[album.id] = album;
      }
      final aaName = (album.albumArtist ?? '').trim();
      final aaKey = normalizeArtistKey(aaName);
      if (aaKey.isNotEmpty && aaKey != primaryKey) {
        displayNames.putIfAbsent(aaKey, () => aaName);
        albumsByArtist.putIfAbsent(aaKey, () => {})[album.id] = album;
      }
    }

    _artistsByKey.clear();
    final allKeys = <String>{
      ...tracksByArtist.keys,
      ...albumsByArtist.keys,
    };

    for (final key in allKeys) {
      final artistAlbums =
          (albumsByArtist[key]?.values.toList() ?? <CanonicalAlbumSummary>[])
            ..sort(compareAlbumsNewestFirst);
      final artistTracks = List<TrackInfo>.unmodifiable(
        tracksByArtist[key] ?? const <TrackInfo>[],
      );
      final repAlbum = _pickRepresentativeAlbum(artistAlbums);
      final repTrack = _pickRepresentativeTrack(artistTracks);
      _artistsByKey[key] = ArtistIndexEntry(
        key: key,
        displayName: displayNames[key] ?? key,
        albums: List.unmodifiable(artistAlbums),
        tracks: artistTracks,
        representativeAlbum: repAlbum,
        representativeTrack: repTrack,
      );
    }

    final sortedArtists = _artistsByKey.values.toList()
      ..sort(
        (a, b) => a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        ),
      );
    _orderedArtists = List.unmodifiable(sortedArtists);
  }

  static int compareAlbumsNewestFirst(
    CanonicalAlbumSummary a,
    CanonicalAlbumSummary b,
  ) {
    final ya = a.year;
    final yb = b.year;
    if (ya != null && yb != null && ya != yb) {
      return yb.compareTo(ya);
    }
    if (ya != null && yb == null) return -1;
    if (ya == null && yb != null) return 1;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  CanonicalAlbumSummary? _pickRepresentativeAlbum(
    List<CanonicalAlbumSummary> albums,
  ) {
    if (albums.isEmpty) return null;
    for (final a in albums) {
      if ((a.coverUrl != null && a.coverUrl!.isNotEmpty) ||
          getArtworkPathSync(a.id) != null) {
        return a;
      }
    }
    return albums.first;
  }

  TrackInfo? _pickRepresentativeTrack(List<TrackInfo> tracks) {
    if (tracks.isEmpty) return null;
    for (final t in tracks) {
      if ((t.coverUrl != null && t.coverUrl!.isNotEmpty) ||
          (t.albumArtUrl != null && t.albumArtUrl!.isNotEmpty) ||
          getArtworkPathSync(t.id) != null) {
        return t;
      }
    }
    return tracks.first;
  }

  /// Stores or updates a [CanonicalAlbumSummary] synchronously in cache.
  void putAlbumSummarySync(CanonicalAlbumSummary summary) {
    _albumsById[summary.id] = summary;
  }

  /// Stores or updates a [CanonicalAlbumDetail] synchronously in cache.
  void putAlbumDetailSync(CanonicalAlbumDetail detail) {
    _albumDetailsById[detail.id] = detail;
    if (!_albumsById.containsKey(detail.id)) {
      _albumsById[detail.id] = CanonicalAlbumSummary(
        id: detail.id,
        title: detail.title,
        artist: detail.artistName,
        year: detail.releaseYear,
        coverUrl: detail.coverUrl,
      );
    }
    notifyListeners();
  }

  /// Synchronous summary lookup for frame-0 Hero rendering.
  CanonicalAlbumSummary? getAlbumSummarySync(String albumId) =>
      _albumsById[albumId];

  /// Synchronous album detail lookup for frame-0 rendering.
  CanonicalAlbumDetail? getAlbumDetailSync(String albumId) =>
      _albumDetailsById[albumId];

  /// Loads and caches [CanonicalAlbumDetail] from [audioService], deduplicating
  /// concurrent requests for the same [albumId].
  Future<CanonicalAlbumDetail?> loadAlbumDetail(
    AudioService audioService,
    String albumId, {
    bool forceRefresh = false,
  }) {
    if (!forceRefresh) {
      final cached = _albumDetailsById[albumId];
      if (cached != null) return Future.value(cached);
    }

    final existing = _inFlightAlbumDetails[albumId];
    if (existing != null) return existing;

    final future = audioService
        .getAlbumDetail(albumId)
        .then((detail) {
          if (detail != null) {
            _albumDetailsById[albumId] = detail;
            _albumsById.putIfAbsent(
              albumId,
              () => CanonicalAlbumSummary(
                id: detail.id,
                title: detail.title,
                artist: detail.artistName,
                year: detail.releaseYear,
                coverUrl: detail.coverUrl,
              ),
            );
            notifyListeners();
          }
          return detail;
        })
        .whenComplete(() {
          _inFlightAlbumDetails.remove(albumId);
        });

    _inFlightAlbumDetails[albumId] = future;
    return future;
  }

  /// Synchronous case-insensitive artist lookup.
  ArtistIndexEntry? getArtistSync(String artistNameOrKey) {
    final key = normalizeArtistKey(artistNameOrKey);
    if (key.isEmpty) return null;
    return _artistsByKey[key];
  }

  /// Ensures the library index is primed and returns the matching
  /// [ArtistIndexEntry] if available.
  Future<ArtistIndexEntry?> ensureArtistLoaded(
    AudioService audioService,
    String artistNameOrKey,
  ) async {
    final key = normalizeArtistKey(artistNameOrKey);
    if (key.isEmpty) return null;
    final cached = _artistsByKey[key];
    if (cached != null && _isPrimed) return cached;
    await prime(audioService);
    return _artistsByKey[key];
  }

  /// Resolves the canonical album matching [track], checking exact artist+title,
  /// exact title, and prefix fallback (e.g. remastered edition suffixes).
  CanonicalAlbumSummary? resolveAlbumForTrack(TrackInfo track) {
    final titleKey = _normalizeTitleKey(track.album);
    if (titleKey.isEmpty) return null;

    final artistKey = normalizeArtistKey(track.artist);
    final albumArtistKey = normalizeArtistKey(track.effectiveAlbumArtist);

    final exact =
        _albumByNormalizedTitleAndArtist['$albumArtistKey|$titleKey'] ??
        _albumByNormalizedTitleAndArtist['$artistKey|$titleKey'] ??
        _albumByNormalizedTitle[titleKey];
    if (exact != null) return exact;

    for (final album in _orderedAlbums) {
      final albTitle = _normalizeTitleKey(album.title);
      if (albTitle.isEmpty) continue;
      final albArtist = normalizeArtistKey(album.artist);
      final sameArtist =
          albArtist == artistKey || albArtist == albumArtistKey;
      if (sameArtist &&
          (titleKey.startsWith(albTitle) || albTitle.startsWith(titleKey))) {
        return album;
      }
    }

    for (final detail in _albumDetailsById.values) {
      for (final ver in detail.versions) {
        if (ver.tracks.any((t) => t.id == track.id)) {
          return _albumsById[detail.id];
        }
      }
    }
    return null;
  }

  String? resolveAlbumIdForTrack(TrackInfo track) {
    final summary = resolveAlbumForTrack(track);
    if (summary != null) return summary.id;
    for (final detail in _albumDetailsById.values) {
      for (final ver in detail.versions) {
        if (ver.tracks.any((t) => t.id == track.id)) {
          return detail.id;
        }
      }
    }
    return null;
  }

  bool hasArtworkCached(String targetId, {int revision = 0}) =>
      _artworkPathCache.containsKey((targetId, revision));

  String? getArtworkPathSync(String targetId, {int revision = 0}) =>
      _artworkPathCache[(targetId, revision)];

  void setArtworkPathSync(
    String targetId,
    String? path, {
    int revision = 0,
    bool notify = false,
  }) {
    _artworkPathCache[(targetId, revision)] = path;
    if (notify) notifyListeners();
  }

  /// Resolves and verifies an artwork cache file path asynchronously without
  /// blocking `build()`, deduplicating concurrent requests for `(targetId, revision)`.
  Future<String?> resolveArtworkPath(
    AudioService audioService,
    String targetId, {
    String? path,
    int revision = 0,
    int maxDim = 0,
  }) {
    final cacheKey = (targetId, revision);
    if (_artworkPathCache.containsKey(cacheKey)) {
      return Future.value(_artworkPathCache[cacheKey]);
    }
    final inFlight = _inFlightArtwork[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _fetchAndVerifyArtwork(
      audioService,
      targetId,
      path: path,
      revision: revision,
      maxDim: maxDim,
    ).whenComplete(() {
      _inFlightArtwork.remove(cacheKey);
    });
    _inFlightArtwork[cacheKey] = future;
    return future;
  }

  Future<void> _acquireArtworkSlot(AudioService audioService) async {
    if (_activeArtworkRequests < _maxConcurrentArtworkRequests) {
      _activeArtworkRequests++;
      return;
    }
    final completer = Completer<void>();
    _artworkWaitQueue.addLast(completer);
    await completer.future;
    if (audioService.isNativeBound) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  void _releaseArtworkSlot() {
    while (_artworkWaitQueue.isNotEmpty) {
      final next = _artworkWaitQueue.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    if (_activeArtworkRequests > 0) {
      _activeArtworkRequests--;
    }
  }

  Future<String?> _fetchAndVerifyArtwork(
    AudioService audioService,
    String targetId, {
    String? path,
    required int revision,
    required int maxDim,
  }) async {
    // Yield the current build frame before invoking artwork extraction, and
    // yield an inter-frame timer on native FFI builds so transitions stay smooth.
    await Future<void>.microtask(() {});
    if (audioService.isNativeBound) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }

    final cacheKey = (targetId, revision);
    if (_artworkPathCache.containsKey(cacheKey)) {
      return _artworkPathCache[cacheKey];
    }

    await _acquireArtworkSlot(audioService);
    try {
      if (_artworkPathCache.containsKey(cacheKey)) {
        return _artworkPathCache[cacheKey];
      }
      final res = await audioService.getArtwork(
        targetId,
        path: path,
        maxDim: maxDim,
      );
      if (res != null && res['found'] == true) {
        final cp = res['cache_path']?.toString();
        if (cp != null && cp.isNotEmpty && File(cp).existsSync()) {
          _artworkPathCache[cacheKey] = cp;
          return cp;
        }
      }
      _artworkPathCache[cacheKey] = null;
      return null;
    } catch (_) {
      return null;
    } finally {
      _releaseArtworkSlot();
    }
  }

  /// Invalidates all cached artwork entries for [targetId] across revisions.
  void invalidateArtwork(String targetId) {
    final keysToRemove = _artworkPathCache.keys
        .where((k) => k.$1 == targetId)
        .toList();
    for (final k in keysToRemove) {
      _artworkPathCache.remove(k);
    }
    final flightToRemove = _inFlightArtwork.keys
        .where((k) => k.$1 == targetId)
        .toList();
    for (final k in flightToRemove) {
      _inFlightArtwork.remove(k);
    }
    notifyListeners();
  }

  void clear() {
    _albumsById.clear();
    _albumDetailsById.clear();
    _artistsByKey.clear();
    _artworkPathCache.clear();
    _inFlightAlbumDetails.clear();
    _inFlightArtwork.clear();
    _orderedAlbums = const [];
    _orderedArtists = const [];
    _albumByNormalizedTitle.clear();
    _albumByNormalizedTitleAndArtist.clear();
    _isPrimed = false;
    notifyListeners();
  }
}
