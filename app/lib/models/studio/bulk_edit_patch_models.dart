part of 'bulk_edit_models.dart';

/// Tagged union matching Rust `FieldPatchOp<T>` (`#[serde(tag = "op", rename_all = "snake_case")]`).
@immutable
sealed class FieldPatchOp<T> {
  const FieldPatchOp();

  const factory FieldPatchOp.keep() = FieldPatchKeep<T>;
  const factory FieldPatchOp.set(T value) = FieldPatchSet<T>;
  const factory FieldPatchOp.clear() = FieldPatchClear<T>;

  String get op;
  Map<String, dynamic> toJson([Object? Function(T value)? encode]);

  factory FieldPatchOp.fromJson(
    Map<String, dynamic> json,
    T Function(Object? raw) decode,
  ) => switch (json['op']?.toString().trim().toLowerCase()) {
    'set' => FieldPatchSet<T>(decode(json['value'])),
    'clear' => FieldPatchClear<T>(),
    _ => FieldPatchKeep<T>(),
  };
}

@immutable
final class FieldPatchKeep<T> extends FieldPatchOp<T> {
  const FieldPatchKeep();

  @override
  String get op => 'keep';

  @override
  Map<String, dynamic> toJson([Object? Function(T value)? encode]) =>
      <String, dynamic>{'op': op};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FieldPatchKeep<T>;

  @override
  int get hashCode => op.hashCode;
}

@immutable
final class FieldPatchSet<T> extends FieldPatchOp<T> {
  final T value;
  const FieldPatchSet(this.value);

  @override
  String get op => 'set';

  @override
  Map<String, dynamic> toJson([Object? Function(T value)? encode]) =>
      <String, dynamic>{
        'op': op,
        'value': encode != null ? encode(value) : value,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FieldPatchSet<T> && other.value == value;

  @override
  int get hashCode => Object.hash(op, value);
}

@immutable
final class FieldPatchClear<T> extends FieldPatchOp<T> {
  const FieldPatchClear();

  @override
  String get op => 'clear';

  @override
  Map<String, dynamic> toJson([Object? Function(T value)? encode]) =>
      <String, dynamic>{'op': op};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FieldPatchClear<T>;

  @override
  int get hashCode => op.hashCode;
}

/// Patch payload submitted to apply tri-state edits across selected albums or tracks.
@immutable
class BulkEditPatch {
  final Map<String, FieldPatchOp<Object?>> fields;
  final FieldPatchOp<String> metaPolicy;
  final List<String> addTagIds;
  final List<String> removeTagIds;
  final bool revertToFileMeta;

  const BulkEditPatch({
    this.fields = const <String, FieldPatchOp<Object?>>{},
    this.metaPolicy = const FieldPatchKeep<String>(),
    this.addTagIds = const <String>[],
    this.removeTagIds = const <String>[],
    this.revertToFileMeta = false,
  });

  factory BulkEditPatch.fromJson(Map<String, dynamic> json) {
    final parsedFields = <String, FieldPatchOp<Object?>>{};
    final rawFields = json['fields'];
    if (rawFields is Map) {
      for (final entry in rawFields.entries) {
        if (entry.value is Map) {
          parsedFields[entry.key.toString()] = FieldPatchOp<Object?>.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
            (raw) => raw,
          );
        }
      }
    }
    final rawPolicy = json['meta_policy'];
    return BulkEditPatch(
      fields: parsedFields,
      metaPolicy: rawPolicy is Map
          ? FieldPatchOp<String>.fromJson(
              Map<String, dynamic>.from(rawPolicy),
              (raw) => raw?.toString() ?? '',
            )
          : const FieldPatchKeep<String>(),
      addTagIds: _readStringList(json['add_tag_ids']),
      removeTagIds: _readStringList(json['remove_tag_ids']),
      revertToFileMeta: _readBool(json['revert_to_file_meta']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
    'meta_policy': metaPolicy.toJson(),
    'add_tag_ids': addTagIds,
    'remove_tag_ids': removeTagIds,
    'revert_to_file_meta': revertToFileMeta,
  };
}

/// Result counts returned after applying a [BulkEditPatch].
@immutable
class BulkEditResult {
  final BulkEditEntityType entityType;
  final int updatedCount;
  final int revertedCount;
  final int tagsAdded;
  final int tagsRemoved;
  final int recomputedGroups;
  final int prunedOrphanVersions;
  final int prunedOrphanAlbums;

  const BulkEditResult({
    required this.entityType,
    this.updatedCount = 0,
    this.revertedCount = 0,
    this.tagsAdded = 0,
    this.tagsRemoved = 0,
    this.recomputedGroups = 0,
    this.prunedOrphanVersions = 0,
    this.prunedOrphanAlbums = 0,
  });

  factory BulkEditResult.fromJson(Map<String, dynamic> json) => BulkEditResult(
    entityType: BulkEditEntityType.fromJson(json['entity_type']?.toString()),
    updatedCount: (json['updated_count'] as num?)?.toInt() ?? 0,
    revertedCount: (json['reverted_count'] as num?)?.toInt() ?? 0,
    tagsAdded: (json['tags_added'] as num?)?.toInt() ?? 0,
    tagsRemoved: (json['tags_removed'] as num?)?.toInt() ?? 0,
    recomputedGroups: (json['recomputed_groups'] as num?)?.toInt() ?? 0,
    prunedOrphanVersions: (json['pruned_orphan_versions'] as num?)?.toInt() ?? 0,
    prunedOrphanAlbums: (json['pruned_orphan_albums'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entity_type': entityType.toJson(),
    'updated_count': updatedCount,
    'reverted_count': revertedCount,
    'tags_added': tagsAdded,
    'tags_removed': tagsRemoved,
    'recomputed_groups': recomputedGroups,
    'pruned_orphan_versions': prunedOrphanVersions,
    'pruned_orphan_albums': prunedOrphanAlbums,
  };
}
