part of '../ffi_audio_service.dart';

/// Implements Library Step 5 Static Playlists & Playlist Improver, Tri-State
/// Bulk Metadata Editor, and Album Assets over FFI. Backup/Restore & Export
/// live in [_FfiStep5BackupExportMixin].
mixin _FfiStep5Mixin on _FfiAudioServiceBase, _FfiStep5BindingsMixin {
  bool get _useRemoteStep5Client =>
      _remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac;

  Map<String, dynamic>? _decodeStep5Map(String? raw) {
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  @override
  Future<List<StaticPlaylistSummary>> listStaticPlaylists() async {
    if (_useRemoteStep5Client) return _remoteClient!.listStaticPlaylists();
    if (!isNativeBound || _libListStaticPlaylistsFn == null) {
      return _delegate.listStaticPlaylists();
    }
    final raw = await _callReadWorker<String>('list_static_playlists');
    if (_disposed || raw == null || raw.isEmpty) {
      return const <StaticPlaylistSummary>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
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
    if (_useRemoteStep5Client) return _remoteClient!.createStaticPlaylist(req);
    if (!isNativeBound || _libCreateStaticPlaylistFn == null) {
      return _delegate.createStaticPlaylist(req);
    }
    final raw = await _callWriteWorker<String>('create_static_playlist', {
      'payloadJson': jsonEncode(req.toJson()),
    });
    final map = _decodeStep5Map(raw);
    return map != null ? StaticPlaylistDetail.fromJson(map) : null;
  }

  @override
  Future<StaticPlaylistDetail?> getStaticPlaylistDetail(
    String playlistId,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.getStaticPlaylistDetail(playlistId);
    }
    if (!isNativeBound || _libGetStaticPlaylistDetailFn == null) {
      return _delegate.getStaticPlaylistDetail(playlistId);
    }
    final raw = await _callReadWorker<String>('get_static_playlist_detail', {
      'playlistId': playlistId,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? StaticPlaylistDetail.fromJson(map) : null;
  }

  @override
  Future<bool> deleteStaticPlaylist(String playlistId) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.deleteStaticPlaylist(playlistId);
    }
    if (!isNativeBound || _libDeleteStaticPlaylistFn == null) {
      return _delegate.deleteStaticPlaylist(playlistId);
    }
    final rc = await _callWriteWorker<int>('delete_static_playlist', {
      'playlistId': playlistId,
    });
    return !_disposed && rc == 0;
  }

  @override
  Future<StaticPlaylistDetail?> addTracksToStaticPlaylist(
    String playlistId,
    AddStaticPlaylistTracksRequest req,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.addTracksToStaticPlaylist(playlistId, req);
    }
    if (!isNativeBound || _libAddTracksToStaticPlaylistFn == null) {
      return _delegate.addTracksToStaticPlaylist(playlistId, req);
    }
    final raw = await _callWriteWorker<String>(
      'add_tracks_to_static_playlist',
      {
        'playlistId': playlistId,
        'payloadJson': jsonEncode(req.toJson()),
      },
    );
    final map = _decodeStep5Map(raw);
    return map != null ? StaticPlaylistDetail.fromJson(map) : null;
  }

  @override
  Future<PlaylistImprovementReport?> analyzePlaylistImprovements(
    String playlistId,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.analyzePlaylistImprovements(playlistId);
    }
    if (!isNativeBound || _libAnalyzePlaylistImprovementsFn == null) {
      return _delegate.analyzePlaylistImprovements(playlistId);
    }
    final raw = await _callReadWorker<String>('analyze_playlist_improvements', {
      'playlistId': playlistId,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? PlaylistImprovementReport.fromJson(map) : null;
  }

  @override
  Future<ApplyPlaylistImprovementsResult?> applyPlaylistImprovements(
    String playlistId,
    ApplyPlaylistImprovementsRequest req,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.applyPlaylistImprovements(playlistId, req);
    }
    if (!isNativeBound || _libApplyPlaylistImprovementsFn == null) {
      return _delegate.applyPlaylistImprovements(playlistId, req);
    }
    final raw = await _callWriteWorker<String>('apply_playlist_improvements', {
      'playlistId': playlistId,
      'payloadJson': jsonEncode(req.toJson()),
    });
    final map = _decodeStep5Map(raw);
    return map != null ? ApplyPlaylistImprovementsResult.fromJson(map) : null;
  }

  @override
  Future<List<PlaylistSnapshotRecord>> listPlaylistSnapshots(
    String playlistId,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.listPlaylistSnapshots(playlistId);
    }
    if (!isNativeBound || _libListPlaylistSnapshotsFn == null) {
      return _delegate.listPlaylistSnapshots(playlistId);
    }
    final raw = await _callReadWorker<String>('list_playlist_snapshots', {
      'playlistId': playlistId,
    });
    if (_disposed || raw == null || raw.isEmpty) {
      return const <PlaylistSnapshotRecord>[];
    }
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
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
    if (_useRemoteStep5Client) {
      return _remoteClient!.revertPlaylistSnapshot(snapshotId);
    }
    if (!isNativeBound || _libRevertPlaylistSnapshotFn == null) {
      return _delegate.revertPlaylistSnapshot(snapshotId);
    }
    final raw = await _callWriteWorker<String>('revert_playlist_snapshot', {
      'snapshotId': snapshotId,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? RevertPlaylistSnapshotResult.fromJson(map) : null;
  }

  @override
  Future<BulkEditSummary?> getBulkEditSummary(
    BulkEditEntityType entityType,
    List<String> entityIds,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.getBulkEditSummary(entityType, entityIds);
    }
    if (!isNativeBound || _libGetBulkEditSummaryFn == null) {
      return _delegate.getBulkEditSummary(entityType, entityIds);
    }
    final payload = jsonEncode(<String, dynamic>{
      'entity_type': entityType.toJson(),
      'entity_ids': entityIds,
    });
    final raw = await _callReadWorker<String>('get_bulk_edit_summary', {
      'payloadJson': payload,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? BulkEditSummary.fromJson(map) : null;
  }

  @override
  Future<BulkEditResult?> applyBulkEdit(
    BulkEditEntityType entityType,
    List<String> entityIds,
    BulkEditPatch patch,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.applyBulkEdit(entityType, entityIds, patch);
    }
    if (!isNativeBound || _libApplyBulkEditFn == null) {
      return _delegate.applyBulkEdit(entityType, entityIds, patch);
    }
    final payload = jsonEncode(<String, dynamic>{
      'entity_type': entityType.toJson(),
      'entity_ids': entityIds,
      'patch': patch.toJson(),
    });
    final raw = await _callWriteWorker<String>('apply_bulk_edit', {
      'payloadJson': payload,
    });
    final map = _decodeStep5Map(raw);
    if (map == null) return null;
    unawaited(_reloadTracksFromNativeAsync());
    return BulkEditResult.fromJson(map);
  }

  @override
  Future<AlbumAssetsResponse?> getAlbumAssets(
    String albumVersionOrAlbumId,
  ) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.getAlbumAssets(albumVersionOrAlbumId);
    }
    if (!isNativeBound || _libGetAlbumAssetsFn == null) {
      return _delegate.getAlbumAssets(albumVersionOrAlbumId);
    }
    final raw = await _callReadWorker<String>('get_album_assets', {
      'albumId': albumVersionOrAlbumId,
    });
    final map = _decodeStep5Map(raw);
    return map != null ? AlbumAssetsResponse.fromJson(map) : null;
  }

  @override
  Future<Uint8List?> readAlbumAssetBytes(String assetId) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.readAlbumAssetBytes(assetId);
    }
    if (!isNativeBound || _libReadAlbumAssetContentFn == null) {
      return _delegate.readAlbumAssetBytes(assetId);
    }
    final raw = await _callReadWorker<String>('read_album_asset_content', {
      'assetId': assetId,
    });
    final map = _decodeStep5Map(raw);
    if (map == null) return null;
    final b64 = (map['data_base64'] ?? map['content_base64'] ?? map['base64'])
        ?.toString()
        .trim();
    if (b64 != null && b64.isNotEmpty) {
      try {
        return Uint8List.fromList(base64Decode(b64));
      } catch (_) {}
    }
    final filePath = (map['file_path'] ?? map['path'])?.toString().trim();
    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      if (await file.exists()) {
        return file.readAsBytes();
      }
    }
    return null;
  }

  @override
  Future<bool> openAlbumPdfAsset(AlbumAssetRecord asset) async {
    if (_useRemoteStep5Client) {
      return _remoteClient!.openAlbumPdfAsset(asset);
    }
    if (!isNativeBound || _libReadAlbumAssetContentFn == null) {
      return _delegate.openAlbumPdfAsset(asset);
    }
    final raw = await _callReadWorker<String>('read_album_asset_content', {
      'assetId': asset.id,
    });
    final map = _decodeStep5Map(raw);
    if (map == null) return false;
    final verifiedPath = (map['file_path'] ?? map['path'])?.toString().trim();
    if (verifiedPath != null && verifiedPath.isNotEmpty) {
      final opened = await openFileWithOsViewer(verifiedPath);
      if (opened) return true;
    }
    final b64 = (map['data_base64'] ?? map['content_base64'] ?? map['base64'])
        ?.toString()
        .trim();
    if (b64 != null && b64.isNotEmpty) {
      try {
        final bytes = Uint8List.fromList(base64Decode(b64));
        return await writeTempPdfAndOpen(
          assetId: asset.id,
          displayName: asset.displayName,
          bytes: bytes,
        );
      } catch (_) {}
    }
    return false;
  }
}
