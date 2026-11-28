part of 'audio_service.dart';

/// Shared helper filtering banned tracks (`preference == -1`) from automatic
/// collection queues while preserving any explicitly selected track.
({List<TrackInfo> tracks, int startIndex}) filterQueueTracksForPlayback(
  List<TrackInfo> tracks, {
  int startIndex = 0,
  bool excludeBanned = true,
  TrackInfo? explicitTrack,
}) {
  bool matchesExplicit(TrackInfo candidate) {
    if (explicitTrack == null) return false;
    if (identical(candidate, explicitTrack)) return true;
    if (candidate.id.isNotEmpty && candidate.id == explicitTrack.id) {
      return true;
    }
    return false;
  }

  if (tracks.isEmpty) {
    if (explicitTrack != null) {
      return (tracks: <TrackInfo>[explicitTrack], startIndex: 0);
    }
    return (tracks: const <TrackInfo>[], startIndex: -1);
  }

  final clampedStart = startIndex.clamp(0, tracks.length - 1);

  if (!excludeBanned) {
    final copy = List<TrackInfo>.from(tracks);
    if (explicitTrack != null) {
      final idx = copy.indexWhere(matchesExplicit);
      if (idx >= 0) {
        return (tracks: copy, startIndex: idx);
      }
      final insertIdx = startIndex.clamp(0, copy.length);
      copy.insert(insertIdx, explicitTrack);
      return (tracks: copy, startIndex: insertIdx);
    }
    return (tracks: copy, startIndex: clampedStart);
  }

  final kept = <TrackInfo>[];
  var resolvedStart = -1;
  var explicitMatched = false;

  for (var i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final isExplicit = matchesExplicit(track);
    if (track.preference == -1 && !isExplicit) {
      continue;
    }
    final newIdx = kept.length;
    kept.add(track);
    if (isExplicit) {
      resolvedStart = newIdx;
      explicitMatched = true;
    } else if (explicitTrack == null && resolvedStart < 0 && i >= clampedStart) {
      resolvedStart = newIdx;
    }
  }

  if (explicitTrack != null && !explicitMatched) {
    final insertIdx = startIndex.clamp(0, kept.length);
    kept.insert(insertIdx, explicitTrack);
    resolvedStart = insertIdx;
  }

  if (kept.isEmpty) {
    return (tracks: const <TrackInfo>[], startIndex: -1);
  }

  return (tracks: kept, startIndex: resolvedStart >= 0 ? resolvedStart : 0);
}

/// Library Step 4 contract mixin: Tri-State Preferences (-1 / 0 / 1),
/// Dynamic Bookmarks, Unified FocusQuery-backed Smart Playlists,
/// Listen Later (library + external streaming snapshots), and Unified Queue API.
mixin AudioServiceStep4Mixin {
  Future<SetEntityPreferenceResponse?> setEntityPreference(
    String entityType,
    String entityId,
    int preference,
  ) async => null;

  Future<List<BookmarkItem>> listBookmarks() async => const <BookmarkItem>[];

  Future<BookmarkItem?> createBookmark({
    required String name,
    required String targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async => null;

  Future<BookmarkItem?> updateBookmark(
    String id, {
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async => null;

  Future<bool> deleteBookmark(String id) async => false;

  Future<bool> reorderBookmarks(List<String> orderedIds) async => false;

  Future<List<SmartPlaylistItem>> listSmartPlaylists() async =>
      const <SmartPlaylistItem>[];

  Future<SmartPlaylistItem?> createSmartPlaylist({
    required String name,
    String description = '',
    required String focusQueryJson,
    bool excludeBanned = true,
    int? limitCount,
    bool isPinned = true,
  }) async => null;

  Future<SmartPlaylistItem?> updateSmartPlaylist(
    String id, {
    String? name,
    String? description,
    String? focusQueryJson,
    bool? excludeBanned,
    int? limitCount,
    bool clearLimitCount = false,
    bool? isPinned,
    int? sortOrder,
  }) async => null;

  Future<bool> deleteSmartPlaylist(String id) async => false;

  Future<SmartPlaylistItem?> duplicateSmartPlaylist(String id) async => null;

  Future<SmartPlaylistEvaluation?> evaluateSmartPlaylist(String id) async =>
      null;

  Future<ListenLaterItem?> addToListenLater({
    required String sourceKind,
    required String entityType,
    String? entityId,
    String? providerId,
    String? externalId,
    required String title,
    String artistName = '',
    String albumTitle = '',
    String? coverUrl,
    int? trackCount,
    String? metadataJson,
    String note = '',
  }) async => null;

  Future<List<ListenLaterItem>> listListenLater({String? status}) async =>
      const <ListenLaterItem>[];

  Future<ListenLaterItem?> markListenLaterStatus(
    String id,
    String status,
  ) async => null;

  Future<ListenLaterItem?> updateListenLaterNote(
    String id,
    String note,
  ) async => null;

  Future<bool> removeListenLater(String id) async => false;

  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) async => null;

  /// Replaces the active playback queue with [tracks] (filtering out
  /// `preference == -1` tracks when [excludeBanned] is `true`, while always
  /// preserving [explicitTrack] if supplied) and begins playback at the
  /// resolved start index.
  Future<void> playQueue(
    List<TrackInfo> tracks, {
    int startIndex = 0,
    bool excludeBanned = true,
    TrackInfo? explicitTrack,
  }) async {}

  /// Adds [tracks] to the active playback queue (filtering out
  /// `preference == -1` tracks when [excludeBanned] is `true`). When
  /// [playNext] is `true`, inserts immediately after the currently playing
  /// track; otherwise appends to the end. Returns the number of tracks added.
  Future<int> enqueueTracks(
    List<TrackInfo> tracks, {
    bool excludeBanned = true,
    bool playNext = false,
  }) async => 0;

  /// Clears all upcoming tracks strictly after the currently playing track
  /// (remaining user queue and trailing auto-queue) without stopping or
  /// reloading the current track or modifying played history. Returns the
  /// number of cleared tracks.
  Future<int> clearUpcomingQueue() async => 0;
}
