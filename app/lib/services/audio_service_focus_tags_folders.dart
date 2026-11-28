part of 'audio_service.dart';

/// Library Step 3 contract mixin: Focus multi-dimensional filter engine,
/// Custom Nested Tags (DAG), and Physical Folder Browsing.
///
/// Default implementations return safe empty/no-op values; all production and
/// mock [AudioService] implementations (`FfiAudioService`, `ServerAudioService`,
/// `MockAudioService`, `CoordinatingAudioService`) override all 13 methods.
mixin AudioServiceFocusTagsFoldersMixin {
  Future<FocusQueryResponse> focusQuery(FocusQueryRequest request) async =>
      FocusQueryResponse(
        entity: request.query.entity,
        limit: request.limit,
        offset: request.offset,
      );

  Future<FocusFacetsResponse> focusFacets(FocusQuery query) async =>
      const FocusFacetsResponse();

  Future<List<TagSummary>> listTags() async => const <TagSummary>[];

  Future<TagSummary?> createTag(CreateTagRequest request) async => null;

  Future<TagSummary?> updateTag(UpdateTagRequest request) async => null;

  Future<bool> deleteTag(String tagId) async => false;

  Future<bool> linkTagParent(TagLinkRequest request) async => false;

  Future<bool> unlinkTagParent(TagLinkRequest request) async => false;

  Future<BatchTagItemsResponse> batchTagItems(
    BatchTagItemsRequest request,
  ) async => const BatchTagItemsResponse();

  Future<List<TagSummary>> getEntityTags(
    TagEntityType entityType,
    String entityId,
  ) async => const <TagSummary>[];

  Future<List<FolderNode>> getFolderRoots() async => const <FolderNode>[];

  Future<FolderContentsResponse?> getFolderContents(String folderId) async =>
      null;

  Future<List<String>> getFolderRecursiveTrackIds(String folderId) async =>
      const <String>[];
}
