part of '../library_index_cache.dart';

extension _LibraryIndexGroupingExt on LibraryIndexCache {
  Future<void> _setIncludeHiddenImpl(
    AudioService audioService,
    bool includeHidden,
  ) {
    if (_includeHidden == includeHidden && _isPrimed) {
      return Future<void>.value();
    }
    _includeHidden = includeHidden;
    return refresh(audioService);
  }

  void _rebuildIndexImpl({
    required List<CanonicalAlbumSummary> albums,
    required List<TrackInfo> tracks,
  }) {
    _albumsById.clear();
    _albumByNormalizedTitle.clear();
    _albumByNormalizedTitleAndArtist.clear();

    final seenKeys = <String>{};
    final dedupedAlbums = <CanonicalAlbumSummary>[];
    for (final album in albums) {
      if (!LibraryIndexCache._isValidSummary(album)) continue;
      final rowKey = _includeHidden ? album.selectionKey : album.effectiveGroupId;
      if (seenKeys.add(rowKey)) {
        dedupedAlbums.add(album);
      }
      final existing = _albumsById[album.effectiveGroupId];
      if (existing == null || (!existing.isPrimary && album.isPrimary)) {
        _albumsById[album.effectiveGroupId] = album;
      }

      final titleKey = LibraryIndexCache._normalizeTitleKey(album.title);
      if (titleKey.isNotEmpty) {
        _albumByNormalizedTitle.putIfAbsent(titleKey, () => album);
        final artistKey = LibraryIndexCache.normalizeArtistKey(album.artist);
        if (artistKey.isNotEmpty) {
          _albumByNormalizedTitleAndArtist.putIfAbsent(
            '$artistKey|$titleKey',
            () => album,
          );
        }
        final aaKey =
            LibraryIndexCache.normalizeArtistKey(album.albumArtist ?? '');
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
      final key = LibraryIndexCache.normalizeArtistKey(rawName);
      if (key.isNotEmpty) {
        displayNames.putIfAbsent(key, () => rawName);
        tracksByArtist.putIfAbsent(key, () => []).add(track);
      }
    }

    for (final album in _albumsById.values) {
      final primaryName = album.artist.trim();
      final primaryKey = LibraryIndexCache.normalizeArtistKey(primaryName);
      if (primaryKey.isNotEmpty) {
        displayNames.putIfAbsent(primaryKey, () => primaryName);
        albumsByArtist.putIfAbsent(primaryKey, () => {})[album.effectiveGroupId] =
            album;
      }
      final aaName = (album.albumArtist ?? '').trim();
      final aaKey = LibraryIndexCache.normalizeArtistKey(aaName);
      if (aaKey.isNotEmpty && aaKey != primaryKey) {
        displayNames.putIfAbsent(aaKey, () => aaName);
        albumsByArtist.putIfAbsent(aaKey, () => {})[album.effectiveGroupId] =
            album;
      }
    }

    final previousArtists = Map<String, ArtistIndexEntry>.from(_artistsByKey);
    _artistsByKey.clear();
    final allKeys = <String>{
      ...tracksByArtist.keys,
      ...albumsByArtist.keys,
    };

    for (final key in allKeys) {
      final artistAlbums =
          (albumsByArtist[key]?.values.toList() ?? <CanonicalAlbumSummary>[])
            ..sort(LibraryIndexCache.compareAlbumsNewestFirst);
      final artistTracks = List<TrackInfo>.unmodifiable(
        tracksByArtist[key] ?? const <TrackInfo>[],
      );
      final repAlbum = _pickRepresentativeAlbum(artistAlbums);
      final repTrack = _pickRepresentativeTrack(artistTracks);
      final prev = previousArtists[key];
      _artistsByKey[key] = ArtistIndexEntry(
        key: key,
        displayName: displayNames[key] ?? key,
        artistId: prev?.artistId,
        preference: prev?.preference ?? 0,
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
}
