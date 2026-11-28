part of '../mock_audio_service.dart';

mixin _MockFocusTagsFoldersMixin
    on _MockAudioServiceBase, _MockAlbumGroupingMixin {
  _MockFocusTagsFoldersStore? _focusStore;

  _MockFocusTagsFoldersStore get _ensureFocusStore =>
      _focusStore ??= _MockFocusTagsFoldersStore();

  @visibleForTesting
  void seedMockTags({
    required List<TagSummary> tags,
    Map<String, List<(TagEntityType, String)>> assignments = const {},
  }) {
    final s = _ensureFocusStore;
    s.tags.clear();
    s.tagLinks.clear();
    s.tagItems.clear();
    for (final t in tags) {
      s.tags[t.id] = _MockTagRecord(
        id: t.id,
        name: t.name,
        color: t.color,
        createdAt: t.createdAt,
        updatedAt: t.updatedAt,
      );
      for (final p in t.parentIds) {
        s.tagLinks.add((p, t.id));
      }
      for (final c in t.childIds) {
        s.tagLinks.add((t.id, c));
      }
    }
    for (final entry in assignments.entries) {
      for (final pair in entry.value) {
        s.tagItems.add((entry.key, pair.$1, pair.$2));
      }
    }
  }

  @visibleForTesting
  void seedMockFolders(Map<FolderNode, List<String>> folderTree) {
    final s = _ensureFocusStore;
    s.folders.clear();
    for (final entry in folderTree.entries) {
      s.folders[entry.key.id] = _MockFolderRecord(
        node: entry.key,
        directTrackIds: List<String>.from(entry.value),
      );
    }
  }

  Set<String> _effectiveAlbumTags(CanonicalAlbumSummary album) {
    final s = _ensureFocusStore;
    final ids = <String>{};
    for (final (tagId, et, eid) in s.tagItems) {
      if (et == TagEntityType.albumGroup &&
          (eid == album.effectiveGroupId || eid == album.id)) {
        ids.add(tagId);
      } else if (et == TagEntityType.artist &&
          eid.toLowerCase() == album.artist.toLowerCase()) {
        ids.add(tagId);
      }
    }
    return ids;
  }

  Set<String> _effectiveTrackTags(TrackInfo track) {
    final s = _ensureFocusStore;
    final ids = <String>{};
    final albumGroupIds = <String>{};
    for (final g in _ensureAlbumGroups()) {
      final hasTrack = g.versions.any(
        (v) => v.tracks.any((t) => t.id == track.id),
      );
      if (hasTrack ||
          track.album.toLowerCase().startsWith(g.title.toLowerCase())) {
        albumGroupIds.add(g.id);
      }
    }
    for (final (tagId, et, eid) in s.tagItems) {
      if (et == TagEntityType.track && eid == track.id) {
        ids.add(tagId);
      } else if (et == TagEntityType.albumGroup &&
          albumGroupIds.contains(eid)) {
        ids.add(tagId);
      } else if (et == TagEntityType.artist &&
          (eid == track.artistId ||
              eid.toLowerCase() == track.artist.toLowerCase())) {
        ids.add(tagId);
      }
    }
    return ids;
  }

  bool _matchAlbumPredicate(CanonicalAlbumSummary a, FocusPredicate p) {
    final strVal = _mockStringValue(p.value).toLowerCase();
    return switch (p.facet) {
      FocusFacet.format => (a.codec ?? '').toLowerCase() == strVal,
      FocusFacet.bitDepth => _mockMatchIntRange(a.bitDepth, p.value),
      FocusFacet.sampleRate => _mockMatchIntRange(a.sampleRateHz, p.value),
      FocusFacet.channels => _mockMatchIntRange(2, p.value),
      FocusFacet.source =>
        (a.provider ?? '').toLowerCase() == strVal ||
            a.availableProviders.any((pr) => pr.toLowerCase() == strVal),
      FocusFacet.releaseYear => _mockMatchIntRange(a.year, p.value),
      FocusFacet.addedAt => true,
      FocusFacet.playStatus => strVal == 'unplayed',
      FocusFacet.genre => false,
      FocusFacet.label =>
        (a.recordLabel ?? '').toLowerCase() == strVal && strVal.isNotEmpty,
      FocusFacet.tag => _effectiveAlbumTags(
        a,
      ).any(_ensureFocusStore.descendantTagIds(_mockStringValue(p.value)).contains),
      FocusFacet.inspector => switch (strVal) {
        'has_cover' => a.coverUrl != null && a.coverUrl!.isNotEmpty,
        'no_cover' => a.coverUrl == null || a.coverUrl!.isEmpty,
        'hidden' => a.isHidden,
        'multi_version' => a.totalVersionCount > 1,
        _ => false,
      },
      FocusFacet.preference => _mockMatchPreferenceValue(a.preference, p.value),
    };
  }

  bool _matchTrackPredicate(TrackInfo t, FocusPredicate p) {
    final strVal = _mockStringValue(p.value).toLowerCase();
    return switch (p.facet) {
      FocusFacet.format => _mockMatchTrackFormatValue(t, strVal),
      FocusFacet.bitDepth => _mockMatchIntRange(t.format.bitDepth, p.value),
      FocusFacet.sampleRate =>
        _mockMatchIntRange(t.format.sampleRateHz, p.value),
      FocusFacet.channels => _mockMatchIntRange(t.format.channels, p.value),
      FocusFacet.source => t.providerName.toLowerCase().contains(strVal),
      FocusFacet.releaseYear => _mockMatchIntRange(t.year, p.value),
      FocusFacet.addedAt => true,
      FocusFacet.playStatus => strVal == 'unplayed',
      FocusFacet.genre =>
        (t.genre ?? '').toLowerCase() == strVal && strVal.isNotEmpty,
      FocusFacet.label => false,
      FocusFacet.tag => _effectiveTrackTags(
        t,
      ).any(_ensureFocusStore.descendantTagIds(_mockStringValue(p.value)).contains),
      FocusFacet.inspector => switch (strVal) {
        'has_lyrics' => t.hasLyrics,
        'no_lyrics' => !t.hasLyrics,
        'has_cover' => t.artworkUrl != null,
        'no_cover' => t.artworkUrl == null,
        _ => false,
      },
      FocusFacet.preference => _mockMatchPreferenceValue(t.preference, p.value),
    };
  }

  @override
  Future<FocusQueryResponse> focusQuery(FocusQueryRequest request) async {
    final q = request.query;
    final limit = request.limit.clamp(1, 500);
    final offset = request.offset < 0 ? 0 : request.offset;
    if (q.entity == FocusEntity.tracks) {
      final filtered = _queue
          .where(
            (t) => _mockMatchesFocusPredicates(
              t,
              q.predicates,
              _matchTrackPredicate,
            ),
          )
          .toList();
      final sorted = _mockSortTracks(filtered, q.sort);
      final page = sorted.skip(offset).take(limit).toList(growable: false);
      return FocusQueryResponse(
        entity: FocusEntity.tracks,
        totalCount: sorted.length,
        limit: limit,
        offset: offset,
        tracks: page,
      );
    }
    final allAlbums = _buildMockAlbumSummaries(
      limit: 10000,
      includeHidden: q.includeHidden,
    );
    final filtered = allAlbums
        .where(
          (a) => _mockMatchesFocusPredicates(
            a,
            q.predicates,
            _matchAlbumPredicate,
          ),
        )
        .toList();
    final sorted = _mockSortAlbums(filtered, q.sort);
    final page = sorted.skip(offset).take(limit).toList(growable: false);
    return FocusQueryResponse(
      entity: FocusEntity.albums,
      totalCount: sorted.length,
      limit: limit,
      offset: offset,
      albums: page,
    );
  }

  @override
  Future<FocusFacetsResponse> focusFacets(FocusQuery query) async {
    final s = _ensureFocusStore;
    final facets = <String, List<FocusFacetBucket>>{};
    int? minYear;
    int? maxYear;

    if (query.entity == FocusEntity.tracks) {
      final matchedAll = _queue
          .where(
            (t) => _mockMatchesFocusPredicates(
              t,
              query.predicates,
              _matchTrackPredicate,
            ),
          )
          .toList();
      for (final t in matchedAll) {
        if (t.year != null) {
          minYear = minYear == null ? t.year : math.min(minYear, t.year!);
          maxYear = maxYear == null ? t.year : math.max(maxYear, t.year!);
        }
      }
      List<TrackInfo> withoutFacet(FocusFacet f) => _queue
          .where(
            (t) => _mockMatchesFocusPredicates(
              t,
              query.predicates.where((p) => p.facet != f).toList(),
              _matchTrackPredicate,
            ),
          )
          .toList();
      final formatMap = <String, (String, int)>{};
      for (final t in withoutFacet(FocusFacet.format)) {
        final k = t.format.codec.name.toLowerCase();
        formatMap[k] = (k.toUpperCase(), (formatMap[k]?.$2 ?? 0) + 1);
      }
      facets[FocusFacet.format.wireName] = _mockSortedBuckets(formatMap);
      final srMap = <String, (String, int)>{};
      for (final t in withoutFacet(FocusFacet.sampleRate)) {
        final k = t.format.sampleRateHz.toString();
        srMap[k] = (
          AudioFormat.formatSampleRateKhz(t.format.sampleRateHz),
          (srMap[k]?.$2 ?? 0) + 1,
        );
      }
      facets[FocusFacet.sampleRate.wireName] = _mockSortedBuckets(srMap);
      final tagMap = <String, (String, int)>{};
      final tagPool = withoutFacet(FocusFacet.tag);
      for (final tag in s.tags.values) {
        final desc = s.descendantTagIds(tag.id);
        final cnt = tagPool
            .where((t) => _effectiveTrackTags(t).any(desc.contains))
            .length;
        if (cnt > 0) tagMap[tag.id] = (tag.name, cnt);
      }
      facets[FocusFacet.tag.wireName] = _mockSortedBuckets(tagMap);
      return FocusFacetsResponse(
        totalMatched: matchedAll.length,
        facets: facets,
        yearRange: FocusIntRangeBounds(min: minYear, max: maxYear),
      );
    }

    final allAlbums = _buildMockAlbumSummaries(
      limit: 10000,
      includeHidden: query.includeHidden,
    );
    final matchedAll = allAlbums
        .where(
          (a) => _mockMatchesFocusPredicates(
            a,
            query.predicates,
            _matchAlbumPredicate,
          ),
        )
        .toList();
    for (final a in matchedAll) {
      if (a.year != null) {
        minYear = minYear == null ? a.year : math.min(minYear, a.year!);
        maxYear = maxYear == null ? a.year : math.max(maxYear, a.year!);
      }
    }
    List<CanonicalAlbumSummary> withoutFacet(FocusFacet f) => allAlbums
        .where(
          (a) => _mockMatchesFocusPredicates(
            a,
            query.predicates.where((p) => p.facet != f).toList(),
            _matchAlbumPredicate,
          ),
        )
        .toList();

    final formatMap = <String, (String, int)>{};
    for (final a in withoutFacet(FocusFacet.format)) {
      final k = (a.codec ?? '').toLowerCase();
      if (k.isNotEmpty) {
        formatMap[k] = (k.toUpperCase(), (formatMap[k]?.$2 ?? 0) + 1);
      }
    }
    facets[FocusFacet.format.wireName] = _mockSortedBuckets(formatMap);

    final srcMap = <String, (String, int)>{};
    for (final a in withoutFacet(FocusFacet.source)) {
      final k = (a.provider ?? 'local').toLowerCase();
      srcMap[k] = (k, (srcMap[k]?.$2 ?? 0) + 1);
    }
    facets[FocusFacet.source.wireName] = _mockSortedBuckets(srcMap);

    final tagMap = <String, (String, int)>{};
    final tagPool = withoutFacet(FocusFacet.tag);
    for (final tag in s.tags.values) {
      final desc = s.descendantTagIds(tag.id);
      final cnt = tagPool
          .where((a) => _effectiveAlbumTags(a).any(desc.contains))
          .length;
      if (cnt > 0) tagMap[tag.id] = (tag.name, cnt);
    }
    facets[FocusFacet.tag.wireName] = _mockSortedBuckets(tagMap);

    return FocusFacetsResponse(
      totalMatched: matchedAll.length,
      facets: facets,
      yearRange: FocusIntRangeBounds(min: minYear, max: maxYear),
    );
  }

  @override
  Future<List<TagSummary>> listTags() async => _ensureFocusStore.listSummaries();

  @override
  Future<TagSummary?> createTag(CreateTagRequest request) async {
    final trimmed = request.name.trim();
    if (trimmed.isEmpty) return null;
    final s = _ensureFocusStore;
    final norm = trimmed.toLowerCase();
    final dup = s.tags.values.any((t) => t.name.trim().toLowerCase() == norm);
    if (dup) return null;
    final id = 'tag-${++s.tagSeq}';
    final now = DateTime.now().toUtc().toIso8601String();
    s.tags[id] = _MockTagRecord(
      id: id,
      name: trimmed,
      color: request.color?.trim().isEmpty == true ? null : request.color?.trim(),
      createdAt: now,
      updatedAt: now,
    );
    return s.toSummary(id);
  }

  @override
  Future<TagSummary?> updateTag(UpdateTagRequest request) async {
    final s = _ensureFocusStore;
    final rec = s.tags[request.id];
    if (rec == null) return null;
    if (request.name != null) {
      final trimmed = request.name!.trim();
      if (trimmed.isEmpty) return null;
      final norm = trimmed.toLowerCase();
      final dup = s.tags.values.any(
        (t) => t.id != rec.id && t.name.trim().toLowerCase() == norm,
      );
      if (dup) return null;
      rec.name = trimmed;
    }
    if (request.clearColor) {
      rec.color = null;
    } else if (request.color != null) {
      rec.color = request.color!.trim();
    }
    rec.updatedAt = DateTime.now().toUtc().toIso8601String();
    return s.toSummary(rec.id);
  }

  @override
  Future<bool> deleteTag(String tagId) async {
    final s = _ensureFocusStore;
    if (!s.tags.containsKey(tagId)) return false;
    s.tags.remove(tagId);
    s.tagLinks.removeWhere((e) => e.$1 == tagId || e.$2 == tagId);
    s.tagItems.removeWhere((e) => e.$1 == tagId);
    return true;
  }

  @override
  Future<bool> linkTagParent(TagLinkRequest request) async {
    final s = _ensureFocusStore;
    if (!s.tags.containsKey(request.parentTagId) ||
        !s.tags.containsKey(request.childTagId)) {
      return false;
    }
    if (s.wouldCreateCycle(request.parentTagId, request.childTagId)) {
      return false;
    }
    s.tagLinks.add((request.parentTagId, request.childTagId));
    return true;
  }

  @override
  Future<bool> unlinkTagParent(TagLinkRequest request) async {
    final s = _ensureFocusStore;
    return s.tagLinks.remove((request.parentTagId, request.childTagId));
  }

  @override
  Future<BatchTagItemsResponse> batchTagItems(
    BatchTagItemsRequest request,
  ) async {
    final s = _ensureFocusStore;
    var affected = 0;
    for (final tagId in request.tagIds) {
      if (!s.tags.containsKey(tagId)) continue;
      for (final entityId in request.entityIds) {
        final key = (tagId, request.entityType, entityId);
        final changed = request.op == TagBatchOp.remove
            ? s.tagItems.remove(key)
            : s.tagItems.add(key);
        if (changed) affected++;
      }
    }
    return BatchTagItemsResponse(affected: affected);
  }

  @override
  Future<List<TagSummary>> getEntityTags(
    TagEntityType entityType,
    String entityId,
  ) async {
    final s = _ensureFocusStore;
    final tagIds = s.tagItems
        .where((e) => e.$2 == entityType && e.$3 == entityId)
        .map((e) => e.$1)
        .where(s.tags.containsKey)
        .toSet();
    final list = tagIds.map(s.toSummary).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  @override
  Future<List<FolderNode>> getFolderRoots() async {
    final s = _ensureFocusStore;
    final roots = s.folders.values
        .where((r) => r.node.parentId == null)
        .map((r) => r.node)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return roots;
  }

  @override
  Future<FolderContentsResponse?> getFolderContents(String folderId) async {
    final s = _ensureFocusStore;
    final rec = s.folders[folderId];
    if (rec == null) return null;
    final subs = s.folders.values
        .where((r) => r.node.parentId == folderId)
        .map((r) => r.node)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final tracks = rec.directTrackIds
        .map((id) => _queue.where((t) => t.id == id).firstOrNull)
        .whereType<TrackInfo>()
        .toList(growable: false);
    return FolderContentsResponse(
      folder: rec.node,
      breadcrumbs: s.buildBreadcrumbs(folderId),
      subfolders: subs,
      tracks: tracks,
    );
  }

  @override
  Future<List<String>> getFolderRecursiveTrackIds(String folderId) async {
    return _ensureFocusStore.recursiveTrackIds(folderId);
  }
}
