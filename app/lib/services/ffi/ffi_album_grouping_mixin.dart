part of '../ffi_audio_service.dart';

mixin _FfiAlbumGroupingMixin on _FfiAudioServiceBase {
  _LuminaStrPtrDart? _libGetAlbumsWithOptionsFn;
  _LuminaStr2PtrDart? _libSetPrimaryVersionFn;
  _LuminaStrPtrDart? _libResetPrimaryVersionFn;
  _LuminaStrPtrDart? _libMergeAlbumVersionsFn;
  _LuminaStrPtrDart? _libSplitAlbumVersionFn;
  _LuminaStrPtrDart? _libGroupAlternateVersionsFn;
  _LuminaStrPtrDart? _libUngroupVersionFn;
  _LuminaStrI32PtrDart? _libSetVersionHiddenFn;
  _LuminaStrPtrDart? _libResetAlbumGroupingFn;

  @override
  void _bindAlbumGroupingSymbols(ffi.DynamicLibrary dylib) {
    F? tryLookup<F>(F Function() lookup) {
      try {
        return lookup();
      } catch (_) {
        return null;
      }
    }

    _libGetAlbumsWithOptionsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_albums_with_options',
      ),
    );
    _libSetPrimaryVersionFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_set_primary_version',
      ),
    );
    _libResetPrimaryVersionFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_reset_primary_version',
      ),
    );
    _libMergeAlbumVersionsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_merge_album_versions',
      ),
    );
    _libSplitAlbumVersionFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_split_album_version',
      ),
    );
    _libGroupAlternateVersionsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_group_alternate_versions',
      ),
    );
    _libUngroupVersionFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_ungroup_version',
      ),
    );
    _libSetVersionHiddenFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrI32PtrNative, _LuminaStrI32PtrDart>(
        'lumina_library_set_version_hidden',
      ),
    );
    _libResetAlbumGroupingFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_reset_album_grouping',
      ),
    );
  }

  Future<AlbumVersionOpResult> _parseAlbumOpResult(String? raw) async {
    if (_disposed || raw == null || raw.isEmpty) {
      return const AlbumVersionOpResult();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final res = AlbumVersionOpResult.fromJson(
          Map<String, dynamic>.from(decoded),
        );
        await _reloadTracksFromNativeAsync();
        if (!_disposed) {
          _emitState(_state);
        }
        return res;
      }
    } catch (_) {}
    return const AlbumVersionOpResult();
  }

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.getAlbums(
        limit: limit,
        includeHidden: includeHidden,
      );
    }
    if (!isNativeBound ||
        (_libGetAlbumsWithOptionsFn == null && _getAlbumsFn == null)) {
      return _delegate.getAlbums(limit: limit, includeHidden: includeHidden);
    }
    String? raw;
    if (_libGetAlbumsWithOptionsFn != null) {
      final optionsJson = jsonEncode(<String, dynamic>{
        'limit': limit,
        'offset': 0,
        'include_hidden': includeHidden,
      });
      raw = await _callReadWorker<String>('get_albums_with_options', {
        'optionsJson': optionsJson,
      });
    } else if (_getAlbumsFn != null) {
      raw = await _callReadWorker<String>('get_albums', {'limit': limit});
    }
    if (_disposed || raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(CanonicalAlbumSummary.fromJson)
          .where(
            (a) =>
                a.id.isNotEmpty && (a.trackCount == null || a.trackCount! > 0),
          )
          .toList();
    }
    return const [];
  }

  @override
  Future<AlbumVersionOpResult> setPrimaryVersion(
    String groupId,
    String versionId,
  ) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.setPrimaryVersion(groupId, versionId);
    }
    if (!isNativeBound || _libSetPrimaryVersionFn == null) {
      return _delegate.setPrimaryVersion(groupId, versionId);
    }
    final raw = await _callWriteWorker<String>('set_primary_version', {
      'groupId': groupId,
      'versionId': versionId,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> resetPrimaryVersion(String groupId) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.resetPrimaryVersion(groupId);
    }
    if (!isNativeBound || _libResetPrimaryVersionFn == null) {
      return _delegate.resetPrimaryVersion(groupId);
    }
    final raw = await _callWriteWorker<String>('reset_primary_version', {
      'groupId': groupId,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> mergeAlbumVersions({
    required String targetVersionId,
    required List<String> sourceVersionIds,
    String? newEditionLabel,
    List<DiscMappingEntry> discMapping = const <DiscMappingEntry>[],
  }) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.mergeAlbumVersions(
        targetVersionId: targetVersionId,
        sourceVersionIds: sourceVersionIds,
        newEditionLabel: newEditionLabel,
        discMapping: discMapping,
      );
    }
    if (!isNativeBound || _libMergeAlbumVersionsFn == null) {
      return _delegate.mergeAlbumVersions(
        targetVersionId: targetVersionId,
        sourceVersionIds: sourceVersionIds,
        newEditionLabel: newEditionLabel,
        discMapping: discMapping,
      );
    }
    final payloadJson = jsonEncode(<String, dynamic>{
      'target_version_id': targetVersionId,
      'source_version_ids': sourceVersionIds,
      if (newEditionLabel != null && newEditionLabel.trim().isNotEmpty)
        'new_edition_label': newEditionLabel.trim(),
      'disc_mapping': discMapping.map((e) => e.toJson()).toList(),
    });
    final raw = await _callWriteWorker<String>('merge_album_versions', {
      'payloadJson': payloadJson,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> splitAlbumVersion({
    required String versionId,
    required List<SplitTrackGroup> trackGroups,
    SplitTargetMode targetMode = SplitTargetMode.sameGroup,
  }) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.splitAlbumVersion(
        versionId: versionId,
        trackGroups: trackGroups,
        targetMode: targetMode,
      );
    }
    if (!isNativeBound || _libSplitAlbumVersionFn == null) {
      return _delegate.splitAlbumVersion(
        versionId: versionId,
        trackGroups: trackGroups,
        targetMode: targetMode,
      );
    }
    final payloadJson = jsonEncode(<String, dynamic>{
      'version_id': versionId,
      'track_groups': trackGroups.map((g) => g.toJson()).toList(),
      'target_mode': targetMode.toJson(),
    });
    final raw = await _callWriteWorker<String>('split_album_version', {
      'payloadJson': payloadJson,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> groupAsAlternateVersions({
    required List<String> versionIds,
    String? targetGroupId,
    String? primaryVersionId,
  }) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.groupAsAlternateVersions(
        versionIds: versionIds,
        targetGroupId: targetGroupId,
        primaryVersionId: primaryVersionId,
      );
    }
    if (!isNativeBound || _libGroupAlternateVersionsFn == null) {
      return _delegate.groupAsAlternateVersions(
        versionIds: versionIds,
        targetGroupId: targetGroupId,
        primaryVersionId: primaryVersionId,
      );
    }
    final payloadJson = jsonEncode(<String, dynamic>{
      'version_ids': versionIds,
      if (targetGroupId != null && targetGroupId.trim().isNotEmpty)
        'target_group_id': targetGroupId.trim(),
      if (primaryVersionId != null && primaryVersionId.trim().isNotEmpty)
        'primary_version_id': primaryVersionId.trim(),
    });
    final raw = await _callWriteWorker<String>('group_alternate_versions', {
      'payloadJson': payloadJson,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> ungroupVersion(String versionId) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.ungroupVersion(versionId);
    }
    if (!isNativeBound || _libUngroupVersionFn == null) {
      return _delegate.ungroupVersion(versionId);
    }
    final raw = await _callWriteWorker<String>('ungroup_version', {
      'versionId': versionId,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> setVersionHidden(
    String versionId, {
    required bool isHidden,
  }) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.setVersionHidden(versionId, isHidden: isHidden);
    }
    if (!isNativeBound || _libSetVersionHiddenFn == null) {
      return _delegate.setVersionHidden(versionId, isHidden: isHidden);
    }
    final raw = await _callWriteWorker<String>('set_version_hidden', {
      'versionId': versionId,
      'isHidden': isHidden,
    });
    return _parseAlbumOpResult(raw);
  }

  @override
  Future<AlbumVersionOpResult> resetAlbumGrouping(String versionId) async {
    if (_remoteClient != null &&
        _connectionMode != ConnectionMode.localOrUsbDac) {
      return _remoteClient!.resetAlbumGrouping(versionId);
    }
    if (!isNativeBound || _libResetAlbumGroupingFn == null) {
      return _delegate.resetAlbumGrouping(versionId);
    }
    final raw = await _callWriteWorker<String>('reset_album_grouping', {
      'versionId': versionId,
    });
    return _parseAlbumOpResult(raw);
  }
}
