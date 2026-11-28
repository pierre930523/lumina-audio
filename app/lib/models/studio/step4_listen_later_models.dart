part of 'step4_models.dart';

/// Listen Later entry supporting both local library references and external
/// streaming snapshots without polluting the library catalog until promoted.
@immutable
class ListenLaterItem {
  final String id;
  final String sourceKind;
  final String entityType;
  final String? entityId;
  final String? providerId;
  final String? externalId;
  final String title;
  final String artistName;
  final String albumTitle;
  final String? coverUrl;
  final int? trackCount;
  final String? metadataJson;
  final String note;
  final String status;
  final String addedAt;
  final String? listenedAt;
  final String? promotedEntityId;

  const ListenLaterItem({
    required this.id,
    required this.sourceKind,
    required this.entityType,
    this.entityId,
    this.providerId,
    this.externalId,
    required this.title,
    this.artistName = '',
    this.albumTitle = '',
    this.coverUrl,
    this.trackCount,
    this.metadataJson,
    this.note = '',
    this.status = 'pending',
    this.addedAt = '',
    this.listenedAt,
    this.promotedEntityId,
  });

  bool get isPending => status == 'pending';
  bool get isListened => status == 'listened';
  bool get isLibrary => sourceKind == 'library';
  bool get isExternal => sourceKind == 'external';
  bool get isAlbum => entityType == 'album';
  bool get isTrack => entityType == 'track';
  bool get isPromoted =>
      promotedEntityId != null && promotedEntityId!.trim().isNotEmpty;

  Map<String, dynamic>? parseMetadata() {
    final raw = metadataJson?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  ListenLaterItem copyWith({
    String? id,
    String? sourceKind,
    String? entityType,
    String? entityId,
    String? providerId,
    String? externalId,
    String? title,
    String? artistName,
    String? albumTitle,
    String? coverUrl,
    int? trackCount,
    String? metadataJson,
    String? note,
    String? status,
    String? addedAt,
    String? listenedAt,
    bool clearListenedAt = false,
    String? promotedEntityId,
  }) => ListenLaterItem(
    id: id ?? this.id,
    sourceKind: sourceKind ?? this.sourceKind,
    entityType: entityType ?? this.entityType,
    entityId: entityId ?? this.entityId,
    providerId: providerId ?? this.providerId,
    externalId: externalId ?? this.externalId,
    title: title ?? this.title,
    artistName: artistName ?? this.artistName,
    albumTitle: albumTitle ?? this.albumTitle,
    coverUrl: coverUrl ?? this.coverUrl,
    trackCount: trackCount ?? this.trackCount,
    metadataJson: metadataJson ?? this.metadataJson,
    note: note ?? this.note,
    status: status ?? this.status,
    addedAt: addedAt ?? this.addedAt,
    listenedAt: clearListenedAt ? null : (listenedAt ?? this.listenedAt),
    promotedEntityId: promotedEntityId ?? this.promotedEntityId,
  );

  factory ListenLaterItem.fromJson(Map<String, dynamic> json) =>
      ListenLaterItem(
        id: json['id']?.toString() ?? '',
        sourceKind: json['source_kind']?.toString() ?? 'library',
        entityType: json['entity_type']?.toString() ?? 'album',
        entityId: _readOptionalString(json['entity_id']),
        providerId: _readOptionalString(json['provider_id']),
        externalId: _readOptionalString(json['external_id']),
        title: json['title']?.toString() ?? '',
        artistName: json['artist_name']?.toString() ?? '',
        albumTitle: json['album_title']?.toString() ?? '',
        coverUrl: _readOptionalString(json['cover_url']),
        trackCount: (json['track_count'] as num?)?.toInt(),
        metadataJson: _readOptionalString(json['metadata_json']),
        note: json['note']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
        addedAt: json['added_at']?.toString() ?? '',
        listenedAt: _readOptionalString(json['listened_at']),
        promotedEntityId: _readOptionalString(json['promoted_entity_id']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'source_kind': sourceKind,
    'entity_type': entityType,
    if (entityId != null) 'entity_id': entityId,
    if (providerId != null) 'provider_id': providerId,
    if (externalId != null) 'external_id': externalId,
    'title': title,
    'artist_name': artistName,
    'album_title': albumTitle,
    if (coverUrl != null) 'cover_url': coverUrl,
    if (trackCount != null) 'track_count': trackCount,
    if (metadataJson != null) 'metadata_json': metadataJson,
    'note': note,
    'status': status,
    'added_at': addedAt,
    if (listenedAt != null) 'listened_at': listenedAt,
    if (promotedEntityId != null) 'promoted_entity_id': promotedEntityId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ListenLaterItem &&
          other.id == id &&
          other.sourceKind == sourceKind &&
          other.entityType == entityType &&
          other.entityId == entityId &&
          other.providerId == providerId &&
          other.externalId == externalId &&
          other.title == title &&
          other.artistName == artistName &&
          other.albumTitle == albumTitle &&
          other.coverUrl == coverUrl &&
          other.trackCount == trackCount &&
          other.metadataJson == metadataJson &&
          other.note == note &&
          other.status == status &&
          other.addedAt == addedAt &&
          other.listenedAt == listenedAt &&
          other.promotedEntityId == promotedEntityId;

  @override
  int get hashCode => Object.hash(
    id,
    sourceKind,
    entityType,
    entityId,
    providerId,
    externalId,
    title,
    artistName,
    albumTitle,
    coverUrl,
    trackCount,
    metadataJson,
    note,
    status,
    addedAt,
    listenedAt,
    promotedEntityId,
  );
}

/// Result of promoting an external streaming Listen Later entry into the library.
@immutable
class PromoteListenLaterResult {
  final ListenLaterItem item;
  final String promotedEntityId;

  const PromoteListenLaterResult({
    required this.item,
    required this.promotedEntityId,
  });

  factory PromoteListenLaterResult.fromJson(Map<String, dynamic> json) {
    final rawItem = json['item'];
    return PromoteListenLaterResult(
      item: rawItem is Map
          ? ListenLaterItem.fromJson(Map<String, dynamic>.from(rawItem))
          : const ListenLaterItem(
              id: '',
              sourceKind: 'external',
              entityType: 'album',
              title: '',
            ),
      promotedEntityId: json['promoted_entity_id']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'item': item.toJson(),
    'promoted_entity_id': promotedEntityId,
  };
}
