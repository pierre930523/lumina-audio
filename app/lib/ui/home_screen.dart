import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/home_layout_preset.dart';
import '../models/nav_entry.dart';
import '../models/playback_state.dart';
import '../models/podcast_models.dart';
import '../models/streaming_models.dart';
import '../models/streaming_provider_meta.dart';
import '../models/studio_models.dart';
import '../services/album_layout_settings_controller.dart';
import '../services/artwork_palette_service.dart';
import '../services/audio_service.dart';
import '../services/bookmarks_controller.dart';
import '../services/desktop_window_controller.dart';
import '../services/escape_dismiss_registry.dart';
import '../services/home_dashboard_data_controller.dart';
import '../services/library_index_cache.dart';
import '../services/library_settings_controller.dart';
import '../services/listen_later_controller.dart';
import '../services/listen_later_playback_tracker.dart';
import '../services/now_playing_view_controller.dart';
import '../services/playback/app_service_bootstrapper.dart';
import '../services/playback_persistence_service.dart';
import '../services/podcast_store.dart';
import '../services/recommendation_settings_controller.dart';
import '../services/smart_playlist_service.dart';
import '../services/streaming/autoplay_controller.dart';
import '../services/streaming/oauth_helper.dart';
import '../services/streaming/streaming_manager.dart';
import '../services/ui_scale_controller.dart';
import '../services/unified_search_controller.dart';
import '../shaders/shader_loader.dart';
import 'albums/album_detail_page.dart';
import 'albums/albums_and_credits_view.dart';
import 'artists/artist_detail_page.dart';
import 'artists/artists_view.dart';
import 'audiobooks/audiobooks_view.dart';
import 'common/ambient_dynamic_background.dart';
import 'common/bottom_player_bar_scope.dart';
import 'common/desktop_window_caption.dart';
import 'common/frosted_glass_container.dart';
import 'common/lumina_context_menu.dart';
import 'common/track_hover_prefetch.dart';
import 'common/window_drag_bar.dart';
import 'dsp/dsp_control_panel.dart';
import 'folders/folders_view.dart';
import 'home/home_stage_view.dart';
import 'home/widgets/top_ambient_aura.dart';
import 'home_shell/bookmarks_menu_button.dart';
import 'home_shell/home_layout_switcher_button.dart';
import 'home_shell/library_overflow_drawer.dart';
import 'library/library_browser_view.dart';
import 'listen_later/listen_later_view.dart';
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
import 'settings/settings_widgets.dart';
import 'settings/streaming_login_dialog.dart';
import 'streaming/streaming_service_view.dart';
import 'tags/tags_view.dart';
import 'theme/lumina_glass_theme.dart';
import 'theme/lumina_tokens.dart';
import 'theme/responsive_layout.dart';
import 'theme/smooth_scroll.dart';
import 'zones/output_zone_panel.dart';

part 'home_shell/home_content_router.dart';
part 'home_shell/home_input_and_notices.dart';
part 'home_shell/home_lifecycle.dart';
part 'home_shell/home_navigation.dart';
part 'home_shell/home_settings_workspace.dart';
part 'home_shell/home_shell_layout.dart';
part 'home_shell/home_sidebar.dart';
part 'home_shell/home_sidebar_menu.dart';
part 'home_shell/home_top_bar.dart';
part 'home_shell/home_top_bar_controls.dart';
part 'home_shell/home_window_tray.dart';

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
  final RecommendationSettingsController? recommendationSettings;
  final AutoplayController? autoplayController;

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
    this.recommendationSettings,
    this.autoplayController,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final DesktopWindowController _windowController =
      widget.windowController ?? DesktopWindowController.instance;

  late final NavHistoryController _navController;
  late final bool _ownsNavController;
  late final LibraryIndexCache _libraryCache;
  late final bool _ownsLibraryCache;

  HomeTab _lastSettingsTab = HomeTab.general;
  bool _sidebarCollapsed = false;
  bool _isNowPlayingExpanded = false;
  bool _hasEverExpandedNowPlaying = false;
  final ValueNotifier<double?> _measuredMiniPlayerHeight =
      ValueNotifier<double?>(null);
  final ValueNotifier<double> _effectiveMiniPlayerClearance =
      ValueNotifier<double>(84.0);
  final ValueNotifier<bool> _headerScrimVisible = ValueNotifier<bool>(false);
  final GlideScrollController _settingsScrollController =
      GlideScrollController();
  final GlideScrollController _sidebarScrollController =
      GlideScrollController();
  final GlideScrollController _settingsTabBarScrollController =
      GlideScrollController();
  final GlideScrollController _compactNavScrollController =
      GlideScrollController();
  double? _lastReportedMiniPlayerHeight;
  final TextEditingController _topSearchController = TextEditingController();
  final FocusNode _topSearchFocusNode = FocusNode();
  final GlobalKey _layoutSwitcherKey = GlobalKey(
    debugLabel: 'home_layout_switcher',
  );
  bool _topSearchExpanded = false;
  late final NowPlayingViewController _nowPlayingController;
  late final bool _ownsNowPlayingController;
  late final ArtworkPaletteService _paletteService;
  late final AnimationController _nowPlayingAnimController;
  late final CurvedAnimation _nowPlayingCurvedAnim;
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
  String? _selectedTagId;
  String? _selectedFolderId;
  List<ProviderStatusInfo> _loggedInStreamingProviders = const [];
  LoadedShaders _shaders = LoadedShaders.empty;
  ui.FragmentShader? _glassShader;
  late final UiScaleController _scaleController;
  late final bool _ownsScaleController;
  late final SmartPlaylistService _playlistService;
  late final BookmarksController _bookmarksController;
  late final ListenLaterController _listenLaterController;
  late final ListenLaterPlaybackTracker _listenLaterPlaybackTracker;
  late final LibrarySettingsController _librarySettingsController;
  late final AlbumLayoutSettingsController _albumLayoutController;
  String? _activeFocusQueryJson;
  String? _activeViewStateJson;
  String? _activeBookmarkId;
  late final PlaybackPersistenceService _playbackPersistenceService;
  late final bool _ownsPlaybackPersistenceService;
  late final PodcastStore _podcastStore;
  late final PodcastPlaybackTracker _podcastPlaybackTracker;
  late final AppPlaybackSession _playbackSession;
  late final StreamingManager _streamingManager;
  late final RecommendationSettingsController _recommendationSettings;
  late final AudioService _effectiveAudioService;
  late final UnifiedSearchController _searchController;
  late final HomeDashboardDataController _homeDataController;
  HomeLayoutPreset _lastHomeLayoutPreset = HomeLayoutPreset.auraQuickResume;
  ThemeMode _lastThemeMode = ThemeMode.dark;
  bool _lastAuraFollowCover = true;
  bool _lastMinimalCoverMode = false;
  double? _lastMeasuredRawMiniHeight;
  StreamSubscription<PlaybackState>? _playbackStateSub;
  StreamSubscription<TrackInfo>? _trackChangedSub;
  StreamSubscription<void>? _libraryReloadedSub;

  bool _isStartupRestoring = true;
  bool _isHiddenToTray = false;
  bool _isExiting = false;
  PlaybackStatus? _lastPersistedStatus;
  String? _lastPersistedTrackId;
  String? _lastTrayTrackKey;
  bool? _lastTrayPlaying;
  bool? _lastTrayIdle;

  // Store exact tear-off instances for extension methods so unbind/remove calls
  // match the registered callback identity across evaluations.
  late final VoidCallback _boundWindowClose = _handleWindowClose;
  late final VoidCallback _boundRestoreFromTray = _handleRestoreFromTray;
  late final void Function(String action) _boundTrayMenuAction =
      _handleTrayMenuAction;
  late final VoidCallback _boundWindowMinimize = _handleWindowMinimize;
  late final VoidCallback _boundWindowRestoredOrFocused =
      _handleWindowRestoredOrFocused;
  late final VoidCallback _boundStreamingManagerChanged =
      _onStreamingManagerChanged;
  late final void Function(AnimationStatus status) _boundNowPlayingAnimStatus =
      _onNowPlayingAnimStatus;
  late final VoidCallback _boundNavChanged = _onNavChanged;
  late final VoidCallback _boundLibraryCacheChanged = _onLibraryCacheChanged;
  late final VoidCallback _boundScaleControllerVisualizerChanged =
      _onScaleControllerVisualizerChanged;
  late final VoidCallback _boundScaleAppearanceChanged =
      _onScaleAppearanceChanged;
  late final VoidCallback _boundTopSearchFocusChanged =
      _onTopSearchFocusChanged;
  late final VoidCallback _boundSettingsScrollChanged =
      _onSettingsScrollChanged;
  late final bool Function(KeyEvent event) _boundHardwareKey =
      _handleHardwareKey;

  HomeTab get _activeTab => _navController.current.tab;

  void _refreshState([VoidCallback? fn]) {
    if (!mounted) return;
    setState(fn ?? () {});
  }

  void _onScaleAppearanceChanged() {
    if (!mounted) return;
    final nextPreset = _scaleController.homeLayoutPreset;
    final nextTheme = _scaleController.themeMode;
    final nextAura = _scaleController.auraFollowCover;
    final nextMinimal = _scaleController.minimalCoverMode;
    if (nextPreset == _lastHomeLayoutPreset &&
        nextTheme == _lastThemeMode &&
        nextAura == _lastAuraFollowCover &&
        nextMinimal == _lastMinimalCoverMode) {
      return;
    }
    _lastHomeLayoutPreset = nextPreset;
    _lastThemeMode = nextTheme;
    _lastAuraFollowCover = nextAura;
    _lastMinimalCoverMode = nextMinimal;
    _syncEffectiveClearance();
    _refreshState();
  }

  void _syncEffectiveClearance([double? rawMiniHeight]) {
    final base = rawMiniHeight ?? _lastMeasuredRawMiniHeight;
    if (base == null) return;
    final target = _scaleController.homeLayoutPreset.usesFloatingPlayerPill
        ? base + 12.0
        : base;
    if ((_effectiveMiniPlayerClearance.value - target).abs() > 0.5) {
      _effectiveMiniPlayerClearance.value = target;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initControllers();
    _initWindowAndTray();
    _libraryReloadedSub = _effectiveAudioService.libraryReloadedStream.listen(
      _handleLibraryReloaded,
    );
  }

  void _handleLibraryReloaded(void _) {
    if (!mounted) return;
    _libraryCache.setIncludeHiddenSync(_albumLayoutController.showHiddenAlbums);
    unawaited(_libraryCache.refresh(_effectiveAudioService));
    unawaited(_playlistService.load());
    unawaited(_bookmarksController.load());
    unawaited(_listenLaterController.refresh());
    _refreshState();
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('曲庫備份已還原，已自動重新載入資料庫。')),
      );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _handleWindowRestoredOrFocused();
    }
  }

  @override
  void dispose() {
    _libraryReloadedSub?.cancel();
    _libraryReloadedSub = null;
    _disposeControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final preset = _scaleController.homeLayoutPreset;
    return BottomPlayerBarScope(
      clearanceListenable: _effectiveMiniPlayerClearance,
      child: TrackPrefetchScope(
        onPrefetchTrack: _playbackSession.requestHoverPrefetch,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          child: Focus(
            autofocus: true,
            onKeyEvent: _handleGlobalKeyEvent,
            child: FocusScope(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: ColoredBox(
                  color: glass.canvasBg,
                  child: TickerMode(
                    enabled: !_isHiddenToTray,
                    child: SafeArea(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final availWidth = constraints.maxWidth;
                          final isDesktop =
                              LuminaResponsive.showDesktopSidebar(availWidth);
                          final sidebarWidth = switch (preset) {
                            HomeLayoutPreset.classic => math.max(
                              220.0,
                              LuminaResponsive.sidebarWidth(availWidth),
                            ),
                            _ => 0.0,
                          };
                          final baseFallbackMini = availWidth >= 740
                              ? 84.0
                              : (availWidth >= 480 ? 99.0 : 114.0);
                          final fallbackMiniPlayerClearance =
                              preset.usesFloatingPlayerPill
                                  ? baseFallbackMini + 12.0
                                  : baseFallbackMini;
                          if (_measuredMiniPlayerHeight.value == null &&
                              (_effectiveMiniPlayerClearance.value -
                                          fallbackMiniPlayerClearance)
                                      .abs() >
                                  0.5) {
                            _scheduleFallbackClearanceSync(
                              fallbackMiniPlayerClearance,
                            );
                          }
                          final showOverlay =
                              _hasEverExpandedNowPlaying &&
                              (_isNowPlayingExpanded ||
                                  !_nowPlayingAnimController.isDismissed);
                          final isNowPlayingFullyCovered =
                              _isNowPlayingExpanded &&
                              _nowPlayingAnimController.isCompleted &&
                              !_isHiddenToTray;

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              _buildAmbientLayer(
                                isNowPlayingFullyCovered:
                                    isNowPlayingFullyCovered,
                              ),
                              Positioned.fill(
                                child: CustomMultiChildLayout(
                                  delegate: _HomeShellLayoutDelegate(
                                    floatingPillMode:
                                        preset.usesFloatingPlayerPill,
                                    onMiniPlayerHeightMeasured:
                                        _handleShellMiniPlayerMeasured,
                                  ),
                                  children: [
                                    _buildWorkspaceLayer(
                                      isDesktop: isDesktop,
                                      availWidth: availWidth,
                                      sidebarWidth: sidebarWidth,
                                      isNowPlayingFullyCovered:
                                          isNowPlayingFullyCovered,
                                    ),
                                    if (_hasEverExpandedNowPlaying)
                                      _buildNowPlayingLayer(
                                        fallbackMiniPlayerClearance:
                                            baseFallbackMini,
                                        isOverlayActive: showOverlay,
                                        isNowPlayingFullyCovered:
                                            isNowPlayingFullyCovered,
                                      ),
                                    _buildMiniPlayerLayer(
                                      suppressBackdropBlur: showOverlay,
                                    ),
                                  ],
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
        ),
      ),
    );
  }
}
