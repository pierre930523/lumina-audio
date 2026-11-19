import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/nav_entry.dart';
import '../models/playback_state.dart';
import '../models/streaming_provider_meta.dart';
import '../models/studio_models.dart';
import '../services/album_layout_settings_controller.dart';
import '../services/audio_service.dart';
import '../services/library_index_cache.dart';
import '../services/library_settings_controller.dart';
import '../services/smart_playlist_service.dart';
import '../services/ui_scale_controller.dart';
import '../shaders/shader_loader.dart';
import 'albums/album_detail_page.dart';
import 'albums/albums_and_credits_view.dart';
import 'artists/artist_detail_page.dart';
import 'artists/artists_view.dart';
import 'audiobooks/audiobooks_view.dart';
import 'dsp/dsp_control_panel.dart';
import 'home/home_dashboard_view.dart';
import 'library/library_browser_view.dart';
import 'mini_player/floating_capsule.dart';
import 'now_playing/now_playing_overlay.dart';
import 'playlists/smart_playlists_view.dart';
import 'podcasts/podcasts_view.dart';
import 'profiles/profile_switcher_bar.dart';
import 'radio/radio_view.dart';
import 'settings/appearance_scale_panel.dart';
import 'settings/general_settings_panel.dart';
import 'settings/library_settings_panel.dart';
import 'settings/providers_and_remote_panel.dart';
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

enum LuminaUiVersion {
  v2Overhaul,
  v1Classic,
}

class HomeScreen extends StatefulWidget {
  final AudioService audioService;
  final UiScaleController? uiScaleController;
  final LibraryIndexCache? libraryCache;
  final NavHistoryController? navHistoryController;

  const HomeScreen({
    super.key,
    required this.audioService,
    this.uiScaleController,
    this.libraryCache,
    this.navHistoryController,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
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
  bool _isDetailScrolledPastHero = false;
  String? _activeDetailTitle;
  late final AnimationController _stickyTitleFadeController;
  late final Animation<double> _stickyTitleFadeAnimation;
  String? _selectedAlbumId;
  String? _selectedCreditArtistId;
  String? _selectedSmartPlaylistId;
  String? _selectedStreamingKind;
  List<ProviderStatusInfo> _loggedInStreamingProviders = const [];
  LoadedShaders _shaders = LoadedShaders.empty;
  ui.FragmentShader? _glassShader;
  late final UiScaleController _scaleController;
  late final bool _ownsScaleController;
  late final SmartPlaylistService _playlistService;
  late final LibrarySettingsController _librarySettingsController;
  late final AlbumLayoutSettingsController _albumLayoutController;
  LuminaUiVersion _uiVersion = LuminaUiVersion.v2Overhaul;

  HomeTab get _activeTab => _navController.current.tab;

  @override
  void initState() {
    super.initState();
    _stickyTitleFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _stickyTitleFadeAnimation = CurvedAnimation(
      parent: _stickyTitleFadeController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

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
    _playlistService = SmartPlaylistService()..load();
    _librarySettingsController = LibrarySettingsController()..load();
    _albumLayoutController = AlbumLayoutSettingsController()..load();
    _selectedSmartPlaylistId = _playlistService.playlists.firstOrNull?.id;
    _syncStateFromEntry(_navController.current);
    _refreshProviders();
    _initShaders();
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
        _activeTab == HomeTab.albumDetail || _activeTab == HomeTab.artistDetail;
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
    if (entry.tab.isSettings) {
      _lastSettingsTab = entry.tab;
    }

    final isDetailTab =
        entry.tab == HomeTab.albumDetail || entry.tab == HomeTab.artistDetail;
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
    final list = await widget.audioService.listProviders();
    if (!mounted) return;
    final streaming = list
        .where(
          (p) =>
              StreamingProviderMeta.isStreamingKind(p.kind) &&
              (p.isOnline || p.isConfigured),
        )
        .toList();
    setState(() {
      _loggedInStreamingProviders = streaming;
      if (_activeTab == HomeTab.streamingProvider &&
          !streaming.any((p) => p.kind == _selectedStreamingKind)) {
        _selectedStreamingKind = null;
        _navController.replaceCurrent(NavEntry.tab(HomeTab.settings));
      }
    });
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
    _stickyTitleFadeController.dispose();
    _libraryCache.removeListener(_onLibraryCacheChanged);
    _navController.removeListener(_onNavChanged);
    if (_ownsNavController) {
      _navController.dispose();
    }
    if (_ownsLibraryCache) {
      _libraryCache.dispose();
    }
    if (_ownsScaleController) {
      _scaleController.dispose();
    }
    _playlistService.dispose();
    _librarySettingsController.dispose();
    _albumLayoutController.dispose();
    _glassShader?.dispose();
    _shaders.backdropImage?.dispose();
    super.dispose();
  }

  bool _isSettingsTab(HomeTab tab) => tab.isSettings;

  void _pushEntry(NavEntry entry) {
    if (entry.isSameRoute(_navController.current) && !_isNowPlayingExpanded) {
      return;
    }
    setState(() {
      _isNowPlayingExpanded = false;
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
    _libraryCache.loadAlbumDetail(widget.audioService, albumId);
    _pushEntry(NavEntry.album(albumId));
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
    setState(() {
      _isNowPlayingExpanded = false;
    });
    _navController.goBack();
  }

  void _goForward() {
    if (!_navController.canGoForward) return;
    setState(() {
      _isNowPlayingExpanded = false;
    });
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
    setState(() {
      _isNowPlayingExpanded = !_isNowPlayingExpanded;
    });
  }

  bool _isTextEditingFocused() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final context = focus.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _handleEscape() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    if (_isNowPlayingExpanded) {
      setState(() {
        _isNowPlayingExpanded = false;
      });
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (_isTextEditingFocused()) return;
            widget.audioService.togglePlayPause();
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _goBack,
          const SingleActivator(LogicalKeyboardKey.backspace): () {
            if (_isTextEditingFocused()) return;
            _goBack();
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
              _goForward,
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            _selectTab(HomeTab.library);
          },
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
            _selectTab(HomeTab.library);
          },
          const SingleActivator(LogicalKeyboardKey.keyM): () {
            if (_isTextEditingFocused()) return;
            widget.audioService.toggleMute();
          },
          const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: _canvasBg,
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final availWidth = constraints.maxWidth;
                  final isDesktop =
                      LuminaResponsive.showDesktopSidebar(availWidth);
                  final sidebarWidth =
                      LuminaResponsive.sidebarWidth(availWidth);
                  return Column(
                    children: [
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, anim) {
                            final isOverlay = child.key ==
                                const ValueKey('now_playing_stage');
                            if (isOverlay) {
                              final slide = Tween<Offset>(
                                begin: const Offset(0, 0.06),
                                end: Offset.zero,
                              ).animate(anim);
                              return FadeTransition(
                                opacity: anim,
                                child: SlideTransition(
                                  position: slide,
                                  child: child,
                                ),
                              );
                            }
                            return FadeTransition(opacity: anim, child: child);
                          },
                          child: _isNowPlayingExpanded
                              ? NowPlayingOverlay(
                                  key: const ValueKey('now_playing_stage'),
                                  audioService: widget.audioService,
                                  onCollapse: () {
                                    setState(
                                        () => _isNowPlayingExpanded = false);
                                  },
                                )
                              : KeyedSubtree(
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
                                                widthFactor: _sidebarCollapsed
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
                                                availWidth: availWidth,
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
                      ),
                      FloatingCapsuleMiniPlayer(
                        audioService: widget.audioService,
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
                    ],
                  );
                },
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
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Text(
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
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: LuminaTokens.statusSuccess,
                    shape: BoxShape.circle,
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
    final isSelected = _activeTab == item.tab;
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
        _buildTopBar(isDesktop: isDesktop, availWidth: availWidth),
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

  Widget _buildUiVersionMenu() {
    return PopupMenuButton<LuminaUiVersion>(
      key: const Key('btn_ui_version_switcher'),
      tooltip: '介面版本切換：v2.0 互動重構版 / v1.0 原始版',
      color: _sidebarBg,
      onSelected: (ver) {
        if (_uiVersion != ver) {
          setState(() {
            _uiVersion = ver;
            if (ver == LuminaUiVersion.v1Classic) {
              _activeDetailTitle = null;
            }
          });
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<LuminaUiVersion>(
          value: LuminaUiVersion.v2Overhaul,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _uiVersion == LuminaUiVersion.v2Overhaul
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: _uiVersion == LuminaUiVersion.v2Overhaul
                    ? _accentBlue
                    : LuminaTokens.textMuted,
              ),
              const SizedBox(width: 8),
              const Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'v2.0 重構新版（建議）',
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '單一頂欄導覽 / 無重複標題',
                      style: TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<LuminaUiVersion>(
          value: LuminaUiVersion.v1Classic,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _uiVersion == LuminaUiVersion.v1Classic
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: _uiVersion == LuminaUiVersion.v1Classic
                    ? _accentBlue
                    : LuminaTokens.textMuted,
              ),
              const SizedBox(width: 8),
              const Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'v1.0 原始舊版',
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '次級返回列 / 重複標題',
                      style: TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: _uiVersion == LuminaUiVersion.v2Overhaul
              ? _accentBlue.withValues(alpha: 0.15)
              : LuminaTokens.cardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: _uiVersion == LuminaUiVersion.v2Overhaul
                ? _accentBlue.withValues(alpha: 0.55)
                : LuminaTokens.borderSubtle,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.layers_rounded,
              size: 13,
              color: _uiVersion == LuminaUiVersion.v2Overhaul
                  ? _accentBlue
                  : LuminaTokens.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              _uiVersion == LuminaUiVersion.v2Overhaul ? 'v2.0 新版' : 'v1.0 舊版',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _uiVersion == LuminaUiVersion.v2Overhaul
                    ? _accentBlue
                    : LuminaTokens.textSecondary,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 14,
              color: _uiVersion == LuminaUiVersion.v2Overhaul
                  ? _accentBlue
                  : LuminaTokens.textMuted,
            ),
          ],
        ),
      ),
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

  Widget _buildTopBar({required bool isDesktop, required double availWidth}) {
    final canGoBack = _navController.canGoBack;
    final canGoForward = _navController.canGoForward;
    final inSettings = _isSettingsTab(_activeTab);
    final effectiveWidth = availWidth / _scaleController.scale;
    final isCompactTopBar = effectiveWidth < 460;
    final isCompactProfile = effectiveWidth < 560;

    return Container(
      decoration: BoxDecoration(
        border: inSettings
            ? const Border(
                bottom: BorderSide(color: _dividerColor, width: 1),
              )
            : null,
      ),
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 18 : (isCompactTopBar ? 8 : 12),
        10,
        isDesktop ? 24 : (isCompactTopBar ? 8 : 12),
        8,
      ),
      child: Row(
        children: [
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
          if (isDesktop && effectiveWidth >= 580) ...[
            _buildUiVersionMenu(),
            const SizedBox(width: 6),
          ],
          if (isDesktop && effectiveWidth >= 500) ...[
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
          IconButton(
            tooltip: '搜尋曲庫',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.search_rounded,
              size: 19,
              color: _activeTab == HomeTab.library
                  ? _accentBlue
                  : LuminaTokens.textSecondary,
            ),
            onPressed: () => _selectTab(HomeTab.library),
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
          SizedBox(width: isCompactTopBar ? 2 : 6),
          ProfileSwitcherBar(
            audioService: widget.audioService,
            compact: isCompactProfile,
          ),
        ],
      ),
    );
  }

  Widget _buildTopBarTitle({
    required bool isDesktop,
    required bool isCompactTopBar,
  }) {
    final showDefaultTitle = !isDesktop || _sidebarCollapsed;
    final isDetailTab =
        _activeTab == HomeTab.albumDetail || _activeTab == HomeTab.artistDetail;
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
                    child: const Text(
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
        audioService: widget.audioService,
        scaleController: _scaleController,
      ),
      HomeTab.appearance => AppearanceAndScalePanel(
        scaleController: _scaleController,
      ),
      HomeTab.librarySettings => LibrarySettingsPanel(
        audioService: widget.audioService,
        settingsController: _librarySettingsController,
        onLibraryChanged: () {
          _libraryCache.refresh(widget.audioService);
          setState(() {});
        },
      ),
      HomeTab.dsp => DspControlPanel(audioService: widget.audioService),
      HomeTab.zones => OutputZonePanel(audioService: widget.audioService),
      HomeTab.settings => ProvidersAndRemotePanel(
        audioService: widget.audioService,
        onProvidersChanged: _refreshProviders,
      ),
      HomeTab.about => AboutSettingsPanel(audioService: widget.audioService),
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
        audioService: widget.audioService,
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
          stream: widget.audioService.stateStream,
          initialData: widget.audioService.currentState,
          builder: (context, snapshot) {
            final state = snapshot.data ?? widget.audioService.currentState;
            return LibraryBrowserView(
              audioService: widget.audioService,
              activeTrackId: state.track?.id,
              librarySettings: _librarySettingsController,
              onOpenLibrarySettings: () => _selectTab(HomeTab.librarySettings),
            );
          },
        ),
        HomeTab.albums => AlbumsAndCreditsView(
          key: ValueKey('albums_mode_$entryId'),
          audioService: widget.audioService,
          libraryCache: _libraryCache,
          layoutController: _albumLayoutController,
          startInCreditsMode: false,
          initialScrollOffset: savedOffset,
          onScrollOffsetChanged: onOffsetChanged,
          onOpenAlbumDetail: _openAlbumDetail,
          onOpenArtist: _openArtist,
        ),
        HomeTab.albumDetail => AlbumDetailPage(
          key: ValueKey('album_detail_${entryId}_${_uiVersion.name}'),
          albumId: entry.albumId ?? _selectedAlbumId ?? '',
          audioService: widget.audioService,
          libraryCache: _libraryCache,
          onBack: _goBack,
          showInlineBackButton: _uiVersion == LuminaUiVersion.v1Classic,
          onOpenArtist: _openArtist,
          onOpenArtistCredits: _openArtistCredits,
          initialScrollOffset: savedOffset,
          onScrollOffsetChanged: onOffsetChanged,
          onTitleChanged: _uiVersion == LuminaUiVersion.v2Overhaul
              ? _onDetailTitleChanged
              : null,
        ),
        HomeTab.credits => AlbumsAndCreditsView(
          key: ValueKey('credits_mode_${entry.creditArtistId ?? entryId}'),
          audioService: widget.audioService,
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
          audioService: widget.audioService,
          libraryCache: _libraryCache,
          onOpenArtist: _openArtist,
          onOpenCredits: () => _openArtistCredits(null),
          onOpenAlbumDetail: _openAlbumDetail,
        ),
        HomeTab.artistDetail => ArtistDetailPage(
          key: ValueKey('artist_detail_${entryId}_${_uiVersion.name}'),
          artistName: entry.artistName ?? entry.artistKey ?? '',
          artistKey: entry.artistKey,
          audioService: widget.audioService,
          libraryCache: _libraryCache,
          onBack: _goBack,
          showInlineBackButton: _uiVersion == LuminaUiVersion.v1Classic,
          onOpenAlbumDetail: _openAlbumDetail,
          onOpenCredits: () => _openArtistCredits(null),
          initialScrollOffset: savedOffset,
          onScrollOffsetChanged: onOffsetChanged,
          onTitleChanged: _uiVersion == LuminaUiVersion.v2Overhaul
              ? _onDetailTitleChanged
              : null,
        ),
        HomeTab.audiobooks => AudiobooksView(audioService: widget.audioService),
        HomeTab.podcasts => PodcastsView(audioService: widget.audioService),
        HomeTab.radio => RadioView(audioService: widget.audioService),
        HomeTab.smartPlaylists => SmartPlaylistsView(
          audioService: widget.audioService,
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
          stream: widget.audioService.stateStream,
          initialData: widget.audioService.currentState,
          builder: (context, snapshot) {
            final meta = StreamingProviderMeta.byKind(
              entry.streamingKind ?? _selectedStreamingKind ?? '',
            );
            if (meta == null) return const SizedBox.shrink();
            final state = snapshot.data ?? widget.audioService.currentState;
            return StreamingServiceView(
              key: ValueKey('streaming_view_${meta.kind}'),
              audioService: widget.audioService,
              provider: meta,
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
