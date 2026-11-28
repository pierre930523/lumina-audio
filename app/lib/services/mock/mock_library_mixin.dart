part of '../mock_audio_service.dart';

mixin _MockLibraryMixin on _MockAudioServiceBase, _MockAlbumGroupingMixin {
  @override
  Future<int> scanDirectory(String path) async => _queue.length;

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return List<TrackInfo>.from(_queue);
    }
    return _queue
        .where(
          (t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q) ||
              t.album.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async =>
      _buildMockAlbumSummaries(limit: limit, includeHidden: includeHidden);

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    final key = 'album:$albumId';
    final overrides = _metadataOverrides[key];
    final userEdits = _entityUserEdits[key];
    final fileMeta = _entityFileMeta[key];
    final cloudMeta = _entityCloudMeta[key];
    final metaPolicy = _entityMetaPolicies[key] ?? MetadataPolicy.inherit;
    final effectivePolicy = metaPolicy == MetadataPolicy.inherit
        ? _defaultMetadataPolicy
        : metaPolicy;

    String? readMapString(Map<String, dynamic>? map, String field) {
      final v = map?[field];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      return null;
    }

    String? overrideString(String field) {
      final fromUser = readMapString(userEdits, field);
      if (fromUser != null) return fromUser;
      final raw = overrides?[field]?.valueJson;
      if (raw == null || raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is String && decoded.trim().isNotEmpty) {
          return decoded.trim();
        }
      } catch (_) {}
      return null;
    }

    String resolveString(String field, String fallback) {
      final edited = overrideString(field);
      if (edited != null) return edited;
      final primary = effectivePolicy == MetadataPolicy.cloud
          ? readMapString(cloudMeta, field)
          : readMapString(fileMeta, field);
      if (primary != null) return primary;
      final secondary = effectivePolicy == MetadataPolicy.cloud
          ? readMapString(fileMeta, field)
          : readMapString(cloudMeta, field);
      return secondary ?? fallback;
    }

    final hasUserEdits =
        (userEdits != null && userEdits.isNotEmpty) ||
        (overrides != null && overrides.isNotEmpty);

    final store = _ensureAlbumGroups();
    final matched = store.where((g) => g.id == albumId).firstOrNull;
    if (matched != null) {
      _resolveMockPrimary(matched);
      if (matched.versions.isEmpty) return null;
      final hiddenCount = matched.versions.where((v) => v.isHidden).length;
      return CanonicalAlbumDetail(
        id: matched.id,
        title: resolveString('title', matched.title),
        artistName: resolveString('artist_name', matched.artistName),
        releaseYear: matched.releaseYear,
        editorialBio: matched.editorialBio,
        coverUrl: matched.coverUrl,
        metaPolicy: metaPolicy,
        hasUserEdits: hasUserEdits,
        primaryVersionId: matched.primaryVersionId,
        isPrimaryLocked: matched.isPrimaryLocked,
        hiddenVersionCount: hiddenCount,
        preference: matched.preference,
        versions: List<AlbumVersionInfo>.unmodifiable(matched.versions),
        credits: List<AlbumCreditInfo>.unmodifiable(matched.credits),
      );
    }

    // Fallback for arbitrary albumIds requested by legacy unit/widget tests
    final fallback = store.firstOrNull;
    if (fallback == null) return null;
    return CanonicalAlbumDetail(
      id: albumId,
      title: resolveString('title', fallback.title),
      artistName: resolveString('artist_name', fallback.artistName),
      releaseYear: fallback.releaseYear,
      editorialBio: fallback.editorialBio,
      coverUrl: fallback.coverUrl,
      metaPolicy: metaPolicy,
      hasUserEdits: hasUserEdits,
      primaryVersionId: fallback.primaryVersionId,
      isPrimaryLocked: fallback.isPrimaryLocked,
      hiddenVersionCount: fallback.versions.where((v) => v.isHidden).length,
      versions: List<AlbumVersionInfo>.unmodifiable(fallback.versions),
      credits: List<AlbumCreditInfo>.unmodifiable(fallback.credits),
    );
  }

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) async {
    return ArtistDetailInfo(
      id: artistId,
      name: artistId == 'art-ap' ? 'Alan Parsons' : 'Pink Floyd',
      sortName: artistId == 'art-ap' ? 'Parsons, Alan' : 'Pink Floyd',
      biography: '前衛搖滾傳奇與錄音室先驅。',
      preference: _mockArtistPreferences[artistId] ?? 0,
      albums: await getAlbums(),
      credits: const [
        AlbumCreditInfo(
          artistId: 'art-ap',
          artistName: 'Alan Parsons',
          role: '錄音工程師',
          albumId: 'alb-dsotm',
          albumTitle: 'The Dark Side of the Moon',
        ),
      ],
    );
  }

  @override
  Future<int> deduplicateLibrary() async => 1;

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) async =>
      {
        'albums_processed': 2,
        'albums_enriched': 2,
        'credits_added': 3,
      };
}
