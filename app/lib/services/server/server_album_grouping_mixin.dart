part of '../server_audio_service.dart';

mixin _ServerAlbumGroupingMixin on _ServerAudioServiceBase {
  AlbumVersionOpResult _decodeOpResult(int code, dynamic data) {
    if (code == 200 && data is Map) {
      return AlbumVersionOpResult.fromJson(Map<String, dynamic>.from(data));
    }
    return const AlbumVersionOpResult();
  }

  @override
  Future<AlbumVersionOpResult> setPrimaryVersion(
    String groupId,
    String versionId,
  ) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/albums/${Uri.encodeComponent(groupId)}/primary-version',
      body: <String, dynamic>{'version_id': versionId},
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> resetPrimaryVersion(String groupId) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/albums/${Uri.encodeComponent(groupId)}/primary-version',
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> mergeAlbumVersions({
    required String targetVersionId,
    required List<String> sourceVersionIds,
    String? newEditionLabel,
    List<DiscMappingEntry> discMapping = const <DiscMappingEntry>[],
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/versions/merge',
      body: <String, dynamic>{
        'target_version_id': targetVersionId,
        'source_version_ids': sourceVersionIds,
        if (newEditionLabel != null && newEditionLabel.trim().isNotEmpty)
          'new_edition_label': newEditionLabel.trim(),
        'disc_mapping': discMapping.map((e) => e.toJson()).toList(),
      },
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> splitAlbumVersion({
    required String versionId,
    required List<SplitTrackGroup> trackGroups,
    SplitTargetMode targetMode = SplitTargetMode.sameGroup,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/versions/${Uri.encodeComponent(versionId)}/split',
      body: <String, dynamic>{
        'version_id': versionId,
        'track_groups': trackGroups.map((g) => g.toJson()).toList(),
        'target_mode': targetMode.toJson(),
      },
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> groupAsAlternateVersions({
    required List<String> versionIds,
    String? targetGroupId,
    String? primaryVersionId,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/versions/group',
      body: <String, dynamic>{
        'version_ids': versionIds,
        if (targetGroupId != null && targetGroupId.trim().isNotEmpty)
          'target_group_id': targetGroupId.trim(),
        if (primaryVersionId != null && primaryVersionId.trim().isNotEmpty)
          'primary_version_id': primaryVersionId.trim(),
      },
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> ungroupVersion(String versionId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/versions/${Uri.encodeComponent(versionId)}/ungroup',
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> setVersionHidden(
    String versionId, {
    required bool isHidden,
  }) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/versions/${Uri.encodeComponent(versionId)}/hidden',
      body: <String, dynamic>{'is_hidden': isHidden},
    );
    return _decodeOpResult(code, data);
  }

  @override
  Future<AlbumVersionOpResult> resetAlbumGrouping(String versionId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/versions/${Uri.encodeComponent(versionId)}/reset-grouping',
    );
    return _decodeOpResult(code, data);
  }
}
