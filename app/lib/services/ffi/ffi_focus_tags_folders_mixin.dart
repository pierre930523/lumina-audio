part of '../ffi_audio_service.dart';

mixin _FfiFocusTagsFoldersMixin on _FfiAudioServiceBase {
  _LuminaStrPtrDart? _libFocusQueryFn;
  _LuminaStrPtrDart? _libFocusFacetsFn;
  _LuminaVoidPtrDart? _libListTagsFn;
  _LuminaStrPtrDart? _libCreateTagFn;
  _LuminaStrPtrDart? _libUpdateTagFn;
  _LuminaStrIntDart? _libDeleteTagFn;
  _LuminaStrIntDart? _libLinkTagParentFn;
  _LuminaStrIntDart? _libUnlinkTagParentFn;
  _LuminaStrPtrDart? _libBatchTagItemsFn;
  _LuminaStr2PtrDart? _libGetEntityTagsFn;
  _LuminaVoidPtrDart? _libGetFolderRootsFn;
  _LuminaStrPtrDart? _libGetFolderContentsFn;
  _LuminaStrPtrDart? _libGetFolderRecursiveTrackIdsFn;

  @override
  void _bindFocusTagsFoldersSymbols(ffi.DynamicLibrary dylib) {
    F? tryLookup<F>(F Function() lookup) {
      try {
        return lookup();
      } catch (_) {
        return null;
      }
    }

    _libFocusQueryFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_focus_query',
      ),
    );
    _libFocusFacetsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_focus_facets',
      ),
    );
    _libListTagsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_list_tags',
      ),
    );
    _libCreateTagFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_create_tag',
      ),
    );
    _libUpdateTagFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_update_tag',
      ),
    );
    _libDeleteTagFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_delete_tag',
      ),
    );
    _libLinkTagParentFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_link_tag_parent',
      ),
    );
    _libUnlinkTagParentFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrIntNative, _LuminaStrIntDart>(
        'lumina_library_unlink_tag_parent',
      ),
    );
    _libBatchTagItemsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_batch_tag_items',
      ),
    );
    _libGetEntityTagsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStr2PtrNative, _LuminaStr2PtrDart>(
        'lumina_library_get_entity_tags',
      ),
    );
    _libGetFolderRootsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaVoidPtrNative, _LuminaVoidPtrDart>(
        'lumina_library_get_folder_roots',
      ),
    );
    _libGetFolderContentsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_folder_contents',
      ),
    );
    _libGetFolderRecursiveTrackIdsFn = tryLookup(
      () => dylib.lookupFunction<_LuminaStrPtrNative, _LuminaStrPtrDart>(
        'lumina_library_get_folder_recursive_track_ids',
      ),
    );
  }

  bool get _useRemoteFocusClient =>
      _remoteClient != null && _connectionMode != ConnectionMode.localOrUsbDac;

  @override
  Future<FocusQueryResponse> focusQuery(FocusQueryRequest request) async {
    if (_useRemoteFocusClient) return _remoteClient!.focusQuery(request);
    if (!isNativeBound || _libFocusQueryFn == null) {
      return _delegate.focusQuery(request);
    }
    final raw = await _callReadWorker<String>('focus_query', {
      'requestJson': jsonEncode(request.toJson()),
    });
    if (_disposed || raw == null || raw.isEmpty) {
      return FocusQueryResponse(
        entity: request.query.entity,
        limit: request.limit,
        offset: request.offset,
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return FocusQueryResponse.fromJson(Map<String, dynamic>.from(decoded));
    }
    return FocusQueryResponse(
      entity: request.query.entity,
      limit: request.limit,
      offset: request.offset,
    );
  }

  @override
  Future<FocusFacetsResponse> focusFacets(FocusQuery query) async {
    if (_useRemoteFocusClient) return _remoteClient!.focusFacets(query);
    if (!isNativeBound || _libFocusFacetsFn == null) {
      return _delegate.focusFacets(query);
    }
    final raw = await _callReadWorker<String>('focus_facets', {
      'queryJson': jsonEncode(query.toJson()),
    });
    if (_disposed || raw == null || raw.isEmpty) {
      return const FocusFacetsResponse();
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return FocusFacetsResponse.fromJson(Map<String, dynamic>.from(decoded));
    }
    return const FocusFacetsResponse();
  }

  @override
  Future<List<TagSummary>> listTags() async {
    if (_useRemoteFocusClient) return _remoteClient!.listTags();
    if (!isNativeBound || _libListTagsFn == null) {
      return _delegate.listTags();
    }
    final raw = await _callReadWorker<String>('list_tags');
    if (_disposed || raw == null || raw.isEmpty) return const <TagSummary>[];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => TagSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <TagSummary>[];
  }

  @override
  Future<TagSummary?> createTag(CreateTagRequest request) async {
    if (_useRemoteFocusClient) return _remoteClient!.createTag(request);
    if (!isNativeBound || _libCreateTagFn == null) {
      return _delegate.createTag(request);
    }
    final raw = await _callWriteWorker<String>('create_tag', {
      'payloadJson': jsonEncode(request.toJson()),
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return TagSummary.fromJson(Map<String, dynamic>.from(decoded));
    }
    return null;
  }

  @override
  Future<TagSummary?> updateTag(UpdateTagRequest request) async {
    if (_useRemoteFocusClient) return _remoteClient!.updateTag(request);
    if (!isNativeBound || _libUpdateTagFn == null) {
      return _delegate.updateTag(request);
    }
    final raw = await _callWriteWorker<String>('update_tag', {
      'payloadJson': jsonEncode(request.toJson()),
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return TagSummary.fromJson(Map<String, dynamic>.from(decoded));
    }
    return null;
  }

  @override
  Future<bool> deleteTag(String tagId) async {
    if (_useRemoteFocusClient) return _remoteClient!.deleteTag(tagId);
    if (!isNativeBound || _libDeleteTagFn == null) {
      return _delegate.deleteTag(tagId);
    }
    final rc = await _callWriteWorker<int>('delete_tag', {'tagId': tagId});
    return rc == 0;
  }

  @override
  Future<bool> linkTagParent(TagLinkRequest request) async {
    if (_useRemoteFocusClient) return _remoteClient!.linkTagParent(request);
    if (!isNativeBound || _libLinkTagParentFn == null) {
      return _delegate.linkTagParent(request);
    }
    final rc = await _callWriteWorker<int>('link_tag_parent', {
      'payloadJson': jsonEncode(request.toJson()),
    });
    return rc == 0;
  }

  @override
  Future<bool> unlinkTagParent(TagLinkRequest request) async {
    if (_useRemoteFocusClient) return _remoteClient!.unlinkTagParent(request);
    if (!isNativeBound || _libUnlinkTagParentFn == null) {
      return _delegate.unlinkTagParent(request);
    }
    final rc = await _callWriteWorker<int>('unlink_tag_parent', {
      'payloadJson': jsonEncode(request.toJson()),
    });
    return rc == 0;
  }

  @override
  Future<BatchTagItemsResponse> batchTagItems(
    BatchTagItemsRequest request,
  ) async {
    if (_useRemoteFocusClient) return _remoteClient!.batchTagItems(request);
    if (!isNativeBound || _libBatchTagItemsFn == null) {
      return _delegate.batchTagItems(request);
    }
    final raw = await _callWriteWorker<String>('batch_tag_items', {
      'payloadJson': jsonEncode(request.toJson()),
    });
    if (_disposed || raw == null || raw.isEmpty) {
      return const BatchTagItemsResponse();
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return BatchTagItemsResponse.fromJson(Map<String, dynamic>.from(decoded));
    }
    return const BatchTagItemsResponse();
  }

  @override
  Future<List<TagSummary>> getEntityTags(
    TagEntityType entityType,
    String entityId,
  ) async {
    if (_useRemoteFocusClient) {
      return _remoteClient!.getEntityTags(entityType, entityId);
    }
    if (!isNativeBound || _libGetEntityTagsFn == null) {
      return _delegate.getEntityTags(entityType, entityId);
    }
    final raw = await _callReadWorker<String>('get_entity_tags', {
      'entityType': entityType.toJson(),
      'entityId': entityId,
    });
    if (_disposed || raw == null || raw.isEmpty) return const <TagSummary>[];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => TagSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <TagSummary>[];
  }

  @override
  Future<List<FolderNode>> getFolderRoots() async {
    if (_useRemoteFocusClient) return _remoteClient!.getFolderRoots();
    if (!isNativeBound || _libGetFolderRootsFn == null) {
      return _delegate.getFolderRoots();
    }
    final raw = await _callReadWorker<String>('get_folder_roots');
    if (_disposed || raw == null || raw.isEmpty) return const <FolderNode>[];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => FolderNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <FolderNode>[];
  }

  @override
  Future<FolderContentsResponse?> getFolderContents(String folderId) async {
    if (_useRemoteFocusClient) {
      return _remoteClient!.getFolderContents(folderId);
    }
    if (!isNativeBound || _libGetFolderContentsFn == null) {
      return _delegate.getFolderContents(folderId);
    }
    final raw = await _callReadWorker<String>('get_folder_contents', {
      'folderId': folderId,
    });
    if (_disposed || raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return FolderContentsResponse.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    }
    return null;
  }

  @override
  Future<List<String>> getFolderRecursiveTrackIds(String folderId) async {
    if (_useRemoteFocusClient) {
      return _remoteClient!.getFolderRecursiveTrackIds(folderId);
    }
    if (!isNativeBound || _libGetFolderRecursiveTrackIdsFn == null) {
      return _delegate.getFolderRecursiveTrackIds(folderId);
    }
    final raw = await _callReadWorker<String>(
      'get_folder_recursive_track_ids',
      {'folderId': folderId},
    );
    if (_disposed || raw == null || raw.isEmpty) return const <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList(growable: false);
    }
    if (decoded is Map && decoded['track_ids'] is List) {
      return (decoded['track_ids'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(growable: false);
    }
    return const <String>[];
  }
}
