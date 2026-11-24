import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/streaming_models.dart';
import '../models/streaming_provider_meta.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'library_index_cache.dart';
import 'library_settings_controller.dart';
import 'streaming/streaming_manager.dart';

/// Unified search result wrapper for a track from either local library or a
/// connected streaming provider.
@immutable
class SearchTrackMatch {
  final TrackInfo track;
  final String sourceKind;

  const SearchTrackMatch({
    required this.track,
    required this.sourceKind,
  });

  bool get isLocal => sourceKind == 'local';
}

/// Unified search result wrapper for an album from either local library or a
/// connected streaming provider.
@immutable
class SearchAlbumMatch {
  final String id;
  final String title;
  final String artist;
  final int? year;
  final String? coverUrl;
  final String? qualityLabel;
  final String sourceKind;
  final CanonicalAlbumSummary? localAlbum;
  final StreamingAlbum? streamingAlbum;

  const SearchAlbumMatch({
    required this.id,
    required this.title,
    required this.artist,
    required this.sourceKind,
    this.year,
    this.coverUrl,
    this.qualityLabel,
    this.localAlbum,
    this.streamingAlbum,
  });

  factory SearchAlbumMatch.local(CanonicalAlbumSummary album) {
    return SearchAlbumMatch(
      id: album.id,
      title: album.title,
      artist: album.artist,
      year: album.year,
      coverUrl: album.coverUrl,
      sourceKind: 'local',
      localAlbum: album,
    );
  }

  factory SearchAlbumMatch.streaming(StreamingAlbum album) {
    return SearchAlbumMatch(
      id: album.id,
      title: album.title,
      artist: album.artist,
      year: album.year,
      coverUrl: album.coverUrl,
      qualityLabel: album.qualityLabel,
      sourceKind: album.providerKind,
      streamingAlbum: album,
    );
  }

  bool get isLocal => sourceKind == 'local';
}

/// Unified search result wrapper for an artist extracted from local library
/// or streaming search catalogs.
@immutable
class SearchArtistMatch {
  final String name;
  final List<String> sourceKinds;
  final int albumCount;
  final int trackCount;
  final String? coverUrl;
  final CanonicalAlbumSummary? representativeAlbum;
  final TrackInfo? representativeTrack;

  const SearchArtistMatch({
    required this.name,
    required this.sourceKinds,
    this.albumCount = 0,
    this.trackCount = 0,
    this.coverUrl,
    this.representativeAlbum,
    this.representativeTrack,
  });
}

/// Per-provider streaming search state & results bucket.
@immutable
class ProviderSearchBucket {
  final String providerKind;
  final List<TrackInfo> tracks;
  final List<StreamingAlbum> albums;
  final List<SearchArtistMatch> artists;
  final bool isLoading;
  final String? error;

  const ProviderSearchBucket({
    required this.providerKind,
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.isLoading = false,
    this.error,
  });

  int get totalCount => tracks.length + albums.length + artists.length;
  bool get hasError => error != null && error!.trim().isNotEmpty;

  ProviderSearchBucket copyWith({
    List<TrackInfo>? tracks,
    List<StreamingAlbum>? albums,
    List<SearchArtistMatch>? artists,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ProviderSearchBucket(
      providerKind: providerKind,
      tracks: tracks ?? this.tracks,
      albums: albums ?? this.albums,
      artists: artists ?? this.artists,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Coordinates debounced, cancellable, non-blocking parallel search across
/// the local library and all connected streaming providers.
class UnifiedSearchController extends ChangeNotifier {
  final AudioService audioService;
  final LibraryIndexCache libraryCache;
  final StreamingManager streamingManager;
  final LibrarySettingsController? librarySettings;
  final Duration debounceDuration;
  final Duration streamingTimeout;

  String _query = '';
  String _selectedSource = 'all';
  bool _isSearchingLocal = false;
  List<TrackInfo> _localTracks = const [];
  List<CanonicalAlbumSummary> _localAlbums = const [];
  List<SearchArtistMatch> _localArtists = const [];
  Map<String, ProviderSearchBucket> _streamingBuckets = const {};

  int _requestId = 0;
  Timer? _debounce;
  CancellationToken? _activeCancel;
  bool _disposed = false;

  UnifiedSearchController({
    required this.audioService,
    required this.libraryCache,
    required this.streamingManager,
    this.librarySettings,
    this.debounceDuration = const Duration(milliseconds: 300),
    this.streamingTimeout = const Duration(seconds: 8),
  });

  String get query => _query;
  String get selectedSource => _selectedSource;
  bool get isSearchingLocal => _isSearchingLocal;
  bool get isAnyLoading =>
      _isSearchingLocal || _streamingBuckets.values.any((b) => b.isLoading);

  List<TrackInfo> get localTracks => _localTracks;
  List<CanonicalAlbumSummary> get localAlbums => _localAlbums;
  List<SearchArtistMatch> get localArtists => _localArtists;
  Map<String, ProviderSearchBucket> get streamingBuckets =>
      Map.unmodifiable(_streamingBuckets);

  int get localTotalCount =>
      _localTracks.length + _localAlbums.length + _localArtists.length;

  int get totalResultCount =>
      localTotalCount +
      _streamingBuckets.values.fold<int>(0, (sum, b) => sum + b.totalCount);

  List<String> get orderedStreamingKinds {
    final ordered = <String>[];
    for (final kind in StreamingManager.providerOrder) {
      if (_streamingBuckets.containsKey(kind)) {
        ordered.add(kind);
      }
    }
    for (final kind in _streamingBuckets.keys) {
      if (!ordered.contains(kind)) {
        ordered.add(kind);
      }
    }
    return ordered;
  }

  List<SearchTrackMatch> get visibleTracks {
    if (_selectedSource == 'local') {
      return [
        for (final t in _localTracks)
          SearchTrackMatch(track: t, sourceKind: 'local'),
      ];
    }
    if (_selectedSource != 'all') {
      final bucket = _streamingBuckets[_selectedSource];
      if (bucket == null) return const [];
      return [
        for (final t in bucket.tracks)
          SearchTrackMatch(track: t, sourceKind: bucket.providerKind),
      ];
    }
    final merged = <SearchTrackMatch>[
      for (final t in _localTracks)
        SearchTrackMatch(track: t, sourceKind: 'local'),
    ];
    for (final kind in orderedStreamingKinds) {
      final bucket = _streamingBuckets[kind]!;
      for (final t in bucket.tracks) {
        merged.add(SearchTrackMatch(track: t, sourceKind: kind));
      }
    }
    return merged;
  }

  List<SearchAlbumMatch> get visibleAlbums {
    if (_selectedSource == 'local') {
      return [
        for (final a in _localAlbums) SearchAlbumMatch.local(a),
      ];
    }
    if (_selectedSource != 'all') {
      final bucket = _streamingBuckets[_selectedSource];
      if (bucket == null) return const [];
      return [
        for (final a in bucket.albums) SearchAlbumMatch.streaming(a),
      ];
    }
    final merged = <SearchAlbumMatch>[
      for (final a in _localAlbums) SearchAlbumMatch.local(a),
    ];
    for (final kind in orderedStreamingKinds) {
      final bucket = _streamingBuckets[kind]!;
      for (final a in bucket.albums) {
        merged.add(SearchAlbumMatch.streaming(a));
      }
    }
    return merged;
  }

  List<SearchArtistMatch> get visibleArtists {
    if (_selectedSource == 'local') {
      return _localArtists;
    }
    if (_selectedSource != 'all') {
      return _streamingBuckets[_selectedSource]?.artists ?? const [];
    }

    final accByKey = <String, _MutableArtistAcc>{};
    void ingest(SearchArtistMatch artist) {
      final key = LibraryIndexCache.normalizeArtistKey(artist.name);
      if (key.isEmpty) return;
      final existing = accByKey[key];
      if (existing == null) {
        accByKey[key] = _MutableArtistAcc(
          name: artist.name,
          sourceKinds: List<String>.from(artist.sourceKinds),
          albumCount: artist.albumCount,
          trackCount: artist.trackCount,
          coverUrl: artist.coverUrl,
          representativeAlbum: artist.representativeAlbum,
          representativeTrack: artist.representativeTrack,
        );
      } else {
        for (final sk in artist.sourceKinds) {
          if (!existing.sourceKinds.contains(sk)) {
            existing.sourceKinds.add(sk);
          }
        }
        existing.albumCount += artist.albumCount;
        existing.trackCount += artist.trackCount;
        existing.coverUrl ??= artist.coverUrl;
        existing.representativeAlbum ??= artist.representativeAlbum;
        existing.representativeTrack ??= artist.representativeTrack;
      }
    }

    for (final a in _localArtists) {
      ingest(a);
    }
    for (final kind in orderedStreamingKinds) {
      for (final a in _streamingBuckets[kind]!.artists) {
        ingest(a);
      }
    }

    final lower = _query.toLowerCase();
    final list = accByKey.values.map((a) => a.build()).toList();
    list.sort((a, b) {
      final aMatch = a.name.toLowerCase().contains(lower);
      final bMatch = b.name.toLowerCase().contains(lower);
      if (aMatch != bMatch) return aMatch ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  List<({String kind, String name, String error})> get visibleErrors {
    final out = <({String kind, String name, String error})>[];
    if (_selectedSource == 'local') return out;
    final kinds = _selectedSource == 'all'
        ? orderedStreamingKinds
        : <String>[_selectedSource];
    for (final kind in kinds) {
      final bucket = _streamingBuckets[kind];
      if (bucket != null && bucket.hasError) {
        final name = StreamingProviderMeta.byKind(kind)?.name ?? kind;
        out.add((kind: kind, name: name, error: bucket.error!));
      }
    }
    return out;
  }

  void selectSource(String source) {
    if (_selectedSource == source) return;
    if (source != 'all' &&
        source != 'local' &&
        !_streamingBuckets.containsKey(source)) {
      return;
    }
    _selectedSource = source;
    _safeNotify();
  }

  void clear() {
    _debounce?.cancel();
    _debounce = null;
    _activeCancel?.cancel();
    _activeCancel = null;
    _requestId++;
    _query = '';
    _selectedSource = 'all';
    _clearResultsState();
    _safeNotify();
  }

  void updateQuery(String raw, {bool immediate = false}) {
    final trimmed = raw.trim();
    _debounce?.cancel();
    _debounce = null;
    _activeCancel?.cancel();
    _activeCancel = null;
    final reqId = ++_requestId;
    _query = trimmed;

    if (trimmed.isEmpty) {
      _clearResultsState();
      _safeNotify();
      return;
    }

    if (immediate) {
      _runSearch(trimmed, reqId);
      return;
    }

    _debounce = Timer(debounceDuration, () {
      if (_disposed || reqId != _requestId) return;
      _runSearch(trimmed, reqId);
    });
  }

  void _clearResultsState() {
    _isSearchingLocal = false;
    _localTracks = const [];
    _localAlbums = const [];
    _localArtists = const [];
    _streamingBuckets = const {};
  }

  void _runSearch(String query, int reqId) {
    if (_disposed || reqId != _requestId) return;
    final token = CancellationToken();
    _activeCancel = token;

    final lower = query.toLowerCase();

    // 1. Instant local album & artist filtering from synchronous LibraryIndexCache.
    _localAlbums = List<CanonicalAlbumSummary>.unmodifiable(
      libraryCache.albums.where((album) {
        if (album.id.startsWith('streaming:')) return false;
        return album.title.toLowerCase().contains(lower) ||
            album.artist.toLowerCase().contains(lower) ||
            (album.albumArtist?.toLowerCase().contains(lower) ?? false);
      }),
    );

    _localArtists = List<SearchArtistMatch>.unmodifiable(
      libraryCache.artists
          .where((artist) => artist.displayName.toLowerCase().contains(lower))
          .map(
            (artist) => SearchArtistMatch(
              name: artist.displayName,
              sourceKinds: const ['local'],
              albumCount: artist.albumCount,
              trackCount: artist.trackCount,
              coverUrl: artist.representativeAlbum?.coverUrl ??
                  artist.representativeTrack?.coverUrl ??
                  artist.representativeTrack?.albumArtUrl,
              representativeAlbum: artist.representativeAlbum,
              representativeTrack: artist.representativeTrack,
            ),
          ),
    );

    // Pre-seed instant local track matches from in-memory queue so frame-0 has
    // immediate tracks even before async searchLibrary resolves.
    _localTracks = List<TrackInfo>.unmodifiable(
      _filterExcludedTracks(
        audioService.queue.where(
          (t) =>
              t.title.toLowerCase().contains(lower) ||
              t.artist.toLowerCase().contains(lower) ||
              t.album.toLowerCase().contains(lower),
        ),
      ),
    );
    _isSearchingLocal = true;

    // 2. Initialize streaming buckets in loading state for all browsable providers
    //    (connected providers plus guest-mode providers such as YouTube Music).
    final browsable = streamingManager.browsableProviders;
    final initialBuckets = <String, ProviderSearchBucket>{};
    for (final provider in browsable) {
      initialBuckets[provider.kind] = ProviderSearchBucket(
        providerKind: provider.kind,
        isLoading: true,
      );
    }
    _streamingBuckets = initialBuckets;

    if (_selectedSource != 'all' &&
        _selectedSource != 'local' &&
        !_streamingBuckets.containsKey(_selectedSource)) {
      _selectedSource = 'all';
    }

    _safeNotify();

    // 3. Authoritative async local library search (Rust FFI / AudioService).
    unawaited(() async {
      try {
        final results = await audioService.searchLibrary(query);
        if (reqId != _requestId || token.isCancelled || _disposed) return;
        _localTracks = List<TrackInfo>.unmodifiable(
          _filterExcludedTracks(results),
        );
        _isSearchingLocal = false;
        _safeNotify();
      } catch (_) {
        if (reqId != _requestId || token.isCancelled || _disposed) return;
        _isSearchingLocal = false;
        _safeNotify();
      }
    }());

    // 4. Parallel non-blocking streaming queries with per-provider timeout & isolation.
    for (final provider in browsable) {
      final kind = provider.kind;
      final providerCancel = CancellationToken();
      void forwardCancel() => providerCancel.cancel();
      token.addListener(forwardCancel);

      unawaited(() async {
        try {
          final catalog = await streamingManager
              .searchProvider(kind, query, cancel: providerCancel)
              .timeout(streamingTimeout);
          if (reqId != _requestId || token.isCancelled || _disposed) return;

          final artists = _extractArtistsFromCatalog(kind, catalog, lower);
          _streamingBuckets = <String, ProviderSearchBucket>{
            ..._streamingBuckets,
            kind: ProviderSearchBucket(
              providerKind: kind,
              tracks: List<TrackInfo>.unmodifiable(catalog.tracks),
              albums: List<StreamingAlbum>.unmodifiable(catalog.albums),
              artists: List<SearchArtistMatch>.unmodifiable(artists),
              isLoading: false,
            ),
          };
          _safeNotify();
        } on TimeoutException {
          providerCancel.cancel();
          if (reqId != _requestId || token.isCancelled || _disposed) return;
          _streamingBuckets = <String, ProviderSearchBucket>{
            ..._streamingBuckets,
            kind: ProviderSearchBucket(
              providerKind: kind,
              isLoading: false,
              error: '搜尋逾時（超過 ${streamingTimeout.inSeconds} 秒）',
            ),
          };
          _safeNotify();
        } on StreamingException catch (e) {
          if (e.isCancelled ||
              reqId != _requestId ||
              token.isCancelled ||
              _disposed) {
            return;
          }
          _streamingBuckets = <String, ProviderSearchBucket>{
            ..._streamingBuckets,
            kind: ProviderSearchBucket(
              providerKind: kind,
              isLoading: false,
              error: e.message,
            ),
          };
          _safeNotify();
        } catch (e) {
          if (reqId != _requestId || token.isCancelled || _disposed) return;
          _streamingBuckets = <String, ProviderSearchBucket>{
            ..._streamingBuckets,
            kind: ProviderSearchBucket(
              providerKind: kind,
              isLoading: false,
              error: e.toString(),
            ),
          };
          _safeNotify();
        } finally {
          token.removeListener(forwardCancel);
        }
      }());
    }
  }

  Iterable<TrackInfo> _filterExcludedTracks(Iterable<TrackInfo> tracks) {
    final settings = librarySettings;
    if (settings == null || settings.excludedExtensions.isEmpty) {
      return tracks;
    }
    return tracks.where(
      (t) => !settings.isTrackExcluded(t.filePath, t.format.codec.name),
    );
  }

  List<SearchArtistMatch> _extractArtistsFromCatalog(
    String kind,
    StreamingCatalog catalog,
    String lowerQuery,
  ) {
    final accByKey = <String, _MutableArtistAcc>{};

    bool isPlaceholderArtist(String name) {
      final lower = name.toLowerCase();
      return lower.isEmpty ||
          lower == '未知藝術家' ||
          lower == 'unknown artist';
    }

    _MutableArtistAcc ensureArtist(String rawName) {
      final trimmed = rawName.trim();
      final key = LibraryIndexCache.normalizeArtistKey(trimmed);
      return accByKey.putIfAbsent(
        key,
        () => _MutableArtistAcc(
          name: trimmed,
          sourceKinds: <String>[kind],
        ),
      );
    }

    for (final album in catalog.albums) {
      final name = album.artist.trim();
      if (isPlaceholderArtist(name)) continue;
      final acc = ensureArtist(name);
      acc.albumCount++;
      acc.coverUrl ??= album.coverUrl;
      acc.representativeAlbum ??= CanonicalAlbumSummary(
        id: 'streaming:${album.providerKind}:${album.id}',
        title: album.title,
        artist: album.artist,
        year: album.year,
        availableProviders: <String>[album.providerKind],
        coverUrl: album.coverUrl,
      );
    }

    for (final track in catalog.tracks) {
      final name = track.artist.trim();
      if (isPlaceholderArtist(name)) continue;
      final acc = ensureArtist(name);
      acc.trackCount++;
      acc.coverUrl ??= track.coverUrl ?? track.albumArtUrl;
      acc.representativeTrack ??= track;
    }

    final artists = accByKey.values.map((a) => a.build()).toList();
    artists.sort((a, b) {
      final aMatch = a.name.toLowerCase().contains(lowerQuery);
      final bMatch = b.name.toLowerCase().contains(lowerQuery);
      if (aMatch != bMatch) return aMatch ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return artists;
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    _activeCancel?.cancel();
    _activeCancel = null;
    super.dispose();
  }
}

class _MutableArtistAcc {
  final String name;
  final List<String> sourceKinds;
  int albumCount;
  int trackCount;
  String? coverUrl;
  CanonicalAlbumSummary? representativeAlbum;
  TrackInfo? representativeTrack;

  _MutableArtistAcc({
    required this.name,
    required this.sourceKinds,
    this.albumCount = 0,
    this.trackCount = 0,
    this.coverUrl,
    this.representativeAlbum,
    this.representativeTrack,
  });

  SearchArtistMatch build() => SearchArtistMatch(
    name: name,
    sourceKinds: List<String>.unmodifiable(sourceKinds),
    albumCount: albumCount,
    trackCount: trackCount,
    coverUrl: coverUrl,
    representativeAlbum: representativeAlbum,
    representativeTrack: representativeTrack,
  );
}
