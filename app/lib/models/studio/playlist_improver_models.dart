import 'package:flutter/foundation.dart';

part 'playlist_improver_report_models.dart';

bool _readBool(dynamic raw, {bool fallback = false}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  final s = raw.toString().trim().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return fallback;
}

List<String> _readStringList(dynamic raw) =>
    (raw as List<dynamic>? ?? const []).map((e) => e.toString()).toList(growable: false);

/// Summary row for a static playlist managed by the library DB.
@immutable
class StaticPlaylistSummary {
  final String id;
  final String providerId;
  final String sourcePath;
  final String name;
  final int trackCount;
  final int resolvedCount;
  final int unresolvedCount;
  final int snapshotCount;
  final String updatedAt;

  const StaticPlaylistSummary({
    required this.id,
    required this.providerId,
    required this.sourcePath,
    required this.name,
    this.trackCount = 0,
    this.resolvedCount = 0,
    this.unresolvedCount = 0,
    this.snapshotCount = 0,
    this.updatedAt = '',
  });

  factory StaticPlaylistSummary.fromJson(Map<String, dynamic> json) =>
      StaticPlaylistSummary(
        id: json['id']?.toString() ?? '',
        providerId: json['provider_id']?.toString() ?? '',
        sourcePath: json['source_path']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
        resolvedCount: (json['resolved_count'] as num?)?.toInt() ?? 0,
        unresolvedCount: (json['unresolved_count'] as num?)?.toInt() ?? 0,
        snapshotCount: (json['snapshot_count'] as num?)?.toInt() ?? 0,
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'provider_id': providerId,
    'source_path': sourcePath,
    'name': name,
    'track_count': trackCount,
    'resolved_count': resolvedCount,
    'unresolved_count': unresolvedCount,
    'snapshot_count': snapshotCount,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StaticPlaylistSummary &&
          other.id == id &&
          other.providerId == providerId &&
          other.sourcePath == sourcePath &&
          other.name == name &&
          other.trackCount == trackCount &&
          other.resolvedCount == resolvedCount &&
          other.unresolvedCount == unresolvedCount &&
          other.snapshotCount == snapshotCount &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    providerId,
    sourcePath,
    name,
    trackCount,
    resolvedCount,
    unresolvedCount,
    snapshotCount,
    updatedAt,
  );
}

/// Compact track metadata used inside static playlist views & improver suggestions.
@immutable
class PlaylistTrackSummary {
  final String trackId;
  final String versionId;
  final String canonicalAlbumId;
  final String title;
  final String artistName;
  final String albumTitle;
  final String providerId;
  final String codec;
  final int sampleRateHz;
  final int bitDepth;
  final bool isDsd;
  final int durationMs;
  final double qualityScore;
  final String fileStatus;
  final String? isrc;
  final String? filePath;

  const PlaylistTrackSummary({
    required this.trackId,
    required this.versionId,
    required this.canonicalAlbumId,
    required this.title,
    this.artistName = '',
    this.albumTitle = '',
    required this.providerId,
    required this.codec,
    this.sampleRateHz = 0,
    this.bitDepth = 0,
    this.isDsd = false,
    this.durationMs = 0,
    this.qualityScore = 0.0,
    this.fileStatus = '',
    this.isrc,
    this.filePath,
  });

  factory PlaylistTrackSummary.fromJson(Map<String, dynamic> json) =>
      PlaylistTrackSummary(
        trackId: json['track_id']?.toString() ?? '',
        versionId: json['version_id']?.toString() ?? '',
        canonicalAlbumId: json['canonical_album_id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        artistName: json['artist_name']?.toString() ?? '',
        albumTitle: json['album_title']?.toString() ?? '',
        providerId: json['provider_id']?.toString() ?? '',
        codec: json['codec']?.toString() ?? '',
        sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt() ?? 0,
        bitDepth: (json['bit_depth'] as num?)?.toInt() ?? 0,
        isDsd: _readBool(json['is_dsd']),
        durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
        qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
        fileStatus: json['file_status']?.toString() ?? '',
        isrc: json['isrc']?.toString(),
        filePath: json['file_path']?.toString(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'track_id': trackId,
    'version_id': versionId,
    'canonical_album_id': canonicalAlbumId,
    'title': title,
    'artist_name': artistName,
    'album_title': albumTitle,
    'provider_id': providerId,
    'codec': codec,
    'sample_rate_hz': sampleRateHz,
    'bit_depth': bitDepth,
    'is_dsd': isDsd,
    'duration_ms': durationMs,
    'quality_score': qualityScore,
    'file_status': fileStatus,
    if (isrc != null) 'isrc': isrc,
    if (filePath != null) 'file_path': filePath,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistTrackSummary &&
          other.trackId == trackId &&
          other.versionId == versionId &&
          other.canonicalAlbumId == canonicalAlbumId &&
          other.title == title &&
          other.artistName == artistName &&
          other.albumTitle == albumTitle &&
          other.providerId == providerId &&
          other.codec == codec &&
          other.sampleRateHz == sampleRateHz &&
          other.bitDepth == bitDepth &&
          other.isDsd == isDsd &&
          other.durationMs == durationMs &&
          other.qualityScore == qualityScore &&
          other.fileStatus == fileStatus &&
          other.isrc == isrc &&
          other.filePath == filePath;

  @override
  int get hashCode => Object.hash(
    trackId,
    versionId,
    canonicalAlbumId,
    title,
    artistName,
    albumTitle,
    providerId,
    codec,
    sampleRateHz,
    bitDepth,
    isDsd,
    durationMs,
    qualityScore,
    fileStatus,
    isrc,
    filePath,
  );
}

/// Single ordered entry inside a static playlist.
@immutable
class StaticPlaylistItemView {
  final int position;
  final String rawEntry;
  final String? resolvedTrackSourceId;
  final PlaylistTrackSummary? track;
  final bool isMissing;

  const StaticPlaylistItemView({
    required this.position,
    required this.rawEntry,
    this.resolvedTrackSourceId,
    this.track,
    this.isMissing = false,
  });

  factory StaticPlaylistItemView.fromJson(Map<String, dynamic> json) {
    final rawTrack = json['track'];
    return StaticPlaylistItemView(
      position: (json['position'] as num?)?.toInt() ?? 0,
      rawEntry: json['raw_entry']?.toString() ?? '',
      resolvedTrackSourceId: json['resolved_track_source_id']?.toString(),
      track: rawTrack is Map
          ? PlaylistTrackSummary.fromJson(Map<String, dynamic>.from(rawTrack))
          : null,
      isMissing: _readBool(json['is_missing']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'position': position,
    'raw_entry': rawEntry,
    if (resolvedTrackSourceId != null)
      'resolved_track_source_id': resolvedTrackSourceId,
    if (track != null) 'track': track!.toJson(),
    'is_missing': isMissing,
  };
}

/// Full detail payload for a static playlist and its ordered entries.
@immutable
class StaticPlaylistDetail {
  final StaticPlaylistSummary playlist;
  final List<StaticPlaylistItemView> items;

  const StaticPlaylistDetail({
    required this.playlist,
    this.items = const <StaticPlaylistItemView>[],
  });

  factory StaticPlaylistDetail.fromJson(Map<String, dynamic> json) {
    final rawPlaylist = json['playlist'];
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return StaticPlaylistDetail(
      playlist: rawPlaylist is Map
          ? StaticPlaylistSummary.fromJson(Map<String, dynamic>.from(rawPlaylist))
          : const StaticPlaylistSummary(
              id: '',
              providerId: '',
              sourcePath: '',
              name: '',
            ),
      items: rawItems
          .whereType<Map>()
          .map((e) => StaticPlaylistItemView.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'playlist': playlist.toJson(),
    'items': items.map((i) => i.toJson()).toList(growable: false),
  };
}

@immutable
class CreateStaticPlaylistRequest {
  final String name;
  final List<String> trackIds;

  const CreateStaticPlaylistRequest({
    required this.name,
    this.trackIds = const <String>[],
  });

  factory CreateStaticPlaylistRequest.fromJson(Map<String, dynamic> json) =>
      CreateStaticPlaylistRequest(
        name: json['name']?.toString() ?? '',
        trackIds: _readStringList(json['track_ids']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'track_ids': trackIds,
  };
}

@immutable
class AddStaticPlaylistTracksRequest {
  final List<String> trackIds;

  const AddStaticPlaylistTracksRequest({this.trackIds = const <String>[]});

  factory AddStaticPlaylistTracksRequest.fromJson(Map<String, dynamic> json) =>
      AddStaticPlaylistTracksRequest(trackIds: _readStringList(json['track_ids']));

  Map<String, dynamic> toJson() => <String, dynamic>{'track_ids': trackIds};
}
