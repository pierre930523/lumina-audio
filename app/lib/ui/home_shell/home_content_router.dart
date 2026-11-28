part of '../home_screen.dart';

extension _HomeContentRouter on _HomeScreenState {
  Widget _buildMainColumn({
    required bool isDesktop,
    required double availWidth,
  }) {
    final currentEntry = _navController.current;
    final inSettings = _isSettingsTab(_activeTab);
    final preset = _scaleController.homeLayoutPreset;
    final showCapsuleInSubRow =
        !isDesktop && preset.isSidebarless && availWidth < 660;
    final showCompactStrip = !isDesktop && preset.usesSidebar;

    final Widget stageChild;
    if (inSettings) {
      stageChild = _buildSettingsWorkspace(
        isDesktop: isDesktop,
        availWidth: availWidth,
        topBarHeight: isDesktop ? WindowDragBar.kDefaultHeight : 0.0,
      );
    } else {
      final maskedContent = _BottomEdgeFadeMask(
        key: const Key('main_content_bottom_fade_mask'),
        fadeHeight: 28.0,
        child: _buildActiveContent(
          isDesktop: isDesktop,
          availWidth: availWidth,
        ),
      );
      final extendBehindTopBar =
          isDesktop &&
          _activeTab == HomeTab.home &&
          preset == HomeLayoutPreset.auraQuickResume;
      stageChild = (isDesktop && !extendBehindTopBar)
          ? Column(
              children: [
                const SizedBox(height: WindowDragBar.kDefaultHeight),
                Expanded(child: maskedContent),
              ],
            )
          : maskedContent;
    }

    final switcher = AnimatedSwitcher(
      duration: const Duration(milliseconds: 120),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0.008, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(
          inSettings
              ? 'stage_settings_workspace'
              : 'stage_${currentEntry.effectiveId}',
        ),
        child: stageChild,
      ),
    );

    if (isDesktop) {
      return switcher;
    }

    return Column(
      children: [
        const SizedBox(height: WindowDragBar.kDefaultHeight),
        if (showCapsuleInSubRow)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _buildFloatingNavCapsule(
                  showIcons: false,
                  showDrawerLabel: false,
                ),
              ),
            ),
          )
        else if (showCompactStrip)
          _buildCompactNavStrip(),
        Expanded(child: switcher),
      ],
    );
  }

  Widget _buildActiveContent({
    required bool isDesktop,
    required double availWidth,
  }) {
    final entry = _navController.current;
    final entryId = entry.effectiveId;
    final savedOffset = _navController.getScrollOffset(entryId);
    void onOffsetChanged(double offset) {
      _handleScrollOffsetChanged(entryId, offset);
    }

    if (_activeTab == HomeTab.home) {
      final preset = _scaleController.homeLayoutPreset;
      final topInset =
          isDesktop && preset == HomeLayoutPreset.auraQuickResume
              ? WindowDragBar.kDefaultHeight
              : 0.0;
      return ListenableBuilder(
        listenable: Listenable.merge([_playlistService, _scaleController]),
        builder: (context, _) {
          final currentPreset = _scaleController.homeLayoutPreset;
          final effectiveTopInset =
              isDesktop && currentPreset == HomeLayoutPreset.auraQuickResume
                  ? WindowDragBar.kDefaultHeight
                  : topInset;
          return HomeStageView(
            preset: currentPreset,
            audioService: _effectiveAudioService,
            dataController: _homeDataController,
            libraryCache: _libraryCache,
            paletteService: _paletteService,
            smartPlaylists: _playlistService.playlists,
            auraFollowCover: _scaleController.auraFollowCover,
            minimalCoverMode: _scaleController.minimalCoverMode,
            initialScrollOffset: savedOffset,
            topInset: effectiveTopInset,
            onScrollOffsetChanged: onOffsetChanged,
            onOpenAlbums: () => _selectTab(HomeTab.albums),
            onOpenLibrary: () => _selectTab(HomeTab.library),
            onOpenCredits: () => _openArtistCredits(null),
            onOpenDsp: () => _selectTab(HomeTab.dsp),
            onOpenZones: () => _selectTab(HomeTab.zones),
            onOpenAppearance: () => _selectTab(HomeTab.appearance),
            onOpenLibrarySettings: () => _selectTab(HomeTab.librarySettings),
            onOpenProviderSettings: () => _selectTab(HomeTab.settings),
            onOpenAlbumDetail: _openAlbumDetail,
            onOpenSmartPlaylist: _openSmartPlaylist,
            onOpenSmartPlaylists: () => _selectTab(HomeTab.smartPlaylists),
          );
        },
      );
    }

    if (_isSettingsTab(_activeTab)) {
      return _buildSettingsWorkspace(
        isDesktop: isDesktop,
        availWidth: availWidth,
      );
    }

    final hPad = LuminaResponsive.contentHorizontalPadding(availWidth);
    final usesFloatingPill =
        _scaleController.homeLayoutPreset.usesFloatingPlayerPill;
    final fallbackMiniHeight = availWidth >= 740
        ? 84.0
        : (availWidth >= 480 ? 99.0 : 114.0);

    return ValueListenableBuilder<double?>(
      valueListenable: _measuredMiniPlayerHeight,
      builder: (context, measuredHeight, _) {
        final bottomPad = usesFloatingPill
            ? (measuredHeight ?? fallbackMiniHeight)
            : 0.0;
        return Padding(
          padding: EdgeInsets.fromLTRB(hPad, 8, hPad, bottomPad),
          child: switch (_activeTab) {
            HomeTab.library => StreamBuilder<PlaybackState>(
              stream: _effectiveAudioService.stateStream,
              initialData: _effectiveAudioService.currentState,
              builder: (context, snapshot) {
                final state =
                    snapshot.data ?? _effectiveAudioService.currentState;
                return LibraryBrowserView(
                  audioService: _effectiveAudioService,
                  libraryCache: _libraryCache,
                  activeTrackId: state.track?.id,
                  librarySettings: _librarySettingsController,
                  playlistService: _playlistService,
                  initialFocusQuery: entry.parsedFocusQuery,
                  initialViewStateJson: entry.viewStateJson,
                  editingSmartPlaylistId: entry.editingSmartPlaylistId,
                  onFocusQueryChanged: _handleActiveFocusQueryChanged,
                  onViewStateChanged: _handleActiveViewStateChanged,
                  onCancelEditSmartPlaylist: () {
                    _openSmartPlaylist(entry.editingSmartPlaylistId!);
                  },
                  onSavedSmartPlaylist: (sp) {
                    _openSmartPlaylist(sp.id);
                  },
                  onOpenLibrarySettings: () =>
                      _selectTab(HomeTab.librarySettings),
                  onOpenAlbumDetail: _openAlbumDetail,
                  onOpenArtist: _openArtist,
                );
              },
            ),
            HomeTab.albums => AlbumsAndCreditsView(
              key: ValueKey('albums_mode_$entryId'),
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              layoutController: _albumLayoutController,
              listenLaterController: _listenLaterController,
              startInCreditsMode: false,
              initialFocusQuery: entry.parsedFocusQuery,
              initialViewStateJson: entry.viewStateJson,
              onFocusQueryChanged: _handleActiveFocusQueryChanged,
              onViewStateChanged: _handleActiveViewStateChanged,
              initialScrollOffset: savedOffset,
              onScrollOffsetChanged: onOffsetChanged,
              onOpenAlbumDetail: _openAlbumDetail,
              onOpenArtist: _openArtist,
            ),
            HomeTab.albumDetail => AlbumDetailPage(
              key: ValueKey('album_detail_$entryId'),
              albumId: entry.albumId ?? _selectedAlbumId ?? '',
              audioService: _effectiveAudioService,
              streamingManager: _streamingManager,
              listenLaterController: _listenLaterController,
              onPlayStreamingTrack: _playStreamingTrack,
              libraryCache: _libraryCache,
              onBack: _goBack,
              showInlineBackButton: false,
              onOpenArtist: _openArtist,
              onOpenArtistCredits: _openArtistCredits,
              initialScrollOffset: savedOffset,
              onScrollOffsetChanged: onOffsetChanged,
              onTitleChanged: _onDetailTitleChanged,
            ),
            HomeTab.credits => AlbumsAndCreditsView(
              key: ValueKey('credits_mode_${entry.creditArtistId ?? entryId}'),
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              layoutController: _albumLayoutController,
              startInCreditsMode: true,
              initialArtistId: entry.creditArtistId ?? _selectedCreditArtistId,
              initialScrollOffset: savedOffset,
              onScrollOffsetChanged: onOffsetChanged,
              onOpenAlbumDetail: _openAlbumDetail,
              onOpenArtist: _openArtist,
            ),
            HomeTab.artists => ArtistsView(
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              onOpenArtist: _openArtist,
              onOpenCredits: () => _openArtistCredits(null),
              onOpenAlbumDetail: _openAlbumDetail,
            ),
            HomeTab.artistDetail => ArtistDetailPage(
              key: ValueKey('artist_detail_$entryId'),
              artistName: entry.artistName ?? entry.artistKey ?? '',
              artistKey: entry.artistKey,
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              onBack: _goBack,
              showInlineBackButton: false,
              onOpenAlbumDetail: _openAlbumDetail,
              onOpenCredits: () => _openArtistCredits(null),
              initialScrollOffset: savedOffset,
              onScrollOffsetChanged: onOffsetChanged,
              onTitleChanged: _onDetailTitleChanged,
            ),
            HomeTab.audiobooks => AudiobooksView(
              audioService: _effectiveAudioService,
            ),
            HomeTab.podcasts => PodcastsView(
              key: ValueKey('podcasts_view_$entryId'),
              audioService: _effectiveAudioService,
              streamingManager: _streamingManager,
              onPlayStreamingTrack: _playStreamingTrack,
              onOpenPodcastShow: _openPodcastDetail,
              onOpenLogin: () => _selectTab(HomeTab.settings),
              podcastStore: _podcastStore,
            ),
            HomeTab.podcastDetail => PodcastDetailPage(
              key: ValueKey('podcast_detail_$entryId'),
              showId: entry.podcastShowId ?? _selectedPodcastShowId ?? '',
              initialShow: entry.podcastShow ?? _selectedPodcastShow,
              audioService: _effectiveAudioService,
              streamingManager: _streamingManager,
              onPlayStreamingTrack: _playStreamingTrack,
              onBack: _goBack,
              podcastStore: _podcastStore,
              initialScrollOffset: savedOffset,
              onScrollOffsetChanged: onOffsetChanged,
              onTitleChanged: _onDetailTitleChanged,
            ),
            HomeTab.radio => RadioView(audioService: _effectiveAudioService),
            HomeTab.search => StreamBuilder<PlaybackState>(
              stream: _effectiveAudioService.stateStream,
              initialData: _effectiveAudioService.currentState,
              builder: (context, snapshot) {
                final state =
                    snapshot.data ?? _effectiveAudioService.currentState;
                return UnifiedSearchResultsView(
                  controller: _searchController,
                  audioService: _effectiveAudioService,
                  libraryCache: _libraryCache,
                  streamingManager: _streamingManager,
                  listenLaterController: _listenLaterController,
                  activeTrackId: state.track?.id,
                  onOpenLocalAlbum: _openAlbumDetail,
                  onOpenStreamingAlbum: _openStreamingAlbum,
                  onOpenArtist: _openArtist,
                  onPlayStreamingTrack: _playStreamingTrack,
                );
              },
            ),
            HomeTab.smartPlaylists => SmartPlaylistsView(
              audioService: _effectiveAudioService,
              playlistService: _playlistService,
              libraryCache: _libraryCache,
              selectedPlaylistId:
                  entry.smartPlaylistId ?? _selectedSmartPlaylistId,
              onSelectPlaylist: (id) {
                _refreshState(() => _selectedSmartPlaylistId = id);
                _navController.replaceCurrent(
                  _navController.current.copyWith(smartPlaylistId: id),
                );
              },
              onEditRules: _editSmartPlaylistRules,
            ),
            HomeTab.listenLater => ListenLaterView(
              audioService: _effectiveAudioService,
              controller: _listenLaterController,
              libraryCache: _libraryCache,
              onOpenAlbumDetail: _openAlbumDetail,
              onOpenStreamingAlbum: _openStreamingAlbum,
              onPlayStreamingTrack: _playStreamingTrack,
              onLibraryPromoted: () {
                _libraryCache.refresh(_effectiveAudioService);
                _refreshState();
              },
            ),
            HomeTab.tags => TagsView(
              key: ValueKey('tags_view_${entry.tagId ?? entryId}'),
              audioService: _effectiveAudioService,
              initialTagId: entry.tagId ?? _selectedTagId,
              onOpenFocusQuery: _openFocusQuery,
            ),
            HomeTab.folders => FoldersView(
              key: ValueKey('folders_view_${entry.folderId ?? entryId}'),
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              initialFolderId: entry.folderId ?? _selectedFolderId,
              onFolderChanged: (id) {
                _selectedFolderId = id;
              },
              onOpenAlbumDetail: _openAlbumDetail,
              onOpenArtist: _openArtist,
              onOpenLibrarySettings: () => _selectTab(HomeTab.librarySettings),
            ),
            HomeTab.streamingProvider => StreamBuilder<PlaybackState>(
              stream: _effectiveAudioService.stateStream,
              initialData: _effectiveAudioService.currentState,
              builder: (context, snapshot) {
                final meta = StreamingProviderMeta.byKind(
                  entry.streamingKind ?? _selectedStreamingKind ?? '',
                );
                if (meta == null) return const SizedBox.shrink();
                final state =
                    snapshot.data ?? _effectiveAudioService.currentState;
                return StreamingServiceView(
                  key: ValueKey('streaming_view_${meta.kind}'),
                  audioService: _effectiveAudioService,
                  provider: meta,
                  streamingManager: _streamingManager,
                  listenLaterController: _listenLaterController,
                  onPlayStreamingTrack: _playStreamingTrack,
                  onPlayStreamingTrackWithContext: (track, queue) =>
                      _playStreamingTrack(track, queueContext: queue),
                  onOpenStreamingAlbum: _openStreamingAlbum,
                  onSwitchStreamingProvider: _openStreamingProvider,
                  activeTrackId: state.track?.id,
                  onOpenProviderSettings: () => _selectTab(HomeTab.settings),
                  onLibraryUpdated: () {
                    _libraryCache.refresh(widget.audioService);
                    _refreshState();
                  },
                );
              },
            ),
            _ => const SizedBox.shrink(),
          },
        );
      },
    );
  }
}
