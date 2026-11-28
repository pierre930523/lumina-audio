import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'podcast_models.dart';
import 'studio/focus_models.dart';

/// Top-level workspace destinations inside [HomeScreen].
enum HomeTab {
  home,
  library,
  albums,
  albumDetail,
  credits,
  smartPlaylists,
  listenLater,
  tags,
  folders,
  artists,
  artistDetail,
  audiobooks,
  podcasts,
  podcastDetail,
  radio,
  search,
  streamingProvider,
  general,
  appearance,
  librarySettings,
  dsp,
  zones,
  settings,
  about;

  bool get isSettings =>
      this == HomeTab.general ||
      this == HomeTab.appearance ||
      this == HomeTab.librarySettings ||
      this == HomeTab.dsp ||
      this == HomeTab.zones ||
      this == HomeTab.settings ||
      this == HomeTab.about;
}

/// Immutable navigation history entry carrying route parameters.
@immutable
class NavEntry {
  final HomeTab tab;
  final String? albumId;
  final String? artistKey;
  final String? artistName;
  final String? smartPlaylistId;
  final String? streamingKind;
  final String? creditArtistId;
  final String? podcastShowId;
  final PodcastShow? podcastShow;
  final String? tagId;
  final String? folderId;
  final String? focusQueryJson;
  final String? viewStateJson;
  final String? activeBookmarkId;
  final String? editingSmartPlaylistId;
  final String? entryId;

  const NavEntry({
    required this.tab,
    this.albumId,
    this.artistKey,
    this.artistName,
    this.smartPlaylistId,
    this.streamingKind,
    this.creditArtistId,
    this.podcastShowId,
    this.podcastShow,
    this.tagId,
    this.folderId,
    this.focusQueryJson,
    this.viewStateJson,
    this.activeBookmarkId,
    this.editingSmartPlaylistId,
    this.entryId,
  });

  factory NavEntry.tab(HomeTab tab, {String? entryId}) =>
      NavEntry(tab: tab, entryId: entryId);

  factory NavEntry.album(String albumId, {String? entryId}) => NavEntry(
    tab: HomeTab.albumDetail,
    albumId: albumId,
    entryId: entryId,
  );

  factory NavEntry.podcastDetail(
    String showId, {
    PodcastShow? show,
    String? entryId,
  }) => NavEntry(
    tab: HomeTab.podcastDetail,
    podcastShowId: showId,
    podcastShow: show,
    entryId: entryId,
  );

  factory NavEntry.artist({
    required String artistName,
    String? artistKey,
    String? entryId,
  }) {
    final trimmed = artistName.trim();
    final key = (artistKey != null && artistKey.trim().isNotEmpty)
        ? artistKey.trim().toLowerCase()
        : trimmed.toLowerCase();
    return NavEntry(
      tab: HomeTab.artistDetail,
      artistKey: key,
      artistName: trimmed,
      entryId: entryId,
    );
  }

  factory NavEntry.credits({String? artistId, String? entryId}) => NavEntry(
    tab: HomeTab.credits,
    creditArtistId: artistId,
    entryId: entryId,
  );

  factory NavEntry.smartPlaylist(String playlistId, {String? entryId}) =>
      NavEntry(
        tab: HomeTab.smartPlaylists,
        smartPlaylistId: playlistId,
        entryId: entryId,
      );

  factory NavEntry.listenLater({String? entryId}) =>
      NavEntry(tab: HomeTab.listenLater, entryId: entryId);

  factory NavEntry.streaming(String kind, {String? entryId}) => NavEntry(
    tab: HomeTab.streamingProvider,
    streamingKind: kind,
    entryId: entryId,
  );

  factory NavEntry.tags({String? tagId, String? entryId}) => NavEntry(
    tab: HomeTab.tags,
    tagId: tagId,
    entryId: entryId,
  );

  factory NavEntry.folders({String? folderId, String? entryId}) => NavEntry(
    tab: HomeTab.folders,
    folderId: folderId,
    entryId: entryId,
  );

  factory NavEntry.focus(
    FocusQuery query, {
    String? viewStateJson,
    String? activeBookmarkId,
    String? editingSmartPlaylistId,
    String? entryId,
  }) => NavEntry(
    tab: query.entity == FocusEntity.tracks ? HomeTab.library : HomeTab.albums,
    focusQueryJson: jsonEncode(query.toJson()),
    viewStateJson: viewStateJson,
    activeBookmarkId: activeBookmarkId,
    editingSmartPlaylistId: editingSmartPlaylistId,
    entryId: entryId,
  );

  FocusQuery? get parsedFocusQuery {
    final raw = focusQueryJson?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return FocusQuery.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic>? get parsedViewState {
    final raw = viewStateJson?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  String get normalizedArtistKey =>
      (artistKey != null && artistKey!.trim().isNotEmpty)
          ? artistKey!.trim().toLowerCase()
          : (artistName ?? '').trim().toLowerCase();

  String get routeKey => [
    tab.name,
    albumId ?? '',
    normalizedArtistKey,
    smartPlaylistId ?? '',
    streamingKind ?? '',
    creditArtistId ?? '',
    podcastShowId ?? '',
    tagId ?? '',
    folderId ?? '',
    focusQueryJson ?? '',
    viewStateJson ?? '',
    editingSmartPlaylistId ?? '',
  ].join('|');

  String get effectiveId => entryId ?? routeKey;

  bool isSameRoute(NavEntry other) => routeKey == other.routeKey;

  NavEntry copyWith({
    HomeTab? tab,
    String? albumId,
    String? artistKey,
    String? artistName,
    String? smartPlaylistId,
    String? streamingKind,
    String? creditArtistId,
    String? podcastShowId,
    PodcastShow? podcastShow,
    String? tagId,
    String? folderId,
    String? focusQueryJson,
    bool clearFocusQueryJson = false,
    String? viewStateJson,
    bool clearViewStateJson = false,
    String? activeBookmarkId,
    bool clearActiveBookmarkId = false,
    String? editingSmartPlaylistId,
    bool clearEditingSmartPlaylistId = false,
    String? entryId,
  }) {
    return NavEntry(
      tab: tab ?? this.tab,
      albumId: albumId ?? this.albumId,
      artistKey: artistKey ?? this.artistKey,
      artistName: artistName ?? this.artistName,
      smartPlaylistId: smartPlaylistId ?? this.smartPlaylistId,
      streamingKind: streamingKind ?? this.streamingKind,
      creditArtistId: creditArtistId ?? this.creditArtistId,
      podcastShowId: podcastShowId ?? this.podcastShowId,
      podcastShow: podcastShow ?? this.podcastShow,
      tagId: tagId ?? this.tagId,
      folderId: folderId ?? this.folderId,
      focusQueryJson: clearFocusQueryJson
          ? null
          : (focusQueryJson ?? this.focusQueryJson),
      viewStateJson: clearViewStateJson
          ? null
          : (viewStateJson ?? this.viewStateJson),
      activeBookmarkId: clearActiveBookmarkId
          ? null
          : (activeBookmarkId ?? this.activeBookmarkId),
      editingSmartPlaylistId: clearEditingSmartPlaylistId
          ? null
          : (editingSmartPlaylistId ?? this.editingSmartPlaylistId),
      entryId: entryId ?? this.entryId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavEntry &&
          runtimeType == other.runtimeType &&
          tab == other.tab &&
          albumId == other.albumId &&
          artistKey == other.artistKey &&
          artistName == other.artistName &&
          smartPlaylistId == other.smartPlaylistId &&
          streamingKind == other.streamingKind &&
          creditArtistId == other.creditArtistId &&
          podcastShowId == other.podcastShowId &&
          podcastShow == other.podcastShow &&
          tagId == other.tagId &&
          folderId == other.folderId &&
          focusQueryJson == other.focusQueryJson &&
          viewStateJson == other.viewStateJson &&
          activeBookmarkId == other.activeBookmarkId &&
          editingSmartPlaylistId == other.editingSmartPlaylistId &&
          entryId == other.entryId;

  @override
  int get hashCode => Object.hash(
    tab,
    albumId,
    artistKey,
    artistName,
    smartPlaylistId,
    streamingKind,
    creditArtistId,
    podcastShowId,
    podcastShow,
    tagId,
    folderId,
    focusQueryJson,
    viewStateJson,
    activeBookmarkId,
    editingSmartPlaylistId,
    entryId,
  );

  @override
  String toString() => 'NavEntry($routeKey, id: $entryId)';
}

/// Manages a browser-style back/forward navigation stack and per-entry scroll
/// offsets for [HomeScreen].
class NavHistoryController extends ChangeNotifier {
  final int maxHistory;
  final List<NavEntry> _backStack = [];
  final List<NavEntry> _forwardStack = [];
  final Map<String, double> _scrollOffsets = {};
  NavEntry _current;
  int _nextId = 1;

  NavHistoryController({
    NavEntry initialEntry = const NavEntry(
      tab: HomeTab.home,
      entryId: 'nav_0',
    ),
    this.maxHistory = 50,
  }) : _current = initialEntry.entryId != null
           ? initialEntry
           : initialEntry.copyWith(entryId: 'nav_0');

  NavEntry get current => _current;
  List<NavEntry> get backStack => List.unmodifiable(_backStack);
  List<NavEntry> get forwardStack => List.unmodifiable(_forwardStack);
  bool get canGoBack => _backStack.isNotEmpty;
  bool get canGoForward => _forwardStack.isNotEmpty;

  String _allocateEntryId() => 'nav_${_nextId++}';

  /// Navigates to [entry], pushing the current entry onto the back stack and
  /// clearing the forward stack. No-ops if [entry] matches the current route.
  void push(NavEntry entry) {
    if (entry.isSameRoute(_current)) return;
    _backStack.add(_current);
    if (_backStack.length > maxHistory) {
      final removed = _backStack.removeAt(0);
      _scrollOffsets.remove(removed.effectiveId);
    }
    for (final dropped in _forwardStack) {
      _scrollOffsets.remove(dropped.effectiveId);
    }
    _forwardStack.clear();
    _current = entry.entryId != null
        ? entry
        : entry.copyWith(entryId: _allocateEntryId());
    notifyListeners();
  }

  /// Replaces the current entry in-place without changing history stacks.
  void replaceCurrent(NavEntry entry) {
    _current = entry.entryId != null
        ? entry
        : entry.copyWith(entryId: _current.effectiveId);
    notifyListeners();
  }

  /// Steps back one entry if possible and returns the restored [NavEntry].
  NavEntry? goBack() {
    if (_backStack.isEmpty) return null;
    _forwardStack.add(_current);
    if (_forwardStack.length > maxHistory) {
      final removed = _forwardStack.removeAt(0);
      _scrollOffsets.remove(removed.effectiveId);
    }
    _current = _backStack.removeLast();
    notifyListeners();
    return _current;
  }

  /// Steps forward one entry if possible and returns the restored [NavEntry].
  NavEntry? goForward() {
    if (_forwardStack.isEmpty) return null;
    _backStack.add(_current);
    if (_backStack.length > maxHistory) {
      final removed = _backStack.removeAt(0);
      _scrollOffsets.remove(removed.effectiveId);
    }
    _current = _forwardStack.removeLast();
    notifyListeners();
    return _current;
  }

  /// Saves the scroll offset associated with [entryId].
  void saveScrollOffset(String entryId, double offset) {
    _scrollOffsets[entryId] = offset < 0 ? 0.0 : offset;
  }

  /// Returns the saved scroll offset for [entryId], defaulting to 0.0.
  double getScrollOffset(String entryId) => _scrollOffsets[entryId] ?? 0.0;

  void saveCurrentScrollOffset(double offset) {
    saveScrollOffset(_current.effectiveId, offset);
  }

  double get currentScrollOffset => getScrollOffset(_current.effectiveId);

  void clearScrollOffsets() {
    _scrollOffsets.clear();
  }
}
