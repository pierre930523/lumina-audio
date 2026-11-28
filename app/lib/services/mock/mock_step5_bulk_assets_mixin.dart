part of '../mock_audio_service.dart';

final Uint8List _mock1x1PngBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

final Uint8List _mockMinimalPdfBytes = Uint8List.fromList(
  utf8.encode('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n'),
);

/// Rich in-memory MockAudioService implementation for Step 5 Tri-State Bulk
/// Metadata Editor and Album Assets (PDF Booklets & Multi-Image Gallery).
mixin _MockStep5BulkAssetsMixin
    on
        _MockAudioServiceBase,
        _MockAlbumGroupingMixin,
        _MockFocusTagsFoldersMixin,
        _MockStep4Mixin {
  Map<String, List<AlbumAssetRecord>>? _mockAlbumAssetsByVersion;
  final Map<String, Uint8List> _mockAssetBytesById = <String, Uint8List>{};
  final List<AlbumAssetRecord> _openedPdfAssets = <AlbumAssetRecord>[];

  /// Test helper: inspect PDF assets opened via [openAlbumPdfAsset].
  List<AlbumAssetRecord> get openedPdfAssets =>
      List<AlbumAssetRecord>.unmodifiable(_openedPdfAssets);

  AlbumAssetRecord? get lastOpenedPdfAsset =>
      _openedPdfAssets.isEmpty ? null : _openedPdfAssets.last;

  /// Test helper: override album assets and optional raw bytes for widget tests.
  void setMockAlbumAssets(
    String versionOrAlbumId,
    List<AlbumAssetRecord> assets, {
    Map<String, Uint8List>? bytesByAssetId,
  }) {
    final map = _ensureAlbumAssetsMap();
    map[versionOrAlbumId] = List<AlbumAssetRecord>.from(assets);
    if (bytesByAssetId != null) {
      _mockAssetBytesById.addAll(bytesByAssetId);
    }
  }

  TriStateFieldValue<Object?> _aggregateValues(List<Object?> values) {
    final nonEmpty = values
        .where((v) => v != null && (v is! String || v.trim().isNotEmpty))
        .toList(growable: false);
    if (nonEmpty.isEmpty) return const TriStateEmpty<Object?>();
    final unique = <Object?>[];
    for (final v in nonEmpty) {
      if (!unique.any((u) => u == v)) unique.add(v);
    }
    if (unique.length == 1 && nonEmpty.length == values.length) {
      return TriStateCommon<Object?>(unique.first);
    }
    return TriStateMixed<Object?>(
      distinctCount: unique.length,
      sampleValues: unique.take(3).toList(growable: false),
    );
  }

  @override
  Future<BulkEditSummary?> getBulkEditSummary(
    BulkEditEntityType entityType,
    List<String> entityIds,
  ) async {
    final ids = entityIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return BulkEditSummary(entityType: entityType, selectedCount: 0);
    }
    final prefix = entityType == BulkEditEntityType.album ? 'album' : 'track';
    final fieldNames = entityType == BulkEditEntityType.album
        ? const <String>[
            'title',
            'sort_title',
            'album_artist',
            'release_year',
            'upc',
            'editorial_bio',
          ]
        : const <String>[
            'title',
            'artist_name',
            'album_artist',
            'album_title',
            'disc_number',
            'track_number',
            'release_year',
            'genre',
            'composer',
            'isrc',
            'lyrics',
          ];

    final fields = <String, TriStateFieldValue<Object?>>{};
    for (final field in fieldNames) {
      final vals = <Object?>[];
      for (final id in ids) {
        final edits = _entityUserEdits['$prefix:$id'];
        if (edits != null && edits.containsKey(field)) {
          vals.add(edits[field]);
          continue;
        }
        if (entityType == BulkEditEntityType.album) {
          final g = _ensureAlbumGroups().where((e) => e.id == id).firstOrNull;
          vals.add(switch (field) {
            'title' => g?.title,
            'album_artist' => g?.artistName,
            'release_year' => g?.releaseYear,
            'editorial_bio' => g?.editorialBio,
            _ => null,
          });
        } else {
          final t = _queue.where((e) => e.id == id).firstOrNull;
          vals.add(switch (field) {
            'title' => t?.title,
            'artist_name' => t?.artist,
            'album_artist' => t?.albumArtist ?? t?.artist,
            'album_title' => t?.album,
            'disc_number' => t?.discNumber,
            'track_number' => t?.trackNumber,
            'release_year' => t?.year,
            'genre' => t?.genre,
            'composer' => t?.composer,
            _ => null,
          });
        }
      }
      fields[field] = _aggregateValues(vals);
    }

    final policyVals = ids
        .map(
          (id) =>
              (_entityMetaPolicies['$prefix:$id'] ?? _defaultMetadataPolicy)
                  .toJson(),
        )
        .toList(growable: false);
    final policyAgg = _aggregateValues(policyVals);
    final metaPolicy = switch (policyAgg) {
      TriStateCommon<Object?>(:final value) =>
        TriStateCommon<String>(value.toString()),
      TriStateMixed<Object?>(:final distinctCount, :final sampleValues) =>
        TriStateMixed<String>(
          distinctCount: distinctCount,
          sampleValues:
              sampleValues.map((e) => e.toString()).toList(growable: false),
        ),
      TriStateEmpty<Object?>() => const TriStateEmpty<String>(),
    };

    final tagType = entityType == BulkEditEntityType.album
        ? TagEntityType.albumGroup
        : TagEntityType.track;
    final store = _ensureFocusStore;
    final tags = store.tags.values.map((tag) {
      final count = ids
          .where((id) => store.tagItems.contains((tag.id, tagType, id)))
          .length;
      final state = count == 0
          ? TagSelectionState.none
          : (count == ids.length ? TagSelectionState.all : TagSelectionState.some);
      return BulkTagSummaryItem(
        tagId: tag.id,
        name: tag.name,
        color: tag.color,
        state: state,
        assignedCount: count,
        totalCount: ids.length,
      );
    }).toList(growable: false);

    final userEditsCount = ids
        .where((id) => (_entityUserEdits['$prefix:$id']?.isNotEmpty ?? false))
        .length;

    return BulkEditSummary(
      entityType: entityType,
      selectedCount: ids.length,
      fields: fields,
      metaPolicy: metaPolicy,
      tags: tags,
      hasUserEditsCount: userEditsCount,
    );
  }

  @override
  Future<BulkEditResult?> applyBulkEdit(
    BulkEditEntityType entityType,
    List<String> entityIds,
    BulkEditPatch patch,
  ) async {
    final ids = entityIds.where((id) => id.trim().isNotEmpty).toList();
    final prefix = entityType == BulkEditEntityType.album ? 'album' : 'track';
    final tagType = entityType == BulkEditEntityType.album
        ? TagEntityType.albumGroup
        : TagEntityType.track;
    var updated = 0;
    var reverted = 0;
    var tagsAdded = 0;
    var tagsRemoved = 0;

    for (final id in ids) {
      final key = '$prefix:$id';
      if (patch.revertToFileMeta) {
        _entityUserEdits.remove(key);
        reverted++;
      } else {
        var entityTouched = false;
        final map = _entityUserEdits.putIfAbsent(key, () => <String, dynamic>{});
        for (final entry in patch.fields.entries) {
          switch (entry.value) {
            case FieldPatchKeep<Object?>():
              break;
            case FieldPatchSet<Object?>(:final value):
              map[entry.key] = value;
              entityTouched = true;
            case FieldPatchClear<Object?>():
              map.remove(entry.key);
              entityTouched = true;
          }
        }
        switch (patch.metaPolicy) {
          case FieldPatchKeep<String>():
            break;
          case FieldPatchSet<String>(:final value):
            _entityMetaPolicies[key] = MetadataPolicy.fromJson(value);
            entityTouched = true;
          case FieldPatchClear<String>():
            _entityMetaPolicies.remove(key);
            entityTouched = true;
        }
        if (entityTouched) updated++;
      }

      final store = _ensureFocusStore;
      for (final tagId in patch.addTagIds) {
        if (store.tagItems.add((tagId, tagType, id))) {
          tagsAdded++;
        }
      }
      for (final tagId in patch.removeTagIds) {
        if (store.tagItems.remove((tagId, tagType, id))) {
          tagsRemoved++;
        }
      }
    }

    return BulkEditResult(
      entityType: entityType,
      updatedCount: updated,
      revertedCount: reverted,
      tagsAdded: tagsAdded,
      tagsRemoved: tagsRemoved,
    );
  }

  Map<String, List<AlbumAssetRecord>> _ensureAlbumAssetsMap() {
    if (_mockAlbumAssetsByVersion != null) return _mockAlbumAssetsByVersion!;
    const now = '2026-11-27T00:00:00Z';
    _mockAssetBytesById['asset-dsotm-booklet'] = _mockMinimalPdfBytes;
    _mockAssetBytesById['asset-dsotm-front'] = _mock1x1PngBytes;
    _mockAssetBytesById['asset-dsotm-back'] = _mock1x1PngBytes;
    _mockAlbumAssetsByVersion = <String, List<AlbumAssetRecord>>{
      'ver-qobuz': const <AlbumAssetRecord>[
        AlbumAssetRecord(
          id: 'asset-dsotm-booklet',
          albumVersionId: 'ver-qobuz',
          assetKind: AlbumAssetKind.pdf,
          sourceKind: AlbumAssetSourceKind.file,
          role: AlbumAssetRole.booklet,
          filePath: r'D:\Music\Pink Floyd\The Dark Side of the Moon\Booklet.pdf',
          mimeType: 'application/pdf',
          fileSize: 204800,
          displayName: 'Digital Booklet.pdf',
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
        ),
        AlbumAssetRecord(
          id: 'asset-dsotm-front',
          albumVersionId: 'ver-qobuz',
          assetKind: AlbumAssetKind.image,
          sourceKind: AlbumAssetSourceKind.file,
          role: AlbumAssetRole.front,
          filePath: r'D:\Music\Pink Floyd\The Dark Side of the Moon\cover.png',
          mimeType: 'image/png',
          width: 1400,
          height: 1400,
          fileSize: 512000,
          displayName: 'Front Cover',
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
        ),
        AlbumAssetRecord(
          id: 'asset-dsotm-back',
          albumVersionId: 'ver-qobuz',
          assetKind: AlbumAssetKind.image,
          sourceKind: AlbumAssetSourceKind.file,
          role: AlbumAssetRole.back,
          filePath: r'D:\Music\Pink Floyd\The Dark Side of the Moon\back.png',
          mimeType: 'image/png',
          width: 1400,
          height: 1400,
          fileSize: 488000,
          displayName: 'Back Cover',
          sortOrder: 1,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    };
    return _mockAlbumAssetsByVersion!;
  }

  @override
  Future<AlbumAssetsResponse?> getAlbumAssets(
    String albumVersionOrAlbumId,
  ) async {
    final map = _ensureAlbumAssetsMap();
    var targetVersionId = albumVersionOrAlbumId;
    var list = map[targetVersionId];
    if (list == null) {
      final group = _ensureAlbumGroups()
          .where((g) => g.id == albumVersionOrAlbumId)
          .firstOrNull;
      final primary = group?.primaryVersionId ?? group?.versions.firstOrNull?.id;
      if (primary != null) {
        targetVersionId = primary;
        list = map[primary];
      }
    }
    final records = list ?? const <AlbumAssetRecord>[];
    return AlbumAssetsResponse(
      albumVersionId: targetVersionId,
      pdfs: records
          .where((a) => a.assetKind == AlbumAssetKind.pdf)
          .toList(growable: false),
      images: records
          .where((a) => a.assetKind == AlbumAssetKind.image)
          .toList(growable: false),
      totalCount: records.length,
    );
  }

  @override
  Future<Uint8List?> readAlbumAssetBytes(String assetId) async {
    _ensureAlbumAssetsMap();
    return _mockAssetBytesById[assetId];
  }

  @override
  Future<bool> openAlbumPdfAsset(AlbumAssetRecord asset) async {
    _openedPdfAssets.add(asset);
    return true;
  }
}
