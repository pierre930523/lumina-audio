part of '../server_audio_service.dart';

mixin _ServerFocusTagsFoldersMixin on _ServerAudioServiceBase {
  @override
  Future<FocusQueryResponse> focusQuery(FocusQueryRequest request) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/focus/query',
      body: request.toJson(),
    );
    if (code == 200 && data is Map) {
      return FocusQueryResponse.fromJson(Map<String, dynamic>.from(data));
    }
    return FocusQueryResponse(
      entity: request.query.entity,
      limit: request.limit,
      offset: request.offset,
    );
  }

  @override
  Future<FocusFacetsResponse> focusFacets(FocusQuery query) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/focus/facets',
      body: query.toJson(),
    );
    if (code == 200 && data is Map) {
      return FocusFacetsResponse.fromJson(Map<String, dynamic>.from(data));
    }
    return const FocusFacetsResponse();
  }

  @override
  Future<List<TagSummary>> listTags() async {
    final (code, data) = await _requestJson('GET', '/api/v1/library/tags');
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => TagSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <TagSummary>[];
  }

  @override
  Future<TagSummary?> createTag(CreateTagRequest request) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/tags',
      body: request.toJson(),
    );
    if ((code == 200 || code == 201) && data is Map) {
      return TagSummary.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<TagSummary?> updateTag(UpdateTagRequest request) async {
    final (code, data) = await _requestJson(
      'PATCH',
      '/api/v1/library/tags/${Uri.encodeComponent(request.id)}',
      body: request.toJson(),
    );
    if (code == 200 && data is Map) {
      return TagSummary.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> deleteTag(String tagId) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/library/tags/${Uri.encodeComponent(tagId)}',
    );
    return code == 200 || code == 204;
  }

  @override
  Future<bool> linkTagParent(TagLinkRequest request) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/library/tags/links',
      body: request.toJson(),
    );
    return code == 200 || code == 201 || code == 204;
  }

  @override
  Future<bool> unlinkTagParent(TagLinkRequest request) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/library/tags/links/remove',
      body: request.toJson(),
    );
    return code == 200 || code == 204;
  }

  @override
  Future<BatchTagItemsResponse> batchTagItems(
    BatchTagItemsRequest request,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/tags/items/batch',
      body: request.toJson(),
    );
    if (code == 200 && data is Map) {
      return BatchTagItemsResponse.fromJson(Map<String, dynamic>.from(data));
    }
    return const BatchTagItemsResponse();
  }

  @override
  Future<List<TagSummary>> getEntityTags(
    TagEntityType entityType,
    String entityId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/tags/items/'
      '${Uri.encodeComponent(entityType.toJson())}/'
      '${Uri.encodeComponent(entityId)}',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => TagSummary.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <TagSummary>[];
  }

  @override
  Future<List<FolderNode>> getFolderRoots() async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/folders/roots',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => FolderNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const <FolderNode>[];
  }

  @override
  Future<FolderContentsResponse?> getFolderContents(String folderId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/folders/${Uri.encodeComponent(folderId)}/contents',
    );
    if (code == 200 && data is Map) {
      return FolderContentsResponse.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<List<String>> getFolderRecursiveTrackIds(String folderId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/folders/${Uri.encodeComponent(folderId)}/track-ids',
    );
    if (code != 200) return const <String>[];
    if (data is List) {
      return data.map((e) => e.toString()).toList(growable: false);
    }
    if (data is Map && data['track_ids'] is List) {
      return (data['track_ids'] as List<dynamic>)
          .map((e) => e.toString())
          .toList(growable: false);
    }
    return const <String>[];
  }
}
