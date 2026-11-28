part of '../home_screen.dart';

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

const List<_NavItemSpec> _browseNavItems = [
  _NavItemSpec(tab: HomeTab.home, keyName: 'nav_tab_home', label: '主頁', icon: Icons.home_outlined, activeIcon: Icons.home_rounded),
  _NavItemSpec(tab: HomeTab.credits, keyName: 'nav_tab_credits', label: '關係圖', icon: Icons.account_tree_outlined, activeIcon: Icons.account_tree_rounded),
];

const List<_NavItemSpec> _libraryNavItems = [
  _NavItemSpec(tab: HomeTab.albums, keyName: 'nav_tab_albums', label: '專輯', icon: Icons.album_outlined, activeIcon: Icons.album_rounded),
  _NavItemSpec(tab: HomeTab.artists, keyName: 'nav_tab_artists', label: '藝術家', icon: Icons.person_outline_rounded, activeIcon: Icons.person_rounded),
  _NavItemSpec(tab: HomeTab.library, keyName: 'nav_tab_library', label: '曲目', icon: Icons.music_note_outlined, activeIcon: Icons.music_note_rounded),
  _NavItemSpec(tab: HomeTab.smartPlaylists, keyName: 'nav_tab_smart_playlists', label: '智慧歌單', icon: Icons.auto_awesome_outlined, activeIcon: Icons.auto_awesome_rounded),
  _NavItemSpec(tab: HomeTab.listenLater, keyName: 'nav_tab_listen_later', label: '稍後收聽', icon: Icons.watch_later_outlined, activeIcon: Icons.watch_later_rounded),
  _NavItemSpec(tab: HomeTab.tags, keyName: 'nav_tab_tags', label: '標籤', icon: Icons.label_outline_rounded, activeIcon: Icons.label_rounded),
  _NavItemSpec(tab: HomeTab.folders, keyName: 'nav_tab_folders', label: '資料夾', icon: Icons.folder_outlined, activeIcon: Icons.folder_rounded),
];

const List<_NavItemSpec> _mediaNavItems = [
  _NavItemSpec(tab: HomeTab.audiobooks, keyName: 'nav_tab_audiobooks', label: '有聲書', icon: Icons.menu_book_outlined, activeIcon: Icons.menu_book_rounded),
  _NavItemSpec(tab: HomeTab.podcasts, keyName: 'nav_tab_podcasts', label: 'Podcast', icon: Icons.podcasts_outlined, activeIcon: Icons.podcasts_rounded),
  _NavItemSpec(tab: HomeTab.radio, keyName: 'nav_tab_radio', label: '廣播電台', icon: Icons.radio_outlined, activeIcon: Icons.radio_rounded),
];

extension _HomeSidebarBuilder on _HomeScreenState {
  Widget _buildSidebar({
    required double width,
    required bool collapsed,
    required HomeLayoutPreset preset,
  }) {
    final glass = LuminaGlassTheme.of(context);
    final isClassicDark = preset == HomeLayoutPreset.classic && glass.isDark;
    final bgColor = isClassicDark ? LuminaTokens.glassSidebarBg : glass.sidebarBg;
    final blurSigma = isClassicDark ? LuminaTokens.glassSidebarBlur : glass.glassBlur;
    final borderColor = isClassicDark ? LuminaTokens.glassSidebarBorder : glass.sidebarBorder;

    return FrostedGlassContainer(
      key: const Key('main_sidebar_glass_container'),
      width: width,
      color: bgColor,
      blurSigma: blurSigma,
      enableBackdropBlur: !collapsed,
      border: Border(right: BorderSide(color: borderColor, width: 1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IgnorePointer(
            child: SizedBox(
              key: const Key('sidebar_brand_header'),
              width: width,
              height: WindowDragBar.kDefaultHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Lumina Audio',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: glass.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ValueListenableBuilder<double?>(
              valueListenable: _measuredMiniPlayerHeight,
              builder: (context, measuredHeight, child) {
                final floatingBottomPad = preset.usesFloatingPlayerPill
                    ? (measuredHeight ?? 84.0)
                    : 0.0;
                return Padding(
                  padding: EdgeInsets.only(bottom: floatingBottomPad),
                  child: child,
                );
              },
              child: _BottomEdgeFadeMask(
                fadeHeight: 28.0,
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    _playlistService,
                    _listenLaterController,
                  ]),
                  builder: (context, _) {
                    final pinnedPlaylists = _playlistService.pinnedPlaylists;
                    return SmoothScrollWrapper(
                      controller: _sidebarScrollController,
                      child: SingleChildScrollView(
                        controller: _sidebarScrollController,
                        padding: const EdgeInsets.only(
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildSidebarSectionLabel(glass, '瀏覽'),
                          for (final item in _browseNavItems)
                            _buildSidebarTile(glass, item),
                          const SizedBox(height: LuminaTokens.spaceXs),
                          _buildSidebarSectionLabel(glass, '我的音樂資料庫'),
                          for (final item in _libraryNavItems)
                            _buildSidebarTile(glass, item),
                          const SizedBox(height: LuminaTokens.spaceXs),
                          _buildSidebarSectionLabel(glass, '媒體'),
                          for (final item in _mediaNavItems)
                            _buildSidebarTile(glass, item),
                          if (_loggedInStreamingProviders.isNotEmpty) ...[
                            const SizedBox(height: LuminaTokens.spaceXs),
                            _buildSidebarSectionLabel(glass, '串流服務'),
                            for (final p in _loggedInStreamingProviders)
                              if (StreamingProviderMeta.byKind(p.kind)
                                  case final meta?)
                                _buildStreamingSidebarTile(glass, meta),
                          ],
                          const SizedBox(height: LuminaTokens.spaceMd),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 0, 10, 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '智慧播放清單',
                                  style: TextStyle(
                                    color: glass.textTertiary,
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
                                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                  icon: Icon(
                                    Icons.add_rounded,
                                    size: 16,
                                    color: glass.textSecondary,
                                  ),
                                  onPressed: _promptCreateSmartPlaylist,
                                ),
                              ],
                            ),
                          ),
                          for (final sp in pinnedPlaylists)
                            _buildSmartPlaylistSidebarTile(glass, sp),
                        ],
                      ),
                    ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmartPlaylistSidebarTile(
    LuminaGlassTheme glass,
    SmartPlaylistItem sp,
  ) {
    final isSelected =
        _activeTab == HomeTab.smartPlaylists &&
        _selectedSmartPlaylistId == sp.id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: GestureDetector(
        onSecondaryTapUp: (d) =>
            _showSmartPlaylistSidebarMenu(context, sp, d.globalPosition),
        child: Material(
          color: isSelected ? glass.glassBgActive : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            key: Key('sidebar_smart_playlist_${sp.id}'),
            borderRadius: BorderRadius.circular(8),
            hoverColor: glass.glassBgHover,
            onTap: () => _openSmartPlaylist(sp.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 13,
                    color: isSelected ? glass.textPrimary : glass.textSecondary,
                  ),
                  const SizedBox(width: LuminaTokens.spaceXs),
                  Expanded(
                    child: Text(
                      sp.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected ? glass.textPrimary : glass.textSecondary,
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarSectionLabel(LuminaGlassTheme glass, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
      child: Text(
        title,
        style: TextStyle(
          color: glass.textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _buildStreamingSidebarTile(
    LuminaGlassTheme glass,
    StreamingProviderMeta meta,
  ) {
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
              : glass.accent.withValues(alpha: 0.75));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: isSelected ? glass.glassBgActive : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: Key('nav_streaming_${meta.kind}'),
          borderRadius: BorderRadius.circular(8),
          hoverColor: glass.glassBgHover,
          onTap: () => _openStreamingProvider(meta.kind),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                      color: isSelected ? glass.textPrimary : glass.textSecondary,
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
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

  Widget _buildSidebarTile(LuminaGlassTheme glass, _NavItemSpec item) {
    final isSelected =
        _activeTab == item.tab ||
        (item.tab == HomeTab.podcasts && _activeTab == HomeTab.podcastDetail);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Material(
        color: isSelected ? glass.glassBgActive : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: Key(item.keyName),
          borderRadius: BorderRadius.circular(8),
          hoverColor: glass.glassBgHover,
          onTap: () => _selectTab(item.tab),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                Icon(
                  isSelected ? item.activeIcon : item.icon,
                  size: 17,
                  color: isSelected ? glass.textPrimary : glass.textSecondary,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? glass.textPrimary : glass.textSecondary,
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (item.tab == HomeTab.listenLater &&
                    _listenLaterController.pendingCount > 0)
                  Container(
                    key: const Key('sidebar_listen_later_badge'),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: glass.accent.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: glass.accent.withValues(alpha: 0.6)),
                    ),
                    child: Text(
                      '${_listenLaterController.pendingCount}',
                      style: TextStyle(
                        color: glass.textPrimary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
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
}
