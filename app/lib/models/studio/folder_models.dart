import 'package:flutter/foundation.dart';

import '../playback_state.dart';

/// Physical directory node in the local library folder tree.
@immutable
class FolderNode {
  final String id;
  final String? rootId;
  final String? parentId;
  final String name;
  final String normPath;
  final String displayPath;
  final int depth;
  final int directTrackCount;
  final int recursiveTrackCount;
  final bool isOnline;

  const FolderNode({
    required this.id,
    this.rootId,
    this.parentId,
    required this.name,
    required this.normPath,
    required this.displayPath,
    this.depth = 0,
    this.directTrackCount = 0,
    this.recursiveTrackCount = 0,
    this.isOnline = true,
  });

  factory FolderNode.fromJson(Map<String, dynamic> json) => FolderNode(
    id: json['id']?.toString() ?? '',
    rootId: json['root_id']?.toString(),
    parentId: json['parent_id']?.toString(),
    name: json['name']?.toString() ?? '',
    normPath: json['norm_path']?.toString() ?? '',
    displayPath: json['display_path']?.toString() ?? '',
    depth: (json['depth'] as num?)?.toInt() ?? 0,
    directTrackCount: (json['direct_track_count'] as num?)?.toInt() ?? 0,
    recursiveTrackCount: (json['recursive_track_count'] as num?)?.toInt() ?? 0,
    isOnline: json['is_online'] == null
        ? true
        : (json['is_online'] == true || json['is_online'] == 1),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (rootId != null) 'root_id': rootId,
    if (parentId != null) 'parent_id': parentId,
    'name': name,
    'norm_path': normPath,
    'display_path': displayPath,
    'depth': depth,
    'direct_track_count': directTrackCount,
    'recursive_track_count': recursiveTrackCount,
    'is_online': isOnline,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderNode &&
          other.id == id &&
          other.rootId == rootId &&
          other.parentId == parentId &&
          other.name == name &&
          other.normPath == normPath &&
          other.displayPath == displayPath &&
          other.depth == depth &&
          other.directTrackCount == directTrackCount &&
          other.recursiveTrackCount == recursiveTrackCount &&
          other.isOnline == isOnline;

  @override
  int get hashCode => Object.hash(
    id,
    rootId,
    parentId,
    name,
    normPath,
    displayPath,
    depth,
    directTrackCount,
    recursiveTrackCount,
    isOnline,
  );
}

/// Single path segment in a folder breadcrumb trail.
@immutable
class FolderBreadcrumb {
  final String id;
  final String name;
  final String displayPath;

  const FolderBreadcrumb({
    required this.id,
    required this.name,
    required this.displayPath,
  });

  factory FolderBreadcrumb.fromJson(Map<String, dynamic> json) =>
      FolderBreadcrumb(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        displayPath: json['display_path']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'display_path': displayPath,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FolderBreadcrumb &&
          other.id == id &&
          other.name == name &&
          other.displayPath == displayPath;

  @override
  int get hashCode => Object.hash(id, name, displayPath);
}

/// Contents of a selected physical folder: metadata, breadcrumbs, immediate
/// subfolders, and direct audio tracks.
@immutable
class FolderContentsResponse {
  final FolderNode? folder;
  final List<FolderBreadcrumb> breadcrumbs;
  final List<FolderNode> subfolders;
  final List<TrackInfo> tracks;

  const FolderContentsResponse({
    this.folder,
    this.breadcrumbs = const <FolderBreadcrumb>[],
    this.subfolders = const <FolderNode>[],
    this.tracks = const <TrackInfo>[],
  });

  factory FolderContentsResponse.fromJson(Map<String, dynamic> json) {
    final rawFolder = json['folder'];
    final rawCrumbs = json['breadcrumbs'] as List<dynamic>? ?? const [];
    final rawSubs = json['subfolders'] as List<dynamic>? ?? const [];
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    return FolderContentsResponse(
      folder: rawFolder is Map
          ? FolderNode.fromJson(Map<String, dynamic>.from(rawFolder))
          : null,
      breadcrumbs: rawCrumbs
          .whereType<Map>()
          .map((e) => FolderBreadcrumb.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      subfolders: rawSubs
          .whereType<Map>()
          .map((e) => FolderNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      tracks: rawTracks
          .whereType<Map>()
          .map((e) => TrackInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}
