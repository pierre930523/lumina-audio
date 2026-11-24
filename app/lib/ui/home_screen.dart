import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/nav_entry.dart';
import '../models/playback_state.dart';
import '../models/podcast_models.dart';
import '../models/streaming_models.dart';
import '../models/streaming_provider_meta.dart';
import '../models/studio_models.dart';
import '../services/album_layout_settings_controller.dart';
import '../services/artwork_palette_service.dart';
import '../services/audio_service.dart';
import '../services/desktop_window_controller.dart';
import '../services/escape_dismiss_registry.dart';
import '../services/ffi_audio_service.dart';
import '../services/library_index_cache.dart';
import '../services/library_settings_controller.dart';
import '../services/now_playing_view_controller.dart';
import '../services/playback_persistence_service.dart';
import '../services/podcast_store.dart';
import '../services/smart_playlist_service.dart';
import '../services/streaming/l1_stream_cache.dart';
import '../services/streaming/oauth_helper.dart';
import '../services/streaming/pot_sidecar_manager.dart';
import '../services/streaming/secure_credential_store.dart';
import '../services/streaming/streaming_manager.dart';
import '../services/streaming/streaming_playback_coordinator.dart';
import '../services/ui_scale_controller.dart';
import '../services/unified_search_controller.dart';
import '../shaders/shader_loader.dart';
import 'albums/album_detail_page.dart';
import 'albums/albums_and_credits_view.dart';
import 'artists/artist_detail_page.dart';
import 'artists/artists_view.dart';
import 'audiobooks/audiobooks_view.dart';
import 'common/desktop_window_caption.dart';
import 'common/track_hover_prefetch.dart';
import 'common/window_drag_bar.dart';
import 'dsp/dsp_control_panel.dart';
import 'home/home_dashboard_view.dart';
import 'library/library_browser_view.dart';
import 'mini_player/floating_capsule.dart';
import 'now_playing/now_playing_overlay.dart';
import 'playlists/smart_playlists_view.dart';
import 'podcasts/podcast_detail_page.dart';
import 'podcasts/podcasts_view.dart';
import 'profiles/profile_switcher_bar.dart';
import 'radio/radio_view.dart';
import 'search/unified_search_results_view.dart';
import 'settings/appearance_scale_panel.dart';
import 'settings/general_settings_panel.dart';
import 'settings/library_settings_panel.dart';
import 'settings/providers_and_remote_panel.dart';
import 'settings/streaming_login_dialog.dart';
import 'streaming/streaming_service_view.dart';
import 'theme/lumina_tokens.dart';
import 'theme/responsive_layout.dart';
import 'zones/output_zone_panel.dart';

class _NavItemSpec {
  final HomeTab tab;
  final String keyName;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  const _NavItemSpec({
    required this.tab,
    required this.keyName,
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

class HomeScreen extends StatefulWidget {
  final AudioService audioService;
  final UiScaleController? uiScaleController;
  final LibraryIndexCache? libraryCache;
  final NavHistoryController? navHistoryController;
  final NowPlayingViewController? nowPlayingController;
  final ArtworkPaletteService? artworkPaletteService;
  final DesktopWindowController? windowController;
  final StreamingManager? streamingManager;
  final PlaybackPersistenceService? playbackPersistenceService;
  final PodcastStore? podcastStore;

  const HomeScreen({
    super.key,
    required this.audioService,
    this.uiScaleController,
    this.libraryCache,
    this.navHistoryController,
    this.nowPlayingController,
    this.artworkPaletteService,
    this.windowController,
    this.streamingManager,
    this.playbackPersistenceService,
    this.podcastStore,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final DesktopWindowController _windowController =
      widget.windowController ?? DesktopWindowController.instance;
  static const _canvasBg = LuminaTokens.canvasBg;
  static const _sidebarBg = LuminaTokens.sidebarBg;
  static const _settingsRailBg = LuminaTokens.sidebarBg;
  static const _dividerColor = LuminaTokens.borderSubtle;
  static const _accentBlue = LuminaTokens.accentBlue;

  static const List<_NavItemSpec> _browseNavItems = [
    _NavItemSpec(
      tab: HomeTab.home,
      keyName: 'nav_tab_home',
      label: '主頁',
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.credits,
      keyName: 'nav_tab_credits',
      label: '關係圖',
      icon: Icons.account_tree_outlined,
      activeIcon: Icons.account_tree_rounded,
    ),
  ];

  static const List<_NavItemSpec> _libraryNavItems = [
    _NavItemSpec(
      tab: HomeTab.albums,
      keyName: 'nav_tab_albums',
      label: '專輯',
      icon: Icons.album_outlined,
      activeIcon: Icons.album_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.artists,
      keyName: 'nav_tab_artists',
      label: '藝術家',
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.library,
      keyName: 'nav_tab_library',
      label: '曲目',
      icon: Icons.music_note_outlined,
      activeIcon: Icons.music_note_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.smartPlaylists,
      keyName: 'nav_tab_smart_playlists',
      label: '智慧歌單',
      icon: Icons.auto_awesome_outlined,
      activeIcon: Icons.auto_awesome_rounded,
    ),
  ];

  static const List<_NavItemSpec> _mediaNavItems = [
    _NavItemSpec(
      tab: HomeTab.audiobooks,
      keyName: 'nav_tab_audiobooks',
      label: '有聲書',
      icon: Icons.menu_book_outlined,
      activeIcon: Icons.menu_book_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.podcasts,
      keyName: 'nav_tab_podcasts',
      label: 'Podcast',
      icon: Icons.podcasts_outlined,
      activeIcon: Icons.podcasts_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.radio,
      keyName: 'nav_tab_radio',
      label: '廣播電台',
      icon: Icons.radio_outlined,
      activeIcon: Icons.radio_rounded,
    ),
  ];

  static const List<_NavItemSpec> _settingsSubTabs = [
    _NavItemSpec(
      tab: HomeTab.general,
      keyName: 'nav_tab_general',
      label: '通用',
      icon: Icons.tune_outlined,
      activeIcon: Icons.tune_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.appearance,
      keyName: 'nav_tab_appearance',
      label: '外觀與縮放',
      icon: Icons.aspect_ratio_outlined,
      activeIcon: Icons.aspect_ratio_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.librarySettings,
      keyName: 'nav_tab_library_settings',
      label: '音樂庫',
      icon: Icons.library_music_outlined,
      activeIcon: Icons.library_music_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.dsp,
      keyName: 'nav_tab_dsp',
      label: 'DSP 音訊引擎',
      icon: Icons.graphic_eq_rounded,
      activeIcon: Icons.graphic_eq_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.zones,
      keyName: 'nav_tab_zones',
      label: '輸出與音區',
      icon: Icons.speaker_group_outlined,
      activeIcon: Icons.speaker_group_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.settings,
      keyName: 'nav_tab_settings',
      label: '網路與串流來源',
      icon: Icons.dns_outlined,
      activeIcon: Icons.dns_rounded,
    ),
    _NavItemSpec(
      tab: HomeTab.about,
      keyName: 'nav_tab_about',
      label: '關於',
      icon: Icons.info_outline_rounded,
      activeIcon: Icons.info_rounded,
    ),
  ];

  late final NavHistoryController _navController;
  late final bool _ownsNavController;
  late final LibraryIndexCache _libraryCache;
  late final bool _ownsLibraryCache;

  HomeTab _lastSettingsTab = HomeTab.general;
  bool _sidebarCollapsed = false;
  bool _isNowPlayingExpanded = false;
  bool _hasEverExpandedNowPlaying = false;
  final TextEditingController _topSearchController = TextEditingController();
  final FocusNode _topSearchFocusNode = FocusNode();
  bool _topSearchExpanded = false;
  late final NowPlayingViewController _nowPlayingController;
  late final bool _ownsNowPlayingController;
  late final ArtworkPaletteService _paletteService;
  late final AnimationController _nowPlayingAnimController;
  late final Animation<double> _nowPlayingCurvedAnim;
  late final Animation<Offset> _nowPlayingSlideAnim;
  bool _isDetailScrolledPastHero = false;
  String? _activeDetailTitle;
  late final AnimationController _stickyTitleFadeController;
  late final Animation<double> _stickyTitleFadeAnimation;
  String? _selectedAlbumId;
  String? _selectedCreditArtistId;
  String? _selectedSmartPlaylistId;
  String? _selectedStreamingKind;
  String? _selectedPodcastShowId;
  PodcastShow? _selectedPodcastShow;
  List<ProviderStatusInfo> _loggedInStreamingProviders = const [];
  LoadedShaders _shaders = LoadedShaders.empty;
  ui.FragmentShader? _glassShader;
  late final UiScaleController _scaleController;
  late final bool _ownsScaleController;
  late final SmartPlaylistService _playlistService;
  late final LibrarySettingsController _librarySettingsController;
  late final AlbumLayoutSettingsController _albumLayoutController;
  late final PlaybackPersistenceService _playbackPersistenceService;
  late final bool _ownsPlaybackPersistenceService;
  late final PodcastStore _podcastStore;
  late final PodcastPlaybackTracker _podcastPlaybackTracker;
  late final StreamingManager _streamingManager;
  late final bool _ownsStreamingManager;
  late final StreamingPlaybackCoordinator _streamingCoordinator;
  late final CoordinatingAudioService _effectiveAudioService;
  late final UnifiedSearchController _searchController;
  StreamSubscription<PlaybackState>? _playbackStateSub;

  bool _isStartupRestoring = true;
  bool _isHiddenToTray = false;
  bool _isExiting = false;
  PlaybackStatus? _lastPersistedStatus;
  String? _lastPersistedTrackId;
  String? _lastTrayTrackKey;
  bool? _lastTrayPlaying;
  bool? _lastTrayIdle;

  HomeTab get _activeTab => _navController.current.tab;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      duration: const Duration(milliseconds: 300),
    );
    _nowPlayingCurvedAnim = CurvedAnimation(
      parent: _nowPlayingAnimController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _nowPlayingSlideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(_nowPlayingCurvedAnim);
    _nowPlayingAnimController.addStatusListener(_onNowPlayingAnimStatus);

    _ownsNavController = widget.navHistoryController == null;
    _navController = widget.navHistoryController ?? NavHistoryController();
    _navController.addListener(_onNavChanged);

    _ownsLibraryCache = widget.libraryCache == null;
    _libraryCache = widget.libraryCache ?? LibraryIndexCache();
    _libraryCache.seedFromQueueSync(widget.audioService.queue);
    _libraryCache.prime(widget.audioService);
    _libraryCache.addListener(_onLibraryCacheChanged);

    _ownsScaleController = widget.uiScaleController == null;
    _scaleController = widget.uiScaleController ?? UiScaleController();
    widget.audioService.setVisualizerSettingEnabled(false);
    _scaleController.addListener(_onScaleControllerVisualizerChanged);
    _playlistService = SmartPlaylistService()..load();
    _librarySettingsController = LibrarySettingsController()..load();
    _albumLayoutController = AlbumLayoutSettingsController()..load();
    _selectedSmartPlaylistId = _playlistService.playlists.firstOrNull?.id;
    _syncStateFromEntry(_navController.current);
    _initShaders();

    final isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');
    final ffiAudio = !isTestEnv && widget.audioService is FfiAudioService
        ? widget.audioService as FfiAudioService
        : null;
    _ownsStreamingManager = widget.streamingManager == null;
    _streamingManager = widget.streamingManager ??
        StreamingManager(
          credentialStore: isTestEnv ? MemorySecureCredentialStore() : null,
          l1CachePersistence: ffiAudio != null
              ? FfiL1StreamCachePersistence(
                  libraryProvider: () => ffiAudio.nativeLibrary,
                  waitDbReady: () => ffiAudio.dbReady,
                )
              : null,
          waitDbReady: ffiAudio != null ? () => ffiAudio.dbReady : null,
          sidecarLifecycleBinder: ffiAudio != null
              ? FfiSidecarLifecycleBinder(
                  libraryProvider: () => ffiAudio.nativeLibrary,
                )
              : null,
          onHttp2Warmup: ffiAudio?.triggerStreamingHttp2Warmup,
        );
    _streamingManager.addListener(_onStreamingManagerChanged);
    if (widget.audioService is FfiAudioService) {
      (widget.audioService as FfiAudioService).attachStreamingManager(
        _streamingManager,
      );
    }
    _syncStreamingProvidersFromManager(notify: false);
    _streamingCoordinator = StreamingPlaybackCoordinator(
      audioService: widget.audioService,
      streamingManager: _streamingManager,
      onNotice: _showStreamingNoticeSnackBar,
      onError: _showStreamingErrorSnackBar,
    );
    _effectiveAudioService = CoordinatingAudioService(
      inner: widget.audioService,
      coordinator: _streamingCoordinator,
      disposeInner: false,
    );
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

    _windowController.setPreventClose(true);
    _windowController.onWindowClose = _handleWindowClose;
    _windowController.onTrayClick = _handleRestoreFromTray;
    _windowController.onTrayMenuAction = _handleTrayMenuAction;
    _windowController.onSingleInstanceWakeup = _handleRestoreFromTray;
    _windowController.onWindowMinimize = _handleWindowMinimize;
    _windowController.onWindowRestore = _handleWindowRestoredOrFocused;
    _windowController.onWindowMaximize = _handleWindowRestoredOrFocused;
    _windowController.onWindowUnmaximize = _handleWindowRestoredOrFocused;
    _windowController.onWindowFocus = _handleWindowRestoredOrFocused;
    final initialTray = _trayInfoFor(_effectiveAudioService.currentState);
    _lastTrayTrackKey = _trayTrackKeyFor(_effectiveAudioService.currentState);
    _lastTrayPlaying = initialTray.isPlaying;
    _lastTrayIdle = _isTrayIdleState(_effectiveAudioService.currentState);
    _windowController.initTray(
      tooltip: initialTray.tooltip,
      nowPlayingLabel: initialTray.nowPlayingLabel,
      isPlaying: initialTray.isPlaying,
    );

    _playbackStateSub = _effectiveAudioService.stateStream.listen(_onPlaybackState);
    _topSearchFocusNode.addListener(_onTopSearchFocusChanged);
    EscapeDismissRegistry.instance.registerGlobalHost();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _initializeStartupSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isExiting) return;
      unawaited(_streamingManager.warmup());
    });
  }

  Future<void> _initializeStartupSession() async {
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
    setState(() {
      _loggedInStreamingProviders = streaming;
      if (_activeTab == HomeTab.streamingProvider &&
          !streaming.any((p) => p.kind == _selectedStreamingKind)) {
        _selectedStreamingKind = null;
        _navController.replaceCurrent(NavEntry.tab(HomeTab.settings));
      }
    });
  }

  bool _isTrayIdleState(PlaybackState state) =>
      state.track == null ||
      state.status == PlaybackStatus.stopped ||
      state.status == PlaybackStatus.uninitialized;

  String _trayTrackKeyFor(PlaybackState state) {
    final t = state.track;
    if (t == null) return 'none';
    return '${t.id}|${t.title}|${t.artist}';
  }

  ({String tooltip, String nowPlayingLabel, bool isPlaying}) _trayInfoFor(
    PlaybackState state,
  ) {
    final track = state.track;
    final isPlaying = state.status == PlaybackStatus.playing;
    if (_isTrayIdleState(state) || track == null) {
      return (
        tooltip: 'Lumina Audio — 待機中',
        nowPlayingLabel: 'Lumina Audio — 待機中',
        isPlaying: false,
      );
    }
    return (
      tooltip: 'Lumina Audio — ${track.title} - ${track.artist}',
      nowPlayingLabel: '正在播放：${track.title} - ${track.artist}',
      isPlaying: isPlaying,
    );
  }

  void _syncTrayFromState(PlaybackState state) {
    final trackKey = _trayTrackKeyFor(state);
    final isPlaying = state.status == PlaybackStatus.playing;
    final isIdle = _isTrayIdleState(state);
    if (trackKey == _lastTrayTrackKey &&
        isPlaying == _lastTrayPlaying &&
        isIdle == _lastTrayIdle) {
      return;
    }
    _lastTrayTrackKey = trackKey;
    _lastTrayPlaying = isPlaying;
    _lastTrayIdle = isIdle;
    final info = _trayInfoFor(state);
    unawaited(
      _windowController.updateTray(
        tooltip: info.tooltip,
        nowPlayingLabel: info.nowPlayingLabel,
        isPlaying: info.isPlaying,
      ),
    );
  }

  void _onPlaybackState(PlaybackState state) {
    _syncTrayFromState(state);
    if (_isStartupRestoring ||
        _playbackPersistenceService.isRestoring ||
        _isExiting) {
      return;
    }

    final isPlaying = state.status == PlaybackStatus.playing;
    final statusChanged = state.status != _lastPersistedStatus;
    final trackChanged = state.track?.id != _lastPersistedTrackId;
    _lastPersistedStatus = state.status;
    _lastPersistedTrackId = state.track?.id;

    if (isPlaying) {
      final snapshot = _playbackPersistenceService.buildSnapshot(
        state: state,
        queue: _effectiveAudioService.queue,
      );
      _playbackPersistenceService.saveThrottled(snapshot);
    } else if (statusChanged || trackChanged) {
      final snapshot = _playbackPersistenceService.buildSnapshot(
        state: state,
        queue: _effectiveAudioService.queue,
      );
      unawaited(_playbackPersistenceService.saveImmediate(snapshot));
    }
  }

  void _handleWindowClose() {
    if (_isExiting) return;
    if (_scaleController.minimizeToTrayOnClose) {
      final snap = _playbackPersistenceService.buildSnapshot(
        state: _effectiveAudioService.currentState,
        queue: _effectiveAudioService.queue,
      );
      unawaited(_playbackPersistenceService.saveImmediate(snap));
      if (mounted) {
        setState(() {
          _isHiddenToTray = true;
        });
      } else {
        _isHiddenToTray = true;
      }
      _effectiveAudioService.setWindowMinimized(true);
      unawaited(_windowController.hide());
      return;
    }
    unawaited(_performCleanExit());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _handleWindowRestoredOrFocused();
    }
  }

  void _handleWindowMinimize() {
    if (_isExiting) return;
    // Never disable root TickerMode on taskbar minimize; only minimize audio/visualizer work.
    _effectiveAudioService.setWindowMinimized(true);
  }

  void _handleWindowRestoredOrFocused() {
    if (_isExiting) return;
    final stateChanged =
        _isHiddenToTray ||
        _windowController.isHiddenToTrayNotifier.value ||
        _windowController.isMinimizedNotifier.value;

    _isHiddenToTray = false;
    _windowController.isHiddenToTrayNotifier.value = false;
    _windowController.isMinimizedNotifier.value = false;
    _effectiveAudioService.setWindowMinimized(false);

    if (!mounted) return;
    if (stateChanged) {
      setState(() {});
    }
    WidgetsBinding.instance.scheduleForcedFrame();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _handleRestoreFromTray() {
    if (_isExiting) return;
    _handleWindowRestoredOrFocused();
    unawaited(() async {
      await _windowController.show();
      await _windowController.focus();
      if (mounted) {
        setState(() {});
      }
    }());
  }

  void _handleTrayMenuAction(String action) {
    switch (action) {
      case 'show':
        _handleRestoreFromTray();
      case 'toggle_play_pause':
        unawaited(_effectiveAudioService.togglePlayPause());
      case 'previous':
        unawaited(_effectiveAudioService.previous());
      case 'next':
        unawaited(_effectiveAudioService.next());
      case 'quit':
        unawaited(_performCleanExit());
    }
  }

  Future<void> _performCleanExit() async {
    if (_isExiting) return;
    _isExiting = true;
    try {
      final baseState = _effectiveAudioService.currentState;
      var effectiveState = baseState;
      try {
        final liveMap = await _effectiveAudioService.getPlaybackState();
        if (liveMap != null) {
          final livePosMs = (liveMap['position_ms'] as num?)?.toInt();
          final liveVol = (liveMap['volume'] as num?)?.toDouble();
          final liveCode = (liveMap['state_code'] as num?)?.toInt();
          effectiveState = baseState.copyWith(
            position: livePosMs != null && livePosMs >= 0
                ? Duration(milliseconds: livePosMs)
                : baseState.position,
            volume: liveVol != null && liveVol.isFinite
                ? liveVol.clamp(0.0, 1.0)
                : baseState.volume,
            status: liveCode != null
                ? PlaybackStatus.fromCode(liveCode)
                : baseState.status,
          );
        }
      } catch (_) {
        effectiveState = _effectiveAudioService.currentState;
      }

      final snapshot = _playbackPersistenceService.buildSnapshot(
        state: effectiveState,
        queue: _effectiveAudioService.queue,
      );
      await _playbackPersistenceService.saveAndFlushForExit(snapshot);

      await _playbackStateSub?.cancel();
      _playbackStateSub = null;
      _streamingCoordinator.dispose();
      _effectiveAudioService.dispose();
      await _streamingCoordinator.ytDlpService.stopAll();
      if (widget.audioService is FfiAudioService) {
        (widget.audioService as FfiAudioService).detachStreamingManager();
      }
      _streamingManager.removeListener(_onStreamingManagerChanged);
      await _streamingManager.disposeAsync();
      widget.audioService.dispose();
      await _windowController.destroyTray();
      await _windowController.destroy();
    } catch (_) {
      try {
        await _windowController.destroyTray();
      } catch (_) {}
      try {
        await _windowController.destroy();
      } catch (_) {}
    }
  }

  Future<void> _openExternalUrl(String url) async {
    try {
      await openSystemBrowser(
        url,
        urlOpener: _windowController.isSupported ? _windowController.openUrl : null,
      );
    } catch (_) {}
  }

  String? _fallbackWebUrlForTrack(TrackInfo track) {
    final id = track.id;
    if (id.startsWith('apple:')) {
      return 'https://music.apple.com';
    }
    if (id.startsWith('tidal:')) {
      return 'https://listen.tidal.com/track/${id.substring(6)}';
    }
    if (id.startsWith('deezer:')) {
      return 'https://www.deezer.com/track/${id.substring(7)}';
    }
    if (id.startsWith('ytm:')) {
      return 'https://music.youtube.com/watch?v=${id.substring(4)}';
    }
    if (id.startsWith('qobuz:')) {
      return 'https://play.qobuz.com';
    }
    return null;
  }

  void _showStreamingNoticeSnackBar(
    TrackInfo track,
    ResolvedStreamResult result,
  ) {
    if (!mounted) return;
    final notice =
        result.drmNotice ?? '目前播放為官方試聽片段（${result.format.label}）';
    final webUrl = result.externalWebUrl;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(notice),
          action: webUrl != null && webUrl.isNotEmpty
              ? SnackBarAction(
                  label: '於瀏覽器開啟',
                  textColor: LuminaTokens.accentBlue,
                  onPressed: () => _openExternalUrl(webUrl),
                )
              : null,
        ),
      );
  }

  void _showStreamingErrorSnackBar(
    TrackInfo track,
    String message,
    bool isDrmRestricted,
  ) {
    if (!mounted) return;
    final provider = _streamingManager.resolveProviderForTrack(track);
    final isAuthRequired =
        (provider != null &&
            (_streamingManager.isAuthRequired(provider.kind) ||
                provider.authState == StreamingAuthState.authRequired)) ||
        RegExp(
          r'\bAUTH_REQUIRED\b|HTTP\s*401\b|\b401\s+Unauthorized\b|重新登入|授權已失效',
          caseSensitive: false,
        ).hasMatch(message);
    final webUrl = isDrmRestricted ? _fallbackWebUrlForTrack(track) : null;
    final SnackBarAction? action;
    if (isAuthRequired && provider != null) {
      action = SnackBarAction(
        key: Key('snackbar_action_relogin_${provider.kind}'),
        label: '重新登入',
        textColor: LuminaTokens.accentBlue,
        onPressed: () {
          if (!mounted) return;
          unawaited(
            StreamingLoginDialog.show(context, provider, _streamingManager),
          );
        },
      );
    } else if (webUrl != null) {
      action = SnackBarAction(
        label: '於瀏覽器開啟',
        textColor: LuminaTokens.accentBlue,
        onPressed: () => _openExternalUrl(webUrl),
      );
    } else {
      action = null;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: LuminaTokens.statusErrorBg,
          content: Text(
            message,
            style: const TextStyle(color: Color(0xFFFECACA)),
          ),
          action: action,
        ),
      );
  }

  Future<void> _playStreamingTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) async {
    await _streamingCoordinator.playTrack(track, queueContext: queueContext);
  }

  void _onScaleControllerVisualizerChanged() {
    widget.audioService.setVisualizerSettingEnabled(false);
  }

  void _onNavChanged() {
    if (!mounted) return;
    setState(() {
      _syncStateFromEntry(_navController.current);
    });
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final isDetail =
        _activeTab == HomeTab.albumDetail || _activeTab == HomeTab.artistDetail;
    if (isDetail) {
      setState(() {});
    }
  }

  void _onDetailTitleChanged(String title) {
    if (_activeDetailTitle == title) return;
    _activeDetailTitle = title;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _handleScrollOffsetChanged(String entryId, double offset) {
    _navController.saveScrollOffset(entryId, offset);
    final isDetailTab =
        _activeTab == HomeTab.albumDetail ||
        _activeTab == HomeTab.artistDetail ||
        _activeTab == HomeTab.podcastDetail;
    if (isDetailTab) {
      final pastHero = offset > 200;
      if (pastHero != _isDetailScrolledPastHero) {
        setState(() {
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
      final cachedDetail = _libraryCache.getAlbumDetailSync(albumId) ??
          _libraryCache.albumDetailsById[albumId];
      if (cachedDetail != null && cachedDetail.title.isNotEmpty) {
        return cachedDetail.title;
      }
      final cachedSummary = _libraryCache.getAlbumSummarySync(albumId) ??
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
    setState(() {
      _shaders = loaded;
      _glassShader = loaded.liquidGlassProgram?.fragmentShader();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    EscapeDismissRegistry.instance.unregisterGlobalHost();
    _topSearchFocusNode.removeListener(_onTopSearchFocusChanged);
    _topSearchFocusNode.dispose();
    _topSearchController.dispose();
    _searchController.dispose();
    if (_windowController.onWindowClose == _handleWindowClose) {
      _windowController.onWindowClose = null;
    }
    if (_windowController.onTrayClick == _handleRestoreFromTray) {
      _windowController.onTrayClick = null;
    }
    if (_windowController.onTrayMenuAction == _handleTrayMenuAction) {
      _windowController.onTrayMenuAction = null;
    }
    if (_windowController.onSingleInstanceWakeup == _handleRestoreFromTray) {
      _windowController.onSingleInstanceWakeup = null;
    }
    if (_windowController.onWindowMinimize == _handleWindowMinimize) {
      _windowController.onWindowMinimize = null;
    }
    if (_windowController.onWindowRestore == _handleWindowRestoredOrFocused) {
      _windowController.onWindowRestore = null;
    }
    if (_windowController.onWindowMaximize == _handleWindowRestoredOrFocused) {
      _windowController.onWindowMaximize = null;
    }
    if (_windowController.onWindowUnmaximize == _handleWindowRestoredOrFocused) {
      _windowController.onWindowUnmaximize = null;
    }
    if (_windowController.onWindowFocus == _handleWindowRestoredOrFocused) {
      _windowController.onWindowFocus = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _streamingCoordinator.dispose();
    _effectiveAudioService.dispose();
    if (widget.audioService is FfiAudioService) {
      (widget.audioService as FfiAudioService).detachStreamingManager();
    }
    _streamingManager.removeListener(_onStreamingManagerChanged);
    if (_ownsStreamingManager) {
      _streamingManager.dispose();
    }
    _nowPlayingAnimController.removeStatusListener(_onNowPlayingAnimStatus);
    _nowPlayingAnimController.dispose();
    if (_ownsNowPlayingController) {
      _nowPlayingController.dispose();
    }
    _stickyTitleFadeController.dispose();
    _libraryCache.removeListener(_onLibraryCacheChanged);
    _navController.removeListener(_onNavChanged);
    if (_ownsNavController) {
      _navController.dispose();
    }
    if (_ownsLibraryCache) {
      _libraryCache.dispose();
    }
    _scaleController.removeListener(_onScaleControllerVisualizerChanged);
    if (_ownsScaleController) {
      _scaleController.dispose();
    }
    _playlistService.dispose();
    _librarySettingsController.dispose();
    _albumLayoutController.dispose();
    _podcastPlaybackTracker.dispose();
    _playbackStateSub?.cancel();
    _playbackStateSub = null;
    if (!_isExiting) {
      unawaited(_playbackPersistenceService.flush(syncFlush: true));
    }
    if (_ownsPlaybackPersistenceService) {
      _playbackPersistenceService.dispose();
    }
    _glassShader?.dispose();
    _shaders.backdropImage?.dispose();
    super.dispose();
  }

  bool _isSettingsTab(HomeTab tab) => tab.isSettings;

  void _onNowPlayingAnimStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.completed) {
      setState(() {});
    }
  }

  void _setNowPlayingExpanded(bool expanded) {
    if (_isNowPlayingExpanded == expanded) return;
    setState(() {
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
    setState(() {
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
      _ => NavEntry.tab(next),
    };
    _pushEntry(entry);
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
      libraryTracks: widget.audioService.queue,
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
    _setNowPlayingExpanded(!_isNowPlayingExpanded);
  }

  bool _isTextEditingFocused() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final context = focus.context;
    if (context == null || !context.mounted) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _onTopSearchFocusChanged() {
    if (!mounted) return;
    if (!_topSearchFocusNode.hasFocus &&
        _topSearchExpanded &&
        _topSearchController.text.trim().isEmpty) {
      setState(() {
        _topSearchExpanded = false;
      });
    } else if (_topSearchExpanded) {
      setState(() {});
    }
  }

  void _expandTopSearch() {
    if (_isNowPlayingExpanded) {
      _setNowPlayingExpanded(false);
    }
    if (!_topSearchExpanded) {
      setState(() {
        _topSearchExpanded = true;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_topSearchExpanded) return;
      _topSearchFocusNode.requestFocus();
    });
  }

  void _onTopSearchChanged(String value) {
    final trimmed = value.trim();
    _searchController.updateQuery(value);
    if (trimmed.isNotEmpty && _activeTab != HomeTab.search) {
      _pushEntry(NavEntry.tab(HomeTab.search));
    }
  }

  void _onTopSearchSubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      _searchController.clear();
      return;
    }
    _searchController.updateQuery(value, immediate: true);
    if (_activeTab != HomeTab.search) {
      _pushEntry(NavEntry.tab(HomeTab.search));
    }
  }

  void _handleTopSearchClearPressed() {
    if (_topSearchController.text.isNotEmpty) {
      _topSearchController.clear();
      _searchController.clear();
      if (_activeTab == HomeTab.search && _navController.canGoBack) {
        _goBack();
      }
      _topSearchFocusNode.requestFocus();
      setState(() {});
    } else {
      _searchController.clear();
      if (_activeTab == HomeTab.search && _navController.canGoBack) {
        _goBack();
      }
      _topSearchFocusNode.unfocus();
      setState(() {
        _topSearchExpanded = false;
      });
    }
  }

  KeyEventResult _handleGlobalKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    final ctrl = keyboard.isControlPressed;
    final meta = keyboard.isMetaPressed;
    final alt = keyboard.isAltPressed;
    final shift = keyboard.isShiftPressed;

    if ((ctrl || meta) && !alt && event.logicalKey == LogicalKeyboardKey.keyF) {
      _expandTopSearch();
      return KeyEventResult.handled;
    }

    // Critical guard: pass all editing keys (Backspace, Delete, Space, M,
    // arrows, Ctrl+A/C/V/X/Z, IME composition) to EditableText untouched.
    if (_isTextEditingFocused()) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.space && !ctrl && !alt && !meta) {
      _effectiveAudioService.togglePlayPause();
      return KeyEventResult.handled;
    }

    if (alt && !ctrl && !meta && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _goBack();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        !ctrl &&
        !alt &&
        !meta &&
        !shift) {
      _goBack();
      return KeyEventResult.handled;
    }

    if (alt && !ctrl && !meta && event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _goForward();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyM && !ctrl && !alt && !meta) {
      _effectiveAudioService.toggleMute();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    if (event is KeyRepeatEvent) {
      return event.logicalKey == LogicalKeyboardKey.escape;
    }
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.f11) {
      unawaited(_windowController.toggleFullScreen());
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return _handleEscape();
    }
    return false;
  }

  bool _handleEscape() {
    // 1. Active text input focus -> unfocus only (collapse empty top search).
    if (_isTextEditingFocused()) {
      FocusManager.instance.primaryFocus?.unfocus();
      if (_topSearchExpanded && _topSearchController.text.trim().isEmpty) {
        setState(() {
          _topSearchExpanded = false;
        });
      }
      return true;
    }

    // 2. Floating layers (non-Navigator popovers -> root Navigator dialogs ->
    //    Now Playing lyrics settings toolbar -> expanded top search box).
    if (EscapeDismissRegistry.instance.dismissTopmost()) {
      return true;
    }
    final rootNav = Navigator.maybeOf(context, rootNavigator: true);
    if (rootNav != null && rootNav.canPop()) {
      unawaited(rootNav.maybePop());
      return true;
    }
    if (_isNowPlayingExpanded && _nowPlayingController.lyricsSettingsExpanded) {
      _nowPlayingController.setLyricsSettingsExpanded(false);
      return true;
    }
    final isDetailRoute =
        _activeTab == HomeTab.albumDetail ||
        _activeTab == HomeTab.artistDetail ||
        _activeTab == HomeTab.podcastDetail;
    if (_topSearchExpanded && !_isNowPlayingExpanded && !isDetailRoute) {
      setState(() {
        _topSearchExpanded = false;
      });
      return true;
    }

    // 3. Exit fullscreen mode.
    if (_windowController.isFullScreenNotifier.value) {
      unawaited(_windowController.setFullScreen(false));
      return true;
    }

    // 4. Collapse Now Playing overlay.
    if (_isNowPlayingExpanded) {
      _setNowPlayingExpanded(false);
      return true;
    }

    // 5. Step back in workspace navigation history.
    if (_navController.canGoBack) {
      _goBack();
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    return TrackPrefetchScope(
      onPrefetchTrack: _streamingCoordinator.requestHoverPrefetch,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleGlobalKeyEvent,
        child: FocusScope(
          child: Scaffold(
            backgroundColor: _canvasBg,
            body: TickerMode(
              enabled: !_isHiddenToTray,
              child: SafeArea(
                child: LayoutBuilder(
                builder: (context, constraints) {
                  final availWidth = constraints.maxWidth;
                  final isDesktop =
                      LuminaResponsive.showDesktopSidebar(availWidth);
                  final sidebarWidth =
                      LuminaResponsive.sidebarWidth(availWidth);
                  final miniPlayerClearance = availWidth >= 740
                      ? 99.0
                      : (availWidth >= 480 ? 116.0 : 138.0);
                  final showOverlay = _hasEverExpandedNowPlaying &&
                      (_isNowPlayingExpanded ||
                          !_nowPlayingAnimController.isDismissed);
                  final isNowPlayingFullyCovered = _isNowPlayingExpanded &&
                      _nowPlayingAnimController.isCompleted &&
                      !_isHiddenToTray;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      // Layer 0: Persistent Workspace (never torn down on Now Playing open/close)
                      Positioned.fill(
                        key: const ValueKey('home_workspace_layer'),
                        child: RepaintBoundary(
                          key: const Key('workspace_repaint_boundary'),
                          child: TickerMode(
                            enabled:
                                !_isHiddenToTray && !isNowPlayingFullyCovered,
                            child: Visibility(
                              visible: !isNowPlayingFullyCovered,
                              maintainState: true,
                              maintainAnimation: true,
                              maintainSize: true,
                              child: IgnorePointer(
                                ignoring: _isNowPlayingExpanded,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom: miniPlayerClearance,
                                  ),
                                  child: Column(
                                    children: [
                                      _buildTopBar(
                                        isDesktop: isDesktop,
                                        availWidth: availWidth,
                                        sidebarWidth: sidebarWidth,
                                      ),
                                      Expanded(
                                        child: KeyedSubtree(
                                          key: const ValueKey('workspace_stage'),
                                          child: isDesktop
                                              ? Row(
                                                  children: [
                                                    ClipRect(
                                                      child: AnimatedAlign(
                                                        duration: const Duration(
                                                          milliseconds: 220,
                                                        ),
                                                        curve: Curves.easeOutCubic,
                                                        alignment:
                                                            Alignment.centerRight,
                                                        widthFactor:
                                                            _sidebarCollapsed
                                                                ? 0.0
                                                                : 1.0,
                                                        child: _buildSidebar(
                                                          width: sidebarWidth,
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: _buildMainColumn(
                                                        isDesktop: true,
                                                        availWidth: availWidth -
                                                            (_sidebarCollapsed
                                                                ? 0.0
                                                                : sidebarWidth),
                                                      ),
                                                    ),
                                                  ],
                                                )
                                              : _buildMainColumn(
                                                  isDesktop: false,
                                                  availWidth: availWidth,
                                                ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Layer 1: Fullscreen NowPlayingOverlay (spans 100% height from top: 0 to bottom: 0)
                      if (showOverlay)
                        Positioned.fill(
                          key: const ValueKey('home_now_playing_layer'),
                          child: RepaintBoundary(
                            key: const Key(
                              'now_playing_overlay_repaint_boundary',
                            ),
                            child: SlideTransition(
                              position: _nowPlayingSlideAnim,
                              child: FadeTransition(
                                opacity: _nowPlayingCurvedAnim,
                                child: NowPlayingOverlay(
                                  key: const ValueKey('now_playing_stage'),
                                  audioService: _effectiveAudioService,
                                  libraryCache: _libraryCache,
                                  controller: _nowPlayingController,
                                  windowController: _windowController,
                                  paletteService: _paletteService,
                                  meshFluidProgram: _shaders.meshFluidProgram,
                                  isVisible:
                                      _isNowPlayingExpanded && !_isHiddenToTray,
                                  isTransitionSettled:
                                      isNowPlayingFullyCovered,
                                  bottomClearance: miniPlayerClearance,
                                  onCollapse: () =>
                                      _setNowPlayingExpanded(false),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Layer 2: Single persistent floating capsule mini player pinned at bottom edge
                      Positioned(
                        key: const ValueKey('home_mini_player_layer'),
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: RepaintBoundary(
                          key: const Key('mini_player_repaint_boundary'),
                          child: FloatingCapsuleMiniPlayer(
                            audioService: _effectiveAudioService,
                            libraryCache: _libraryCache,
                            uiScaleController: _scaleController,
                            showLyrics: _isNowPlayingExpanded,
                            isNowPlayingExpanded: _isNowPlayingExpanded,
                            glassShader: _glassShader,
                            backdropImage: _shaders.backdropImage,
                            onToggleLyrics: _toggleNowPlaying,
                            onToggleNowPlaying: _toggleNowPlaying,
                            onOpenZones: () => _selectTab(HomeTab.zones),
                            onOpenLibrary: () => _selectTab(HomeTab.library),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildSidebar({required double width}) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: _sidebarBg,
        border: Border(right: BorderSide(color: _dividerColor, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: ListenableBuilder(
              listenable: _playlistService,
              builder: (context, _) {
                final smartPlaylists = _playlistService.playlists;
                return SingleChildScrollView(
                  padding: const EdgeInsets.only(
                    bottom: LuminaTokens.bottomScrollClearance,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSidebarSectionLabel('瀏覽'),
                      for (final item in _browseNavItems)
                        _buildSidebarTile(item),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      _buildSidebarSectionLabel('我的音樂資料庫'),
                      for (final item in _libraryNavItems)
                        _buildSidebarTile(item),
                      const SizedBox(height: LuminaTokens.spaceSm),
                      _buildSidebarSectionLabel('媒體'),
                      for (final item in _mediaNavItems)
                        _buildSidebarTile(item),
                      if (_loggedInStreamingProviders.isNotEmpty) ...[
                        const SizedBox(height: LuminaTokens.spaceSm),
                        _buildSidebarSectionLabel('串流服務'),
                        for (final p in _loggedInStreamingProviders)
                          if (StreamingProviderMeta.byKind(p.kind)
                              case final meta?)
                            _buildStreamingSidebarTile(meta),
                      ],
                      const SizedBox(height: LuminaTokens.spaceMd),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 10, 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              '智慧播放清單',
                              style: TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                              ),
                            ),
                            IconButton(
                              key: const Key('btn_sidebar_new_smart_playlist'),
                              tooltip: '新增智慧歌單',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                              icon: const Icon(
                                Icons.add_rounded,
                                size: 16,
                                color: LuminaTokens.textSecondary,
                              ),
                              onPressed: _promptCreateSmartPlaylist,
                            ),
                          ],
                        ),
                      ),
                      for (final sp in smartPlaylists)
                        InkWell(
                          hoverColor: LuminaTokens.cardHoverBg.withValues(
                            alpha: 0.7,
                          ),
                          onTap: () => _openSmartPlaylist(sp.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 13,
                                  color: (_activeTab ==
                                              HomeTab.smartPlaylists &&
                                          _selectedSmartPlaylistId == sp.id)
                                      ? _accentBlue
                                      : LuminaTokens.textMuted,
                                ),
                                const SizedBox(width: LuminaTokens.spaceXs),
                                Expanded(
                                  child: Text(
                                    sp.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: (_activeTab ==
                                                  HomeTab.smartPlaylists &&
                                              _selectedSmartPlaylistId == sp.id)
                                          ? _accentBlue
                                          : LuminaTokens.textSecondary,
                                      fontSize: 12,
                                      fontWeight: (_activeTab ==
                                                  HomeTab.smartPlaylists &&
                                              _selectedSmartPlaylistId == sp.id)
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarSectionLabel(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: LuminaTokens.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _buildStreamingSidebarTile(StreamingProviderMeta meta) {
    final isSelected =
        _activeTab == HomeTab.streamingProvider &&
        _selectedStreamingKind == meta.kind;
    final provider = _streamingManager.providerFor(meta.kind);
    final isAuthRequired =
        _streamingManager.isAuthRequired(meta.kind) ||
        provider?.authState == StreamingAuthState.authRequired;
    final isConnected =
        !isAuthRequired && provider?.authState == StreamingAuthState.connected;
    final statusDotColor = isAuthRequired
        ? LuminaTokens.statusError
        : (isConnected
              ? LuminaTokens.statusSuccess
              : LuminaTokens.accentBlue.withValues(alpha: 0.75));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: isSelected
            ? _accentBlue.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: Key('nav_streaming_${meta.kind}'),
          borderRadius: BorderRadius.circular(6),
          hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.7),
          onTap: () => _openStreamingProvider(meta.kind),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                meta.buildBadge(boxSize: 20, borderRadius: 5),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    meta.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected
                          ? _accentBlue
                          : LuminaTokens.textPrimary,
                      fontSize: 13,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                Tooltip(
                  message: isAuthRequired
                      ? '授權已失效，請重新登入'
                      : (isConnected ? '已連線' : '探索模式'),
                  child: Container(
                    key: Key('nav_streaming_status_dot_${meta.kind}'),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: statusDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarTile(_NavItemSpec item) {
    final isSelected = _activeTab == item.tab ||
        (item.tab == HomeTab.podcasts && _activeTab == HomeTab.podcastDetail);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: isSelected
            ? _accentBlue.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: Key(item.keyName),
          borderRadius: BorderRadius.circular(6),
          hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.7),
          onTap: () => _selectTab(item.tab),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  isSelected ? item.activeIcon : item.icon,
                  size: 17,
                  color: isSelected ? _accentBlue : LuminaTokens.textSecondary,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected
                          ? _accentBlue
                          : LuminaTokens.textPrimary,
                      fontSize: 13,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainColumn({required bool isDesktop, required double availWidth}) {
    final currentEntry = _navController.current;
    return Column(
      children: [
        if (!isDesktop) _buildCompactNavStrip(),
        Expanded(
          child: AnimatedSwitcher(
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
              key: ValueKey('stage_${currentEntry.effectiveId}'),
              child: _buildActiveContent(
                isDesktop: isDesktop,
                availWidth: availWidth,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQuickScaleMenu() {
    return ListenableBuilder(
      listenable: _scaleController,
      builder: (context, _) {
        return PopupMenuButton<double>(
          key: const Key('btn_quick_scale_menu'),
          tooltip: '快速調整介面縮放（Ctrl + +/- / 0）',
          color: _sidebarBg,
          onSelected: (val) {
            if (val < 0) {
              _selectTab(HomeTab.appearance);
            } else {
              _scaleController.setScale(val);
            }
          },
          itemBuilder: (context) => [
            for (final preset in UiScaleController.presets)
              PopupMenuItem<double>(
                value: preset,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (_scaleController.scale - preset).abs() < 0.02
                          ? Icons.check_rounded
                          : Icons.crop_free_rounded,
                      size: 16,
                      color: (_scaleController.scale - preset).abs() < 0.02
                          ? _accentBlue
                          : LuminaTokens.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      preset == 1.0
                          ? '100% (預設)'
                          : '${(preset * 100).round()}%',
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem<double>(
              value: -1.0,
              child: Text(
                '開啟外觀與縮放微調面板...',
                style: TextStyle(color: _accentBlue, fontSize: 12.5),
              ),
            ),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: LuminaTokens.cardElevatedBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
              border: Border.all(color: LuminaTokens.borderControl),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.aspect_ratio_rounded,
                  size: 14,
                  color: LuminaTokens.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_scaleController.percentage}%',
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar({
    required bool isDesktop,
    required double availWidth,
    required double sidebarWidth,
  }) {
    final canGoBack = _navController.canGoBack;
    final canGoForward = _navController.canGoForward;
    final inSettings = _isSettingsTab(_activeTab);
    final contentAvailWidth =
        availWidth - (isDesktop && !_sidebarCollapsed ? sidebarWidth : 0.0);
    final isCompactTopBar = contentAvailWidth < 480;
    final isCompactProfile = contentAvailWidth < (isDesktop ? 720 : 520);

    return WindowDragBar(
      controller: _windowController,
      height: 48.0,
      border: inSettings
          ? const Border(
              bottom: BorderSide(color: _dividerColor, width: 1),
            )
          : null,
      child: Row(
        children: [
          if (isDesktop)
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: _sidebarCollapsed ? 0.0 : sidebarWidth,
                decoration: BoxDecoration(
                  color: _sidebarBg,
                  border: _sidebarCollapsed
                      ? null
                      : const Border(
                          right: BorderSide(color: _dividerColor, width: 1),
                        ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.centerLeft,
                child: _sidebarCollapsed
                    ? null
                    : const Text(
                        'Lumina Audio',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
              ),
            ),
          if (isDesktop) const SizedBox(width: 8),
          if (isDesktop)
            IconButton(
              tooltip: _sidebarCollapsed ? '展開側欄' : '收合側欄',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              icon: Icon(
                _sidebarCollapsed
                    ? Icons.menu_rounded
                    : Icons.menu_open_rounded,
                size: 19,
                color: LuminaTokens.textSecondary,
              ),
              onPressed: () {
                setState(() => _sidebarCollapsed = !_sidebarCollapsed);
              },
            ),
          IconButton(
            key: const Key('btn_nav_back'),
            tooltip: '返回上一頁',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            disabledColor: LuminaTokens.textDisabled,
            icon: Icon(
              Icons.chevron_left_rounded,
              size: 22,
              color: canGoBack
                  ? LuminaTokens.textPrimary
                  : LuminaTokens.textDisabled,
            ),
            onPressed: canGoBack ? _goBack : null,
          ),
          IconButton(
            key: const Key('btn_nav_forward'),
            tooltip: '下一頁',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            disabledColor: LuminaTokens.textDisabled,
            icon: Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: canGoForward
                  ? LuminaTokens.textPrimary
                  : LuminaTokens.textDisabled,
            ),
            onPressed: canGoForward ? _goForward : null,
          ),
          _buildTopBarTitle(
            isDesktop: isDesktop,
            isCompactTopBar: isCompactTopBar,
          ),
          if (isDesktop && contentAvailWidth >= 760) ...[
            _buildQuickScaleMenu(),
            const SizedBox(width: 6),
            IconButton(
              tooltip: '專輯典藏',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.bookmark_border_rounded,
                size: 19,
                color: _activeTab == HomeTab.albums
                    ? _accentBlue
                    : LuminaTokens.textSecondary,
              ),
              onPressed: () => _selectTab(HomeTab.albums),
            ),
            const SizedBox(width: 4),
          ],
          _buildCollapsibleTopSearch(
            contentAvailWidth,
            isDesktop: isDesktop,
            isCompactTopBar: isCompactTopBar,
            isCompactProfile: isCompactProfile,
          ),
          const SizedBox(width: 2),
          Container(
            decoration: BoxDecoration(
              color: inSettings
                  ? _accentBlue.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              border: Border.all(
                color: inSettings
                    ? _accentBlue.withValues(alpha: 0.7)
                    : Colors.transparent,
              ),
            ),
            child: IconButton(
              key: const Key('btn_open_settings_hub'),
              tooltip: '細項設定（通用 / 外觀 / 音樂庫 / DSP / 音區 / 串流與遠端）',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              icon: Icon(
                inSettings ? Icons.settings_rounded : Icons.settings_outlined,
                size: 19,
                color: inSettings ? _accentBlue : LuminaTokens.textSecondary,
              ),
              onPressed: () => _selectTab(_lastSettingsTab),
            ),
          ),
          if (contentAvailWidth >= 380) ...[
            SizedBox(width: isCompactTopBar ? 2 : 6),
            ProfileSwitcherBar(
              audioService: _effectiveAudioService,
              compact: isCompactProfile,
            ),
          ],
          if (isDesktop) ...[
            const SizedBox(width: 8),
            DesktopWindowCaptionButtons(
              height: 48.0,
              controller: _windowController,
              audioService: _effectiveAudioService,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCollapsibleTopSearch(
    double contentAvailWidth, {
    required bool isDesktop,
    required bool isCompactTopBar,
    required bool isCompactProfile,
  }) {
    final showDesktopQuickActions = isDesktop && contentAvailWidth >= 760;
    final showProfile = contentAvailWidth >= 380;
    final reservedWidth =
        (isDesktop ? 48.0 : 0.0) + // sidebar toggle + spacing
        80.0 + // back + forward buttons
        (isDesktop ? 56.0 : 28.0) + // minimum drag bar / title breathing room
        (showDesktopQuickActions ? 126.0 : 0.0) + // scale menu + bookmark
        44.0 + // settings button + spacing
        (showProfile
            ? ((isCompactTopBar ? 2.0 : 6.0) + (isCompactProfile ? 34.0 : 138.0))
            : 0.0) +
        (isDesktop ? 184.0 : 0.0); // desktop window caption buttons + spacing

    final maxSafeWidth = math.max(34.0, contentAvailWidth - reservedWidth);
    final targetExpandedWidth = (contentAvailWidth * 0.32).clamp(150.0, 250.0);
    final expandedWidth = math.min(targetExpandedWidth, maxSafeWidth);
    final boxWidth = _topSearchExpanded ? expandedWidth : 34.0;
    final layoutWidth = math.max(96.0, expandedWidth);
    final hasFocus = _topSearchFocusNode.hasFocus;

    return TapRegion(
      groupId: EditableText,
      onTapOutside: (_) {
        if (!_topSearchExpanded) return;
        _topSearchFocusNode.unfocus();
        if (_topSearchController.text.trim().isEmpty) {
          setState(() {
            _topSearchExpanded = false;
          });
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: boxWidth,
        height: 32.0,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _topSearchExpanded
              ? LuminaTokens.cardElevatedBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: _topSearchExpanded
              ? Border.all(
                  color: hasFocus
                      ? LuminaTokens.focusRing
                      : LuminaTokens.borderControl,
                  width: hasFocus ? 1.4 : 1.0,
                )
              : null,
        ),
        child: _topSearchExpanded
            ? OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: layoutWidth,
                maxWidth: layoutWidth,
                child: Row(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _topSearchFocusNode.requestFocus(),
                      child: const Padding(
                        padding: EdgeInsets.only(left: 10, right: 6),
                        child: Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: LuminaTokens.textSecondary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        key: const Key('top_search_input'),
                        controller: _topSearchController,
                        focusNode: _topSearchFocusNode,
                        onChanged: _onTopSearchChanged,
                        onSubmitted: _onTopSearchSubmitted,
                        maxLines: 1,
                        textAlignVertical: TextAlignVertical.center,
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 13,
                          height: 1.2,
                        ),
                        cursorColor: LuminaTokens.accentBlue,
                        decoration: const InputDecoration(
                          isDense: true,
                          isCollapsed: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          hintText: '搜尋曲庫與串流...',
                          hintStyle: TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 12.5,
                          ),
                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('btn_top_search_clear'),
                      tooltip: '清除或收合搜尋',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: LuminaTokens.textSecondary,
                      ),
                      onPressed: _handleTopSearchClearPressed,
                    ),
                    const SizedBox(width: 2),
                  ],
                ),
              )
            : Center(
                child: IconButton(
                  key: const Key('btn_top_search_toggle'),
                  tooltip: '搜尋曲庫與串流 (Ctrl+F)',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(
                    Icons.search_rounded,
                    size: 19,
                    color: LuminaTokens.textSecondary,
                  ),
                  onPressed: _expandTopSearch,
                ),
              ),
      ),
    );
  }

  Widget _buildTopBarTitle({
    required bool isDesktop,
    required bool isCompactTopBar,
  }) {
    final showDefaultTitle = !isDesktop || _sidebarCollapsed;
    final isDetailTab =
        _activeTab == HomeTab.albumDetail ||
        _activeTab == HomeTab.artistDetail ||
        _activeTab == HomeTab.podcastDetail;
    final stickyTitle = isDetailTab ? _resolveStickyTitle() : '';

    return Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isCompactTopBar ? 4 : 8),
        child: AnimatedBuilder(
          animation: _stickyTitleFadeAnimation,
          builder: (context, _) {
            final t = _stickyTitleFadeAnimation.value;
            return Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (showDefaultTitle)
                  Opacity(
                    opacity: (1.0 - t).clamp(0.0, 1.0),
                    child: const IgnorePointer(
                      child: Text(
                        'Lumina Audio',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (isDetailTab && stickyTitle.isNotEmpty)
                  FadeTransition(
                    opacity: _stickyTitleFadeAnimation,
                    child: IgnorePointer(
                      ignoring: t < 0.05,
                      child: Text(
                        stickyTitle,
                        key: const Key('top_bar_sticky_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCompactNavStrip() {
    final foregroundTabs = [
      ..._browseNavItems,
      ..._libraryNavItems,
      ..._mediaNavItems,
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          for (final item in foregroundTabs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: Key(item.keyName),
                selected: _activeTab == item.tab,
                onSelected: (_) => _selectTab(item.tab),
                backgroundColor: _sidebarBg,
                selectedColor: _accentBlue.withValues(alpha: 0.2),
                side: BorderSide(
                  color: _activeTab == item.tab
                      ? _accentBlue
                      : LuminaTokens.borderControl,
                ),
                label: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: _activeTab == item.tab
                        ? _accentBlue
                        : LuminaTokens.textSecondary,
                    fontWeight: _activeTab == item.tab
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
            ),
          for (final p in _loggedInStreamingProviders)
            if (StreamingProviderMeta.byKind(p.kind) case final meta?)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('nav_streaming_${meta.kind}'),
                  selected:
                      _activeTab == HomeTab.streamingProvider &&
                      _selectedStreamingKind == meta.kind,
                  onSelected: (_) => _openStreamingProvider(meta.kind),
                  backgroundColor: _sidebarBg,
                  selectedColor: _accentBlue.withValues(alpha: 0.2),
                  side: BorderSide(
                    color: (_activeTab == HomeTab.streamingProvider &&
                            _selectedStreamingKind == meta.kind)
                        ? _accentBlue
                        : LuminaTokens.borderControl,
                  ),
                  label: Text(
                    meta.name,
                    style: TextStyle(
                      fontSize: 12,
                      color: (_activeTab == HomeTab.streamingProvider &&
                              _selectedStreamingKind == meta.kind)
                          ? _accentBlue
                          : LuminaTokens.textSecondary,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildSettingsWorkspace({
    required bool isDesktop,
    required double availWidth,
  }) {
    final activeSpec = _settingsSubTabs.firstWhere(
      (s) => s.tab == _activeTab,
      orElse: () => _settingsSubTabs.first,
    );
    final railWidth = LuminaResponsive.settingsRailWidth(availWidth);
    final contentHorizontalPad =
        LuminaResponsive.settingsContentHorizontalPadding(availWidth);

    final detailBody = switch (_activeTab) {
      HomeTab.general => GeneralSettingsPanel(
        audioService: _effectiveAudioService,
        scaleController: _scaleController,
      ),
      HomeTab.appearance => AppearanceAndScalePanel(
        scaleController: _scaleController,
      ),
      HomeTab.librarySettings => LibrarySettingsPanel(
        audioService: _effectiveAudioService,
        settingsController: _librarySettingsController,
        onLibraryChanged: () {
          _libraryCache.refresh(_effectiveAudioService);
          setState(() {});
        },
      ),
      HomeTab.dsp => DspControlPanel(audioService: _effectiveAudioService),
      HomeTab.zones => OutputZonePanel(audioService: _effectiveAudioService),
      HomeTab.settings => ProvidersAndRemotePanel(
        audioService: _effectiveAudioService,
        streamingManager: _streamingManager,
        onProvidersChanged: _refreshProviders,
      ),
      HomeTab.about => AboutSettingsPanel(audioService: _effectiveAudioService),
      _ => const SizedBox.shrink(),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final useSideRail = isDesktop && constraints.maxWidth >= 680;
        if (useSideRail) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: railWidth,
                decoration: const BoxDecoration(
                  color: _settingsRailBg,
                  border: Border(
                    right: BorderSide(color: _dividerColor, width: 1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 18, 16, 12),
                      child: Text(
                        '設定',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.only(
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                        children: [
                          for (final spec in _settingsSubTabs)
                            _buildSettingsRailItem(spec),
                        ],
                      ),
                    ),
                    const Divider(color: _dividerColor, height: 1),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.translate_rounded,
                            size: 15,
                            color: LuminaTokens.textMuted,
                          ),
                          SizedBox(width: 8),
                          Text(
                            '繁體中文',
                            style: TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    contentHorizontalPad,
                    22,
                    contentHorizontalPad,
                    12,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activeSpec.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Expanded(child: detailBody),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  for (final spec in _settingsSubTabs)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key(spec.keyName),
                        selected: _activeTab == spec.tab,
                        onSelected: (_) => _selectTab(spec.tab),
                        backgroundColor: _sidebarBg,
                        selectedColor: _accentBlue.withValues(alpha: 0.22),
                        side: BorderSide(
                          color: _activeTab == spec.tab
                              ? _accentBlue
                              : LuminaTokens.borderControl,
                        ),
                        label: Text(
                          spec.label,
                          style: TextStyle(
                            fontSize: 12,
                            color: _activeTab == spec.tab
                                ? _accentBlue
                                : LuminaTokens.textSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(color: _dividerColor, height: 1),
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  contentHorizontalPad,
                  10,
                  contentHorizontalPad,
                  8,
                ),
                child: detailBody,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSettingsRailItem(_NavItemSpec spec) {
    final isSelected = _activeTab == spec.tab;
    return Material(
      color: isSelected ? LuminaTokens.cardElevatedBg : Colors.transparent,
      child: InkWell(
        key: Key(spec.keyName),
        hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.7),
        onTap: () => _selectTab(spec.tab),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: isSelected ? _accentBlue : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 11),
          child: Text(
            spec.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSelected
                  ? LuminaTokens.textPrimary
                  : LuminaTokens.textSecondary,
              fontSize: 13.5,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
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
      return HomeDashboardView(
        audioService: _effectiveAudioService,
        libraryCache: _libraryCache,
        initialScrollOffset: savedOffset,
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
      );
    }

    if (_isSettingsTab(_activeTab)) {
      return _buildSettingsWorkspace(
        isDesktop: isDesktop,
        availWidth: availWidth,
      );
    }

    final pad = EdgeInsets.symmetric(
      horizontal: LuminaResponsive.contentHorizontalPadding(availWidth),
      vertical: 8,
    );

    return Padding(
      padding: pad,
      child: switch (_activeTab) {
        HomeTab.library => StreamBuilder<PlaybackState>(
          stream: _effectiveAudioService.stateStream,
          initialData: _effectiveAudioService.currentState,
          builder: (context, snapshot) {
            final state = snapshot.data ?? _effectiveAudioService.currentState;
            return LibraryBrowserView(
              audioService: _effectiveAudioService,
              activeTrackId: state.track?.id,
              librarySettings: _librarySettingsController,
              onOpenLibrarySettings: () => _selectTab(HomeTab.librarySettings),
            );
          },
        ),
        HomeTab.albums => AlbumsAndCreditsView(
          key: ValueKey('albums_mode_$entryId'),
          audioService: _effectiveAudioService,
          libraryCache: _libraryCache,
          layoutController: _albumLayoutController,
          startInCreditsMode: false,
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
        HomeTab.audiobooks => AudiobooksView(audioService: _effectiveAudioService),
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
            final state = snapshot.data ?? _effectiveAudioService.currentState;
            return UnifiedSearchResultsView(
              controller: _searchController,
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              streamingManager: _streamingManager,
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
          selectedPlaylistId: entry.smartPlaylistId ?? _selectedSmartPlaylistId,
          onSelectPlaylist: (id) {
            setState(() => _selectedSmartPlaylistId = id);
            _navController.replaceCurrent(
              _navController.current.copyWith(smartPlaylistId: id),
            );
          },
        ),
        HomeTab.streamingProvider => StreamBuilder<PlaybackState>(
          stream: _effectiveAudioService.stateStream,
          initialData: _effectiveAudioService.currentState,
          builder: (context, snapshot) {
            final meta = StreamingProviderMeta.byKind(
              entry.streamingKind ?? _selectedStreamingKind ?? '',
            );
            if (meta == null) return const SizedBox.shrink();
            final state = snapshot.data ?? _effectiveAudioService.currentState;
            return StreamingServiceView(
              key: ValueKey('streaming_view_${meta.kind}'),
              audioService: _effectiveAudioService,
              provider: meta,
              streamingManager: _streamingManager,
              onPlayStreamingTrack: _playStreamingTrack,
              onPlayStreamingTrackWithContext: (track, queue) =>
                  _playStreamingTrack(track, queueContext: queue),
              onOpenStreamingAlbum: _openStreamingAlbum,
              onSwitchStreamingProvider: _openStreamingProvider,
              activeTrackId: state.track?.id,
              onOpenProviderSettings: () => _selectTab(HomeTab.settings),
              onLibraryUpdated: () {
                _libraryCache.refresh(widget.audioService);
                setState(() {});
              },
            );
          },
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}
