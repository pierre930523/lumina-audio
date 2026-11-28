part of '../mock_audio_service.dart';

class _MockTagRecord {
  String id;
  String name;
  String? color;
  String createdAt;
  String updatedAt;

  _MockTagRecord({
    required this.id,
    required this.name,
    this.color,
    required this.createdAt,
    required this.updatedAt,
  });
}

class _MockFolderRecord {
  final FolderNode node;
  final List<String> directTrackIds;

  const _MockFolderRecord({
    required this.node,
    this.directTrackIds = const <String>[],
  });
}

class _MockFocusTagsFoldersStore {
  final Map<String, _MockTagRecord> tags = <String, _MockTagRecord>{};
  final Set<(String, String)> tagLinks = <(String, String)>{};
  final Set<(String, TagEntityType, String)> tagItems =
      <(String, TagEntityType, String)>{};
  final Map<String, _MockFolderRecord> folders = <String, _MockFolderRecord>{};
  int tagSeq = 100;

  _MockFocusTagsFoldersStore() {
    _seedDefaults();
  }

  void _seedDefaults() {
    const now = '2026-01-01T00:00:00Z';
    tags['tag-audiophile'] = _MockTagRecord(
      id: 'tag-audiophile',
      name: '發燒試音',
      color: '#E5C158',
      createdAt: now,
      updatedAt: now,
    );
    tags['tag-late-night'] = _MockTagRecord(
      id: 'tag-late-night',
      name: '深夜聆聽',
      color: '#7B92F8',
      createdAt: now,
      updatedAt: now,
    );
    tags['tag-classic-rock'] = _MockTagRecord(
      id: 'tag-classic-rock',
      name: '經典搖滾',
      color: '#A855F7',
      createdAt: now,
      updatedAt: now,
    );
    tagLinks.add(('tag-audiophile', 'tag-late-night'));
    tagItems.addAll(const [
      ('tag-audiophile', TagEntityType.albumGroup, 'alb-dsotm'),
      ('tag-late-night', TagEntityType.track, 'trk-001'),
      ('tag-classic-rock', TagEntityType.albumGroup, 'alb-wall'),
    ]);

    folders['fld-root-music'] = const _MockFolderRecord(
      node: FolderNode(
        id: 'fld-root-music',
        rootId: 'root-music',
        name: 'Music',
        normPath: 'd:/music',
        displayPath: r'D:\Music',
        depth: 0,
        directTrackCount: 0,
        recursiveTrackCount: 3,
        isOnline: true,
      ),
    );
    folders['fld-pink-floyd'] = const _MockFolderRecord(
      node: FolderNode(
        id: 'fld-pink-floyd',
        rootId: 'root-music',
        parentId: 'fld-root-music',
        name: 'Pink Floyd',
        normPath: 'd:/music/pink floyd',
        displayPath: r'D:\Music\Pink Floyd',
        depth: 1,
        directTrackCount: 0,
        recursiveTrackCount: 3,
        isOnline: true,
      ),
    );
    folders['fld-dsotm'] = const _MockFolderRecord(
      node: FolderNode(
        id: 'fld-dsotm',
        rootId: 'root-music',
        parentId: 'fld-pink-floyd',
        name: 'The Dark Side of the Moon',
        normPath: 'd:/music/pink floyd/the dark side of the moon',
        displayPath: r'D:\Music\Pink Floyd\The Dark Side of the Moon',
        depth: 2,
        directTrackCount: 2,
        recursiveTrackCount: 2,
        isOnline: true,
      ),
      directTrackIds: <String>['trk-001', 'trk-002'],
    );
    folders['fld-wall'] = const _MockFolderRecord(
      node: FolderNode(
        id: 'fld-wall',
        rootId: 'root-music',
        parentId: 'fld-pink-floyd',
        name: 'The Wall',
        normPath: 'd:/music/pink floyd/the wall',
        displayPath: r'D:\Music\Pink Floyd\The Wall',
        depth: 2,
        directTrackCount: 1,
        recursiveTrackCount: 1,
        isOnline: true,
      ),
      directTrackIds: <String>['trk-003'],
    );
  }

  /// Returns [rootTagId] plus all transitive child tag IDs (cycle-safe).
  Set<String> descendantTagIds(String rootTagId) {
    final visited = <String>{};
    final queue = <String>[rootTagId];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (!visited.add(current)) continue;
      for (final (parentId, childId) in tagLinks) {
        if (parentId == current && !visited.contains(childId)) {
          queue.add(childId);
        }
      }
    }
    return visited;
  }

  bool wouldCreateCycle(String parentId, String childId) {
    if (parentId == childId) return true;
    return descendantTagIds(childId).contains(parentId);
  }

  TagSummary toSummary(String tagId) {
    final rec = tags[tagId]!;
    final parentIds = tagLinks
        .where((e) => e.$2 == tagId)
        .map((e) => e.$1)
        .toList()
      ..sort();
    final childIds = tagLinks
        .where((e) => e.$1 == tagId)
        .map((e) => e.$2)
        .toList()
      ..sort();
    final direct = tagItems
        .where((e) => e.$1 == tagId)
        .map((e) => (e.$2, e.$3))
        .toSet();
    final subtree = descendantTagIds(tagId);
    final recursive = tagItems
        .where((e) => subtree.contains(e.$1))
        .map((e) => (e.$2, e.$3))
        .toSet();
    return TagSummary(
      id: rec.id,
      name: rec.name,
      color: rec.color,
      parentIds: parentIds,
      childIds: childIds,
      directItemCount: direct.length,
      recursiveItemCount: recursive.length,
      createdAt: rec.createdAt,
      updatedAt: rec.updatedAt,
    );
  }

  List<TagSummary> listSummaries() {
    final list = tags.keys.map(toSummary).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<FolderBreadcrumb> buildBreadcrumbs(String folderId) {
    final trail = <FolderBreadcrumb>[];
    String? cur = folderId;
    final seen = <String>{};
    while (cur != null && cur.isNotEmpty && seen.add(cur)) {
      final rec = folders[cur];
      if (rec == null) break;
      trail.add(
        FolderBreadcrumb(
          id: rec.node.id,
          name: rec.node.name,
          displayPath: rec.node.displayPath,
        ),
      );
      cur = rec.node.parentId;
    }
    return trail.reversed.toList(growable: false);
  }

  List<String> recursiveTrackIds(String folderId) {
    final result = <String>[];
    final seenFolders = <String>{};
    void visit(String id) {
      if (!seenFolders.add(id)) return;
      final rec = folders[id];
      if (rec == null) return;
      result.addAll(rec.directTrackIds);
      final children = folders.values
          .where((f) => f.node.parentId == id)
          .toList()
        ..sort(
          (a, b) => a.node.name.toLowerCase().compareTo(
            b.node.name.toLowerCase(),
          ),
        );
      for (final c in children) {
        visit(c.node.id);
      }
    }

    visit(folderId);
    return result;
  }
}

bool _mockMatchesFocusPredicates<T>(
  T item,
  List<FocusPredicate> predicates,
  bool Function(T item, FocusPredicate predicate) matchSingle,
) {
  if (predicates.isEmpty) return true;
  final includesByFacet = <FocusFacet, List<FocusPredicate>>{};
  final excludes = <FocusPredicate>[];
  for (final p in predicates) {
    if (p.mode == FocusPredicateMode.exclude) {
      excludes.add(p);
    } else {
      includesByFacet.putIfAbsent(p.facet, () => <FocusPredicate>[]).add(p);
    }
  }
  for (final group in includesByFacet.values) {
    if (!group.any((p) => matchSingle(item, p))) return false;
  }
  for (final ex in excludes) {
    if (matchSingle(item, ex)) return false;
  }
  return true;
}

bool _mockMatchIntRange(int? actual, FocusValue val) {
  if (actual == null) return false;
  return switch (val) {
    FocusIntValue(:final value) => actual == value,
    FocusStringValue(:final value) => actual.toString() == value.trim(),
    FocusIntRangeValue(:final min, :final max) =>
      (min == null || actual >= min) && (max == null || actual <= max),
    FocusDateRangeValue() => false,
  };
}

String _mockStringValue(FocusValue val) => switch (val) {
  FocusStringValue(:final value) => value.trim(),
  FocusIntValue(:final value) => value.toString(),
  _ => '',
};

List<FocusFacetBucket> _mockSortedBuckets(
  Map<String, (String label, int count)> raw,
) {
  final buckets = raw.entries
      .where((e) => e.key.isNotEmpty && e.value.$2 > 0)
      .map(
        (e) => FocusFacetBucket(
          value: e.key,
          label: e.value.$1,
          count: e.value.$2,
        ),
      )
      .toList()
    ..sort((a, b) {
      final c = b.count.compareTo(a.count);
      return c != 0 ? c : a.label.compareTo(b.label);
    });
  return buckets;
}

List<CanonicalAlbumSummary> _mockSortAlbums(
  List<CanonicalAlbumSummary> list,
  FocusSort? sort,
) {
  final items = List<CanonicalAlbumSummary>.from(list);
  if (sort == null) return items;
  if (sort.field == FocusSortField.random) {
    items.shuffle(math.Random(sort.seed ?? 42));
    return items;
  }
  final mult = sort.direction == FocusSortDirection.desc ? -1 : 1;
  items.sort((a, b) {
    final cmp = switch (sort.field) {
      FocusSortField.title => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      FocusSortField.artist => a.artist.toLowerCase().compareTo(
        b.artist.toLowerCase(),
      ),
      FocusSortField.releaseYear => (a.year ?? 0).compareTo(b.year ?? 0),
      FocusSortField.sampleRate => (a.sampleRateHz ?? 0).compareTo(
        b.sampleRateHz ?? 0,
      ),
      FocusSortField.addedAt || FocusSortField.duration => a.id.compareTo(b.id),
      FocusSortField.random => 0,
    };
    return cmp * mult;
  });
  return items;
}

List<TrackInfo> _mockSortTracks(List<TrackInfo> list, FocusSort? sort) {
  final items = List<TrackInfo>.from(list);
  if (sort == null) return items;
  if (sort.field == FocusSortField.random) {
    items.shuffle(math.Random(sort.seed ?? 42));
    return items;
  }
  final mult = sort.direction == FocusSortDirection.desc ? -1 : 1;
  items.sort((a, b) {
    final cmp = switch (sort.field) {
      FocusSortField.title => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      FocusSortField.artist => a.artist.toLowerCase().compareTo(
        b.artist.toLowerCase(),
      ),
      FocusSortField.releaseYear => (a.year ?? 0).compareTo(b.year ?? 0),
      FocusSortField.sampleRate => a.format.sampleRateHz.compareTo(
        b.format.sampleRateHz,
      ),
      FocusSortField.duration => a.duration.compareTo(b.duration),
      FocusSortField.addedAt => a.id.compareTo(b.id),
      FocusSortField.random => 0,
    };
    return cmp * mult;
  });
  return items;
}
