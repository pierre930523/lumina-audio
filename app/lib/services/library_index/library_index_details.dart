part of '../library_index_cache.dart';

extension _LibraryIndexDetailsExt on LibraryIndexCache {
  void _evictAlbumByIdImpl(String albumId) {
    if (albumId.isEmpty) return;
    final removedDetail = _albumDetailsById.remove(albumId) != null;
    final removedSummary = _albumsById.remove(albumId) != null;
    if (removedSummary) {
      _orderedAlbums = List.unmodifiable(
        _orderedAlbums.where((a) => a.id != albumId),
      );
    }
    if (removedDetail || removedSummary) {
      _notifyCacheChanged();
    }
  }

  void _putAlbumDetailSyncImpl(CanonicalAlbumDetail detail) {
    final sanitized = LibraryIndexCache._filterEmptyVersions(detail);
    final trackCount = LibraryIndexCache._countTracks(sanitized);
    if (sanitized.versions.isEmpty || trackCount <= 0) {
      _evictAlbumByIdImpl(sanitized.id);
      return;
    }
    _albumDetailsById[sanitized.id] = sanitized;
    if (!_albumsById.containsKey(sanitized.id)) {
      _albumsById[sanitized.id] = CanonicalAlbumSummary(
        id: sanitized.id,
        title: sanitized.title,
        artist: sanitized.artistName,
        year: sanitized.releaseYear,
        coverUrl: sanitized.coverUrl,
        trackCount: trackCount,
        preference: sanitized.preference,
      );
    }
    _notifyCacheChanged();
  }

  void _putArtistDetailSyncImpl(ArtistDetailInfo detail) {
    final key = LibraryIndexCache.normalizeArtistKey(detail.name);
    if (key.isEmpty) return;
    final existing = _artistsByKey[key];
    final nextEntry = ArtistIndexEntry(
      key: key,
      displayName: existing?.displayName ?? detail.name,
      artistId: detail.id.isNotEmpty ? detail.id : existing?.artistId,
      preference: detail.preference,
      albums: existing?.albums ?? detail.albums,
      tracks: existing?.tracks ?? const <TrackInfo>[],
      representativeAlbum: existing?.representativeAlbum ??
          (detail.albums.isNotEmpty ? detail.albums.first : null),
      representativeTrack: existing?.representativeTrack,
    );
    _artistsByKey[key] = nextEntry;
    _orderedArtists = List.unmodifiable(
      _artistsByKey.values.toList()
        ..sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        ),
    );
    _notifyCacheChanged();
  }

  static CanonicalAlbumSummary _withAlbumPreference(
    CanonicalAlbumSummary a,
    int preference,
  ) => CanonicalAlbumSummary(
    id: a.id,
    groupId: a.groupId,
    versionId: a.versionId,
    primaryVersionId: a.primaryVersionId,
    title: a.title,
    artist: a.artist,
    year: a.year,
    availableProviders: a.availableProviders,
    albumArtist: a.albumArtist,
    coverUrl: a.coverUrl,
    trackCount: a.trackCount,
    discCount: a.discCount,
    versionCount: a.versionCount,
    hiddenVersionCount: a.hiddenVersionCount,
    totalVersionCount: a.totalVersionCount,
    isPrimary: a.isPrimary,
    isPrimaryLocked: a.isPrimaryLocked,
    isHidden: a.isHidden,
    isManualGroup: a.isManualGroup,
    qualityScore: a.qualityScore,
    editionLabel: a.editionLabel,
    provider: a.provider,
    codec: a.codec,
    sampleRateHz: a.sampleRateHz,
    bitDepth: a.bitDepth,
    isDsd: a.isDsd,
    recordLabel: a.recordLabel,
    preference: preference,
  );

  void _updateEntityPreferenceSyncImpl(
    String entityType,
    String entityId,
    int preference,
  ) {
    var changed = false;
    if (entityType == 'album' || entityType == 'album_group') {
      final summary = _albumsById[entityId];
      if (summary != null) {
        _albumsById[entityId] = _withAlbumPreference(summary, preference);
        _orderedAlbums = List.unmodifiable(
          _orderedAlbums.map(
            (a) => (a.id == entityId || a.effectiveGroupId == entityId)
                ? _withAlbumPreference(a, preference)
                : a,
          ),
        );
        changed = true;
      }
      final detail = _albumDetailsById[entityId];
      if (detail != null) {
        _albumDetailsById[entityId] = detail.copyWith(preference: preference);
        changed = true;
      }
    } else if (entityType == 'artist') {
      final normId = LibraryIndexCache.normalizeArtistKey(entityId);
      for (final entry in _artistsByKey.entries.toList()) {
        final v = entry.value;
        if (v.artistId == entityId || v.key == normId) {
          _artistsByKey[entry.key] = ArtistIndexEntry(
            key: v.key,
            displayName: v.displayName,
            artistId: v.artistId ?? entityId,
            preference: preference,
            albums: v.albums,
            tracks: v.tracks,
            representativeAlbum: v.representativeAlbum,
            representativeTrack: v.representativeTrack,
          );
          changed = true;
        }
      }
      if (changed) {
        _orderedArtists = List.unmodifiable(
          _artistsByKey.values.toList()
            ..sort(
              (a, b) => a.displayName.toLowerCase().compareTo(
                b.displayName.toLowerCase(),
              ),
            ),
        );
      }
    }
    if (changed) {
      _notifyCacheChanged();
    }
  }

  Future<CanonicalAlbumDetail?> _loadAlbumDetailImpl(
    AudioService audioService,
    String albumId, {
    bool forceRefresh = false,
  }) {
    if (!forceRefresh) {
      final cached = _albumDetailsById[albumId];
      if (cached != null) return Future.value(cached);
    }

    final existing = _inFlightAlbumDetails[albumId];
    if (!forceRefresh && existing != null) return existing;

    final gen = _refreshGeneration;
    final future = audioService
        .getAlbumDetailFiltered(albumId, includeHidden: _includeHidden)
        .then((detail) {
          if (detail != null) {
            final sanitized = LibraryIndexCache._filterEmptyVersions(detail);
            final trackCount = LibraryIndexCache._countTracks(sanitized);
            if (sanitized.versions.isEmpty || trackCount <= 0) {
              if (gen == _refreshGeneration) {
                _evictAlbumByIdImpl(albumId);
              }
              return null;
            }
            if (gen == _refreshGeneration) {
              _albumDetailsById[albumId] = sanitized;
              _albumsById.putIfAbsent(
                albumId,
                () => CanonicalAlbumSummary(
                  id: sanitized.id,
                  title: sanitized.title,
                  artist: sanitized.artistName,
                  year: sanitized.releaseYear,
                  coverUrl: sanitized.coverUrl,
                  trackCount: trackCount,
                  preference: sanitized.preference,
                ),
              );
              _notifyCacheChanged();
            }
            return sanitized;
          }
          return null;
        })
        .whenComplete(() {
          if (gen == _refreshGeneration) {
            _inFlightAlbumDetails.remove(albumId);
          }
        });

    _inFlightAlbumDetails[albumId] = future;
    return future;
  }
}
