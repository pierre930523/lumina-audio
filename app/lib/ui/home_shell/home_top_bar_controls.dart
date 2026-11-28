part of '../home_screen.dart';

typedef _TopBarMetrics = ({
  bool isSidebarless,
  bool showSidebarSpacer,
  bool showCapsuleInTopBar,
  bool showBrandWordmark,
  bool showCapsuleIcons,
  bool showDrawerLabel,
  bool isCompactTopBar,
  bool isCompactProfile,
  bool showScaleMenu,
  bool showDspQuickBtn,
  bool showBookmarksBtn,
  bool showProfile,
});

extension _HomeTopBarControls on _HomeScreenState {
  _TopBarMetrics _computeTopBarMetrics({
    required bool isDesktop,
    required double availWidth,
    required double contentAvailWidth,
    required HomeLayoutPreset preset,
  }) {
    final isSidebarless = preset.isSidebarless;
    final showCapsuleInTopBar = isSidebarless && availWidth >= 660;
    return (
      isSidebarless: isSidebarless,
      showSidebarSpacer: isDesktop && preset.usesSidebar,
      showCapsuleInTopBar: showCapsuleInTopBar,
      showBrandWordmark: isSidebarless &&
          (showCapsuleInTopBar ? availWidth >= 780 : availWidth >= 420),
      showCapsuleIcons: availWidth >= 1060,
      showDrawerLabel: availWidth >= 1340,
      isCompactTopBar: contentAvailWidth < 480,
      isCompactProfile: contentAvailWidth <
          (isSidebarless ? 1520 : (isDesktop ? 780 : 580)),
      showScaleMenu:
          isDesktop && contentAvailWidth >= (isSidebarless ? 1520 : 820),
      showDspQuickBtn: contentAvailWidth >= (isSidebarless ? 1060 : 680),
      showBookmarksBtn: contentAvailWidth >= (isSidebarless ? 980 : 500),
      showProfile: contentAvailWidth >= 380,
    );
  }

  double _estimateCapsuleHalfWidth(_TopBarMetrics metrics) {
    if (metrics.showCapsuleIcons && metrics.showDrawerLabel) return 184.0;
    if (metrics.showCapsuleIcons) return 164.0;
    return 132.0;
  }

  Widget _buildFloatingNavCapsule({
    required bool showIcons,
    required bool showDrawerLabel,
  }) {
    final glass = LuminaGlassTheme.of(context);
    const capsuleTabs = <({
      String key,
      HomeTab tab,
      String label,
      IconData icon,
      IconData activeIcon,
    })>[
      (
        key: 'capsule_nav_home',
        tab: HomeTab.home,
        label: '主頁',
        icon: Icons.home_outlined,
        activeIcon: Icons.home_rounded,
      ),
      (
        key: 'capsule_nav_albums',
        tab: HomeTab.albums,
        label: '專輯',
        icon: Icons.album_outlined,
        activeIcon: Icons.album_rounded,
      ),
      (
        key: 'capsule_nav_artists',
        tab: HomeTab.artists,
        label: '藝術家',
        icon: Icons.person_outline_rounded,
        activeIcon: Icons.person_rounded,
      ),
      (
        key: 'capsule_nav_library',
        tab: HomeTab.library,
        label: '曲目',
        icon: Icons.music_note_outlined,
        activeIcon: Icons.music_note_rounded,
      ),
    ];

    return FrostedGlassContainer(
      key: const Key('topbar_floating_nav_capsule'),
      blurSigma: LuminaTokens.glassPillBlur,
      color: glass.isDark ? const Color(0x47181B22) : glass.glassBgElevated,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
      border: Border.all(color: glass.glassBorderStrong),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < capsuleTabs.length; i++) ...[
            _buildCapsuleNavPill(
              glass,
              key: Key(capsuleTabs[i].key),
              label: capsuleTabs[i].label,
              icon: _activeTab == capsuleTabs[i].tab
                  ? capsuleTabs[i].activeIcon
                  : capsuleTabs[i].icon,
              showIcon: showIcons,
              selected: _activeTab == capsuleTabs[i].tab ||
                  (capsuleTabs[i].tab == HomeTab.albums &&
                      _activeTab == HomeTab.albumDetail) ||
                  (capsuleTabs[i].tab == HomeTab.artists &&
                      _activeTab == HomeTab.artistDetail),
              onTap: () => _selectTab(capsuleTabs[i].tab),
            ),
            if (i < capsuleTabs.length - 1) const SizedBox(width: 2),
          ],
          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: glass.glassBorderStrong,
          ),
          LibraryOverflowDrawerButton(
            showLabel: showDrawerLabel,
            config: LibraryOverflowConfig(
              activeTab: _activeTab,
              selectedSmartPlaylistId: _selectedSmartPlaylistId,
              selectedStreamingKind: _selectedStreamingKind,
              playlistService: _playlistService,
              listenLaterController: _listenLaterController,
              streamingManager: _streamingManager,
              loggedInStreamingProviders: _loggedInStreamingProviders,
              onSelectTab: _selectTab,
              onOpenSmartPlaylist: _openSmartPlaylist,
              onCreateSmartPlaylist: _promptCreateSmartPlaylist,
              onOpenStreamingProvider: _openStreamingProvider,
              onSecondaryTapSmartPlaylist: (sp, pos) =>
                  _showSmartPlaylistSidebarMenu(context, sp, pos),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCapsuleNavPill(
    LuminaGlassTheme glass, {
    required Key key,
    required String label,
    required IconData icon,
    required bool showIcon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? glass.glassBgActive : Colors.transparent,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        hoverColor: glass.pillHoverBg,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: showIcon ? 10 : 9,
            vertical: 5,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showIcon) ...[
                Icon(
                  icon,
                  size: 14,
                  color: selected ? glass.textPrimary : glass.textSecondary,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: selected ? glass.textPrimary : glass.textSecondary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickScaleMenu(LuminaGlassTheme glass) {
    return ListenableBuilder(
      listenable: _scaleController,
      builder: (context, _) {
        return PopupMenuButton<double>(
          key: const Key('btn_quick_scale_menu'),
          tooltip: '快速調整介面縮放（Ctrl + +/- / 0）',
          color: glass.menuBg,
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
                          ? glass.textPrimary
                          : glass.textTertiary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      preset == 1.0
                          ? '100% (預設)'
                          : '${(preset * 100).round()}%',
                      style: TextStyle(color: glass.textPrimary, fontSize: 13),
                    ),
                  ],
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem<double>(
              value: -1.0,
              child: Text(
                '開啟外觀與縮放微調面板...',
                style: TextStyle(
                  color: glass.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          child: FrostedGlassContainer(
            blurSigma: LuminaTokens.glassPillBlur,
            color: glass.pillBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            border: Border.all(color: glass.pillBorder),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.aspect_ratio_rounded,
                  size: 14,
                  color: glass.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_scaleController.percentage}%',
                  style: TextStyle(
                    color: glass.textPrimary,
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

  Widget _buildCollapsibleTopSearch(
    double contentAvailWidth, {
    required bool isDesktop,
    required _TopBarMetrics metrics,
    required LuminaGlassTheme glass,
  }) {
    final capsuleReserved = metrics.showCapsuleInTopBar
        ? (metrics.showCapsuleIcons ? 356.0 : 256.0)
        : 0.0;
    final wordmarkReserved =
        metrics.showBrandWordmark ? 112.0 : (isDesktop ? 56.0 : 28.0);
    final reservedWidth =
        (metrics.showSidebarSpacer ? 48.0 : 0.0) +
        80.0 + // back + forward icon buttons
        wordmarkReserved +
        capsuleReserved +
        (metrics.showScaleMenu ? 94.0 : 0.0) +
        (metrics.showDspQuickBtn ? 42.0 : 0.0) +
        (metrics.showBookmarksBtn ? 42.0 : 0.0) +
        42.0 + // btn_home_layout_switcher
        48.0 + // settings pill + spacing
        (metrics.showProfile
            ? ((metrics.isCompactTopBar ? 4.0 : 6.0) +
                (metrics.isCompactProfile ? 44.0 : 150.0))
            : 0.0) +
        (isDesktop ? 188.0 : 0.0) +
        8.0; // safety margin against fractional DPR rounding

    final maxSafeWidth = math.max(34.0, contentAvailWidth - reservedWidth);
    final targetExpandedWidth = (contentAvailWidth * 0.30).clamp(140.0, 240.0);
    final expandedWidth = math.min(targetExpandedWidth, maxSafeWidth);
    final boxWidth = _topSearchExpanded ? expandedWidth : 34.0;
    final layoutWidth = math.max(68.0, expandedWidth);
    final hasFocus = _topSearchFocusNode.hasFocus;

    return TapRegion(
      groupId: EditableText,
      onTapOutside: (_) {
        if (!_topSearchExpanded) return;
        _topSearchFocusNode.unfocus();
        if (_topSearchController.text.trim().isEmpty) {
          _refreshState(() => _topSearchExpanded = false);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: boxWidth,
        height: 34.0,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: glass.pillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(
            color: (_topSearchExpanded && hasFocus)
                ? glass.accent
                : glass.pillBorder,
            width: (_topSearchExpanded && hasFocus) ? 1.4 : 1.0,
          ),
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
                      child: Padding(
                        padding: const EdgeInsets.only(left: 10, right: 6),
                        child: Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: glass.textSecondary,
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
                        style: TextStyle(
                          color: glass.textPrimary,
                          fontSize: 13,
                          height: 1.2,
                        ),
                        cursorColor: glass.accent,
                        decoration: InputDecoration(
                          isDense: true,
                          isCollapsed: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          hintText: '搜尋曲庫與串流...',
                          hintStyle: TextStyle(
                            color: glass.textTertiary,
                            fontSize: 12.5,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 4),
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
                      icon: Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: glass.textSecondary,
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
                  hoverColor: glass.pillHoverBg,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    Icons.search_rounded,
                    size: 18,
                    color: glass.textSecondary,
                  ),
                  onPressed: _expandTopSearch,
                ),
              ),
      ),
    );
  }
}
