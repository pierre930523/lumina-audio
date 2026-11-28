import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../playback_state.dart';
import 'focus_models.dart';

part 'step4_listen_later_models.dart';

bool _readBool(dynamic raw, {bool fallback = false}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  final s = raw.toString().trim().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return fallback;
}

String? _readOptionalString(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString();
  return s.isEmpty ? null : s;
}

/// Response payload from updating an entity's tri-state preference (-1 / 0 / 1).
@immutable
class SetEntityPreferenceResponse {
  final String entityType;
  final String entityId;
  final int preference;

  const SetEntityPreferenceResponse({
    required this.entityType,
    required this.entityId,
    required this.preference,
  });

  factory SetEntityPreferenceResponse.fromJson(Map<String, dynamic> json) =>
      SetEntityPreferenceResponse(
        entityType: json['entity_type']?.toString() ?? '',
        entityId: json['entity_id']?.toString() ?? '',
        preference: (json['preference'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entity_type': entityType,
    'entity_id': entityId,
    'preference': preference,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SetEntityPreferenceResponse &&
          other.entityType == entityType &&
          other.entityId == entityId &&
          other.preference == preference;

  @override
  int get hashCode => Object.hash(entityType, entityId, preference);
}

/// Dynamic Bookmark capturing route + optional serialized [FocusQuery] + view state.
@immutable
class BookmarkItem {
  final String id;
  final String name;
  final String targetRoute;
  final String? focusQueryJson;
  final String? viewStateJson;
  final int sortOrder;
  final String createdAt;
  final String updatedAt;

  const BookmarkItem({
    required this.id,
    required this.name,
    required this.targetRoute,
    this.focusQueryJson,
    this.viewStateJson,
    this.sortOrder = 0,
    this.createdAt = '',
    this.updatedAt = '',
  });

  FocusQuery? parseFocusQuery() {
    final raw = focusQueryJson?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return FocusQuery.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic>? parseViewState() {
    final raw = viewStateJson?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  BookmarkItem copyWith({
    String? id,
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    bool clearFocusQueryJson = false,
    String? viewStateJson,
    bool clearViewStateJson = false,
    int? sortOrder,
    String? createdAt,
    String? updatedAt,
  }) => BookmarkItem(
    id: id ?? this.id,
    name: name ?? this.name,
    targetRoute: targetRoute ?? this.targetRoute,
    focusQueryJson: clearFocusQueryJson
        ? null
        : (focusQueryJson ?? this.focusQueryJson),
    viewStateJson: clearViewStateJson
        ? null
        : (viewStateJson ?? this.viewStateJson),
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory BookmarkItem.fromJson(Map<String, dynamic> json) => BookmarkItem(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    targetRoute: json['target_route']?.toString() ?? '',
    focusQueryJson: _readOptionalString(json['focus_query_json']),
    viewStateJson: _readOptionalString(json['view_state_json']),
    sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    createdAt: json['created_at']?.toString() ?? '',
    updatedAt: json['updated_at']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'target_route': targetRoute,
    if (focusQueryJson != null) 'focus_query_json': focusQueryJson,
    if (viewStateJson != null) 'view_state_json': viewStateJson,
    'sort_order': sortOrder,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookmarkItem &&
          other.id == id &&
          other.name == name &&
          other.targetRoute == targetRoute &&
          other.focusQueryJson == focusQueryJson &&
          other.viewStateJson == viewStateJson &&
          other.sortOrder == sortOrder &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    targetRoute,
    focusQueryJson,
    viewStateJson,
    sortOrder,
    createdAt,
    updatedAt,
  );
}

/// Unified FocusQuery-backed Smart Playlist persisted in SQLite.
@immutable
class SmartPlaylistItem {
  final String id;
  final String name;
  final String description;
  final String focusQueryJson;
  final bool excludeBanned;
  final int? limitCount;
  final bool isPinned;
  final int sortOrder;
  final bool isSystemSeed;
  final String createdAt;
  final String updatedAt;

  const SmartPlaylistItem({
    required this.id,
    required this.name,
    this.description = '',
    required this.focusQueryJson,
    this.excludeBanned = true,
    this.limitCount,
    this.isPinned = true,
    this.sortOrder = 0,
    this.isSystemSeed = false,
    this.createdAt = '',
    this.updatedAt = '',
  });

  FocusQuery? parseFocusQuery() {
    final raw = focusQueryJson.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return FocusQuery.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  SmartPlaylistItem copyWith({
    String? id,
    String? name,
    String? description,
    String? focusQueryJson,
    bool? excludeBanned,
    int? limitCount,
    bool clearLimitCount = false,
    bool? isPinned,
    int? sortOrder,
    bool? isSystemSeed,
    String? createdAt,
    String? updatedAt,
  }) => SmartPlaylistItem(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    focusQueryJson: focusQueryJson ?? this.focusQueryJson,
    excludeBanned: excludeBanned ?? this.excludeBanned,
    limitCount: clearLimitCount ? null : (limitCount ?? this.limitCount),
    isPinned: isPinned ?? this.isPinned,
    sortOrder: sortOrder ?? this.sortOrder,
    isSystemSeed: isSystemSeed ?? this.isSystemSeed,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory SmartPlaylistItem.fromJson(Map<String, dynamic> json) =>
      SmartPlaylistItem(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        focusQueryJson: json['focus_query_json']?.toString() ?? '{}',
        excludeBanned: _readBool(json['exclude_banned'], fallback: true),
        limitCount: (json['limit_count'] as num?)?.toInt(),
        isPinned: _readBool(json['is_pinned'], fallback: true),
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        isSystemSeed: _readBool(json['is_system_seed'], fallback: false),
        createdAt: json['created_at']?.toString() ?? '',
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'focus_query_json': focusQueryJson,
    'exclude_banned': excludeBanned,
    if (limitCount != null) 'limit_count': limitCount,
    'is_pinned': isPinned,
    'sort_order': sortOrder,
    'is_system_seed': isSystemSeed,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SmartPlaylistItem &&
          other.id == id &&
          other.name == name &&
          other.description == description &&
          other.focusQueryJson == focusQueryJson &&
          other.excludeBanned == excludeBanned &&
          other.limitCount == limitCount &&
          other.isPinned == isPinned &&
          other.sortOrder == sortOrder &&
          other.isSystemSeed == isSystemSeed &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    focusQueryJson,
    excludeBanned,
    limitCount,
    isPinned,
    sortOrder,
    isSystemSeed,
    createdAt,
    updatedAt,
  );
}

/// Evaluation result of a [SmartPlaylistItem] against the library DB.
@immutable
class SmartPlaylistEvaluation {
  final SmartPlaylistItem playlist;
  final int totalMatched;
  final List<TrackInfo> tracks;

  const SmartPlaylistEvaluation({
    required this.playlist,
    this.totalMatched = 0,
    this.tracks = const <TrackInfo>[],
  });

  factory SmartPlaylistEvaluation.fromJson(Map<String, dynamic> json) {
    final rawPlaylist = json['playlist'];
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    return SmartPlaylistEvaluation(
      playlist: rawPlaylist is Map
          ? SmartPlaylistItem.fromJson(Map<String, dynamic>.from(rawPlaylist))
          : const SmartPlaylistItem(id: '', name: '', focusQueryJson: '{}'),
      totalMatched: (json['total_matched'] as num?)?.toInt() ?? 0,
      tracks: rawTracks
          .whereType<Map>()
          .map((e) => TrackInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'playlist': playlist.toJson(),
    'total_matched': totalMatched,
    'tracks': tracks.map((t) => t.toJson()).toList(growable: false),
  };
}
