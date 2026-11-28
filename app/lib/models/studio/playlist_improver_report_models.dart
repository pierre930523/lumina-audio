part of 'playlist_improver_models.dart';

/// Category of actionable improvement detected by the Playlist Improver.
enum PlaylistImprovementKind {
  duplicate('duplicate'),
  repair('repair'),
  upgrade('upgrade');

  final String wireName;

  const PlaylistImprovementKind(this.wireName);

  String toJson() => wireName;

  static PlaylistImprovementKind fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'repair' => PlaylistImprovementKind.repair,
        'upgrade' => PlaylistImprovementKind.upgrade,
        _ => PlaylistImprovementKind.duplicate,
      };
}

/// Single suggested deduplication, repair, or quality-upgrade action.
@immutable
class PlaylistImprovementSuggestion {
  final String suggestionId;
  final PlaylistImprovementKind kind;
  final int position;
  final int? duplicateOfPosition;
  final String rawEntry;
  final PlaylistTrackSummary? currentTrack;
  final PlaylistTrackSummary? candidateTrack;
  final String reason;
  final double confidence;

  const PlaylistImprovementSuggestion({
    required this.suggestionId,
    required this.kind,
    required this.position,
    this.duplicateOfPosition,
    required this.rawEntry,
    this.currentTrack,
    this.candidateTrack,
    required this.reason,
    this.confidence = 0.0,
  });

  factory PlaylistImprovementSuggestion.fromJson(Map<String, dynamic> json) {
    final rawCurrent = json['current_track'];
    final rawCandidate = json['candidate_track'];
    return PlaylistImprovementSuggestion(
      suggestionId: json['suggestion_id']?.toString() ?? '',
      kind: PlaylistImprovementKind.fromJson(json['kind']?.toString()),
      position: (json['position'] as num?)?.toInt() ?? 0,
      duplicateOfPosition: (json['duplicate_of_position'] as num?)?.toInt(),
      rawEntry: json['raw_entry']?.toString() ?? '',
      currentTrack: rawCurrent is Map
          ? PlaylistTrackSummary.fromJson(Map<String, dynamic>.from(rawCurrent))
          : null,
      candidateTrack: rawCandidate is Map
          ? PlaylistTrackSummary.fromJson(Map<String, dynamic>.from(rawCandidate))
          : null,
      reason: json['reason']?.toString() ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'suggestion_id': suggestionId,
    'kind': kind.toJson(),
    'position': position,
    if (duplicateOfPosition != null) 'duplicate_of_position': duplicateOfPosition,
    'raw_entry': rawEntry,
    if (currentTrack != null) 'current_track': currentTrack!.toJson(),
    if (candidateTrack != null) 'candidate_track': candidateTrack!.toJson(),
    'reason': reason,
    'confidence': confidence,
  };
}

/// Diagnostic analysis report produced for a static playlist.
@immutable
class PlaylistImprovementReport {
  final String playlistId;
  final String playlistName;
  final int totalItems;
  final int duplicateCount;
  final int repairCount;
  final int upgradeCount;
  final List<PlaylistImprovementSuggestion> suggestions;

  const PlaylistImprovementReport({
    required this.playlistId,
    required this.playlistName,
    this.totalItems = 0,
    this.duplicateCount = 0,
    this.repairCount = 0,
    this.upgradeCount = 0,
    this.suggestions = const <PlaylistImprovementSuggestion>[],
  });

  factory PlaylistImprovementReport.fromJson(Map<String, dynamic> json) {
    final rawSuggestions = json['suggestions'] as List<dynamic>? ?? const [];
    return PlaylistImprovementReport(
      playlistId: json['playlist_id']?.toString() ?? '',
      playlistName: json['playlist_name']?.toString() ?? '',
      totalItems: (json['total_items'] as num?)?.toInt() ?? 0,
      duplicateCount: (json['duplicate_count'] as num?)?.toInt() ?? 0,
      repairCount: (json['repair_count'] as num?)?.toInt() ?? 0,
      upgradeCount: (json['upgrade_count'] as num?)?.toInt() ?? 0,
      suggestions: rawSuggestions
          .whereType<Map>()
          .map((e) => PlaylistImprovementSuggestion.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'playlist_id': playlistId,
    'playlist_name': playlistName,
    'total_items': totalItems,
    'duplicate_count': duplicateCount,
    'repair_count': repairCount,
    'upgrade_count': upgradeCount,
    'suggestions': suggestions.map((s) => s.toJson()).toList(growable: false),
  };
}

@immutable
class ApplyPlaylistImprovementsRequest {
  final List<String> suggestionIds;
  final List<PlaylistImprovementKind>? applyKinds;
  final String? reason;

  const ApplyPlaylistImprovementsRequest({
    this.suggestionIds = const <String>[],
    this.applyKinds,
    this.reason,
  });

  factory ApplyPlaylistImprovementsRequest.fromJson(Map<String, dynamic> json) {
    final rawKinds = json['apply_kinds'];
    return ApplyPlaylistImprovementsRequest(
      suggestionIds: _readStringList(json['suggestion_ids']),
      applyKinds: rawKinds is List
          ? rawKinds
                .map((e) => PlaylistImprovementKind.fromJson(e?.toString()))
                .toList(growable: false)
          : null,
      reason: json['reason']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'suggestion_ids': suggestionIds,
    if (applyKinds != null)
      'apply_kinds': applyKinds!.map((k) => k.toJson()).toList(growable: false),
    if (reason != null) 'reason': reason,
  };
}

@immutable
class ApplyPlaylistImprovementsResult {
  final String playlistId;
  final String? snapshotId;
  final int duplicatesRemoved;
  final int tracksRepaired;
  final int tracksUpgraded;
  final int finalTrackCount;

  const ApplyPlaylistImprovementsResult({
    required this.playlistId,
    this.snapshotId,
    this.duplicatesRemoved = 0,
    this.tracksRepaired = 0,
    this.tracksUpgraded = 0,
    this.finalTrackCount = 0,
  });

  factory ApplyPlaylistImprovementsResult.fromJson(Map<String, dynamic> json) =>
      ApplyPlaylistImprovementsResult(
        playlistId: json['playlist_id']?.toString() ?? '',
        snapshotId: json['snapshot_id']?.toString(),
        duplicatesRemoved: (json['duplicates_removed'] as num?)?.toInt() ?? 0,
        tracksRepaired: (json['tracks_repaired'] as num?)?.toInt() ?? 0,
        tracksUpgraded: (json['tracks_upgraded'] as num?)?.toInt() ?? 0,
        finalTrackCount: (json['final_track_count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'playlist_id': playlistId,
    if (snapshotId != null) 'snapshot_id': snapshotId,
    'duplicates_removed': duplicatesRemoved,
    'tracks_repaired': tracksRepaired,
    'tracks_upgraded': tracksUpgraded,
    'final_track_count': finalTrackCount,
  };
}

@immutable
class PlaylistSnapshotRecord {
  final String id;
  final String playlistId;
  final String reason;
  final int trackCount;
  final String createdAt;

  const PlaylistSnapshotRecord({
    required this.id,
    required this.playlistId,
    required this.reason,
    this.trackCount = 0,
    this.createdAt = '',
  });

  factory PlaylistSnapshotRecord.fromJson(Map<String, dynamic> json) =>
      PlaylistSnapshotRecord(
        id: json['id']?.toString() ?? '',
        playlistId: json['playlist_id']?.toString() ?? '',
        reason: json['reason']?.toString() ?? '',
        trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
        createdAt: json['created_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'playlist_id': playlistId,
    'reason': reason,
    'track_count': trackCount,
    'created_at': createdAt,
  };
}

@immutable
class RevertPlaylistSnapshotResult {
  final String playlistId;
  final String snapshotId;
  final int restoredTrackCount;

  const RevertPlaylistSnapshotResult({
    required this.playlistId,
    required this.snapshotId,
    this.restoredTrackCount = 0,
  });

  factory RevertPlaylistSnapshotResult.fromJson(Map<String, dynamic> json) =>
      RevertPlaylistSnapshotResult(
        playlistId: json['playlist_id']?.toString() ?? '',
        snapshotId: json['snapshot_id']?.toString() ?? '',
        restoredTrackCount: (json['restored_track_count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'playlist_id': playlistId,
    'snapshot_id': snapshotId,
    'restored_track_count': restoredTrackCount,
  };
}
