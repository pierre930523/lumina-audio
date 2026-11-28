part of '../streaming_playback_coordinator.dart';

/// Forwards all Library Step 3 Focus, Nested Tags, and Physical Folder methods
/// from [CoordinatingAudioService] to its [inner] [AudioService].
mixin _CoordinatingAudioServiceFocusDelegatesMixin implements AudioService {
  AudioService get inner;

  @override
  Future<FocusQueryResponse> focusQuery(FocusQueryRequest request) =>
      inner.focusQuery(request);

  @override
  Future<FocusFacetsResponse> focusFacets(FocusQuery query) =>
      inner.focusFacets(query);

  @override
  Future<List<TagSummary>> listTags() => inner.listTags();

  @override
  Future<TagSummary?> createTag(CreateTagRequest request) =>
      inner.createTag(request);

  @override
  Future<TagSummary?> updateTag(UpdateTagRequest request) =>
      inner.updateTag(request);

  @override
  Future<bool> deleteTag(String tagId) => inner.deleteTag(tagId);

  @override
  Future<bool> linkTagParent(TagLinkRequest request) =>
      inner.linkTagParent(request);

  @override
  Future<bool> unlinkTagParent(TagLinkRequest request) =>
      inner.unlinkTagParent(request);

  @override
  Future<BatchTagItemsResponse> batchTagItems(BatchTagItemsRequest request) =>
      inner.batchTagItems(request);

  @override
  Future<List<TagSummary>> getEntityTags(
    TagEntityType entityType,
    String entityId,
  ) => inner.getEntityTags(entityType, entityId);

  @override
  Future<List<FolderNode>> getFolderRoots() => inner.getFolderRoots();

  @override
  Future<FolderContentsResponse?> getFolderContents(String folderId) =>
      inner.getFolderContents(folderId);

  @override
  Future<List<String>> getFolderRecursiveTrackIds(String folderId) =>
      inner.getFolderRecursiveTrackIds(folderId);
}
