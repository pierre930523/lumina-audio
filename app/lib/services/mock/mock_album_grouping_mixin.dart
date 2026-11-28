part of '../mock_audio_service.dart';

mixin _MockAlbumGroupingMixin on _MockAudioServiceBase {
  List<_MockAlbumGroupEntry>? _albumGroupsStore;
  int _mockGroupSeq = 0;

  List<_MockAlbumGroupEntry> _ensureAlbumGroups() =>
      _albumGroupsStore ??= _createDefaultMockAlbumGroups();

  @visibleForTesting
  void seedAlbumGroups(List<CanonicalAlbumDetail> details) {
    _albumGroupsStore = details.map((d) {
      final entry = _MockAlbumGroupEntry(
        id: d.id,
        title: d.title,
        artistName: d.artistName,
        releaseYear: d.releaseYear,
        editorialBio: d.editorialBio,
        coverUrl: d.coverUrl,
        primaryVersionId: d.primaryVersionId,
        isPrimaryLocked: d.isPrimaryLocked,
        versions: List<AlbumVersionInfo>.from(d.versions),
        credits: List<AlbumCreditInfo>.from(d.credits),
      );
      _resolveMockPrimaryForGroup(entry);
      return entry;
    }).toList();
  }

  void _resolveMockPrimary(_MockAlbumGroupEntry group) =>
      _resolveMockPrimaryForGroup(group);

  (int prunedVersions, int prunedAlbums) _pruneEmptyMockEntities() {
    final store = _ensureAlbumGroups();
    var prunedVers = 0;
    for (final g in store) {
      final before = g.versions.length;
      g.versions.removeWhere((v) => v.tracks.isEmpty);
      prunedVers += before - g.versions.length;
    }
    final beforeGroups = store.length;
    store.removeWhere((g) => g.versions.isEmpty);
    final prunedAlbs = beforeGroups - store.length;
    for (final g in store) {
      _resolveMockPrimaryForGroup(g);
    }
    return (prunedVers, prunedAlbs);
  }

  (_MockAlbumGroupEntry, int)? _findMockVersion(String versionId) {
    for (final g in _ensureAlbumGroups()) {
      final idx = g.versions.indexWhere((v) => v.id == versionId);
      if (idx >= 0) return (g, idx);
    }
    return null;
  }

  List<CanonicalAlbumSummary> _buildMockAlbumSummaries({
    required int limit,
    required bool includeHidden,
  }) {
    final store = _ensureAlbumGroups();
    final rows = <CanonicalAlbumSummary>[];
    for (final g in store) {
      _resolveMockPrimaryForGroup(g);
      if (g.versions.isEmpty) continue;
      if (includeHidden) {
        for (final v in g.versions) {
          rows.add(_mockSummaryFromVersion(g, v));
        }
      } else {
        final primary = g.versions
                .where((v) => v.id == g.primaryVersionId && !v.isHidden)
                .firstOrNull ??
            g.versions.where((v) => !v.isHidden).firstOrNull;
        if (primary != null) {
          rows.add(_mockSummaryFromVersion(g, primary));
        }
      }
    }
    return rows.take(limit).toList();
  }

  @override
  Future<AlbumVersionOpResult> setPrimaryVersion(
    String groupId,
    String versionId,
  ) async {
    final group =
        _ensureAlbumGroups().where((g) => g.id == groupId).firstOrNull;
    if (group == null) return const AlbumVersionOpResult();
    final idx = group.versions.indexWhere((v) => v.id == versionId);
    if (idx < 0) return const AlbumVersionOpResult();
    group.versions[idx] = group.versions[idx].copyWith(isHidden: false);
    group.primaryVersionId = versionId;
    group.isPrimaryLocked = true;
    _resolveMockPrimaryForGroup(group);
    return AlbumVersionOpResult(
      affectedGroupIds: [group.id],
      affectedVersionIds: [versionId],
      primaryVersionId: group.primaryVersionId,
    );
  }

  @override
  Future<AlbumVersionOpResult> resetPrimaryVersion(String groupId) async {
    final group =
        _ensureAlbumGroups().where((g) => g.id == groupId).firstOrNull;
    if (group == null) return const AlbumVersionOpResult();
    group.isPrimaryLocked = false;
    _resolveMockPrimaryForGroup(group);
    return AlbumVersionOpResult(
      affectedGroupIds: [group.id],
      affectedVersionIds:
          group.primaryVersionId != null ? [group.primaryVersionId!] : const [],
      primaryVersionId: group.primaryVersionId,
    );
  }

  @override
  Future<AlbumVersionOpResult> mergeAlbumVersions({
    required String targetVersionId,
    required List<String> sourceVersionIds,
    String? newEditionLabel,
    List<DiscMappingEntry> discMapping = const <DiscMappingEntry>[],
  }) async {
    final targetLoc = _findMockVersion(targetVersionId);
    if (targetLoc == null) return const AlbumVersionOpResult();
    final (targetGroup, targetIdx) = targetLoc;
    final targetVer = targetGroup.versions[targetIdx];
    final mappingById = <String, int>{
      for (final m in discMapping) m.versionId: m.discStart,
    };
    final targetBaseDisc = mappingById[targetVersionId] ?? 1;
    final combinedTracks = targetVer.tracks
        .map(
          (t) => t.copyWith(
            discNumber: targetBaseDisc > 1
                ? (t.discNumber - 1) + targetBaseDisc
                : t.discNumber,
          ),
        )
        .toList();
    var moved = 0;
    final affectedGroups = <String>{targetGroup.id};
    final affectedVersions = <String>{targetVersionId};
    var nextDisc =
        combinedTracks.map((t) => t.discNumber).fold<int>(0, (a, b) => a > b ? a : b) + 1;

    for (final srcId in sourceVersionIds) {
      if (srcId == targetVersionId) continue;
      final srcLoc = _findMockVersion(srcId);
      if (srcLoc == null) continue;
      final (srcGroup, srcIdx) = srcLoc;
      final srcVer = srcGroup.versions[srcIdx];
      affectedGroups.add(srcGroup.id);
      affectedVersions.add(srcId);
      final discStart = mappingById[srcId] ?? nextDisc;
      for (final t in srcVer.tracks) {
        final newDisc = (t.discNumber - 1) + discStart;
        combinedTracks.add(t.copyWith(discNumber: newDisc));
        if (newDisc >= nextDisc) nextDisc = newDisc + 1;
        moved++;
      }
      srcGroup.versions[srcIdx] = srcVer.copyWith(tracks: const []);
    }

    targetGroup.versions[targetIdx] = targetVer.copyWith(
      editionLabel: (newEditionLabel != null && newEditionLabel.trim().isNotEmpty)
          ? newEditionLabel.trim()
          : targetVer.editionLabel,
      tracks: combinedTracks,
      trackCount: combinedTracks.length,
      discCount: combinedTracks.map((t) => t.discNumber).toSet().length,
      hasManualTracks: true,
    );
    final (prunedVers, prunedAlbs) = _pruneEmptyMockEntities();
    return AlbumVersionOpResult(
      affectedGroupIds: affectedGroups.toList(),
      affectedVersionIds: affectedVersions.toList(),
      primaryVersionId: targetGroup.primaryVersionId,
      movedTracks: moved,
      prunedVersions: prunedVers,
      prunedAlbums: prunedAlbs,
    );
  }

  @override
  Future<AlbumVersionOpResult> splitAlbumVersion({
    required String versionId,
    required List<SplitTrackGroup> trackGroups,
    SplitTargetMode targetMode = SplitTargetMode.sameGroup,
  }) async {
    final loc = _findMockVersion(versionId);
    if (loc == null || trackGroups.isEmpty) return const AlbumVersionOpResult();
    final (sourceGroup, srcIdx) = loc;
    final srcVer = sourceGroup.versions[srcIdx];
    final remainingTracks = List<AlbumVersionTrackInfo>.from(srcVer.tracks);
    final affectedGroups = <String>{sourceGroup.id};
    final affectedVersions = <String>{versionId};
    var moved = 0;

    final allTrackIds = srcVer.tracks.map((t) => t.id).toSet();
    final requestedIds = trackGroups.expand((g) => g.trackIds).toSet();
    final fullPartition =
        trackGroups.length >= 2 && allTrackIds.every(requestedIds.contains);

    final startIndex = fullPartition ? 1 : 0;
    if (fullPartition) {
      final keepSet = trackGroups.first.trackIds.toSet();
      final kept = srcVer.tracks.where((t) => keepSet.contains(t.id)).toList();
      remainingTracks
        ..clear()
        ..addAll(kept);
      sourceGroup.versions[srcIdx] = srcVer.copyWith(
        tracks: kept,
        editionLabel: trackGroups.first.editionLabel ?? srcVer.editionLabel,
        hasManualTracks: true,
      );
    }

    for (var i = startIndex; i < trackGroups.length; i++) {
      final grp = trackGroups[i];
      final idSet = grp.trackIds.toSet();
      final movedList =
          srcVer.tracks.where((t) => idSet.contains(t.id)).toList();
      if (movedList.isEmpty) continue;
      remainingTracks.removeWhere((t) => idSet.contains(t.id));
      moved += movedList.length;

      final newVerId = 'ver-split-${++_mockGroupSeq}';
      affectedVersions.add(newVerId);
      if (targetMode == SplitTargetMode.sameGroup) {
        sourceGroup.versions.add(
          srcVer.copyWith(
            id: newVerId,
            externalAlbumId: '${srcVer.externalAlbumId}#split$_mockGroupSeq',
            editionLabel: grp.editionLabel ?? grp.title ?? '拆分版本 $_mockGroupSeq',
            isPrimary: false,
            manualGroupId: sourceGroup.id,
            hasManualTracks: true,
            tracks: movedList,
          ),
        );
      } else {
        final newGroupId = 'alb-split-$_mockGroupSeq';
        affectedGroups.add(newGroupId);
        _ensureAlbumGroups().add(
          _MockAlbumGroupEntry(
            id: newGroupId,
            title: grp.title ?? '${sourceGroup.title} (拆分 $_mockGroupSeq)',
            artistName: sourceGroup.artistName,
            releaseYear: sourceGroup.releaseYear,
            coverUrl: sourceGroup.coverUrl,
            primaryVersionId: newVerId,
            versions: [
              srcVer.copyWith(
                id: newVerId,
                externalAlbumId:
                    '${srcVer.externalAlbumId}#split$_mockGroupSeq',
                editionLabel: grp.editionLabel ?? srcVer.editionLabel,
                isPrimary: true,
                manualGroupId: newGroupId,
                hasManualTracks: true,
                tracks: movedList,
              ),
            ],
          ),
        );
      }
    }

    if (!fullPartition) {
      sourceGroup.versions[srcIdx] = srcVer.copyWith(
        tracks: remainingTracks,
        hasManualTracks: true,
      );
    }
    final (prunedVers, prunedAlbs) = _pruneEmptyMockEntities();
    return AlbumVersionOpResult(
      affectedGroupIds: affectedGroups.toList(),
      affectedVersionIds: affectedVersions.toList(),
      primaryVersionId: sourceGroup.primaryVersionId,
      movedTracks: moved,
      prunedVersions: prunedVers,
      prunedAlbums: prunedAlbs,
    );
  }

  @override
  Future<AlbumVersionOpResult> groupAsAlternateVersions({
    required List<String> versionIds,
    String? targetGroupId,
    String? primaryVersionId,
  }) async {
    if (versionIds.length < 2) return const AlbumVersionOpResult();
    final store = _ensureAlbumGroups();
    _MockAlbumGroupEntry? targetGroup;
    if (targetGroupId != null && targetGroupId.isNotEmpty) {
      targetGroup = store.where((g) => g.id == targetGroupId).firstOrNull;
    }
    targetGroup ??= _findMockVersion(versionIds.first)?.$1;
    if (targetGroup == null) return const AlbumVersionOpResult();

    final affectedGroups = <String>{targetGroup.id};
    final affectedVersions = <String>{};
    for (final vid in versionIds) {
      final loc = _findMockVersion(vid);
      if (loc == null) continue;
      final (srcGroup, srcIdx) = loc;
      final ver = srcGroup.versions[srcIdx];
      affectedGroups.add(srcGroup.id);
      affectedVersions.add(vid);
      final updated = ver.copyWith(manualGroupId: targetGroup.id);
      if (srcGroup.id == targetGroup.id) {
        srcGroup.versions[srcIdx] = updated;
      } else {
        srcGroup.versions.removeAt(srcIdx);
        targetGroup.versions.add(updated);
      }
    }
    if (primaryVersionId != null &&
        targetGroup.versions.any((v) => v.id == primaryVersionId)) {
      targetGroup.primaryVersionId = primaryVersionId;
      targetGroup.isPrimaryLocked = true;
    }
    final (prunedVers, prunedAlbs) = _pruneEmptyMockEntities();
    return AlbumVersionOpResult(
      affectedGroupIds: affectedGroups.toList(),
      affectedVersionIds: affectedVersions.toList(),
      primaryVersionId: targetGroup.primaryVersionId,
      prunedVersions: prunedVers,
      prunedAlbums: prunedAlbs,
    );
  }

  @override
  Future<AlbumVersionOpResult> ungroupVersion(String versionId) async {
    final loc = _findMockVersion(versionId);
    if (loc == null) return const AlbumVersionOpResult();
    final (srcGroup, srcIdx) = loc;
    if (srcGroup.versions.length <= 1) return const AlbumVersionOpResult();
    final ver = srcGroup.versions.removeAt(srcIdx);
    final newGroupId = 'alb-ungroup-${++_mockGroupSeq}';
    _ensureAlbumGroups().add(
      _MockAlbumGroupEntry(
        id: newGroupId,
        title: srcGroup.title,
        artistName: srcGroup.artistName,
        releaseYear: srcGroup.releaseYear,
        coverUrl: srcGroup.coverUrl,
        primaryVersionId: ver.id,
        versions: [
          ver.copyWith(
            isPrimary: true,
            isHidden: false,
            manualGroupId: newGroupId,
          ),
        ],
      ),
    );
    final (prunedVers, prunedAlbs) = _pruneEmptyMockEntities();
    return AlbumVersionOpResult(
      affectedGroupIds: [srcGroup.id, newGroupId],
      affectedVersionIds: [versionId],
      primaryVersionId: versionId,
      prunedVersions: prunedVers,
      prunedAlbums: prunedAlbs,
    );
  }

  @override
  Future<AlbumVersionOpResult> setVersionHidden(
    String versionId, {
    required bool isHidden,
  }) async {
    final loc = _findMockVersion(versionId);
    if (loc == null) return const AlbumVersionOpResult();
    final (group, idx) = loc;
    group.versions[idx] = group.versions[idx].copyWith(isHidden: isHidden);
    if (isHidden && group.primaryVersionId == versionId) {
      group.isPrimaryLocked = false;
    }
    _resolveMockPrimaryForGroup(group);
    return AlbumVersionOpResult(
      affectedGroupIds: [group.id],
      affectedVersionIds: [versionId],
      primaryVersionId: group.primaryVersionId,
    );
  }

  @override
  Future<AlbumVersionOpResult> resetAlbumGrouping(String versionId) async {
    final loc = _findMockVersion(versionId);
    if (loc == null) return const AlbumVersionOpResult();
    final (group, idx) = loc;
    group.versions[idx] = group.versions[idx].copyWith(
      clearManualGroupId: true,
      hasManualTracks: false,
    );
    return AlbumVersionOpResult(
      affectedGroupIds: [group.id],
      affectedVersionIds: [versionId],
      primaryVersionId: group.primaryVersionId,
    );
  }
}
