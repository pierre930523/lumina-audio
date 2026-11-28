import 'package:flutter/foundation.dart';

import '../playback_state.dart';
import 'studio_library_models.dart';

part 'focus_response_models.dart';

/// Target library entity queried by the Focus multi-dimensional filter engine.
enum FocusEntity {
  albums,
  tracks;

  String toJson() => name;

  static FocusEntity fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'tracks' => FocusEntity.tracks,
        _ => FocusEntity.albums,
      };
}

/// Include (positive) or exclude (NOT / negated) predicate mode.
enum FocusPredicateMode {
  include,
  exclude;

  String toJson() => name;

  static FocusPredicateMode fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'exclude' => FocusPredicateMode.exclude,
        _ => FocusPredicateMode.include,
      };

  FocusPredicateMode get toggled => this == FocusPredicateMode.include
      ? FocusPredicateMode.exclude
      : FocusPredicateMode.include;
}

/// Supported Focus filter facets matching the Rust `FocusFacet` enum.
enum FocusFacet {
  format('format', '格式'),
  bitDepth('bit_depth', '位元深度'),
  sampleRate('sample_rate', '取樣率'),
  channels('channels', '聲道'),
  source('source', '來源'),
  releaseYear('release_year', '發行年份'),
  addedAt('added_at', '加入時間'),
  playStatus('play_status', '播放狀態'),
  genre('genre', '流派'),
  label('label', '廠牌'),
  tag('tag', '標籤'),
  inspector('inspector', '檢視器'),
  preference('preference', '偏好');

  final String wireName;
  final String displayLabel;

  const FocusFacet(this.wireName, this.displayLabel);

  String toJson() => wireName;

  static FocusFacet fromJson(String? raw) {
    final norm = raw?.trim().toLowerCase() ?? '';
    for (final v in values) {
      if (v.wireName == norm || v.name.toLowerCase() == norm) {
        return v;
      }
    }
    return FocusFacet.format;
  }
}

/// Tagged union predicate value serialized as `{ "kind": "...", ... }`.
@immutable
sealed class FocusValue {
  const FocusValue();

  const factory FocusValue.string(String value) = FocusStringValue;
  const factory FocusValue.int(int value) = FocusIntValue;
  const factory FocusValue.intRange({int? min, int? max}) = FocusIntRangeValue;
  const factory FocusValue.dateRange({String? from, String? to}) =
      FocusDateRangeValue;

  String get kind;
  Map<String, dynamic> toJson();

  factory FocusValue.fromJson(Map<String, dynamic> json) {
    return switch (json['kind']?.toString().trim().toLowerCase()) {
      'int' => FocusIntValue((json['value'] as num?)?.toInt() ?? 0),
      'int_range' => FocusIntRangeValue(
        min: (json['min'] as num?)?.toInt(),
        max: (json['max'] as num?)?.toInt(),
      ),
      'date_range' => FocusDateRangeValue(
        from: json['from']?.toString(),
        to: json['to']?.toString(),
      ),
      _ => FocusStringValue(json['value']?.toString() ?? ''),
    };
  }
}

@immutable
final class FocusStringValue extends FocusValue {
  final String value;

  const FocusStringValue(this.value);

  @override
  String get kind => 'string';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'value': value,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusStringValue && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

@immutable
final class FocusIntValue extends FocusValue {
  final int value;

  const FocusIntValue(this.value);

  @override
  String get kind => 'int';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'value': value,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FocusIntValue && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

@immutable
final class FocusIntRangeValue extends FocusValue {
  final int? min;
  final int? max;

  const FocusIntRangeValue({this.min, this.max});

  @override
  String get kind => 'int_range';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusIntRangeValue && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(kind, min, max);
}

@immutable
final class FocusDateRangeValue extends FocusValue {
  final String? from;
  final String? to;

  const FocusDateRangeValue({this.from, this.to});

  @override
  String get kind => 'date_range';

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    if (from != null) 'from': from,
    if (to != null) 'to': to,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusDateRangeValue && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(kind, from, to);
}

/// Single filter pill inside a [FocusQuery].
@immutable
class FocusPredicate {
  final FocusFacet facet;
  final FocusValue value;
  final FocusPredicateMode mode;

  const FocusPredicate({
    required this.facet,
    required this.value,
    this.mode = FocusPredicateMode.include,
  });

  FocusPredicate toggledMode() => copyWith(mode: mode.toggled);

  FocusPredicate copyWith({
    FocusFacet? facet,
    FocusValue? value,
    FocusPredicateMode? mode,
  }) => FocusPredicate(
    facet: facet ?? this.facet,
    value: value ?? this.value,
    mode: mode ?? this.mode,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'facet': facet.toJson(),
    'value': value.toJson(),
    'mode': mode.toJson(),
  };

  factory FocusPredicate.fromJson(Map<String, dynamic> json) {
    final rawVal = json['value'];
    final parsedVal = rawVal is Map<String, dynamic>
        ? FocusValue.fromJson(rawVal)
        : rawVal is Map
        ? FocusValue.fromJson(Map<String, dynamic>.from(rawVal))
        : FocusStringValue(rawVal?.toString() ?? '');
    return FocusPredicate(
      facet: FocusFacet.fromJson(json['facet']?.toString()),
      value: parsedVal,
      mode: FocusPredicateMode.fromJson(json['mode']?.toString()),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusPredicate &&
          other.facet == facet &&
          other.value == value &&
          other.mode == mode;

  @override
  int get hashCode => Object.hash(facet, value, mode);
}

enum FocusSortField {
  title('title', '名稱'),
  artist('artist', '藝術家'),
  releaseYear('release_year', '發行年份'),
  addedAt('added_at', '加入時間'),
  sampleRate('sample_rate', '取樣率'),
  duration('duration', '時長'),
  random('random', '隨機');

  final String wireName;
  final String displayLabel;

  const FocusSortField(this.wireName, this.displayLabel);

  String toJson() => wireName;

  static FocusSortField fromJson(String? raw) {
    final norm = raw?.trim().toLowerCase() ?? '';
    for (final v in values) {
      if (v.wireName == norm || v.name.toLowerCase() == norm) {
        return v;
      }
    }
    return FocusSortField.title;
  }
}

enum FocusSortDirection {
  asc,
  desc;

  String toJson() => name;

  static FocusSortDirection fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'desc' => FocusSortDirection.desc,
        _ => FocusSortDirection.asc,
      };
}

@immutable
class FocusSort {
  final FocusSortField field;
  final FocusSortDirection direction;
  final int? seed;

  const FocusSort({
    required this.field,
    this.direction = FocusSortDirection.asc,
    this.seed,
  });

  FocusSort copyWith({
    FocusSortField? field,
    FocusSortDirection? direction,
    int? seed,
    bool clearSeed = false,
  }) => FocusSort(
    field: field ?? this.field,
    direction: direction ?? this.direction,
    seed: clearSeed ? null : (seed ?? this.seed),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'field': field.toJson(),
    'direction': direction.toJson(),
    if (seed != null) 'seed': seed,
  };

  factory FocusSort.fromJson(Map<String, dynamic> json) => FocusSort(
    field: FocusSortField.fromJson(json['field']?.toString()),
    direction: FocusSortDirection.fromJson(json['direction']?.toString()),
    seed: (json['seed'] as num?)?.toInt(),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusSort &&
          other.field == field &&
          other.direction == direction &&
          other.seed == seed;

  @override
  int get hashCode => Object.hash(field, direction, seed);
}
