import 'package:flutter/foundation.dart';

part 'bulk_edit_patch_models.dart';

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

/// Target entity type for tri-state bulk metadata editing.
enum BulkEditEntityType {
  album('album'),
  track('track');

  final String wireName;
  const BulkEditEntityType(this.wireName);

  String toJson() => wireName;

  static BulkEditEntityType fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'track' => BulkEditEntityType.track,
        _ => BulkEditEntityType.album,
      };
}

/// Tagged union matching Rust `TriStateFieldValue<T>` (`#[serde(tag = "state", rename_all = "snake_case")]`).
@immutable
sealed class TriStateFieldValue<T> {
  const TriStateFieldValue();

  const factory TriStateFieldValue.empty() = TriStateEmpty<T>;
  const factory TriStateFieldValue.common(T value) = TriStateCommon<T>;
  const factory TriStateFieldValue.mixed({
    required int distinctCount,
    List<T> sampleValues,
  }) = TriStateMixed<T>;

  String get state;
  bool get isEmpty => this is TriStateEmpty<T>;
  bool get isCommon => this is TriStateCommon<T>;
  bool get isMixed => this is TriStateMixed<T>;
  T? get commonValue => switch (this) {
    TriStateCommon<T>(:final value) => value,
    _ => null,
  };

  Map<String, dynamic> toJson([Object? Function(T value)? encode]);

  factory TriStateFieldValue.fromJson(
    Map<String, dynamic> json,
    T Function(Object? raw) decode,
  ) => switch (json['state']?.toString().trim().toLowerCase()) {
    'common' => TriStateCommon<T>(decode(json['value'])),
    'mixed' => TriStateMixed<T>(
      distinctCount: (json['distinct_count'] as num?)?.toInt() ?? 0,
      sampleValues: (json['sample_values'] as List<dynamic>? ?? const [])
          .map((e) => decode(e))
          .toList(growable: false),
    ),
    _ => TriStateEmpty<T>(),
  };
}

@immutable
final class TriStateEmpty<T> extends TriStateFieldValue<T> {
  const TriStateEmpty();

  @override
  String get state => 'empty';

  @override
  Map<String, dynamic> toJson([Object? Function(T value)? encode]) =>
      <String, dynamic>{'state': state};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TriStateEmpty<T>;

  @override
  int get hashCode => state.hashCode;
}

@immutable
final class TriStateCommon<T> extends TriStateFieldValue<T> {
  final T value;
  const TriStateCommon(this.value);

  @override
  String get state => 'common';

  @override
  Map<String, dynamic> toJson([Object? Function(T value)? encode]) =>
      <String, dynamic>{
        'state': state,
        'value': encode != null ? encode(value) : value,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TriStateCommon<T> && other.value == value;

  @override
  int get hashCode => Object.hash(state, value);
}

@immutable
final class TriStateMixed<T> extends TriStateFieldValue<T> {
  final int distinctCount;
  final List<T> sampleValues;

  const TriStateMixed({required this.distinctCount, this.sampleValues = const []});

  @override
  String get state => 'mixed';

  @override
  Map<String, dynamic> toJson([Object? Function(T value)? encode]) =>
      <String, dynamic>{
        'state': state,
        'distinct_count': distinctCount,
        'sample_values': encode != null
            ? sampleValues.map(encode).toList(growable: false)
            : sampleValues,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TriStateMixed<T> &&
          other.distinctCount == distinctCount &&
          listEquals(other.sampleValues, sampleValues);

  @override
  int get hashCode => Object.hash(state, distinctCount, Object.hashAll(sampleValues));
}

/// Tri-state tag assignment coverage across a bulk selection.
enum TagSelectionState {
  none('none'),
  some('some'),
  all('all');

  final String wireName;
  const TagSelectionState(this.wireName);

  String toJson() => wireName;

  static TagSelectionState fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'some' => TagSelectionState.some,
        'all' => TagSelectionState.all,
        _ => TagSelectionState.none,
      };
}

/// Per-tag summary inside a [BulkEditSummary].
@immutable
class BulkTagSummaryItem {
  final String tagId;
  final String name;
  final String? color;
  final TagSelectionState state;
  final int assignedCount;
  final int totalCount;

  const BulkTagSummaryItem({
    required this.tagId,
    required this.name,
    this.color,
    this.state = TagSelectionState.none,
    this.assignedCount = 0,
    this.totalCount = 0,
  });

  factory BulkTagSummaryItem.fromJson(Map<String, dynamic> json) =>
      BulkTagSummaryItem(
        tagId: json['tag_id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        color: json['color']?.toString(),
        state: TagSelectionState.fromJson(json['state']?.toString()),
        assignedCount: (json['assigned_count'] as num?)?.toInt() ?? 0,
        totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'tag_id': tagId,
    'name': name,
    if (color != null) 'color': color,
    'state': state.toJson(),
    'assigned_count': assignedCount,
    'total_count': totalCount,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BulkTagSummaryItem &&
          other.tagId == tagId &&
          other.name == name &&
          other.color == color &&
          other.state == state &&
          other.assignedCount == assignedCount &&
          other.totalCount == totalCount;

  @override
  int get hashCode =>
      Object.hash(tagId, name, color, state, assignedCount, totalCount);
}

/// Aggregated tri-state field & tag summary for a multi-item selection.
@immutable
class BulkEditSummary {
  final BulkEditEntityType entityType;
  final int selectedCount;
  final Map<String, TriStateFieldValue<Object?>> fields;
  final TriStateFieldValue<String> metaPolicy;
  final List<BulkTagSummaryItem> tags;
  final int hasUserEditsCount;

  const BulkEditSummary({
    required this.entityType,
    this.selectedCount = 0,
    this.fields = const <String, TriStateFieldValue<Object?>>{},
    this.metaPolicy = const TriStateEmpty<String>(),
    this.tags = const <BulkTagSummaryItem>[],
    this.hasUserEditsCount = 0,
  });

  factory BulkEditSummary.fromJson(Map<String, dynamic> json) {
    final parsedFields = <String, TriStateFieldValue<Object?>>{};
    final rawFields = json['fields'];
    if (rawFields is Map) {
      for (final entry in rawFields.entries) {
        if (entry.value is Map) {
          parsedFields[entry.key.toString()] = TriStateFieldValue<Object?>.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
            (raw) => raw,
          );
        }
      }
    }
    final rawPolicy = json['meta_policy'];
    final rawTags = json['tags'] as List<dynamic>? ?? const [];
    return BulkEditSummary(
      entityType: BulkEditEntityType.fromJson(json['entity_type']?.toString()),
      selectedCount: (json['selected_count'] as num?)?.toInt() ?? 0,
      fields: parsedFields,
      metaPolicy: rawPolicy is Map
          ? TriStateFieldValue<String>.fromJson(
              Map<String, dynamic>.from(rawPolicy),
              (raw) => raw?.toString() ?? '',
            )
          : const TriStateEmpty<String>(),
      tags: rawTags
          .whereType<Map>()
          .map((e) => BulkTagSummaryItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      hasUserEditsCount: (json['has_user_edits_count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entity_type': entityType.toJson(),
    'selected_count': selectedCount,
    'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
    'meta_policy': metaPolicy.toJson(),
    'tags': tags.map((t) => t.toJson()).toList(growable: false),
    'has_user_edits_count': hasUserEditsCount,
  };
}
