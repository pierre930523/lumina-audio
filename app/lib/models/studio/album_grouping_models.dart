import 'package:flutter/foundation.dart';

/// Maps a source version to its starting disc number when merging multiple
/// versions into a single multi-disc album version.
@immutable
class DiscMappingEntry {
  final String versionId;
  final int discStart;

  const DiscMappingEntry({
    required this.versionId,
    required this.discStart,
  });

  factory DiscMappingEntry.fromJson(Map<String, dynamic> json) =>
      DiscMappingEntry(
        versionId: json['version_id']?.toString() ??
            json['source_version_id']?.toString() ??
            '',
        discStart: (json['disc_start'] as num?)?.toInt() ??
            (json['disc_number'] as num?)?.toInt() ??
            (json['disc_offset'] as num?)?.toInt() ??
            1,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version_id': versionId,
        'disc_start': discStart,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscMappingEntry &&
          other.versionId == versionId &&
          other.discStart == discStart;

  @override
  int get hashCode => Object.hash(versionId, discStart);
}

/// Destination mode when splitting an album version into multiple track groups.
enum SplitTargetMode {
  sameGroup,
  newGroup;

  String toJson() => switch (this) {
        SplitTargetMode.sameGroup => 'same_group',
        SplitTargetMode.newGroup => 'new_group',
      };

  static SplitTargetMode fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'new_group' => SplitTargetMode.newGroup,
        _ => SplitTargetMode.sameGroup,
      };

  String get displayLabel => switch (this) {
        SplitTargetMode.sameGroup => '作為同一專輯的新版本',
        SplitTargetMode.newGroup => '成為完全獨立的新專輯群組',
      };
}

/// One target group of tracks produced by splitting an existing album version.
@immutable
class SplitTrackGroup {
  final List<String> trackIds;
  final String? title;
  final String? editionLabel;

  const SplitTrackGroup({
    required this.trackIds,
    this.title,
    this.editionLabel,
  });

  factory SplitTrackGroup.fromJson(Map<String, dynamic> json) =>
      SplitTrackGroup(
        trackIds: (json['track_ids'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        title: json['title']?.toString(),
        editionLabel: json['edition_label']?.toString(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'track_ids': trackIds,
        if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
        if (editionLabel != null && editionLabel!.trim().isNotEmpty)
          'edition_label': editionLabel!.trim(),
      };
}

/// Result returned by all Step 2 album group / version mutation operations.
@immutable
class AlbumVersionOpResult {
  final List<String> affectedGroupIds;
  final List<String> affectedVersionIds;
  final String? primaryVersionId;
  final int movedTracks;
  final int prunedVersions;
  final int prunedAlbums;

  const AlbumVersionOpResult({
    this.affectedGroupIds = const <String>[],
    this.affectedVersionIds = const <String>[],
    this.primaryVersionId,
    this.movedTracks = 0,
    this.prunedVersions = 0,
    this.prunedAlbums = 0,
  });

  bool get hasChanges =>
      affectedGroupIds.isNotEmpty ||
      affectedVersionIds.isNotEmpty ||
      movedTracks > 0 ||
      prunedVersions > 0 ||
      prunedAlbums > 0;

  factory AlbumVersionOpResult.fromJson(Map<String, dynamic> json) =>
      AlbumVersionOpResult(
        affectedGroupIds:
            (json['affected_group_ids'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
        affectedVersionIds:
            (json['affected_version_ids'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList(growable: false),
        primaryVersionId: json['primary_version_id']?.toString(),
        movedTracks: (json['moved_tracks'] as num?)?.toInt() ?? 0,
        prunedVersions: (json['pruned_versions'] as num?)?.toInt() ?? 0,
        prunedAlbums: (json['pruned_albums'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'affected_group_ids': affectedGroupIds,
        'affected_version_ids': affectedVersionIds,
        if (primaryVersionId != null) 'primary_version_id': primaryVersionId,
        'moved_tracks': movedTracks,
        'pruned_versions': prunedVersions,
        'pruned_albums': prunedAlbums,
      };
}
