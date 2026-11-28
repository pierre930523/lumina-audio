part of 'focus_models.dart';

/// Complete multi-dimensional Focus query state.
@immutable
class FocusQuery {
  final FocusEntity entity;
  final List<FocusPredicate> predicates;
  final FocusSort? sort;
  final bool includeHidden;
  final String? profileId;

  const FocusQuery({
    this.entity = FocusEntity.albums,
    this.predicates = const <FocusPredicate>[],
    this.sort,
    this.includeHidden = false,
    this.profileId,
  });

  bool get hasPredicates => predicates.isNotEmpty;

  FocusQuery copyWith({
    FocusEntity? entity,
    List<FocusPredicate>? predicates,
    FocusSort? sort,
    bool clearSort = false,
    bool? includeHidden,
    String? profileId,
    bool clearProfileId = false,
  }) => FocusQuery(
    entity: entity ?? this.entity,
    predicates: predicates ?? this.predicates,
    sort: clearSort ? null : (sort ?? this.sort),
    includeHidden: includeHidden ?? this.includeHidden,
    profileId: clearProfileId ? null : (profileId ?? this.profileId),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entity': entity.toJson(),
    'predicates': predicates.map((p) => p.toJson()).toList(growable: false),
    if (sort != null) 'sort': sort!.toJson(),
    'include_hidden': includeHidden,
    if (profileId != null && profileId!.isNotEmpty) 'profile_id': profileId,
  };

  factory FocusQuery.fromJson(Map<String, dynamic> json) {
    final rawPreds = json['predicates'] as List<dynamic>? ?? const [];
    final rawSort = json['sort'];
    return FocusQuery(
      entity: FocusEntity.fromJson(json['entity']?.toString()),
      predicates: rawPreds
          .whereType<Map>()
          .map((e) => FocusPredicate.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      sort: rawSort is Map
          ? FocusSort.fromJson(Map<String, dynamic>.from(rawSort))
          : null,
      includeHidden:
          json['include_hidden'] == true || json['include_hidden'] == 1,
      profileId: json['profile_id']?.toString(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusQuery &&
          other.entity == entity &&
          listEquals(other.predicates, predicates) &&
          other.sort == sort &&
          other.includeHidden == includeHidden &&
          other.profileId == profileId;

  @override
  int get hashCode => Object.hash(
    entity,
    Object.hashAll(predicates),
    sort,
    includeHidden,
    profileId,
  );
}

@immutable
class FocusQueryRequest {
  final FocusQuery query;
  final int limit;
  final int offset;

  const FocusQueryRequest({
    required this.query,
    this.limit = 100,
    this.offset = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'query': query.toJson(),
    'limit': limit,
    'offset': offset,
  };

  factory FocusQueryRequest.fromJson(Map<String, dynamic> json) {
    final rawQuery = json['query'];
    return FocusQueryRequest(
      query: rawQuery is Map
          ? FocusQuery.fromJson(Map<String, dynamic>.from(rawQuery))
          : const FocusQuery(),
      limit: (json['limit'] as num?)?.toInt() ?? 100,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class FocusQueryResponse {
  final FocusEntity entity;
  final int totalCount;
  final int limit;
  final int offset;
  final List<CanonicalAlbumSummary> albums;
  final List<TrackInfo> tracks;

  const FocusQueryResponse({
    this.entity = FocusEntity.albums,
    this.totalCount = 0,
    this.limit = 100,
    this.offset = 0,
    this.albums = const <CanonicalAlbumSummary>[],
    this.tracks = const <TrackInfo>[],
  });

  factory FocusQueryResponse.fromJson(Map<String, dynamic> json) {
    final rawAlbums = json['albums'] as List<dynamic>? ?? const [];
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    return FocusQueryResponse(
      entity: FocusEntity.fromJson(json['entity']?.toString()),
      totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 100,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      albums: rawAlbums
          .whereType<Map>()
          .map(
            (e) => CanonicalAlbumSummary.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
      tracks: rawTracks
          .whereType<Map>()
          .map((e) => TrackInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }
}

@immutable
class FocusFacetBucket {
  final String value;
  final String label;
  final int count;

  const FocusFacetBucket({
    required this.value,
    required this.label,
    required this.count,
  });

  static String preferenceBucketLabel(String rawValue) =>
      switch (rawValue.trim().toLowerCase()) {
        'favorite' || 'loved' || '1' => '喜愛',
        'neutral' || '0' => '普通',
        'banned' || 'blocked' || '-1' => '已封鎖',
        _ => rawValue,
      };

  static int? preferenceIntForBucket(String rawValue) =>
      switch (rawValue.trim().toLowerCase()) {
        'favorite' || 'loved' || '1' => 1,
        'neutral' || '0' => 0,
        'banned' || 'blocked' || '-1' => -1,
        _ => null,
      };

  factory FocusFacetBucket.fromJson(Map<String, dynamic> json) =>
      FocusFacetBucket(
        value: json['value']?.toString() ?? '',
        label: json['label']?.toString() ?? json['value']?.toString() ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'value': value,
    'label': label,
    'count': count,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusFacetBucket &&
          other.value == value &&
          other.label == label &&
          other.count == count;

  @override
  int get hashCode => Object.hash(value, label, count);
}

@immutable
class FocusIntRangeBounds {
  final int? min;
  final int? max;

  const FocusIntRangeBounds({this.min, this.max});

  factory FocusIntRangeBounds.fromJson(Map<String, dynamic> json) =>
      FocusIntRangeBounds(
        min: (json['min'] as num?)?.toInt(),
        max: (json['max'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (min != null) 'min': min,
    if (max != null) 'max': max,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FocusIntRangeBounds && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);
}

@immutable
class FocusFacetsResponse {
  final int totalMatched;
  final Map<String, List<FocusFacetBucket>> facets;
  final FocusIntRangeBounds yearRange;

  const FocusFacetsResponse({
    this.totalMatched = 0,
    this.facets = const <String, List<FocusFacetBucket>>{},
    this.yearRange = const FocusIntRangeBounds(),
  });

  List<FocusFacetBucket> bucketsFor(FocusFacet facet) =>
      facets[facet.wireName] ?? const <FocusFacetBucket>[];

  factory FocusFacetsResponse.fromJson(Map<String, dynamic> json) {
    final parsedFacets = <String, List<FocusFacetBucket>>{};
    final rawFacets = json['facets'];
    if (rawFacets is Map) {
      for (final entry in rawFacets.entries) {
        final key = entry.key.toString();
        final list = entry.value;
        if (list is List) {
          parsedFacets[key] = list
              .whereType<Map>()
              .map(
                (e) => FocusFacetBucket.fromJson(Map<String, dynamic>.from(e)),
              )
              .toList(growable: false);
        }
      }
    }
    final rawYear = json['year_range'];
    return FocusFacetsResponse(
      totalMatched: (json['total_matched'] as num?)?.toInt() ?? 0,
      facets: parsedFacets,
      yearRange: rawYear is Map
          ? FocusIntRangeBounds.fromJson(Map<String, dynamic>.from(rawYear))
          : const FocusIntRangeBounds(),
    );
  }
}
