import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/playback_state.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'library_index/artist_index_entry.dart';

export 'library_index/artist_index_entry.dart';

part 'library_index/library_index_artwork.dart';
part 'library_index/library_index_details.dart';
part 'library_index/library_index_grouping.dart';

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
  int _artworkCacheEpoch = 0;
  int _refreshGeneration = 0;
  Future<void>? _refreshFuture;
  bool _activeRefreshInvalidates = false;

  List<CanonicalAlbumSummary> _orderedAlbums = const [];
  List<ArtistIndexEntry> _orderedArtists = const [];
  final Map<String, CanonicalAlbumSummary> _albumByNormalizedTitle = {};
  final Map<String, CanonicalAlbumSummary> _albumByNormalizedTitleAndArtist = {};
  bool _isPrimed = false;
  bool _includeHidden = false;

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

  bool get includeHidden => _includeHidden;

  bool get isRefreshing => _refreshFuture != null;

  /// Updates whether hidden and alternate versions are included in [albums]
  /// and refreshes the index from [audioService] when changed.
  Future<void> setIncludeHidden(
    AudioService audioService,
    bool includeHidden,
  ) => _setIncludeHiddenImpl(audioService, includeHidden);

  void setIncludeHiddenSync(bool includeHidden) {
    _includeHidden = includeHidden;
  }

  /// Monotonically increases each time [refresh] or [clear] invalidates cached
  /// album details and artwork paths.
  int get refreshGeneration => _refreshGeneration;

  /// Primes the cache once using [audioService]. Subsequent calls before
  /// [refresh] return immediately (or await the active prime future).
  Future<void> prime(AudioService audioService) {
    if (_isPrimed) return Future.value();
    return _startRefresh(audioService, invalidateCachedAssets: false);
  }

  /// Refreshes albums and artist indices from [audioService], deduplicating
  /// concurrent refresh calls.
  Future<void> refresh(AudioService audioService) =>
      _startRefresh(audioService, invalidateCachedAssets: true);

  Future<void> _startRefresh(
    AudioService audioService, {
    required bool invalidateCachedAssets,
  }) {
    final active = _refreshFuture;
    if (active != null && !invalidateCachedAssets) return active;
    if (active != null && _activeRefreshInvalidates) return active;

    _activeRefreshInvalidates = invalidateCachedAssets;
    final future = _doRefresh(
      audioService,
      invalidateCachedAssets: invalidateCachedAssets,
    ).whenComplete(() {
      _refreshFuture = null;
      _activeRefreshInvalidates = false;
    });
    _refreshFuture = future;
    return future;
  }

  static int _countTracks(CanonicalAlbumDetail detail) {
    var total = 0;
    for (final v in detail.versions) {
      total += v.tracks.length;
    }
    return total;
  }

  static bool _isValidSummary(CanonicalAlbumSummary album) =>
      album.id.isNotEmpty && (album.trackCount == null || album.trackCount! > 0);

  static CanonicalAlbumDetail _filterEmptyVersions(CanonicalAlbumDetail detail) {
    if (detail.versions.every((v) => v.tracks.isNotEmpty)) {
      return detail;
    }
    return detail.copyWith(
      versions: detail.versions
          .where((v) => v.tracks.isNotEmpty)
          .toList(growable: false),
    );
  }

  Future<void> _doRefresh(
    AudioService audioService, {
    required bool invalidateCachedAssets,
  }) async {
    final fetchedAlbums = await audioService.getAlbums(
      limit: 500,
      includeHidden: _includeHidden,
    );
    final libraryTracks = await audioService.getLibraryTracksFiltered(
      limit: 10000,
      includeHidden: _includeHidden,
    );
    if (invalidateCachedAssets) {
      final staleArtworkPaths = _artworkPathCache.values
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      _albumDetailsById.clear();
      _inFlightAlbumDetails.clear();
      _artworkPathCache.clear();
      _inFlightArtwork.clear();
      _artworkCacheEpoch++;
      _refreshGeneration++;
      _evictArtworkImageCache(staleArtworkPaths);
    }
    _rebuildIndex(albums: fetchedAlbums, tracks: libraryTracks);
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
      final sanitized = _filterEmptyVersions(d);
      if (sanitized.versions.isNotEmpty) {
        _albumDetailsById[sanitized.id] = sanitized;
      }
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
  }) => _rebuildIndexImpl(albums: albums, tracks: tracks);

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

  void _notifyCacheChanged() => notifyListeners();

  /// Stores or updates a [CanonicalAlbumSummary] synchronously in cache.
  /// Albums with explicit `trackCount <= 0` are ignored and evicted.
  void putAlbumSummarySync(CanonicalAlbumSummary summary) {
    if (!_isValidSummary(summary)) {
      _evictAlbumByIdImpl(summary.id);
      return;
    }
    _albumsById[summary.id] = summary;
  }

  /// Stores or updates a [CanonicalAlbumDetail] synchronously in cache.
  /// Never caches or synthesizes a summary when all versions have 0 tracks.
  void putAlbumDetailSync(CanonicalAlbumDetail detail) =>
      _putAlbumDetailSyncImpl(detail);

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
  }) =>
      _loadAlbumDetailImpl(
        audioService,
        albumId,
        forceRefresh: forceRefresh,
      );

  /// Synchronous case-insensitive artist lookup.
  ArtistIndexEntry? getArtistSync(String artistNameOrKey) {
    final key = normalizeArtistKey(artistNameOrKey);
    if (key.isEmpty) return null;
    return _artistsByKey[key];
  }

  /// Stores or updates artist ID and tri-state preference from [ArtistDetailInfo].
  void putArtistDetailSync(ArtistDetailInfo detail) =>
      _putArtistDetailSyncImpl(detail);

  /// Updates cached album or artist tri-state preference immediately in memory.
  void updateEntityPreferenceSync(
    String entityType,
    String entityId,
    int preference,
  ) => _updateEntityPreferenceSyncImpl(entityType, entityId, preference);

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
  }) =>
      _resolveArtworkPathImpl(
        audioService,
        targetId,
        path: path,
        revision: revision,
        maxDim: maxDim,
      );

  /// Invalidates all cached artwork entries for [targetId] across revisions.
  void invalidateArtwork(String targetId) {
    _invalidateArtworkImpl(targetId);
    notifyListeners();
  }

  void clear() {
    final staleArtworkPaths = _artworkPathCache.values
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    _albumsById.clear();
    _albumDetailsById.clear();
    _artistsByKey.clear();
    _artworkPathCache.clear();
    _inFlightAlbumDetails.clear();
    _inFlightArtwork.clear();
    _artworkCacheEpoch++;
    _refreshGeneration++;
    _evictArtworkImageCache(staleArtworkPaths);
    _orderedAlbums = const [];
    _orderedArtists = const [];
    _albumByNormalizedTitle.clear();
    _albumByNormalizedTitleAndArtist.clear();
    _isPrimed = false;
    notifyListeners();
  }
}
