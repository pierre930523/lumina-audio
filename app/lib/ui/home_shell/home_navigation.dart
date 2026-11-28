part of '../home_screen.dart';

extension _HomeNavigation on _HomeScreenState {
  void _onSettingsScrollChanged() {
    if (!mounted || !_isSettingsTab(_activeTab)) return;
    if (_settingsScrollController.positions.length != 1) return;
    final scrolled = _settingsScrollController.offset > 16.0;
    if (_headerScrimVisible.value != scrolled) {
      _headerScrimVisible.value = scrolled;
    }
  }

  void _onScaleControllerVisualizerChanged() {
    widget.audioService.setVisualizerSettingEnabled(false);
  }

  void _onNavChanged() {
    if (!mounted) return;
    _refreshState(() {
      _syncStateFromEntry(_navController.current);
    });
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final isDetail =
        _activeTab == HomeTab.albumDetail || _activeTab == HomeTab.artistDetail;
    if (isDetail) {
      _refreshState();
    }
  }

  void _onDetailTitleChanged(String title) {
    if (_activeDetailTitle == title) return;
    _activeDetailTitle = title;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshState();
      }
    });
  }

  void _handleScrollOffsetChanged(String entryId, double offset) {
    _navController.saveScrollOffset(entryId, offset);
    if (_activeTab == HomeTab.home) {
      final scrolled = offset > 16.0;
      if (_headerScrimVisible.value != scrolled) {
        _headerScrimVisible.value = scrolled;
      }
    }
    final isDetailTab =
        _activeTab == HomeTab.albumDetail ||
        _activeTab == HomeTab.artistDetail ||
        _activeTab == HomeTab.podcastDetail;
    if (isDetailTab) {
      final pastHero = offset > 200;
      if (pastHero != _isDetailScrolledPastHero) {
        _refreshState(() {
          _isDetailScrolledPastHero = pastHero;
          if (pastHero) {
            _stickyTitleFadeController.forward();
          } else {
            _stickyTitleFadeController.reverse();
          }
        });
      }
    }
  }

  String _resolveStickyTitle() {
    if (_activeDetailTitle != null && _activeDetailTitle!.isNotEmpty) {
      return _activeDetailTitle!;
    }
    final entry = _navController.current;
    if (_activeTab == HomeTab.albumDetail) {
      final albumId = entry.albumId ?? _selectedAlbumId ?? '';
      if (albumId.isEmpty) return '';
      final cachedDetail =
          _libraryCache.getAlbumDetailSync(albumId) ??
          _libraryCache.albumDetailsById[albumId];
      if (cachedDetail != null && cachedDetail.title.isNotEmpty) {
        return cachedDetail.title;
      }
      final cachedSummary =
          _libraryCache.getAlbumSummarySync(albumId) ??
          _libraryCache.albumsById[albumId];
      if (cachedSummary != null && cachedSummary.title.isNotEmpty) {
        return cachedSummary.title;
      }
      return '';
    }
    if (_activeTab == HomeTab.artistDetail) {
      final name = entry.artistName?.trim() ?? '';
      if (name.isNotEmpty) return name;
      final key = entry.artistKey?.trim() ?? '';
      if (key.isNotEmpty) {
        final fromIndex = _libraryCache.artistsByKey[key]?.displayName;
        if (fromIndex != null && fromIndex.isNotEmpty) return fromIndex;
        return key;
      }
      return '';
    }
    if (_activeTab == HomeTab.podcastDetail) {
      final showTitle =
          (entry.podcastShow?.title ?? _selectedPodcastShow?.title ?? '')
              .trim();
      if (showTitle.isNotEmpty) return showTitle;
      return '';
    }
    return '';
  }

  void _syncStateFromEntry(NavEntry entry) {
    _headerScrimVisible.value = false;
    if (_isSettingsTab(entry.tab) &&
        entry.tab != _activeTab &&
        _settingsScrollController.positions.length == 1) {
      _settingsScrollController.jumpTo(0.0);
    }
    if (entry.albumId != null) {
      _selectedAlbumId = entry.albumId;
    }
    if (entry.tab == HomeTab.credits) {
      _selectedCreditArtistId = entry.creditArtistId;
    }
    if (entry.smartPlaylistId != null) {
      _selectedSmartPlaylistId = entry.smartPlaylistId;
    }
    if (entry.streamingKind != null) {
      _selectedStreamingKind = entry.streamingKind;
    }
    if (entry.podcastShowId != null) {
      _selectedPodcastShowId = entry.podcastShowId;
    }
    if (entry.podcastShow != null) {
      _selectedPodcastShow = entry.podcastShow;
    }
    if (entry.tagId != null) {
      _selectedTagId = entry.tagId;
    }
    if (entry.folderId != null) {
      _selectedFolderId = entry.folderId;
    }
    _activeFocusQueryJson = entry.focusQueryJson;
    _activeViewStateJson = entry.viewStateJson;
    _activeBookmarkId = entry.activeBookmarkId;
    _bookmarksController.setActiveBookmarkId(
      entry.activeBookmarkId,
      notify: false,
    );
    if (entry.tab.isSettings) {
      _lastSettingsTab = entry.tab;
    }

    final isDetailTab =
        entry.tab == HomeTab.albumDetail ||
        entry.tab == HomeTab.artistDetail ||
        entry.tab == HomeTab.podcastDetail;
    if (isDetailTab) {
      final savedOffset = _navController.getScrollOffset(entry.effectiveId);
      _isDetailScrolledPastHero = savedOffset > 200;
      _stickyTitleFadeController.value = _isDetailScrolledPastHero ? 1.0 : 0.0;
    } else {
      _activeDetailTitle = null;
      _isDetailScrolledPastHero = false;
      _stickyTitleFadeController.value = 0.0;
    }
  }

  Future<void> _refreshProviders() async {
    await widget.audioService.listProviders();
    if (!mounted) return;
    _syncStreamingProvidersFromManager();
  }

  Future<void> _initShaders() async {
    final loaded = await ShaderLoader.load();
    if (!mounted) return;
    _refreshState(() {
      _shaders = loaded;
      _glassShader = loaded.liquidGlassProgram?.fragmentShader();
    });
  }

  bool _isSettingsTab(HomeTab tab) => tab.isSettings;

  void _onNowPlayingAnimStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.completed) {
      _refreshState();
    }
  }

  void _setNowPlayingExpanded(bool expanded) {
    if (_isNowPlayingExpanded == expanded) return;
    if (!expanded && _nowPlayingController.queueDrawerOpen) {
      _nowPlayingController.setQueueDrawerOpen(false);
    }
    _refreshState(() {
      _isNowPlayingExpanded = expanded;
      if (expanded) {
        _hasEverExpandedNowPlaying = true;
        _nowPlayingAnimController.forward();
      } else {
        _nowPlayingAnimController.reverse();
      }
    });
  }

  void _pushEntry(NavEntry entry) {
    if (entry.isSameRoute(_navController.current) && !_isNowPlayingExpanded) {
      return;
    }
    _setNowPlayingExpanded(false);
    _refreshState(() {
      _syncStateFromEntry(entry);
    });
    _navController.push(entry);
  }

  void _selectTab(HomeTab next) {
    final entry = switch (next) {
      HomeTab.smartPlaylists => NavEntry(
        tab: HomeTab.smartPlaylists,
        smartPlaylistId: _selectedSmartPlaylistId,
      ),
      HomeTab.credits => NavEntry.credits(artistId: _selectedCreditArtistId),
      HomeTab.albumDetail => NavEntry.album(_selectedAlbumId ?? ''),
      HomeTab.tags => NavEntry.tags(tagId: _selectedTagId),
      HomeTab.folders => NavEntry.folders(folderId: _selectedFolderId),
      _ => NavEntry.tab(next),
    };
    _pushEntry(entry);
  }

  void _openFocusQuery(FocusQuery query) {
    _pushEntry(NavEntry.focus(query));
  }

  void _openAlbumDetail(String albumId) {
    if (albumId.isEmpty) return;
    _selectedAlbumId = albumId;
    if (!albumId.startsWith('streaming:')) {
      _libraryCache.loadAlbumDetail(widget.audioService, albumId);
    }
    _pushEntry(NavEntry.album(albumId));
  }

  void _openStreamingAlbum(StreamingAlbum album) {
    final fullId = 'streaming:${album.providerKind}:${album.id}';
    _selectedAlbumId = fullId;
    _libraryCache.putAlbumSummarySync(
      CanonicalAlbumSummary(
        id: fullId,
        title: album.title,
        artist: album.artist,
        year: album.year,
        availableProviders: <String>[album.providerKind],
        coverUrl: album.coverUrl,
      ),
    );
    _pushEntry(NavEntry.album(fullId));
  }

  void _openArtist(String artistName) {
    final trimmed = artistName.trim();
    if (trimmed.isEmpty) return;
    _libraryCache.ensureArtistLoaded(widget.audioService, trimmed);
    _pushEntry(NavEntry.artist(artistName: trimmed));
  }

  void _openArtistCredits(String? artistId) {
    _selectedCreditArtistId = artistId;
    _pushEntry(NavEntry.credits(artistId: artistId));
  }

  void _openStreamingProvider(String kind) {
    _selectedStreamingKind = kind;
    _pushEntry(NavEntry.streaming(kind));
  }

  void _openSmartPlaylist(String playlistId) {
    _selectedSmartPlaylistId = playlistId;
    _pushEntry(NavEntry.smartPlaylist(playlistId));
  }

  void _editSmartPlaylistRules(SmartPlaylistItem playlist) {
    final query =
        playlist.parseFocusQuery() ?? const FocusQuery(entity: FocusEntity.tracks);
    _pushEntry(
      NavEntry.focus(
        query.copyWith(entity: FocusEntity.tracks),
        editingSmartPlaylistId: playlist.id,
      ),
    );
  }

  void _handleActiveFocusQueryChanged(FocusQuery query) {
    _activeFocusQueryJson = jsonEncode(query.toJson());
  }

  void _handleActiveViewStateChanged(String? viewStateJson) {
    _activeViewStateJson = viewStateJson;
  }

  String _currentTargetRouteName() {
    final entry = _navController.current;
    return switch (entry.tab) {
      HomeTab.library => 'tracks',
      HomeTab.albums => 'albums',
      HomeTab.albumDetail => 'album:${entry.albumId ?? _selectedAlbumId ?? ''}',
      HomeTab.artistDetail =>
        'artist:${entry.artistName ?? entry.artistKey ?? ''}',
      HomeTab.smartPlaylists =>
        'smart_playlist:${entry.smartPlaylistId ?? _selectedSmartPlaylistId ?? ''}',
      HomeTab.listenLater => 'listen_later',
      HomeTab.tags => 'tags:${entry.tagId ?? ''}',
      HomeTab.folders => 'folders:${entry.folderId ?? ''}',
      HomeTab.streamingProvider =>
        'streaming:${entry.streamingKind ?? _selectedStreamingKind ?? ''}',
      _ => entry.tab.name,
    };
  }

  String _defaultBookmarkName() {
    return switch (_activeTab) {
      HomeTab.library => '曲目檢視書籤',
      HomeTab.albums => '專輯檢視書籤',
      HomeTab.albumDetail =>
        _resolveStickyTitle().isNotEmpty ? _resolveStickyTitle() : '專輯書籤',
      HomeTab.artistDetail =>
        _resolveStickyTitle().isNotEmpty ? _resolveStickyTitle() : '藝術家書籤',
      HomeTab.listenLater => '稍後收聽',
      _ => '自訂檢視書籤',
    };
  }

  Future<void> _saveCurrentAsBookmark(String name) async {
    final created = await _bookmarksController.create(
      name: name,
      targetRoute: _currentTargetRouteName(),
      focusQueryJson: _activeFocusQueryJson,
      viewStateJson: _activeViewStateJson,
    );
    if (created != null && mounted) {
      _refreshState(() => _activeBookmarkId = created.id);
      _navController.replaceCurrent(
        _navController.current.copyWith(
          activeBookmarkId: created.id,
          focusQueryJson: _activeFocusQueryJson,
          viewStateJson: _activeViewStateJson,
        ),
      );
    }
  }

  Future<void> _updateActiveBookmark(BookmarkItem active) async {
    final updated = await _bookmarksController.update(
      active.id,
      targetRoute: _currentTargetRouteName(),
      focusQueryJson: _activeFocusQueryJson,
      viewStateJson: _activeViewStateJson,
    );
    if (updated != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已更新書籤「${updated.name}」')),
      );
    }
  }

  void _openBookmark(BookmarkItem bm) {
    final route = bm.targetRoute.trim();
    final uniqueEntryId =
        'bm_${bm.id}_${DateTime.now().microsecondsSinceEpoch}';
    NavEntry target;
    if (route == 'tracks' || route == 'library') {
      target = NavEntry(
        tab: HomeTab.library,
        focusQueryJson: bm.focusQueryJson,
        viewStateJson: bm.viewStateJson,
        activeBookmarkId: bm.id,
        entryId: uniqueEntryId,
      );
    } else if (route == 'albums') {
      target = NavEntry(
        tab: HomeTab.albums,
        focusQueryJson: bm.focusQueryJson,
        viewStateJson: bm.viewStateJson,
        activeBookmarkId: bm.id,
        entryId: uniqueEntryId,
      );
    } else if (route.startsWith('album:')) {
      final albumId = route.substring('album:'.length);
      target = NavEntry.album(albumId, entryId: uniqueEntryId).copyWith(
        activeBookmarkId: bm.id,
        viewStateJson: bm.viewStateJson,
      );
    } else if (route.startsWith('artist:')) {
      final artistName = route.substring('artist:'.length);
      target = NavEntry.artist(
        artistName: artistName,
        entryId: uniqueEntryId,
      ).copyWith(activeBookmarkId: bm.id, viewStateJson: bm.viewStateJson);
    } else if (route.startsWith('smart_playlist:')) {
      final pid = route.substring('smart_playlist:'.length);
      target = NavEntry.smartPlaylist(
        pid,
        entryId: uniqueEntryId,
      ).copyWith(activeBookmarkId: bm.id);
    } else if (route == 'listen_later' || route == 'listenLater') {
      target = NavEntry.listenLater(
        entryId: uniqueEntryId,
      ).copyWith(activeBookmarkId: bm.id);
    } else {
      final matchedTab = HomeTab.values
          .where((t) => t.name == route)
          .firstOrNull;
      target = NavEntry(
        tab: matchedTab ?? HomeTab.albums,
        focusQueryJson: bm.focusQueryJson,
        viewStateJson: bm.viewStateJson,
        activeBookmarkId: bm.id,
        entryId: uniqueEntryId,
      );
    }
    _pushEntry(target);
  }

  void _openPodcastDetail(String showId, {PodcastShow? show}) {
    final cleanId = showId.trim();
    if (cleanId.isEmpty) return;
    _selectedPodcastShowId = cleanId;
    if (show != null) {
      _selectedPodcastShow = show;
    }
    _pushEntry(NavEntry.podcastDetail(cleanId, show: show));
  }

  Future<void> _promptCreateSmartPlaylist() async {
    final created = await SmartPlaylistsView.showCreateDialog(
      context: context,
      service: _playlistService,
    );
    if (created != null && mounted) {
      _openSmartPlaylist(created.id);
    }
  }

  void _goBack() {
    if (!_navController.canGoBack) return;
    _setNowPlayingExpanded(false);
    _navController.goBack();
  }

  void _goForward() {
    if (!_navController.canGoForward) return;
    _setNowPlayingExpanded(false);
    _navController.goForward();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if ((event.buttons & kBackMouseButton) != 0) {
      _goBack();
    } else if ((event.buttons & kForwardMouseButton) != 0) {
      _goForward();
    }
  }

  void _toggleNowPlaying() {
    if (_isNowPlayingExpanded) {
      _setNowPlayingExpanded(false);
      return;
    }
    _nowPlayingController.setQueueDrawerOpen(false);
    _nowPlayingController.setMode(NowPlayingViewMode.cover);
    _setNowPlayingExpanded(true);
  }

  void _toggleNowPlayingWithLyrics() {
    if (_isNowPlayingExpanded) {
      _setNowPlayingExpanded(false);
      return;
    }
    _nowPlayingController.setQueueDrawerOpen(false);
    _nowPlayingController.setMode(NowPlayingViewMode.split);
    _setNowPlayingExpanded(true);
  }

  void _toggleNowPlayingLyricsMode() {
    _nowPlayingController.setQueueDrawerOpen(false);
    final next = _nowPlayingController.mode == NowPlayingViewMode.cover
        ? NowPlayingViewMode.split
        : NowPlayingViewMode.cover;
    _nowPlayingController.setMode(next);
  }
}
