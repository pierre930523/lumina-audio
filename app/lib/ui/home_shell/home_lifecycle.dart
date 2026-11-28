part of '../home_screen.dart';

extension _HomeLifecycle on _HomeScreenState {
  void _initControllers() {
    _stickyTitleFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _stickyTitleFadeAnimation = CurvedAnimation(
      parent: _stickyTitleFadeController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _ownsNowPlayingController = widget.nowPlayingController == null;
    _nowPlayingController =
        widget.nowPlayingController ?? NowPlayingViewController();
    if (_ownsNowPlayingController) {
      _nowPlayingController.load();
    }
    _paletteService = widget.artworkPaletteService ?? ArtworkPaletteService();

    _nowPlayingAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _nowPlayingCurvedAnim = CurvedAnimation(
      parent: _nowPlayingAnimController,
      curve: const Cubic(0.22, 1.0, 0.36, 1.0),
      reverseCurve: Curves.easeInCubic,
    );
    _nowPlayingSlideAnim = Tween<Offset>(
      begin: const Offset(0.0, 1.0),
      end: Offset.zero,
    ).animate(_nowPlayingCurvedAnim);
    _nowPlayingAnimController.addStatusListener(_boundNowPlayingAnimStatus);

    _ownsNavController = widget.navHistoryController == null;
    _navController = widget.navHistoryController ?? NavHistoryController();
    _navController.addListener(_boundNavChanged);

    _ownsLibraryCache = widget.libraryCache == null;
    _libraryCache = widget.libraryCache ?? LibraryIndexCache();
    _libraryCache.seedFromQueueSync(widget.audioService.queue);
    _libraryCache.prime(widget.audioService);
    _libraryCache.addListener(_boundLibraryCacheChanged);

    _ownsScaleController = widget.uiScaleController == null;
    _scaleController = widget.uiScaleController ?? UiScaleController();
    _lastHomeLayoutPreset = _scaleController.homeLayoutPreset;
    _lastThemeMode = _scaleController.themeMode;
    _lastAuraFollowCover = _scaleController.auraFollowCover;
    _lastMinimalCoverMode = _scaleController.minimalCoverMode;
    widget.audioService.setVisualizerSettingEnabled(false);
    _scaleController.addListener(_boundScaleControllerVisualizerChanged);
    _scaleController.addListener(_boundScaleAppearanceChanged);
    _librarySettingsController = LibrarySettingsController()..load();
    _albumLayoutController = AlbumLayoutSettingsController()..load();
    _initShaders();

    _playbackSession = AppServiceBootstrapper.createSession(
      audioService: widget.audioService,
      streamingManager: widget.streamingManager,
      recommendationSettings: widget.recommendationSettings,
      autoplayController: widget.autoplayController,
      onStreamingNotice: _showStreamingNoticeSnackBar,
      onStreamingError: _showStreamingErrorSnackBar,
    );
    _streamingManager = _playbackSession.streamingManager;
    _streamingManager.addListener(_boundStreamingManagerChanged);
    _syncStreamingProvidersFromManager(notify: false);
    _recommendationSettings = _playbackSession.recommendationSettings;
    _effectiveAudioService = _playbackSession.effectiveAudioService;
    _playlistService = SmartPlaylistService(_effectiveAudioService)..load();
    _bookmarksController = BookmarksController(_effectiveAudioService)..load();
    _listenLaterController = ListenLaterController(_effectiveAudioService)
      ..refresh();
    _syncStateFromEntry(_navController.current);
    _listenLaterPlaybackTracker = ListenLaterPlaybackTracker(
      audioService: _effectiveAudioService,
      settings: _librarySettingsController,
      onAutoMarkedListened: _listenLaterController.applyAutoMarkedItem,
    );
    _selectedSmartPlaylistId = _playlistService.playlists.firstOrNull?.id;
    _homeDataController = HomeDashboardDataController(
      audioService: _effectiveAudioService,
      libraryCache: _libraryCache,
      playlistService: _playlistService,
    );
    unawaited(_homeDataController.ensureLoaded());
    _searchController = UnifiedSearchController(
      audioService: _effectiveAudioService,
      libraryCache: _libraryCache,
      streamingManager: _streamingManager,
      librarySettings: _librarySettingsController,
    );

    _ownsPlaybackPersistenceService = widget.playbackPersistenceService == null;
    _playbackPersistenceService =
        widget.playbackPersistenceService ?? PlaybackPersistenceService();
    _podcastStore = widget.podcastStore ?? PodcastStore.instance;
    _podcastStore.ensureLoadedSync();
    _podcastPlaybackTracker = PodcastPlaybackTracker(
      audioService: _effectiveAudioService,
      store: _podcastStore,
    );
  }

  void _bindWindowController() {
    _windowController.onWindowClose = _boundWindowClose;
    _windowController.onTrayClick = _boundRestoreFromTray;
    _windowController.onTrayMenuAction = _boundTrayMenuAction;
    _windowController.onSingleInstanceWakeup = _boundRestoreFromTray;
    _windowController.onWindowMinimize = _boundWindowMinimize;
    _windowController.onWindowRestore = _boundWindowRestoredOrFocused;
    _windowController.onWindowMaximize = _boundWindowRestoredOrFocused;
    _windowController.onWindowUnmaximize = _boundWindowRestoredOrFocused;
    _windowController.onWindowFocus = _boundWindowRestoredOrFocused;
  }

  void _initWindowAndTray() {
    _windowController.setPreventClose(true);
    _bindWindowController();
    final initialTray = _trayInfoFor(_effectiveAudioService.currentState);
    _lastTrayTrackKey = _trayTrackKeyFor(_effectiveAudioService.currentState);
    _lastTrayPlaying = initialTray.isPlaying;
    _lastTrayIdle = _isTrayIdleState(_effectiveAudioService.currentState);
    _windowController.initTray(
      tooltip: initialTray.tooltip,
      nowPlayingLabel: initialTray.nowPlayingLabel,
      isPlaying: initialTray.isPlaying,
    );

    _playbackStateSub = _effectiveAudioService.stateStream.listen(
      _onPlaybackState,
    );
    _trackChangedSub = _effectiveAudioService.trackChangedStream.listen(
      _onTrackChanged,
    );
    _topSearchFocusNode.addListener(_boundTopSearchFocusChanged);
    _settingsScrollController.addListener(_boundSettingsScrollChanged);
    EscapeDismissRegistry.instance.registerGlobalHost();
    HardwareKeyboard.instance.addHandler(_boundHardwareKey);
    _initializeStartupSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isExiting) return;
      unawaited(_streamingManager.warmup());
    });
  }

  void _unbindWindowController() {
    if (_windowController.onWindowClose == _boundWindowClose) {
      _windowController.onWindowClose = null;
    }
    if (_windowController.onTrayClick == _boundRestoreFromTray) {
      _windowController.onTrayClick = null;
    }
    if (_windowController.onTrayMenuAction == _boundTrayMenuAction) {
      _windowController.onTrayMenuAction = null;
    }
    if (_windowController.onSingleInstanceWakeup == _boundRestoreFromTray) {
      _windowController.onSingleInstanceWakeup = null;
    }
    if (_windowController.onWindowMinimize == _boundWindowMinimize) {
      _windowController.onWindowMinimize = null;
    }
    if (_windowController.onWindowRestore == _boundWindowRestoredOrFocused) {
      _windowController.onWindowRestore = null;
    }
    if (_windowController.onWindowMaximize == _boundWindowRestoredOrFocused) {
      _windowController.onWindowMaximize = null;
    }
    if (_windowController.onWindowUnmaximize == _boundWindowRestoredOrFocused) {
      _windowController.onWindowUnmaximize = null;
    }
    if (_windowController.onWindowFocus == _boundWindowRestoredOrFocused) {
      _windowController.onWindowFocus = null;
    }
  }

  void _disposeControllers() {
    HardwareKeyboard.instance.removeHandler(_boundHardwareKey);
    EscapeDismissRegistry.instance.unregisterGlobalHost();
    _topSearchFocusNode.removeListener(_boundTopSearchFocusChanged);
    _topSearchFocusNode.dispose();
    _topSearchController.dispose();
    _searchController.dispose();
    _settingsScrollController.removeListener(_boundSettingsScrollChanged);
    _settingsScrollController.dispose();
    _sidebarScrollController.dispose();
    _settingsTabBarScrollController.dispose();
    _compactNavScrollController.dispose();
    _headerScrimVisible.dispose();
    _measuredMiniPlayerHeight.dispose();
    _effectiveMiniPlayerClearance.dispose();
    _unbindWindowController();
    _streamingManager.removeListener(_boundStreamingManagerChanged);
    _playbackSession.dispose();
    _nowPlayingAnimController.removeStatusListener(_boundNowPlayingAnimStatus);
    _nowPlayingAnimController.dispose();
    if (_ownsNowPlayingController) {
      _nowPlayingController.dispose();
    }
    _stickyTitleFadeController.dispose();
    _libraryCache.removeListener(_boundLibraryCacheChanged);
    _navController.removeListener(_boundNavChanged);
    if (_ownsNavController) {
      _navController.dispose();
    }
    if (_ownsLibraryCache) {
      _libraryCache.dispose();
    }
    _scaleController.removeListener(_boundScaleControllerVisualizerChanged);
    _scaleController.removeListener(_boundScaleAppearanceChanged);
    if (_ownsScaleController) {
      _scaleController.dispose();
    }
    _homeDataController.dispose();
    _playlistService.dispose();
    _bookmarksController.dispose();
    _listenLaterController.dispose();
    _listenLaterPlaybackTracker.dispose();
    _librarySettingsController.dispose();
    _albumLayoutController.dispose();
    _podcastPlaybackTracker.dispose();
    _playbackStateSub?.cancel();
    _playbackStateSub = null;
    _trackChangedSub?.cancel();
    _trackChangedSub = null;
    if (!_isExiting) {
      unawaited(_playbackPersistenceService.flush(syncFlush: true));
    }
    if (_ownsPlaybackPersistenceService) {
      _playbackPersistenceService.dispose();
    }
    _glassShader?.dispose();
    _shaders.backdropImage?.dispose();
  }

  Future<void> _initializeStartupSession() async {
    // Yield past synchronous initState/build before reading prefs so
    // UiScaleController.load() never notifies parent ListenableBuilders during build.
    await Future<void>.value();
    if (!mounted || _isExiting) return;
    try {
      await _scaleController.load(
        audioService: _ownsScaleController ? _effectiveAudioService : null,
      );
      if (!mounted || _isExiting) return;

      await _playbackPersistenceService.restoreSession(
        _effectiveAudioService,
        rememberPosition: _scaleController.rememberPlaybackPosition,
      );
    } catch (_) {
      // Keep startup resilient if preferences or session file fail to read.
    } finally {
      _isStartupRestoring = false;
      final cur = _effectiveAudioService.currentState;
      _lastPersistedStatus = cur.status;
      _lastPersistedTrackId = cur.track?.id;
      _syncTrayFromState(cur);
    }

    if (!mounted || _isExiting) return;
    try {
      await _streamingManager.initialize();
    } catch (_) {
      // Provider errors remain visible on each provider's authState/lastError.
    }
    if (!mounted || _isExiting) return;
    _syncStreamingProvidersFromManager();
  }

  void _onStreamingManagerChanged() {
    _syncStreamingProvidersFromManager();
  }

  void _syncStreamingProvidersFromManager({bool notify = true}) {
    final streaming = _streamingManager.providers
        .where(
          (p) =>
              p.authState == StreamingAuthState.connected ||
              p.authState == StreamingAuthState.authRequired ||
              _streamingManager.isAuthRequired(p.kind) ||
              p.supportsGuestMode,
        )
        .map(
          (p) => ProviderStatusInfo(
            kind: p.kind,
            isConfigured:
                p.authState == StreamingAuthState.connected ||
                p.authState == StreamingAuthState.authRequired ||
                _streamingManager.isAuthRequired(p.kind),
            isOnline: p.authState == StreamingAuthState.connected,
          ),
        )
        .toList(growable: false);
    if (!notify) {
      _loggedInStreamingProviders = streaming;
      return;
    }
    if (!mounted) return;
    _refreshState(() {
      _loggedInStreamingProviders = streaming;
      if (_activeTab == HomeTab.streamingProvider &&
          !streaming.any((p) => p.kind == _selectedStreamingKind)) {
        _selectedStreamingKind = null;
        _navController.replaceCurrent(NavEntry.tab(HomeTab.settings));
      }
    });
  }
}
