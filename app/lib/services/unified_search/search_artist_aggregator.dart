part of '../unified_search_controller.dart';

extension _UnifiedSearchArtistAggregator on UnifiedSearchController {
  List<SearchArtistMatch> _mergeVisibleArtists() {
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
