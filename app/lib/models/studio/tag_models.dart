import 'package:flutter/foundation.dart';

/// Entity type that can receive Custom Nested Tag assignments.
enum TagEntityType {
  albumGroup('album_group'),
  track('track'),
  artist('artist');

  final String wireName;

  const TagEntityType(this.wireName);

  String toJson() => wireName;

  static TagEntityType fromJson(String? raw) {
    final norm = raw?.trim().toLowerCase() ?? '';
    return switch (norm) {
      'track' => TagEntityType.track,
      'artist' => TagEntityType.artist,
      _ => TagEntityType.albumGroup,
    };
  }
}

/// Batch operation mode when tagging or untagging entities.
enum TagBatchOp {
  add,
  remove;

  String toJson() => name;

  static TagBatchOp fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'remove' => TagBatchOp.remove,
        _ => TagBatchOp.add,
      };
}

/// Summary DTO for a custom nested tag node in the tag DAG.
@immutable
class TagSummary {
  final String id;
  final String name;
  final String? color;
  final List<String> parentIds;
  final List<String> childIds;
  final int directItemCount;
  final int recursiveItemCount;
  final String createdAt;
  final String updatedAt;

  const TagSummary({
    required this.id,
    required this.name,
    this.color,
    this.parentIds = const <String>[],
    this.childIds = const <String>[],
    this.directItemCount = 0,
    this.recursiveItemCount = 0,
    this.createdAt = '',
    this.updatedAt = '',
  });

  TagSummary copyWith({
    String? id,
    String? name,
    String? color,
    bool clearColor = false,
    List<String>? parentIds,
    List<String>? childIds,
    int? directItemCount,
    int? recursiveItemCount,
    String? createdAt,
    String? updatedAt,
  }) => TagSummary(
    id: id ?? this.id,
    name: name ?? this.name,
    color: clearColor ? null : (color ?? this.color),
    parentIds: parentIds ?? this.parentIds,
    childIds: childIds ?? this.childIds,
    directItemCount: directItemCount ?? this.directItemCount,
    recursiveItemCount: recursiveItemCount ?? this.recursiveItemCount,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  factory TagSummary.fromJson(Map<String, dynamic> json) => TagSummary(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    color: json['color']?.toString(),
    parentIds: (json['parent_ids'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    childIds: (json['child_ids'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    directItemCount: (json['direct_item_count'] as num?)?.toInt() ?? 0,
    recursiveItemCount: (json['recursive_item_count'] as num?)?.toInt() ?? 0,
    createdAt: json['created_at']?.toString() ?? '',
    updatedAt: json['updated_at']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    if (color != null) 'color': color,
    'parent_ids': parentIds,
    'child_ids': childIds,
    'direct_item_count': directItemCount,
    'recursive_item_count': recursiveItemCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TagSummary &&
          other.id == id &&
          other.name == name &&
          other.color == color &&
          listEquals(other.parentIds, parentIds) &&
          listEquals(other.childIds, childIds) &&
          other.directItemCount == directItemCount &&
          other.recursiveItemCount == recursiveItemCount &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    color,
    Object.hashAll(parentIds),
    Object.hashAll(childIds),
    directItemCount,
    recursiveItemCount,
    createdAt,
    updatedAt,
  );
}

@immutable
class CreateTagRequest {
  final String name;
  final String? color;

  const CreateTagRequest({required this.name, this.color});

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name.trim(),
    if (color != null && color!.trim().isNotEmpty) 'color': color!.trim(),
  };

  factory CreateTagRequest.fromJson(Map<String, dynamic> json) =>
      CreateTagRequest(
        name: json['name']?.toString() ?? '',
        color: json['color']?.toString(),
      );
}

@immutable
class UpdateTagRequest {
  final String id;
  final String? name;
  final String? color;
  final bool clearColor;

  const UpdateTagRequest({
    required this.id,
    this.name,
    this.color,
    this.clearColor = false,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (name != null) 'name': name!.trim(),
    if (color != null && !clearColor) 'color': color!.trim(),
    'clear_color': clearColor,
  };

  factory UpdateTagRequest.fromJson(Map<String, dynamic> json) =>
      UpdateTagRequest(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString(),
        color: json['color']?.toString(),
        clearColor: json['clear_color'] == true || json['clear_color'] == 1,
      );
}

@immutable
class TagLinkRequest {
  final String parentTagId;
  final String childTagId;

  const TagLinkRequest({required this.parentTagId, required this.childTagId});

  Map<String, dynamic> toJson() => <String, dynamic>{
    'parent_tag_id': parentTagId,
    'child_tag_id': childTagId,
  };

  factory TagLinkRequest.fromJson(Map<String, dynamic> json) => TagLinkRequest(
    parentTagId: json['parent_tag_id']?.toString() ?? '',
    childTagId: json['child_tag_id']?.toString() ?? '',
  );
}

@immutable
class BatchTagItemsRequest {
  final List<String> tagIds;
  final TagEntityType entityType;
  final List<String> entityIds;
  final TagBatchOp op;

  const BatchTagItemsRequest({
    required this.tagIds,
    required this.entityType,
    required this.entityIds,
    this.op = TagBatchOp.add,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tag_ids': tagIds,
    'entity_type': entityType.toJson(),
    'entity_ids': entityIds,
    'op': op.toJson(),
  };

  factory BatchTagItemsRequest.fromJson(Map<String, dynamic> json) =>
      BatchTagItemsRequest(
        tagIds: (json['tag_ids'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        entityType: TagEntityType.fromJson(json['entity_type']?.toString()),
        entityIds: (json['entity_ids'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(growable: false),
        op: TagBatchOp.fromJson(json['op']?.toString()),
      );
}

@immutable
class BatchTagItemsResponse {
  final int affected;

  const BatchTagItemsResponse({this.affected = 0});

  factory BatchTagItemsResponse.fromJson(Map<String, dynamic> json) =>
      BatchTagItemsResponse(
        affected: (json['affected'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{'affected': affected};
}
