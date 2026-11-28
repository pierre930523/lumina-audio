import 'package:flutter/foundation.dart';

/// Media category of an album asset (PDF digital booklet vs gallery image).
enum AlbumAssetKind {
  pdf('pdf'),
  image('image');

  final String wireName;

  const AlbumAssetKind(this.wireName);

  String toJson() => wireName;

  static AlbumAssetKind fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'image' => AlbumAssetKind.image,
        _ => AlbumAssetKind.pdf,
      };
}

/// Origin of an album asset: standalone file in album folder or embedded picture tag.
enum AlbumAssetSourceKind {
  file('file'),
  embedded('embedded');

  final String wireName;

  const AlbumAssetSourceKind(this.wireName);

  String toJson() => wireName;

  static AlbumAssetSourceKind fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'embedded' => AlbumAssetSourceKind.embedded,
        _ => AlbumAssetSourceKind.file,
      };
}

/// Semantic visual role of an album asset.
enum AlbumAssetRole {
  front('front'),
  back('back'),
  media('media'),
  booklet('booklet'),
  other('other');

  final String wireName;

  const AlbumAssetRole(this.wireName);

  String toJson() => wireName;

  static AlbumAssetRole fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'front' => AlbumAssetRole.front,
        'back' => AlbumAssetRole.back,
        'media' => AlbumAssetRole.media,
        'booklet' => AlbumAssetRole.booklet,
        _ => AlbumAssetRole.other,
      };
}

/// Metadata record for one PDF booklet or artwork image attached to an album version.
@immutable
class AlbumAssetRecord {
  final String id;
  final String albumVersionId;
  final AlbumAssetKind assetKind;
  final AlbumAssetSourceKind sourceKind;
  final AlbumAssetRole role;
  final String? filePath;
  final String? embeddedTrackId;
  final int? embeddedPicIndex;
  final String mimeType;
  final int? width;
  final int? height;
  final int? fileSize;
  final String displayName;
  final int sortOrder;
  final String createdAt;
  final String updatedAt;

  const AlbumAssetRecord({
    required this.id,
    required this.albumVersionId,
    required this.assetKind,
    required this.sourceKind,
    this.role = AlbumAssetRole.other,
    this.filePath,
    this.embeddedTrackId,
    this.embeddedPicIndex,
    required this.mimeType,
    this.width,
    this.height,
    this.fileSize,
    this.displayName = '',
    this.sortOrder = 0,
    this.createdAt = '',
    this.updatedAt = '',
  });

  factory AlbumAssetRecord.fromJson(Map<String, dynamic> json) =>
      AlbumAssetRecord(
        id: json['id']?.toString() ?? '',
        albumVersionId: json['album_version_id']?.toString() ?? '',
        assetKind: AlbumAssetKind.fromJson(json['asset_kind']?.toString()),
        sourceKind: AlbumAssetSourceKind.fromJson(json['source_kind']?.toString()),
        role: AlbumAssetRole.fromJson(json['role']?.toString()),
        filePath: json['file_path']?.toString(),
        embeddedTrackId: json['embedded_track_id']?.toString(),
        embeddedPicIndex: (json['embedded_pic_index'] as num?)?.toInt(),
        mimeType: json['mime_type']?.toString() ?? '',
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        fileSize: (json['file_size'] as num?)?.toInt(),
        displayName: json['display_name']?.toString() ?? '',
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        createdAt: json['created_at']?.toString() ?? '',
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'album_version_id': albumVersionId,
    'asset_kind': assetKind.toJson(),
    'source_kind': sourceKind.toJson(),
    'role': role.toJson(),
    if (filePath != null) 'file_path': filePath,
    if (embeddedTrackId != null) 'embedded_track_id': embeddedTrackId,
    if (embeddedPicIndex != null) 'embedded_pic_index': embeddedPicIndex,
    'mime_type': mimeType,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (fileSize != null) 'file_size': fileSize,
    'display_name': displayName,
    'sort_order': sortOrder,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlbumAssetRecord &&
          other.id == id &&
          other.albumVersionId == albumVersionId &&
          other.assetKind == assetKind &&
          other.sourceKind == sourceKind &&
          other.role == role &&
          other.filePath == filePath &&
          other.embeddedTrackId == embeddedTrackId &&
          other.embeddedPicIndex == embeddedPicIndex &&
          other.mimeType == mimeType &&
          other.width == width &&
          other.height == height &&
          other.fileSize == fileSize &&
          other.displayName == displayName &&
          other.sortOrder == sortOrder &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    albumVersionId,
    assetKind,
    sourceKind,
    role,
    filePath,
    embeddedTrackId,
    embeddedPicIndex,
    mimeType,
    width,
    height,
    fileSize,
    displayName,
    sortOrder,
    createdAt,
    updatedAt,
  );
}

/// Grouped PDF booklets and gallery images for a specific album version.
@immutable
class AlbumAssetsResponse {
  final String albumVersionId;
  final List<AlbumAssetRecord> pdfs;
  final List<AlbumAssetRecord> images;
  final int totalCount;

  const AlbumAssetsResponse({
    this.albumVersionId = '',
    this.pdfs = const <AlbumAssetRecord>[],
    this.images = const <AlbumAssetRecord>[],
    this.totalCount = 0,
  });

  factory AlbumAssetsResponse.fromJson(Map<String, dynamic> json) {
    final rawPdfs = json['pdfs'] as List<dynamic>? ?? const [];
    final rawImages = json['images'] as List<dynamic>? ?? const [];
    return AlbumAssetsResponse(
      albumVersionId: json['album_version_id']?.toString() ?? '',
      pdfs: rawPdfs
          .whereType<Map>()
          .map((e) => AlbumAssetRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      images: rawImages
          .whereType<Map>()
          .map((e) => AlbumAssetRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false),
      totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'album_version_id': albumVersionId,
    'pdfs': pdfs.map((e) => e.toJson()).toList(growable: false),
    'images': images.map((e) => e.toJson()).toList(growable: false),
    'total_count': totalCount,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlbumAssetsResponse &&
          other.albumVersionId == albumVersionId &&
          listEquals(other.pdfs, pdfs) &&
          listEquals(other.images, images) &&
          other.totalCount == totalCount;

  @override
  int get hashCode => Object.hash(
    albumVersionId,
    Object.hashAll(pdfs),
    Object.hashAll(images),
    totalCount,
  );
}
