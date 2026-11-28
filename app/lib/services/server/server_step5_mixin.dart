part of '../server_audio_service.dart';

/// Implements Library Step 5 Static Playlists & Improver, Bulk Metadata Editor,
/// and Album Assets over REST. Backup/Restore & Export live in
/// [_ServerStep5BackupExportMixin].
mixin _ServerStep5Mixin on _ServerAudioServiceBase {
  @override
  Future<List<StaticPlaylistSummary>> listStaticPlaylists() async {
    final (code, data) = await _requestJson('GET', '/api/v1/library/playlists');
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map(
            (e) => StaticPlaylistSummary.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false);
    }
    return const <StaticPlaylistSummary>[];
  }

  @override
  Future<StaticPlaylistDetail?> createStaticPlaylist(
    CreateStaticPlaylistRequest req,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/playlists',
      body: req.toJson(),
    );
    if ((code == 200 || code == 201) && data is Map) {
      return StaticPlaylistDetail.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<StaticPlaylistDetail?> getStaticPlaylistDetail(
    String playlistId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/playlists/${Uri.encodeComponent(playlistId)}',
    );
    if (code == 200 && data is Map) {
      return StaticPlaylistDetail.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> deleteStaticPlaylist(String playlistId) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/playlists/${Uri.encodeComponent(playlistId)}',
    );
    if (code != 200 && code != 204) return false;
    if (data is Map && data.containsKey('deleted')) {
      return data['deleted'] == true;
    }
    return true;
  }

  @override
  Future<StaticPlaylistDetail?> addTracksToStaticPlaylist(
    String playlistId,
    AddStaticPlaylistTracksRequest req,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/playlists/${Uri.encodeComponent(playlistId)}/tracks',
      body: req.toJson(),
    );
    if ((code == 200 || code == 201) && data is Map) {
      return StaticPlaylistDetail.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<PlaylistImprovementReport?> analyzePlaylistImprovements(
    String playlistId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/playlists/${Uri.encodeComponent(playlistId)}/improvements',
      timeout: const Duration(seconds: 30),
    );
    if (code == 200 && data is Map) {
      return PlaylistImprovementReport.fromJson(
        Map<String, dynamic>.from(data),
      );
    }
    return null;
  }

  @override
  Future<ApplyPlaylistImprovementsResult?> applyPlaylistImprovements(
    String playlistId,
    ApplyPlaylistImprovementsRequest req,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/playlists/${Uri.encodeComponent(playlistId)}/improvements/apply',
      body: req.toJson(),
      timeout: const Duration(seconds: 30),
    );
    if (code == 200 && data is Map) {
      return ApplyPlaylistImprovementsResult.fromJson(
        Map<String, dynamic>.from(data),
      );
    }
    return null;
  }

  @override
  Future<List<PlaylistSnapshotRecord>> listPlaylistSnapshots(
    String playlistId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/playlists/${Uri.encodeComponent(playlistId)}/snapshots',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map(
            (e) =>
                PlaylistSnapshotRecord.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false);
    }
    return const <PlaylistSnapshotRecord>[];
  }

  @override
  Future<RevertPlaylistSnapshotResult?> revertPlaylistSnapshot(
    String snapshotId,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/playlists/snapshots/${Uri.encodeComponent(snapshotId)}/revert',
    );
    if (code == 200 && data is Map) {
      return RevertPlaylistSnapshotResult.fromJson(
        Map<String, dynamic>.from(data),
      );
    }
    return null;
  }

  @override
  Future<BulkEditSummary?> getBulkEditSummary(
    BulkEditEntityType entityType,
    List<String> entityIds,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/bulk-edit/summary',
      body: <String, dynamic>{
        'entity_type': entityType.toJson(),
        'entity_ids': entityIds,
      },
    );
    if (code == 200 && data is Map) {
      return BulkEditSummary.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<BulkEditResult?> applyBulkEdit(
    BulkEditEntityType entityType,
    List<String> entityIds,
    BulkEditPatch patch,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/bulk-edit/apply',
      body: <String, dynamic>{
        'entity_type': entityType.toJson(),
        'entity_ids': entityIds,
        'patch': patch.toJson(),
      },
      timeout: const Duration(seconds: 30),
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return BulkEditResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<AlbumAssetsResponse?> getAlbumAssets(
    String albumVersionOrAlbumId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/albums/${Uri.encodeComponent(albumVersionOrAlbumId)}/assets',
    );
    if (code == 200 && data is Map) {
      return AlbumAssetsResponse.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<Uint8List?> readAlbumAssetBytes(String assetId) async {
    final (code, bytes) = await _requestBytes(
      'GET',
      '/api/v1/library/assets/${Uri.encodeComponent(assetId)}/content',
      timeout: const Duration(seconds: 20),
    );
    if (code == 200 && bytes != null && bytes.isNotEmpty) {
      return bytes;
    }
    return null;
  }

  @override
  Future<bool> openAlbumPdfAsset(AlbumAssetRecord asset) async {
    final bytes = await readAlbumAssetBytes(asset.id);
    if (bytes == null || bytes.isEmpty) return false;
    return writeTempPdfAndOpen(
      assetId: asset.id,
      displayName: asset.displayName,
      bytes: bytes,
    );
  }
}
