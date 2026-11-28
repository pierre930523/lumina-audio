part of '../streaming_playback_coordinator.dart';

mixin _CoordinatingAudioServiceGroupingDelegatesMixin
    implements AudioService {
  AudioService get inner;

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) => inner.getAlbums(limit: limit, includeHidden: includeHidden);

  @override
  Future<AlbumVersionOpResult> setPrimaryVersion(
    String groupId,
    String versionId,
  ) => inner.setPrimaryVersion(groupId, versionId);

  @override
  Future<AlbumVersionOpResult> resetPrimaryVersion(String groupId) =>
      inner.resetPrimaryVersion(groupId);

  @override
  Future<AlbumVersionOpResult> mergeAlbumVersions({
    required String targetVersionId,
    required List<String> sourceVersionIds,
    String? newEditionLabel,
    List<DiscMappingEntry> discMapping = const <DiscMappingEntry>[],
  }) => inner.mergeAlbumVersions(
    targetVersionId: targetVersionId,
    sourceVersionIds: sourceVersionIds,
    newEditionLabel: newEditionLabel,
    discMapping: discMapping,
  );

  @override
  Future<AlbumVersionOpResult> splitAlbumVersion({
    required String versionId,
    required List<SplitTrackGroup> trackGroups,
    SplitTargetMode targetMode = SplitTargetMode.sameGroup,
  }) => inner.splitAlbumVersion(
    versionId: versionId,
    trackGroups: trackGroups,
    targetMode: targetMode,
  );

  @override
  Future<AlbumVersionOpResult> groupAsAlternateVersions({
    required List<String> versionIds,
    String? targetGroupId,
    String? primaryVersionId,
  }) => inner.groupAsAlternateVersions(
    versionIds: versionIds,
    targetGroupId: targetGroupId,
    primaryVersionId: primaryVersionId,
  );

  @override
  Future<AlbumVersionOpResult> ungroupVersion(String versionId) =>
      inner.ungroupVersion(versionId);

  @override
  Future<AlbumVersionOpResult> setVersionHidden(
    String versionId, {
    required bool isHidden,
  }) => inner.setVersionHidden(versionId, isHidden: isHidden);

  @override
  Future<AlbumVersionOpResult> resetAlbumGrouping(String versionId) =>
      inner.resetAlbumGrouping(versionId);
}
